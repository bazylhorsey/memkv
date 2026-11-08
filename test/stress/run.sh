#!/bin/bash
# Concurrency stress test for memkv.
#
# Run it against a SCRATCH server: it changes memkv.max_memory with ALTER SYSTEM
# and flushes the store. Connection settings come from the usual PG* variables.
#
#   test/stress/run.sh [seconds-for-the-mixed-phase] [clients]
#
# Set MEMKV_TEST_LOG to the server log to also scan it for crashes and
# assertion failures. Build the server with --enable-cassert to get the most
# out of this. The exit status is non-zero if any check fails.
set -u
cd "$(dirname "$0")" || exit 2

SECS=${1:-30}
CLIENTS=${2:-32}
JOBS=${JOBS:-8}
PSQL="psql -X -Atq -v ON_ERROR_STOP=1"
OUT=$(mktemp)
trap 'rm -f "$OUT"' EXIT
fails=0

ok()  { printf 'PASS  %s\n' "$*"; }
bad() { printf 'FAIL  %s\n' "$*"; fails=$((fails + 1)); }

set_cap() {     # MB
    $PSQL -c "ALTER SYSTEM SET memkv.max_memory = '$1MB'" \
          -c "SELECT pg_reload_conf()" >/dev/null
    sleep 1
}

log_mark() { if [ -n "${MEMKV_TEST_LOG:-}" ]; then wc -c < "$MEMKV_TEST_LOG"; else echo 0; fi; }

log_check() {   # byte offset from log_mark, phase name
    [ -n "${MEMKV_TEST_LOG:-}" ] || return 0
    local pat='TRAP:|PANIC|terminated by signal|was terminated|Assert|assertion|corrupt'
    if tail -c +"$(($1 + 1))" "$MEMKV_TEST_LOG" | grep -E -q "$pat"; then
        bad "$2: the server log shows a crash or assertion failure"
        tail -c +"$(($1 + 1))" "$MEMKV_TEST_LOG" | grep -E "$pat" | head -5
    fi
}

# pgbench with the common flags. Fails if it exits non-zero or reports errors.
pgb() {         # phase name, then pgbench arguments
    local name=$1
    shift
    pgbench -n -M prepared -j "$JOBS" "$@" > "$OUT" 2>&1
    local rc=$?
    if [ $rc -ne 0 ] || grep -q -i -E 'aborted|error|failed transactions: [1-9]' "$OUT"; then
        bad "$name: pgbench exit status $rc"
        grep -i -E 'aborted|error|failed' "$OUT" | head -5
        return 1
    fi
    return 0
}

fill_capacity() {   # flush, then fill the store with 1000-byte values, evicting as it overflows
    $PSQL -c "SELECT memkv.flush()" >/dev/null
    $PSQL <<'SQL'
DO $$ BEGIN
  FOR i IN 1..30000 LOOP PERFORM memkv.set('cap' || i, repeat('x', 1000)); END LOOP;
END $$;
SQL
}

# Flush, then count the 1000-byte values that fit before the first eviction.
# Counting after an overflow instead would depend on where in an eviction
# round the loop stopped, which moves by up to a sixteenth of the store.
count_capacity() {
    $PSQL -c "SELECT memkv.flush()" >/dev/null
    $PSQL 2>&1 <<'SQL' | sed -n 's/^NOTICE:  *//p'
DO $$
DECLARE
  n int := 0;
  e0 bigint := (SELECT evicted FROM memkv.stats());
BEGIN
  WHILE n < 30000 LOOP
    PERFORM memkv.set('cap' || n, repeat('x', 1000));
    EXIT WHEN (SELECT evicted FROM memkv.stats()) > e0;
    n := n + 1;
  END LOOP;
  RAISE NOTICE '%', n;
END $$;
SQL
}

$PSQL -c "CREATE EXTENSION IF NOT EXISTS memkv" >/dev/null 2>&1

# An exact leak oracle, for servers built with assertions. PostgreSQL's
# dsa_dump() lists every allocator span with how many of its objects are free,
# and kv_debug_dsa() sends that to the server log. After a flush only the
# index's own structures may be allocated: its control block and its bucket
# array. Needs MEMKV_TEST_LOG. have_dump=0 when it isn't available.
have_dump=0
if [ -n "${MEMKV_TEST_LOG:-}" ] &&
   $PSQL -c "CREATE OR REPLACE FUNCTION kv_debug_dsa() RETURNS void AS '\$libdir/memkv', 'kv_debug_dsa' LANGUAGE C" >/dev/null 2>&1; then
    have_dump=1
fi

live_objects() {    # flush, dump the allocator, count what is still allocated
    local mark
    $PSQL -c "SELECT memkv.flush()" >/dev/null
    mark=$(log_mark)
    $PSQL -c "SELECT kv_debug_dsa()" >/dev/null
    tail -c +"$((mark + 1))" "$MEMKV_TEST_LOG" | awk '
        /pool for size class/            { mode = "small"; next }
        /pool for large object spans/    { mode = "large"; next }
        /pool for blocks of span objects/ { mode = ""; next }
        /objects free = /                { split($NF, a, "/")
                                           if (mode == "small") live += a[2] - a[1]
                                           else if (mode == "large") live += 1 }
        END { print live + 0 }'
}

[ "$have_dump" -eq 1 ] && base_live=$(live_objects)

# verify() compares entries with each other, so it only means something when
# nothing is writing: call it between phases, never during one.
check_verify() {    # phase name
    local n
    n=$($PSQL -c "SELECT count(*) FROM memkv.verify()")
    if [ "$n" = "0" ]; then
        ok "$1: verify() finds nothing wrong"
    else
        bad "$1: verify() reports $n problem(s)"
        $PSQL -F' | ' -c "SELECT key, problem FROM memkv.verify() LIMIT 5"
    fi
}

# --- 1. exact counters: no lost memkv.incr updates -----------------------------
set_cap 64
$PSQL -c "SELECT memkv.flush()" >/dev/null
mark=$(log_mark)
T=5000
if pgb "memkv.incr" -c "$CLIENTS" -t "$T" -f incr.sql; then
    want=$((CLIENTS * T))
    got=$($PSQL -c "SELECT sum(memkv.get('ctr' || i)::bigint) FROM generate_series(0, 7) i")
    if [ "$got" = "$want" ]; then ok "memkv.incr: $CLIENTS clients x $T = $got, none lost"
    else bad "memkv.incr: counters sum to $got, expected $want"; fi
fi
log_check "$mark" "memkv.incr"
check_verify "memkv.incr"

# --- 2. exact hash counters: no lost optimistic hash updates ----------------
$PSQL -c "SELECT memkv.flush()" >/dev/null
mark=$(log_mark)
if pgb "memkv.hincr" -c "$CLIENTS" -t "$T" -f hincr.sql; then
    want=$((CLIENTS * T))
    got=$($PSQL -c "SELECT sum(value::bigint) FROM memkv.hgetall('hctr')")
    if [ "$got" = "$want" ]; then ok "memkv.hincr: $CLIENTS clients x $T = $got, none lost"
    else bad "memkv.hincr: fields sum to $got, expected $want"; fi
fi
log_check "$mark" "memkv.hincr"
check_verify "memkv.hincr"

# --- 3. unique hash fields: every memkv.hset must land -------------------------
$PSQL -c "SELECT memkv.flush()" >/dev/null
mark=$(log_mark)
HC=16
HT=100
if pgb "memkv.hset" -c "$HC" -t "$HT" -D n=0 -f hset.sql; then
    want=$((HC * HT))
    got=$($PSQL -c "SELECT memkv.hlen('hs')")
    if [ "$got" = "$want" ]; then ok "memkv.hset: $HC clients x $HT = $got distinct fields"
    else bad "memkv.hset: hash has $got fields, expected $want"; fi
fi
log_check "$mark" "memkv.hset"
check_verify "memkv.hset"

# --- 3b. an exact rate limiter: 32 clients race for 1000 slots ---------------
$PSQL -c "SELECT memkv.flush()" >/dev/null
mark=$(log_mark)
if pgb "memkv.rate_limit" -c "$CLIENTS" -t 100 -f limiter.sql; then
    calls=$((CLIENTS * 100))
    got=$($PSQL -c "SELECT memkv.get('stress_allowed')")
    if [ "$got" = "1000" ]; then ok "memkv.rate_limit: $calls calls at a capacity of 1000 let exactly $got through"
    else bad "memkv.rate_limit: $got calls passed, expected exactly 1000 of $calls"; fi
fi
log_check "$mark" "memkv.rate_limit"
check_verify "memkv.rate_limit"

# --- 4. everything at once, with the store full -----------------------------
set_cap 8
$PSQL -c "SELECT memkv.flush()" >/dev/null
mark=$(log_mark)
if pgb "mixed" -c "$CLIENTS" -T "$SECS" -f mixed.sql; then
    tps=$(grep -E '^tps' "$OUT" | head -1)
    ok "mixed: $CLIENTS clients, ${SECS}s, no errors ($tps)"
fi
log_check "$mark" "mixed"
$PSQL -F' ' -c "SELECT 'stats after mixed: keys=' || keys || ' bytes=' || memory_bytes || '/' || max_memory_bytes || ' evicted=' || evicted || ' expired=' || expired || ' hits=' || hits || ' misses=' || misses FROM memkv.stats()"
check_verify "mixed"
# The run only means something if it really exercised eviction and expiry.
read -r evicted expired < <($PSQL -F' ' -c "SELECT evicted, expired FROM memkv.stats()")
if [ "${evicted:-0}" -gt 0 ] && [ "${expired:-0}" -gt 0 ]; then
    ok "mixed: eviction ($evicted keys) and expiry ($expired keys) were both exercised"
else
    bad "mixed: eviction=$evicted expiry=$expired, so a path was never exercised"
fi

# --- 4b. the index is most of the memory ------------------------------------
# One-byte values over millions of keys: what is stored is mostly index, and it
# has to grow and evict inside the cap without ever failing.
$PSQL -c "SELECT memkv.flush()" >/dev/null
mark=$(log_mark)
if pgb "tiny keys" -c "$CLIENTS" -T 10 -f tiny.sql; then
    ok "tiny keys: $CLIENTS clients, 10s of 1-byte values over 5 million keys, no errors"
fi
log_check "$mark" "tiny keys"
$PSQL -F' ' -c "SELECT 'stats after tiny keys: keys=' || keys || ' bytes=' || memory_bytes || '/' || max_memory_bytes || ' evicted=' || evicted FROM memkv.stats()"

# The same, but starting from a store full of big values: the index has to grow
# while there is no free memory, by evicting.
fill_capacity >/dev/null
mark=$(log_mark)
if pgb "tiny after big" -c "$CLIENTS" -T 10 -f tiny.sql; then
    ok "tiny after big: the index grew inside a full cap without errors"
fi
log_check "$mark" "tiny after big"
check_verify "tiny keys"

# --- 5. leak check ----------------------------------------------------------
# Run the mixed workload again and again, flush after each run, and count how
# many 1000-byte values fit. The index bucket array only ever grows, and where
# it sits splits the free pages differently from run to run, so the count
# wobbles by a few percent. That is not a leak, so without the allocator dump
# below the check can only catch a loss of a tenth of the store per run.
mark=$(log_mark)
caps=()
for round in 1 2 3; do
    pgb "leak round $round" -c "$CLIENTS" -T 8 -f mixed.sql || break
    caps+=("$(count_capacity)")
done
printf '      keys that fit after each run of the workload and a flush: %s\n' "${caps[*]}"
if [ "${#caps[@]}" -eq 3 ]; then
    if [ "$have_dump" -eq 1 ]; then
        after_live=$(live_objects)
        if [ "$after_live" = "$base_live" ]; then
            ok "leak: after every workload and a flush $after_live objects are allocated, as on a fresh store (the index's own)"
        else
            bad "leak: $after_live objects still allocated after a flush, $base_live on a fresh store"
        fi
    elif [ "${caps[2]}" -ge $((caps[1] * 90 / 100)) ]; then
        ok "leak: capacity is steady (${caps[1]}, then ${caps[2]}); run on an assertion build with MEMKV_TEST_LOG for the exact check"
    else
        bad "leak: capacity fell from ${caps[1]} to ${caps[2]} between identical runs"
    fi
fi
left=$($PSQL -c "SELECT memkv.flush()" -c "SELECT keys FROM memkv.stats()" | tail -1)
[ "$left" = "0" ] || bad "leak: $left keys left after memkv.flush()"
log_check "$mark" "leak"

$PSQL -c "SELECT memkv.flush()" >/dev/null
[ "$have_dump" -eq 1 ] && $PSQL -c "DROP FUNCTION IF EXISTS kv_debug_dsa()" >/dev/null
$PSQL -c "ALTER SYSTEM RESET memkv.max_memory" -c "SELECT pg_reload_conf()" >/dev/null

echo
if [ "$fails" -eq 0 ]; then echo "stress test: all checks passed"; exit 0; fi
echo "stress test: $fails check(s) FAILED"
exit 1

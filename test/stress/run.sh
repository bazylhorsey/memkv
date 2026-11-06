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

fill_capacity() {   # flush, then count the 1000-byte values that fit at the current cap
    $PSQL -c "SELECT kv_flush()" >/dev/null
    $PSQL <<'SQL'
DO $$ BEGIN
  FOR i IN 1..30000 LOOP PERFORM kv_set('cap' || i, repeat('x', 1000)); END LOOP;
END $$;
SELECT keys FROM kv_stats();
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
    $PSQL -c "SELECT kv_flush()" >/dev/null
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

# --- 1. exact counters: no lost kv_incr updates -----------------------------
set_cap 64
$PSQL -c "SELECT kv_flush()" >/dev/null
mark=$(log_mark)
T=5000
if pgb "kv_incr" -c "$CLIENTS" -t "$T" -f incr.sql; then
    want=$((CLIENTS * T))
    got=$($PSQL -c "SELECT sum(kv_get('ctr' || i)::bigint) FROM generate_series(0, 7) i")
    if [ "$got" = "$want" ]; then ok "kv_incr: $CLIENTS clients x $T = $got, none lost"
    else bad "kv_incr: counters sum to $got, expected $want"; fi
fi
log_check "$mark" "kv_incr"

# --- 2. exact hash counters: no lost optimistic hash updates ----------------
$PSQL -c "SELECT kv_flush()" >/dev/null
mark=$(log_mark)
if pgb "kv_hincr" -c "$CLIENTS" -t "$T" -f hincr.sql; then
    want=$((CLIENTS * T))
    got=$($PSQL -c "SELECT sum(value::bigint) FROM kv_hgetall('hctr')")
    if [ "$got" = "$want" ]; then ok "kv_hincr: $CLIENTS clients x $T = $got, none lost"
    else bad "kv_hincr: fields sum to $got, expected $want"; fi
fi
log_check "$mark" "kv_hincr"

# --- 3. unique hash fields: every kv_hset must land -------------------------
$PSQL -c "SELECT kv_flush()" >/dev/null
mark=$(log_mark)
HC=16
HT=100
if pgb "kv_hset" -c "$HC" -t "$HT" -D n=0 -f hset.sql; then
    want=$((HC * HT))
    got=$($PSQL -c "SELECT kv_hlen('hs')")
    if [ "$got" = "$want" ]; then ok "kv_hset: $HC clients x $HT = $got distinct fields"
    else bad "kv_hset: hash has $got fields, expected $want"; fi
fi
log_check "$mark" "kv_hset"

# --- 4. everything at once, with the store full -----------------------------
set_cap 8
$PSQL -c "SELECT kv_flush()" >/dev/null
mark=$(log_mark)
if pgb "mixed" -c "$CLIENTS" -T "$SECS" -f mixed.sql; then
    tps=$(grep -E '^tps' "$OUT" | head -1)
    ok "mixed: $CLIENTS clients, ${SECS}s, no errors ($tps)"
fi
log_check "$mark" "mixed"
$PSQL -F' ' -c "SELECT 'stats after mixed: keys=' || keys || ' bytes=' || memory_bytes || '/' || max_memory_bytes || ' evicted=' || evicted || ' expired=' || expired || ' hits=' || hits || ' misses=' || misses FROM kv_stats()"
# The run only means something if it really exercised eviction and expiry.
read -r evicted expired < <($PSQL -F' ' -c "SELECT evicted, expired FROM kv_stats()")
if [ "${evicted:-0}" -gt 0 ] && [ "${expired:-0}" -gt 0 ]; then
    ok "mixed: eviction ($evicted keys) and expiry ($expired keys) were both exercised"
else
    bad "mixed: eviction=$evicted expiry=$expired, so a path was never exercised"
fi

# --- 5. leak check ----------------------------------------------------------
# Run the mixed workload again and again, flush after each run, and count how
# many 1000-byte values fit. The index bucket array only ever grows, and where
# it sits splits the free pages differently from run to run, so the count
# wobbles by a few percent. That is not a leak, so it can't be the check by
# itself; the allocator dump below is.
mark=$(log_mark)
caps=()
for round in 1 2 3; do
    pgb "leak round $round" -c "$CLIENTS" -T 8 -f mixed.sql || break
    caps+=("$(fill_capacity)")
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
    elif [ "${caps[2]}" -ge $((caps[1] * 95 / 100)) ]; then
        ok "leak: capacity is steady (${caps[1]}, then ${caps[2]}); run on an assertion build with MEMKV_TEST_LOG for the exact check"
    else
        bad "leak: capacity fell from ${caps[1]} to ${caps[2]} between identical runs"
    fi
fi
left=$($PSQL -c "SELECT kv_flush()" -c "SELECT keys FROM kv_stats()" | tail -1)
[ "$left" = "0" ] || bad "leak: $left keys left after kv_flush()"
log_check "$mark" "leak"

$PSQL -c "SELECT kv_flush()" >/dev/null
[ "$have_dump" -eq 1 ] && $PSQL -c "DROP FUNCTION IF EXISTS kv_debug_dsa()" >/dev/null
$PSQL -c "ALTER SYSTEM RESET memkv.max_memory" -c "SELECT pg_reload_conf()" >/dev/null

echo
if [ "$fails" -eq 0 ]; then echo "stress test: all checks passed"; exit 0; fi
echo "stress test: $fails check(s) FAILED"
exit 1

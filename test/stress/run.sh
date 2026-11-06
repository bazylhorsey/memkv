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

# Baseline for the leak check at the end, taken before any workload runs.
set_cap 8
base=$(fill_capacity)
printf '      baseline: %s 1000-byte values fit in an 8MB store\n' "$base"

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

# --- 5. leak check: after all of that, a flush must give the whole cap back --
# A leaked allocation pins its superblock, so the number of 1000-byte values
# that fit after kv_flush() would drop below the baseline taken at the start.
mark=$(log_mark)
caps=()
for cycle in 1 2 3; do
    caps+=("$(fill_capacity)")
done
printf '      keys that fit: baseline %s, after the workloads %s\n' "$base" "${caps[*]}"
leaked=0
for v in "${caps[@]}"; do
    [ "$v" -lt $((base * 99 / 100)) ] && leaked=1
done
if [ "$leaked" -eq 0 ]; then
    ok "leak: the store holds its baseline $base keys again after every workload and a flush"
else
    bad "leak: capacity after kv_flush() fell below the baseline of $base keys (${caps[*]})"
fi
left=$($PSQL -c "SELECT kv_flush()" -c "SELECT keys FROM kv_stats()" | tail -1)
[ "$left" = "0" ] || bad "leak: $left keys left after kv_flush()"
log_check "$mark" "leak"

$PSQL -c "SELECT kv_flush()" >/dev/null
$PSQL -c "ALTER SYSTEM RESET memkv.max_memory" -c "SELECT pg_reload_conf()" >/dev/null

echo
if [ "$fails" -eq 0 ]; then echo "stress test: all checks passed"; exit 0; fi
echo "stress test: $fails check(s) FAILED"
exit 1

#!/bin/bash
# memkv vs an UNLOGGED table, measured with pgbench.
#
# Every workload runs the same single operation per transaction, over 100,000
# keys with 100-byte values, through prepared statements on a unix socket:
#
#   get       memkv: SELECT kv_get(key)     table: SELECT v FROM t WHERE k = key
#   incr      memkv: SELECT kv_incr(key)    table: INSERT .. ON CONFLICT DO UPDATE n = n + 1
#   incr_hot  same as incr, but only 16 distinct keys (lock contention)
#   set       memkv: SELECT kv_set(key, v)  table: INSERT .. ON CONFLICT DO UPDATE v = excluded.v
#   mget100   memkv: kv_mget(100 keys)      table: SELECT .. WHERE k = ANY (100 keys)
#             (one statement does 100 lookups, so the fixed cost per query is shared)
#
# Table writes are run with synchronous_commit on and off, because the commit
# record flush is most of their cost; kv_* never writes WAL. Reads are
# unaffected by it.
#
# Run it against a SCRATCH server. Connection settings come from PG*.
#
#   bench/run.sh [seconds-per-run] [client-counts]      e.g. bench/run.sh 15 "1 16 64"
#
# Output is a TSV on stdout: workload, system, clients, tps, p50_us, p99_us.
set -u

SECS=${1:-15}
CLIENTS=${2:-"1 16 64"}
WARM=${WARM:-3}
KEYS=100000
PSQL="psql -X -Atq -v ON_ERROR_STOP=1"
DIR=$(mktemp -d)
trap 'rm -rf "$DIR"' EXIT
VAL=$(printf 'x%.0s' $(seq 1 100))

# --- scripts ----------------------------------------------------------------
w() { cat > "$DIR/$1.sql"; }   # w name <<'EOF' ... EOF
w get_kv      <<'EOF'
\set k random(1, 100000)
SELECT kv_get('k' || :k::text);
EOF
w get_tbl     <<'EOF'
\set k random(1, 100000)
SELECT v FROM bench_kv WHERE k = 'k' || :k::text;
EOF
w incr_kv     <<'EOF'
\set k random(1, 100000)
SELECT kv_incr('c' || :k::text);
EOF
w incr_tbl    <<'EOF'
\set k random(1, 100000)
INSERT INTO bench_ctr AS t (k, n) VALUES ('c' || :k::text, 1)
ON CONFLICT (k) DO UPDATE SET n = t.n + 1 RETURNING n;
EOF
w incr_hot_kv <<'EOF'
\set k random(1, 16)
SELECT kv_incr('c' || :k::text);
EOF
w incr_hot_tbl <<'EOF'
\set k random(1, 16)
INSERT INTO bench_ctr AS t (k, n) VALUES ('c' || :k::text, 1)
ON CONFLICT (k) DO UPDATE SET n = t.n + 1 RETURNING n;
EOF
# 100 random keys per statement, so the fixed cost of a query is shared by 100 lookups.
w mget_kv     <<'EOF'
SELECT cardinality(kv_mget(ARRAY(SELECT 'k' || (1 + floor(random() * 100000))::int FROM generate_series(1, 100))));
EOF
w mget_tbl    <<'EOF'
SELECT count(v) FROM bench_kv WHERE k = ANY (ARRAY(SELECT 'k' || (1 + floor(random() * 100000))::int FROM generate_series(1, 100)));
EOF
w set_kv      <<'EOF'
\set k random(1, 100000)
SELECT kv_set('k' || :k::text, :v);
EOF
w set_tbl     <<'EOF'
\set k random(1, 100000)
INSERT INTO bench_kv (k, v) VALUES ('k' || :k::text, :v)
ON CONFLICT (k) DO UPDATE SET v = EXCLUDED.v;
EOF

# --- setup ------------------------------------------------------------------
setup() {
    $PSQL <<SQL
CREATE EXTENSION IF NOT EXISTS memkv;
DROP TABLE IF EXISTS bench_kv, bench_ctr;
CREATE UNLOGGED TABLE bench_kv  (k text PRIMARY KEY, v text   NOT NULL);
CREATE UNLOGGED TABLE bench_ctr (k text PRIMARY KEY, n bigint NOT NULL);
INSERT INTO bench_kv  SELECT 'k' || i, '$VAL' FROM generate_series(1, $KEYS) i;
INSERT INTO bench_ctr SELECT 'c' || i, 0      FROM generate_series(1, $KEYS) i;
VACUUM (ANALYZE) bench_kv, bench_ctr;
SELECT kv_flush() \gset
SELECT count(kv_set('k' || i, '$VAL')) FROM generate_series(1, $KEYS) i \gset
SELECT count(kv_set('c' || i, '0'))    FROM generate_series(1, $KEYS) i \gset
SQL
}

# --- one run ----------------------------------------------------------------
# run_one workload system script sync clients
run_one() {
    local wl=$1 sys=$2 script=$3 sync=$4 c=$5 j
    j=$c; [ "$j" -gt 8 ] && j=8
    export PGOPTIONS="-c synchronous_commit=$sync"
    # warm up, unmeasured
    pgbench -n -M prepared -D v="$VAL" -c "$c" -j "$j" -T "$WARM" -f "$DIR/$script.sql" >/dev/null 2>&1
    rm -f "$DIR"/log.*
    local out
    out=$(pgbench -n -M prepared -D v="$VAL" -c "$c" -j "$j" -T "$SECS" \
            -l --sampling-rate=0.1 --log-prefix="$DIR/log" \
            -f "$DIR/$script.sql" 2>&1)
    local tps
    tps=$(printf '%s\n' "$out" | awk '/^tps/ {printf "%.0f", $3}')
    if [ -z "$tps" ] || printf '%s\n' "$out" | grep -q -i -E 'aborted|error'; then
        echo "benchmark failed: $wl $sys c=$c" >&2; printf '%s\n' "$out" | tail -5 >&2
        printf '%s\t%s\t%s\tFAILED\t-\t-\n' "$wl" "$sys" "$c"; return
    fi
    # column 3 of the pgbench log is the latency in microseconds
    local pct
    pct=$(cat "$DIR"/log.* | awk '{print $3}' | sort -n | awk '
        { a[NR] = $1 }
        END { printf "%d\t%d", a[int(NR * 0.50) + 1], a[int(NR * 0.99) + 1] }')
    printf '%s\t%s\t%s\t%s\t%s\n' "$wl" "$sys" "$c" "$tps" "$pct"
    unset PGOPTIONS
}

setup || { echo "setup failed" >&2; exit 1; }
printf 'workload\tsystem\tclients\ttps\tp50_us\tp99_us\n'
for c in $CLIENTS; do
    run_one get      memkv           get_kv       on  "$c"
    run_one get      table           get_tbl      on  "$c"
    run_one mget100  memkv           mget_kv      on  "$c"
    run_one mget100  table           mget_tbl     on  "$c"
    for wl in incr incr_hot set; do
        run_one "$wl" memkv          "${wl}_kv"   on  "$c"
        run_one "$wl" table_sync     "${wl}_tbl"  on  "$c"
        run_one "$wl" table_async    "${wl}_tbl"  off "$c"
    done
done

# --- what the table left behind ---------------------------------------------
$PSQL -F' ' <<'SQL' | sed 's/^/# /'
SELECT 'table bloat: ' || relname || ' live=' || n_live_tup || ' dead=' || n_dead_tup ||
       ' size=' || pg_size_pretty(pg_total_relation_size(relid))
FROM pg_stat_user_tables WHERE relname IN ('bench_kv', 'bench_ctr') ORDER BY relname;
SELECT 'memkv store: keys=' || keys || ' memory=' || pg_size_pretty(memory_bytes) FROM kv_stats();
SQL

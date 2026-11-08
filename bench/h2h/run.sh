#!/bin/bash
# Head to head: memkv against pg_kv, with an UNLOGGED table on each server as a
# yardstick. Everything runs in Docker on one host, the way pg_kv's own bench
# does it: each server limited to SERVER_CPUS, pgbench in a separate container
# limited to CLIENT_CPUS, over the Docker network, prepared statements, 100,000
# keys with 64-byte values. The shapes are get, set, incr, and a batch of 100
# gets in one statement (pg_kv has no batch call, so every side runs the same
# SQL; memkv's own mget is measured as well).
#
#   bench/h2h/run.sh
#   SECS=15 ROUNDS=3 CLIENTS="1 16 64" bench/h2h/run.sh
#
# Images (override with the variables):
#   MEMKV_IMAGE  default memkv:19rc1  -- `docker build -t memkv:19rc1 .`
#   PGKV_IMAGE   default pg_kv:18-arm64
#
# pg_kv's published image is linux/amd64 only. On an arm64 machine it would run
# under emulation, and that makes pg_kv look several times slower than it is, so
# build it natively from its own Dockerfile:
#   git clone https://github.com/Murat7Ay/pg_kv && cd pg_kv && git checkout 2941f47
#   docker build --build-arg PG_MAJOR=18 -t pg_kv:18-arm64 .
#
# MEMKV_FN is the prefix of memkv's SQL functions: "kv_" or "memkv." by version.
#
# The servers differ in PostgreSQL major (pg_kv supports 15-18, memkv needs 19),
# so the UNLOGGED tables run on both, to show how much of a gap is the server.
# Results go to a TSV (OUT) and a summary is printed at the end.
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
MEMKV_IMAGE=${MEMKV_IMAGE:-memkv:19rc1}
PGKV_IMAGE=${PGKV_IMAGE:-pg_kv:18-arm64}
FN=${MEMKV_FN:-memkv.}
SECS=${SECS:-10}
WARM=${WARM:-2}
ROUNDS=${ROUNDS:-1}
CLIENTS=${CLIENTS:-"1 16 64"}
SERVER_CPUS=${SERVER_CPUS:-4}
CLIENT_CPUS=${CLIENT_CPUS:-3}
OUT=${OUT:-$HERE/h2h-$(date +%Y%m%d-%H%M%S).tsv}
NET=h2h-net
VAL=$(printf 'v%.0s' $(seq 1 64))
SCRIPTS=$(mktemp -d)

cleanup() { docker rm -f h2h-memkv h2h-pgkv h2h-client >/dev/null 2>&1; rm -rf "$SCRIPTS"; }
trap cleanup EXIT

# --- pgbench scripts -----------------------------------------------------------
w() { cat > "$SCRIPTS/$1.sql"; }
w memkv_get  <<EOF
\\set k random(1, 100000)
SELECT ${FN}get('key:' || :k);
EOF
w memkv_set  <<EOF
\\set k random(1, 100000)
SELECT ${FN}set('key:' || :k, '$VAL');
EOF
w memkv_incr <<EOF
\\set k random(1, 100000)
SELECT ${FN}incr('ctr:' || :k);
EOF
w pgkv_get   <<EOF
\\set k random(1, 100000)
SELECT kv.get('key:' || :k);
EOF
w pgkv_set   <<EOF
\\set k random(1, 100000)
SELECT kv.set('key:' || :k, '$VAL');
EOF
w pgkv_incr  <<EOF
\\set k random(1, 100000)
SELECT kv.incr('ctr:' || :k);
EOF
# a hundred random keys in one statement, the same shape on every side
w memkv_batch <<EOF
SELECT count(${FN}get('key:' || (1 + floor(random() * 100000))::int)) FROM generate_series(1, 100);
EOF
w pgkv_batch <<EOF
SELECT count(kv.get('key:' || (1 + floor(random() * 100000))::int)) FROM generate_series(1, 100);
EOF
w memkv_mget <<EOF
SELECT cardinality(${FN}mget(ARRAY(SELECT 'key:' || (1 + floor(random() * 100000))::int FROM generate_series(1, 100))));
EOF
w unlogged_batch <<EOF
SELECT count(v) FROM cache_unlogged
 WHERE k = ANY (ARRAY(SELECT 'key:' || (1 + floor(random() * 100000))::int FROM generate_series(1, 100)));
EOF
# the table side, as pg_kv's bench writes it; get_ttl is its get, with the TTL check
w unlogged_get <<EOF
\\set k random(1, 100000)
SELECT v FROM cache_unlogged WHERE k = 'key:' || :k;
EOF
w unlogged_get_ttl <<EOF
\\set k random(1, 100000)
SELECT v FROM cache_unlogged WHERE k = 'key:' || :k AND (expires_at IS NULL OR expires_at > now());
EOF
w unlogged_set <<EOF
\\set k random(1, 100000)
INSERT INTO cache_unlogged (k, v) VALUES ('key:' || :k, '$VAL')
  ON CONFLICT (k) DO UPDATE SET v = EXCLUDED.v, expires_at = NULL;
EOF
w unlogged_incr <<EOF
\\set k random(1, 100000)
INSERT INTO counters_unlogged (k, n) VALUES ('ctr:' || :k, 1)
  ON CONFLICT (k) DO UPDATE SET n = counters_unlogged.n + 1 RETURNING n;
EOF

TABLES="CREATE UNLOGGED TABLE cache_unlogged (k text PRIMARY KEY, v text NOT NULL, expires_at timestamptz);
CREATE UNLOGGED TABLE counters_unlogged (k text PRIMARY KEY, n bigint NOT NULL);
INSERT INTO cache_unlogged (k, v) SELECT 'key:' || i, '$VAL' FROM generate_series(1, 100000) i;
INSERT INTO counters_unlogged SELECT 'ctr:' || i, 0 FROM generate_series(1, 100000) i;
VACUUM ANALYZE cache_unlogged, counters_unlogged;"

# --- start everything -----------------------------------------------------------
cleanup_old() { docker rm -f h2h-memkv h2h-pgkv h2h-client >/dev/null 2>&1; }
cleanup_old
docker network inspect $NET >/dev/null 2>&1 || docker network create $NET >/dev/null
docker run -d --name h2h-memkv --network $NET --cpus="$SERVER_CPUS" --shm-size=1g \
    -e POSTGRES_PASSWORD=postgres "$MEMKV_IMAGE" postgres \
    -c shared_buffers=1GB -c max_connections=200 -c memkv.max_memory=512MB >/dev/null || exit 1
docker run -d --name h2h-pgkv --network $NET --cpus="$SERVER_CPUS" --shm-size=1g \
    -e POSTGRES_PASSWORD=postgres "$PGKV_IMAGE" postgres \
    -c shared_preload_libraries=pg_kv -c pg_kv.max_entries=400000 -c pg_kv.max_value_bytes=256 \
    -c shared_buffers=1GB -c max_connections=200 >/dev/null || exit 1
docker run -d --name h2h-client --network $NET --cpus="$CLIENT_CPUS" -e PGPASSWORD=postgres \
    -v "$SCRIPTS":/bench:ro --entrypoint sleep "$MEMKV_IMAGE" infinity >/dev/null || exit 1

for h in h2h-memkv h2h-pgkv; do
    for i in $(seq 1 60); do
        docker exec h2h-client pg_isready -h $h -U postgres -q 2>/dev/null && break
        sleep 1
    done
done

psql_in() { docker exec -i h2h-client psql -h "$1" -U postgres -X -q -v ON_ERROR_STOP=1 postgres; }
psql_c()  { docker exec h2h-client psql -h "$1" -U postgres -X -Atq postgres -c "$2"; }

psql_in h2h-memkv <<SQL || { echo "memkv setup failed" >&2; exit 1; }
CREATE EXTENSION memkv;
SELECT count(${FN}set('key:' || i, '$VAL')) FROM generate_series(1, 100000) i \\gset
$TABLES
SQL
psql_in h2h-pgkv <<SQL || { echo "pg_kv setup failed" >&2; exit 1; }
CREATE EXTENSION pg_kv;
SELECT count(kv.set('key:' || i, '$VAL')) FROM generate_series(1, 100000) i \\gset
$TABLES
SQL
{
    echo "# memkv server: $(psql_c h2h-memkv 'SHOW server_version')   pg_kv server: $(psql_c h2h-pgkv 'SHOW server_version')"
    echo "# servers ${SERVER_CPUS} CPUs, client ${CLIENT_CPUS} CPUs, ${SECS}s per cell, ${ROUNDS} round(s)"
} >&2

# --- one cell -------------------------------------------------------------------
# cell round system host script op clients
cell() {
    local round=$1 sys=$2 host=$3 script=$4 op=$5 c=$6 j out tps lat p99
    j=$c; [ "$j" -gt 3 ] && j=3
    docker exec h2h-client sh -c 'rm -f /tmp/pgb.*'
    docker exec h2h-client pgbench -n -M prepared -c "$c" -j "$j" -T "$WARM" -h "$host" -U postgres \
        -f "/bench/$script.sql" postgres >/dev/null 2>&1
    out=$(docker exec h2h-client pgbench -n -M prepared -c "$c" -j "$j" -T "$SECS" \
            -l --sampling-rate=0.1 --log-prefix=/tmp/pgb -h "$host" -U postgres \
            -f "/bench/$script.sql" postgres 2>&1)
    tps=$(printf '%s\n' "$out" | awk '/^tps/ {printf "%.0f", $3}')
    lat=$(printf '%s\n' "$out" | awk '/^latency average/ {print $4}')
    if [ -z "$tps" ] || printf '%s\n' "$out" | grep -q -i -E 'aborted|error'; then
        echo "FAILED: $sys $op c=$c" >&2; printf '%s\n' "$out" | tail -3 >&2
        printf '%s\t%s\t%s\t%s\tFAILED\t-\t-\n' "$round" "$sys" "$op" "$c" >> "$OUT"; return
    fi
    p99=$(docker exec h2h-client sh -c "cat /tmp/pgb.* | awk '{print \$3}' | sort -n | awk '{a[NR]=\$1} END {print a[int(NR*0.99)+1]}'")
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$round" "$sys" "$op" "$c" "$tps" "$lat" "$p99" >> "$OUT"
}

printf 'round\tsystem\top\tclients\ttps\tavg_ms\tp99_us\n' > "$OUT"
for round in $(seq 1 "$ROUNDS"); do
    for c in $CLIENTS; do
        for op in get set incr batch; do
            cell "$round" memkv       h2h-memkv "memkv_$op"    "$op" "$c"
            cell "$round" pg_kv       h2h-pgkv  "pgkv_$op"     "$op" "$c"
            cell "$round" unlogged_19 h2h-memkv "unlogged_$op" "$op" "$c"
            cell "$round" unlogged_18 h2h-pgkv  "unlogged_$op" "$op" "$c"
        done
        cell "$round" memkv       h2h-memkv memkv_mget     mget "$c"
        cell "$round" unlogged_19 h2h-memkv unlogged_get_ttl get_ttl "$c"
        cell "$round" unlogged_18 h2h-pgkv  unlogged_get_ttl get_ttl "$c"
    done
    echo "round $round done" >&2
done

# --- what each side holds afterwards ----------------------------------------------
{
    echo "# memkv:  $(psql_c h2h-memkv "SELECT 'keys=' || keys || ' memory=' || pg_size_pretty(memory_bytes) FROM ${FN}stats()")"
    echo "# pg_kv:  $(psql_c h2h-pgkv  "SELECT 'entries=' || entries || ' shmem=' || pg_size_pretty(shmem_bytes) FROM kv.stats()")"
    for h in h2h-memkv h2h-pgkv; do
        echo "# $h unlogged: $(psql_c $h "SELECT string_agg(relname || ' live=' || n_live_tup || ' dead=' || n_dead_tup, ', ') FROM pg_stat_user_tables WHERE relname LIKE '%unlogged'")"
    done
} >&2

python3 "$HERE/summarize.py" "$OUT"

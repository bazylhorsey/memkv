#!/bin/bash
# Three things bench/h2h/run.sh doesn't show, memkv against pg_kv in Docker:
#
#   rate     rate limiting, 10,000 limiters, 16 and 64 clients
#   values   which value sizes each accepts
#   evict    a keyspace ten times what each holds, so most writes evict
#
#   bench/h2h/scenarios.sh                 all three
#   bench/h2h/scenarios.sh evict           one of them
#
# Same images and variables as run.sh (MEMKV_IMAGE, PGKV_IMAGE, MEMKV_FN,
# SERVER_CPUS, CLIENT_CPUS, SECS, WARM).
set -u

MEMKV_IMAGE=${MEMKV_IMAGE:-memkv:19rc1}
PGKV_IMAGE=${PGKV_IMAGE:-pg_kv:18-arm64}
FN=${MEMKV_FN:-memkv.}
SECS=${SECS:-10}
WARM=${WARM:-2}
SERVER_CPUS=${SERVER_CPUS:-4}
CLIENT_CPUS=${CLIENT_CPUS:-3}
WHICH=${1:-all}
NET=h2h-net
SCRIPTS=$(mktemp -d)

cleanup() { docker rm -f h2h-memkv h2h-pgkv h2h-client >/dev/null 2>&1; rm -rf "$SCRIPTS"; }
trap cleanup EXIT

docker network inspect $NET >/dev/null 2>&1 || docker network create $NET >/dev/null
w() { cat > "$SCRIPTS/$1.sql"; }
psql_c() { docker exec h2h-client psql -h "$1" -U postgres -X -Atq postgres -c "$2" 2>&1; }

# up MEMKV_ARGS PGKV_ARGS: fresh servers with extra postgres arguments, and a client
up() {
    docker rm -f h2h-memkv h2h-pgkv h2h-client >/dev/null 2>&1
    docker run -d --name h2h-memkv --network $NET --cpus="$SERVER_CPUS" --shm-size=1g \
        -e POSTGRES_PASSWORD=postgres "$MEMKV_IMAGE" postgres \
        -c shared_buffers=1GB -c max_connections=200 $1 >/dev/null || exit 1
    docker run -d --name h2h-pgkv --network $NET --cpus="$SERVER_CPUS" --shm-size=1g \
        -e POSTGRES_PASSWORD=postgres "$PGKV_IMAGE" postgres \
        -c shared_preload_libraries=pg_kv -c shared_buffers=1GB -c max_connections=200 $2 >/dev/null || exit 1
    docker run -d --name h2h-client --network $NET --cpus="$CLIENT_CPUS" -e PGPASSWORD=postgres \
        -v "$SCRIPTS":/bench:ro --entrypoint sleep "$MEMKV_IMAGE" infinity >/dev/null || exit 1
    for h in h2h-memkv h2h-pgkv; do
        for _ in $(seq 1 60); do docker exec h2h-client pg_isready -h $h -U postgres -q 2>/dev/null && break; sleep 1; done
    done
    psql_c h2h-memkv "CREATE EXTENSION memkv" >/dev/null
    psql_c h2h-pgkv "CREATE EXTENSION pg_kv" >/dev/null
}

# run_pgbench host script clients seconds -> "tps p50 p99 p999 max" (latencies in us)
run_pgbench() {
    local host=$1 script=$2 c=$3 secs=$4 j out tps
    j=$c; [ "$j" -gt 3 ] && j=3
    docker exec h2h-client sh -c 'rm -f /tmp/pgb.*'
    out=$(docker exec h2h-client pgbench -n -M prepared -c "$c" -j "$j" -T "$secs" -l --sampling-rate=0.2 \
            --log-prefix=/tmp/pgb -h "$host" -U postgres -f "/bench/$script.sql" postgres 2>&1)
    tps=$(printf '%s\n' "$out" | awk '/^tps/ {printf "%.0f", $3}')
    if [ -z "$tps" ] || printf '%s\n' "$out" | grep -q -i -E 'aborted|error'; then
        printf 'FAILED %s\n' "$(printf '%s\n' "$out" | grep -i -m1 -E 'error|aborted' | cut -c1-80)"; return
    fi
    printf '%s ' "$tps"
    docker exec h2h-client sh -c "cat /tmp/pgb.* | awk '{print \$3}' | sort -n | awk '{a[NR]=\$1} END {printf \"%d %d %d %d\", a[int(NR*0.50)+1], a[int(NR*0.99)+1], a[int(NR*0.999)+1], a[NR]}'"
    echo
}

# --- rate limiting ------------------------------------------------------------------
scenario_rate() {
    echo "== rate limiting: 10,000 limiters, capacity 100 per minute =="
    w rl_memkv <<EOF
\\set k random(1, 10000)
SELECT ${FN}rate_limit('api:' || :k, 100, interval '1 minute');
EOF
    w rl_pgkv <<EOF
\\set k random(1, 10000)
SELECT kv.rate_limit('api:' || :k, 100, interval '1 minute');
EOF
    up "-c memkv.max_memory=256MB" "-c pg_kv.max_entries=400000"
    printf '%-8s %7s %9s %8s %8s\n' system clients ops/s p50_us p99_us
    for c in 16 64; do
        for sys in memkv pg_kv; do
            [ $sys = memkv ] && host=h2h-memkv || host=h2h-pgkv
            docker exec h2h-client pgbench -n -M prepared -c "$c" -j 3 -T "$WARM" -h $host -U postgres -f /bench/rl_${sys/pg_kv/pgkv}.sql postgres >/dev/null 2>&1
            read -r tps p50 p99 rest <<<"$(run_pgbench $host rl_${sys/pg_kv/pgkv} "$c" "$SECS")"
            printf '%-8s %7s %9s %8s %8s\n' $sys "$c" "$tps" "$p50" "$p99"
        done
    done
    echo "(memkv: ${FN}rate_limit, an in-place GCRA update; pg_kv: kv.rate_limit, a token bucket)"
}

# --- value sizes --------------------------------------------------------------------
scenario_values() {
    echo "== which values each accepts (pg_kv with the max_value_bytes=256 its own bench uses) =="
    up "" "-c pg_kv.max_entries=100000 -c pg_kv.max_value_bytes=256"
    printf '%-12s %-24s %-24s\n' "value bytes" memkv pg_kv
    for n in 100 256 300 1000 10000 1000000; do
        m=$(psql_c h2h-memkv "SELECT ${FN}set('v$n', repeat('x', $n))" | head -1 | cut -c1-40)
        p=$(psql_c h2h-pgkv "SELECT kv.set('v$n', repeat('x', $n))" | head -1 | cut -c1-40)
        [ "$m" = "t" ] && m=ok; [ -z "$p" ] && p=ok
        printf '%-12s %-24s %-24s\n' "$n" "$m" "$p"
    done
    echo "key bytes:"
    for n in 100 128 129 1000; do
        m=$(psql_c h2h-memkv "SELECT ${FN}set(repeat('k', $n), 'v')" | head -1 | cut -c1-40)
        p=$(psql_c h2h-pgkv "SELECT kv.set(repeat('k', $n), 'v')" | head -1 | cut -c1-40)
        [ "$m" = "t" ] && m=ok; [ -z "$p" ] && p=ok
        printf '%-12s %-24s %-24s\n' "$n" "$m" "$p"
    done
}

# --- eviction at scale --------------------------------------------------------------
scenario_evict() {
    local val; val=$(printf 'v%.0s' $(seq 1 64))
    echo "== a full store: 10,000,000 random keys, each side sized for about 1,000,000, 16 clients =="
    w ev_memkv <<EOF
\\set k random(1, 10000000)
SELECT ${FN}set('k' || :k, '$val');
EOF
    w ev_pgkv <<EOF
\\set k random(1, 10000000)
SELECT kv.set('k' || :k, '$val');
EOF
    up "-c memkv.max_memory=192MB" "-c pg_kv.max_entries=1000000 -c pg_kv.max_key_bytes=32 -c pg_kv.max_value_bytes=64"
    printf '%-8s %9s %8s %8s %9s %9s   %s\n' system ops/s p50_us p99_us p99.9_us max_us "held / evicted"
    for sys in memkv pg_kv; do
        [ $sys = memkv ] && host=h2h-memkv || host=h2h-pgkv
        s=${sys/pg_kv/pgkv}
        # fill it first, so the measured run starts with every write evicting
        docker exec h2h-client pgbench -n -M prepared -c 16 -j 3 -T $((SECS * 2)) -h $host -U postgres -f /bench/ev_$s.sql postgres >/dev/null 2>&1
        read -r tps p50 p99 p999 max <<<"$(run_pgbench $host ev_$s 16 $((SECS * 2)))"
        if [ $sys = memkv ]; then
            st=$(psql_c $host "SELECT keys || ' keys / ' || evicted || ' evicted, ' || pg_size_pretty(memory_bytes) FROM ${FN}stats()")
        else
            st=$(psql_c $host "SELECT entries || ' entries / ' || evictions || ' evicted, ' || pg_size_pretty(shmem_bytes) FROM kv.stats()")
        fi
        printf '%-8s %9s %8s %8s %9s %9s   %s\n' $sys "$tps" "$p50" "$p99" "$p999" "$max" "$st"
    done
}

case "$WHICH" in
    rate)   scenario_rate ;;
    values) scenario_values ;;
    evict)  scenario_evict ;;
    all)    scenario_rate; echo; scenario_values; echo; scenario_evict ;;
    *)      echo "usage: $0 [rate|values|evict|all]" >&2; exit 1 ;;
esac

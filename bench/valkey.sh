#!/bin/bash
# Valkey reference numbers to put next to bench/run.sh.
#
# Starts Valkey in a throwaway Docker container (no persistence) and drives it
# with valkey-benchmark running INSIDE that container, over TCP loopback, one
# request in flight per client, 100-byte values, 100,000 keys. The output
# columns match bench/run.sh.
#
# Caveat: Docker on a Mac runs the container in a Linux VM, so this is not the
# same kernel or CPU scheduler as the native Postgres runs. Treat the ratios as
# rough. For a clean comparison, run both on the same Linux host.
#
#   bench/valkey.sh [seconds-per-run] [client-counts]
set -u

SECS=${1:-15}
CLIENTS=${2:-"1 16 64"}
NAME=memkv-bench-valkey
IMG=${VALKEY_IMAGE:-valkey/valkey:latest}

docker rm -f "$NAME" >/dev/null 2>&1
docker run -d --rm --name "$NAME" "$IMG" \
    valkey-server --save "" --appendonly no --protected-mode no >/dev/null || exit 1
trap 'docker rm -f "$NAME" >/dev/null 2>&1' EXIT
sleep 2
vb() { docker exec "$NAME" valkey-benchmark -h 127.0.0.1 "$@"; }

echo "# $(docker exec "$NAME" valkey-server --version)" >&2
vb -t set -n 300000 -r 100000 -d 100 -q >/dev/null    # populate the key space

printf 'workload\tsystem\tclients\ttps\tp50_us\tp99_us\n'
for c in $CLIENTS; do
    t=$c; [ "$t" -gt 4 ] && t=4
    for test in get incr set; do
        # short calibration run, to size the real one to about $SECS seconds
        rps=$(vb -t "$test" -c "$c" --threads "$t" -n 100000 -d 100 -r 100000 --csv \
                | tail -1 | tr -d '"' | awk -F, '{printf "%d", $2}')
        n=$(awk -v r="$rps" -v s="$SECS" 'BEGIN { printf "%d", r * s }')
        vb -t "$test" -c "$c" --threads "$t" -n "$n" -d 100 -r 100000 --csv \
            | tail -1 | tr -d '"' \
            | awk -F, -v wl="$test" -v c="$c" \
                '{ printf "%s\tvalkey\t%s\t%.0f\t%.0f\t%.0f\n", wl, c, $2, $5 * 1000, $7 * 1000 }'
    done
done

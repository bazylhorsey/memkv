#!/bin/bash
# Run the test suite against the memkv Docker image, the way a user gets it.
#
#   ci/run.sh              build memkv:ci from the Dockerfile, then test it
#   ci/run.sh some:image   test an image you already have
#
# The official PostgreSQL image is not built with assertions, so the tests that
# need them (collision.sql, the damage tests in verify.sql, the exact leak check
# in the stress test) skip themselves here. ci/assert.sh runs those.
set -uo pipefail
cd "$(dirname "$0")/.."

if [ $# -eq 0 ]; then
    IMAGE=memkv:ci
    docker build -t "$IMAGE" . || exit 1
else
    IMAGE=$1
fi

NAME=memkv-ci-$$
trap 'docker rm -f "$NAME" >/dev/null 2>&1' EXIT
docker run -d --name "$NAME" --shm-size=512m -e POSTGRES_PASSWORD=postgres \
    -v "$PWD/test:/test:ro" "$IMAGE" >/dev/null || exit 1
for _ in $(seq 1 60); do
    docker exec "$NAME" pg_isready -U postgres -q 2>/dev/null && break
    sleep 1
done
docker exec "$NAME" pg_isready -U postgres -q || { echo "server did not start" >&2; exit 1; }

psql() { docker exec -e PGUSER=postgres "$NAME" psql -X -v ON_ERROR_STOP=1 "$@"; }
psql -q -c "CREATE EXTENSION memkv" || exit 1

fail=0
for t in commands keys overwrite rate_limit errors access verify collision eviction; do
    if out=$(psql -f "/test/$t.sql" 2>&1 >/dev/null); then
        echo "PASS  test/$t.sql"
    else
        echo "FAIL  test/$t.sql"
        printf '%s\n' "$out" | head -12
        fail=1
    fi
done

docker exec -e PGUSER=postgres "$NAME" bash /test/stress/run.sh 10 16 || fail=1

echo
if [ "$fail" -eq 0 ]; then echo "all tests passed"; else echo "tests FAILED"; fi
exit $fail

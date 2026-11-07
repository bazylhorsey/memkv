#!/bin/bash
# Build memkv against a PostgreSQL 19 built with assertions (--enable-cassert)
# and run every test, including the ones that need assertions: the hash
# collision test, the damage tests in verify.sql, and the stress test's exact
# leak check, which reads the allocator's own dump.
#
#   ci/assert.sh /path/to/the/postgres/install/prefix
#
# It installs memkv into that prefix, starts a throwaway server on a unix
# socket, and removes it afterwards.
set -uo pipefail

PREFIX=${1:?usage: ci/assert.sh /path/to/the/postgres/install/prefix}
export PATH="$PREFIX/bin:$PATH"
SRC=$(cd "$(dirname "$0")/.." && pwd)

BUILD=$(mktemp -d)
DATA=$(mktemp -d)
SOCK=$(mktemp -d /tmp/memkv-ci.XXXXXX)
stop() { pg_ctl -D "$DATA" -m immediate stop >/dev/null 2>&1; rm -rf "$BUILD" "$DATA" "$SOCK"; }
trap stop EXIT

(cd "$BUILD" && make -s -f "$SRC/Makefile" VPATH="$SRC" PG_CONFIG="$PREFIX/bin/pg_config" install) || exit 1

initdb -D "$DATA" -A trust -E UTF8 --no-locale >/dev/null || exit 1
export PGHOST=$SOCK PGPORT=${PGPORT:-54329} PGDATABASE=postgres
pg_ctl -D "$DATA" -l "$DATA/server.log" -w >/dev/null \
    -o "-c port=$PGPORT -c unix_socket_directories=$SOCK -c listen_addresses='' -c max_connections=200" start || exit 1

if [ "$(psql -X -Atq -c 'SHOW debug_assertions')" != "on" ]; then
    echo "this PostgreSQL was not built with --enable-cassert" >&2
    exit 1
fi
psql -X -q -c "CREATE EXTENSION memkv" || exit 1

fail=0
cd "$SRC"
for t in commands keys overwrite rate_limit errors access verify collision eviction; do
    if out=$(psql -X -v ON_ERROR_STOP=1 -f "test/$t.sql" 2>&1 >/dev/null); then
        echo "PASS  test/$t.sql"
    else
        echo "FAIL  test/$t.sql"
        printf '%s\n' "$out" | head -12
        fail=1
    fi
done

# the assertion-only tests must have run, not skipped themselves
for marker in "collision.sql:memkv.test_weak_hash" "verify.sql:kv_debug_corrupt"; do
    f=${marker%%:*}
    if psql -X -v ON_ERROR_STOP=1 -f "test/$f" 2>&1 | grep -q "skipped"; then
        echo "FAIL  test/$f skipped itself on an assertion build"
        fail=1
    fi
done

MEMKV_TEST_LOG="$DATA/server.log" bash test/stress/run.sh 20 32 || fail=1

if grep -q -E 'TRAP:|PANIC|terminated by signal' "$DATA/server.log"; then
    echo "FAIL  the server log has a crash or an assertion failure"
    grep -E 'TRAP:|PANIC|terminated by signal' "$DATA/server.log" | head -5
    fail=1
fi

echo
if [ "$fail" -eq 0 ]; then echo "all tests passed"; else echo "tests FAILED"; fi
exit $fail

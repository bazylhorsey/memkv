#!/bin/sh
# Type-check memkv.c against an older PG's headers via test/compat (no PG 19
# needed). Not a substitute for building against PG 19.
set -e
cd "$(dirname "$0")/.."
tmp=$(mktemp -d)
# PG < 17 has no dshash copy_function field.
grep -v '\.copy_function' memkv.c > "$tmp/memkv.c"
${CC:-gcc} -std=gnu11 -fsyntax-only -Wall -Wextra -Wno-unused-parameter \
  -Wmissing-prototypes -Wdeclaration-after-statement \
  -Itest/compat -I. -I"$(${PG_CONFIG:-pg_config} --includedir-server)" "$tmp/memkv.c"
rm -rf "$tmp"
echo "compile check passed"

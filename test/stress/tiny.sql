-- pgbench script: one-byte values over a huge key space, so the index is most of
-- what is stored and the store stays full. Run through test/stress/run.sh.
\set k random(1, 5000000)
SELECT kv_set('t' || :k::text, 'x');

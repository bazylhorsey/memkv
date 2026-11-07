-- pgbench script: every client adds a field that nobody else adds, to one hash.
-- Needs -D n=0. After the run the hash must hold exactly clients * N fields.
\set n :n + 1
SELECT memkv.hset('hs', 'c' || :client_id::text || '_' || :n::text, 'v');

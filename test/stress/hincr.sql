-- pgbench script: every client increments one of 16 fields of a single hash.
-- Hash writes are optimistic (read, rebuild, retry if the version changed),
-- so this is the lost-update test: the fields must sum to exactly N.
SELECT kv_hincr('hctr', 'f' || (:client_id % 16)::text);

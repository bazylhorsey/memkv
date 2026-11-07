-- Manual eviction test for memkv. Run as a superuser on a scratch server:
--   psql -X -v ON_ERROR_STOP=1 -f test/eviction.sql
-- It shrinks memkv.max_memory to 1MB, so don't run it where the store matters.

CREATE EXTENSION IF NOT EXISTS memkv;
ALTER SYSTEM SET memkv.max_memory = '1MB';
ALTER SYSTEM SET memkv.eviction_policy = 'allkeys-lru';
SELECT pg_reload_conf();
SELECT pg_sleep(0.5);
\c
SELECT kv_flush();

-- 1. A full store evicts instead of erroring, and recently used keys survive.
SELECT kv_set('hot', 'keep me');
DO $$
BEGIN
  FOR i IN 1..5000 LOOP
    PERFORM kv_set('k' || i, repeat('x', 1000));
    IF i % 50 = 0 THEN
      PERFORM kv_get('hot');          -- keep 'hot' recently used
    END IF;
  END LOOP;
END $$;
SELECT kv_get('hot') = 'keep me'                    AS hot_survived;   -- t
SELECT kv_get('k1') IS NULL                         AS oldest_evicted; -- t
SELECT kv_get('k5000') IS NOT NULL                  AS newest_kept;    -- t
SELECT count(*) FILTER (WHERE kv_get('k' || i) IS NOT NULL) AS live_keys
FROM generate_series(1, 5000) i;                                       -- roughly 500-700 (the cap covers the index too)

-- 2. Expired keys are dropped before any live key is evicted.
SELECT kv_flush();
SELECT kv_set('live' || i, repeat('y', 1000)) FROM generate_series(1, 300) i;
SELECT kv_set('ttl'  || i, repeat('z', 1000), '1 second') FROM generate_series(1, 300) i;
SELECT pg_sleep(1.5);
SELECT kv_set('new' || i, repeat('n', 1000)) FROM generate_series(1, 300) i;
SELECT count(*) FILTER (WHERE kv_get('live' || i) IS NOT NULL) AS live_kept
FROM generate_series(1, 300) i;                                        -- 300

-- 3. volatile-lru only evicts keys with a TTL, then errors.
ALTER SYSTEM SET memkv.eviction_policy = 'volatile-lru';
SELECT pg_reload_conf();
SELECT pg_sleep(0.5);
\c
SELECT kv_flush();
SELECT kv_set('p' || i, repeat('p', 1000)) FROM generate_series(1, 300) i;
SELECT kv_set('v' || i, repeat('v', 1000), '1 hour') FROM generate_series(1, 300) i;
SELECT kv_set('q' || i, repeat('q', 1000)) FROM generate_series(1, 300) i;
SELECT count(*) FILTER (WHERE kv_get('p' || i) IS NOT NULL) AS persistent_kept
FROM generate_series(1, 300) i;                                        -- 300
\set ON_ERROR_STOP 0
SELECT kv_set('r' || i, repeat('r', 1000)) FROM generate_series(1, 2000) i;  -- ERROR: memkv is full

-- 4. A value bigger than the cap errors without touching the store.
SELECT kv_set('big', repeat('b', 2 * 1024 * 1024));                   -- ERROR: does not fit

-- 5. noeviction keeps the old behaviour.
ALTER SYSTEM SET memkv.eviction_policy = 'noeviction';
SELECT pg_reload_conf();
SELECT pg_sleep(0.5);
\c
SELECT kv_flush();
SELECT kv_set('n' || i, repeat('n', 1000)) FROM generate_series(1, 2000) i;  -- ERROR: memkv is full

\set ON_ERROR_STOP 1

-- Clean up.
SELECT kv_flush();
ALTER SYSTEM RESET memkv.max_memory;
ALTER SYSTEM RESET memkv.eviction_policy;
SELECT pg_reload_conf();

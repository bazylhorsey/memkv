-- volatile-lru evicts a share of the keys that have a TTL, not a share of all
-- the keys. With a few TTL keys among many persistent ones, the first time the
-- store is full must not take them all. Every check is an ASSERT:
--   psql -X -v ON_ERROR_STOP=1 -f test/volatile.sql
-- It shrinks memkv.max_memory to 1MB while it runs.
CREATE EXTENSION IF NOT EXISTS memkv;
ALTER SYSTEM SET memkv.max_memory = '1MB';
ALTER SYSTEM SET memkv.eviction_policy = 'volatile-lru';
SELECT pg_reload_conf() \gset
SELECT pg_sleep(0.5) \gset
\c
SELECT memkv.flush() \gset

DO $$
DECLARE
    i       int;
    e0      bigint;
    ttl_out int;
BEGIN
    -- forty keys with a TTL, which are all that can be evicted
    FOR i IN 1..40 LOOP
        PERFORM memkv.set('w' || i, repeat('w', 1000), interval '1 hour');
    END LOOP;
    SELECT evicted INTO e0 FROM memkv.stats();

    -- then persistent keys, until the store is full and something is evicted
    i := 0;
    LOOP
        i := i + 1;
        ASSERT i < 5000, 'the store never filled up';
        PERFORM memkv.set('p' || i, repeat('p', 1000));
        EXIT WHEN (SELECT evicted FROM memkv.stats()) > e0;
    END LOOP;
    ASSERT i > 100, format('only %s persistent keys went in before the first eviction', i);

    -- a share of the 40 went, not all of them (a share of every key in the
    -- store would be more than there are)
    SELECT count(*) INTO ttl_out FROM generate_series(1, 40) g WHERE memkv.get('w' || g) IS NOT NULL;
    ASSERT ttl_out >= 28, format('the first eviction took %s of the 40 keys that could be evicted', 40 - ttl_out);
    -- and no persistent key was touched
    ASSERT (SELECT count(*) FROM generate_series(1, i) g WHERE memkv.get('p' || g) IS NOT NULL) = i,
           'a persistent key was evicted';
END $$;

SELECT memkv.flush() \gset
ALTER SYSTEM RESET memkv.max_memory;
ALTER SYSTEM RESET memkv.eviction_policy;
SELECT pg_reload_conf() \gset
SELECT pg_sleep(0.5) \gset
\c

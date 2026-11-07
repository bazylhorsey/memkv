-- What a write does when it can't get memory, in the cases that are hard to
-- make happen: keys that keep expiring while it evicts, and an eviction that
-- never gets anywhere. Only for servers built with assertions: memkv.test_reclaim
-- exists only there. Every check is an ASSERT:
--   psql -X -v ON_ERROR_STOP=1 -f test/reclaim.sql
-- It shrinks memkv.max_memory to 1MB while it runs.
SELECT current_setting('debug_assertions') = 'on' AS asserts \gset
\if :asserts

CREATE EXTENSION IF NOT EXISTS memkv;
ALTER SYSTEM SET memkv.max_memory = '1MB';
ALTER SYSTEM SET memkv.eviction_policy = 'allkeys-lru';
SELECT pg_reload_conf() \gset
SELECT pg_sleep(0.5) \gset
\c
SELECT memkv.flush() \gset

-- Fill the store so that the next large value has to evict.
CREATE FUNCTION pg_temp.fill() RETURNS void LANGUAGE plpgsql AS $$
DECLARE i int;
BEGIN
    PERFORM memkv.flush();
    FOR i IN 1..3000 LOOP
        PERFORM memkv.set('k' || i, repeat('x', 1000));
    END LOOP;
END $$;

-- 1. A write that needs memory when keys keep expiring. Dropping expired keys
-- is tried first, but if it is all that ever happens the write never gets
-- room: a large value needs more than the scattered chunks that expired keys
-- leave. After that first round, live keys have to be evicted regardless.
SELECT pg_temp.fill() \gset
SET memkv.test_reclaim = 1;
SET statement_timeout = '30s';
DO $$
DECLARE
    big text := repeat('b', 100000);
BEGIN
    ASSERT memkv.set('big', big), 'the write completed';
    ASSERT memkv.get('big') = big, 'and it holds its value';
END $$;
RESET statement_timeout;
RESET memkv.test_reclaim;

-- 2. An eviction that never frees anything can be cancelled: the write ends
-- with query_canceled when its statement_timeout runs out, instead of
-- spinning with an LWLock held where no cancel can reach it.
SELECT pg_temp.fill() \gset
SET memkv.test_reclaim = 2;
SET statement_timeout = '1s';
DO $$
DECLARE
    t0 timestamptz := clock_timestamp();
    cancelled boolean := false;
BEGIN
    BEGIN
        PERFORM memkv.set('big', repeat('b', 100000));
    EXCEPTION WHEN query_canceled THEN
        cancelled := true;
    END;
    ASSERT cancelled, 'a write stuck evicting was not cancelled';
    ASSERT clock_timestamp() - t0 < interval '10 seconds', 'and it took too long to cancel';
END $$;
RESET statement_timeout;
RESET memkv.test_reclaim;

-- the store is still sound, and other writers were never blocked from it
SELECT count(*) = 0 AS sound FROM memkv.verify() \gset
\if :sound
\else
    SELECT * FROM memkv.verify() LIMIT 5;
    \quit 3
\endif
SELECT memkv.set('after', 'ok') AND memkv.get('after') = 'ok' AS usable \gset
\if :usable
\else
    \echo 'the store is not usable after a cancelled write'
    \quit 3
\endif

SELECT memkv.flush() \gset
ALTER SYSTEM RESET memkv.max_memory;
ALTER SYSTEM RESET memkv.eviction_policy;
SELECT pg_reload_conf() \gset
SELECT pg_sleep(0.5) \gset
\c

\else
\echo 'skipped: memkv.test_reclaim needs a server built with --enable-cassert'
\endif

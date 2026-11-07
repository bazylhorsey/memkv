-- Hash collisions. Only for servers built with assertions: memkv.test_weak_hash
-- exists only there. It cuts every key hash to one bit, so two keys can hold
-- the two possible hashes and any further key collides with one of them.
--   psql -X -v ON_ERROR_STOP=1 -f test/collision.sql
-- Every check is an ASSERT. A collision must never return or overwrite another
-- key's value: reads of the loser miss, writes of it fail.
SELECT current_setting('debug_assertions') = 'on' AS asserts \gset
\if :asserts

CREATE EXTENSION IF NOT EXISTS memkv;
SELECT kv_flush() \gset
ALTER SYSTEM SET memkv.test_weak_hash = on;
SELECT pg_reload_conf() \gset
SELECT pg_sleep(0.5) \gset
\c

DO $$
DECLARE
    stored  int := 0;
    refused int := 0;
    v       text;
    loser   text;
    i       int;
BEGIN
    -- 20 keys, 2 possible hashes: at most 2 can be stored
    FOR i IN 1..20 LOOP
        BEGIN
            PERFORM kv_set('key' || i, 'value' || i);
            stored := stored + 1;
        EXCEPTION WHEN internal_error THEN
            refused := refused + 1;
        END;
    END LOOP;
    ASSERT stored BETWEEN 1 AND 2, format('%s keys stored with a 1-bit hash', stored);
    ASSERT refused = 20 - stored, 'every other write is refused';

    -- every read returns the key's own value or nothing
    FOR i IN 1..20 LOOP
        v := kv_get('key' || i);
        ASSERT v IS NULL OR v = 'value' || i, format('key%s read another key''s value: %s', i, v);
    END LOOP;
    ASSERT (SELECT keys FROM kv_stats()) = stored;

    -- the other operations treat the loser as missing, and never touch the winner
    FOR i IN 1..20 LOOP
        IF kv_get('key' || i) IS NULL THEN
            loser := 'key' || i;
            EXIT;
        END IF;
    END LOOP;
    ASSERT loser IS NOT NULL;
    ASSERT NOT kv_exists(loser) AND kv_ttl(loser) IS NULL AND NOT kv_del(loser)
       AND NOT kv_expire(loser, '1 hour') AND NOT kv_persist(loser), 'the loser is missing';
    ASSERT (SELECT keys FROM kv_stats()) = stored, 'and deleting it removed nothing';
    BEGIN
        PERFORM kv_incr(loser);
        ASSERT false, 'kv_incr on the loser must fail';
    EXCEPTION WHEN internal_error THEN NULL;
    END;
    BEGIN
        PERFORM kv_hset(loser, 'f', 'v');
        ASSERT false, 'kv_hset on the loser must fail';
    EXCEPTION WHEN internal_error THEN NULL;
    END;
    ASSERT kv_hget(loser, 'f') IS NULL AND kv_hlen(loser) = 0, 'hash reads of the loser miss';
    ASSERT kv_mget(ARRAY[loser]) = ARRAY[NULL]::text[], 'kv_mget of the loser misses';

    -- freeing the winner's hash lets the loser in
    FOR i IN 1..20 LOOP
        IF kv_get('key' || i) IS NOT NULL THEN
            PERFORM kv_del('key' || i);
        END IF;
    END LOOP;
    PERFORM kv_set(loser, 'now mine');
    ASSERT kv_get(loser) = 'now mine';
    PERFORM kv_flush();

    -- an expired key doesn't hold its hash: a colliding key takes the entry over
    PERFORM kv_set('first', 'x', '300 milliseconds');
    FOR i IN 1..20 LOOP
        BEGIN
            PERFORM kv_set('probe' || i, 'p');
            PERFORM kv_del('probe' || i);        -- stored, so not the colliding one
        EXCEPTION WHEN internal_error THEN
            loser := 'probe' || i;               -- collides with 'first'
            EXIT;
        END;
    END LOOP;
    PERFORM pg_sleep(0.5);
    PERFORM kv_set(loser, 'took over');
    ASSERT kv_get(loser) = 'took over' AND kv_get('first') IS NULL, 'an expired key gives up its entry';
    PERFORM kv_flush();
END $$;

ALTER SYSTEM RESET memkv.test_weak_hash;
SELECT pg_reload_conf() \gset
SELECT pg_sleep(0.5) \gset
\c
SELECT kv_flush() \gset

\else
\echo 'skipped: memkv.test_weak_hash exists only on servers built with assertions'
\endif

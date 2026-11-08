-- verify(): a sound store gives no rows. On a server built with assertions the
-- test also damages entries on purpose and checks that verify() notices, since
-- a checker that never reports anything proves nothing. Every check is an ASSERT:
--   psql -X -v ON_ERROR_STOP=1 -f test/verify.sql
CREATE EXTENSION IF NOT EXISTS memkv;
SELECT memkv.flush() \gset

-- a store with every kind of entry, some with TTLs
SELECT count(memkv.set('s' || i, repeat('x', i % 50),
                       CASE WHEN i % 3 = 0 THEN interval '1 hour' END))
FROM generate_series(1, 2000) i \gset
SELECT count(memkv.hset('h' || (i % 20), 'f' || i, 'v')) FROM generate_series(1, 400) i \gset
SELECT count(memkv.rate_limit('b' || i, 10, interval '1 minute')::int) FROM generate_series(1, 100) i \gset
SELECT count(memkv.incr('c' || (i % 30))) FROM generate_series(1, 300) i \gset

DO $$
BEGIN
    ASSERT (SELECT count(*) FROM memkv.verify()) = 0, 'a sound store has no problems';
END $$;

-- after deletes and overwrites too
SELECT count(memkv.del('s' || i)) FROM generate_series(1, 2000, 2) i \gset
SELECT count(memkv.set('s' || i, 'again')) FROM generate_series(2, 2000, 4) i \gset
SELECT count(memkv.hdel('h' || (i % 20), 'f' || i)) FROM generate_series(1, 400, 3) i \gset

DO $$
BEGIN
    ASSERT (SELECT count(*) FROM memkv.verify()) = 0, 'still none after deletes and overwrites';
END $$;

SELECT current_setting('debug_assertions') = 'on' AS asserts \gset
\if :asserts

CREATE FUNCTION pg_temp.damage(key text, what text) RETURNS void
AS '$libdir/memkv', 'kv_debug_corrupt' LANGUAGE C;

DO $$
DECLARE
    what    text;
    n       int;
BEGIN
    FOREACH what IN ARRAY ARRAY['hash', 'type', 'len', 'klen', 'cap'] LOOP
        PERFORM memkv.flush();
        PERFORM memkv.set('s', 'a string');
        PERFORM memkv.hset('h', 'f', 'v');
        PERFORM memkv.rate_limit('b', 5, interval '1 hour');
        ASSERT (SELECT count(*) FROM memkv.verify()) = 0, 'clean before the damage';

        -- len only means something for a hash or a limiter, which have a shape
        PERFORM pg_temp.damage(CASE WHEN what = 'len' THEN 'h' ELSE 's' END, what);
        SELECT count(*) INTO n FROM memkv.verify();
        ASSERT n >= 1, format('verify() must notice damage of kind %s', what);
    END LOOP;

    -- a limiter of the wrong size is a problem too
    PERFORM memkv.flush();
    PERFORM memkv.rate_limit('b', 5, interval '1 hour');
    PERFORM pg_temp.damage('b', 'len');
    ASSERT (SELECT count(*) FROM memkv.verify()) >= 1, 'a damaged limiter';

    PERFORM memkv.flush();
    ASSERT (SELECT count(*) FROM memkv.verify()) = 0, 'and a flush puts it right';
END $$;

\else
\echo 'damage detection skipped: kv_debug_corrupt exists only on servers built with assertions'
\endif

SELECT memkv.flush() \gset

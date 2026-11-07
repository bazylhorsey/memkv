-- Every error memkv raises and the SQLSTATE it carries, so clients can map them
-- to exceptions without reading messages. Every check is an ASSERT:
--   psql -X -v ON_ERROR_STOP=1 -f test/errors.sql
-- The hash collision error (XX000) is in test/collision.sql, which needs an
-- assertion build.
CREATE EXTENSION IF NOT EXISTS memkv;
SELECT memkv.flush() \gset

-- Run a statement; say 'ok' or the SQLSTATE it failed with.
CREATE FUNCTION pg_temp.state(q text) RETURNS text LANGUAGE plpgsql AS $$
BEGIN
    EXECUTE q;
    RETURN 'ok';
EXCEPTION WHEN OTHERS THEN
    RETURN SQLSTATE;
END $$;

DO $$
BEGIN
    PERFORM memkv.hset('h', 'f', 'v');
    PERFORM memkv.set('s', 'abc');
    PERFORM memkv.set('big', '9223372036854775807');
    PERFORM memkv.rate_limit('b', 3, interval '1 hour');
    PERFORM memkv.hset('hbad', 'f', 'not a number');
    PERFORM memkv.hset('hbig', 'f', '9223372036854775807');

    -- 42809 wrong_object_type: the key holds another kind of value
    ASSERT pg_temp.state($q$SELECT memkv.get('h')$q$) = '42809', 'get on a hash';
    ASSERT pg_temp.state($q$SELECT memkv.incr('h')$q$) = '42809', 'incr on a hash';
    ASSERT pg_temp.state($q$SELECT memkv.hget('s', 'f')$q$) = '42809', 'hget on a string';
    ASSERT pg_temp.state($q$SELECT memkv.hset('s', 'f', 'v')$q$) = '42809', 'hset on a string';
    ASSERT pg_temp.state($q$SELECT memkv.hlen('b')$q$) = '42809', 'hlen on a limiter';
    ASSERT pg_temp.state($q$SELECT memkv.get('b')$q$) = '42809', 'get on a limiter';
    ASSERT pg_temp.state($q$SELECT memkv.rate_limit('s', 3, interval '1 hour')$q$) = '42809', 'a limiter on a string';
    ASSERT pg_temp.state($q$SELECT memkv.rate_limit('h', 3, interval '1 hour')$q$) = '42809', 'a limiter on a hash';

    -- 22004 null_value_not_allowed
    ASSERT pg_temp.state($q$SELECT memkv.set(NULL, 'v')$q$) = '22004', 'set with a null key';
    ASSERT pg_temp.state($q$SELECT memkv.set('k', NULL)$q$) = '22004', 'set with a null value';
    ASSERT pg_temp.state($q$SELECT memkv.mset(NULL, ARRAY['a'])$q$) = '22004', 'mset with null keys';
    ASSERT pg_temp.state($q$SELECT memkv.mset(ARRAY['a', NULL], ARRAY['1', '2'])$q$) = '22004', 'mset with a null key';
    ASSERT pg_temp.state($q$SELECT memkv.mget(ARRAY['a', NULL])$q$) = '22004', 'mget with a null key';

    -- 22023 invalid_parameter_value
    ASSERT pg_temp.state($q$SELECT memkv.set('k', 'v', nx => true, xx => true)$q$) = '22023', 'nx and xx';
    ASSERT pg_temp.state($q$SELECT memkv.set('k', 'v', interval '0 seconds')$q$) = '22023', 'a TTL of zero';
    ASSERT pg_temp.state($q$SELECT memkv.expire('s', interval '-1 second')$q$) = '22023', 'a negative TTL';
    ASSERT pg_temp.state($q$SELECT memkv.rate_limit('x', 0, interval '1 hour')$q$) = '22023', 'capacity 0';
    ASSERT pg_temp.state($q$SELECT memkv.rate_limit('x', 5, interval '0 seconds')$q$) = '22023', 'period 0';
    ASSERT pg_temp.state($q$SELECT memkv.rate_limit('x', 5, interval '1 hour', 0)$q$) = '22023', 'cost 0';
    ASSERT pg_temp.state($q$SELECT memkv.rate_limit('x', 5, interval '1 hour', 6)$q$) = '22023', 'cost over capacity';

    -- 22P02 invalid_text_representation: the value is not an integer
    ASSERT pg_temp.state($q$SELECT memkv.incr('s')$q$) = '22P02', 'incr on text';
    ASSERT pg_temp.state($q$SELECT memkv.hincr('hbad', 'f')$q$) = '22P02', 'hincr on text';

    -- 22003 numeric_value_out_of_range
    ASSERT pg_temp.state($q$SELECT memkv.incr('big')$q$) = '22003', 'incr overflow';
    ASSERT pg_temp.state($q$SELECT memkv.hincr('hbig', 'f')$q$) = '22003', 'hincr overflow';

    -- 2202E array_subscript_error
    ASSERT pg_temp.state($q$SELECT memkv.mset(ARRAY['a', 'b'], ARRAY['1'])$q$) = '2202E', 'mset with different lengths';
    ASSERT pg_temp.state($q$SELECT memkv.mget('{{a},{b}}'::text[])$q$) = '2202E', 'mget with a 2-D array';

    -- 54000 program_limit_exceeded: an entry that could never fit in the cap
    ASSERT pg_temp.state(format($q$SELECT memkv.set('toobig', repeat('x', %s))$q$,
                                (SELECT max_memory_bytes FROM memkv.stats()) + 1)) = '54000', 'larger than the cap';

    -- and the ones that succeed say so
    ASSERT pg_temp.state($q$SELECT memkv.get('s')$q$) = 'ok';
END $$;

-- 53200 out_of_memory: the store is full and the policy won't evict
ALTER SYSTEM SET memkv.max_memory = '1MB';
ALTER SYSTEM SET memkv.eviction_policy = 'noeviction';
SELECT pg_reload_conf() \gset
SELECT pg_sleep(0.5) \gset
\c
SELECT memkv.flush() \gset
DO $$
DECLARE
    i int;
BEGIN
    FOR i IN 1..5000 LOOP
        PERFORM memkv.set('k' || i, repeat('x', 1000));
    END LOOP;
    ASSERT false, 'a 1 MB store with noeviction must fill up';
EXCEPTION WHEN out_of_memory THEN
    NULL;
END $$;
SELECT memkv.flush() \gset
ALTER SYSTEM RESET memkv.max_memory;
ALTER SYSTEM RESET memkv.eviction_policy;
SELECT pg_reload_conf() \gset
SELECT pg_sleep(0.5) \gset
\c
SELECT memkv.flush() \gset

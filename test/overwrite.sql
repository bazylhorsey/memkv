-- Overwriting a value where it already is. set() and incr() write over an
-- existing key in place when the new value fits, so these check that whatever
-- the sizes do, what you read back is exactly what you wrote. Every check is an
-- ASSERT:
--   psql -X -v ON_ERROR_STOP=1 -f test/overwrite.sql
CREATE EXTENSION IF NOT EXISTS memkv;
SELECT memkv.flush() \gset

DO $$
DECLARE
    sizes   int[] := ARRAY[0, 1, 10, 100, 1000, 1000, 600, 100, 5, 5000, 20, 20, 0, 70000, 3, 3, 40000, 7];
    n       int;
    i       int;
    v       text;
BEGIN
    -- any sequence of sizes reads back exactly: growing, shrinking, staying
    FOREACH n IN ARRAY sizes LOOP
        PERFORM memkv.set('k', repeat('a', n));
        v := memkv.get('k');
        ASSERT length(v) = n AND v = repeat('a', n), format('after a set of %s bytes', n);
    END LOOP;

    -- and in a random order, over a few keys, with content that tells them apart
    FOR i IN 1..3000 LOOP
        n := (random() * 3000)::int;
        PERFORM memkv.set('r' || (i % 7), repeat(chr(97 + i % 26), n));
        ASSERT memkv.get('r' || (i % 7)) = repeat(chr(97 + i % 26), n), format('random size %s', n);
    END LOOP;

    -- set replaces the TTL, incr keeps it
    PERFORM memkv.set('t', 'abc', interval '1 hour');
    PERFORM memkv.set('t', 'xyz');
    ASSERT memkv.ttl('t') = 'infinity', 'a set without a TTL clears it';
    PERFORM memkv.set('c', '5', interval '1 hour');
    ASSERT memkv.incr('c') = 6, 'incr';
    ASSERT memkv.ttl('c') BETWEEN interval '59 minutes' AND interval '1 hour', 'incr keeps the TTL';

    -- counters across digit boundaries, in both directions
    PERFORM memkv.set('d', '8');
    ASSERT memkv.incr('d') = 9 AND memkv.incr('d') = 10 AND memkv.get('d') = '10', '9 to 10';
    FOR i IN 1..95 LOOP PERFORM memkv.incr('d'); END LOOP;
    ASSERT memkv.get('d') = '105', 'up to 105';
    ASSERT memkv.incr('d', -100) = 5 AND memkv.get('d') = '5', 'back down to one digit';
    ASSERT memkv.incr('d', -10) = -5 AND memkv.get('d') = '-5', 'across zero';
    ASSERT memkv.incr('d', -95) = -100 AND memkv.get('d') = '-100', 'to three digits and a sign';
    ASSERT memkv.incr('e', 9223372036854775807) = 9223372036854775807
       AND memkv.get('e') = '9223372036854775807', 'the largest number';
    ASSERT memkv.incr('e', -9223372036854775807) = 0 AND memkv.get('e') = '0', 'and back to zero';
    ASSERT memkv.incr('f', -9223372036854775807 - 1) = -9223372036854775808, 'the smallest number';

    -- a counter that was set as text of one digit still grows
    PERFORM memkv.set('g', '9');
    ASSERT memkv.incr('g', 9223372036854775798) = 9223372036854775807, 'one digit to nineteen';

    -- kinds change in place
    PERFORM memkv.hset('x', 'f', 'v');
    ASSERT memkv.set('x', 'now a string') AND memkv.get('x') = 'now a string', 'a string over a hash';
    PERFORM memkv.rate_limit('x2', 5, interval '1 hour');
    ASSERT memkv.set('x2', 'a string') AND memkv.get('x2') = 'a string', 'a string over a limiter';
END $$;

DO $$
BEGIN
    -- NX and XX
    PERFORM memkv.set('nx', 'one');
    ASSERT NOT memkv.set('nx', 'two', nx => true) AND memkv.get('nx') = 'one', 'nx leaves a live key alone';
    ASSERT NOT memkv.set('missing', 'x', xx => true) AND NOT memkv.exists('missing'), 'xx does not create';
    ASSERT memkv.set('nx', 'three', xx => true) AND memkv.get('nx') = 'three', 'xx overwrites';

    -- an expired key counts as missing
    PERFORM memkv.set('e', 'old', interval '100 milliseconds');
    PERFORM pg_sleep(0.2);
    ASSERT NOT memkv.set('e', 'x', xx => true) AND memkv.get('e') IS NULL, 'xx on an expired key';
    ASSERT memkv.set('e', 'new', nx => true) AND memkv.get('e') = 'new' AND memkv.ttl('e') = 'infinity', 'nx on an expired key';
    PERFORM memkv.set('e2', '41', interval '100 milliseconds');
    PERFORM pg_sleep(0.2);
    ASSERT memkv.incr('e2') = 1 AND memkv.ttl('e2') = 'infinity', 'incr on an expired counter starts again';

    -- mset goes through the same path
    PERFORM memkv.mset(ARRAY['m1', 'm2'], ARRAY['aaaa', 'bbbb']);
    PERFORM memkv.mset(ARRAY['m1', 'm2'], ARRAY['cc', 'dddddd']);
    ASSERT memkv.mget(ARRAY['m1', 'm2']) = ARRAY['cc', 'dddddd'], 'mset over existing keys';

    -- the store is still sound
    ASSERT (SELECT count(*) FROM memkv.verify()) = 0, 'verify() after all of that';
END $$;

SELECT memkv.flush() \gset

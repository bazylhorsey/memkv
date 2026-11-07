-- Rate limiting. Every check is an ASSERT, so
--   psql -X -v ON_ERROR_STOP=1 -f test/rate_limit.sql
-- prints nothing when everything holds and stops at the first difference.
CREATE EXTENSION IF NOT EXISTS memkv;
SELECT memkv.flush() \gset

DO $$
DECLARE
    r       record;
    n       int;
    i       int;
BEGIN
    -- capacity: exactly that many pass in a period, and the rest don't
    SELECT count(*) INTO n FROM generate_series(1, 20) g
    WHERE memkv.rate_limit('t:cap', 5, interval '1 hour');
    ASSERT n = 5, format('capacity 5: %s of 20 calls passed', n);

    -- the first call on a new limiter: allowed, one of five used
    SELECT * INTO r FROM memkv.rate_limit_info('t:info', 5, interval '1 hour');
    ASSERT r.allowed AND r.remaining = 4 AND r.retry_after_ms = 0, 'first call';
    ASSERT r.reset_after_ms BETWEEN 719000 AND 720000,
           format('it is full again in one fifth of an hour, not %s ms', r.reset_after_ms);

    -- use up the rest; the sixth call is refused and says when it would pass
    FOR i IN 2..5 LOOP
        SELECT * INTO r FROM memkv.rate_limit_info('t:info', 5, interval '1 hour');
        ASSERT r.allowed, format('call %s is allowed', i);
    END LOOP;
    ASSERT r.remaining = 0, 'the fifth leaves nothing';
    SELECT * INTO r FROM memkv.rate_limit_info('t:info', 5, interval '1 hour');
    ASSERT NOT r.allowed AND r.remaining = 0, 'the sixth is refused';
    ASSERT r.retry_after_ms BETWEEN 719000 AND 720000,
           format('it passes one interval from now, not in %s ms', r.retry_after_ms);
    ASSERT r.reset_after_ms BETWEEN 3599000 AND 3600000,
           format('the bucket is full in an hour, not %s ms', r.reset_after_ms);
    ASSERT memkv.ttl('t:info') BETWEEN interval '59 minutes' AND interval '1 hour',
           'the key lives until the bucket is full';

    -- cost: a call can count for several requests
    SELECT * INTO r FROM memkv.rate_limit_info('t:cost', 10, interval '1 hour', cost => 4);
    ASSERT r.allowed AND r.remaining = 6, 'cost 4 of 10';
    SELECT * INTO r FROM memkv.rate_limit_info('t:cost', 10, interval '1 hour', cost => 4);
    ASSERT r.allowed AND r.remaining = 2, 'cost 4 again';
    SELECT * INTO r FROM memkv.rate_limit_info('t:cost', 10, interval '1 hour', cost => 4);
    ASSERT NOT r.allowed AND r.remaining = 2, 'a third would need 2 more';
    ASSERT r.retry_after_ms BETWEEN 719000 AND 720000, 'two requests take two intervals of 6 minutes';
    ASSERT memkv.rate_limit('t:cost', 10, interval '1 hour', cost => 2), 'but cost 2 still fits';
    ASSERT NOT memkv.rate_limit('t:cost', 10, interval '1 hour'), 'and then nothing does';

    -- refill: two per 400 ms
    ASSERT memkv.rate_limit('t:fast', 2, interval '400 milliseconds');
    ASSERT memkv.rate_limit('t:fast', 2, interval '400 milliseconds');
    ASSERT NOT memkv.rate_limit('t:fast', 2, interval '400 milliseconds'), 'two at once, not three';
    PERFORM pg_sleep(0.25);
    ASSERT memkv.rate_limit('t:fast', 2, interval '400 milliseconds'), 'one interval later one more passes';
    ASSERT NOT memkv.rate_limit('t:fast', 2, interval '400 milliseconds'), 'but only one';
    PERFORM pg_sleep(0.5);
    ASSERT NOT memkv.exists('t:fast'), 'an idle bucket expires by itself';
    ASSERT memkv.rate_limit('t:fast', 2, interval '400 milliseconds')
       AND memkv.rate_limit('t:fast', 2, interval '400 milliseconds')
       AND NOT memkv.rate_limit('t:fast', 2, interval '400 milliseconds'), 'full again after a period';

    -- a limiter is its own kind of value
    BEGIN
        PERFORM memkv.get('t:info');
        ASSERT false, 'get on a limiter must fail';
    EXCEPTION WHEN wrong_object_type THEN NULL;
    END;
    BEGIN
        PERFORM memkv.incr('t:info');
        ASSERT false, 'incr on a limiter must fail';
    EXCEPTION WHEN wrong_object_type THEN NULL;
    END;
    ASSERT memkv.mget(ARRAY['t:info']) = ARRAY[NULL]::text[], 'mget skips it';
    PERFORM memkv.set('t:str', 'x');
    BEGIN
        PERFORM memkv.rate_limit('t:str', 3, interval '1 hour');
        ASSERT false, 'a limiter on a string must fail';
    EXCEPTION WHEN wrong_object_type THEN NULL;
    END;
    ASSERT memkv.set('t:info', 'now a string') AND memkv.get('t:info') = 'now a string', 'set replaces a limiter';
    ASSERT memkv.del('t:str');

    -- the limit can change between calls, because the state is a point in time:
    -- two of four used a half hour of the period, and with a capacity of eight
    -- three more of the new size still fit
    ASSERT memkv.rate_limit('t:change', 4, interval '1 hour');
    ASSERT memkv.rate_limit('t:change', 4, interval '1 hour');
    SELECT * INTO r FROM memkv.rate_limit_info('t:change', 8, interval '1 hour');
    ASSERT r.allowed AND r.remaining = 3, format('a bigger capacity: %s left', r.remaining);
    -- a bucket that is already full for its period has no room to give back
    ASSERT memkv.rate_limit('t:full', 2, interval '1 hour') AND memkv.rate_limit('t:full', 2, interval '1 hour');
    ASSERT NOT memkv.rate_limit('t:full', 4, interval '1 hour'), 'raising the capacity does not refill it';

    -- bad arguments
    BEGIN PERFORM memkv.rate_limit('x', 0, interval '1 hour'); ASSERT false;
    EXCEPTION WHEN invalid_parameter_value THEN NULL; END;
    BEGIN PERFORM memkv.rate_limit('x', 5, interval '0 seconds'); ASSERT false;
    EXCEPTION WHEN invalid_parameter_value THEN NULL; END;
    BEGIN PERFORM memkv.rate_limit('x', 5, interval '1 hour', 0); ASSERT false;
    EXCEPTION WHEN invalid_parameter_value THEN NULL; END;
    BEGIN PERFORM memkv.rate_limit('x', 5, interval '1 hour', 6); ASSERT false, 'cost over capacity';
    EXCEPTION WHEN invalid_parameter_value THEN NULL; END;
    -- an endless period allows its capacity once and then refuses, without an error
    ASSERT memkv.rate_limit('t:inf', 1, interval 'infinity'), 'the first of an endless period';
    SELECT * INTO r FROM memkv.rate_limit_info('t:inf', 1, interval 'infinity');
    ASSERT NOT r.allowed AND r.remaining = 0, 'and then nothing';
    ASSERT memkv.rate_limit(NULL, 5, interval '1 hour') IS NULL, 'a null key gives null';
END $$;

SELECT memkv.flush() \gset

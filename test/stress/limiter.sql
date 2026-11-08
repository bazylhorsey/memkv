-- pgbench script: every client asks one rate limiter and counts the calls it
-- let through. With a capacity of 1000 an hour and more than 1000 calls in
-- total, exactly 1000 must pass, however many clients race for them.
SELECT CASE WHEN memkv.rate_limit('stress_limiter', 1000, interval '1 hour')
            THEN memkv.incr('stress_allowed') END;

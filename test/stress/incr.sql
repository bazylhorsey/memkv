-- pgbench script: every client increments one of 8 shared counters.
-- After N transactions in total the counters must sum to exactly N.
SELECT memkv.incr('ctr' || (:client_id % 8)::text);

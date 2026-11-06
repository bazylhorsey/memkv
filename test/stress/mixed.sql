-- pgbench script: every memkv function, on overlapping keys.
--
-- The key space is much larger than a small max_memory, so the store stays full
-- and eviction runs constantly. Keys that start with "ts" have a 20 ms TTL, so
-- they expire before eviction reaches them; "tl" keys have a 1 s TTL and are
-- normally evicted first. Key families never share a type: k* and t* are
-- strings, c* are counters, h* and hc* are hashes.
-- Run through test/stress/run.sh.
\set k random(1, 20000)
\set r random(1, 200)
\if :r <= 56
  SELECT kv_get('k' || :k::text);
\elif :r <= 92
  SELECT kv_set('k' || :k::text, repeat('v', 100 + :k % 900));
\elif :r <= 98
  SELECT kv_set('k' || :k::text, repeat('n', 100 + :k % 900), nx => true);
\elif :r <= 102
  SELECT kv_set('k' || :k::text, repeat('x', 100 + :k % 900), xx => true);
\elif :r <= 110
  SELECT kv_set('ts' || :k::text, repeat('t', 50 + :k % 400), interval '20 milliseconds');
\elif :r <= 118
  SELECT kv_set('tl' || :k::text, repeat('t', 50 + :k % 400), interval '1 second');
\elif :r <= 124
  SELECT kv_exists('k' || :k::text), kv_ttl('ts' || :k::text);
\elif :r <= 128
  SELECT kv_expire('k' || :k::text, interval '1 second'), kv_persist('k' || :k::text);
\elif :r <= 140
  SELECT kv_incr('c' || (:k % 64)::text);
\elif :r <= 154
  SELECT kv_hset('h' || (:k % 32)::text, 'f' || (:k % 16)::text, repeat('x', 1 + :k % 50));
\elif :r <= 160
  SELECT kv_hdel('h' || (:k % 32)::text, 'f' || (:k % 16)::text), kv_hlen('h' || (:k % 32)::text);
\elif :r <= 170
  SELECT kv_hincr('hc' || (:k % 8)::text, 'n' || (:k % 4)::text);
\elif :r <= 176
  SELECT * FROM kv_hgetall('h' || (:k % 32)::text);
\elif :r <= 182
  SELECT kv_mget(ARRAY['k' || :k::text, 'k' || (:k + 1)::text, 'c' || (:k % 64)::text]);
\elif :r <= 186
  SELECT kv_mset(ARRAY['k' || :k::text, 'k' || (:k + 1)::text], ARRAY['a', 'b'], interval '2 seconds');
\elif :r <= 197
  SELECT kv_del('k' || :k::text);
\elif :r <= 199
  SELECT kv_sweep();
\else
  SELECT keys FROM kv_stats();
\endif

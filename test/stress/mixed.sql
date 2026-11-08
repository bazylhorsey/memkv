-- pgbench script: every memkv function, on overlapping keys.
--
-- The key space is much larger than a small max_memory, so the store stays full
-- and eviction runs constantly. Keys that start with "ts" have a 20 ms TTL, so
-- they expire before eviction reaches them; "tl" keys have a 1 s TTL and are
-- normally evicted first. Key families never share a type: k* and t* are
-- strings (v* get a new random size every time), c* are counters, h* and hc*
-- are hashes, rl* are rate limiters.
-- Run through test/stress/run.sh.
\set k random(1, 20000)
\set r random(1, 200)
\set sz random(1, 1000)
\if :r <= 56
  SELECT memkv.get('k' || :k::text);
\elif :r <= 80
  SELECT memkv.set('k' || :k::text, repeat('v', 100 + :k % 900));
\elif :r <= 92
  SELECT memkv.set('v' || (:k % 500)::text, repeat('r', :sz));
\elif :r <= 98
  SELECT memkv.set('k' || :k::text, repeat('n', 100 + :k % 900), nx => true);
\elif :r <= 102
  SELECT memkv.set('k' || :k::text, repeat('x', 100 + :k % 900), xx => true);
\elif :r <= 110
  SELECT memkv.set('ts' || :k::text, repeat('t', 50 + :k % 400), interval '20 milliseconds');
\elif :r <= 118
  SELECT memkv.set('tl' || :k::text, repeat('t', 50 + :k % 400), interval '1 second');
\elif :r <= 124
  SELECT memkv.exists('k' || :k::text), memkv.ttl('ts' || :k::text);
\elif :r <= 128
  SELECT memkv.expire('k' || :k::text, interval '1 second'), memkv.persist('k' || :k::text);
\elif :r <= 140
  SELECT memkv.incr('c' || (:k % 64)::text);
\elif :r <= 154
  SELECT memkv.hset('h' || (:k % 32)::text, 'f' || (:k % 16)::text, repeat('x', 1 + :k % 50));
\elif :r <= 160
  SELECT memkv.hdel('h' || (:k % 32)::text, 'f' || (:k % 16)::text), memkv.hlen('h' || (:k % 32)::text);
\elif :r <= 170
  SELECT memkv.hincr('hc' || (:k % 8)::text, 'n' || (:k % 4)::text);
\elif :r <= 176
  SELECT * FROM memkv.hgetall('h' || (:k % 32)::text);
\elif :r <= 182
  SELECT memkv.mget(ARRAY['k' || :k::text, 'k' || (:k + 1)::text, 'c' || (:k % 64)::text]);
\elif :r <= 186
  SELECT memkv.mset(ARRAY['k' || :k::text, 'k' || (:k + 1)::text], ARRAY['a', 'b'], interval '2 seconds');
\elif :r <= 192
  SELECT memkv.del('k' || :k::text);
\elif :r <= 197
  SELECT memkv.rate_limit('rl' || (:k % 100)::text, 50, interval '1 second');
\elif :r <= 199
  SELECT memkv.sweep();
\else
  SELECT keys FROM memkv.stats();
\endif

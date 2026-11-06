-- Walk-through of memkv functions. Expected results are in the comments.
--   psql -X -f test/commands.sql
CREATE EXTENSION IF NOT EXISTS memkv;
SELECT kv_flush();

-- SET NX / XX
SELECT kv_set('lock', 'me', '30 seconds', nx => true);   -- t
SELECT kv_set('lock', 'you', nx => true);                -- f
SELECT kv_get('lock');                                   -- me
SELECT kv_set('nobody', 'x', xx => true);                -- f
SELECT kv_exists('nobody');                              -- f
SELECT kv_set('lock', 'me2', xx => true);                -- t (and clears the TTL)

-- TTL / PERSIST / EXPIRE
SELECT kv_ttl('lock');                                   -- infinity
SELECT kv_expire('lock', '1 hour');                      -- t
SELECT kv_ttl('lock') BETWEEN '59 minutes' AND '1 hour'; -- t
SELECT kv_persist('lock');                               -- t
SELECT kv_persist('lock');                               -- f
SELECT kv_ttl('missing');                                -- NULL

-- MGET / MSET
SELECT kv_mset(ARRAY['a','b','c'], ARRAY['1','2','3']);
SELECT kv_mget(ARRAY['a','missing','c']);                -- {1,NULL,3}
SELECT kv_mget('{}');                                    -- {}

-- Hashes
SELECT kv_hset('user:1', 'name', 'Ada');                 -- t
SELECT kv_hset('user:1', 'name', 'Ada L.');              -- f
SELECT kv_hset('user:1', 'email', 'ada@example.com');    -- t
SELECT kv_hget('user:1', 'name');                        -- Ada L.
SELECT kv_hlen('user:1');                                -- 2
SELECT kv_hincr('user:1', 'logins');                     -- 1
SELECT kv_hincr('user:1', 'logins', 5);                  -- 6
SELECT * FROM kv_hgetall('user:1') ORDER BY field;       -- email, logins, name
SELECT kv_hdel('user:1', 'email');                       -- t
SELECT kv_hdel('user:1', 'email');                       -- f
SELECT kv_expire('user:1', '1 hour');                    -- t (TTLs work on hashes)
SELECT kv_hset('user:1', 'x', 'y');                      -- t (TTL kept)
SELECT kv_ttl('user:1') < '1 hour';                      -- t
SELECT kv_hdel('user:1', 'name'), kv_hdel('user:1', 'logins'), kv_hdel('user:1', 'x');
SELECT kv_exists('user:1');                              -- f (last field removed)

-- Wrong type
\set ON_ERROR_STOP 0
SELECT kv_hset('h', 'f', 'v');
SELECT kv_get('h');                                      -- ERROR: wrong kind of value
SELECT kv_incr('h');                                     -- ERROR: wrong kind of value
SELECT kv_hget('a', 'f');                                -- ERROR: wrong kind of value
SELECT kv_set('a', 'x', nx => true, xx => true);         -- ERROR: nx and xx
\set ON_ERROR_STOP 1
SELECT kv_mget(ARRAY['h','a']);                          -- {NULL,1}

-- Stats
SELECT * FROM kv_stats();
SELECT kv_flush();

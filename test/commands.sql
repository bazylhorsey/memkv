-- Walk-through of memkv functions. Expected results are in the comments.
--   psql -X -f test/commands.sql
CREATE EXTENSION IF NOT EXISTS memkv;
SELECT memkv.flush();

-- SET NX / XX
SELECT memkv.set('lock', 'me', '30 seconds', nx => true);   -- t
SELECT memkv.set('lock', 'you', nx => true);                -- f
SELECT memkv.get('lock');                                   -- me
SELECT memkv.set('nobody', 'x', xx => true);                -- f
SELECT memkv.exists('nobody');                              -- f
SELECT memkv.set('lock', 'me2', xx => true);                -- t (and clears the TTL)

-- TTL / PERSIST / EXPIRE
SELECT memkv.ttl('lock');                                   -- infinity
SELECT memkv.expire('lock', '1 hour');                      -- t
SELECT memkv.ttl('lock') BETWEEN '59 minutes' AND '1 hour'; -- t
SELECT memkv.persist('lock');                               -- t
SELECT memkv.persist('lock');                               -- f
SELECT memkv.ttl('missing');                                -- NULL

-- MGET / MSET
SELECT memkv.mset(ARRAY['a','b','c'], ARRAY['1','2','3']);
SELECT memkv.mget(ARRAY['a','missing','c']);                -- {1,NULL,3}
SELECT memkv.mget('{}');                                    -- {}

-- Hashes
SELECT memkv.hset('user:1', 'name', 'Ada');                 -- t
SELECT memkv.hset('user:1', 'name', 'Ada L.');              -- f
SELECT memkv.hset('user:1', 'email', 'ada@example.com');    -- t
SELECT memkv.hget('user:1', 'name');                        -- Ada L.
SELECT memkv.hlen('user:1');                                -- 2
SELECT memkv.hincr('user:1', 'logins');                     -- 1
SELECT memkv.hincr('user:1', 'logins', 5);                  -- 6
SELECT * FROM memkv.hgetall('user:1') ORDER BY field;       -- email, logins, name
SELECT memkv.hdel('user:1', 'email');                       -- t
SELECT memkv.hdel('user:1', 'email');                       -- f
SELECT memkv.expire('user:1', '1 hour');                    -- t (TTLs work on hashes)
SELECT memkv.hset('user:1', 'x', 'y');                      -- t (TTL kept)
SELECT memkv.ttl('user:1') < '1 hour';                      -- t
SELECT memkv.hdel('user:1', 'name'), memkv.hdel('user:1', 'logins'), memkv.hdel('user:1', 'x');
SELECT memkv.exists('user:1');                              -- f (last field removed)

-- Wrong type
\set ON_ERROR_STOP 0
SELECT memkv.hset('h', 'f', 'v');
SELECT memkv.get('h');                                      -- ERROR: wrong kind of value
SELECT memkv.incr('h');                                     -- ERROR: wrong kind of value
SELECT memkv.hget('a', 'f');                                -- ERROR: wrong kind of value
SELECT memkv.set('a', 'x', nx => true, xx => true);         -- ERROR: nx and xx
\set ON_ERROR_STOP 1
SELECT memkv.mget(ARRAY['h','a']);                          -- {NULL,1}

-- Stats
SELECT * FROM memkv.stats();
SELECT memkv.flush();

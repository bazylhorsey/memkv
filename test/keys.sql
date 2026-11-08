-- Keys of any length, compared exactly. Every check is an ASSERT, so
--   psql -X -v ON_ERROR_STOP=1 -f test/keys.sql
-- prints nothing when everything holds and stops at the first difference.
CREATE EXTENSION IF NOT EXISTS memkv;
SELECT memkv.flush() \gset

DO $$
DECLARE
    big   text := repeat('a', 1000000);         -- a megabyte of key
    near  text := repeat('a', 999999) || 'b';   -- differs from it in the last byte only
    k5    text;
BEGIN
    PERFORM memkv.set(big, 'long');
    ASSERT memkv.get(big) = 'long', 'a 1 MB key reads back';
    ASSERT memkv.get(left(big, 999999)) IS NULL, 'a prefix of a key is another key';
    ASSERT memkv.get(big || 'b') IS NULL, 'an extension of a key is another key';
    ASSERT memkv.get(near) IS NULL, 'a key that differs in its last byte is another key';

    PERFORM memkv.set(near, 'near');
    ASSERT memkv.get(big) = 'long' AND memkv.get(near) = 'near', 'each key holds its own value';
    ASSERT memkv.del(big), 'delete the long key';
    ASSERT memkv.get(big) IS NULL AND memkv.get(near) = 'near', 'deleting one key leaves the other';
    ASSERT memkv.del(near);

    -- the empty key is an ordinary key
    ASSERT memkv.set('', 'empty');
    ASSERT memkv.get('') = 'empty' AND memkv.exists(''), 'the empty key works';
    ASSERT memkv.get(' ') IS NULL, 'a space is not the empty key';
    ASSERT memkv.del('') AND NOT memkv.exists('');

    -- non-ASCII keys compare by bytes
    PERFORM memkv.set('ключ', 'v');
    ASSERT memkv.get('ключ') = 'v' AND memkv.get('ключ ') IS NULL AND memkv.get('ключа') IS NULL;
    ASSERT memkv.del('ключ');

    -- every kind of operation takes a long key
    k5 := repeat('k', 5000);
    ASSERT memkv.incr(k5) = 1 AND memkv.incr(k5, 4) = 5, 'memkv.incr';
    ASSERT memkv.del(k5);
    ASSERT memkv.hset(k5, 'f', 'v') AND memkv.hget(k5, 'f') = 'v' AND memkv.hlen(k5) = 1, 'hash set and get';
    ASSERT memkv.hincr(k5, 'n', 3) = 3 AND memkv.hlen(k5) = 2, 'hash incr';
    ASSERT (SELECT count(*) FROM memkv.hgetall(k5)) = 2, 'hash getall';
    ASSERT memkv.hdel(k5, 'f') AND memkv.hdel(k5, 'n') AND NOT memkv.exists(k5), 'hash delete removes the key';

    ASSERT memkv.set(k5, 'x', '1 hour'), 'memkv.set with a TTL';
    ASSERT memkv.ttl(k5) <= interval '1 hour', 'memkv.ttl';
    ASSERT memkv.expire(k5, '2 hours') AND memkv.persist(k5) AND memkv.ttl(k5) = 'infinity', 'expire and persist';
    ASSERT NOT memkv.set(k5, 'y', nx => true), 'nx refuses an existing key';
    ASSERT memkv.set(k5, 'z', xx => true) AND memkv.get(k5) = 'z', 'xx replaces it';

    PERFORM memkv.mset(ARRAY[k5 || '1', k5 || '2'], ARRAY['one', 'two']);
    ASSERT memkv.mget(ARRAY[k5 || '2', k5 || '3', k5 || '1']) = ARRAY['two', NULL, 'one'], 'memkv.mget';
    ASSERT memkv.get(k5) = 'z', 'a key and the same key plus a digit are different keys';
END $$;

SELECT memkv.flush() \gset
SELECT keys = 0 AS empty_again FROM memkv.stats();

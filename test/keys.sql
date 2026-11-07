-- Keys of any length, compared exactly. Every check is an ASSERT, so
--   psql -X -v ON_ERROR_STOP=1 -f test/keys.sql
-- prints nothing when everything holds and stops at the first difference.
CREATE EXTENSION IF NOT EXISTS memkv;
SELECT kv_flush() \gset

DO $$
DECLARE
    big   text := repeat('a', 1000000);         -- a megabyte of key
    near  text := repeat('a', 999999) || 'b';   -- differs from it in the last byte only
    k5    text;
BEGIN
    PERFORM kv_set(big, 'long');
    ASSERT kv_get(big) = 'long', 'a 1 MB key reads back';
    ASSERT kv_get(left(big, 999999)) IS NULL, 'a prefix of a key is another key';
    ASSERT kv_get(big || 'b') IS NULL, 'an extension of a key is another key';
    ASSERT kv_get(near) IS NULL, 'a key that differs in its last byte is another key';

    PERFORM kv_set(near, 'near');
    ASSERT kv_get(big) = 'long' AND kv_get(near) = 'near', 'each key holds its own value';
    ASSERT kv_del(big), 'delete the long key';
    ASSERT kv_get(big) IS NULL AND kv_get(near) = 'near', 'deleting one key leaves the other';
    ASSERT kv_del(near);

    -- the empty key is an ordinary key
    ASSERT kv_set('', 'empty');
    ASSERT kv_get('') = 'empty' AND kv_exists(''), 'the empty key works';
    ASSERT kv_get(' ') IS NULL, 'a space is not the empty key';
    ASSERT kv_del('') AND NOT kv_exists('');

    -- non-ASCII keys compare by bytes
    PERFORM kv_set('ключ', 'v');
    ASSERT kv_get('ключ') = 'v' AND kv_get('ключ ') IS NULL AND kv_get('ключа') IS NULL;
    ASSERT kv_del('ключ');

    -- every kind of operation takes a long key
    k5 := repeat('k', 5000);
    ASSERT kv_incr(k5) = 1 AND kv_incr(k5, 4) = 5, 'kv_incr';
    ASSERT kv_del(k5);
    ASSERT kv_hset(k5, 'f', 'v') AND kv_hget(k5, 'f') = 'v' AND kv_hlen(k5) = 1, 'hash set and get';
    ASSERT kv_hincr(k5, 'n', 3) = 3 AND kv_hlen(k5) = 2, 'hash incr';
    ASSERT (SELECT count(*) FROM kv_hgetall(k5)) = 2, 'hash getall';
    ASSERT kv_hdel(k5, 'f') AND kv_hdel(k5, 'n') AND NOT kv_exists(k5), 'hash delete removes the key';

    ASSERT kv_set(k5, 'x', '1 hour'), 'kv_set with a TTL';
    ASSERT kv_ttl(k5) <= interval '1 hour', 'kv_ttl';
    ASSERT kv_expire(k5, '2 hours') AND kv_persist(k5) AND kv_ttl(k5) = 'infinity', 'expire and persist';
    ASSERT NOT kv_set(k5, 'y', nx => true), 'nx refuses an existing key';
    ASSERT kv_set(k5, 'z', xx => true) AND kv_get(k5) = 'z', 'xx replaces it';

    PERFORM kv_mset(ARRAY[k5 || '1', k5 || '2'], ARRAY['one', 'two']);
    ASSERT kv_mget(ARRAY[k5 || '2', k5 || '3', k5 || '1']) = ARRAY['two', NULL, 'one'], 'kv_mget';
    ASSERT kv_get(k5) = 'z', 'a key and the same key plus a digit are different keys';
END $$;

SELECT kv_flush() \gset
SELECT keys = 0 AS empty_again FROM kv_stats();

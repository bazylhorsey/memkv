\echo Use "CREATE EXTENSION memkv" to load this file. \quit

-- Strings and keys

-- Returns false when nx/xx stopped the write.
CREATE FUNCTION kv_set(key text, value text, ttl interval DEFAULT NULL,
                       nx boolean DEFAULT false, xx boolean DEFAULT false)
RETURNS boolean AS 'MODULE_PATHNAME' LANGUAGE C;

CREATE FUNCTION kv_get(key text) RETURNS text
AS 'MODULE_PATHNAME' LANGUAGE C STRICT;

CREATE FUNCTION kv_del(key text) RETURNS boolean
AS 'MODULE_PATHNAME' LANGUAGE C STRICT;

CREATE FUNCTION kv_exists(key text) RETURNS boolean
AS 'MODULE_PATHNAME' LANGUAGE C STRICT;

CREATE FUNCTION kv_incr(key text, amount bigint DEFAULT 1) RETURNS bigint
AS 'MODULE_PATHNAME' LANGUAGE C STRICT;

CREATE FUNCTION kv_expire(key text, ttl interval) RETURNS boolean
AS 'MODULE_PATHNAME' LANGUAGE C STRICT;

-- 'infinity' when the key has no TTL, NULL when it doesn't exist.
CREATE FUNCTION kv_ttl(key text) RETURNS interval
AS 'MODULE_PATHNAME' LANGUAGE C STRICT;

CREATE FUNCTION kv_persist(key text) RETURNS boolean
AS 'MODULE_PATHNAME' LANGUAGE C STRICT;

CREATE FUNCTION kv_mget(keys text[]) RETURNS text[]
AS 'MODULE_PATHNAME' LANGUAGE C STRICT;

CREATE FUNCTION kv_mset(keys text[], "values" text[], ttl interval DEFAULT NULL)
RETURNS void AS 'MODULE_PATHNAME' LANGUAGE C;

-- Hashes

-- Returns true when the field is new.
CREATE FUNCTION kv_hset(key text, field text, value text) RETURNS boolean
AS 'MODULE_PATHNAME' LANGUAGE C STRICT;

CREATE FUNCTION kv_hget(key text, field text) RETURNS text
AS 'MODULE_PATHNAME' LANGUAGE C STRICT;

CREATE FUNCTION kv_hdel(key text, field text) RETURNS boolean
AS 'MODULE_PATHNAME' LANGUAGE C STRICT;

CREATE FUNCTION kv_hlen(key text) RETURNS bigint
AS 'MODULE_PATHNAME' LANGUAGE C STRICT;

CREATE FUNCTION kv_hincr(key text, field text, amount bigint DEFAULT 1)
RETURNS bigint AS 'MODULE_PATHNAME' LANGUAGE C STRICT;

CREATE FUNCTION kv_hgetall(key text, OUT field text, OUT value text)
RETURNS SETOF record AS 'MODULE_PATHNAME' LANGUAGE C STRICT;

-- Maintenance

CREATE FUNCTION kv_sweep() RETURNS bigint
AS 'MODULE_PATHNAME' LANGUAGE C;

CREATE FUNCTION kv_flush() RETURNS bigint
AS 'MODULE_PATHNAME' LANGUAGE C;

CREATE FUNCTION kv_stats(OUT keys bigint, OUT keys_with_ttl bigint,
                         OUT memory_bytes bigint, OUT max_memory_bytes bigint,
                         OUT hits bigint, OUT misses bigint,
                         OUT evicted bigint, OUT expired bigint)
AS 'MODULE_PATHNAME' LANGUAGE C;

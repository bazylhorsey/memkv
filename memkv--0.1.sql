\echo Use "CREATE EXTENSION memkv" to load this file. \quit

-- Everything lives in the memkv schema. Using it takes USAGE on that schema,
-- which PostgreSQL gives nobody by default. The two functions that read or
-- empty the whole store, flush() and verify(), can only be run by the role that
-- installed the extension; GRANT EXECUTE on them to allow others.

-- Strings and keys

-- Returns false when nx/xx stopped the write.
CREATE FUNCTION set(key text, value text, ttl interval DEFAULT NULL,
                    nx boolean DEFAULT false, xx boolean DEFAULT false)
RETURNS boolean AS 'MODULE_PATHNAME', 'kv_set' LANGUAGE C;

CREATE FUNCTION get(key text) RETURNS text
AS 'MODULE_PATHNAME', 'kv_get' LANGUAGE C STRICT;

CREATE FUNCTION del(key text) RETURNS boolean
AS 'MODULE_PATHNAME', 'kv_del' LANGUAGE C STRICT;

CREATE FUNCTION "exists"(key text) RETURNS boolean
AS 'MODULE_PATHNAME', 'kv_exists' LANGUAGE C STRICT;

CREATE FUNCTION incr(key text, amount bigint DEFAULT 1) RETURNS bigint
AS 'MODULE_PATHNAME', 'kv_incr' LANGUAGE C STRICT;

CREATE FUNCTION expire(key text, ttl interval) RETURNS boolean
AS 'MODULE_PATHNAME', 'kv_expire' LANGUAGE C STRICT;

-- 'infinity' when the key has no TTL, NULL when it doesn't exist.
CREATE FUNCTION ttl(key text) RETURNS interval
AS 'MODULE_PATHNAME', 'kv_ttl' LANGUAGE C STRICT;

CREATE FUNCTION persist(key text) RETURNS boolean
AS 'MODULE_PATHNAME', 'kv_persist' LANGUAGE C STRICT;

CREATE FUNCTION mget(keys text[]) RETURNS text[]
AS 'MODULE_PATHNAME', 'kv_mget' LANGUAGE C STRICT;

CREATE FUNCTION mset(keys text[], "values" text[], ttl interval DEFAULT NULL)
RETURNS void AS 'MODULE_PATHNAME', 'kv_mset' LANGUAGE C;

-- Hashes

-- Returns true when the field is new.
CREATE FUNCTION hset(key text, field text, value text) RETURNS boolean
AS 'MODULE_PATHNAME', 'kv_hset' LANGUAGE C STRICT;

CREATE FUNCTION hget(key text, field text) RETURNS text
AS 'MODULE_PATHNAME', 'kv_hget' LANGUAGE C STRICT;

CREATE FUNCTION hdel(key text, field text) RETURNS boolean
AS 'MODULE_PATHNAME', 'kv_hdel' LANGUAGE C STRICT;

CREATE FUNCTION hlen(key text) RETURNS bigint
AS 'MODULE_PATHNAME', 'kv_hlen' LANGUAGE C STRICT;

CREATE FUNCTION hincr(key text, field text, amount bigint DEFAULT 1)
RETURNS bigint AS 'MODULE_PATHNAME', 'kv_hincr' LANGUAGE C STRICT;

CREATE FUNCTION hgetall(key text, OUT field text, OUT value text)
RETURNS SETOF record AS 'MODULE_PATHNAME', 'kv_hgetall' LANGUAGE C STRICT;

-- Rate limiting: capacity requests per period, refilling smoothly (GCRA).
-- cost is how many requests one call counts for.

-- true when allowed
CREATE FUNCTION rate_limit(key text, capacity bigint, period interval,
                           cost bigint DEFAULT 1)
RETURNS boolean AS 'MODULE_PATHNAME', 'kv_rate_limit' LANGUAGE C STRICT;

-- Everything needed for Retry-After and X-RateLimit-* headers.
CREATE FUNCTION rate_limit_info(key text, capacity bigint, period interval,
                                cost bigint DEFAULT 1,
                                OUT allowed boolean, OUT remaining bigint,
                                OUT retry_after_ms bigint,
                                OUT reset_after_ms bigint)
AS 'MODULE_PATHNAME', 'kv_rate_limit_info' LANGUAGE C STRICT;

-- Maintenance

CREATE FUNCTION sweep() RETURNS bigint
AS 'MODULE_PATHNAME', 'kv_sweep' LANGUAGE C;

CREATE FUNCTION flush() RETURNS bigint
AS 'MODULE_PATHNAME', 'kv_flush' LANGUAGE C;

CREATE FUNCTION stats(OUT keys bigint, OUT keys_with_ttl bigint,
                      OUT memory_bytes bigint, OUT max_memory_bytes bigint,
                      OUT hits bigint, OUT misses bigint,
                      OUT evicted bigint, OUT expired bigint)
AS 'MODULE_PATHNAME', 'kv_stats' LANGUAGE C;

-- One row per inconsistency, none when the store is sound. Run it while
-- nothing is writing: it compares entries with each other.
CREATE FUNCTION verify() RETURNS TABLE (key text, problem text)
AS 'MODULE_PATHNAME', 'kv_verify' LANGUAGE C;

REVOKE ALL ON FUNCTION flush(), verify() FROM PUBLIC;

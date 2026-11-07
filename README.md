# memkv

A Valkey-style key-value store inside PostgreSQL shared memory: strings, counters, hashes, TTLs, LRU
eviction and rate limiting. It needs PostgreSQL 19, and nothing else: no `shared_preload_libraries`, no
restart. The store is created on the first call.

## Try it

With Docker, on the official PostgreSQL 19 release-candidate image:

```sh
docker build -t memkv:19rc1 .
docker run -d --name memkv --shm-size=256m -e POSTGRES_PASSWORD=postgres -p 5432:5432 memkv:19rc1
psql -h localhost -U postgres -c "CREATE EXTENSION memkv" \
     -c "SELECT memkv.set('hello', 'world'), memkv.get('hello')"
```

From source, with PG 19's server dev package (for example `postgresql-server-dev-19`):

```sh
make && sudo make install
```

```sql
CREATE EXTENSION memkv;

SELECT memkv.set('session:42', '{"user": 1}', interval '30 minutes');
SELECT memkv.get('session:42');         -- '{"user": 1}'
SELECT memkv.ttl('session:42');         -- time left
SELECT memkv.incr('views:post:7');      -- 1, 2, 3 …
SELECT memkv.hset('user:1', 'name', 'Ada');
SELECT memkv.hgetall('user:1');

-- 100 requests a minute per API key, refilling smoothly
SELECT memkv.rate_limit('api:' || api_key, 100, interval '1 minute');       -- true / false

-- optional: clear expired keys every minute if you use pg_cron
SELECT cron.schedule('memkv-sweep', '* * * * *', 'SELECT memkv.sweep()');
```

Everything lives in the `memkv` schema. Use it as `memkv.get(...)`, or put the schema on your `search_path`.

## Functions

| Function | Valkey | Notes |
|---|---|---|
| `set(key, value, ttl => NULL, nx => false, xx => false)` | SET [EX] [NX\|XX] | Returns false when `nx`/`xx` stopped the write. Replaces any value, including a hash. |
| `get(key)` | GET | NULL if missing. Errors on a hash. |
| `mget(keys text[])` | MGET | Array of values in key order, NULL for missing keys or hashes. |
| `mset(keys text[], values text[], ttl => NULL)` | MSET | Writes pairs one at a time, so not atomic like Valkey's. |
| `del(key)` | DEL | |
| `exists(key)` | EXISTS | Doesn't count as a use for LRU. |
| `incr(key, amount => 1)` | INCRBY | Keeps an existing TTL. |
| `expire(key, ttl)` | EXPIRE | |
| `ttl(key)` | TTL | Interval left, `'infinity'` with no TTL, NULL if missing. |
| `persist(key)` | PERSIST | True if a TTL was removed. |
| `hset(key, field, value)` | HSET | True if the field is new. Creates the key. |
| `hget(key, field)` | HGET | |
| `hdel(key, field)` | HDEL | Deletes the key when its last field goes. |
| `hlen(key)` | HLEN | |
| `hincr(key, field, amount => 1)` | HINCRBY | |
| `hgetall(key)` | HGETALL | Rows of `(field, value)`. |
| `rate_limit(key, capacity, period, cost => 1)` | | True when allowed. See below. |
| `rate_limit_info(key, capacity, period, cost => 1)` | | `allowed, remaining, retry_after_ms, reset_after_ms`. |
| `sweep()` | | Drops expired keys now; returns how many. |
| `flush()` | FLUSHALL | Owner only, see Access control. |
| `stats()` | INFO / DBSIZE | `keys, keys_with_ttl, memory_bytes, max_memory_bytes, hits, misses, evicted, expired`. Counting keys scans the whole index. |
| `verify()` | | Checks the store's invariants. Owner only. See Checking the store. |

Using a string function on a hash (or the reverse) errors with `wrong_object_type`, like Valkey's WRONGTYPE.
Keys can be any length. Keys and values are text.

Hashes are stored as one compact blob, like Valkey's listpack encoding for small hashes. That makes small
hashes cheap, but every write copies the whole hash, so keep them to a few hundred fields. Hash writes are
optimistic: concurrent writers to the same hash retry rather than block.

## Rate limiting

`rate_limit(key, capacity, period)` lets `capacity` calls through per `period`, refilling smoothly (GCRA, the
algorithm behind a leaky bucket). Bursts up to the capacity are allowed. `cost` is how many requests one call
counts for; a cost larger than the capacity can never pass and is an error.

```sql
SELECT memkv.rate_limit('api:' || api_key, 100, interval '1 minute');            -- true / false

-- everything needed for Retry-After and X-RateLimit-* headers
SELECT * FROM memkv.rate_limit_info('upload:' || user_id, 50, interval '1 hour', cost => 5);
--  allowed | remaining | retry_after_ms | reset_after_ms
```

- The decision is exact: it is made under the key's lock, so any number of sessions on one key together get
  exactly its capacity. The stress test has 32 clients race for 1000 slots and checks that 1000 get through.
- A limiter is one 8-byte value. An absent limiter counts as a full one, and its TTL is the moment it would be
  full again, so idle limiters expire by themselves.
- `retry_after_ms` is 0 when allowed, otherwise how long until this same call would pass. `reset_after_ms` is
  how long until the bucket is full again.
- It is a kind of value like a string or a hash: `get` on it is `wrong_object_type`, and `set` replaces it.
- Under memory pressure a limiter can be evicted like any key, and an evicted limiter starts full.

## Access control

- Using memkv takes `USAGE` on the `memkv` schema. PostgreSQL gives nobody that on a new schema, so grant it:

  ```sql
  GRANT USAGE ON SCHEMA memkv TO app_role;
  ```

- `flush()` empties the whole server's store and `verify()` scans all of it. Both are revoked from `PUBLIC` and
  can be run only by the role that installed the extension. Grant them to others if you want:
  `GRANT EXECUTE ON FUNCTION memkv.flush() TO ...`.

## Settings

| Setting | Default | Meaning |
|---|---|---|
| `memkv.max_memory` | `64MB` | Cap on the shared memory memkv uses: keys, values and the index. |
| `memkv.eviction_policy` | `allkeys-lru` | What happens when the cap is reached: `allkeys-lru`, `volatile-lru` (only keys with a TTL), or `noeviction` (error). |

Both are `SIGHUP` settings: change them with `ALTER SYSTEM` and `SELECT pg_reload_conf()`.

## Eviction

When a write can't get memory, memkv first drops every expired key and retries. If that isn't enough, it
evicts the least recently used keys allowed by the policy and retries again, repeating until the write fits
or nothing evictable is left (then it errors with `memkv is full`). One backend evicts at a time; the others
wait and retry their allocation first, since the evictor may have freed what they need.

- A key's "last used" time is updated by `get`, `set`, `incr` and `expire`.
- Each eviction round scans the index once and evicts the oldest ~1/128 of live keys (at least 1, at most
  4096), doubling each further round within the same write. Evicting a batch at once means a store that stays
  full scans rarely instead of on every write. It does mean a full store usually sits up to ~1% below the cap
  right after an eviction.
- Unlike Valkey's random sampling, the scan sees every key, so the keys evicted really are the oldest ones. A
  key used between the scan and its eviction is skipped.
- A single entry (key and value) at least as large as `memkv.max_memory` is rejected without evicting
  anything. Entries that are a large fraction of the cap may still need much of the store evicted to find
  contiguous space, so keep values small relative to the cap.

## Errors

Every error carries a SQLSTATE, so clients can react without parsing messages:

| SQLSTATE | Condition | When |
|---|---|---|
| `42809` | `wrong_object_type` | the key holds another kind of value: `get` on a hash, `hset` on a string, `rate_limit` on either |
| `22004` | `null_value_not_allowed` | a NULL key or value, or a NULL inside the arrays of `mget` and `mset` |
| `22023` | `invalid_parameter_value` | `nx` and `xx` together; a TTL that isn't positive; a rate limit capacity, period or cost that isn't positive, or a cost over the capacity |
| `22P02` | `invalid_text_representation` | `incr` or `hincr` on a value that is not an integer |
| `22003` | `numeric_value_out_of_range` | `incr` or `hincr` overflow |
| `2202E` | `array_subscript_error` | `mget` or `mset` arrays that aren't one-dimensional, or keys and values of different lengths |
| `54000` | `program_limit_exceeded` | an entry larger than `memkv.max_memory` |
| `53200` | `out_of_memory` | `memkv is full`: nothing is evictable under the policy |
| `XX000` | `internal_error` | `memkv key hash collision`: another live key has the same 128-bit hash |

`test/errors.sql` triggers each one and checks its SQLSTATE.

## Checking the store

`verify()` walks every entry and returns one row `(key, problem)` per inconsistency, and nothing when the store
is sound. It checks that each entry's key still matches its hash, that hashes and rate limiters have the shape
they should, that expiry times and versions make sense, and that no two entries share an allocation. It
compares entries with each other, so run it while nothing is writing, for example at the end of a test:

```sql
SELECT count(*) FROM memkv.verify();    -- 0
```

## Good to know

- **No restart needed:** PG 19 lets an extension get shared memory without reserving it at server start, so you
  don't need `shared_preload_libraries`. The store is created on the first call.
- **One store per server:** Every database with the extension sees the same keys, so prefix keys per app.
- **Not transactional:** `set` inside a transaction that rolls back still happened, like calling Valkey from
  your app.
- **Not durable:** Data is gone when Postgres restarts or crashes, and replicas never see it.
- **Memory:** `memkv.max_memory` caps everything memkv stores: keys, values and the index. A key costs about 90
  bytes of index plus its own bytes and its value, each rounded up to the allocator's size class. Keys can be
  any length. The allocator keeps one 64 KB block per value-size class it has used, so with many different
  sizes up to about 2.3 MB of the cap can sit reserved; that only matters for caps under about 16 MB. A full
  index is handled like full value space: expired keys go first, then eviction.
- **Docker:** Set `--shm-size` above `max_memory`. This memory lives in `/dev/shm`, which defaults to 64MB in
  Docker.

## Tests

Run these against a scratch server. Each prints nothing and exits 0 when it passes:

```sh
for t in keys rate_limit errors access verify; do psql -X -v ON_ERROR_STOP=1 -f test/$t.sql; done
psql -X -v ON_ERROR_STOP=1 -f test/eviction.sql     # shrinks memkv.max_memory to 1MB while it runs
test/stress/run.sh 30 32                            # 32 clients; set MEMKV_TEST_LOG=<server log> on assertion builds
```

`test/commands.sql` is a walk-through of every function with the expected results in its comments.
`test/collision.sql`, and the damage detection in `test/verify.sql`, need a server built with assertions and
skip themselves otherwise. `test/stress/run.sh` has two modes of leak check: on an assertion build it reads
PostgreSQL's allocator dump and requires that a flush leaves only the index's own structures allocated.

## License

PostgreSQL License. See [LICENSE](LICENSE).

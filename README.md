# memkv

A Valkey-style key-value store with TTLs and LRU eviction, kept in PostgreSQL
shared memory. Requires PostgreSQL 19+ (`GetNamedDSA` / `GetNamedDSHash`).

## Build and try it

You need PG 19's server dev package, e.g. `postgresql-server-dev-19`.

```sh
make && sudo make install
```

```sql
CREATE EXTENSION memkv;
SELECT kv_set('greeting', 'hello', '10 seconds');
SELECT kv_get('greeting');   -- hello, then NULL after 10s
SELECT kv_incr('hits');      -- 1, 2, 3 …
SELECT kv_del('greeting');

-- optional: clear expired keys every minute if you use pg_cron
SELECT cron.schedule('memkv-sweep', '* * * * *', 'SELECT kv_sweep()');
```

## Functions

| Function | Valkey | Notes |
|---|---|---|
| `kv_set(key, value, ttl => NULL, nx => false, xx => false)` | SET [EX] [NX\|XX] | Returns false when `nx`/`xx` stopped the write. Replaces any value, including a hash. |
| `kv_get(key)` | GET | NULL if missing. Errors on a hash. |
| `kv_mget(keys text[])` | MGET | Array of values in key order, NULL for missing keys or hashes. |
| `kv_mset(keys text[], values text[], ttl => NULL)` | MSET | Writes pairs one at a time, so not atomic like Valkey's. |
| `kv_del(key)` | DEL | |
| `kv_exists(key)` | EXISTS | Doesn't count as a use for LRU. |
| `kv_incr(key, amount => 1)` | INCRBY | Keeps an existing TTL. |
| `kv_expire(key, ttl)` | EXPIRE | |
| `kv_ttl(key)` | TTL | Interval left, `'infinity'` with no TTL, NULL if missing. |
| `kv_persist(key)` | PERSIST | True if a TTL was removed. |
| `kv_hset(key, field, value)` | HSET | True if the field is new. Creates the key. |
| `kv_hget(key, field)` | HGET | |
| `kv_hdel(key, field)` | HDEL | Deletes the key when its last field goes. |
| `kv_hlen(key)` | HLEN | |
| `kv_hincr(key, field, amount => 1)` | HINCRBY | |
| `kv_hgetall(key)` | HGETALL | Rows of `(field, value)`. |
| `kv_sweep()` | | Drops expired keys now; returns how many. |
| `kv_flush()` | FLUSHALL | |
| `kv_stats()` | INFO / DBSIZE | `keys, keys_with_ttl, memory_bytes, max_memory_bytes, hits, misses, evicted, expired`. Counting keys scans the whole index. |

Using a string function on a hash (or the reverse) errors with
`wrong_object_type`, like Valkey's WRONGTYPE.

Hashes are stored as one compact blob, like Valkey's listpack encoding for
small hashes. That makes small hashes cheap, but every write copies the
whole hash, so keep them to a few hundred fields. Hash writes are
optimistic: concurrent writers to the same hash retry rather than block.

`test/commands.sql` walks through the functions; `test/eviction.sql` exercises eviction against a scratch server (it shrinks
`memkv.max_memory` to 1MB while it runs).

## Settings

| Setting | Default | Meaning |
|---|---|---|
| `memkv.max_memory` | `64MB` | Approximate cap on value storage. |
| `memkv.eviction_policy` | `allkeys-lru` | What happens when the cap is reached: `allkeys-lru`, `volatile-lru` (only keys with a TTL), or `noeviction` (error). |

Both are `SIGHUP` settings: change them with `ALTER SYSTEM` and
`SELECT pg_reload_conf()`.

## Eviction

When a write can't get memory, memkv first drops every expired key and
retries. If that isn't enough, it evicts the least recently used keys
allowed by the policy and retries again, repeating until the value fits
or nothing evictable is left (then it errors with `memkv is full`).

- A key's "last used" time is updated by `kv_get`, `kv_set`, `kv_incr`
  and `kv_expire`.
- Each eviction round scans the index once and evicts the oldest ~1/128 of
  live keys (at least 1, at most 4096), doubling each further round within
  the same write. Evicting a batch at once means a store that stays full
  scans rarely instead of on every write. It does mean a full store
  usually sits up to ~1% below the cap right after an eviction.
- Unlike Valkey's random sampling, the scan sees every key, so the keys
  evicted really are the oldest ones. A key used between the scan and its
  eviction is skipped.
- A single value at least as large as `memkv.max_memory` is rejected
  without evicting anything. Values that are a large fraction of the cap
  may still need much of the store evicted to find contiguous space, so
  keep values small relative to the cap.

## Good to know

- **No restart needed:** PG 19 lets an extension get shared memory without
  reserving it at server start, so you don't need
  `shared_preload_libraries`. The store is created on the first call.
- **One store per server:** Every database with the extension sees the same
  keys. Any role that can call the functions can read or overwrite any key,
  so prefix keys per app, and `REVOKE EXECUTE … FROM PUBLIC` if other apps
  share the server.
- **Not durable:** Data is gone when Postgres restarts or crashes, and
  replicas never see it.
- **Memory:** `memkv.max_memory` caps value storage only. Each key also
  costs about 200 bytes of index, which is not capped, and keys can be at
  most 127 bytes.
- **Docker:** Set `--shm-size` above `max_memory`. This memory lives in
  `/dev/shm`, which defaults to 64MB in Docker.

## License

PostgreSQL License. See [LICENSE](LICENSE).

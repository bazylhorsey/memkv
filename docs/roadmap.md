# memkv roadmap: what to build to compete

Nov 6, 2026 · @Bazyl Horsey

## Verdict

Don't chase Valkey parity. Make memkv the best answer to one question: "I already run Postgres; do I really need Redis for caching, locks, rate limits and counters?" That market is the "just use Postgres" crowd, and today their options are UNLOGGED tables (slow under updates, they bloat, no TTL) or running Valkey anyway.

memkv wins that market on four things, in this order:

1. **Zero ops.** PG 19 lets it work without `shared_preload_libraries` or a restart. Few extensions can say that, so protect it.
2. **Postgres-native correctness that Redis can't offer.** An opt-in transactional mode means a rolled-back transaction never leaves stale cache entries behind.
3. **Predictable memory.** One cap that covers everything, with eviction that never errors in cache mode.
4. **Fast enough.** Clearly faster than an UNLOGGED table on hot reads and counters, shown with published benchmarks.

Everything below serves one of those four. Anything that doesn't, such as persistence, clustering or pub/sub, is on the skip list.

## Phase 0: prove it before building more

Nothing has run on PG 19 yet, and the whole pitch rests on speed. Do this first.

1. Build on PG 19 and run `test/commands.sql` and `test/eviction.sql`.
2. Add a concurrency stress test: many pgbench clients doing mixed get, set, incr and hset on overlapping keys while the store is full. It should catch lock bugs, leaks (memory that keeps climbing after `kv_flush()`) and lost hash updates.
3. Benchmark with pgbench against an UNLOGGED table (`INSERT ... ON CONFLICT` and `SELECT`) and against Valkey from the same app server. Measure ops/sec and p99 latency at 1, 16 and 64 clients.

**Gate:** if memkv isn't at least about 2x faster than an UNLOGGED table on gets and increments at 16+ clients, the speed claim is gone. Then reposition around TTL, eviction and no bloat, or stop.

## Phase 1: fix the design before the first release

These change memory layout or default behaviour, so they're cheap now and painful once people depend on 0.1.

| Change | Why it matters | Cost |
| --- | --- | --- |
| **Hashed keys** (16-byte hash in the index, full key next to the value) | Any key length, and index cost drops from \~200 to \~90 bytes per key | Medium |
| **One real memory cap** (build the index inside memkv's own DSA, with no-OOM inserts) | `max_memory` then covers keys and index too, and a full index evicts instead of failing | Medium |
| **Per-database scope by default** (database OID folded into the key hash) | Two apps on one server can't read each other's keys by accident, which managed hosts will require | Small once keys are hashed |
| **No shared hot counters** (per-backend stats slots, version built from the backend number plus a local counter) | Today every get bumps one shared atomic, which caps throughput at high core counts | Small |
| **`bytea` values** (`kv_set`/`kv_get` overloads) | Binary data, serialized objects and compressed payloads | Small |

Do hashed keys and the real memory cap together, since both rework the index.

## Phase 2: build what Valkey can't do

This is where memkv stops being "Redis but slower" and becomes the better choice.

1. **Transactional mode** (`memkv.transactional`, per session, off by default). Writes are buffered and applied at commit, and discarded on rollback. That fixes cache-aside's classic bug, where a rolled-back transaction leaves a cache entry for data that never existed. Redis can't offer this because it can't see your transaction.
2. **`kv_ratelimit(key, limit, per interval)`**, a GCRA limiter done in one call that returns allowed or denied plus the retry time. Rate limiting is the top reason people add Redis, and in Redis it takes Lua or a sorted set. Here it's one function and one stored integer.
3. **Safe locks**: `kv_del_if(key, value)` and `kv_set_if(key, expected, new)` for compare-and-swap. With `kv_set(..., nx => true)` and a TTL, that covers correct distributed locks. Redis needs a Lua script to release a lock safely.
4. **MSET all-or-nothing on errors, plus `kv_hmset`** for groups that must change together, as discussed earlier.

Items 1 to 4 are small and turn common Redis use cases into a single SQL call. Next comes the big one.

**5. Sorted sets** (`kv_zadd`, `kv_zscore`, `kv_zrange`, `kv_zrank`, `kv_zrem`, `kv_zincr`). Small sets are stored as a sorted blob with binary search, and sets past a size threshold move to a skiplist in shared memory, the same split Valkey uses. This is the primitive behind leaderboards, sliding windows, delayed jobs and time indexes. It's about 5x the work of hashes.

## Phase 3: background expiry and distribution

1. **Background expiry.** A dynamic background worker started on first use, so it still needs no preload. It sweeps expired keys every `memkv.sweep_interval` and drops the pg\_cron dependency, so memory doesn't fill with dead keys.
2. **Packaging.** Publish on PGXN with a `META.json`, then get into the PGDG apt and yum repos so it's one `apt install`.
3. **Managed-host readiness.** Once per-database scope exists, mark the extension `trusted` so non-superusers can `CREATE EXTENSION`. Then pitch it to providers (Supabase, Neon, Crunchy, Tembo-style platforms). Being installable where people already host Postgres matters more than any single feature.
4. **Docs that sell it.** A "replace Redis for X" page for each use case (cache, sessions, locks, rate limits, counters) with the benchmark numbers from Phase 0.

## Recommended defaults

Defaults should make the common case, a cache, safe without tuning.

| Setting | Default | Reason |
| --- | --- | --- |
| `memkv.max_memory` | `64MB` | Fits Docker's default `/dev/shm` with room to spare. Once the cap covers the index, it's the only memory knob people need. |
| `memkv.eviction_policy` | `allkeys-lru` | A cache should forget, not error. Keep `volatile-lru` and `noeviction` for people using memkv as a store. |
| `memkv.scope` (new) | `database` | Safe on shared and managed servers. `server` is opt-in for cross-database sharing. |
| `memkv.transactional` (new) | `off`, settable per session | Matches what Redis users expect and is fastest. Turn it on in sessions that write cache entries inside transactions. |
| `memkv.sweep_interval` (new) | `10s` | Keeps dead keys from piling up. `0` turns the worker off. |
| Key length | Unlimited, once keys are hashed | Removes the most arbitrary limit. |

Skip an LFU policy until someone asks. LRU with exact oldest-first selection is already better than Valkey's sampled LRU for most caches.

## What not to build

Each of these either already exists in Postgres or would pull memkv into a fight with Valkey that it loses.

| Skip | Why |
| --- | --- |
| Persistence (snapshots, AOF) | If data must survive a restart, it belongs in a table. Durability blurs the pitch and adds failure modes. |
| Replication and cluster mode | Replicas can't write shared memory on the primary, and a cluster is Valkey's home turf. |
| Pub/sub and keyspace notifications | `LISTEN`/`NOTIFY` already exists. At most, document the pattern. |
| Lua scripting | PL/pgSQL, plus transactional mode, already does it better. |
| Streams and lists as queues | pgmq and `SKIP LOCKED` tables are durable and already won that niche. |
| A Redis wire-protocol (RESP) listener | Managed hosts won't open the port, and it would compete with Valkey on its own terms. |
| Sorted sets, for now | Not skipped: moved into Phase 2 as item 5, after the small items. |

The test for any future feature: does it remove a reason to run Redis next to Postgres, without asking people to change how they run Postgres?

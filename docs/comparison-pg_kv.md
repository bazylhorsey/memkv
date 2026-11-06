# memkv vs Murat7Ay/pg\_kv

Nov 6, 2026 · @Bazyl Horsey

## Bottom line

Murat7Ay/pg\_kv is a direct competitor with our exact pitch ("just use Postgres instead of Redis"), already shipped as v0.1.0 on 2026-10-19 with Docker images, CI on PG 15 to 18, benchmarks and a .NET client. It already has the two Phase 2 items we picked next: rate limiting and sorted sets.

Our real differentiators are PG 19 only: no `shared_preload_libraries`, memory that grows to a byte cap instead of fixed slots, hashes, NX/XX, MGET/MSET and policy-based LRU. Those are exactly what pg\_kv lists as its own next steps, so the window is short.

Recommendation: stop leading with "Redis in Postgres" and lead with "no preload, no restart, variable-size memory". Pull Phase 0 (build, test and benchmark on PG 19) forward, since they have numbers and we have never run our code.

## Side by side

|  | memkv (ours) | [Murat7Ay/pg\_kv](https://github.com/Murat7Ay/pg_kv) |
| --- | --- | --- |
| Language | C, \~1,500 lines | Rust on pgrx 0.19, \~2,000 lines |
| PG versions | 19 only, never built or run yet | 15, 16, 17, 18 in CI; 19 not supported |
| Preload needed | No: `GetNamedDSA` / `GetNamedDSHash` on first call | Yes: `CREATE EXTENSION` fails without it |
| Memory model | DSA, variable-size values, capped by `memkv.max_memory` (index not capped) | Fixed slots: `max_entries x (key + value + 40 B)`, preallocated at start |
| Limits | Keys up to 127 B, values bounded by cap | Keys 128 B, values 512 B, zset members 64 B by default |
| Strings | set (TTL, NX, XX), get, del, exists, incr, expire, ttl, persist, mget, mset | set (TTL), get, del, incr, expire, ttl |
| Hashes | hset, hget, hdel, hlen, hincr, hgetall | None |
| Rate limiting | None (planned, GCRA) | `rate_limit`, `rate_limit_info` (token bucket, Retry-After fields) |
| Sorted sets | None (planned) | zadd, zincrby, zscore, zrank, zrevrank, zrange, zcard, zrem (treap, O(log n) rank) |
| Locking | dshash partition locks; optimistic retries for hash writes | 64 LWLock shards; one global lock for all sorted sets |
| Eviction | Full-scan exact LRU in batches; allkeys-lru, volatile-lru, noeviction | Sampled LRU (16 samples) per full shard; no policy setting |
| Expiry | Lazy on read, plus `kv_sweep()` (pg\_cron) | Lazy on read, plus a background sweeper worker every 1 s |
| Settings | SIGHUP, changeable without restart | All restart-only |
| Durability, replication | None | None |
| Errors | `wrong_object_type` for WRONGTYPE | Documented SQLSTATE per error case |
| Access control | Functions in public schema, PUBLIC can call | `kv` schema needs explicit `USAGE` grant; flush and verify owner-only |
| Tests | Two manual SQL scripts; compile check against PG 16 headers | Functional, randomized vs SQL ground truth, 32-client stress + `kv.verify()`, rate-limit exactness, tiny-limits eviction |
| Packaging | Makefile only | GHCR images per PG major, Docker Compose, NuGet client packages |
| Benchmarks | None | vs UNLOGGED and Redis 8.10; 3 to 7x cheaper server-side than UNLOGGED |
| License | PostgreSQL License | PostgreSQL License |
| Maturity | Unreleased, no repo pushed | v0.1.0, 9 commits all on 2026-10-19, author says not production ready |

## Where the designs differ

- **Memory.** pg\_kv trades memory for predictability: every slot is sized for the largest key and value, so 200k entries with small values cost 108 MB in their own benchmark. Values over 512 B are refused unless you restart with a bigger limit. memkv stores what you write, which is better for mixed sizes, but our \~200 B per-key index is outside the cap. They list slab classes as their next step.
- **Eviction.** Their sampled LRU is cheap per write and local to one shard. Our full scan picks truly oldest keys and batches 1/128 of the store, but a scan over millions of keys while a writer waits is the risk to measure.
- **Expiry.** Their background sweeper reclaims idle keys even when nobody calls anything. We depend on lazy expiry, eviction, or the user scheduling `kv_sweep()`.
- **Rate limiter.** Token bucket stored as a normal key whose TTL is the moment it would be full again, so an absent bucket means full and idle buckets expire on their own. It returns `allowed, remaining, retry_after_ms, reset_after_ms` for HTTP headers. Their test shows 16 clients get exactly the capacity.
- **Sorted sets.** Treap with subtree sizes in a shared node pool, plus an index from (set, member) to node. All sets share one lock, which they flag as a bottleneck. The pool is a fixed global member count.
- **Setup.** Preload is their biggest friction point: it needs a restart and a config change, which managed Postgres users often can't do. That is our strongest point, and they note PG 17's DSM registry as a possible no-preload mode later.

## What to borrow

1. **Their test strategy.** A `kv_verify()` that checks every invariant, a concurrent stress run followed by verify, randomized ops compared to a plain SQL table, and a tiny-limits server that runs under constant eviction. We have none of this, and our optimistic hash writes and batch eviction are the parts most likely to break under load.
2. **The benchmark shape.** Server-side ns per op with no network (one statement plus commit), throughput vs UNLOGGED in interleaved rounds, and dead tuples after the run. Dead-tuple counts make the case better than ops/s.
3. **Token bucket with TTL equal to refill time.** Simpler to explain than GCRA and gives `retry_after` for free. Either works; copy the result columns and the exactness test.
4. **A background sweeper option.** A small bgworker for expiry so users don't need pg\_cron. On PG 19 we can register a dynamic worker without preload.
5. **Documented SQLSTATEs** for every error, so clients can map them to typed exceptions.
6. **Secure by default.** Put functions in their own schema, require a grant, and make flush owner-only. Today any role can flush our whole store.
7. **A Docker image** with the extension ready, since PG 19 packages are scarce and that is our main adoption barrier.

## Roadmap and positioning changes

**Positioning.** "Postgres teams don't need Redis" is now their headline too, and they got there first. Ours becomes: *the Redis-style cache for Postgres 19 that needs no preload, no restart, and stores values of any size.* For PG 15 to 18 users, point them at pg\_kv honestly rather than compete.

**Roadmap changes:**

- **Phase 0 moves up and grows.** Build on PG 19, then add `kv_verify()`, a stress test and a benchmark against pg\_kv on PG 18 as well as UNLOGGED and Valkey. Without numbers, pg\_kv wins every comparison by default.
- **Rate limiting stays first in Phase 2,** but match their API (`allowed, remaining, retry_after, reset_after`, cost argument) so switching is easy.
- **Sorted sets stay, with a twist.** Per-set locking instead of one global lock, and no fixed member pool, so we beat their stated weak spot.
- **Add to Phase 1:** own schema with grants, owner-only flush, SQLSTATE table, cap the index inside `max_memory`.
- **Add to Phase 3:** optional built-in sweeper worker, Docker image.
- **Unchanged:** skip persistence, cluster, pub/sub and Lua. They skip the same things.

**Naming clash.** Their extension is `pg_kv`, with `kv.*` functions, a GHCR image and NuGet packages named PgKv. Your repo is also called pg\_kv (I could not reach bazylhorsey/pg\_kv from here, so I could not check whether it is public). Two public projects called pg\_kv would confuse PGXN, packagers and search. I suggest naming the repo and package **memkv** to match the extension. Our `kv_*` function names don't clash with their `kv.*` schema, but would if both were installed and we moved ours into a `kv` schema, so pick a different schema name such as `memkv`.

## Sources

- [Murat7Ay/pg\_kv](https://github.com/Murat7Ay/pg_kv): README, CHANGELOG, src/, test/, bench/results, read 2026-11-06 at commit 2941f47
- memkv working copy in project files (memkv.c, README.md, memkv--0.1.sql)

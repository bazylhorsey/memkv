# memkv Phase 0 results

Nov 5, 2026

## Verdict

memkv builds and runs on PostgreSQL 19 RC1 with no `shared_preload_libraries`. It passes both SQL scripts, and a 30-second, 32-client stress run over every function found no lost updates, no leaks and no crashes. The stress run found one real problem, memory stranded after `kv_flush()`, and the fix is one line.

**The speed gate fails as written.** At 16 and 64 clients, a get or an increment runs only 1.05x to 1.26x faster than an UNLOGGED table. The roadmap asks for about 2x. The engine is not the reason: a memkv get costs about 90 ns against 1.2 to 1.7 µs for a table lookup, and an increment about 85 ns against 4 µs. But a Postgres statement costs about 10 µs before it does any work, and that cost is the same for both. One operation per statement hides the difference.

Where memkv does clear 2x: batches (4x to 5x with 100 lookups per statement), calls from inside functions and triggers (7x to 49x per operation), and p50 write latency at 64 clients (2x to 3x lower). Tables also bloat under updates and memkv does not.

## Setup

- Apple M5, 10 cores, 16 GB, macOS. Postgres 19rc1 built from the release tarball, once with assertions (`--enable-cassert`, -O1) for correctness tests and once with -O2 and no assertions for benchmarks. Both are private builds; nothing is installed system-wide.
- Scratch clusters on a unix socket only. `shared_preload_libraries` empty. Benchmark server: `shared_buffers=512MB`, `memkv.max_memory=256MB`.
- 100,000 keys, 100-byte values, text keys on both sides. `pgbench -M prepared`, 15 s per cell after a 3 s warm-up, p50 and p99 from a 10% sample of per-transaction latencies.
- The table is `UNLOGGED`, `k text PRIMARY KEY`, everything in shared buffers, default autovacuum. Increments use `INSERT .. ON CONFLICT DO UPDATE` on a `bigint` column. Table writes were run with `synchronous_commit` on and off.

## Correctness

- **Build.** Zero warnings with Postgres's own flags (`-Wall -Wmissing-prototypes -Werror=vla` and the rest) on both builds. The PG 19 RC1 signatures of `GetNamedDSMSegment`, `GetNamedDSA`, `GetNamedDSHash` and the `dshash` calls match the code.
- **No preload.** `CREATE EXTENSION memkv` and every function work on a server started with an empty `shared_preload_libraries` and no restart.
- **`test/commands.sql`.** Every result matches the expected value in its comment, including the hit and miss counters in `kv_stats()`.
- **`test/eviction.sql`.** Failed on its first run (see the bug below), passes in full after the fix, run straight after `commands.sql`.
- **Stress (`test/stress/run.sh 30 32`, assertion build).** 32 clients doing `kv_incr` 5,000 times each: counters sum to exactly 160,000. Same for `kv_hincr` on one hash, which is the optimistic retry path: exactly 160,000. 16 clients adding unique fields to one hash: all 1,600 present. Then 30 s of every function at once on an 8 MB store (about 4.1 million statements, 426,482 evictions, 163,297 expirations): no errors, no assertion failures or crashes in the server log.
- **Leak check.** Fill an 8 MB store with 1000-byte values, count how many fit, run all the workloads above, flush, count again: 7,857 keys before and 7,857 after, on three repeats. A leaked allocation would pin a 64 KB superblock and show up as at least 64 missing keys.

## The bug: `kv_flush()` stranded memory

PostgreSQL's DSA keeps one empty superblock (64 KB) for every value-size class that has ever been used, and never returns it (`dsa_free`, dsa.c:933). `kv_flush()` freed the values but left those superblocks, so the memory under `max_memory` that a flushed store could actually use depended on what had been stored before:

| other value sizes used before `kv_flush()` | 1 KB values that fit in a 1 MB store |
| --- | --- |
| 0 | 955 (91%) |
| 4 | 700 (67%) |
| 8 | 512 (49%) |
| 16 | 256 (24%) |

That is why `eviction.sql` showed 446 live keys instead of 700 to 900 right after `commands.sql`, then ran out of room in section 3. `dsa_trim()` returns exactly those superblocks, so `kv_flush()` now calls it. A fresh store holds 91% to 96% of the cap for 1 KB values at 1 MB and up, 80% to 88% for 100 B and 10 KB values, so the cap is a good predictor once it is above a few MB. In an early run, 8 s of mixed traffic on an 8 MB cap left 6,450 of 7,857 keys usable after a flush (18% lost) until the fix.

The flush fix doesn't cover normal operation. While the store is running, each size class that has ever been used can still keep one 64 KB superblock. There are 36 size classes up to 8 KB, so at most about 2.3 MB stays reserved. That is 3.6% of the default 64 MB cap, and only matters for caps under about 16 MB. Values over 8 KB take whole pages and keep nothing.

The same read of the Postgres source confirms the roadmap's Phase 1 point on memory: `GetNamedDSHash()` creates its own private DSA for the index and does not hand it back, so `dsa_set_size_limit()` can't cover the index. A single cap means creating the hash table with `dshash_create()` inside memkv's own DSA.

## Speed through the protocol

One operation per statement unless noted. "Table" is sync commit / async commit for writes.

| Workload | Clients | memkv ops/s | Table ops/s | memkv vs table | memkv p99 µs | Table p99 µs |
| --- | --- | --- | --- | --- | --- | --- |
| get | 16 | 274,121 | 253,392 | 1.08x | 157 | 171 |
| incr | 16 | 263,585 | 250,153 / 228,643 | 1.05x / 1.15x | 162 | 221 / 360 |
| incr, 16 hot keys | 16 | 254,290 | 210,958 / 203,483 | 1.21x / 1.25x | 181 | 420 / 451 |
| set | 16 | 262,359 | 229,560 / 244,001 | 1.14x / 1.08x | 188 | 310 / 208 |
| mget, 100 keys | 16 | 109,706 | 27,019 | **4.06x** | 911 | 2,937 |
| get | 64 | 375,682 | 312,000 | 1.20x | 1,004 | 1,308 |
| incr | 64 | 276,550 | 219,982 / 231,298 | 1.26x / 1.20x | 1,465 | 818 / 1,008 |
| incr, 16 hot keys | 64 | 250,665 | 201,121 / 195,223 | 1.25x / 1.28x | 1,653 | 1,802 / 1,661 |
| set | 64 | 248,404 | 208,837 / 213,647 | 1.19x / 1.16x | 1,632 | 1,768 / 2,013 |
| mget, 100 keys | 64 | 131,518 | 26,618 | **4.94x** | 1,598 | 39,165 |
| get | 1 | 102,250 | 84,003 | 1.22x | 11 | 14 |
| incr | 1 | 100,915 | 58,490 / 60,896 | 1.73x / 1.66x | 11 | 22 / 19 |
| set | 1 | 100,867 | 66,330 / 66,248 | 1.52x / 1.52x | 12 | 17 / 17 |
| mget, 100 keys | 1 | 28,506 | 12,546 | 2.27x | 39 | 86 |

At 64 clients p50 for writes is 67 to 75 µs in memkv and 142 to 225 µs in the table. p99 is much closer and not consistently in memkv's favour: at 64 clients the table is better on `incr` (818 µs against 1,465 µs).

**Gate:** "if memkv isn't at least about 2x faster than an UNLOGGED table on gets and increments at 16+ clients, the speed claim is gone." Result: 1.08x and 1.05x at 16 clients, 1.20x and 1.26x at 64. Not met.

## Why: the cost of the operation itself

Timed loops inside one PL/pgSQL block (`bench/serverside.sql`): no protocol, no per-statement overhead from the client, no commit. Nanoseconds per operation, two rounds:

| Operation | memkv | UNLOGGED table | Ratio |
| --- | --- | --- | --- |
| get | 76 to 96 | 1,210 to 1,665 | 13x to 22x |
| incr | 80 to 86 | 3,916 to 4,197 | 49x |
| set | 512 to 517 | 3,741 to 4,088 | 7x to 8x |

At one client a memkv statement takes 10 µs for a get and 10 µs for an increment, and the table takes 12 µs and 16 to 17 µs. So about 9 to 10 µs is statement overhead that neither side can avoid, and with every core busy at 16 clients that overhead is what sets throughput.

## Against Valkey

Valkey 9.1.3 in a Docker container, driven by its own `valkey-benchmark` over loopback TCP from inside the container, one request in flight per client (`bench/valkey.sh`). Docker on a Mac runs in a Linux VM, so this is rougher than the Postgres runs.

| Clients | Valkey get / incr / set ops/s | Valkey p99 µs (get) | memkv get / incr / set vs Valkey |
| --- | --- | --- | --- |
| 1 | 39,238 / 38,855 / 38,577 | 31 | 2.6x / 2.6x / 2.6x |
| 16 | 285,089 / 285,116 / 266,086 | 87 | 0.96x / 0.92x / 0.99x |
| 64 | 374,156 / 374,906 / 362,865 | 263 | 1.00x / 0.74x / 0.68x |

## Bloat

Dead tuples left in the tables at the end of a run, with autovacuum running: `bench_kv` 7,275 (1 client), 29,445 (16), 41,863 (64) on 100,000 live rows; `bench_ctr` 3, 0 and 7,739. memkv has no equivalent.

## Caveats

- One machine, one round per cell. The Mac was not idle: load average was 6 to 9 on 10 cores and `photoanalysisd` was using about one core just before the runs. The ratios for single-operation statements are far from the 2x gate, so noise doesn't change the verdict, but treat second digits loosely.
- pgbench shares the 10 cores with the server.
- macOS's default `wal_sync_method` (`open_datasync`) does not do a full flush to the drive, so synchronous commits are cheap here. On a Linux server with a real flush the table's `synchronous_commit=on` numbers would be worse, and the write ratios would grow.
- Valkey ran in a VM, the Postgres runs did not.

## Not done

- A benchmark against Murat7Ay/pg_kv on PG 18. It needs a Rust and pgrx build and a PG 18 server with preload.
- `kv_verify()` and the randomized comparison against a plain SQL table from `comparison-pg_kv.md`. The stress run checks exact counts instead.
- Linux numbers.

## Reproduce

Build a PG 19 server, then `make install PG_CONFIG=/path/to/pg_config`, then against a scratch server:

```sh
psql -X -f test/commands.sql
psql -X -v ON_ERROR_STOP=1 -f test/eviction.sql
test/stress/run.sh 30 32            # set MEMKV_TEST_LOG=<server log> to scan it
bench/run.sh 15 "1 16 64"
psql -X -f bench/serverside.sql
bench/valkey.sh 15 "1 16 64"        # needs Docker
```

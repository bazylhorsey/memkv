/*
 * memkv.c - Valkey-style key-value store in PostgreSQL shared memory.
 * Requires PostgreSQL 19+ (GetNamedDSA / GetNamedDSMSegment with an arg).
 *
 * Copyright (c) 2026, Bazyl Horsey. PostgreSQL License; see LICENSE.
 *
 * Keys hold either a string or a hash (field -> value map). When the store is
 * full, memkv drops expired keys first and then evicts least-recently-used
 * keys (see memkv.eviction_policy).
 *
 * Everything lives in one DSA, so memkv.max_memory caps all of it. The index
 * is a dshash table keyed by a 128-bit hash of the key, and each entry points
 * at one allocation holding the key bytes followed by the value bytes. The
 * full key is compared on every lookup, so a hash collision can never return
 * or overwrite another key's value.
 */
#include "postgres.h"

#include <limits.h>

#include "access/htup_details.h"
#include "catalog/pg_type.h"
#include "common/hashfn.h"
#include "common/int.h"
#include "fmgr.h"
#include "funcapi.h"
#include "lib/dshash.h"
#include "lib/stringinfo.h"
#include "miscadmin.h"
#include "port/atomics.h"
#include "storage/dsm_registry.h"
#include "storage/lwlock.h"
#include "utils/array.h"
#include "utils/builtins.h"
#include "utils/dsa.h"
#include "utils/guc.h"
#include "utils/timestamp.h"
#include "utils/tuplestore.h"

PG_MODULE_MAGIC;

#define KV_NEVER    PG_INT64_MAX    /* expires_at for keys with no TTL */
#define KV_INT_BUF  32              /* room for any int64 as text */

/*
 * Eviction tuning. Each eviction round scans the whole index once and
 * evicts about 1/128 of the live keys (at least one), oldest first. Later
 * rounds within the same allocation double that, so a large value that
 * needs many small ones gone doesn't take hundreds of scans.
 */
#define KV_EVICT_SHIFT      7       /* evict nlive >> 7 per round */
#define KV_EVICT_MAX        4096    /* at most this many keys per round */
#define KV_EVICT_STALLS     8       /* give up after this many empty rounds */

typedef enum KVEvictionPolicy
{
    KV_EVICT_NONE,                  /* error when full (after dropping expired) */
    KV_EVICT_ALLKEYS_LRU,           /* evict any key, least recently used first */
    KV_EVICT_VOLATILE_LRU           /* evict only keys that have a TTL */
} KVEvictionPolicy;

static const struct config_enum_entry kv_eviction_options[] = {
    {"noeviction", KV_EVICT_NONE, false},
    {"allkeys-lru", KV_EVICT_ALLKEYS_LRU, false},
    {"volatile-lru", KV_EVICT_VOLATILE_LRU, false},
    {NULL, 0, false}
};

typedef enum KVType
{
    KV_STRING = 0,
    KV_HASH = 1,
    KV_BUCKET = 2                   /* a rate limiter: one int64, see below */
} KVType;

/*
 * The index key: a 128-bit hash of the key bytes, seeded per store. The full
 * key is kept next to the value and compared on every lookup.
 */
typedef struct KVHash
{
    uint64      w[2];
} KVHash;

/* A key as the caller gave it, plus its hash. The bytes belong to the caller. */
typedef struct KVKey
{
    KVHash      hash;
    const char *data;
    Size        len;
} KVKey;

typedef struct KVEntry
{
    KVHash      hash;               /* hash key: must be first */
    dsa_pointer data;               /* key bytes, then value bytes, in kv_dsa */
    uint32      klen;               /* length of the key at the start of data */
    uint32      len;                /* length of the value after the key */
    uint32      vcap;               /* bytes allocated for the value (>= len) */
    uint8       type;               /* KVType */
    TimestampTz expires_at;
    uint64      version;            /* changes whenever value changes */
    pg_atomic_uint64 atime;         /* last access; written under a shared lock */
} KVEntry;

/* Server-wide state, in a small named DSM segment. */
typedef struct KVShared
{
    pg_atomic_uint64 hits;
    pg_atomic_uint64 misses;
    pg_atomic_uint64 evicted;
    pg_atomic_uint64 expired;
    pg_atomic_uint64 version;       /* source of KVEntry.version */
    uint64      hash_seed;          /* random, so nobody can craft collisions */
    dshash_table_handle index_handle;   /* the index, which lives in kv_dsa */
    int         index_tranche;      /* its LWLock tranche */
    LWLock      reclaim_lock;       /* one backend at a time frees memory */
} KVShared;

/* An eviction candidate, copied out of the index during a scan. */
typedef struct KVCandidate
{
    TimestampTz atime;
    KVHash      hash;
} KVCandidate;

/* The key is already a good hash, so some of its bits will do for dshash. */
static dshash_hash
kv_dshash_hash(const void *v, size_t size, void *arg)
{
    uint32      h;

    memcpy(&h, v, sizeof(h));
    return h;
}

static const dshash_parameters kv_params = {
    .key_size = sizeof(KVHash),
    .entry_size = sizeof(KVEntry),
    .compare_function = dshash_memcmp,
    .hash_function = kv_dshash_hash,
    .copy_function = dshash_memcpy,
    /* tranche_id comes from KVShared.index_tranche */
};

static dsa_area *kv_dsa = NULL;         /* keys, values and the index */
static dshash_table *kv_hash = NULL;    /* key index */
static KVShared *kv_shared = NULL;      /* counters, seed, index handle */
static int  kv_max_memory_mb = 64;
static int  kv_eviction_policy = KV_EVICT_ALLKEYS_LRU;
static int  kv_applied_mb = -1;
#ifdef USE_ASSERT_CHECKING
static bool kv_test_weak_hash = false;  /* test only: see _PG_init */
#endif

PG_FUNCTION_INFO_V1(kv_set);
PG_FUNCTION_INFO_V1(kv_get);
PG_FUNCTION_INFO_V1(kv_del);
PG_FUNCTION_INFO_V1(kv_exists);
PG_FUNCTION_INFO_V1(kv_incr);
PG_FUNCTION_INFO_V1(kv_expire);
PG_FUNCTION_INFO_V1(kv_ttl);
PG_FUNCTION_INFO_V1(kv_persist);
PG_FUNCTION_INFO_V1(kv_mget);
PG_FUNCTION_INFO_V1(kv_mset);
PG_FUNCTION_INFO_V1(kv_hset);
PG_FUNCTION_INFO_V1(kv_hget);
PG_FUNCTION_INFO_V1(kv_hdel);
PG_FUNCTION_INFO_V1(kv_hlen);
PG_FUNCTION_INFO_V1(kv_hincr);
PG_FUNCTION_INFO_V1(kv_hgetall);
PG_FUNCTION_INFO_V1(kv_sweep);
PG_FUNCTION_INFO_V1(kv_flush);
PG_FUNCTION_INFO_V1(kv_stats);
PG_FUNCTION_INFO_V1(kv_rate_limit);
PG_FUNCTION_INFO_V1(kv_rate_limit_info);
PG_FUNCTION_INFO_V1(kv_verify);

void
_PG_init(void)
{
    DefineCustomIntVariable("memkv.max_memory",
                            "Cap on the shared memory memkv uses for keys, values and index.",
                            NULL, &kv_max_memory_mb,
                            64, 1, INT_MAX,
                            PGC_SIGHUP, GUC_UNIT_MB,
                            NULL, NULL, NULL);
    DefineCustomEnumVariable("memkv.eviction_policy",
                             "What memkv does when memkv.max_memory is reached.",
                             "noeviction errors, allkeys-lru evicts the least "
                             "recently used keys, volatile-lru evicts only "
                             "keys that have a TTL.",
                             &kv_eviction_policy,
                             KV_EVICT_ALLKEYS_LRU, kv_eviction_options,
                             PGC_SIGHUP, 0,
                             NULL, NULL, NULL);
#ifdef USE_ASSERT_CHECKING
    /*
     * Cut every key hash to one bit so that keys collide, to test collision
     * handling. Only exists in assertion builds. Flush the store before and
     * after changing it: entries made under another hash can't be found.
     */
    DefineCustomBoolVariable("memkv.test_weak_hash",
                             "Test only: keep one bit of each key hash.",
                             NULL, &kv_test_weak_hash, false,
                             PGC_SIGHUP, GUC_NOT_IN_SAMPLE,
                             NULL, NULL, NULL);
#endif
    MarkGUCPrefixReserved("memkv");
}

/*
 * Runs once, in the first backend to use the store, while it holds the DSM
 * registry entry. 'arg' is the values DSA, which the caller attached first:
 * calling GetNamedDSA() from here would re-enter the registry.
 *
 * The index is made inside that DSA, so memkv.max_memory covers it too.
 */
static void
kv_shared_init(void *ptr, void *arg)
{
    KVShared   *s = (KVShared *) ptr;
    dshash_parameters params = kv_params;

    pg_atomic_init_u64(&s->hits, 0);
    pg_atomic_init_u64(&s->misses, 0);
    pg_atomic_init_u64(&s->evicted, 0);
    pg_atomic_init_u64(&s->expired, 0);
    pg_atomic_init_u64(&s->version, 0);

    if (!pg_strong_random(&s->hash_seed, sizeof(s->hash_seed)))
        s->hash_seed = (uint64) GetCurrentTimestamp() ^
            ((uint64) MyProcPid << 32);

    LWLockInitialize(&s->reclaim_lock, LWLockNewTrancheId("memkv_reclaim"));

    s->index_tranche = LWLockNewTrancheId("memkv_index");
    params.tranche_id = s->index_tranche;
    kv_hash = dshash_create((dsa_area *) arg, &params, NULL);
    s->index_handle = dshash_get_hash_table_handle(kv_hash);
}

/* Attach to the shared store; the first caller on the server creates it. */
static void
kv_attach(void)
{
    bool        found;

    if (kv_dsa == NULL)
        kv_dsa = GetNamedDSA("memkv_values", &found);
    if (kv_shared == NULL)
        kv_shared = GetNamedDSMSegment("memkv_shared", sizeof(KVShared),
                                       kv_shared_init, &found, kv_dsa);
    if (kv_hash == NULL)
    {
        /* not the creator: attach, keeping the local state for good */
        dshash_parameters params = kv_params;
        MemoryContext oldcontext = MemoryContextSwitchTo(TopMemoryContext);

        params.tranche_id = kv_shared->index_tranche;
        kv_hash = dshash_attach(kv_dsa, &params, kv_shared->index_handle, NULL);
        MemoryContextSwitchTo(oldcontext);
    }

    if (kv_applied_mb != kv_max_memory_mb)
    {
        dsa_set_size_limit(kv_dsa, (size_t) kv_max_memory_mb * 1024 * 1024);
        kv_applied_mb = kv_max_memory_mb;
    }
}

static inline void
kv_count(pg_atomic_uint64 *counter, int64 n)
{
    if (n > 0)
        pg_atomic_fetch_add_u64(counter, (uint64) n);
}

static inline uint64
kv_next_version(void)
{
    return pg_atomic_add_fetch_u64(&kv_shared->version, 1);
}

static inline bool
kv_expired(const KVEntry *e, TimestampTz now)
{
    return e->expires_at <= now;
}

/* Record an access. Safe under a shared lock: the store is atomic. */
static inline void
kv_touch(KVEntry *e, TimestampTz now)
{
    pg_atomic_write_u64(&e->atime, (uint64) now);
}

static inline TimestampTz
kv_atime(KVEntry *e)
{
    return (TimestampTz) pg_atomic_read_u64(&e->atime);
}

static pg_noreturn void
kv_wrongtype(void)
{
    ereport(ERROR,
            (errcode(ERRCODE_WRONG_OBJECT_TYPE),
             errmsg("memkv key holds the wrong kind of value")));
}

/* The 128-bit hash of some key bytes, as the index has them. Needs the seed. */
static void
kv_hash_bytes(const char *data, Size len, KVHash *h)
{
    uint64      seed = kv_shared->hash_seed;

    h->w[0] = hash_bytes_extended((const unsigned char *) data, (int) len, seed);
    h->w[1] = hash_bytes_extended((const unsigned char *) data, (int) len,
                                  seed ^ UINT64CONST(0x9e3779b97f4a7c15));
#ifdef USE_ASSERT_CHECKING
    if (kv_test_weak_hash)
    {
        h->w[0] &= 1;
        h->w[1] = 0;
    }
#endif
}

/*
 * Make a KVKey from the bytes of t, which must stay alive as long as the key
 * is used. Attaches to the store first, because the hash needs its seed.
 */
static void
kv_key(text *t, KVKey *k)
{
    kv_attach();
    k->data = VARDATA_ANY(t);
    k->len = VARSIZE_ANY_EXHDR(t);
    kv_hash_bytes(k->data, k->len, &k->hash);
}

/* Where an entry's key bytes are; its value follows them. */
static inline char *
kv_entry_base(const KVEntry *e)
{
    return (char *) dsa_get_address(kv_dsa, e->data);
}

static inline char *
kv_entry_value(const KVEntry *e)
{
    return kv_entry_base(e) + e->klen;
}

/* Is this entry for this key, as opposed to another key with the same hash? */
static inline bool
kv_entry_is(const KVEntry *e, const KVKey *key)
{
    return e->klen == key->len &&
        memcmp(kv_entry_base(e), key->data, key->len) == 0;
}

/*
 * Look the key up and lock its entry; NULL if there is none. An entry with
 * the same hash but a different key isn't ours, so it counts as missing.
 */
static KVEntry *
kv_find(const KVKey *key, bool exclusive)
{
    KVEntry    *e = dshash_find(kv_hash, &key->hash, exclusive);

    if (e != NULL && !kv_entry_is(e, key))
    {
        dshash_release_lock(kv_hash, e);
        return NULL;
    }
    return e;
}

static TimestampTz
kv_expiry(Datum ttl)
{
    TimestampTz now = GetCurrentTimestamp();
    TimestampTz at;

    at = DatumGetTimestampTz(DirectFunctionCall2(timestamptz_pl_interval,
                                                 TimestampTzGetDatum(now), ttl));
    if (at <= now)
        ereport(ERROR,
                (errcode(ERRCODE_INVALID_PARAMETER_VALUE),
                 errmsg("memkv ttl must be positive")));
    return at;
}

/* Delete expired entries (or all); returns how many were removed. */
static int64
kv_purge(bool only_expired)
{
    dshash_seq_status status;
    KVEntry    *e;
    TimestampTz now = GetCurrentTimestamp();
    int64       n = 0;

    dshash_seq_init(&status, kv_hash, true);
    while ((e = dshash_seq_next(&status)) != NULL)
    {
        if (only_expired && !kv_expired(e, now))
            continue;
        dsa_free(kv_dsa, e->data);
        dshash_delete_current(&status);
        n++;
    }
    dshash_seq_term(&status);
    if (only_expired)
        kv_count(&kv_shared->expired, n);
    return n;
}

/*
 * Candidate pool: a max-heap on atime holding the oldest keys seen so far,
 * so the root is the youngest candidate and is the one a better key replaces.
 */
static void
kv_pool_sift_down(KVCandidate *pool, int n, int i)
{
    for (;;)
    {
        int         l = 2 * i + 1;
        int         r = l + 1;
        int         top = i;
        KVCandidate tmp;

        if (l < n && pool[l].atime > pool[top].atime)
            top = l;
        if (r < n && pool[r].atime > pool[top].atime)
            top = r;
        if (top == i)
            return;
        tmp = pool[i];
        pool[i] = pool[top];
        pool[top] = tmp;
        i = top;
    }
}

static void
kv_pool_offer(KVCandidate *pool, int *n, int cap, const KVEntry *e,
              TimestampTz atime)
{
    int         i;

    if (*n < cap)
    {
        /* append and sift up */
        i = (*n)++;
        while (i > 0 && pool[(i - 1) / 2].atime < atime)
        {
            pool[i] = pool[(i - 1) / 2];
            i = (i - 1) / 2;
        }
    }
    else if (atime < pool[0].atime)
    {
        /* replace the youngest candidate */
        pool[0].atime = atime;
        pool[0].hash = e->hash;
        kv_pool_sift_down(pool, *n, 0);
        return;
    }
    else
        return;

    pool[i].atime = atime;
    pool[i].hash = e->hash;
}

static int
kv_candidate_cmp(const void *a, const void *b)
{
    TimestampTz x = ((const KVCandidate *) a)->atime;
    TimestampTz y = ((const KVCandidate *) b)->atime;

    return (x > y) - (x < y);
}

/*
 * One eviction round. Scans the index once, dropping expired keys as it
 * goes and collecting the least recently used eligible live keys. If any
 * expired keys were dropped, returns without evicting live ones so the
 * caller can retry its allocation first. Otherwise evicts the oldest
 * candidates, skipping any that were touched since the scan.
 *
 * Returns how many keys were removed; *ncand is how many live keys were
 * eligible for eviction. Must be called without holding any dshash lock.
 */
static int64
kv_evict_round(KVCandidate *pool, int round, int *ncand)
{
    dshash_seq_status status;
    KVEntry    *e;
    TimestampTz now = GetCurrentTimestamp();
    int64       nlive = 0;
    int64       expired = 0;
    int64       evicted = 0;
    int64       want;
    int         npool = 0;
    int         i;

    dshash_seq_init(&status, kv_hash, true);
    while ((e = dshash_seq_next(&status)) != NULL)
    {
        if (kv_expired(e, now))
        {
            dsa_free(kv_dsa, e->data);
            dshash_delete_current(&status);
            expired++;
            continue;
        }
        nlive++;
        if (kv_eviction_policy == KV_EVICT_VOLATILE_LRU &&
            e->expires_at == KV_NEVER)
            continue;
        kv_pool_offer(pool, &npool, KV_EVICT_MAX, e, kv_atime(e));
    }
    dshash_seq_term(&status);
    kv_count(&kv_shared->expired, expired);

    *ncand = npool;
    if (expired > 0 || npool == 0)
        return expired;

    want = Max(nlive >> KV_EVICT_SHIFT, 1) << Min(round, 12);
    want = Min(want, npool);
    qsort(pool, npool, sizeof(KVCandidate), kv_candidate_cmp);

    for (i = 0; i < want; i++)
    {
        dsa_pointer val;

        e = dshash_find(kv_hash, &pool[i].hash, true);
        if (e == NULL)
            continue;                   /* deleted meanwhile */
        if (kv_atime(e) != pool[i].atime)
        {
            /* used (or rewritten) since the scan, so no longer a candidate */
            dshash_release_lock(kv_hash, e);
            continue;
        }
        val = e->data;
        dshash_delete_entry(kv_hash, e);    /* also releases the lock */
        dsa_free(kv_dsa, val);
        evicted++;
    }
    kv_count(&kv_shared->evicted, evicted);
    return evicted;
}

/* State for a loop that frees memory until an allocation fits. */
typedef struct KVReclaim
{
    KVCandidate *pool;
    int         round;
    int         stalls;
} KVReclaim;

static pg_noreturn void
kv_full_error(void)
{
    ereport(ERROR,
            (errcode(ERRCODE_OUT_OF_MEMORY),
             errmsg("memkv is full"),
             kv_eviction_policy == KV_EVICT_VOLATILE_LRU ?
             errhint("No keys with a TTL are left to evict. Add TTLs, "
                     "delete keys, or raise memkv.max_memory.") :
             errhint("Delete keys, add TTLs, or raise memkv.max_memory.")));
}

/*
 * Free some memory: drop expired keys, then evict as the policy allows.
 * Returns false when there is nothing more to free. Never call while holding
 * a dshash lock: this takes them.
 */
static bool
kv_reclaim(KVReclaim *rc)
{
    int64       freed;
    int         ncand;

    CHECK_FOR_INTERRUPTS();

    if (kv_eviction_policy == KV_EVICT_NONE)
    {
        /* Drop expired keys once, then give up. */
        return rc->round++ == 0 && kv_purge(true) > 0;
    }

    if (rc->pool == NULL)
        rc->pool = palloc(sizeof(KVCandidate) * KV_EVICT_MAX);
    freed = kv_evict_round(rc->pool, rc->round++, &ncand);
    if (freed > 0)
        rc->stalls = 0;
    else if (ncand == 0 || ++rc->stalls >= KV_EVICT_STALLS)
        return false;                   /* nothing left we may evict */
    return true;
}

static void
kv_reclaim_done(KVReclaim *rc)
{
    if (rc->pool != NULL)
        pfree(rc->pool);
    rc->pool = NULL;
}

/*
 * Allocate space for a key and value. Never call while holding a dshash
 * lock: when the store is full this sweeps expired keys and evicts others,
 * which takes those locks.
 */
static dsa_pointer
kv_alloc(Size len)
{
    Size        limit = (Size) kv_max_memory_mb * 1024 * 1024;
    KVReclaim   rc = {0};
    dsa_pointer p;

    /* Don't wipe the store for an entry that could never fit. */
    if (len >= limit)
        ereport(ERROR,
                (errcode(ERRCODE_PROGRAM_LIMIT_EXCEEDED),
                 errmsg("memkv entry of %zu bytes does not fit in memkv.max_memory",
                        len)));

    p = dsa_allocate_extended(kv_dsa, Max(len, 1), DSA_ALLOC_NO_OOM);
    if (!DsaPointerIsValid(p))
    {
        /*
         * No room. Make some, one backend at a time. If every backend that
         * failed scanned the index at once they would all pick the same oldest
         * keys: one would evict them, and the rest would find nothing to evict,
         * give up and raise an error while the winner's memory sat free. So
         * whoever gets the lock first tries again, because someone else may
         * have freed what it needs while it waited, and only then evicts.
         */
        LWLockAcquire(&kv_shared->reclaim_lock, LW_EXCLUSIVE);
        for (;;)
        {
            p = dsa_allocate_extended(kv_dsa, Max(len, 1), DSA_ALLOC_NO_OOM);
            if (DsaPointerIsValid(p) || !kv_reclaim(&rc))
                break;
        }
        LWLockRelease(&kv_shared->reclaim_lock);

        kv_reclaim_done(&rc);
        if (!DsaPointerIsValid(p))
            kv_full_error();
    }
    return p;
}

/* Allocate room for the key (copied in) followed by vlen bytes of value. */
static dsa_pointer
kv_alloc_blob(const KVKey *key, Size vlen)
{
    dsa_pointer p = kv_alloc(key->len + vlen);

    memcpy(dsa_get_address(kv_dsa, p), key->data, key->len);
    return p;
}

/* Allocate an entry's key and value and fill them in (no lock may be held). */
static dsa_pointer
kv_alloc_copy(const KVKey *key, const char *data, Size len)
{
    dsa_pointer p = kv_alloc_blob(key, len);

    memcpy((char *) dsa_get_address(kv_dsa, p) + key->len, data, len);
    return p;
}

/*
 * Find or insert the entry for a key, exclusively locked. newval, if valid,
 * is an allocation we own that isn't attached yet; every error path frees it.
 *
 * If the index has no room, make some the way kv_alloc does for values.
 * Under the cap that covers a full table and a bucket array that can't grow;
 * with DSHASH_INSERT_NO_OOM both come back as NULL instead of an error.
 *
 * Another live key with the same hash can't share the entry: that is an
 * error. If it has expired, we take its entry over and report it as new.
 */
static KVEntry *
kv_insert(const KVKey *key, dsa_pointer newval, bool *found)
{
    KVReclaim   rc = {0};
    KVEntry    *e;

    e = dshash_find_or_insert_extended(kv_hash, &key->hash, found,
                                       DSHASH_INSERT_NO_OOM);
    if (e == NULL)
    {
        /* No room in the index: reclaim one backend at a time, as in kv_alloc. */
        LWLockAcquire(&kv_shared->reclaim_lock, LW_EXCLUSIVE);
        while ((e = dshash_find_or_insert_extended(kv_hash, &key->hash, found,
                                                   DSHASH_INSERT_NO_OOM)) == NULL)
        {
            if (!kv_reclaim(&rc))
                break;
        }
        LWLockRelease(&kv_shared->reclaim_lock);

        kv_reclaim_done(&rc);
        if (e == NULL)
        {
            if (DsaPointerIsValid(newval))
                dsa_free(kv_dsa, newval);
            kv_full_error();
        }
    }

    if (*found && !kv_entry_is(e, key))
    {
        if (!kv_expired(e, GetCurrentTimestamp()))
        {
            dshash_release_lock(kv_hash, e);
            if (DsaPointerIsValid(newval))
                dsa_free(kv_dsa, newval);
            ereport(ERROR,
                    (errcode(ERRCODE_INTERNAL_ERROR),
                     errmsg("memkv key hash collision"),
                     errhint("Another key has the same 128-bit hash. "
                             "Use a different key.")));
        }
        dsa_free(kv_dsa, e->data);
        e->data = InvalidDsaPointer;
        e->klen = 0;
        kv_count(&kv_shared->expired, 1);
        *found = false;
    }
    return e;
}

/*
 * Point a locked entry at a new allocation holding len bytes of value, with room
 * for vcap. Returns the old allocation to free.
 */
static dsa_pointer
kv_store(KVEntry *e, bool found, dsa_pointer newval, const KVKey *key,
         Size len, Size vcap, KVType type, TimestampTz now)
{
    dsa_pointer oldval = found ? e->data : InvalidDsaPointer;

    e->data = newval;
    e->klen = (uint32) key->len;
    e->len = (uint32) len;
    e->vcap = (uint32) vcap;
    e->type = (uint8) type;
    e->version = kv_next_version();
    pg_atomic_init_u64(&e->atime, (uint64) now);
    return oldval;
}

/* Remove a key seen as expired, re-checking under an exclusive lock. */
static void
kv_remove_expired(const KVKey *key)
{
    KVEntry    *e = kv_find(key, true);
    dsa_pointer val;

    if (e == NULL)
        return;
    if (!kv_expired(e, GetCurrentTimestamp()))
    {
        dshash_release_lock(kv_hash, e);
        return;
    }
    val = e->data;
    dshash_delete_entry(kv_hash, e);    /* also releases the lock */
    dsa_free(kv_dsa, val);
    kv_count(&kv_shared->expired, 1);
}

/* Strict base-10 int64 parse that never throws (we may hold a lock). */
static bool
kv_parse_int64(const char *s, Size len, int64 *out)
{
    bool        neg = (len > 0 && s[0] == '-');
    Size        i = neg ? 1 : 0;
    int64       v = 0;

    if (i == len || len > 20)
        return false;
    for (; i < len; i++)
    {
        if (s[i] < '0' || s[i] > '9')
            return false;
        /* accumulate as a negative number so INT64_MIN parses */
        if (pg_mul_s64_overflow(v, 10, &v) ||
            pg_sub_s64_overflow(v, s[i] - '0', &v))
            return false;
    }
    if (!neg)
    {
        if (v == PG_INT64_MIN)
            return false;
        v = -v;
    }
    *out = v;
    return true;
}

/* ---------------------------------------------------------------------
 * Strings
 * ---------------------------------------------------------------------
 */

typedef enum KVSetCond
{
    KV_SET_ALWAYS,
    KV_SET_NX,                      /* only if the key doesn't exist */
    KV_SET_XX                       /* only if the key exists */
} KVSetCond;

/*
 * Can a value of len bytes go where one of vcap bytes was? Not if it would
 * leave more than half the space unused, or the key could keep a big
 * allocation for good after one big value.
 */
static inline bool
kv_fits(Size vcap, Size len)
{
    return len <= vcap && vcap - len <= Max(32, vcap / 2);
}

/* Set one string key. Returns false if cond stopped the write. */
static bool
kv_set_one(const KVKey *key, const char *data, Size len,
           TimestampTz expires_at, KVSetCond cond)
{
    dsa_pointer newval;
    dsa_pointer oldval;
    KVEntry    *e;
    bool        found;
    TimestampTz now;

    /*
     * Overwriting a key that is already there with a value of about the same
     * size is the common case, and it needs no allocation: write over it under
     * the entry's own lock. That keeps writers off the allocator's lock, which
     * is what limited them before.
     */
    e = kv_find(key, true);
    if (e != NULL)
    {
        now = GetCurrentTimestamp();
        if ((cond == KV_SET_NX && !kv_expired(e, now)) ||
            (cond == KV_SET_XX && kv_expired(e, now)))
        {
            dshash_release_lock(kv_hash, e);
            return false;
        }
        if (kv_fits(e->vcap, len))
        {
            memcpy(kv_entry_value(e), data, len);
            e->len = (uint32) len;
            e->type = KV_STRING;
            e->version = kv_next_version();
            e->expires_at = expires_at;
            kv_touch(e, now);
            dshash_release_lock(kv_hash, e);
            return true;
        }
        dshash_release_lock(kv_hash, e);
    }
    else if (cond == KV_SET_XX)
        return false;

    /* A new key, or a value that doesn't fit where the old one was. */

    /* Copy the key and value into shared memory before taking any lock. */
    newval = kv_alloc_copy(key, data, len);
    now = GetCurrentTimestamp();

    if (cond == KV_SET_XX)
    {
        e = kv_find(key, true);
        found = (e != NULL);
        if (!found || kv_expired(e, now))
        {
            if (found)
                dshash_release_lock(kv_hash, e);
            dsa_free(kv_dsa, newval);
            return false;
        }
    }
    else
    {
        e = kv_insert(key, newval, &found);
        if (cond == KV_SET_NX && found && !kv_expired(e, now))
        {
            dshash_release_lock(kv_hash, e);
            dsa_free(kv_dsa, newval);
            return false;
        }
    }

    oldval = kv_store(e, found, newval, key, len, len, KV_STRING, now);
    e->expires_at = expires_at;
    dshash_release_lock(kv_hash, e);

    if (DsaPointerIsValid(oldval))
        dsa_free(kv_dsa, oldval);
    return true;
}

/*
 * Read one string key. Returns NULL if it's missing, expired, or (when
 * !strict) not a string. With strict, a non-string is an error.
 */
static text *
kv_get_one(const KVKey *key, bool strict)
{
    KVEntry    *e;
    text       *result;
    TimestampTz now;

    e = kv_find(key, false);
    if (e == NULL)
    {
        kv_count(&kv_shared->misses, 1);
        return NULL;
    }
    now = GetCurrentTimestamp();
    if (kv_expired(e, now))
    {
        dshash_release_lock(kv_hash, e);
        kv_remove_expired(key);         /* lazy expiry, like Valkey */
        kv_count(&kv_shared->misses, 1);
        return NULL;
    }
    if (e->type != KV_STRING)
    {
        dshash_release_lock(kv_hash, e);
        if (strict)
            kv_wrongtype();
        kv_count(&kv_shared->misses, 1);
        return NULL;
    }
    kv_touch(e, now);
    result = cstring_to_text_with_len(kv_entry_value(e), (int) e->len);
    dshash_release_lock(kv_hash, e);
    kv_count(&kv_shared->hits, 1);
    return result;
}

/* kv_set(key, value, ttl DEFAULT NULL, nx DEFAULT false, xx DEFAULT false) */
Datum
kv_set(PG_FUNCTION_ARGS)
{
    KVKey       key;
    text       *val;
    TimestampTz expires_at = KV_NEVER;
    bool        nx = !PG_ARGISNULL(3) && PG_GETARG_BOOL(3);
    bool        xx = !PG_ARGISNULL(4) && PG_GETARG_BOOL(4);

    if (PG_ARGISNULL(0) || PG_ARGISNULL(1))
        ereport(ERROR,
                (errcode(ERRCODE_NULL_VALUE_NOT_ALLOWED),
                 errmsg("memkv key and value cannot be null")));
    if (nx && xx)
        ereport(ERROR,
                (errcode(ERRCODE_INVALID_PARAMETER_VALUE),
                 errmsg("memkv nx and xx cannot both be true")));

    kv_key(PG_GETARG_TEXT_PP(0), &key);
    val = PG_GETARG_TEXT_PP(1);
    if (!PG_ARGISNULL(2))
        expires_at = kv_expiry(PG_GETARG_DATUM(2));

    PG_RETURN_BOOL(kv_set_one(&key, VARDATA_ANY(val), VARSIZE_ANY_EXHDR(val),
                              expires_at,
                              nx ? KV_SET_NX : xx ? KV_SET_XX : KV_SET_ALWAYS));
}

/* kv_get(key) -> value, or NULL if missing or expired */
Datum
kv_get(PG_FUNCTION_ARGS)
{
    KVKey       key;
    text       *result;

    kv_key(PG_GETARG_TEXT_PP(0), &key);

    result = kv_get_one(&key, true);
    if (result == NULL)
        PG_RETURN_NULL();
    PG_RETURN_TEXT_P(result);
}

/* kv_del(key) -> true if a live key was removed */
Datum
kv_del(PG_FUNCTION_ARGS)
{
    KVKey       key;
    KVEntry    *e;
    dsa_pointer val;
    bool        live;

    kv_key(PG_GETARG_TEXT_PP(0), &key);

    e = kv_find(&key, true);
    if (e == NULL)
        PG_RETURN_BOOL(false);
    live = !kv_expired(e, GetCurrentTimestamp());
    val = e->data;
    dshash_delete_entry(kv_hash, e);
    dsa_free(kv_dsa, val);
    if (!live)
        kv_count(&kv_shared->expired, 1);
    PG_RETURN_BOOL(live);
}

/* kv_exists(key) -> true if the key is live; doesn't count as a use */
Datum
kv_exists(PG_FUNCTION_ARGS)
{
    KVKey       key;
    KVEntry    *e;
    bool        live;

    kv_key(PG_GETARG_TEXT_PP(0), &key);

    e = kv_find(&key, false);
    if (e == NULL)
        PG_RETURN_BOOL(false);
    live = !kv_expired(e, GetCurrentTimestamp());
    dshash_release_lock(kv_hash, e);
    if (!live)
        kv_remove_expired(&key);
    PG_RETURN_BOOL(live);
}

static pg_noreturn void
kv_incr_error(bool not_int)
{
    if (not_int)
        ereport(ERROR,
                (errcode(ERRCODE_INVALID_TEXT_REPRESENTATION),
                 errmsg("memkv value is not an integer")));
    ereport(ERROR,
            (errcode(ERRCODE_NUMERIC_VALUE_OUT_OF_RANGE),
             errmsg("memkv increment would overflow")));
}

/* kv_incr(key, amount DEFAULT 1) -> new value; keeps an existing TTL */
Datum
kv_incr(PG_FUNCTION_ARGS)
{
    KVKey       key;
    int64       amount = PG_GETARG_INT64(1);
    int64       cur = 0;
    int64       result = 0;
    bool        found;
    bool        live = false;
    bool        not_int = false;
    dsa_pointer newval;
    dsa_pointer oldval;
    KVEntry    *e;
    TimestampTz now;
    Size        len;
    char        digits[KV_INT_BUF];

    kv_key(PG_GETARG_TEXT_PP(0), &key);

    /*
     * The common case is a counter that exists and whose new number fits where
     * the old one was: update it under the entry's own lock, with no allocation.
     */
    e = kv_find(&key, true);
    if (e != NULL)
    {
        now = GetCurrentTimestamp();
        live = !kv_expired(e, now);
        if (live)
        {
            if (e->type != KV_STRING)
            {
                dshash_release_lock(kv_hash, e);
                kv_wrongtype();
            }
            if (!kv_parse_int64(kv_entry_value(e), e->len, &cur))
                not_int = true;
        }
        if (not_int || pg_add_s64_overflow(cur, amount, &result))
        {
            dshash_release_lock(kv_hash, e);
            kv_incr_error(not_int);
        }
        len = pg_lltoa(result, digits);
        if (len <= e->vcap)
        {
            memcpy(kv_entry_value(e), digits, len);
            e->len = (uint32) len;
            e->type = KV_STRING;
            e->version = kv_next_version();
            if (!live)
                e->expires_at = KV_NEVER;   /* expired counts as missing */
            kv_touch(e, now);
            dshash_release_lock(kv_hash, e);
            PG_RETURN_INT64(result);
        }
        dshash_release_lock(kv_hash, e);
        live = false;
        not_int = false;
        cur = 0;
    }

    /* A new counter, or a number that has outgrown its space. */

    /* Allocate before locking; any int64 fits in KV_INT_BUF bytes. */
    newval = kv_alloc_blob(&key, KV_INT_BUF);

    e = kv_insert(&key, newval, &found);
    now = GetCurrentTimestamp();
    if (found && !kv_expired(e, now))
    {
        live = true;
        if (e->type != KV_STRING)
        {
            dshash_release_lock(kv_hash, e);
            dsa_free(kv_dsa, newval);
            kv_wrongtype();
        }
        if (!kv_parse_int64(kv_entry_value(e), e->len, &cur))
            not_int = true;
    }

    if (not_int || pg_add_s64_overflow(cur, amount, &result))
    {
        /* Leave the stored value alone; report after unlocking. */
        dshash_release_lock(kv_hash, e);
        dsa_free(kv_dsa, newval);
        kv_incr_error(not_int);
    }

    len = pg_lltoa(result, (char *) dsa_get_address(kv_dsa, newval) + key.len);
    oldval = kv_store(e, found, newval, &key, len, KV_INT_BUF, KV_STRING, now);
    if (!live)
        e->expires_at = KV_NEVER;       /* new, or expired counts as missing */
    dshash_release_lock(kv_hash, e);

    if (DsaPointerIsValid(oldval))
        dsa_free(kv_dsa, oldval);
    PG_RETURN_INT64(result);
}

/* kv_expire(key, ttl) -> true if the key exists and now has this TTL */
Datum
kv_expire(PG_FUNCTION_ARGS)
{
    KVKey       key;
    TimestampTz at;
    TimestampTz now;
    KVEntry    *e;
    bool        ok;

    kv_key(PG_GETARG_TEXT_PP(0), &key);
    at = kv_expiry(PG_GETARG_DATUM(1));

    e = kv_find(&key, true);
    if (e == NULL)
        PG_RETURN_BOOL(false);
    now = GetCurrentTimestamp();
    ok = !kv_expired(e, now);
    if (ok)
    {
        e->expires_at = at;
        kv_touch(e, now);
    }
    dshash_release_lock(kv_hash, e);
    PG_RETURN_BOOL(ok);
}

/* kv_ttl(key) -> time left, 'infinity' if no TTL, NULL if missing */
Datum
kv_ttl(PG_FUNCTION_ARGS)
{
    KVKey       key;
    KVEntry    *e;
    TimestampTz now;
    TimestampTz at;
    Interval   *result;

    kv_key(PG_GETARG_TEXT_PP(0), &key);

    e = kv_find(&key, false);
    if (e == NULL)
        PG_RETURN_NULL();
    now = GetCurrentTimestamp();
    at = e->expires_at;
    dshash_release_lock(kv_hash, e);
    if (at <= now)
    {
        kv_remove_expired(&key);
        PG_RETURN_NULL();
    }

    result = (Interval *) palloc0(sizeof(Interval));
    if (at == KV_NEVER)
        INTERVAL_NOEND(result);
    else
        result->time = at - now;        /* microseconds */
    PG_RETURN_INTERVAL_P(result);
}

/* kv_persist(key) -> true if the key had a TTL and now doesn't */
Datum
kv_persist(PG_FUNCTION_ARGS)
{
    KVKey       key;
    KVEntry    *e;
    TimestampTz now;
    bool        ok;

    kv_key(PG_GETARG_TEXT_PP(0), &key);

    e = kv_find(&key, true);
    if (e == NULL)
        PG_RETURN_BOOL(false);
    now = GetCurrentTimestamp();
    ok = !kv_expired(e, now) && e->expires_at != KV_NEVER;
    if (ok)
    {
        e->expires_at = KV_NEVER;
        kv_touch(e, now);
    }
    dshash_release_lock(kv_hash, e);
    PG_RETURN_BOOL(ok);
}

/* Unpack a 1-D text[] with no NULL elements. */
static int
kv_text_array(ArrayType *arr, const char *what, Datum **elems)
{
    bool       *nulls;
    int         n;
    int         i;

    if (ARR_NDIM(arr) > 1)
        ereport(ERROR,
                (errcode(ERRCODE_ARRAY_SUBSCRIPT_ERROR),
                 errmsg("memkv %s must be a one-dimensional array", what)));
    deconstruct_array_builtin(arr, TEXTOID, elems, &nulls, &n);
    for (i = 0; i < n; i++)
        if (nulls[i])
            ereport(ERROR,
                    (errcode(ERRCODE_NULL_VALUE_NOT_ALLOWED),
                     errmsg("memkv %s cannot contain nulls", what)));
    return n;
}

/* kv_mget(keys text[]) -> text[] of values, NULL where missing */
Datum
kv_mget(PG_FUNCTION_ARGS)
{
    Datum      *keys;
    Datum      *vals;
    bool       *nulls;
    int         n;
    int         i;
    int         dims[1];
    int         lbs[1] = {1};
    KVKey       key;

    n = kv_text_array(PG_GETARG_ARRAYTYPE_P(0), "keys", &keys);
    if (n == 0)
        PG_RETURN_ARRAYTYPE_P(construct_empty_array(TEXTOID));
    kv_attach();

    vals = palloc(sizeof(Datum) * n);
    nulls = palloc(sizeof(bool) * n);
    for (i = 0; i < n; i++)
    {
        text       *v;

        kv_key(DatumGetTextPP(keys[i]), &key);
        v = kv_get_one(&key, false);
        nulls[i] = (v == NULL);
        vals[i] = v ? PointerGetDatum(v) : (Datum) 0;
    }
    dims[0] = n;
    PG_RETURN_ARRAYTYPE_P(construct_md_array(vals, nulls, 1, dims, lbs,
                                             TEXTOID, -1, false, TYPALIGN_INT));
}

/*
 * kv_mset(keys text[], values text[], ttl DEFAULT NULL)
 * Sets each pair in turn; other sessions may see some pairs before others.
 */
Datum
kv_mset(PG_FUNCTION_ARGS)
{
    Datum      *keys;
    Datum      *vals;
    int         nkeys;
    int         nvals;
    int         i;
    TimestampTz expires_at = KV_NEVER;
    KVKey       key;

    if (PG_ARGISNULL(0) || PG_ARGISNULL(1))
        ereport(ERROR,
                (errcode(ERRCODE_NULL_VALUE_NOT_ALLOWED),
                 errmsg("memkv keys and values cannot be null")));
    nkeys = kv_text_array(PG_GETARG_ARRAYTYPE_P(0), "keys", &keys);
    nvals = kv_text_array(PG_GETARG_ARRAYTYPE_P(1), "values", &vals);
    if (nkeys != nvals)
        ereport(ERROR,
                (errcode(ERRCODE_ARRAY_SUBSCRIPT_ERROR),
                 errmsg("memkv keys and values must have the same length")));
    if (!PG_ARGISNULL(2))
        expires_at = kv_expiry(PG_GETARG_DATUM(2));

    for (i = 0; i < nkeys; i++)
    {
        text       *v = DatumGetTextPP(vals[i]);

        kv_key(DatumGetTextPP(keys[i]), &key);
        kv_set_one(&key, VARDATA_ANY(v), VARSIZE_ANY_EXHDR(v), expires_at,
                   KV_SET_ALWAYS);
    }
    PG_RETURN_VOID();
}

/* ---------------------------------------------------------------------
 * Hashes
 *
 * A hash value is one blob: uint32 field count, then for each field a
 * KVHField header followed by the field bytes and the value bytes. Like
 * Valkey's listpack encoding it's compact and fast for small hashes, but
 * every write rewrites the whole blob, so keep hashes modest in size.
 *
 * Writes are optimistic: read the blob under a shared lock, build the new
 * one in local memory, allocate it with no lock held, then take the
 * exclusive lock and commit only if the entry's version hasn't changed.
 * ---------------------------------------------------------------------
 */

typedef struct KVHField
{
    uint32      flen;
    uint32      vlen;
} KVHField;

#define KV_H_HDR    sizeof(uint32)

static uint32
kv_h_count(const char *b, Size len)
{
    uint32      n = 0;

    if (len >= KV_H_HDR)
        memcpy(&n, b, KV_H_HDR);
    return n;
}

/* Step through a hash blob; *pos starts at KV_H_HDR. */
static bool
kv_h_next(const char *b, Size len, Size *pos,
          const char **f, uint32 *flen, const char **v, uint32 *vlen)
{
    KVHField    h;

    if (*pos + sizeof(h) > len)
        return false;
    memcpy(&h, b + *pos, sizeof(h));
    *f = b + *pos + sizeof(h);
    *flen = h.flen;
    *v = *f + h.flen;
    *vlen = h.vlen;
    *pos += sizeof(h) + (Size) h.flen + h.vlen;
    return true;
}

static bool
kv_h_lookup(const char *b, Size len, const char *field, uint32 flen,
            const char **v, uint32 *vlen)
{
    Size        pos = KV_H_HDR;
    const char *f;
    uint32      fl;

    while (kv_h_next(b, len, &pos, &f, &fl, v, vlen))
        if (fl == flen && memcmp(f, field, flen) == 0)
            return true;
    return false;
}

static void
kv_h_append(StringInfo buf, const char *f, uint32 flen,
            const char *v, uint32 vlen)
{
    KVHField    h = {flen, vlen};

    appendBinaryStringInfo(buf, (const char *) &h, sizeof(h));
    appendBinaryStringInfo(buf, f, flen);
    appendBinaryStringInfo(buf, v, vlen);
}

/*
 * Build a copy of blob b (may be NULL) with field set to v, or removed if
 * v is NULL. *existed says whether the field was there before.
 */
static char *
kv_h_rewrite(const char *b, Size len, const char *field, uint32 flen,
             const char *v, uint32 vlen, Size *newlen, bool *existed)
{
    StringInfoData buf;
    uint32      n = 0;
    Size        pos = KV_H_HDR;
    const char *f;
    const char *ov;
    uint32      fl;
    uint32      ovl;

    *existed = false;
    initStringInfo(&buf);
    appendBinaryStringInfo(&buf, (const char *) &n, KV_H_HDR);
    if (b != NULL)
    {
        while (kv_h_next(b, len, &pos, &f, &fl, &ov, &ovl))
        {
            if (fl == flen && memcmp(f, field, flen) == 0)
            {
                *existed = true;
                continue;
            }
            kv_h_append(&buf, f, fl, ov, ovl);
            n++;
        }
    }
    if (v != NULL)
    {
        kv_h_append(&buf, field, flen, v, vlen);
        n++;
    }
    memcpy(buf.data, &n, KV_H_HDR);
    *newlen = buf.len;
    return buf.data;
}

/*
 * Copy a live hash's blob into local memory. Returns NULL if the key is
 * missing or expired; errors if it isn't a hash. *version gets the
 * entry's version and *present whether any entry (even expired) exists.
 */
static char *
kv_h_snapshot(const KVKey *key, bool touch, Size *len, bool *present,
              uint64 *version)
{
    KVEntry    *e = kv_find(key, false);
    TimestampTz now;
    char       *copy = NULL;
    bool        expired;

    *present = (e != NULL);
    *len = 0;
    if (e == NULL)
        return NULL;
    *version = e->version;
    now = GetCurrentTimestamp();
    expired = kv_expired(e, now);
    if (!expired)
    {
        if (e->type != KV_HASH)
        {
            dshash_release_lock(kv_hash, e);
            kv_wrongtype();
        }
        *len = e->len;
        copy = palloc(Max(e->len, 1));
        memcpy(copy, kv_entry_value(e), e->len);
        if (touch)
            kv_touch(e, now);
    }
    dshash_release_lock(kv_hash, e);
    if (expired)
        kv_remove_expired(key);
    return copy;
}

typedef enum KVHashOp
{
    KV_H_SET,
    KV_H_DEL,
    KV_H_INCR
} KVHashOp;

/*
 * Change one field of a hash, creating the key if needed and deleting it
 * when its last field goes. SET returns true if the field is new, DEL true
 * if it existed, INCR true (with the new value in *incr_result).
 */
static bool
kv_h_write(const KVKey *key, KVHashOp op, const char *field, uint32 flen,
           const char *v, uint32 vlen, int64 amount, int64 *incr_result)
{
    for (;;)
    {
        Size        oldlen;
        bool        present;
        uint64      version = 0;
        char       *old;
        char       *nb;
        Size        nlen;
        bool        existed;
        bool        found;
        char        numbuf[KV_INT_BUF];
        dsa_pointer np = InvalidDsaPointer;
        KVEntry    *e;
        TimestampTz now;

        old = kv_h_snapshot(key, false, &oldlen, &present, &version);

        if (op == KV_H_DEL && old == NULL)
            return false;
        if (op == KV_H_INCR)
        {
            const char *cv;
            uint32      cvl;
            int64       cur = 0;

            if (old != NULL && kv_h_lookup(old, oldlen, field, flen, &cv, &cvl) &&
                !kv_parse_int64(cv, cvl, &cur))
                ereport(ERROR,
                        (errcode(ERRCODE_INVALID_TEXT_REPRESENTATION),
                         errmsg("memkv hash field value is not an integer")));
            if (pg_add_s64_overflow(cur, amount, incr_result))
                ereport(ERROR,
                        (errcode(ERRCODE_NUMERIC_VALUE_OUT_OF_RANGE),
                         errmsg("memkv increment would overflow")));
            vlen = pg_lltoa(*incr_result, numbuf);
            v = numbuf;
        }

        nb = kv_h_rewrite(old, oldlen, field, flen,
                          op == KV_H_DEL ? NULL : v, vlen, &nlen, &existed);
        if (op == KV_H_DEL && !existed)
            return false;

        /* Allocate with no lock held, then commit if nothing changed. */
        if (kv_h_count(nb, nlen) > 0)
        {
            np = kv_alloc_copy(key, nb, nlen);
            e = kv_insert(key, np, &found);
        }
        else
        {
            e = kv_find(key, true);
            found = (e != NULL);
        }
        now = GetCurrentTimestamp();

        if (found != present ||
            (found && e->version != version) ||
            (found && old != NULL && kv_expired(e, now)))
        {
            /* Someone changed the key since our snapshot: retry. */
            if (e != NULL && !found)
                dshash_delete_entry(kv_hash, e);    /* our fresh insert */
            else if (e != NULL)
                dshash_release_lock(kv_hash, e);
            if (DsaPointerIsValid(np))
                dsa_free(kv_dsa, np);
            pfree(nb);
            if (old)
                pfree(old);
            CHECK_FOR_INTERRUPTS();
            continue;
        }

        if (!DsaPointerIsValid(np))
        {
            /* Last field removed: drop the key. */
            dsa_pointer val = e->data;

            dshash_delete_entry(kv_hash, e);
            dsa_free(kv_dsa, val);
        }
        else
        {
            dsa_pointer oldval = kv_store(e, found, np, key, nlen, nlen, KV_HASH, now);

            if (old == NULL)
                e->expires_at = KV_NEVER;   /* new, or replacing an expired key */
            dshash_release_lock(kv_hash, e);
            if (DsaPointerIsValid(oldval))
                dsa_free(kv_dsa, oldval);
        }

        switch (op)
        {
            case KV_H_SET:
                return !existed;
            case KV_H_DEL:
                return true;
            case KV_H_INCR:
                return true;
        }
        return true;
    }
}

static uint32
kv_field_len(text *t)
{
    Size        len = VARSIZE_ANY_EXHDR(t);

    /* text is under 1GB, so this always fits; keep the check honest */
    if (len > PG_UINT32_MAX)
        ereport(ERROR,
                (errcode(ERRCODE_PROGRAM_LIMIT_EXCEEDED),
                 errmsg("memkv hash field or value is too long")));
    return (uint32) len;
}

/* kv_hset(key, field, value) -> true if the field is new */
Datum
kv_hset(PG_FUNCTION_ARGS)
{
    KVKey       key;
    text       *field = PG_GETARG_TEXT_PP(1);
    text       *val = PG_GETARG_TEXT_PP(2);

    kv_key(PG_GETARG_TEXT_PP(0), &key);
    PG_RETURN_BOOL(kv_h_write(&key, KV_H_SET,
                              VARDATA_ANY(field), kv_field_len(field),
                              VARDATA_ANY(val), kv_field_len(val), 0, NULL));
}

/* kv_hget(key, field) -> value, or NULL */
Datum
kv_hget(PG_FUNCTION_ARGS)
{
    KVKey       key;
    text       *field = PG_GETARG_TEXT_PP(1);
    char       *b;
    Size        len;
    bool        present;
    uint64      version;
    const char *v;
    uint32      vlen;

    kv_key(PG_GETARG_TEXT_PP(0), &key);

    b = kv_h_snapshot(&key, true, &len, &present, &version);
    if (b == NULL ||
        !kv_h_lookup(b, len, VARDATA_ANY(field), kv_field_len(field), &v, &vlen))
    {
        kv_count(&kv_shared->misses, 1);
        PG_RETURN_NULL();
    }
    kv_count(&kv_shared->hits, 1);
    PG_RETURN_TEXT_P(cstring_to_text_with_len(v, (int) vlen));
}

/* kv_hdel(key, field) -> true if the field was removed */
Datum
kv_hdel(PG_FUNCTION_ARGS)
{
    KVKey       key;
    text       *field = PG_GETARG_TEXT_PP(1);

    kv_key(PG_GETARG_TEXT_PP(0), &key);
    PG_RETURN_BOOL(kv_h_write(&key, KV_H_DEL,
                              VARDATA_ANY(field), kv_field_len(field),
                              NULL, 0, 0, NULL));
}

/* kv_hlen(key) -> number of fields, 0 if missing */
Datum
kv_hlen(PG_FUNCTION_ARGS)
{
    KVKey       key;
    char       *b;
    Size        len;
    bool        present;
    uint64      version;

    kv_key(PG_GETARG_TEXT_PP(0), &key);

    b = kv_h_snapshot(&key, false, &len, &present, &version);
    PG_RETURN_INT64(b == NULL ? 0 : (int64) kv_h_count(b, len));
}

/* kv_hincr(key, field, amount DEFAULT 1) -> new value */
Datum
kv_hincr(PG_FUNCTION_ARGS)
{
    KVKey       key;
    text       *field = PG_GETARG_TEXT_PP(1);
    int64       amount = PG_GETARG_INT64(2);
    int64       result = 0;

    kv_key(PG_GETARG_TEXT_PP(0), &key);
    kv_h_write(&key, KV_H_INCR, VARDATA_ANY(field), kv_field_len(field),
               NULL, 0, amount, &result);
    PG_RETURN_INT64(result);
}

/* kv_hgetall(key) -> SETOF (field, value) */
Datum
kv_hgetall(PG_FUNCTION_ARGS)
{
    ReturnSetInfo *rsinfo = (ReturnSetInfo *) fcinfo->resultinfo;
    KVKey       key;
    char       *b;
    Size        len;
    bool        present;
    uint64      version;
    Size        pos = KV_H_HDR;
    const char *f;
    const char *v;
    uint32      flen;
    uint32      vlen;

    kv_key(PG_GETARG_TEXT_PP(0), &key);
    InitMaterializedSRF(fcinfo, 0);

    b = kv_h_snapshot(&key, true, &len, &present, &version);
    if (b == NULL)
    {
        kv_count(&kv_shared->misses, 1);
        return (Datum) 0;
    }
    kv_count(&kv_shared->hits, 1);
    while (kv_h_next(b, len, &pos, &f, &flen, &v, &vlen))
    {
        Datum       values[2];
        bool        nulls[2] = {false, false};

        values[0] = PointerGetDatum(cstring_to_text_with_len(f, (int) flen));
        values[1] = PointerGetDatum(cstring_to_text_with_len(v, (int) vlen));
        tuplestore_putvalues(rsinfo->setResult, rsinfo->setDesc, values, nulls);
    }
    return (Datum) 0;
}

/* ---------------------------------------------------------------------
 * Maintenance and stats
 * ---------------------------------------------------------------------
 */

Datum
kv_sweep(PG_FUNCTION_ARGS)
{
    kv_attach();
    PG_RETURN_INT64(kv_purge(true));
}

Datum
kv_flush(PG_FUNCTION_ARGS)
{
    int64       n;

    kv_attach();
    n = kv_purge(false);

    /*
     * The DSA keeps one empty superblock per value-size class it has ever
     * used; give those back so a flushed store has its whole cap again.
     */
    dsa_trim(kv_dsa);
    PG_RETURN_INT64(n);
}

/*
 * kv_stats() -> one row: live keys, keys with a TTL, memory in use (DSA
 * segments holding keys, values and the index, so it includes free space
 * inside them), the cap, and server-wide hit/miss/eviction/expiry counters
 * since the store was made.
 * Counting keys scans the index, so this is O(keys).
 */
Datum
kv_stats(PG_FUNCTION_ARGS)
{
    TupleDesc   tupdesc;
    Datum       values[8];
    bool        nulls[8] = {0};
    dshash_seq_status status;
    KVEntry    *e;
    TimestampTz now = GetCurrentTimestamp();
    int64       nkeys = 0;
    int64       nttl = 0;

    if (get_call_result_type(fcinfo, NULL, &tupdesc) != TYPEFUNC_COMPOSITE)
        elog(ERROR, "return type must be a row type");
    kv_attach();

    dshash_seq_init(&status, kv_hash, false);
    while ((e = dshash_seq_next(&status)) != NULL)
    {
        if (kv_expired(e, now))
            continue;
        nkeys++;
        if (e->expires_at != KV_NEVER)
            nttl++;
    }
    dshash_seq_term(&status);

    values[0] = Int64GetDatum(nkeys);
    values[1] = Int64GetDatum(nttl);
    values[2] = Int64GetDatum((int64) dsa_get_total_size(kv_dsa));
    values[3] = Int64GetDatum((int64) kv_max_memory_mb * 1024 * 1024);
    values[4] = Int64GetDatum((int64) pg_atomic_read_u64(&kv_shared->hits));
    values[5] = Int64GetDatum((int64) pg_atomic_read_u64(&kv_shared->misses));
    values[6] = Int64GetDatum((int64) pg_atomic_read_u64(&kv_shared->evicted));
    values[7] = Int64GetDatum((int64) pg_atomic_read_u64(&kv_shared->expired));

    tupdesc = BlessTupleDesc(tupdesc);
    PG_RETURN_DATUM(HeapTupleGetDatum(heap_form_tuple(tupdesc, values, nulls)));
}

/* ---------------------------------------------------------------------
 * Rate limiting
 *
 * A limiter is one int64 per key: the "theoretical arrival time" of GCRA, in
 * microseconds. A request of cost n pushes it forward by n/capacity of the
 * period, and is allowed if that leaves it no more than one period ahead of
 * now. An absent bucket is a full one, and a bucket's TTL is the moment it
 * would be full again, so idle buckets expire by themselves. The whole
 * decision is made under the entry's exclusive lock, so it is exact: any
 * number of sessions on one bucket together get exactly its capacity.
 * ---------------------------------------------------------------------
 */

typedef struct KVLimit
{
    bool        allowed;
    int64       remaining;          /* requests of cost 1 still allowed now */
    int64       retry_after;        /* microseconds until this one would pass */
    int64       reset_after;        /* microseconds until the bucket is full */
} KVLimit;

/* a * b / c, rounded down, without overflowing 64 bits on the way */
static int64
kv_muldiv(int64 a, int64 b, int64 c)
{
#ifdef HAVE_INT128
    return (int64) (((int128) a * b) / c);
#else
    return (int64) ((double) a * (double) b / (double) c);
#endif
}

/* How many microseconds an interval is, counted forward from now. */
static int64
kv_interval_micros(Datum interval)
{
    TimestampTz now = GetCurrentTimestamp();
    TimestampTz at;

    at = DatumGetTimestampTz(DirectFunctionCall2(timestamptz_pl_interval,
                                                 TimestampTzGetDatum(now),
                                                 interval));
    return at - now;
}

static void
kv_rate_limit_core(const KVKey *key, int64 capacity, int64 period, int64 cost,
                   KVLimit *out)
{
    int64       inc = kv_muldiv(cost, period, capacity);
    KVEntry    *e;
    TimestampTz now;
    int64       tat;
    int64       base;
    int64       new_tat;
    int64       delay;

    e = kv_find(key, true);
    if (e != NULL)
    {
        now = GetCurrentTimestamp();
        if (kv_expired(e, now))
        {
            dshash_release_lock(kv_hash, e);
            e = NULL;
        }
    }
    if (e == NULL)
    {
        /* A new bucket. Its allocation can't be made while we hold the entry. */
        dsa_pointer newval = kv_alloc_blob(key, sizeof(int64));
        bool        found;

        e = kv_insert(key, newval, &found);
        now = GetCurrentTimestamp();
        if (found && !kv_expired(e, now))
        {
            /* someone else made it while we allocated: use theirs */
            dsa_free(kv_dsa, newval);
        }
        else
        {
            dsa_pointer oldval = kv_store(e, found, newval, key, sizeof(int64),
                                          sizeof(int64), KV_BUCKET, now);

            tat = 0;                    /* long ago, so the bucket is full */
            memcpy(kv_entry_value(e), &tat, sizeof(tat));
            e->expires_at = now;        /* provisional, set below */
            if (DsaPointerIsValid(oldval))
                dsa_free(kv_dsa, oldval);
        }
    }
    if (e->type != KV_BUCKET)
    {
        dshash_release_lock(kv_hash, e);
        kv_wrongtype();
    }

    memcpy(&tat, kv_entry_value(e), sizeof(tat));
    base = Max(tat, (int64) now);
    new_tat = base + inc;               /* can't overflow: see the clamp on period */
    delay = new_tat - now;

    if (delay <= period)
    {
        out->allowed = true;
        memcpy(kv_entry_value(e), &new_tat, sizeof(new_tat));
        e->expires_at = new_tat;        /* full again at that moment */
        out->remaining = kv_muldiv(period - delay, capacity, period);
        out->retry_after = 0;
        out->reset_after = delay;
    }
    else
    {
        out->allowed = false;
        out->remaining = kv_muldiv(Max(period - (base - now), 0), capacity, period);
        out->retry_after = delay - period;
        out->reset_after = base - now;
    }
    kv_touch(e, now);
    dshash_release_lock(kv_hash, e);
}

/* The arguments of rate_limit() and rate_limit_info() are the same. */
static void
kv_rate_limit_args(FunctionCallInfo fcinfo, KVLimit *out)
{
    KVKey       key;
    int64       capacity = PG_GETARG_INT64(1);
    int64       cost = PG_GETARG_INT64(3);
    int64       period;

    kv_key(PG_GETARG_TEXT_PP(0), &key);
    period = kv_interval_micros(PG_GETARG_DATUM(2));
    if (capacity < 1)
        ereport(ERROR,
                (errcode(ERRCODE_INVALID_PARAMETER_VALUE),
                 errmsg("memkv rate limit capacity must be positive")));
    if (period < 1)
        ereport(ERROR,
                (errcode(ERRCODE_INVALID_PARAMETER_VALUE),
                 errmsg("memkv rate limit period must be positive")));
    if (cost < 1)
        ereport(ERROR,
                (errcode(ERRCODE_INVALID_PARAMETER_VALUE),
                 errmsg("memkv rate limit cost must be positive")));
    if (cost > capacity)
        ereport(ERROR,
                (errcode(ERRCODE_INVALID_PARAMETER_VALUE),
                 errmsg("memkv rate limit cost is larger than the capacity, so it can never be allowed")));

    /*
     * An endless period is clamped to about 73,000 years. That keeps every
     * time we add to it, including the stored one, far from overflowing, and
     * it is as good as forever for a limiter.
     */
    period = Min(period, PG_INT64_MAX / 4);
    kv_rate_limit_core(&key, capacity, period, cost, out);
}

/* rate_limit(key, capacity, period, cost DEFAULT 1) -> allowed */
Datum
kv_rate_limit(PG_FUNCTION_ARGS)
{
    KVLimit     r;

    kv_rate_limit_args(fcinfo, &r);
    PG_RETURN_BOOL(r.allowed);
}

/* microseconds to milliseconds, rounded up */
static int64
kv_ceil_ms(int64 us)
{
    return us / 1000 + (us % 1000 != 0);
}

/*
 * rate_limit_info(key, capacity, period, cost DEFAULT 1)
 *   -> allowed, remaining, retry_after_ms, reset_after_ms
 */
Datum
kv_rate_limit_info(PG_FUNCTION_ARGS)
{
    TupleDesc   tupdesc;
    Datum       values[4];
    bool        nulls[4] = {false, false, false, false};
    KVLimit     r;

    if (get_call_result_type(fcinfo, NULL, &tupdesc) != TYPEFUNC_COMPOSITE)
        elog(ERROR, "return type must be a row type");
    kv_rate_limit_args(fcinfo, &r);

    values[0] = BoolGetDatum(r.allowed);
    values[1] = Int64GetDatum(r.remaining);
    values[2] = Int64GetDatum(kv_ceil_ms(r.retry_after));
    values[3] = Int64GetDatum(kv_ceil_ms(r.reset_after));
    tupdesc = BlessTupleDesc(tupdesc);
    PG_RETURN_DATUM(HeapTupleGetDatum(heap_form_tuple(tupdesc, values, nulls)));
}

/* ---------------------------------------------------------------------
 * Self-check
 *
 * verify() walks the whole store and returns one row per inconsistency. It
 * compares entries with each other (shared allocations, repeated versions), so
 * it only means something while nothing else is writing: an entry freed and
 * reallocated mid-scan would look like a duplicate. Run it after a workload.
 * ---------------------------------------------------------------------
 */

static void kv_verify_report(ReturnSetInfo *rsinfo, const char *key,
                             const char *fmt,...)
            pg_attribute_printf(3, 4);

/* One row: the key (null when the problem isn't about one entry) and what is wrong. */
static void
kv_verify_report(ReturnSetInfo *rsinfo, const char *key, const char *fmt,...)
{
    char        buf[256];
    va_list     ap;
    Datum       values[2];
    bool        nulls[2];

    va_start(ap, fmt);
    vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    nulls[0] = (key == NULL);
    values[0] = key ? PointerGetDatum(cstring_to_text(key)) : (Datum) 0;
    nulls[1] = false;
    values[1] = PointerGetDatum(cstring_to_text(buf));
    tuplestore_putvalues(rsinfo->setResult, rsinfo->setDesc, values, nulls);
}

static int
kv_u64_cmp(const void *a, const void *b)
{
    uint64      x = *(const uint64 *) a;
    uint64      y = *(const uint64 *) b;

    return (x > y) - (x < y);
}

/* Up to 32 bytes of an entry's key, for messages. */
static char *
kv_key_label(const KVEntry *e)
{
    Size        n = Min(e->klen, 32);
    const char *k = kv_entry_base(e);
    char       *s = palloc(n + 4);
    Size        i;

    for (i = 0; i < n; i++)
        s[i] = (k[i] >= 0x20 && k[i] < 0x7f) ? k[i] : '?';
    if (e->klen > n)
    {
        s[n++] = '.';
        s[n++] = '.';
        s[n++] = '.';
    }
    s[n] = '\0';
    return s;
}

/* Does a hash's blob parse exactly, with the number of fields it states? */
static bool
kv_h_wellformed(const char *b, Size len)
{
    uint32      n = kv_h_count(b, len);
    Size        pos = KV_H_HDR;
    uint32      seen = 0;

    if (len < KV_H_HDR || n == 0)
        return false;
    while (pos < len)
    {
        KVHField    h;

        if (len - pos < sizeof(h))
            return false;
        memcpy(&h, b + pos, sizeof(h));
        pos += sizeof(h);
        if ((Size) h.flen + h.vlen > len - pos)
            return false;
        pos += (Size) h.flen + h.vlen;
        seen++;
    }
    return seen == n;
}

/* verify() -> (key, problem), one row per problem and none when the store is sound */
Datum
kv_verify(PG_FUNCTION_ARGS)
{
    ReturnSetInfo *rsinfo = (ReturnSetInfo *) fcinfo->resultinfo;
    dshash_seq_status status;
    KVEntry    *e;
    uint64     *ptrs = NULL;
    uint64     *vers = NULL;
    int64       n = 0;
    int64       cap = 0;
    int64       i;

    InitMaterializedSRF(fcinfo, 0);
    kv_attach();

    dshash_seq_init(&status, kv_hash, false);
    while ((e = dshash_seq_next(&status)) != NULL)
    {
        KVHash      h;
        char       *label;

        if (e->type != KV_STRING && e->type != KV_HASH && e->type != KV_BUCKET)
        {
            kv_verify_report(rsinfo, NULL, "an entry has an unknown type %d", (int) e->type);
            continue;
        }
        if (!DsaPointerIsValid(e->data) || e->klen > MaxAllocSize ||
            e->len > MaxAllocSize || e->vcap > MaxAllocSize)
        {
            kv_verify_report(rsinfo, NULL, "an entry has an invalid pointer or length");
            continue;
        }

        label = kv_key_label(e);
        kv_hash_bytes(kv_entry_base(e), e->klen, &h);
        if (memcmp(&h, &e->hash, sizeof(h)) != 0)
        {
            kv_verify_report(rsinfo, label, "the key bytes don't match the entry's hash");
        }
        if (e->expires_at <= 0)
        {
            kv_verify_report(rsinfo, label, "the expiry time is not valid");
        }
        if (e->version == 0)
        {
            kv_verify_report(rsinfo, label, "the entry has no version");
        }
        if (e->len > e->vcap)
            kv_verify_report(rsinfo, label, "the value is longer than the space for it");
        if (e->type == KV_BUCKET && e->len != sizeof(int64))
        {
            kv_verify_report(rsinfo, label, "a rate limiter is %zu bytes, not 8", (size_t) e->len);
        }
        if (e->type == KV_HASH && !kv_h_wellformed(kv_entry_value(e), e->len))
        {
            kv_verify_report(rsinfo, label, "the hash does not parse");
        }
        pfree(label);

        if (n == cap)
        {
            cap = cap == 0 ? 1024 : cap * 2;
            ptrs = ptrs ? repalloc(ptrs, sizeof(uint64) * cap) : palloc(sizeof(uint64) * cap);
            vers = vers ? repalloc(vers, sizeof(uint64) * cap) : palloc(sizeof(uint64) * cap);
        }
        ptrs[n] = (uint64) e->data;
        vers[n] = e->version;
        n++;
    }
    dshash_seq_term(&status);

    if (n > 1)
    {
        qsort(ptrs, n, sizeof(uint64), kv_u64_cmp);
        qsort(vers, n, sizeof(uint64), kv_u64_cmp);
        for (i = 1; i < n; i++)
        {
            if (ptrs[i] == ptrs[i - 1] && (i == 1 || ptrs[i] != ptrs[i - 2]))
            {
                kv_verify_report(rsinfo, NULL, "two entries share one allocation (%llu)",
                                 (unsigned long long) ptrs[i]);
                }
            if (vers[i] == vers[i - 1] && (i == 1 || vers[i] != vers[i - 2]))
            {
                kv_verify_report(rsinfo, NULL, "two entries have the version %llu",
                                 (unsigned long long) vers[i]);
                }
        }
    }
    return (Datum) 0;
}

#ifdef USE_ASSERT_CHECKING
/*
 * Test hook, assertion builds only, not part of the extension script: the
 * stress test creates it by hand. Prints the allocator's internal state to the
 * server log, so a test can check that a flushed store holds nothing but the
 * index's own structures.
 */
PG_FUNCTION_INFO_V1(kv_debug_dsa);

Datum
kv_debug_dsa(PG_FUNCTION_ARGS)
{
    if (!superuser())
        ereport(ERROR,
                (errcode(ERRCODE_INSUFFICIENT_PRIVILEGE),
                 errmsg("must be superuser to dump the memkv allocator")));
    kv_attach();
    dsa_dump(kv_dsa);
    PG_RETURN_VOID();
}

/*
 * Test hook, assertion builds only: damage one entry on purpose, so a test can
 * check that verify() notices. what is one of: hash (the key no longer matches
 * its hash), type (an unknown kind), len (a hash or limiter of the wrong size),
 * klen (the key length is off by one), cap (the value longer than its space). The
 * store should be flushed afterwards.
 */
PG_FUNCTION_INFO_V1(kv_debug_corrupt);

Datum
kv_debug_corrupt(PG_FUNCTION_ARGS)
{
    KVKey       key;
    char       *what = text_to_cstring(PG_GETARG_TEXT_PP(1));
    KVEntry    *e;

    if (!superuser())
        ereport(ERROR,
                (errcode(ERRCODE_INSUFFICIENT_PRIVILEGE),
                 errmsg("must be superuser to damage the memkv store")));
    kv_key(PG_GETARG_TEXT_PP(0), &key);
    e = kv_find(&key, true);
    if (e == NULL)
        ereport(ERROR,
                (errcode(ERRCODE_NO_DATA_FOUND),
                 errmsg("no such key")));
    if (strcmp(what, "hash") == 0)
        e->hash.w[0] ^= 1;
    else if (strcmp(what, "type") == 0)
        e->type = 99;
    else if (strcmp(what, "len") == 0)
        e->len -= 1;
    else if (strcmp(what, "klen") == 0)
        e->klen += 1;
    else if (strcmp(what, "cap") == 0)
        e->len = e->vcap + 1;
    else
    {
        dshash_release_lock(kv_hash, e);
        ereport(ERROR,
                (errcode(ERRCODE_INVALID_PARAMETER_VALUE),
                 errmsg("unknown kind of damage \"%s\"", what)));
    }
    dshash_release_lock(kv_hash, e);
    PG_RETURN_VOID();
}
#endif

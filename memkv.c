/*
 * memkv.c - Valkey-style key-value store in PostgreSQL shared memory.
 * Requires PostgreSQL 19+ (GetNamedDSA / GetNamedDSHash).
 *
 * Copyright (c) 2026, Bazyl Horsey. PostgreSQL License; see LICENSE.
 *
 * Keys hold either a string or a hash (field -> value map). When the value
 * store is full, memkv drops expired keys first and then evicts
 * least-recently-used keys (see memkv.eviction_policy).
 */
#include "postgres.h"

#include <limits.h>

#include "access/htup_details.h"
#include "catalog/pg_type.h"
#include "common/int.h"
#include "fmgr.h"
#include "funcapi.h"
#include "lib/dshash.h"
#include "lib/stringinfo.h"
#include "miscadmin.h"
#include "port/atomics.h"
#include "storage/dsm_registry.h"
#include "utils/array.h"
#include "utils/builtins.h"
#include "utils/dsa.h"
#include "utils/guc.h"
#include "utils/timestamp.h"
#include "utils/tuplestore.h"

PG_MODULE_MAGIC;

#define KV_KEY_LEN  128             /* max key bytes incl. NUL */
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
    KV_HASH = 1
} KVType;

typedef struct KVEntry
{
    char        key[KV_KEY_LEN];    /* hash key: must be first */
    dsa_pointer value;              /* value bytes, in kv_dsa */
    Size        len;
    TimestampTz expires_at;
    uint64      version;            /* changes whenever value changes */
    pg_atomic_uint64 atime;         /* last access; written under a shared lock */
    uint8       type;               /* KVType */
} KVEntry;

/* Server-wide counters, in a small named DSM segment. */
typedef struct KVShared
{
    pg_atomic_uint64 hits;
    pg_atomic_uint64 misses;
    pg_atomic_uint64 evicted;
    pg_atomic_uint64 expired;
    pg_atomic_uint64 version;       /* source of KVEntry.version */
} KVShared;

/* An eviction candidate, copied out of the index during a scan. */
typedef struct KVCandidate
{
    TimestampTz atime;
    char        key[KV_KEY_LEN];
} KVCandidate;

static const dshash_parameters kv_params = {
    .key_size = KV_KEY_LEN,
    .entry_size = sizeof(KVEntry),
    .compare_function = dshash_strcmp,
    .hash_function = dshash_strhash,
    .copy_function = dshash_strcpy,
    /* tranche_id is assigned by GetNamedDSHash() */
};

static dsa_area *kv_dsa = NULL;         /* value storage */
static dshash_table *kv_hash = NULL;    /* key index */
static KVShared *kv_shared = NULL;      /* counters */
static int  kv_max_memory_mb = 64;
static int  kv_eviction_policy = KV_EVICT_ALLKEYS_LRU;
static int  kv_applied_mb = -1;

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

void
_PG_init(void)
{
    DefineCustomIntVariable("memkv.max_memory",
                            "Approximate cap on shared memory for memkv values.",
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
    MarkGUCPrefixReserved("memkv");
}

static void
kv_shared_init(void *ptr, void *arg)
{
    KVShared   *s = (KVShared *) ptr;

    pg_atomic_init_u64(&s->hits, 0);
    pg_atomic_init_u64(&s->misses, 0);
    pg_atomic_init_u64(&s->evicted, 0);
    pg_atomic_init_u64(&s->expired, 0);
    pg_atomic_init_u64(&s->version, 0);
}

/* Attach to the shared store; the first caller on the server creates it. */
static void
kv_attach(void)
{
    bool        found;

    if (kv_shared == NULL)
        kv_shared = GetNamedDSMSegment("memkv_shared", sizeof(KVShared),
                                       kv_shared_init, &found, NULL);
    if (kv_dsa == NULL)
        kv_dsa = GetNamedDSA("memkv_values", &found);
    if (kv_hash == NULL)
        kv_hash = GetNamedDSHash("memkv_index", &kv_params, &found);

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

static void
kv_key_bytes(const char *data, Size len, char *buf)
{
    if (len >= KV_KEY_LEN)
        ereport(ERROR,
                (errcode(ERRCODE_PROGRAM_LIMIT_EXCEEDED),
                 errmsg("memkv keys can be at most %d bytes", KV_KEY_LEN - 1)));
    memcpy(buf, data, len);
    buf[len] = '\0';
}

static void
kv_key(text *t, char *buf)
{
    kv_key_bytes(VARDATA_ANY(t), VARSIZE_ANY_EXHDR(t), buf);
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
        dsa_free(kv_dsa, e->value);
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
        strlcpy(pool[0].key, e->key, KV_KEY_LEN);
        kv_pool_sift_down(pool, *n, 0);
        return;
    }
    else
        return;

    pool[i].atime = atime;
    strlcpy(pool[i].key, e->key, KV_KEY_LEN);
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
            dsa_free(kv_dsa, e->value);
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

        e = dshash_find(kv_hash, pool[i].key, true);
        if (e == NULL)
            continue;                   /* deleted meanwhile */
        if (kv_atime(e) != pool[i].atime)
        {
            /* used (or rewritten) since the scan, so no longer a candidate */
            dshash_release_lock(kv_hash, e);
            continue;
        }
        val = e->value;
        dshash_delete_entry(kv_hash, e);    /* also releases the lock */
        dsa_free(kv_dsa, val);
        evicted++;
    }
    kv_count(&kv_shared->evicted, evicted);
    return evicted;
}

/*
 * Allocate value space. Never call while holding a dshash lock: when the
 * store is full this sweeps expired keys and evicts others, which takes
 * those locks.
 */
static dsa_pointer
kv_alloc(Size len)
{
    Size        limit = (Size) kv_max_memory_mb * 1024 * 1024;
    KVCandidate *pool = NULL;
    dsa_pointer p;
    int         round = 0;
    int         stalls = 0;

    /* Don't wipe the store for a value that could never fit. */
    if (len >= limit)
        ereport(ERROR,
                (errcode(ERRCODE_PROGRAM_LIMIT_EXCEEDED),
                 errmsg("memkv value of %zu bytes does not fit in memkv.max_memory",
                        len)));

    for (;;)
    {
        int64       freed;
        int         ncand;

        p = dsa_allocate_extended(kv_dsa, Max(len, 1), DSA_ALLOC_NO_OOM);
        if (DsaPointerIsValid(p))
            break;

        CHECK_FOR_INTERRUPTS();

        if (kv_eviction_policy == KV_EVICT_NONE)
        {
            /* Old behaviour: drop expired keys once, then give up. */
            if (round++ > 0 || kv_purge(true) == 0)
                break;
            continue;
        }

        if (pool == NULL)
            pool = palloc(sizeof(KVCandidate) * KV_EVICT_MAX);
        freed = kv_evict_round(pool, round++, &ncand);
        if (freed > 0)
            stalls = 0;
        else if (ncand == 0 || ++stalls >= KV_EVICT_STALLS)
            break;                      /* nothing left we may evict */
    }

    if (pool != NULL)
        pfree(pool);
    if (!DsaPointerIsValid(p))
        ereport(ERROR,
                (errcode(ERRCODE_OUT_OF_MEMORY),
                 errmsg("memkv is full"),
                 kv_eviction_policy == KV_EVICT_VOLATILE_LRU ?
                 errhint("No keys with a TTL are left to evict. Add TTLs, "
                         "delete keys, or raise memkv.max_memory.") :
                 errhint("Delete keys, add TTLs, or raise memkv.max_memory.")));
    return p;
}

/* Copy bytes into a fresh value allocation (no lock may be held). */
static dsa_pointer
kv_alloc_copy(const char *data, Size len)
{
    dsa_pointer p = kv_alloc(len);

    memcpy(dsa_get_address(kv_dsa, p), data, len);
    return p;
}

/*
 * Find or insert a key with an exclusive lock, without erroring while we own
 * an unattached value: if the index can't grow, free newval and then error.
 */
static KVEntry *
kv_insert(const char *key, dsa_pointer newval, bool *found)
{
    KVEntry    *e = dshash_find_or_insert_extended(kv_hash, key, found,
                                                   DSHASH_INSERT_NO_OOM);

    if (e == NULL)
    {
        if (DsaPointerIsValid(newval))
            dsa_free(kv_dsa, newval);
        ereport(ERROR,
                (errcode(ERRCODE_OUT_OF_MEMORY),
                 errmsg("out of memory for the memkv index")));
    }
    return e;
}

/* Point a locked entry at a new value. Returns the old value to free. */
static dsa_pointer
kv_store(KVEntry *e, bool found, dsa_pointer newval, Size len, KVType type,
         TimestampTz now)
{
    dsa_pointer oldval = found ? e->value : InvalidDsaPointer;

    e->value = newval;
    e->len = len;
    e->type = (uint8) type;
    e->version = kv_next_version();
    pg_atomic_init_u64(&e->atime, (uint64) now);
    return oldval;
}

/* Remove a key seen as expired, re-checking under an exclusive lock. */
static void
kv_remove_expired(const char *key)
{
    KVEntry    *e = dshash_find(kv_hash, key, true);
    dsa_pointer val;

    if (e == NULL)
        return;
    if (!kv_expired(e, GetCurrentTimestamp()))
    {
        dshash_release_lock(kv_hash, e);
        return;
    }
    val = e->value;
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

/* Set one string key. Returns false if cond stopped the write. */
static bool
kv_set_one(const char *key, const char *data, Size len,
           TimestampTz expires_at, KVSetCond cond)
{
    dsa_pointer newval;
    dsa_pointer oldval;
    KVEntry    *e;
    bool        found;
    TimestampTz now;

    /* Copy the value into shared memory before taking any lock. */
    newval = kv_alloc_copy(data, len);
    now = GetCurrentTimestamp();

    if (cond == KV_SET_XX)
    {
        e = dshash_find(kv_hash, key, true);
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

    oldval = kv_store(e, found, newval, len, KV_STRING, now);
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
kv_get_one(const char *key, bool strict)
{
    KVEntry    *e;
    text       *result;
    TimestampTz now;

    e = dshash_find(kv_hash, key, false);
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
    result = cstring_to_text_with_len(dsa_get_address(kv_dsa, e->value),
                                      (int) e->len);
    dshash_release_lock(kv_hash, e);
    kv_count(&kv_shared->hits, 1);
    return result;
}

/* kv_set(key, value, ttl DEFAULT NULL, nx DEFAULT false, xx DEFAULT false) */
Datum
kv_set(PG_FUNCTION_ARGS)
{
    char        key[KV_KEY_LEN];
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

    kv_key(PG_GETARG_TEXT_PP(0), key);
    val = PG_GETARG_TEXT_PP(1);
    if (!PG_ARGISNULL(2))
        expires_at = kv_expiry(PG_GETARG_DATUM(2));

    kv_attach();
    PG_RETURN_BOOL(kv_set_one(key, VARDATA_ANY(val), VARSIZE_ANY_EXHDR(val),
                              expires_at,
                              nx ? KV_SET_NX : xx ? KV_SET_XX : KV_SET_ALWAYS));
}

/* kv_get(key) -> value, or NULL if missing or expired */
Datum
kv_get(PG_FUNCTION_ARGS)
{
    char        key[KV_KEY_LEN];
    text       *result;

    kv_key(PG_GETARG_TEXT_PP(0), key);
    kv_attach();

    result = kv_get_one(key, true);
    if (result == NULL)
        PG_RETURN_NULL();
    PG_RETURN_TEXT_P(result);
}

/* kv_del(key) -> true if a live key was removed */
Datum
kv_del(PG_FUNCTION_ARGS)
{
    char        key[KV_KEY_LEN];
    KVEntry    *e;
    dsa_pointer val;
    bool        live;

    kv_key(PG_GETARG_TEXT_PP(0), key);
    kv_attach();

    e = dshash_find(kv_hash, key, true);
    if (e == NULL)
        PG_RETURN_BOOL(false);
    live = !kv_expired(e, GetCurrentTimestamp());
    val = e->value;
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
    char        key[KV_KEY_LEN];
    KVEntry    *e;
    bool        live;

    kv_key(PG_GETARG_TEXT_PP(0), key);
    kv_attach();

    e = dshash_find(kv_hash, key, false);
    if (e == NULL)
        PG_RETURN_BOOL(false);
    live = !kv_expired(e, GetCurrentTimestamp());
    dshash_release_lock(kv_hash, e);
    if (!live)
        kv_remove_expired(key);
    PG_RETURN_BOOL(live);
}

/* kv_incr(key, amount DEFAULT 1) -> new value; keeps an existing TTL */
Datum
kv_incr(PG_FUNCTION_ARGS)
{
    char        key[KV_KEY_LEN];
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

    kv_key(PG_GETARG_TEXT_PP(0), key);
    kv_attach();

    /* Allocate before locking; any int64 fits in KV_INT_BUF bytes. */
    newval = kv_alloc(KV_INT_BUF);

    e = kv_insert(key, newval, &found);
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
        if (!kv_parse_int64(dsa_get_address(kv_dsa, e->value), e->len, &cur))
            not_int = true;
    }

    if (not_int || pg_add_s64_overflow(cur, amount, &result))
    {
        /* Leave the stored value alone; report after unlocking. */
        dshash_release_lock(kv_hash, e);
        dsa_free(kv_dsa, newval);
        if (not_int)
            ereport(ERROR,
                    (errcode(ERRCODE_INVALID_TEXT_REPRESENTATION),
                     errmsg("memkv value is not an integer")));
        ereport(ERROR,
                (errcode(ERRCODE_NUMERIC_VALUE_OUT_OF_RANGE),
                 errmsg("memkv increment would overflow")));
    }

    len = pg_lltoa(result, dsa_get_address(kv_dsa, newval));
    oldval = kv_store(e, found, newval, len, KV_STRING, now);
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
    char        key[KV_KEY_LEN];
    TimestampTz at;
    TimestampTz now;
    KVEntry    *e;
    bool        ok;

    kv_key(PG_GETARG_TEXT_PP(0), key);
    at = kv_expiry(PG_GETARG_DATUM(1));
    kv_attach();

    e = dshash_find(kv_hash, key, true);
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
    char        key[KV_KEY_LEN];
    KVEntry    *e;
    TimestampTz now;
    TimestampTz at;
    Interval   *result;

    kv_key(PG_GETARG_TEXT_PP(0), key);
    kv_attach();

    e = dshash_find(kv_hash, key, false);
    if (e == NULL)
        PG_RETURN_NULL();
    now = GetCurrentTimestamp();
    at = e->expires_at;
    dshash_release_lock(kv_hash, e);
    if (at <= now)
    {
        kv_remove_expired(key);
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
    char        key[KV_KEY_LEN];
    KVEntry    *e;
    TimestampTz now;
    bool        ok;

    kv_key(PG_GETARG_TEXT_PP(0), key);
    kv_attach();

    e = dshash_find(kv_hash, key, true);
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
    char        key[KV_KEY_LEN];

    n = kv_text_array(PG_GETARG_ARRAYTYPE_P(0), "keys", &keys);
    if (n == 0)
        PG_RETURN_ARRAYTYPE_P(construct_empty_array(TEXTOID));
    kv_attach();

    vals = palloc(sizeof(Datum) * n);
    nulls = palloc(sizeof(bool) * n);
    for (i = 0; i < n; i++)
    {
        text       *v;

        kv_key(DatumGetTextPP(keys[i]), key);
        v = kv_get_one(key, false);
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
    char        key[KV_KEY_LEN];

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

    /* Check every key before writing any. */
    for (i = 0; i < nkeys; i++)
        kv_key(DatumGetTextPP(keys[i]), key);

    kv_attach();
    for (i = 0; i < nkeys; i++)
    {
        text       *v = DatumGetTextPP(vals[i]);

        kv_key(DatumGetTextPP(keys[i]), key);
        kv_set_one(key, VARDATA_ANY(v), VARSIZE_ANY_EXHDR(v), expires_at,
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
kv_h_snapshot(const char *key, bool touch, Size *len, bool *present,
              uint64 *version)
{
    KVEntry    *e = dshash_find(kv_hash, key, false);
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
        memcpy(copy, dsa_get_address(kv_dsa, e->value), e->len);
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
kv_h_write(const char *key, KVHashOp op, const char *field, uint32 flen,
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
            np = kv_alloc_copy(nb, nlen);
            e = kv_insert(key, np, &found);
        }
        else
        {
            e = dshash_find(kv_hash, key, true);
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
            dsa_pointer val = e->value;

            dshash_delete_entry(kv_hash, e);
            dsa_free(kv_dsa, val);
        }
        else
        {
            dsa_pointer oldval = kv_store(e, found, np, nlen, KV_HASH, now);

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
    char        key[KV_KEY_LEN];
    text       *field = PG_GETARG_TEXT_PP(1);
    text       *val = PG_GETARG_TEXT_PP(2);

    kv_key(PG_GETARG_TEXT_PP(0), key);
    kv_attach();
    PG_RETURN_BOOL(kv_h_write(key, KV_H_SET,
                              VARDATA_ANY(field), kv_field_len(field),
                              VARDATA_ANY(val), kv_field_len(val), 0, NULL));
}

/* kv_hget(key, field) -> value, or NULL */
Datum
kv_hget(PG_FUNCTION_ARGS)
{
    char        key[KV_KEY_LEN];
    text       *field = PG_GETARG_TEXT_PP(1);
    char       *b;
    Size        len;
    bool        present;
    uint64      version;
    const char *v;
    uint32      vlen;

    kv_key(PG_GETARG_TEXT_PP(0), key);
    kv_attach();

    b = kv_h_snapshot(key, true, &len, &present, &version);
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
    char        key[KV_KEY_LEN];
    text       *field = PG_GETARG_TEXT_PP(1);

    kv_key(PG_GETARG_TEXT_PP(0), key);
    kv_attach();
    PG_RETURN_BOOL(kv_h_write(key, KV_H_DEL,
                              VARDATA_ANY(field), kv_field_len(field),
                              NULL, 0, 0, NULL));
}

/* kv_hlen(key) -> number of fields, 0 if missing */
Datum
kv_hlen(PG_FUNCTION_ARGS)
{
    char        key[KV_KEY_LEN];
    char       *b;
    Size        len;
    bool        present;
    uint64      version;

    kv_key(PG_GETARG_TEXT_PP(0), key);
    kv_attach();

    b = kv_h_snapshot(key, false, &len, &present, &version);
    PG_RETURN_INT64(b == NULL ? 0 : (int64) kv_h_count(b, len));
}

/* kv_hincr(key, field, amount DEFAULT 1) -> new value */
Datum
kv_hincr(PG_FUNCTION_ARGS)
{
    char        key[KV_KEY_LEN];
    text       *field = PG_GETARG_TEXT_PP(1);
    int64       amount = PG_GETARG_INT64(2);
    int64       result = 0;

    kv_key(PG_GETARG_TEXT_PP(0), key);
    kv_attach();
    kv_h_write(key, KV_H_INCR, VARDATA_ANY(field), kv_field_len(field),
               NULL, 0, amount, &result);
    PG_RETURN_INT64(result);
}

/* kv_hgetall(key) -> SETOF (field, value) */
Datum
kv_hgetall(PG_FUNCTION_ARGS)
{
    ReturnSetInfo *rsinfo = (ReturnSetInfo *) fcinfo->resultinfo;
    char        key[KV_KEY_LEN];
    char       *b;
    Size        len;
    bool        present;
    uint64      version;
    Size        pos = KV_H_HDR;
    const char *f;
    const char *v;
    uint32      flen;
    uint32      vlen;

    kv_key(PG_GETARG_TEXT_PP(0), key);
    InitMaterializedSRF(fcinfo, 0);
    kv_attach();

    b = kv_h_snapshot(key, true, &len, &present, &version);
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
    kv_attach();
    PG_RETURN_INT64(kv_purge(false));
}

/*
 * kv_stats() -> one row: live keys, keys with a TTL, value memory in use
 * (DSA segments, so it includes free space inside them), the cap, and
 * server-wide hit/miss/eviction/expiry counters since the store was made.
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

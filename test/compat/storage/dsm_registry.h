/*
 * Compile-check shim ONLY: lets memkv.c be type-checked against PG 16
 * headers when no PG 19 install is around. Declares the PG 17-19 APIs
 * memkv uses with their PG 19 signatures. Never link or ship this.
 */
#ifndef MEMKV_COMPAT_DSM_REGISTRY_H
#define MEMKV_COMPAT_DSM_REGISTRY_H
#include "lib/dshash.h"
#include "utils/dsa.h"
#include "datatype/timestamp.h"

extern void *GetNamedDSMSegment(const char *name, size_t size,
                                void (*init_callback) (void *ptr, void *arg),
                                bool *found, void *arg);
extern dsa_area *GetNamedDSA(const char *name, bool *found);

#define DSHASH_INSERT_NO_OOM 0x01
extern void *dshash_find_or_insert_extended(dshash_table *hash_table,
                                            const void *key, bool *found,
                                            int flags);
extern size_t dsa_get_total_size(dsa_area *area);

/* PG 19 names its LWLock tranches; older releases take no argument. */
#if PG_VERSION_NUM < 190000
#define LWLockNewTrancheId(name) LWLockNewTrancheId()
#endif

#ifndef INTERVAL_NOEND
#define INTERVAL_NOEND(i) \
    do { (i)->time = PG_INT64_MAX; (i)->day = PG_INT32_MAX; \
         (i)->month = PG_INT32_MAX; } while (0)
#endif
#ifndef pg_noreturn
#define pg_noreturn _Noreturn
#endif
#endif

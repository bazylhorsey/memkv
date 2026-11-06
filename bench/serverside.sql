-- Cost of the operation itself, with no protocol, no per-statement executor
-- startup and no commit: timed loops inside one PL/pgSQL block.
--
-- Run after bench/run.sh (it needs the bench_kv and bench_ctr tables and the
-- populated store that run.sh leaves behind):
--   psql -X -f bench/serverside.sql
--
-- Each figure is nanoseconds per operation with the cost of the empty loop
-- (building the key text) subtracted. kv_* calls are plain expressions;
-- the table side is a query, so it pays executor startup on every call. That
-- is exactly what code inside a function or trigger sees.
DO $$
DECLARE
    n       constant int := 1000000;
    t0      timestamptz;
    x       text;
    y       bigint;
    i       int;
    base    numeric;
    r       numeric;
BEGIN
    t0 := clock_timestamp();
    FOR i IN 1..n LOOP x := 'k' || (1 + i % 100000); END LOOP;
    base := extract(epoch FROM clock_timestamp() - t0) * 1e9 / n;
    RAISE NOTICE 'empty loop (key text only): % ns/iteration', round(base);

    t0 := clock_timestamp();
    FOR i IN 1..n LOOP x := kv_get('k' || (1 + i % 100000)); END LOOP;
    r := extract(epoch FROM clock_timestamp() - t0) * 1e9 / n - base;
    RAISE NOTICE 'get   memkv : % ns/op', round(r);

    t0 := clock_timestamp();
    FOR i IN 1..n LOOP SELECT v INTO x FROM bench_kv WHERE k = 'k' || (1 + i % 100000); END LOOP;
    r := extract(epoch FROM clock_timestamp() - t0) * 1e9 / n - base;
    RAISE NOTICE 'get   table : % ns/op', round(r);

    t0 := clock_timestamp();
    FOR i IN 1..n LOOP y := kv_incr('c' || (1 + i % 100000)); END LOOP;
    r := extract(epoch FROM clock_timestamp() - t0) * 1e9 / n - base;
    RAISE NOTICE 'incr  memkv : % ns/op', round(r);

    t0 := clock_timestamp();
    FOR i IN 1..n LOOP
        INSERT INTO bench_ctr AS t (k, n) VALUES ('c' || (1 + i % 100000), 1)
        ON CONFLICT (k) DO UPDATE SET n = t.n + 1 RETURNING t.n INTO y;
    END LOOP;
    r := extract(epoch FROM clock_timestamp() - t0) * 1e9 / n - base;
    RAISE NOTICE 'incr  table : % ns/op', round(r);

    t0 := clock_timestamp();
    FOR i IN 1..n LOOP PERFORM kv_set('k' || (1 + i % 100000), 'value'); END LOOP;
    r := extract(epoch FROM clock_timestamp() - t0) * 1e9 / n - base;
    RAISE NOTICE 'set   memkv : % ns/op', round(r);

    t0 := clock_timestamp();
    FOR i IN 1..n LOOP
        INSERT INTO bench_kv (k, v) VALUES ('k' || (1 + i % 100000), 'value')
        ON CONFLICT (k) DO UPDATE SET v = EXCLUDED.v;
    END LOOP;
    r := extract(epoch FROM clock_timestamp() - t0) * 1e9 / n - base;
    RAISE NOTICE 'set   table : % ns/op', round(r);
END $$;

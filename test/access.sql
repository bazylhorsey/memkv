-- Who may use memkv. Run it as the role that installs the extension, a
-- superuser. Every check is an ASSERT:
--   psql -X -v ON_ERROR_STOP=1 -f test/access.sql
CREATE EXTENSION IF NOT EXISTS memkv;
SELECT memkv.flush() \gset
-- a failed earlier run may have left the role and its grants behind
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'memkv_t_user') THEN
        DROP OWNED BY memkv_t_user;
        DROP ROLE memkv_t_user;
    END IF;
END $$;
CREATE ROLE memkv_t_user;

-- With no USAGE on the schema a role can't call anything, whatever the
-- functions' own privileges are.
DO $$
BEGIN
    SET LOCAL ROLE memkv_t_user;
    BEGIN
        PERFORM memkv.get('k');
        ASSERT false, 'a role without USAGE on the memkv schema must be refused';
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;
END $$;

-- With USAGE it can use the cache, but not the two functions that touch the
-- whole store.
GRANT USAGE ON SCHEMA memkv TO memkv_t_user;
DO $$
DECLARE
    r record;
BEGIN
    SET LOCAL ROLE memkv_t_user;
    ASSERT memkv.set('a', '1') AND memkv.get('a') = '1', 'set and get';
    ASSERT memkv.incr('n') = 1 AND memkv.rate_limit('lim', 3, interval '1 hour'), 'incr and rate_limit';
    ASSERT (SELECT keys FROM memkv.stats()) >= 3, 'stats';
    PERFORM memkv.sweep();

    BEGIN
        PERFORM memkv.flush();
        ASSERT false, 'flush must be refused';
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;
    BEGIN
        PERFORM memkv.verify();
        ASSERT false, 'verify must be refused';
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;
END $$;

-- The owner can hand either one out.
GRANT EXECUTE ON FUNCTION memkv.flush() TO memkv_t_user;
DO $$
BEGIN
    SET LOCAL ROLE memkv_t_user;
    ASSERT memkv.flush() >= 3, 'flush once granted';
    BEGIN
        PERFORM memkv.verify();
        ASSERT false, 'verify is still refused';
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;
END $$;
GRANT EXECUTE ON FUNCTION memkv.verify() TO memkv_t_user;
DO $$
BEGIN
    SET LOCAL ROLE memkv_t_user;
    ASSERT (SELECT count(*) FROM memkv.verify()) = 0, 'verify once granted';
END $$;

-- and the installing role always can
SELECT memkv.flush() \gset
SELECT count(*) AS problems FROM memkv.verify() \gset

DROP OWNED BY memkv_t_user;
DROP ROLE memkv_t_user;

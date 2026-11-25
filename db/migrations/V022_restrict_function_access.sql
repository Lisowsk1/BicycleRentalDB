-- V022: access control for the bicycle_rental schema.
--
-- 1. Deferred constraint-trigger functions run at COMMIT as the connected role,
--    so they become SECURITY DEFINER (with a fixed search_path). Without this
--    a restricted application role fails at commit.
-- 2. Every function and procedure in the schema is closed to PUBLIC (PostgreSQL grants
--    EXECUTE on new functions to PUBLIC by default).
-- 3. The application role bicycle_app may call only the operation functions
--    (the SECURITY DEFINER ones). Helpers and trigger functions stay internal.
--    Tables are not granted: all access goes through the operations.

-- 1. Deferred trigger functions (found from the catalog, not a fixed list).
DO $$
DECLARE
    f regprocedure;
BEGIN
    FOR f IN
        SELECT DISTINCT t.tgfoid::regprocedure
        FROM pg_trigger t
        JOIN pg_proc p ON p.oid = t.tgfoid
        WHERE p.pronamespace = 'bicycle_rental'::regnamespace
          AND NOT t.tgisinternal
          AND t.tgconstraint <> 0
          AND t.tgdeferrable
    LOOP
        EXECUTE format(
            'ALTER FUNCTION %s SECURITY DEFINER SET search_path = bicycle_rental, public, pg_temp',
            f);
    END LOOP;
END
$$;

-- 2. Close all existing functions and procedures, and future ones created by the migration role.
REVOKE ALL ON ALL ROUTINES IN SCHEMA bicycle_rental FROM PUBLIC;
ALTER DEFAULT PRIVILEGES IN SCHEMA bicycle_rental
    REVOKE EXECUTE ON ROUTINES FROM PUBLIC;

-- 3. Application role and its grants.
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'bicycle_app') THEN
        CREATE ROLE bicycle_app NOLOGIN;
    END IF;
END
$$;

GRANT USAGE ON SCHEMA bicycle_rental TO bicycle_app;

DO $$
DECLARE
    f regprocedure;
BEGIN
    FOR f IN
        SELECT p.oid::regprocedure
        FROM pg_proc p
        WHERE p.pronamespace = 'bicycle_rental'::regnamespace
          AND p.prokind IN ('f', 'p')
          AND p.prorettype <> 'trigger'::regtype
          AND p.prosecdef
    LOOP
        EXECUTE format('GRANT EXECUTE ON ROUTINE %s TO bicycle_app', f);
    END LOOP;
END
$$;

GRANT EXECUTE ON PROCEDURE bicycle_rental.submit_payment(bigint, uuid, bicycle_rental.payment_status, boolean)
    TO bicycle_app;
    
-- 4. Staff provisioning is a setup-administrator operation: it is not available to bicycle_app.
--    Only the owner/superuser and members of bicycle_setup can create staff accounts.
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'bicycle_setup') THEN
        CREATE ROLE bicycle_setup NOLOGIN;
    END IF;
END
$$;

GRANT USAGE ON SCHEMA bicycle_rental TO bicycle_setup;
REVOKE EXECUTE ON FUNCTION bicycle_rental.provision_staff(text, text, text, text) FROM bicycle_app;
GRANT EXECUTE ON FUNCTION bicycle_rental.provision_staff(text, text, text, text) TO bicycle_setup;

-- Note: functions added by later migrations are closed to PUBLIC automatically (default
-- privileges above) but must be granted to bicycle_app explicitly:
--   GRANT EXECUTE ON ROUTINE bicycle_rental.<operation>(...) TO bicycle_app;
-- Login roles used by the application should be granted membership in bicycle_app;
-- setup/administration logins that create staff accounts get bicycle_setup.

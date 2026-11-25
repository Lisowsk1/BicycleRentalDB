-- V023: Harden privileged_setup / privileged_reset checks so unprivileged roles
-- (such as bicycle_app) cannot bypass table guards via SET LOCAL.

SET LOCAL search_path = bicycle_rental, public;

-- 1. Require BOTH the GUC flag AND membership in bicycle_setup (or table ownership).
CREATE OR REPLACE FUNCTION bicycle_rental.is_privileged_setup()
RETURNS boolean
LANGUAGE sql STABLE
AS $$
    SELECT COALESCE(current_setting('bicycle_rental.privileged_setup', true) IN ('on', 'true'), false)
       AND pg_has_role(session_user, 'bicycle_setup', 'USAGE')
$$;

CREATE OR REPLACE FUNCTION bicycle_rental.is_privileged_reset()
RETURNS boolean
LANGUAGE sql STABLE
AS $$
    SELECT COALESCE(current_setting('bicycle_rental.privileged_reset', true) IN ('on', 'true'), false)
       AND pg_has_role(session_user, 'bicycle_setup', 'USAGE')
$$;

-- 2. Update V002's tariff & audit trigger functions to use the hardened checks.
CREATE OR REPLACE FUNCTION bicycle_rental.enforce_tariff_privileged_only()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NOT bicycle_rental.is_privileged_setup() THEN
        RAISE EXCEPTION 'Tariff records cannot be inserted, updated, or deleted operationally.';
    END IF;

    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    END IF;
    RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION bicycle_rental.enforce_audit_append_only()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NOT bicycle_rental.is_privileged_reset() THEN
        RAISE EXCEPTION 'Audit tables are append-only: % on % is prohibited.', TG_OP, TG_TABLE_NAME;
    END IF;
    RETURN OLD;
END;
$$;

-- 3. Verify that bicycle_app can execute submit_payment and its two phase functions.
GRANT EXECUTE ON FUNCTION bicycle_rental.prepare_payment_submission(bigint, uuid) TO bicycle_app;
GRANT EXECUTE ON FUNCTION bicycle_rental.confirm_payment_submission(bigint, uuid) TO bicycle_app;
GRANT EXECUTE ON PROCEDURE bicycle_rental.submit_payment(bigint, uuid, bicycle_rental.payment_status, boolean) TO bicycle_app;
GRANT EXECUTE ON FUNCTION bicycle_rental.is_privileged_setup() TO bicycle_setup;
GRANT EXECUTE ON FUNCTION bicycle_rental.is_privileged_reset() TO bicycle_setup;
-- V005: Rules the ERD marks as transaction-level notes (cannot be plain constraints).
--  * (a Rider row only for a rider-role account, a Staff row only for a staff-role account, and so
--    mutual exclusion, are enforced declaratively in V004 by role CHECKs + composite foreign keys)
--  * every account has exactly one matching subtype row (checked at commit)
--  * account identity and role never change (F-013, F-086)
--  * accounts and subtype rows are never deleted operationally (F-083); reset uses TRUNCATE (S-004)

-- Subtype key is its account identity: never re-pointed.
CREATE FUNCTION bicycle_rental.trg_forbid_account_id_change()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.account_id IS DISTINCT FROM OLD.account_id THEN
        RAISE EXCEPTION 'account_id of % cannot be changed', TG_TABLE_NAME USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER trg_rider_identity_immutable
    BEFORE UPDATE ON bicycle_rental.rider
    FOR EACH ROW EXECUTE FUNCTION bicycle_rental.trg_forbid_account_id_change();

CREATE TRIGGER trg_staff_identity_immutable
    BEFORE UPDATE ON bicycle_rental.staff
    FOR EACH ROW EXECUTE FUNCTION bicycle_rental.trg_forbid_account_id_change();

CREATE FUNCTION bicycle_rental.trg_account_identity_role_immutable()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.account_id IS DISTINCT FROM OLD.account_id THEN
        RAISE EXCEPTION 'account_id cannot be changed' USING ERRCODE = '23514';
    END IF;
    IF NEW.role IS DISTINCT FROM OLD.role THEN
        RAISE EXCEPTION 'account role cannot be changed' USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER trg_account_identity_role_immutable
    BEFORE UPDATE ON bicycle_rental.account
    FOR EACH ROW EXECUTE FUNCTION bicycle_rental.trg_account_identity_role_immutable();

-- Deferred: the account row and its subtype row are inserted in one transaction.
-- Runs at COMMIT: role rider => rider row and no staff row; role staff => staff row and no rider row.
CREATE FUNCTION bicycle_rental.trg_account_has_matching_subtype()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = bicycle_rental, pg_temp
AS $$
DECLARE
    v_is_rider boolean;
    v_is_staff boolean;
BEGIN
    SELECT EXISTS (SELECT 1 FROM rider r WHERE r.account_id = NEW.account_id),
           EXISTS (SELECT 1 FROM staff s WHERE s.account_id = NEW.account_id)
      INTO v_is_rider, v_is_staff;

    IF (NEW.role = 'rider' AND NOT (v_is_rider AND NOT v_is_staff))
       OR (NEW.role = 'staff' AND NOT (v_is_staff AND NOT v_is_rider)) THEN
        RAISE EXCEPTION 'account % (role %) must have exactly one matching % row',
            NEW.account_id, NEW.role, NEW.role USING ERRCODE = '23514';
    END IF;
    RETURN NULL;
END $$;

CREATE CONSTRAINT TRIGGER ctrg_account_has_matching_subtype
    AFTER INSERT ON bicycle_rental.account
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION bicycle_rental.trg_account_has_matching_subtype();

-- No operational deletion.
CREATE FUNCTION bicycle_rental.trg_forbid_delete()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    RAISE EXCEPTION 'rows of % cannot be deleted', TG_TABLE_NAME USING ERRCODE = '23000';
END $$;

CREATE TRIGGER trg_account_no_delete BEFORE DELETE ON bicycle_rental.account
    FOR EACH ROW EXECUTE FUNCTION bicycle_rental.trg_forbid_delete();
CREATE TRIGGER trg_rider_no_delete BEFORE DELETE ON bicycle_rental.rider
    FOR EACH ROW EXECUTE FUNCTION bicycle_rental.trg_forbid_delete();
CREATE TRIGGER trg_staff_no_delete BEFORE DELETE ON bicycle_rental.staff
    FOR EACH ROW EXECUTE FUNCTION bicycle_rental.trg_forbid_delete();

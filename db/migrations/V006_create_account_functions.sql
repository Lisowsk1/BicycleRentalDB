-- V006: Database operations for registration, login, account reads, blocking/unblocking and audit.
-- All public functions are SECURITY DEFINER with a fixed search_path. The acting account is passed
-- as p_actor_id: this is the trusted operation boundary (F-014/F-015) - the calling application
-- derives it from its validated session, never from client input.
-- Error codes: 42501 not permitted, 22023 invalid input, 23505 duplicate email, P0002 not found.

-- ---------- audit actor must be a staff account ----------
-- V002 attaches audit_entry.staff_id -> staff only if the staff table already existed. It did not
-- (staff arrives in V004), so the foreign key was never created. Add it here, where audit writes start
-- (F-070: the actor of an audit entry is a staff account). Skipped if it already exists.
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'fk_audit_entry_staff'
          AND conrelid = 'bicycle_rental.audit_entry'::regclass
    ) THEN
        ALTER TABLE bicycle_rental.audit_entry
            ADD CONSTRAINT fk_audit_entry_staff
            FOREIGN KEY (staff_id) REFERENCES bicycle_rental.staff (account_id)
            ON UPDATE RESTRICT ON DELETE RESTRICT;
    END IF;
END $$;
-- ---------- internal helpers (not granted to the application role) ----------

CREATE FUNCTION bicycle_rental.require_staff(p_actor_id bigint)
RETURNS void
LANGUAGE plpgsql STABLE
SET search_path = bicycle_rental, public, pg_temp
AS $$
BEGIN
    IF p_actor_id IS NULL OR NOT EXISTS (SELECT 1 FROM staff s WHERE s.account_id = p_actor_id) THEN
        RAISE EXCEPTION 'operation not permitted' USING ERRCODE = '42501';
    END IF;
END $$;

CREATE FUNCTION bicycle_rental.validate_new_account(
    p_first_name text, p_last_name text, p_email text, p_password text)
RETURNS void
LANGUAGE plpgsql IMMUTABLE
SET search_path = bicycle_rental, public, pg_temp
AS $$
BEGIN
    IF p_first_name IS NULL OR trim_ws(p_first_name) = '' THEN
        RAISE EXCEPTION 'first name is required' USING ERRCODE = '22023';
    END IF;
    IF p_last_name IS NULL OR trim_ws(p_last_name) = '' THEN
        RAISE EXCEPTION 'last name is required' USING ERRCODE = '22023';
    END IF;
    IF p_email IS NULL OR trim_ws(p_email) = '' THEN
        RAISE EXCEPTION 'email is required' USING ERRCODE = '22023';
    END IF;
    IF p_password IS NULL OR p_password = '' THEN
        RAISE EXCEPTION 'password is required' USING ERRCODE = '22023';
    END IF;
    -- bcrypt silently ignores bytes after 72; F-005 forbids silent truncation.
    IF octet_length(p_password) > 72 THEN
        RAISE EXCEPTION 'password is longer than 72 bytes' USING ERRCODE = '22023';
    END IF;
END $$;

-- Audit rows are written with bicycle_rental.record_audit_event (V002), inside the caller's transaction.

CREATE FUNCTION bicycle_rental.audit_detail_json(
    p_subject_type bicycle_rental.audit_record_type, p_subject_id bigint, p_field text, p_previous anyelement, p_new anyelement)
RETURNS jsonb
LANGUAGE sql IMMUTABLE
AS $$
    SELECT jsonb_build_object('subject_record_type', p_subject_type::text,
                              'subject_record_id',   p_subject_id,
                              'field_name',          p_field,
                              'previous_value',      to_jsonb(p_previous),
                              'new_value',           to_jsonb(p_new))
$$;

-- Creates an account + subtype row with a bcrypt hash (cost 12, per-password salt).
CREATE FUNCTION bicycle_rental.create_account_internal(
    p_role bicycle_rental.account_role,
    p_first_name text, p_last_name text, p_email text, p_password text)
RETURNS bigint
LANGUAGE plpgsql
SET search_path = bicycle_rental, public, pg_temp
AS $$
DECLARE
    v_account_id bigint;
BEGIN
    PERFORM validate_new_account(p_first_name, p_last_name, p_email, p_password);

    INSERT INTO account (first_name, last_name, email, password_hash, role)
    VALUES (p_first_name, p_last_name, trim_ws(p_email),
            crypt(p_password, gen_salt('bf', 12)), p_role)
    RETURNING account_id INTO v_account_id;

    IF p_role = 'rider' THEN
        INSERT INTO rider (account_id) VALUES (v_account_id);   -- status defaults to active (F-012)
    ELSE
        INSERT INTO staff (account_id) VALUES (v_account_id);
    END IF;
    RETURN v_account_id;
EXCEPTION
    WHEN unique_violation THEN
        RAISE EXCEPTION 'email address is already registered' USING ERRCODE = '23505';
END $$;

-- ---------- public operations ----------

-- F-003/F-004: public rider registration. Role and status are server-assigned.
CREATE FUNCTION bicycle_rental.register_rider(
    p_first_name text, p_last_name text, p_email text, p_password text)
RETURNS bigint
LANGUAGE sql SECURITY DEFINER
SET search_path = bicycle_rental, public, pg_temp
AS $$
    SELECT bicycle_rental.create_account_internal('rider', p_first_name, p_last_name, p_email, p_password)
$$;

-- F-013/S-001: privileged setup only. NOT granted to the application role.
CREATE FUNCTION bicycle_rental.provision_staff(
    p_first_name text, p_last_name text, p_email text, p_password text)
RETURNS bigint
LANGUAGE sql SECURITY DEFINER
SET search_path = bicycle_rental, public, pg_temp
AS $$
    SELECT bicycle_rental.create_account_internal('staff', p_first_name, p_last_name, p_email, p_password)
$$;

-- F-006: credential verification. Returns one row on success, no row on ANY failure
-- (unknown email, wrong password, missing input) so callers cannot tell them apart.
-- A blocked rider may log in (F-006/F-016). Session handling is the application's job (F-007..F-011).
CREATE FUNCTION bicycle_rental.authenticate_account(p_email text, p_password text)
RETURNS TABLE (account_id bigint, role bicycle_rental.account_role,
               first_name text, last_name text, email text,
               rider_status bicycle_rental.rider_status)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = bicycle_rental, public, pg_temp
AS $$
DECLARE
    v_id   bigint;
    v_hash text;
BEGIN
    IF p_email IS NULL OR p_password IS NULL OR p_password = '' OR octet_length(p_password) > 72 THEN
        PERFORM crypt('dummy', gen_salt('bf', 12));
        RETURN;
    END IF;

    SELECT a.account_id, a.password_hash INTO v_id, v_hash
      FROM account a
     WHERE normalize_email(a.email) = normalize_email(p_email);

    IF v_hash IS NULL THEN
        PERFORM crypt(p_password, gen_salt('bf', 12));   -- same cost as a real check
        RETURN;
    END IF;
    IF crypt(p_password, v_hash) <> v_hash THEN
        RETURN;
    END IF;

    RETURN QUERY
    SELECT a.account_id, a.role, a.first_name, a.last_name, a.email, r.status
      FROM account a
      LEFT JOIN rider r ON r.account_id = a.account_id
     WHERE a.account_id = v_id;
END $$;

-- F-015: a rider reads only their own account; staff read any. Never returns the hash.
-- block_reason is visible to staff only.
CREATE FUNCTION bicycle_rental.get_account(p_actor_id bigint, p_account_id bigint)
RETURNS TABLE (account_id bigint, first_name text, last_name text, email text,
               role bicycle_rental.account_role,
               rider_status bicycle_rental.rider_status, block_reason text)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = bicycle_rental, public, pg_temp
AS $$
DECLARE
    v_is_staff boolean;
BEGIN
    IF p_actor_id IS NULL THEN
        RAISE EXCEPTION 'operation not permitted' USING ERRCODE = '42501';
    END IF;
    v_is_staff := EXISTS (SELECT 1 FROM staff s WHERE s.account_id = p_actor_id);
    IF NOT v_is_staff THEN
        IF NOT EXISTS (SELECT 1 FROM rider r WHERE r.account_id = p_actor_id)
           OR p_account_id IS DISTINCT FROM p_actor_id THEN
            RAISE EXCEPTION 'operation not permitted' USING ERRCODE = '42501';
        END IF;
    END IF;

    RETURN QUERY
    SELECT a.account_id, a.first_name, a.last_name, a.email, a.role, r.status,
           CASE WHEN v_is_staff THEN r.block_reason END
      FROM account a
      LEFT JOIN rider r ON r.account_id = a.account_id
     WHERE a.account_id = p_account_id;
END $$;

-- Staff only.
CREATE FUNCTION bicycle_rental.list_riders(
    p_actor_id bigint, p_status bicycle_rental.rider_status DEFAULT NULL)
RETURNS TABLE (account_id bigint, first_name text, last_name text, email text,
               rider_status bicycle_rental.rider_status, block_reason text)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = bicycle_rental, public, pg_temp
AS $$
BEGIN
    PERFORM require_staff(p_actor_id);
    RETURN QUERY
    SELECT a.account_id, a.first_name, a.last_name, a.email, r.status, r.block_reason
      FROM rider r JOIN account a ON a.account_id = r.account_id
     WHERE p_status IS NULL OR r.status = p_status
     ORDER BY a.account_id;
END $$;

-- F-016/F-088/F-071: staff block a rider, optionally with a reason. Returns true when state changed.
--  * blank reason is treated as no reason
--  * already blocked + no/same reason => no-op, no audit entry (F-069)
--  * already blocked + different reason => reason updated and audited
CREATE FUNCTION bicycle_rental.block_rider(
    p_actor_id bigint, p_rider_id bigint, p_reason text DEFAULT NULL)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = bicycle_rental, public, pg_temp
AS $$
DECLARE
    v_reason     text := NULLIF(trim_ws(coalesce(p_reason, '')), '');
    v_old_status rider_status;
    v_old_reason text;
BEGIN
    PERFORM require_staff(p_actor_id);

    SELECT r.status, r.block_reason INTO v_old_status, v_old_reason
      FROM rider r WHERE r.account_id = p_rider_id
       FOR UPDATE;                       -- serializes against concurrent rental start/other changes (R-006)
    IF NOT FOUND THEN
        RAISE EXCEPTION 'rider % not found', p_rider_id USING ERRCODE = 'P0002';
    END IF;

    IF v_old_status = 'blocked' AND (v_reason IS NULL OR v_reason = v_old_reason) THEN
        RETURN false;
    END IF;

    UPDATE rider SET status = 'blocked', block_reason = v_reason WHERE account_id = p_rider_id;

    PERFORM record_audit_event(p_actor_id, 'rider_block', 'Rider', p_rider_id, jsonb_build_array(
        audit_detail_json('Rider', p_rider_id, 'status',       v_old_status::text, 'blocked'::text),
        audit_detail_json('Rider', p_rider_id, 'block_reason', v_old_reason,       v_reason)));
    RETURN true;
END $$;

-- Unblocking clears the block reason. Returns true when state changed.
CREATE FUNCTION bicycle_rental.unblock_rider(p_actor_id bigint, p_rider_id bigint)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = bicycle_rental, public, pg_temp
AS $$
DECLARE
    v_old_status rider_status;
    v_old_reason text;
BEGIN
    PERFORM require_staff(p_actor_id);

    SELECT r.status, r.block_reason INTO v_old_status, v_old_reason
      FROM rider r WHERE r.account_id = p_rider_id
       FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'rider % not found', p_rider_id USING ERRCODE = 'P0002';
    END IF;

    IF v_old_status = 'active' THEN
        RETURN false;
    END IF;

    UPDATE rider SET status = 'active', block_reason = NULL WHERE account_id = p_rider_id;

    PERFORM record_audit_event(p_actor_id, 'rider_unblock', 'Rider', p_rider_id, jsonb_build_array(
        audit_detail_json('Rider', p_rider_id, 'status',       v_old_status::text, 'active'::text),
        audit_detail_json('Rider', p_rider_id, 'block_reason', v_old_reason,       NULL::text)));
    RETURN true;
END $$;

-- F-076: staff-only audit queries, newest first, [from, to).
CREATE FUNCTION bicycle_rental.list_audit_entries(
    p_actor_id bigint,
    p_staff_id bigint DEFAULT NULL, p_action_type bicycle_rental.audit_action_type DEFAULT NULL,
    p_record_type bicycle_rental.audit_record_type DEFAULT NULL, p_record_id bigint DEFAULT NULL,
    p_from timestamptz DEFAULT NULL, p_to timestamptz DEFAULT NULL)
RETURNS TABLE (audit_id bigint, staff_id bigint, action_type bicycle_rental.audit_action_type,
               primary_record_type bicycle_rental.audit_record_type, primary_record_id bigint,
               created_at timestamptz)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = bicycle_rental, public, pg_temp
AS $$
BEGIN
    PERFORM require_staff(p_actor_id);
    RETURN QUERY
    SELECT e.audit_id, e.staff_id, e.action_type,
           e.primary_record_type, e.primary_record_id, e.created_at
      FROM audit_entry e
     WHERE (p_staff_id    IS NULL OR e.staff_id            = p_staff_id)
       AND (p_action_type IS NULL OR e.action_type         = p_action_type)
       AND (p_record_type IS NULL OR e.primary_record_type = p_record_type)
       AND (p_record_id   IS NULL OR e.primary_record_id   = p_record_id)
       AND (p_from        IS NULL OR e.created_at         >= p_from)
       AND (p_to          IS NULL OR e.created_at          < p_to)
     ORDER BY e.created_at DESC, e.audit_id DESC;
END $$;

CREATE FUNCTION bicycle_rental.get_audit_entry_details(p_actor_id bigint, p_audit_id bigint)
RETURNS TABLE (detail_no integer, subject_record_type bicycle_rental.audit_record_type,
               subject_record_id bigint, field_name text, previous_value jsonb, new_value jsonb)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = bicycle_rental, public, pg_temp
AS $$
BEGIN
    PERFORM require_staff(p_actor_id);
    RETURN QUERY
    SELECT d.detail_no, d.subject_record_type, d.subject_record_id,
           d.field_name::text, d.previous_value, d.new_value
      FROM audit_detail d WHERE d.audit_id = p_audit_id
     ORDER BY d.detail_no;
END $$;

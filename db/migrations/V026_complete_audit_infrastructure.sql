-- V026: Complete audit retrieval, affected-record filtering, query indexes,
-- and atomic audit coverage for staff operations in the maintenance stage.

SET LOCAL search_path = bicycle_rental, public;

CREATE INDEX idx_audit_entry_created_at_id
    ON bicycle_rental.audit_entry (created_at DESC, audit_id DESC);

CREATE INDEX idx_audit_entry_staff_action_created_at
    ON bicycle_rental.audit_entry (staff_id, action_type, created_at DESC);

CREATE INDEX idx_audit_detail_subject_record
    ON bicycle_rental.audit_detail (subject_record_type, subject_record_id, audit_id);

-- Match either the primary record or any associated AuditDetail subject. The
-- half-open date interval is retained for consistent paging by time window.
CREATE OR REPLACE FUNCTION bicycle_rental.list_audit_entries(
    p_actor_id bigint,
    p_staff_id bigint DEFAULT NULL,
    p_action_type bicycle_rental.audit_action_type DEFAULT NULL,
    p_record_type bicycle_rental.audit_record_type DEFAULT NULL,
    p_record_id bigint DEFAULT NULL,
    p_from timestamptz DEFAULT NULL,
    p_to timestamptz DEFAULT NULL)
RETURNS TABLE (
    audit_id bigint,
    staff_id bigint,
    action_type bicycle_rental.audit_action_type,
    primary_record_type bicycle_rental.audit_record_type,
    primary_record_id bigint,
    created_at timestamptz)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = bicycle_rental, public, pg_temp
AS $$
BEGIN
    PERFORM require_staff(p_actor_id);
    IF p_from IS NOT NULL AND p_to IS NOT NULL AND p_from > p_to THEN
        RAISE EXCEPTION 'audit date range start must not be after its end'
            USING ERRCODE = '22023';
    END IF;

    RETURN QUERY
    SELECT e.audit_id, e.staff_id, e.action_type,
           e.primary_record_type, e.primary_record_id, e.created_at
      FROM audit_entry e
     WHERE (p_staff_id IS NULL OR e.staff_id = p_staff_id)
       AND (p_action_type IS NULL OR e.action_type = p_action_type)
       AND (p_from IS NULL OR e.created_at >= p_from)
       AND (p_to IS NULL OR e.created_at < p_to)
       AND (
            (p_record_type IS NULL AND p_record_id IS NULL)
            OR ((p_record_type IS NULL OR e.primary_record_type = p_record_type)
                AND (p_record_id IS NULL OR e.primary_record_id = p_record_id))
            OR EXISTS (
                SELECT 1
                  FROM audit_detail d
                 WHERE d.audit_id = e.audit_id
                   AND (p_record_type IS NULL OR d.subject_record_type = p_record_type)
                   AND (p_record_id IS NULL OR d.subject_record_id = p_record_id)
            )
       )
     ORDER BY e.created_at DESC, e.audit_id DESC;
END $$;

-- Retrieve each matching entry together with all of its ordered details.
-- operation_type allows callers to filter precise maintenance-stage actions
-- while action_type retains the established enum and compatibility contract.
CREATE FUNCTION bicycle_rental.list_audit_entries_with_details(
    p_actor_id bigint,
    p_staff_id bigint DEFAULT NULL,
    p_action_type bicycle_rental.audit_action_type DEFAULT NULL,
    p_record_type bicycle_rental.audit_record_type DEFAULT NULL,
    p_record_id bigint DEFAULT NULL,
    p_from timestamptz DEFAULT NULL,
    p_to timestamptz DEFAULT NULL,
    p_operation_type text DEFAULT NULL)
RETURNS TABLE (
    audit_id bigint,
    staff_id bigint,
    action_type bicycle_rental.audit_action_type,
    primary_record_type bicycle_rental.audit_record_type,
    primary_record_id bigint,
    created_at timestamptz,
    operation_type text,
    detail_no integer,
    subject_record_type bicycle_rental.audit_record_type,
    subject_record_id bigint,
    field_name text,
    previous_value jsonb,
    new_value jsonb)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = bicycle_rental, public, pg_temp
AS $$
BEGIN
    PERFORM require_staff(p_actor_id);
    IF p_from IS NOT NULL AND p_to IS NOT NULL AND p_from > p_to THEN
        RAISE EXCEPTION 'audit date range start must not be after its end'
            USING ERRCODE = '22023';
    END IF;
    IF p_operation_type IS NOT NULL AND btrim(p_operation_type) = '' THEN
        RAISE EXCEPTION 'operation type filter must not be blank'
            USING ERRCODE = '22023';
    END IF;

    RETURN QUERY
    SELECT e.audit_id, e.staff_id, e.action_type,
           e.primary_record_type, e.primary_record_id, e.created_at,
           e.operation_type,
           d.detail_no, d.subject_record_type, d.subject_record_id,
           d.field_name::text, d.previous_value, d.new_value
      FROM audit_entry e
      LEFT JOIN audit_detail d ON d.audit_id = e.audit_id
     WHERE (p_staff_id IS NULL OR e.staff_id = p_staff_id)
       AND (p_action_type IS NULL OR e.action_type = p_action_type)
       AND (p_operation_type IS NULL OR e.operation_type = p_operation_type)
       AND (p_from IS NULL OR e.created_at >= p_from)
       AND (p_to IS NULL OR e.created_at < p_to)
       AND (
            (p_record_type IS NULL AND p_record_id IS NULL)
            OR ((p_record_type IS NULL OR e.primary_record_type = p_record_type)
                AND (p_record_id IS NULL OR e.primary_record_id = p_record_id))
            OR EXISTS (
                SELECT 1
                  FROM audit_detail matched
                 WHERE matched.audit_id = e.audit_id
                   AND (p_record_type IS NULL OR matched.subject_record_type = p_record_type)
                   AND (p_record_id IS NULL OR matched.subject_record_id = p_record_id)
            )
       )
     ORDER BY e.created_at DESC, e.audit_id DESC, d.detail_no;
END $$;

-- Build a deterministic list of changed fields from row snapshots.
CREATE FUNCTION bicycle_rental.audit_row_change_details(
    p_record_type bicycle_rental.audit_record_type,
    p_record_id bigint,
    p_old jsonb,
    p_new jsonb)
RETURNS jsonb
LANGUAGE sql IMMUTABLE
SET search_path = bicycle_rental, public, pg_temp
AS $$
    SELECT coalesce(
        jsonb_agg(jsonb_build_object(
            'subject_record_type', p_record_type::text,
            'subject_record_id', p_record_id,
            'field_name', changed.field_name,
            'previous_value', coalesce(p_old, '{}'::jsonb) -> changed.field_name,
            'new_value', coalesce(p_new, '{}'::jsonb) -> changed.field_name
        ) ORDER BY changed.field_name),
        '[]'::jsonb)
      FROM (
          SELECT keys.field_name
            FROM (
                SELECT field_name FROM jsonb_object_keys(coalesce(p_old, '{}'::jsonb)) AS old_keys(field_name)
                UNION
                SELECT field_name FROM jsonb_object_keys(coalesce(p_new, '{}'::jsonb)) AS new_keys(field_name)
            ) keys
           WHERE (coalesce(p_old, '{}'::jsonb) -> keys.field_name)
                 IS DISTINCT FROM
                 (coalesce(p_new, '{}'::jsonb) -> keys.field_name)
      ) changed
$$;

-- Operation wrappers below set the transaction-local actor and precise event
-- name. This trigger turns their successful row changes into atomic audit rows.
CREATE OR REPLACE FUNCTION bicycle_rental.audit_maintenance_mutation()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = bicycle_rental, public, pg_temp
AS $$
DECLARE
    v_actor_text text;
    v_actor_id bigint;
    v_bicycle_id bigint;
    v_old jsonb;
    v_new jsonb;
    v_operation text;
    v_details jsonb;
BEGIN
    v_actor_text := current_setting('bicycle_rental.audit_actor_id', true);
    IF v_actor_text IS NULL OR btrim(v_actor_text) = '' THEN
        RETURN NEW;
    END IF;
    v_actor_id := v_actor_text::bigint;
    IF NOT EXISTS (SELECT 1 FROM staff s WHERE s.account_id = v_actor_id) THEN
        RETURN NEW;
    END IF;

    CASE TG_TABLE_NAME
        WHEN 'fault_report' THEN v_bicycle_id := NEW.bicycle_id;
        WHEN 'maintenance_job' THEN v_bicycle_id := NEW.bicycle_id;
        WHEN 'maintenance_task' THEN
            SELECT mj.bicycle_id INTO v_bicycle_id
              FROM maintenance_job mj WHERE mj.job_id = NEW.maintenance_job_id;
        ELSE
            RAISE EXCEPTION 'audit trigger is not configured for table %', TG_TABLE_NAME;
    END CASE;
    v_operation := current_setting('bicycle_rental.audit_operation_type', true);
    IF v_operation IS NULL OR btrim(v_operation) = '' THEN
        RAISE EXCEPTION 'audit operation context is missing for table %', TG_TABLE_NAME;
    END IF;

    v_old := CASE WHEN TG_OP = 'INSERT' THEN NULL ELSE to_jsonb(OLD) END;
    v_new := to_jsonb(NEW);
    v_details := audit_row_change_details('Bicycle', v_bicycle_id, v_old, v_new);

    PERFORM record_audit_event(
        v_actor_id, 'maintenance_state_update', 'Bicycle', v_bicycle_id, v_details);
    RETURN NEW;
END $$;

CREATE TRIGGER trg_audit_fault_report_mutation
    AFTER INSERT OR UPDATE ON bicycle_rental.fault_report
    FOR EACH ROW EXECUTE FUNCTION bicycle_rental.audit_maintenance_mutation();

CREATE TRIGGER trg_audit_maintenance_job_mutation
    AFTER INSERT OR UPDATE ON bicycle_rental.maintenance_job
    FOR EACH ROW EXECUTE FUNCTION bicycle_rental.audit_maintenance_mutation();

CREATE TRIGGER trg_audit_maintenance_task_mutation
    AFTER INSERT OR UPDATE ON bicycle_rental.maintenance_task
    FOR EACH ROW EXECUTE FUNCTION bicycle_rental.audit_maintenance_mutation();

-- Preserve the existing locking and validation implementations while making
-- their database changes and audit events one atomic operation.
ALTER FUNCTION bicycle_rental.submit_fault_report(bigint, bigint, bicycle_rental.fault_category, bicycle_rental.fault_severity, text, bigint)
    RENAME TO submit_fault_report_without_audit;
ALTER FUNCTION bicycle_rental.link_fault_report_to_job(bigint, bigint, bigint)
    RENAME TO link_fault_report_to_job_without_audit;
ALTER FUNCTION bicycle_rental.review_fault_report(bigint, bigint, bicycle_rental.fault_status, bigint)
    RENAME TO review_fault_report_without_audit;
ALTER FUNCTION bicycle_rental.open_maintenance_job(bigint, bigint, bigint, bigint)
    RENAME TO open_maintenance_job_without_audit;
ALTER FUNCTION bicycle_rental.assign_maintenance_job(bigint, bigint, bigint, boolean, bigint, boolean)
    RENAME TO assign_maintenance_job_without_audit;
ALTER FUNCTION bicycle_rental.start_maintenance_job(bigint, bigint)
    RENAME TO start_maintenance_job_without_audit;
ALTER FUNCTION bicycle_rental.add_maintenance_task(bigint, bigint, bicycle_rental.maintenance_task_type, text, integer)
    RENAME TO add_maintenance_task_without_audit;
ALTER FUNCTION bicycle_rental.complete_maintenance_task(bigint, bigint, integer, text)
    RENAME TO complete_maintenance_task_without_audit;
ALTER FUNCTION bicycle_rental.complete_maintenance_job(bigint, bigint, text)
    RENAME TO complete_maintenance_job_without_audit;
ALTER FUNCTION bicycle_rental.cancel_maintenance_job(bigint, bigint, text)
    RENAME TO cancel_maintenance_job_without_audit;

REVOKE ALL ON FUNCTION bicycle_rental.submit_fault_report_without_audit(bigint, bigint, bicycle_rental.fault_category, bicycle_rental.fault_severity, text, bigint) FROM PUBLIC, bicycle_app;
REVOKE ALL ON FUNCTION bicycle_rental.link_fault_report_to_job_without_audit(bigint, bigint, bigint) FROM PUBLIC, bicycle_app;
REVOKE ALL ON FUNCTION bicycle_rental.review_fault_report_without_audit(bigint, bigint, bicycle_rental.fault_status, bigint) FROM PUBLIC, bicycle_app;
REVOKE ALL ON FUNCTION bicycle_rental.open_maintenance_job_without_audit(bigint, bigint, bigint, bigint) FROM PUBLIC, bicycle_app;
REVOKE ALL ON FUNCTION bicycle_rental.assign_maintenance_job_without_audit(bigint, bigint, bigint, boolean, bigint, boolean) FROM PUBLIC, bicycle_app;
REVOKE ALL ON FUNCTION bicycle_rental.start_maintenance_job_without_audit(bigint, bigint) FROM PUBLIC, bicycle_app;
REVOKE ALL ON FUNCTION bicycle_rental.add_maintenance_task_without_audit(bigint, bigint, bicycle_rental.maintenance_task_type, text, integer) FROM PUBLIC, bicycle_app;
REVOKE ALL ON FUNCTION bicycle_rental.complete_maintenance_task_without_audit(bigint, bigint, integer, text) FROM PUBLIC, bicycle_app;
REVOKE ALL ON FUNCTION bicycle_rental.complete_maintenance_job_without_audit(bigint, bigint, text) FROM PUBLIC, bicycle_app;
REVOKE ALL ON FUNCTION bicycle_rental.cancel_maintenance_job_without_audit(bigint, bigint, text) FROM PUBLIC, bicycle_app;

CREATE FUNCTION bicycle_rental.submit_fault_report(
    p_actor_id bigint, p_bicycle_id bigint, p_category bicycle_rental.fault_category,
    p_severity bicycle_rental.fault_severity, p_description text, p_rental_id bigint DEFAULT NULL)
RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER
SET search_path = bicycle_rental, public, pg_temp
AS $$
DECLARE
    v_old_actor text := current_setting('bicycle_rental.audit_actor_id', true);
    v_old_operation text := current_setting('bicycle_rental.audit_operation_type', true);
    v_id bigint;
BEGIN
    PERFORM set_config('bicycle_rental.audit_actor_id', coalesce(p_actor_id::text, ''), true);
    PERFORM set_config('bicycle_rental.audit_operation_type', 'fault_report_submit', true);
    v_id := submit_fault_report_without_audit(
        p_actor_id, p_bicycle_id, p_category, p_severity, p_description, p_rental_id);
    PERFORM set_config('bicycle_rental.audit_actor_id', coalesce(v_old_actor, ''), true);
    PERFORM set_config('bicycle_rental.audit_operation_type', coalesce(v_old_operation, ''), true);
    RETURN v_id;
END $$;

CREATE FUNCTION bicycle_rental.link_fault_report_to_job(p_actor_id bigint, p_report_id bigint, p_job_id bigint)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER
SET search_path = bicycle_rental, public, pg_temp
AS $$
DECLARE
    v_old_actor text := current_setting('bicycle_rental.audit_actor_id', true);
    v_old_operation text := current_setting('bicycle_rental.audit_operation_type', true);
    v_changed boolean;
BEGIN
    PERFORM set_config('bicycle_rental.audit_actor_id', coalesce(p_actor_id::text, ''), true);
    PERFORM set_config('bicycle_rental.audit_operation_type', 'fault_report_link', true);
    v_changed := link_fault_report_to_job_without_audit(p_actor_id, p_report_id, p_job_id);
    PERFORM set_config('bicycle_rental.audit_actor_id', coalesce(v_old_actor, ''), true);
    PERFORM set_config('bicycle_rental.audit_operation_type', coalesce(v_old_operation, ''), true);
    RETURN v_changed;
END $$;

CREATE FUNCTION bicycle_rental.review_fault_report(
    p_actor_id bigint, p_report_id bigint, p_status bicycle_rental.fault_status,
    p_maintenance_job_id bigint DEFAULT NULL)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER
SET search_path = bicycle_rental, public, pg_temp
AS $$
DECLARE
    v_old_actor text := current_setting('bicycle_rental.audit_actor_id', true);
    v_old_operation text := current_setting('bicycle_rental.audit_operation_type', true);
    v_changed boolean;
BEGIN
    PERFORM set_config('bicycle_rental.audit_actor_id', coalesce(p_actor_id::text, ''), true);
    PERFORM set_config('bicycle_rental.audit_operation_type', 'fault_report_review', true);
    v_changed := review_fault_report_without_audit(p_actor_id, p_report_id, p_status, p_maintenance_job_id);
    PERFORM set_config('bicycle_rental.audit_actor_id', coalesce(v_old_actor, ''), true);
    PERFORM set_config('bicycle_rental.audit_operation_type', coalesce(v_old_operation, ''), true);
    RETURN v_changed;
END $$;

CREATE FUNCTION bicycle_rental.open_maintenance_job(
    p_actor_id bigint, p_bicycle_id bigint, p_provider_id bigint DEFAULT NULL,
    p_assigned_staff_id bigint DEFAULT NULL)
RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER
SET search_path = bicycle_rental, public, pg_temp
AS $$
DECLARE
    v_old_actor text := current_setting('bicycle_rental.audit_actor_id', true);
    v_old_operation text := current_setting('bicycle_rental.audit_operation_type', true);
    v_id bigint;
BEGIN
    PERFORM set_config('bicycle_rental.audit_actor_id', coalesce(p_actor_id::text, ''), true);
    PERFORM set_config('bicycle_rental.audit_operation_type', 'maintenance_job_open', true);
    v_id := open_maintenance_job_without_audit(p_actor_id, p_bicycle_id, p_provider_id, p_assigned_staff_id);
    PERFORM set_config('bicycle_rental.audit_actor_id', coalesce(v_old_actor, ''), true);
    PERFORM set_config('bicycle_rental.audit_operation_type', coalesce(v_old_operation, ''), true);
    RETURN v_id;
END $$;

CREATE FUNCTION bicycle_rental.assign_maintenance_job(
    p_actor_id bigint, p_job_id bigint, p_provider_id bigint DEFAULT NULL,
    p_clear_provider boolean DEFAULT false, p_assigned_staff_id bigint DEFAULT NULL,
    p_clear_assigned_staff boolean DEFAULT false)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER
SET search_path = bicycle_rental, public, pg_temp
AS $$
DECLARE
    v_old_actor text := current_setting('bicycle_rental.audit_actor_id', true);
    v_old_operation text := current_setting('bicycle_rental.audit_operation_type', true);
    v_changed boolean;
BEGIN
    PERFORM set_config('bicycle_rental.audit_actor_id', coalesce(p_actor_id::text, ''), true);
    PERFORM set_config('bicycle_rental.audit_operation_type', 'maintenance_job_assign', true);
    v_changed := assign_maintenance_job_without_audit(
        p_actor_id, p_job_id, p_provider_id, p_clear_provider, p_assigned_staff_id, p_clear_assigned_staff);
    PERFORM set_config('bicycle_rental.audit_actor_id', coalesce(v_old_actor, ''), true);
    PERFORM set_config('bicycle_rental.audit_operation_type', coalesce(v_old_operation, ''), true);
    RETURN v_changed;
END $$;

CREATE FUNCTION bicycle_rental.start_maintenance_job(p_actor_id bigint, p_job_id bigint)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER
SET search_path = bicycle_rental, public, pg_temp
AS $$
DECLARE
    v_old_actor text := current_setting('bicycle_rental.audit_actor_id', true);
    v_old_operation text := current_setting('bicycle_rental.audit_operation_type', true);
    v_changed boolean;
BEGIN
    PERFORM set_config('bicycle_rental.audit_actor_id', coalesce(p_actor_id::text, ''), true);
    PERFORM set_config('bicycle_rental.audit_operation_type', 'maintenance_job_start', true);
    v_changed := start_maintenance_job_without_audit(p_actor_id, p_job_id);
    PERFORM set_config('bicycle_rental.audit_actor_id', coalesce(v_old_actor, ''), true);
    PERFORM set_config('bicycle_rental.audit_operation_type', coalesce(v_old_operation, ''), true);
    RETURN v_changed;
END $$;

CREATE FUNCTION bicycle_rental.add_maintenance_task(
    p_actor_id bigint, p_job_id bigint, p_task_type bicycle_rental.maintenance_task_type,
    p_description text, p_task_no integer DEFAULT NULL)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER
SET search_path = bicycle_rental, public, pg_temp
AS $$
DECLARE
    v_old_actor text := current_setting('bicycle_rental.audit_actor_id', true);
    v_old_operation text := current_setting('bicycle_rental.audit_operation_type', true);
    v_task_no integer;
BEGIN
    PERFORM set_config('bicycle_rental.audit_actor_id', coalesce(p_actor_id::text, ''), true);
    PERFORM set_config('bicycle_rental.audit_operation_type', 'maintenance_task_add', true);
    v_task_no := add_maintenance_task_without_audit(p_actor_id, p_job_id, p_task_type, p_description, p_task_no);
    PERFORM set_config('bicycle_rental.audit_actor_id', coalesce(v_old_actor, ''), true);
    PERFORM set_config('bicycle_rental.audit_operation_type', coalesce(v_old_operation, ''), true);
    RETURN v_task_no;
END $$;

CREATE FUNCTION bicycle_rental.complete_maintenance_task(
    p_actor_id bigint, p_job_id bigint, p_task_no integer, p_outcome text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path = bicycle_rental, public, pg_temp
AS $$
DECLARE
    v_old_actor text := current_setting('bicycle_rental.audit_actor_id', true);
    v_old_operation text := current_setting('bicycle_rental.audit_operation_type', true);
BEGIN
    PERFORM set_config('bicycle_rental.audit_actor_id', coalesce(p_actor_id::text, ''), true);
    PERFORM set_config('bicycle_rental.audit_operation_type', 'maintenance_task_complete', true);
    PERFORM complete_maintenance_task_without_audit(p_actor_id, p_job_id, p_task_no, p_outcome);
    PERFORM set_config('bicycle_rental.audit_actor_id', coalesce(v_old_actor, ''), true);
    PERFORM set_config('bicycle_rental.audit_operation_type', coalesce(v_old_operation, ''), true);
END $$;

CREATE FUNCTION bicycle_rental.complete_maintenance_job(p_actor_id bigint, p_job_id bigint, p_resolution text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path = bicycle_rental, public, pg_temp
AS $$
DECLARE
    v_old_actor text := current_setting('bicycle_rental.audit_actor_id', true);
    v_old_operation text := current_setting('bicycle_rental.audit_operation_type', true);
BEGIN
    PERFORM set_config('bicycle_rental.audit_actor_id', coalesce(p_actor_id::text, ''), true);
    PERFORM set_config('bicycle_rental.audit_operation_type', 'maintenance_job_complete', true);
    PERFORM complete_maintenance_job_without_audit(p_actor_id, p_job_id, p_resolution);
    PERFORM set_config('bicycle_rental.audit_actor_id', coalesce(v_old_actor, ''), true);
    PERFORM set_config('bicycle_rental.audit_operation_type', coalesce(v_old_operation, ''), true);
END $$;

CREATE FUNCTION bicycle_rental.cancel_maintenance_job(p_actor_id bigint, p_job_id bigint, p_resolution text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path = bicycle_rental, public, pg_temp
AS $$
DECLARE
    v_old_actor text := current_setting('bicycle_rental.audit_actor_id', true);
    v_old_operation text := current_setting('bicycle_rental.audit_operation_type', true);
BEGIN
    PERFORM set_config('bicycle_rental.audit_actor_id', coalesce(p_actor_id::text, ''), true);
    PERFORM set_config('bicycle_rental.audit_operation_type', 'maintenance_job_cancel', true);
    PERFORM cancel_maintenance_job_without_audit(p_actor_id, p_job_id, p_resolution);
    PERFORM set_config('bicycle_rental.audit_actor_id', coalesce(v_old_actor, ''), true);
    PERFORM set_config('bicycle_rental.audit_operation_type', coalesce(v_old_operation, ''), true);
END $$;

GRANT EXECUTE ON FUNCTION bicycle_rental.list_audit_entries_with_details(
    bigint, bigint, bicycle_rental.audit_action_type, bicycle_rental.audit_record_type,
    bigint, timestamptz, timestamptz, text) TO bicycle_app;
GRANT EXECUTE ON FUNCTION bicycle_rental.submit_fault_report(bigint, bigint, bicycle_rental.fault_category, bicycle_rental.fault_severity, text, bigint) TO bicycle_app;
GRANT EXECUTE ON FUNCTION bicycle_rental.link_fault_report_to_job(bigint, bigint, bigint) TO bicycle_app;
GRANT EXECUTE ON FUNCTION bicycle_rental.review_fault_report(bigint, bigint, bicycle_rental.fault_status, bigint) TO bicycle_app;
GRANT EXECUTE ON FUNCTION bicycle_rental.open_maintenance_job(bigint, bigint, bigint, bigint) TO bicycle_app;
GRANT EXECUTE ON FUNCTION bicycle_rental.assign_maintenance_job(bigint, bigint, bigint, boolean, bigint, boolean) TO bicycle_app;
GRANT EXECUTE ON FUNCTION bicycle_rental.start_maintenance_job(bigint, bigint) TO bicycle_app;
GRANT EXECUTE ON FUNCTION bicycle_rental.add_maintenance_task(bigint, bigint, bicycle_rental.maintenance_task_type, text, integer) TO bicycle_app;
GRANT EXECUTE ON FUNCTION bicycle_rental.complete_maintenance_task(bigint, bigint, integer, text) TO bicycle_app;
GRANT EXECUTE ON FUNCTION bicycle_rental.complete_maintenance_job(bigint, bigint, text) TO bicycle_app;
GRANT EXECUTE ON FUNCTION bicycle_rental.cancel_maintenance_job(bigint, bigint, text) TO bicycle_app;

REVOKE ALL ON FUNCTION bicycle_rental.audit_row_change_details(
    bicycle_rental.audit_record_type, bigint, jsonb, jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION bicycle_rental.audit_maintenance_mutation() FROM PUBLIC;

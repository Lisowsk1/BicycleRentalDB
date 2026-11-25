-- V028: Store maintenance events against the record actually changed, with
-- operation-specific actions/details. Earlier operations set transaction-local
-- actor and operation context in V026 wrappers.

CREATE OR REPLACE FUNCTION bicycle_rental.validate_audit_record_reference(
    p_record_type bicycle_rental.audit_record_type,
    p_record_id bigint
)
RETURNS void
LANGUAGE plpgsql
SET search_path = bicycle_rental, public, pg_temp
AS $$
DECLARE
    v_exists boolean;
BEGIN
    CASE p_record_type
        WHEN 'Rider' THEN
            SELECT EXISTS (SELECT 1 FROM rider WHERE account_id = p_record_id) INTO v_exists;
        WHEN 'Bicycle' THEN
            SELECT EXISTS (SELECT 1 FROM bicycle WHERE bicycle_id = p_record_id) INTO v_exists;
        WHEN 'Station' THEN
            SELECT EXISTS (SELECT 1 FROM station WHERE station_id = p_record_id) INTO v_exists;
        WHEN 'Rental' THEN
            SELECT EXISTS (SELECT 1 FROM rental WHERE rental_id = p_record_id) INTO v_exists;
        WHEN 'FaultReport' THEN
            SELECT EXISTS (SELECT 1 FROM fault_report WHERE report_id = p_record_id) INTO v_exists;
        WHEN 'MaintenanceJob' THEN
            SELECT EXISTS (SELECT 1 FROM maintenance_job WHERE job_id = p_record_id) INTO v_exists;
        ELSE
            RAISE EXCEPTION 'Unsupported audit record type %', p_record_type
                USING ERRCODE = '22023';
    END CASE;

    IF NOT v_exists THEN
        RAISE EXCEPTION 'Referenced % (%) does not exist.', p_record_type, p_record_id;
    END IF;
END;
$$;

CREATE FUNCTION bicycle_rental.audit_redacted_row_details(
    p_record_type bicycle_rental.audit_record_type,
    p_record_id bigint,
    p_old jsonb,
    p_new jsonb,
    p_excluded_fields text[])
RETURNS jsonb
LANGUAGE sql
STABLE
SET search_path = bicycle_rental, public, pg_temp
AS $$
    SELECT coalesce(jsonb_agg(details.detail ORDER BY details.ordinality), '[]'::jsonb)
      FROM jsonb_array_elements(
               audit_row_change_details(p_record_type, p_record_id, p_old, p_new)
           ) WITH ORDINALITY AS details(detail, ordinality)
     WHERE details.detail ->> 'field_name' <> ALL(p_excluded_fields)
$$;

CREATE OR REPLACE FUNCTION bicycle_rental.audit_maintenance_mutation()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = bicycle_rental, public, pg_temp
AS $$
DECLARE
    v_actor_text text;
    v_actor_id bigint;
    v_operation text;
    v_action bicycle_rental.audit_action_type;
    v_record_type bicycle_rental.audit_record_type;
    v_record_id bigint;
    v_old jsonb;
    v_new jsonb;
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

    v_operation := current_setting('bicycle_rental.audit_operation_type', true);
    IF v_operation IS NULL OR btrim(v_operation) = '' THEN
        RAISE EXCEPTION 'audit operation context is missing for table %', TG_TABLE_NAME;
    END IF;
    v_action := v_operation::bicycle_rental.audit_action_type;
    v_old := CASE WHEN TG_OP = 'INSERT' THEN NULL ELSE to_jsonb(OLD) END;
    v_new := to_jsonb(NEW);

    CASE TG_TABLE_NAME
        WHEN 'fault_report' THEN
            v_record_type := 'FaultReport';
            v_record_id := NEW.report_id;
            v_details := audit_redacted_row_details(
                v_record_type, v_record_id, v_old, v_new, ARRAY['description']);
        WHEN 'maintenance_job' THEN
            v_record_type := 'MaintenanceJob';
            v_record_id := NEW.job_id;
            v_details := audit_redacted_row_details(
                v_record_type, v_record_id, v_old, v_new, ARRAY['resolution']);
        WHEN 'maintenance_task' THEN
            v_record_type := 'MaintenanceJob';
            v_record_id := NEW.maintenance_job_id;
            SELECT coalesce(
                       jsonb_agg(
                           jsonb_set(
                               detail,
                               '{field_name}',
                               to_jsonb(format('task[%s].%s', NEW.task_no, detail ->> 'field_name'))
                           )
                           ORDER BY ordinality
                       ),
                       '[]'::jsonb)
              INTO v_details
              FROM jsonb_array_elements(
                       audit_redacted_row_details(
                           v_record_type, v_record_id, v_old, v_new,
                           ARRAY['description', 'outcome']
                       )
                   ) WITH ORDINALITY AS details(detail, ordinality);
        ELSE
            RAISE EXCEPTION 'audit trigger is not configured for table %', TG_TABLE_NAME;
    END CASE;

    PERFORM record_audit_event(v_actor_id, v_action, v_record_type, v_record_id, v_details);
    RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION bicycle_rental.validate_audit_record_reference(
    bicycle_rental.audit_record_type, bigint) FROM PUBLIC;
REVOKE ALL ON FUNCTION bicycle_rental.audit_redacted_row_details(
    bicycle_rental.audit_record_type, bigint, jsonb, jsonb, text[]) FROM PUBLIC;
REVOKE ALL ON FUNCTION bicycle_rental.audit_maintenance_mutation() FROM PUBLIC;

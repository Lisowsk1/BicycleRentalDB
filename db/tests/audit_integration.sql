-- End-to-end audit retrieval, maintenance workflow, transfer, and atomicity tests.
-- Run after all Flyway migrations with psql --set=ON_ERROR_STOP=1.
-- Fixtures and all audit rows are rolled back.
BEGIN;
SET LOCAL search_path = bicycle_rental, public, pg_temp;

CREATE TEMP TABLE audit_test_results (description text NOT NULL);

CREATE FUNCTION pg_temp.assert_true(p_condition boolean, p_description text)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    IF p_condition IS DISTINCT FROM true THEN
        RAISE EXCEPTION 'FAIL: %', p_description;
    END IF;
    INSERT INTO audit_test_results VALUES (p_description);
END $$;

CREATE FUNCTION pg_temp.reject_maintenance_audit()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.action_type IN ('maintenance_handover', 'maintenance_task_complete') THEN
        RAISE EXCEPTION 'injected audit insert failure' USING ERRCODE = 'P0001';
    END IF;
    RETURN NEW;
END $$;

DO $$
DECLARE
    v_staff bigint;
    v_rider bigint;
    v_station_a bigint;
    v_station_b bigint;
    v_provider bigint;
    v_bicycle bigint;
    v_report bigint;
    v_staff_report bigint;
    v_job bigint;
    v_task integer;
    v_rollback_job bigint;
    v_rollback_task integer;
    v_audit_id bigint;
    v_audit_before bigint;
    v_task_before jsonb;
    v_from timestamptz := clock_timestamp() - interval '1 minute';
    v_to timestamptz;
    v_state text;
BEGIN
    INSERT INTO account (first_name, last_name, email, password_hash, role)
    VALUES ('Audit', 'Staff', 'audit-staff-' || gen_random_uuid() || '@test.invalid',
            '$2a$12$' || repeat('x', 53), 'staff')
    RETURNING account_id INTO v_staff;
    INSERT INTO staff (account_id) VALUES (v_staff);

    INSERT INTO account (first_name, last_name, email, password_hash, role)
    VALUES ('Audit', 'Rider', 'audit-rider-' || gen_random_uuid() || '@test.invalid',
            '$2a$12$' || repeat('x', 53), 'rider')
    RETURNING account_id INTO v_rider;
    INSERT INTO rider (account_id) VALUES (v_rider);

    v_station_a := create_station(v_staff, 'Audit station A ' || gen_random_uuid(), 'Street A', 52, 21, true, true);
    v_station_b := create_station(v_staff, 'Audit station B ' || gen_random_uuid(), 'Street B', 52.1, 21.1, true, true);
    v_provider := create_maintenance_provider(v_staff, 'Audit provider ' || gen_random_uuid());
    v_bicycle := create_bicycle(v_staff, 'audit-' || gen_random_uuid(), 'regular', 'serviceable', v_station_a);

    -- Fault-to-repair-to-return runs through the public operation boundary.
    v_report := submit_fault_report(v_rider, v_bicycle, 'brakes', 'major', 'Brake cable is damaged');
    v_staff_report := submit_fault_report(v_staff, v_bicycle, 'tyres', 'minor', 'Tyre pressure is low');
    v_job := open_maintenance_job(v_staff, v_bicycle, v_provider, v_staff);
    PERFORM pg_temp.assert_true(link_fault_report_to_job(v_staff, v_report, v_job),
        'staff can link the reported fault to its maintenance job');
    PERFORM review_fault_report(v_staff, v_report, 'resolved', v_job);
    PERFORM handover_to_maintenance(v_staff, v_bicycle, v_provider);
    PERFORM start_maintenance_job(v_staff, v_job);
    v_task := add_maintenance_task(v_staff, v_job, 'repair', 'Replace brake cable');
    PERFORM complete_maintenance_task(v_staff, v_job, v_task, 'Cable replaced and adjusted');
    PERFORM complete_maintenance_job(v_staff, v_job, 'Brakes tested and serviceable');
    PERFORM return_from_maintenance(v_staff, v_bicycle, v_station_a, 'serviceable');
    PERFORM transfer_bicycle(v_staff, v_bicycle, v_station_a, v_station_b, 'Fleet balancing');

    PERFORM pg_temp.assert_true(
        (SELECT placement = 'station' AND current_station_id = v_station_b
           FROM bicycle WHERE bicycle_id = v_bicycle),
        'completed repair and transfer leave the bicycle at the destination station');
    PERFORM pg_temp.assert_true(
        (SELECT status = 'completed' AND resolution = 'Brakes tested and serviceable'
           FROM maintenance_job WHERE job_id = v_job),
        'maintenance job completion is persisted');
    PERFORM pg_temp.assert_true(
        (SELECT status = 'resolved' AND maintenance_job_id = v_job
           FROM fault_report WHERE report_id = v_report),
        'fault report is resolved and linked to its repair job');

    PERFORM pg_temp.assert_true(
        (SELECT count(*) = 0 FROM audit_entry
          WHERE operation_type = 'fault_report_submit'
            AND primary_record_type = 'FaultReport'
            AND primary_record_id = v_report),
        'rider fault submissions are not misattributed as staff administrative events');
    PERFORM pg_temp.assert_true(
        (SELECT count(*) = 1 FROM audit_entry
          WHERE operation_type = 'fault_report_submit'
            AND action_type = 'fault_report_submit'
            AND staff_id = v_staff
            AND primary_record_type = 'FaultReport'
            AND primary_record_id = v_staff_report),
        'staff fault submissions are attributed to staff and the correct report');
    PERFORM pg_temp.assert_true(
        (SELECT count(*) = 1 FROM audit_entry
          WHERE operation_type = 'fault_report_link'
            AND action_type = 'fault_report_link'
            AND staff_id = v_staff
            AND primary_record_type = 'FaultReport'
            AND primary_record_id = v_report),
        'staff fault linking has the correct action, actor and primary record');
    PERFORM pg_temp.assert_true(
        (SELECT count(*) > 0 FROM audit_detail d
          JOIN audit_entry e USING (audit_id)
          WHERE e.operation_type = 'fault_report_review'
            AND e.primary_record_type = 'FaultReport'
            AND e.primary_record_id = v_report
            AND d.subject_record_type = 'FaultReport'
            AND d.subject_record_id = v_report
            AND d.field_name = 'status'
            AND d.new_value = '"resolved"'::jsonb),
        'fault review details identify the changed FaultReport and status');
    PERFORM pg_temp.assert_true(
        (SELECT count(*) = 1 FROM audit_entry
          WHERE operation_type = 'maintenance_job_open'
            AND action_type = 'maintenance_job_open'
            AND staff_id = v_staff
            AND primary_record_type = 'MaintenanceJob'
            AND primary_record_id = v_job),
        'maintenance job opening has an accurate action and primary record');
    PERFORM pg_temp.assert_true(
        (SELECT count(*) > 0 FROM audit_detail d
          JOIN audit_entry e USING (audit_id)
          WHERE e.operation_type = 'maintenance_task_complete'
            AND e.primary_record_type = 'MaintenanceJob'
            AND e.primary_record_id = v_job
            AND d.subject_record_type = 'MaintenanceJob'
            AND d.subject_record_id = v_job
            AND d.field_name = format('task[%s].completed_at', v_task)
            AND d.previous_value IS NULL
            AND d.new_value IS NOT NULL),
        'task details identify the parent job and specific completion timestamp');
    PERFORM pg_temp.assert_true(
        (SELECT count(*) = 0 FROM audit_entry
          WHERE staff_id = v_staff
            AND action_type = 'maintenance_state_update'
            AND operation_type IN (
                'fault_report_submit', 'fault_report_link', 'fault_report_review',
                'maintenance_job_open', 'maintenance_job_start', 'maintenance_job_complete',
                'maintenance_task_add', 'maintenance_task_complete'
            )),
        'fault, job and task events do not masquerade as bicycle state updates');

    PERFORM pg_temp.assert_true(
        (SELECT count(DISTINCT audit_id) = 1 FROM list_audit_entries_with_details(
            v_staff, v_staff, 'maintenance_handover', 'Bicycle', v_bicycle,
            v_from, clock_timestamp() + interval '1 minute', NULL)),
        'audit filtering finds the maintenance handover by affected Bicycle');
    SELECT audit_id INTO v_audit_id
      FROM list_audit_entries_with_details(
          v_staff, v_staff, 'maintenance_handover', 'Bicycle', v_bicycle,
          v_from, NULL, NULL)
     LIMIT 1;
    PERFORM pg_temp.assert_true(
        (SELECT count(*) > 0 FROM list_audit_entries_with_details(
            v_staff, v_staff, 'maintenance_handover', 'Bicycle', v_bicycle,
            v_from, NULL, NULL)
          WHERE audit_id = v_audit_id AND field_name = 'placement'
            AND new_value = '"maintenance_provider"'::jsonb),
        'detailed audit retrieval returns ordered maintenance handover fields');

    v_to := clock_timestamp() + interval '1 minute';
    PERFORM pg_temp.assert_true(
        (SELECT count(*) > 0 FROM list_audit_entries_with_details(
            v_staff, v_staff, 'maintenance_job_complete', 'MaintenanceJob', v_job,
            v_from, v_to, 'maintenance_job_complete')),
        'staff, action, affected record and date filters work together');
    PERFORM pg_temp.assert_true(
        (SELECT count(*) = 0 FROM list_audit_entries(
            v_staff, v_staff, NULL, NULL, NULL, v_to, NULL)),
        'exclusive upper date bound returns no future entries');

    PERFORM pg_temp.assert_true(
        (SELECT count(*) >= 1 FROM list_audit_entries_with_details(
            v_staff, v_staff, 'maintenance_task_complete', 'MaintenanceJob', v_job,
            v_from, v_to, 'maintenance_task_complete')
          WHERE field_name = format('task[%s].completed_at', v_task)
            AND new_value IS NOT NULL),
        'task completion has an associated audit detail');
    PERFORM pg_temp.assert_true(
        (SELECT count(*) = 0 FROM audit_detail d
          JOIN audit_entry e USING (audit_id)
          WHERE e.primary_record_type IN ('FaultReport', 'MaintenanceJob')
            AND (
                d.field_name IN ('description', 'resolution', 'outcome')
                OR d.field_name LIKE 'task[%].description'
                OR d.field_name LIKE 'task[%].outcome'
            )),
        'free-text descriptions and outcomes are excluded from maintenance audit values');

    -- A failure to insert the audit entry must roll back the corresponding change.
    SELECT count(*) INTO v_audit_before FROM audit_entry;
    EXECUTE 'CREATE TRIGGER trg_test_reject_handover_audit
        BEFORE INSERT ON audit_entry
        FOR EACH ROW EXECUTE FUNCTION pg_temp.reject_maintenance_audit()';
    BEGIN
        PERFORM handover_to_maintenance(v_staff, v_bicycle, v_provider);
        RAISE EXCEPTION 'expected injected audit failure was not raised' USING ERRCODE = 'P0002';
    EXCEPTION WHEN SQLSTATE 'P0001' THEN
        NULL;
    END;
    EXECUTE 'DROP TRIGGER trg_test_reject_handover_audit ON audit_entry';

    SELECT placement || ':' || coalesce(current_station_id, 0)
      INTO v_state FROM bicycle WHERE bicycle_id = v_bicycle;
    PERFORM pg_temp.assert_true(v_state = 'station:' || v_station_b,
        'audit insert failure rolls back bicycle placement changes');
    PERFORM pg_temp.assert_true((SELECT count(*) = v_audit_before FROM audit_entry),
        'audit insert failure leaves no partial audit rows');

    v_rollback_job := open_maintenance_job(v_staff, v_bicycle, v_provider, v_staff);
    v_rollback_task := add_maintenance_task(v_staff, v_rollback_job, 'inspection', 'Check repaired bicycle');
    SELECT to_jsonb(mt) INTO v_task_before
      FROM maintenance_task mt
     WHERE mt.maintenance_job_id = v_rollback_job AND mt.task_no = v_rollback_task;
    SELECT count(*) INTO v_audit_before FROM audit_entry;
    EXECUTE 'CREATE TRIGGER trg_test_reject_task_audit
        BEFORE INSERT ON audit_entry
        FOR EACH ROW EXECUTE FUNCTION pg_temp.reject_maintenance_audit()';
    BEGIN
        PERFORM complete_maintenance_task(v_staff, v_rollback_job, v_rollback_task, 'Inspection passed');
        RAISE EXCEPTION 'expected injected task audit failure was not raised' USING ERRCODE = 'P0002';
    EXCEPTION WHEN SQLSTATE 'P0001' THEN
        NULL;
    END;
    EXECUTE 'DROP TRIGGER trg_test_reject_task_audit ON audit_entry';

    PERFORM pg_temp.assert_true(
        (SELECT to_jsonb(mt) = v_task_before
           FROM maintenance_task mt
          WHERE mt.maintenance_job_id = v_rollback_job AND mt.task_no = v_rollback_task),
        'task completion rolls back when its audit insert fails');
    PERFORM pg_temp.assert_true((SELECT count(*) = v_audit_before FROM audit_entry),
        'failed task completion leaves no partial audit rows');

    SET CONSTRAINTS ALL IMMEDIATE;
    SET CONSTRAINTS ALL DEFERRED;
END $$;

TABLE audit_test_results;
ROLLBACK;

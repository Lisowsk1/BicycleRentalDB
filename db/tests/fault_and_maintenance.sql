-- Verify FaultReport, MaintenanceProvider, MaintenanceJob, MaintenanceTask,
-- and maintenance audit logging (Issue #15).
-- Wrapped in a transaction and rolled back so the baseline seed remains intact.
--
-- Asserted error codes:
--   42501  not permitted (rider calling staff-only functions or linking another rider's rental to a fault report)
--   22023  invalid input (mismatched bicycle on rental/job links, or assigning a deactivated maintenance provider)
--   55000  business rule violation (duplicate active maintenance job on a bicycle, or completing a job with open tasks)
--   P0001  test assertion failure (raised if any expected rejection or post-condition check fails)

BEGIN;

DO $$
DECLARE
    v_staff_id      bigint;
    v_rider_id      bigint;
    v_other_rider   bigint;
    v_reg_bike_id   bigint;
    v_elc_bike_id   bigint;
    v_rental_id     bigint;
    v_station_id    bigint;
    v_provider_id   bigint;
    v_report_id     bigint;
    v_job_id        bigint;
    v_job_id_2      bigint;
    v_task_no       integer;
    v_audit_count   integer;
BEGIN
    -- Setup isolated actors and fetch seeded entities from V013
    v_staff_id := bicycle_rental.provision_staff(
        'Test', 'Staff', 'test.maint.staff@bicyclerental.local', 'StaffPass123!'
    );
    v_other_rider := bicycle_rental.register_rider(
        'Other', 'Rider', 'other.maint.rider@bicyclerental.local', 'RiderPass123!'
    );

    SELECT bicycle_id INTO v_reg_bike_id FROM bicycle_rental.bicycle WHERE identifier = 'BIKE-REG-001';
    SELECT bicycle_id INTO v_elc_bike_id FROM bicycle_rental.bicycle WHERE identifier = 'BIKE-ELC-001';
    SELECT r.rental_id, r.rider_id
      INTO v_rental_id, v_rider_id
      FROM bicycle_rental.rental r
     WHERE r.bicycle_id = v_reg_bike_id
     LIMIT 1;
    SELECT station_id INTO v_station_id FROM bicycle_rental.station LIMIT 1;
    SELECT station_id INTO v_station_id FROM bicycle_rental.station LIMIT 1;

    -- 1. MaintenanceProvider creation, update, and role enforcement (F-019, F-036)
    BEGIN
        PERFORM bicycle_rental.create_maintenance_provider(v_rider_id, 'Unauthorized Provider');
        RAISE EXCEPTION 'Rider should not be able to create a maintenance provider';
    EXCEPTION WHEN SQLSTATE '42501' THEN NULL;
    END;

    v_provider_id := bicycle_rental.create_maintenance_provider(
        v_staff_id, 'Wroclaw Service Hub', 'hub@wroclaw.local', '+48111222333'
    );
    IF NOT bicycle_rental.update_maintenance_provider(v_staff_id, v_provider_id, p_contact_phone => '+48444555666') THEN
        RAISE EXCEPTION 'Expected update_maintenance_provider to return true';
    END IF;

    -- 2. FaultReport submission & bicycle/rental ownership consistency (F-038..F-040)
    -- Reject mismatched bicycle vs. rental
    BEGIN
        PERFORM bicycle_rental.submit_fault_report(
            v_rider_id, v_elc_bike_id, 'battery', 'minor', 'Mismatched bike', v_rental_id
        );
        RAISE EXCEPTION 'Expected rejection for rental belonging to different bicycle';
    EXCEPTION WHEN SQLSTATE '22023' THEN NULL;
    END;

    -- Reject rider referencing another rider's rental
    BEGIN
        PERFORM bicycle_rental.submit_fault_report(
            v_other_rider, v_reg_bike_id, 'brakes', 'minor', 'Not my rental', v_rental_id
        );
        RAISE EXCEPTION 'Expected rejection for rider referencing another rider''s rental';
    EXCEPTION WHEN SQLSTATE '42501' THEN NULL;
    END;

    -- Valid rider submission with matching rental
    v_report_id := bicycle_rental.submit_fault_report(
        v_rider_id, v_reg_bike_id, 'brakes', 'major', 'Front brake lever loose', v_rental_id
    );

    -- Verify fault submission did not alter bicycle placement or maintenance_state (F-043)
    IF NOT EXISTS (
        SELECT 1 FROM bicycle_rental.bicycle
         WHERE bicycle_id = v_reg_bike_id
           AND placement = 'station'
           AND maintenance_state = 'serviceable'
    ) THEN
        RAISE EXCEPTION 'Fault submission must not alter bicycle placement or maintenance state';
    END IF;

    -- 3. MaintenanceJob opening & single active job per bicycle (F-044, F-045, R-007)
    v_job_id := bicycle_rental.open_maintenance_job(v_staff_id, v_reg_bike_id, v_provider_id, v_staff_id);

    -- Duplicate active job on same bicycle must fail
    BEGIN
        PERFORM bicycle_rental.open_maintenance_job(v_staff_id, v_reg_bike_id);
        RAISE EXCEPTION 'Expected rejection for second active maintenance job on same bicycle';
    EXCEPTION WHEN SQLSTATE '55000' THEN NULL;
    END;

    -- 4. Link FaultReport to MaintenanceJob & verify bicycle consistency (F-041)
    v_job_id_2 := bicycle_rental.open_maintenance_job(v_staff_id, v_elc_bike_id);
    BEGIN
        PERFORM bicycle_rental.link_fault_report_to_job(v_staff_id, v_report_id, v_job_id_2);
        RAISE EXCEPTION 'Expected rejection linking fault report to job of another bicycle';
    EXCEPTION WHEN SQLSTATE '22023' THEN NULL;
    END;

    IF NOT bicycle_rental.link_fault_report_to_job(v_staff_id, v_report_id, v_job_id) THEN
        RAISE EXCEPTION 'Expected link_fault_report_to_job to return true';
    END IF;

    -- 5. MaintenanceTask lifecycle & job completion gating (F-046..F-051)
    IF NOT bicycle_rental.start_maintenance_job(v_staff_id, v_job_id) THEN
        RAISE EXCEPTION 'Expected start_maintenance_job to return true';
    END IF;

    v_task_no := bicycle_rental.add_maintenance_task(
        v_staff_id, v_job_id, 'inspection', 'Inspect front brake cable and caliper'
    );
    IF v_task_no <> 1 THEN
        RAISE EXCEPTION 'Expected first task_no to be 1, got %', v_task_no;
    END IF;

    -- Completing job while task is incomplete must fail (F-050)
    BEGIN
        PERFORM bicycle_rental.complete_maintenance_job(v_staff_id, v_job_id, 'Premature completion');
        RAISE EXCEPTION 'Expected rejection completing job with incomplete tasks';
    EXCEPTION WHEN SQLSTATE '55000' THEN NULL;
    END;

    PERFORM bicycle_rental.complete_maintenance_task(
        v_staff_id, v_job_id, v_task_no, 'Tightened cable and aligned caliper'
    );
    PERFORM bicycle_rental.complete_maintenance_job(
        v_staff_id, v_job_id, 'Front brake serviced and verified'
    );

    -- Completing job must NOT automatically resolve linked fault report (F-043)
    IF NOT EXISTS (
        SELECT 1 FROM bicycle_rental.fault_report
         WHERE report_id = v_report_id AND status = 'open' AND resolved_at IS NULL
    ) THEN
        RAISE EXCEPTION 'Completing a job must not auto-resolve linked fault reports';
    END IF;

    -- Explicit review resolves the fault report and sets resolved_at (F-042)
    IF NOT bicycle_rental.review_fault_report(v_staff_id, v_report_id, 'resolved') THEN
        RAISE EXCEPTION 'Expected review_fault_report to return true';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM bicycle_rental.fault_report
         WHERE report_id = v_report_id AND status = 'resolved' AND resolved_at IS NOT NULL
    ) THEN
        RAISE EXCEPTION 'Resolved fault report must have non-null resolved_at';
    END IF;

    -- 6. Deactivated provider cannot receive new jobs or handovers (F-037, F-056)
    IF NOT bicycle_rental.set_maintenance_provider_active(v_staff_id, v_provider_id, false) THEN
        RAISE EXCEPTION 'Expected set_maintenance_provider_active to return true';
    END IF;

    BEGIN
        PERFORM bicycle_rental.open_maintenance_job(v_staff_id, v_reg_bike_id, v_provider_id);
        RAISE EXCEPTION 'Expected rejection assigning deactivated provider to new job';
    EXCEPTION WHEN SQLSTATE '22023' THEN NULL;
    END;

    -- 7. Audit logging for maintenance state/handover/return operations (F-053..F-055, F-100)
    PERFORM bicycle_rental.set_maintenance_provider_active(v_staff_id, v_provider_id, true);
    PERFORM bicycle_rental.handover_to_maintenance(v_staff_id, v_reg_bike_id, v_provider_id);
    PERFORM bicycle_rental.return_from_maintenance(v_staff_id, v_reg_bike_id, v_station_id, 'serviceable');

    SELECT count(*) INTO v_audit_count
      FROM bicycle_rental.audit_entry
     WHERE staff_id = v_staff_id
       AND primary_record_type = 'Bicycle'
       AND primary_record_id = v_reg_bike_id
       AND action_type IN ('maintenance_handover', 'maintenance_return');

    IF v_audit_count <> 2 THEN
        RAISE EXCEPTION 'Expected 2 maintenance audit entries, found %', v_audit_count;
    END IF;
END;
$$;

ROLLBACK;
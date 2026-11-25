-- ============================================================================
-- Demo Seed Script (runs on top of V001..V030)
-- ============================================================================

BEGIN;

SET LOCAL search_path = bicycle_rental, public;
SET LOCAL bicycle_rental.privileged_setup = 'true';

DO $$
DECLARE
    -- Existing V003 / V013 records
    v_reg_tariff_id        bigint;
    v_st_central_id        bigint;
    v_st_market_id         bigint;

    -- Staff & Riders
    v_staff_admin_id       bigint;
    v_staff_ops_id         bigint;
    v_rider_free_id        bigint;
    v_rider_blocked_id     bigint;
    v_rider_staff_ret_id   bigint;

    -- Stations
    v_st_campus_id         bigint;
    v_st_dropoff_id        bigint;
    v_st_closed_id         bigint;

    -- Bicycles
    v_bike_reg_2           bigint;
    v_bike_reg_3           bigint;
    v_bike_reg_maint       bigint;
    v_bike_elc_high        bigint;
    v_bike_elc_edge        bigint;
    v_bike_elc_low         bigint;
    v_bike_elc_null        bigint;
    v_bike_elc_shop        bigint;

    -- Maintenance
    v_provider_active_id   bigint;
    v_provider_inactive_id bigint;
    v_fault_open_id        bigint;
    v_job_id               bigint;
    v_task_1               integer;
    v_task_2               integer;

    -- Rentals
    v_staff_rental_id      bigint;
    v_hist_rental_id       bigint;
BEGIN
    -- Guard so re-running the script is safe
    IF EXISTS (
        SELECT 1 FROM bicycle_rental.account
         WHERE email = 'anna.nowak@bicyclerental.local'
    ) THEN
        RAISE NOTICE 'Demo seed already applied; skipping.';
        RETURN;
    END IF;

    -- Look up V003 active regular tariff and V013 stations
    SELECT tariff_id INTO v_reg_tariff_id
      FROM bicycle_rental.tariff
     WHERE bicycle_type = 'regular' AND is_active = true
     LIMIT 1;

    SELECT station_id INTO v_st_central_id
      FROM bicycle_rental.station WHERE name = 'Central Station' LIMIT 1;

    SELECT station_id INTO v_st_market_id
      FROM bicycle_rental.station WHERE name = 'Market Square' LIMIT 1;

    -- 1. Staff & Rider Accounts
    v_staff_admin_id := bicycle_rental.provision_staff(
        'Anna', 'Nowak', 'anna.nowak@bicyclerental.local', 'DemoStaff123!'
    );
    v_staff_ops_id := bicycle_rental.provision_staff(
        'Piotr', 'Zielinski', 'piotr.zielinski@bicyclerental.local', 'DemoStaff123!'
    );

    v_rider_free_id := bicycle_rental.register_rider(
        'Marta', 'Wisniewska', 'marta.wisniewska@bicyclerental.local', 'DemoRider123!'
    );

    v_rider_blocked_id := bicycle_rental.register_rider(
        'Tomasz', 'Lewandowski', 'tomasz.lewandowski@bicyclerental.local', 'DemoRider123!'
    );
    PERFORM bicycle_rental.block_rider(
        v_staff_admin_id,
        v_rider_blocked_id,
        'Unresolved brake damage reported after previous rental'
    );

    v_rider_staff_ret_id := bicycle_rental.register_rider(
        'Katarzyna', 'Wojcik', 'katarzyna.wojcik@bicyclerental.local', 'DemoRider123!'
    );

    -- 2. Stations covering all control combinations
    v_st_campus_id := bicycle_rental.create_station(
        v_staff_admin_id,
        'University Campus',
        'pl. Grunwaldzki 13, Wroclaw',
        51.1112000, 17.0595000,
        true, true
    );

    v_st_dropoff_id := bicycle_rental.create_station(
        v_staff_admin_id,
        'Old Town Drop-Off',
        'ul. Swidnicka 20, Wroclaw',
        51.1065000, 17.0321000,
        false, true
    );

    v_st_closed_id := bicycle_rental.create_station(
        v_staff_admin_id,
        'Depot North (Closed)',
        'ul. Osobowicka 45, Wroclaw',
        51.1380000, 17.0150000,
        false, false
    );

    -- 3. Fleet & Battery Edge Cases
    v_bike_reg_2 := bicycle_rental.create_bicycle(
        v_staff_ops_id, 'BIKE-REG-002', 'regular', 'serviceable', v_st_central_id, NULL
    );
    v_bike_reg_3 := bicycle_rental.create_bicycle(
        v_staff_ops_id, 'BIKE-REG-003', 'regular', 'serviceable', v_st_dropoff_id, NULL
    );
    v_bike_reg_maint := bicycle_rental.create_bicycle(
        v_staff_ops_id, 'BIKE-REG-004', 'regular', 'unavailable_for_maintenance', v_st_campus_id, NULL
    );

    v_bike_elc_high := bicycle_rental.create_bicycle(
        v_staff_ops_id, 'BIKE-ELC-002', 'electric', 'serviceable', v_st_campus_id, 92
    );
    v_bike_elc_edge := bicycle_rental.create_bicycle(
        v_staff_ops_id, 'BIKE-ELC-003', 'electric', 'serviceable', v_st_campus_id, 20
    );
    v_bike_elc_low := bicycle_rental.create_bicycle(
        v_staff_ops_id, 'BIKE-ELC-004', 'electric', 'serviceable', v_st_campus_id, 14
    );
    v_bike_elc_null := bicycle_rental.create_bicycle(
        v_staff_ops_id, 'BIKE-ELC-005', 'electric', 'serviceable', v_st_campus_id, NULL
    );
    v_bike_elc_shop := bicycle_rental.create_bicycle(
        v_staff_ops_id, 'BIKE-ELC-006', 'electric', 'serviceable', v_st_campus_id, 48
    );

    -- 4. Station-to-Station Transfer
    PERFORM bicycle_rental.transfer_bicycle(
        v_staff_ops_id,
        v_bike_reg_2,
        v_st_central_id,
        v_st_campus_id,
        'Morning rebalancing to University Campus'
    );

    -- 5. Maintenance Providers, Fault Report, Job & Tasks
    v_provider_active_id := bicycle_rental.create_maintenance_provider(
        v_staff_admin_id,
        'Wroclaw Bike Service Sp. z o.o.',
        'service@wroclawbikes.local',
        '+48 71 555 0101'
    );
    v_provider_inactive_id := bicycle_rental.create_maintenance_provider(
        v_staff_admin_id,
        'Legacy Cycles Workshop',
        'archived@legacycycles.local',
        '+48 71 555 0199'
    );
    PERFORM bicycle_rental.set_maintenance_provider_active(
        v_staff_admin_id, v_provider_inactive_id, false
    );

    v_fault_open_id := bicycle_rental.submit_fault_report(
        v_rider_free_id,
        v_bike_elc_shop,
        'brakes',
        'major',
        'Front disc brake squealing under light braking',
        NULL
    );

    PERFORM bicycle_rental.handover_to_maintenance(
        v_staff_ops_id, v_bike_elc_shop, v_provider_active_id
    );

    v_job_id := bicycle_rental.open_maintenance_job(
        v_staff_ops_id, v_bike_elc_shop, v_provider_active_id, v_staff_ops_id
    );
    PERFORM bicycle_rental.link_fault_report_to_job(
        v_staff_ops_id, v_fault_open_id, v_job_id
    );
    PERFORM bicycle_rental.start_maintenance_job(v_staff_ops_id, v_job_id);

    v_task_1 := bicycle_rental.add_maintenance_task(
        v_staff_ops_id, v_job_id, 'inspection', 'Inspect front caliper and rotor thickness', 1
    );
    v_task_2 := bicycle_rental.add_maintenance_task(
        v_staff_ops_id, v_job_id, 'repair', 'Replace front brake pads and test stopping distance', 2
    );
    PERFORM bicycle_rental.complete_maintenance_task(
        v_staff_ops_id, v_job_id, v_task_1, 'Pads worn below 1 mm; rotor within spec'
    );

    -- 6. Staff-Assisted Return & Pending Payments (submitted below after COMMIT)
    SELECT rental_id INTO v_staff_rental_id
      FROM bicycle_rental.start_rental(
          v_rider_staff_ret_id, v_bike_reg_2, v_reg_tariff_id
      );

    PERFORM bicycle_rental.staff_return_rental(
        v_staff_ops_id, v_staff_rental_id, v_st_dropoff_id
    );

    INSERT INTO bicycle_rental.payment_simulator_scenario (rental_id, scenario)
    VALUES (v_staff_rental_id, 'success_lost_response');

    PERFORM bicycle_rental.request_payment(v_rider_staff_ret_id, v_staff_rental_id);

    INSERT INTO bicycle_rental.rental (
        rider_id, bicycle_id, pickup_station_id, return_station_id, tariff_id,
        start_time, end_time,
        captured_price_per_block, captured_block_length_seconds, captured_currency,
        final_charge, bicycle_type
    )
    VALUES (
        v_rider_blocked_id, v_bike_reg_3, v_st_market_id, v_st_dropoff_id, v_reg_tariff_id,
        '2026-10-15 14:00:00+00', '2026-10-15 14:40:00+00',
        2.50, 900, 'PLN',
        7.50, 'regular'
    )
    RETURNING rental_id INTO v_hist_rental_id;

    INSERT INTO bicycle_rental.payment_simulator_scenario (rental_id, scenario)
    VALUES (v_hist_rental_id, 'failure');

    PERFORM bicycle_rental.request_payment(v_rider_blocked_id, v_hist_rental_id);
END $$;

COMMIT;

-- 7. Submit the two payments outside the transaction block using CALL
SELECT r.rider_id AS lost_rider_id,
       p.payment_reference AS lost_pay_ref,
       (p.status = 'pending' AND NOT EXISTS (
           SELECT 1 FROM bicycle_rental.payment_event pe
            WHERE pe.payment_id = p.payment_id
              AND pe.event_type = 'submission_attempted'
       )) AS run_lost_submit
  FROM bicycle_rental.payment p
  JOIN bicycle_rental.rental r ON r.rental_id = p.rental_id
  JOIN bicycle_rental.account a ON a.account_id = r.rider_id
 WHERE a.email = 'katarzyna.wojcik@bicyclerental.local'
\gset

\if :run_lost_submit
CALL bicycle_rental.submit_payment(:lost_rider_id, :'lost_pay_ref');
\endif

SELECT r.rider_id AS fail_rider_id,
       p.payment_reference AS fail_pay_ref,
       (p.status = 'pending') AS run_fail_submit
  FROM bicycle_rental.payment p
  JOIN bicycle_rental.rental r ON r.rental_id = p.rental_id
  JOIN bicycle_rental.account a ON a.account_id = r.rider_id
 WHERE a.email = 'tomasz.lewandowski@bicyclerental.local'
\gset

\if :run_fail_submit
CALL bicycle_rental.submit_payment(:fail_rider_id, :'fail_pay_ref');
\endif
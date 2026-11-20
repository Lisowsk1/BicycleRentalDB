-- Rental lifecycle tests: eligibility, start, return, staff return, pricing, retries, rollbacks.
-- Run after all migrations with psql --set=ON_ERROR_STOP=1. Needs a superuser or the table owner
-- (it switches session_replication_role to age a rental's start time).
-- All fixtures, helper functions and test-only triggers are rolled back.
BEGIN;
SET LOCAL search_path = bicycle_rental, public, pg_temp;

CREATE TEMP TABLE rental_test_results (description text NOT NULL);

CREATE FUNCTION pg_temp.assert_true(p_condition boolean, p_description text)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    IF p_condition IS DISTINCT FROM true THEN
        RAISE EXCEPTION 'FAIL: %', p_description;
    END IF;
    INSERT INTO rental_test_results VALUES (p_description);
END $$;

-- Check SQLSTATE, including deferred constraints, and roll back the rejected change.
CREATE FUNCTION pg_temp.expect_error(p_state text, p_sql text, p_description text)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    BEGIN
        EXECUTE p_sql;
        SET CONSTRAINTS ALL IMMEDIATE;
    EXCEPTION WHEN OTHERS THEN
        IF SQLSTATE <> p_state THEN
            RAISE EXCEPTION 'FAIL: %; expected SQLSTATE %, got %: %',
                p_description, p_state, SQLSTATE, SQLERRM;
        END IF;
        INSERT INTO rental_test_results VALUES (p_description);
        RETURN;
    END;
    RAISE EXCEPTION 'FAIL: %; expected SQLSTATE %, but command succeeded', p_description, p_state;
END $$;

-- Moves a rental's start into the past so durations and charges are deterministic.
-- start_time is immutable for operational code, so the guard triggers are skipped for this one update.
CREATE FUNCTION pg_temp.age_rental(p_rental bigint, p_seconds integer,
                                   p_price numeric DEFAULT NULL, p_block integer DEFAULT NULL)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    PERFORM set_config('session_replication_role', 'replica', true);
    UPDATE rental
       SET start_time = start_time - make_interval(secs => p_seconds),
           captured_price_per_block = coalesce(p_price, captured_price_per_block),
           captured_block_length_seconds = coalesce(p_block, captured_block_length_seconds)
     WHERE rental_id = p_rental;
    PERFORM set_config('session_replication_role', 'origin', true);
END $$;

CREATE FUNCTION pg_temp.reject_bicycle_rental_move() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN RAISE EXCEPTION 'injected placement failure'; END $$;
CREATE FUNCTION pg_temp.reject_audit() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN RAISE EXCEPTION 'injected audit failure'; END $$;

DO $$
DECLARE
    v_prefix  text := 'rent-' || gen_random_uuid();
    v_staff   bigint;  v_staff2 bigint;
    v_r1 bigint; v_r2 bigint; v_r3 bigint; v_r4 bigint; v_r5 bigint;
    v_a bigint; v_b bigint; v_closed bigint; v_norent bigint;
    v_reg1 bigint; v_reg2 bigint; v_reg3 bigint; v_reg4 bigint; v_el bigint; v_low bigint; v_miss bigint; v_maint bigint; v_inbikes bigint;
    v_t_reg tariff%ROWTYPE; v_t_el tariff%ROWTYPE;
    v_ret record;
    v_d rental_details;
    v_d2 rental_details;
    v_rent1 bigint; v_rent2 bigint; v_rent3 bigint;
    v_now_done boolean;
    v_count bigint;
    v_audit_before bigint;
    v_audit bigint;
    v_end timestamptz;
    v_reason text;
BEGIN
    -- fixtures
    INSERT INTO account (first_name, last_name, email, password_hash, role)
    VALUES ('Rent', 'Staff', v_prefix || '-s1@test.invalid', '$2a$12$' || repeat('x', 53), 'staff') RETURNING account_id INTO v_staff;
    INSERT INTO staff (account_id) VALUES (v_staff);
    INSERT INTO account (first_name, last_name, email, password_hash, role)
    VALUES ('Rent', 'Staff2', v_prefix || '-s2@test.invalid', '$2a$12$' || repeat('x', 53), 'staff') RETURNING account_id INTO v_staff2;
    INSERT INTO staff (account_id) VALUES (v_staff2);
    FOR i IN 1..5 LOOP
        INSERT INTO account (first_name, last_name, email, password_hash, role)
        VALUES ('Rent', 'Rider' || i, v_prefix || '-r' || i || '@test.invalid', '$2a$12$' || repeat('x', 53), 'rider')
        RETURNING account_id INTO v_count;
        INSERT INTO rider (account_id) VALUES (v_count);
        CASE i WHEN 1 THEN v_r1 := v_count; WHEN 2 THEN v_r2 := v_count; WHEN 3 THEN v_r3 := v_count;
               WHEN 4 THEN v_r4 := v_count; ELSE v_r5 := v_count; END CASE;
    END LOOP;

    v_a      := create_station(v_staff, v_prefix || ' A', 'Street A', 52.0, 21.0, true, true);
    v_b      := create_station(v_staff, v_prefix || ' B', 'Street B', 52.1, 21.1, true, true);
    v_closed := create_station(v_staff, v_prefix || ' closed returns', 'Street C', 52.2, 21.2, true, false);
    v_norent := create_station(v_staff, v_prefix || ' no rentals', 'Street D', 52.3, 21.3, false, true);
    v_reg1  := create_bicycle(v_staff, v_prefix || '-reg1', 'regular', 'serviceable', v_a);
    v_reg2  := create_bicycle(v_staff, v_prefix || '-reg2', 'regular', 'serviceable', v_a);
    v_reg3  := create_bicycle(v_staff, v_prefix || '-reg3', 'regular', 'serviceable', v_a);
    v_reg4  := create_bicycle(v_staff, v_prefix || '-reg4', 'regular', 'serviceable', v_a);
    v_el    := create_bicycle(v_staff, v_prefix || '-el',   'electric', 'serviceable', v_a, 50);
    v_low   := create_bicycle(v_staff, v_prefix || '-low',  'electric', 'serviceable', v_a, 19);
    v_miss  := create_bicycle(v_staff, v_prefix || '-miss', 'electric', 'serviceable', v_a);
    v_maint := create_bicycle(v_staff, v_prefix || '-maint', 'regular', 'unavailable_for_maintenance', v_a);
    v_inbikes := create_bicycle(v_staff, v_prefix || '-nr', 'regular', 'serviceable', v_norent);
    SELECT * INTO v_t_reg FROM tariff WHERE bicycle_type = 'regular' AND is_active;
    SELECT * INTO v_t_el  FROM tariff WHERE bicycle_type = 'electric' AND is_active;

    -- pricing arithmetic (F-054, F-055)
    PERFORM pg_temp.assert_true(calculate_rental_charge('2026-01-01 00:00:00+00', '2026-01-01 00:00:00+00', 1800, 2.50) = 0.00, 'zero duration costs zero blocks');
    PERFORM pg_temp.assert_true(calculate_rental_charge('2026-01-01 00:00:00+00', '2026-01-01 00:30:00+00', 1800, 2.50) = 2.50, 'exactly one block length is one block');
    PERFORM pg_temp.assert_true(calculate_rental_charge('2026-01-01 00:00:00+00', '2026-01-01 00:31:00+00', 1800, 2.50) = 5.00, '31 minutes with 30-minute blocks is two blocks');
    PERFORM pg_temp.assert_true(calculate_rental_charge('2026-01-01 00:00:00+00', '2026-01-01 00:30:00.000001+00', 1800, 2.50) = 5.00, 'one microsecond beyond a block starts another');
    PERFORM pg_temp.assert_true(calculate_rental_charge('2026-01-01 00:00:00+00', '2026-01-01 00:00:00.000001+00', 1800, 2.50) = 2.50, 'any positive duration costs at least one block');
    PERFORM pg_temp.assert_true(calculate_rental_charge('2026-01-01 00:00:00+00', '2026-01-01 05:00:00+00', 900, 0.00) = 0.00, 'zero price gives 0.00');
    PERFORM pg_temp.expect_error('22003', $q$SELECT calculate_rental_charge('2026-01-01', '2026-02-01', 1, 9999999999.99)$q$, 'charge overflow is rejected');

    -- eligibility (F-039, F-040)
    PERFORM pg_temp.assert_true((SELECT eligible AND reason IS NULL FROM check_rental_eligibility(v_r1, v_reg1)), 'eligible rider and regular bicycle');
    PERFORM pg_temp.assert_true((SELECT eligible FROM check_rental_eligibility(v_r1, v_el)), 'electric bicycle at 50% is eligible');
    PERFORM pg_temp.assert_true((SELECT reason = 'battery_below_20_percent' FROM check_rental_eligibility(v_r1, v_low)), 'electric bicycle at 19% is not eligible');
    PERFORM pg_temp.assert_true((SELECT reason = 'battery_reading_missing' FROM check_rental_eligibility(v_r1, v_miss)), 'electric bicycle without a reading is not eligible');
    PERFORM pg_temp.assert_true((SELECT reason = 'bicycle_unavailable_for_maintenance' FROM check_rental_eligibility(v_r1, v_maint)), 'bicycle unavailable for maintenance is not eligible');
    PERFORM pg_temp.assert_true((SELECT reason = 'station_rental_disabled' FROM check_rental_eligibility(v_r1, v_inbikes)), 'bicycle at a rental-disabled station is not eligible');
    PERFORM pg_temp.assert_true((SELECT reason = 'bicycle_not_found' FROM check_rental_eligibility(v_r1, -1)), 'unknown bicycle is not eligible');
    PERFORM update_battery(v_staff, v_low, 20);
    PERFORM pg_temp.assert_true((SELECT eligible FROM check_rental_eligibility(v_r1, v_low)), 'electric bicycle at exactly 20% is eligible');
    PERFORM update_battery(v_staff, v_low, 19);
    PERFORM block_rider(v_staff, v_r4, 'test');
    PERFORM pg_temp.assert_true((SELECT reason = 'rider_blocked' FROM check_rental_eligibility(v_r4, v_reg1)), 'blocked rider is not eligible');
    PERFORM pg_temp.expect_error('42501', format('SELECT * FROM check_rental_eligibility(%s, %s)', v_staff, v_reg1), 'staff cannot check rider eligibility');
    PERFORM pg_temp.expect_error('42501', format('SELECT start_rental(%s, %s)', v_staff, v_reg1), 'staff cannot start a rental as a rider');
    PERFORM pg_temp.expect_error('42501', format('SELECT start_rental(-1, %s)', v_reg1), 'unknown actor cannot start a rental');
    PERFORM pg_temp.expect_error('42501', format('SELECT start_rental(NULL, %s)', v_reg1), 'missing actor cannot start a rental');
    PERFORM pg_temp.expect_error('P0002', format('SELECT start_rental(%s, -1)', v_r1), 'unknown bicycle cannot be rented');

    -- ineligible starts change nothing
    SELECT count(*) INTO v_count FROM rental;
    PERFORM pg_temp.expect_error('55000', format('SELECT start_rental(%s, %s)', v_r4, v_reg1), 'blocked rider cannot start');
    PERFORM pg_temp.expect_error('55000', format('SELECT start_rental(%s, %s)', v_r1, v_low), 'low battery prevents start');
    PERFORM pg_temp.expect_error('55000', format('SELECT start_rental(%s, %s)', v_r1, v_miss), 'missing battery prevents start');
    PERFORM pg_temp.expect_error('55000', format('SELECT start_rental(%s, %s)', v_r1, v_maint), 'maintenance state prevents start');
    PERFORM pg_temp.expect_error('55000', format('SELECT start_rental(%s, %s)', v_r1, v_inbikes), 'rental-disabled station prevents start');
    PERFORM pg_temp.assert_true((SELECT count(*) = v_count FROM rental), 'rejected starts create no rental');
    PERFORM pg_temp.assert_true((SELECT bool_and(placement = 'station') FROM bicycle WHERE bicycle_id IN (v_reg1, v_low, v_miss, v_maint, v_inbikes)), 'rejected starts do not move bicycles');
    PERFORM pg_temp.expect_error('22023', format('SELECT start_rental(%s, %s, %s)', v_r1, v_reg1, v_t_el.tariff_id), 'stale or foreign pricing terms are rejected');
    PERFORM pg_temp.assert_true((SELECT count(*) = v_count FROM rental), 'stale pricing terms create no rental');

    -- rental start (F-041, F-042, F-053)
    v_d := start_rental(v_r1, v_reg1, v_t_reg.tariff_id);
    v_rent1 := v_d.rental_id;
    PERFORM pg_temp.assert_true(v_d.state = 'active' AND v_d.end_time IS NULL AND v_d.return_station_id IS NULL AND v_d.final_charge IS NULL, 'new rental is active without return details');
    PERFORM pg_temp.assert_true(v_d.pickup_station_id = v_a AND v_d.rider_id = v_r1 AND v_d.bicycle_id = v_reg1, 'start records rider, bicycle and pickup station');
    PERFORM pg_temp.assert_true(abs(extract(epoch FROM (clock_timestamp() - v_d.start_time))) < 60, 'start time is assigned by the server');
    PERFORM pg_temp.assert_true(v_d.price_per_block = v_t_reg.price_per_block AND v_d.block_length_seconds = v_t_reg.block_length_seconds AND v_d.currency = v_t_reg.currency, 'start captures the tariff terms');
    PERFORM pg_temp.assert_true((SELECT tariff_id = v_t_reg.tariff_id AND bicycle_type = 'regular' FROM rental WHERE rental_id = v_rent1), 'rental references the tariff of the bicycle type');
    PERFORM pg_temp.assert_true((SELECT placement = 'active_rental' AND current_station_id IS NULL FROM bicycle WHERE bicycle_id = v_reg1), 'start moves the bicycle to active rental and clears its station');
    PERFORM pg_temp.assert_true((SELECT regular_available = 3 FROM get_station_availability(v_r1, v_a)), 'a started rental is no longer counted as available');

    PERFORM pg_temp.expect_error('55000', format('SELECT start_rental(%s, %s)', v_r1, v_reg1), 'repeated start for the same rider and bicycle is rejected');
    PERFORM pg_temp.expect_error('55000', format('SELECT start_rental(%s, %s)', v_r1, v_reg2), 'rider with an active rental cannot start another');
    PERFORM pg_temp.expect_error('55000', format('SELECT start_rental(%s, %s)', v_r2, v_reg1), 'rented bicycle cannot be rented by another rider');
    PERFORM pg_temp.assert_true((SELECT count(*) = 1 FROM rental WHERE rider_id = v_r1 AND end_time IS NULL) AND (SELECT count(*) = 1 FROM rental WHERE bicycle_id = v_reg1 AND end_time IS NULL), 'repeated starts leave exactly one active rental per rider and bicycle');

    -- placement always matches rental state (F-029)
    PERFORM pg_temp.expect_error('23514', format('UPDATE bicycle SET placement = ''active_rental'', current_station_id = NULL WHERE bicycle_id = %s', v_reg3), 'bicycle cannot be placed on rental without a rental row');
    PERFORM pg_temp.expect_error('23514', format('UPDATE rental SET end_time = clock_timestamp(), return_station_id = %s, final_charge = 0 WHERE rental_id = %s', v_a, v_rent1), 'rental cannot complete without moving the bicycle back');
    PERFORM pg_temp.expect_error('23514', format('UPDATE bicycle SET placement = ''station'', current_station_id = %s WHERE bicycle_id = %s', v_a, v_reg1), 'rented bicycle cannot return to a station without completing its rental');

    -- lookups (F-048, F-049)
    PERFORM pg_temp.assert_true((SELECT count(*) = 1 AND bool_and(rental_id = v_rent1 AND bicycle_identifier = v_prefix || '-reg1' AND pickup_station_id = v_a) FROM get_active_rental(v_r1)), 'active rental lookup returns identity, bicycle identifier and pickup station');
    PERFORM pg_temp.assert_true((SELECT count(*) = 0 FROM get_active_rental(v_r2)), 'rider without an active rental gets no row');
    PERFORM pg_temp.assert_true((SELECT count(*) = 0 FROM get_rental_history(v_r2)), 'no history gives an empty result');
    PERFORM pg_temp.assert_true((SELECT count(*) = 1 AND bool_and(state = 'active' AND return_station_id IS NULL AND end_time IS NULL) FROM get_rental_history(v_r1)), 'active rental in history has no return details');
    PERFORM pg_temp.expect_error('42501', format('SELECT * FROM get_active_rental(%s)', v_staff), 'staff have no active rental lookup');
    PERFORM pg_temp.expect_error('P0002', format('SELECT get_rental(%s, %s)', v_r2, v_rent1), 'another rider cannot read a rental');
    PERFORM pg_temp.assert_true((get_rental(v_r1, v_rent1)).rental_id = v_rent1 AND (get_rental(v_staff, v_rent1)).rental_id = v_rent1, 'owner and staff can read a rental');

    -- return authorization and eligibility (F-043)
    PERFORM pg_temp.expect_error('P0002', format('SELECT * FROM return_rental(%s, %s, %s)', v_r2, v_rent1, v_b), 'another rider cannot return a rental and learns nothing about it');
    PERFORM pg_temp.expect_error('P0002', format('SELECT * FROM return_rental(%s, -1, %s)', v_r1, v_b), 'unknown rental id is rejected');
    PERFORM pg_temp.expect_error('42501', format('SELECT * FROM return_rental(%s, %s, %s)', v_staff, v_rent1, v_b), 'staff cannot use the rider return operation');
    PERFORM pg_temp.expect_error('42501', format('SELECT * FROM staff_return_rental(%s, %s, %s)', v_r1, v_rent1, v_b), 'riders cannot use the staff return operation');
    PERFORM pg_temp.expect_error('55000', format('SELECT * FROM return_rental(%s, %s, %s)', v_r1, v_rent1, v_closed), 'return-disabled destination rejects the return');
    PERFORM pg_temp.expect_error('22023', format('SELECT * FROM return_rental(%s, %s, -1)', v_r1, v_rent1), 'nonexistent destination rejects the return');
    PERFORM pg_temp.expect_error('22023', format('SELECT * FROM return_rental(%s, %s, NULL)', v_r1, v_rent1), 'missing destination rejects the return');
    PERFORM pg_temp.assert_true((SELECT end_time IS NULL AND return_station_id IS NULL AND final_charge IS NULL FROM rental WHERE rental_id = v_rent1)
        AND (SELECT placement = 'active_rental' FROM bicycle WHERE bicycle_id = v_reg1), 'rejected returns change nothing');

    -- rider return: blocking, maintenance and charge (F-043, F-044, F-054)
    PERFORM block_rider(v_staff, v_r1, 'blocked while renting');
    PERFORM pg_temp.assert_true((SELECT end_time IS NULL FROM rental WHERE rental_id = v_rent1), 'blocking does not end an active rental');
    PERFORM set_maintenance_state(v_staff, v_reg1, 'unavailable_for_maintenance');
    PERFORM pg_temp.assert_true((SELECT placement = 'active_rental' FROM bicycle WHERE bicycle_id = v_reg1), 'maintenance update does not end a rental');
    PERFORM pg_temp.age_rental(v_rent1, 31 * 60);          -- 31 minutes with the seeded 900-second blocks = 3 blocks
    SELECT * INTO v_ret FROM return_rental(v_r1, v_rent1, v_b); v_d := v_ret.details; v_now_done := v_ret.completed_now;
    PERFORM pg_temp.assert_true(v_now_done AND v_d.state = 'completed' AND v_d.return_station_id = v_b AND v_d.end_time >= v_d.start_time, 'blocked rider can return; completion records station and end time');
    PERFORM pg_temp.assert_true(v_d.final_charge = 3 * v_t_reg.price_per_block, 'final charge is started blocks times the captured price');
    PERFORM pg_temp.assert_true(NOT v_d.returned_by_staff, 'rider return is not marked staff-assisted');
    PERFORM pg_temp.assert_true((SELECT placement = 'station' AND current_station_id = v_b AND maintenance_state = 'unavailable_for_maintenance' FROM bicycle WHERE bicycle_id = v_reg1), 'return places the bicycle at the station and preserves maintenance state');
    PERFORM pg_temp.assert_true((SELECT count(*) = 0 FROM get_active_rental(v_r1)), 'completed rental is no longer active');
    PERFORM pg_temp.assert_true((SELECT count(*) = 1 AND bool_and(state = 'completed' AND return_station_name = v_prefix || ' B' AND returned_by_staff = false) FROM get_rental_history(v_r1)), 'history shows the completed rental with current station names');
    PERFORM unblock_rider(v_staff, v_r1);

    -- charge uses captured pricing, not current tariff (F-053, F-055)
    SELECT * INTO v_d FROM start_rental(v_r2, v_reg2);
    v_rent2 := v_d.rental_id;
    PERFORM pg_temp.age_rental(v_rent2, 2 * 3600 + 30, 10.00, 3600);      -- 2h30m, captured 10.00 per 3600 s -> 3 blocks
    PERFORM pg_temp.assert_true((SELECT (details).final_charge = 30.00 FROM return_rental(v_r2, v_rent2, v_a)), 'charge follows the captured price and block length');
    PERFORM pg_temp.assert_true((SELECT price_per_block = v_t_reg.price_per_block FROM tariff t WHERE t.tariff_id = v_t_reg.tariff_id), 'current tariff stays unchanged by captured-pricing test');

    -- electric rental: low battery during rental does not prevent return
    SELECT * INTO v_d FROM start_rental(v_r3, v_el, v_t_el.tariff_id);
    v_rent3 := v_d.rental_id;
    PERFORM pg_temp.assert_true(v_d.bicycle_type = 'electric' AND v_d.price_per_block = v_t_el.price_per_block, 'electric rental captures the electric tariff');
    PERFORM update_battery(v_staff, v_el, 3);
    PERFORM pg_temp.assert_true((SELECT end_time IS NULL FROM rental WHERE rental_id = v_rent3), 'low battery after start does not end the rental');
    PERFORM pg_temp.assert_true((SELECT (details).state = 'completed' FROM return_rental(v_r3, v_rent3, v_b)), 'low battery does not prevent return');
    PERFORM pg_temp.assert_true((SELECT battery_percentage = 3 FROM electric_bicycle WHERE bicycle_id = v_el), 'return keeps the battery reading');

    -- retries (F-045)
    SELECT (details).end_time INTO v_end FROM return_rental(v_r1, v_rent1, v_b);
    SELECT * INTO v_ret FROM return_rental(v_r1, v_rent1, v_b); v_d2 := v_ret.details; v_now_done := v_ret.completed_now;
    PERFORM pg_temp.assert_true(NOT v_now_done AND v_d2.end_time = v_end AND v_d2.final_charge = 3 * v_t_reg.price_per_block, 'retry reports the original completion and stored charge');
    PERFORM pg_temp.expect_error('RT409', format('SELECT * FROM return_rental(%s, %s, %s)', v_r1, v_rent1, v_a), 'retry with a different destination is a conflict');
    PERFORM set_station_controls(v_staff, v_b, true, false);
    PERFORM pg_temp.assert_true((SELECT NOT completed_now AND (details).end_time = v_end FROM return_rental(v_r1, v_rent1, v_b)), 'retry does not recheck station eligibility');
    PERFORM set_station_controls(v_staff, v_b, true, true);
    PERFORM pg_temp.expect_error('P0002', format('SELECT * FROM return_rental(%s, %s, %s)', v_r2, v_rent1, v_b), 'another rider cannot retry a completed rental');
    -- A later rental of the same bicycle is not affected by a retry of an earlier one.
    PERFORM set_maintenance_state(v_staff, v_reg1, 'serviceable');
    SELECT * INTO v_d FROM start_rental(v_r1, v_reg1);
    PERFORM pg_temp.assert_true((SELECT NOT completed_now FROM return_rental(v_r1, v_rent1, v_b)), 'earlier rental retry succeeds as a report');
    PERFORM pg_temp.assert_true((SELECT placement = 'active_rental' FROM bicycle WHERE bicycle_id = v_reg1) AND (SELECT end_time IS NULL FROM rental WHERE rental_id = v_d.rental_id), 'retry of an earlier rental does not complete or move the later rental''s bicycle');
    PERFORM pg_temp.assert_true((SELECT (details).state = 'completed' FROM staff_return_rental(v_staff, v_d.rental_id, v_a)), 'later rental can still be completed');

    -- staff-assisted return and audit (F-078..F-081)
    SELECT * INTO v_d FROM start_rental(v_r5, v_reg3);
    PERFORM pg_temp.age_rental(v_d.rental_id, 901);
    SELECT count(*) INTO v_audit_before FROM audit_entry;
    SELECT * INTO v_ret FROM staff_return_rental(v_staff, v_d.rental_id, v_b); v_d2 := v_ret.details; v_now_done := v_ret.completed_now;
    PERFORM pg_temp.assert_true(v_now_done AND v_d2.state = 'completed' AND v_d2.returned_by_staff AND v_d2.final_charge = 2 * v_t_reg.price_per_block, 'staff-assisted return uses the same charging rules and marks staff attribution');
    PERFORM pg_temp.assert_true((SELECT returned_by_staff_id = v_staff AND rider_id = v_r5 FROM rental WHERE rental_id = v_d.rental_id), 'staff identity stored; the rider remains the owner');
    PERFORM pg_temp.assert_true((SELECT placement = 'station' AND current_station_id = v_b FROM bicycle WHERE bicycle_id = v_reg3), 'staff return places the bicycle at the destination');
    PERFORM pg_temp.assert_true((SELECT count(*) = v_audit_before + 1 FROM audit_entry), 'staff return writes exactly one audit entry');
    SELECT audit_id INTO v_audit FROM audit_entry ORDER BY audit_id DESC LIMIT 1;
    PERFORM pg_temp.assert_true((SELECT staff_id = v_staff AND action_type = 'staff_return' AND primary_record_type = 'Rental' AND primary_record_id = v_d.rental_id FROM audit_entry WHERE audit_id = v_audit), 'audit entry identifies actor, action and rental');
    PERFORM pg_temp.assert_true((SELECT count(*) = 8 FROM audit_detail WHERE audit_id = v_audit)
        AND (SELECT new_value = to_jsonb(v_b) FROM audit_detail WHERE audit_id = v_audit AND field_name = 'return_station_id')
        AND (SELECT previous_value = to_jsonb('active_rental'::text) AND new_value = to_jsonb('station'::text) FROM audit_detail WHERE audit_id = v_audit AND field_name = 'placement')
        AND (SELECT new_value = to_jsonb(v_staff) FROM audit_detail WHERE audit_id = v_audit AND field_name = 'returned_by_staff_id'), 'audit details record rental and bicycle placement changes');
    PERFORM pg_temp.assert_true((SELECT NOT completed_now FROM staff_return_rental(v_staff, v_d.rental_id, v_b)), 'staff retry reports the original completion');
    PERFORM pg_temp.assert_true((SELECT NOT completed_now AND (details).returned_by_staff FROM staff_return_rental(v_staff2, v_d.rental_id, v_b)), 'retry by another staff member keeps the original attribution');
    PERFORM pg_temp.assert_true((SELECT returned_by_staff_id = v_staff FROM rental WHERE rental_id = v_d.rental_id), 'original staff identity is not replaced');
    PERFORM pg_temp.assert_true((SELECT NOT completed_now FROM return_rental(v_r5, v_d.rental_id, v_b)), 'rider retry of a staff-completed return reports it');
    PERFORM pg_temp.expect_error('RT409', format('SELECT * FROM staff_return_rental(%s, %s, %s)', v_staff, v_d.rental_id, v_a), 'staff retry with another destination is a conflict');
    PERFORM pg_temp.assert_true((SELECT count(*) = v_audit_before + 1 FROM audit_entry), 'retries and conflicts write no further audit entries');
    -- Rider-completed rental cannot be reclassified by a later staff retry.
    PERFORM pg_temp.assert_true((SELECT NOT (details).returned_by_staff AND NOT completed_now FROM staff_return_rental(v_staff, v_rent1, v_b)), 'staff retry cannot reclassify a rider-completed return');
    PERFORM pg_temp.assert_true((SELECT count(*) = v_audit_before + 1 FROM audit_entry), 'rider-completed returns are never audited as staff returns');
    PERFORM pg_temp.expect_error('P0002', format('SELECT * FROM staff_return_rental(%s, -1, %s)', v_staff, v_b), 'staff return of an unknown rental is rejected');
    -- Staff return still obeys destination rules.
    SELECT * INTO v_d FROM start_rental(v_r5, v_reg4);
    PERFORM pg_temp.expect_error('55000', format('SELECT * FROM staff_return_rental(%s, %s, %s)', v_staff, v_d.rental_id, v_closed), 'staff return to a return-disabled station is rejected');
    PERFORM pg_temp.assert_true((SELECT count(*) = v_audit_before + 1 FROM audit_entry), 'rejected staff return writes no audit');

    -- transaction rollbacks (R-001, R-002, F-075)
    -- Start: failure after the rental row was inserted must leave neither the row nor the placement change.
    CREATE TRIGGER zz_inject_move_failure BEFORE UPDATE ON bicycle FOR EACH ROW
        WHEN (NEW.placement = 'active_rental') EXECUTE FUNCTION pg_temp.reject_bicycle_rental_move();
    SELECT count(*) INTO v_count FROM rental;
    PERFORM pg_temp.expect_error('P0001', format('SELECT start_rental(%s, %s)', v_r2, v_reg2), 'injected failure aborts rental start');
    PERFORM pg_temp.assert_true((SELECT count(*) = v_count FROM rental), 'failed start leaves no rental row');
    DROP TRIGGER zz_inject_move_failure ON bicycle;
    PERFORM pg_temp.assert_true((SELECT placement = 'station' FROM bicycle WHERE bicycle_id = v_reg2), 'failed start leaves the bicycle where it was');

    -- Return: failure when moving the bicycle must undo the rental completion.
    SELECT * INTO v_d FROM start_rental(v_r2, v_reg2);
    CREATE TRIGGER zz_inject_return_failure BEFORE UPDATE ON bicycle FOR EACH ROW
        WHEN (NEW.placement = 'station') EXECUTE FUNCTION pg_temp.reject_bicycle_rental_move();
    PERFORM pg_temp.expect_error('P0001', format('SELECT * FROM return_rental(%s, %s, %s)', v_r2, v_d.rental_id, v_b), 'injected failure aborts rider return');
    DROP TRIGGER zz_inject_return_failure ON bicycle;
    PERFORM pg_temp.assert_true((SELECT end_time IS NULL AND return_station_id IS NULL AND final_charge IS NULL FROM rental WHERE rental_id = v_d.rental_id)
        AND (SELECT placement = 'active_rental' AND current_station_id IS NULL FROM bicycle WHERE bicycle_id = v_reg2), 'failed return leaves rental active and bicycle on rental');

    -- Staff return: a failing audit write undoes the whole return.
    CREATE TRIGGER zz_inject_audit_failure BEFORE INSERT ON audit_entry FOR EACH ROW EXECUTE FUNCTION pg_temp.reject_audit();
    SELECT count(*) INTO v_count FROM audit_entry;
    PERFORM pg_temp.expect_error('P0001', format('SELECT * FROM staff_return_rental(%s, %s, %s)', v_staff, v_d.rental_id, v_b), 'injected audit failure aborts staff return');
    DROP TRIGGER zz_inject_audit_failure ON audit_entry;
    PERFORM pg_temp.assert_true((SELECT end_time IS NULL AND returned_by_staff_id IS NULL FROM rental WHERE rental_id = v_d.rental_id)
        AND (SELECT placement = 'active_rental' FROM bicycle WHERE bicycle_id = v_reg2)
        AND (SELECT count(*) = v_count FROM audit_entry), 'failed audit leaves rental, bicycle and audit log unchanged');

    -- Charge overflow rejects the return without partial changes (F-055).
    PERFORM pg_temp.age_rental(v_d.rental_id, 86400 * 30, 9999999999.99, 1);
    PERFORM pg_temp.expect_error('22003', format('SELECT * FROM return_rental(%s, %s, %s)', v_r2, v_d.rental_id, v_b), 'charge overflow rejects the return');
    PERFORM pg_temp.assert_true((SELECT end_time IS NULL FROM rental WHERE rental_id = v_d.rental_id)
        AND (SELECT placement = 'active_rental' FROM bicycle WHERE bicycle_id = v_reg2), 'overflow leaves no partial return');

    -- history paging (F-048)
    PERFORM pg_temp.assert_true((SELECT count(*) >= 2 FROM rental WHERE rider_id = v_r2), 'paging fixture: rider has several rentals');
    PERFORM pg_temp.assert_true((SELECT count(*) FROM get_rental_history(v_r2)) = (SELECT count(*) FROM rental WHERE rider_id = v_r2), 'default page returns all rentals of a small history');
    PERFORM pg_temp.assert_true((SELECT count(*) = 1 FROM get_rental_history(v_r2, 1, 0)), 'limit 1 returns one rental');
    PERFORM pg_temp.assert_true((SELECT rental_id FROM get_rental_history(v_r2, 1, 0))
        = (SELECT rental_id FROM rental WHERE rider_id = v_r2 ORDER BY start_time DESC, rental_id DESC LIMIT 1), 'first page starts with the newest rental');
    PERFORM pg_temp.assert_true((SELECT rental_id FROM get_rental_history(v_r2, 1, 1))
        = (SELECT rental_id FROM rental WHERE rider_id = v_r2 ORDER BY start_time DESC, rental_id DESC LIMIT 1 OFFSET 1), 'offset 1 returns the second newest rental');
    PERFORM pg_temp.assert_true((SELECT count(*) = 0 FROM get_rental_history(v_r2, 10, 1000)), 'offset past the end returns no rows');
    PERFORM pg_temp.expect_error('22023', format('SELECT * FROM get_rental_history(%s, 0, 0)', v_r2), 'limit 0 is rejected');
    PERFORM pg_temp.expect_error('22023', format('SELECT * FROM get_rental_history(%s, 201, 0)', v_r2), 'limit above 200 is rejected');
    PERFORM pg_temp.expect_error('22023', format('SELECT * FROM get_rental_history(%s, 10, -1)', v_r2), 'negative offset is rejected');
    PERFORM pg_temp.expect_error('22023', format('SELECT * FROM get_rental_history(%s, NULL, 0)', v_r2), 'NULL limit is rejected');
    SET CONSTRAINTS ALL IMMEDIATE;
END $$;

SELECT count(*) AS rental_lifecycle_assertions_passed FROM rental_test_results;

ROLLBACK;

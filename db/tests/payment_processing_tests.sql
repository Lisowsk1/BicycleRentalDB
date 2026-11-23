-- V015: Payment processing tests. Runs in one transaction that ends with ROLLBACK.
-- Usage: psql -v ON_ERROR_STOP=1 -f V015_payment_processing_tests.sql

BEGIN;
SET LOCAL search_path = bicycle_rental, public;

CREATE FUNCTION pg_temp.expect_error(p_sql text, p_sqlstate text)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    BEGIN
        EXECUTE p_sql;
    EXCEPTION WHEN OTHERS THEN
        IF SQLSTATE = p_sqlstate THEN
            RETURN;
        END IF;
        RAISE EXCEPTION 'expected SQLSTATE %, got % (%) for: %', p_sqlstate, SQLSTATE, SQLERRM, p_sql;
    END;
    RAISE EXCEPTION 'statement succeeded but SQLSTATE % was expected: %', p_sqlstate, p_sql;
END $$;

CREATE FUNCTION pg_temp.new_rental(
    p_rider bigint, p_bike bigint, p_station bigint, p_tariff bigint, p_charge numeric)
RETURNS bigint
LANGUAGE plpgsql
AS $$
DECLARE
    v_id bigint;
BEGIN
    INSERT INTO bicycle_rental.rental (
        rider_id, bicycle_id, pickup_station_id, return_station_id, tariff_id,
        start_time, end_time, captured_price_per_block, captured_block_length_seconds,
        captured_currency, final_charge, bicycle_type)
    SELECT p_rider, p_bike, p_station, p_station, t.tariff_id,
           clock_timestamp() - interval '1 hour', clock_timestamp(),
           t.price_per_block, t.block_length_seconds, t.currency, p_charge, t.bicycle_type
      FROM bicycle_rental.tariff t
     WHERE t.tariff_id = p_tariff
    RETURNING rental_id INTO v_id;
    RETURN v_id;
END $$;

CREATE FUNCTION pg_temp.events(p_ref uuid)
RETURNS text
LANGUAGE sql
AS $$
    SELECT string_agg(e.event_type::text, ',' ORDER BY e.event_id)
      FROM bicycle_rental.payment_event e
      JOIN bicycle_rental.payment p ON p.payment_id = e.payment_id
     WHERE p.payment_reference = p_ref
$$;

DO $test$
DECLARE
    v_rider_a bigint;
    v_rider_b bigint;
    v_staff   bigint;
    v_bike    bigint;
    v_station bigint;
    v_tariff  bigint;
    v_jan     bigint;
    v_jan_active bigint;
    v_r_ok bigint;
    v_r_lost bigint;
    v_r_unavail bigint;
    v_r_fail bigint;
    v_r_zero bigint;
    v_r_none bigint;
    v_r_manual bigint;
    v_r_cwf bigint;
    v_r_rb1 bigint;
    v_r_rb2 bigint;
    v_ok_ref uuid;
    v_lost_ref uuid;
    v_ref uuid;
    v_rand uuid := gen_random_uuid();
    v_row record;
    v_n integer;
    v_events_before integer;
BEGIN
    v_rider_a := bicycle_rental.register_rider('Pay', 'Alpha', 'pay.alpha@example.test', 'AlphaPass123!');
    v_rider_b := bicycle_rental.register_rider('Pay', 'Beta',  'pay.beta@example.test',  'BetaPass123!');
    v_staff   := bicycle_rental.provision_staff('Pay', 'Staff', 'pay.staff@example.test', 'StaffPass123!');

    SELECT b.bicycle_id INTO v_bike    FROM bicycle b WHERE b.identifier = 'BIKE-REG-001';
    SELECT s.station_id INTO v_station FROM station s WHERE s.name = 'Market Square';
    SELECT t.tariff_id  INTO v_tariff  FROM tariff t WHERE t.bicycle_type = 'regular' AND t.is_active;
    SELECT r.rider_id   INTO v_jan     FROM rental r WHERE r.end_time IS NOT NULL AND r.final_charge > 0 ORDER BY r.rental_id LIMIT 1;
    SELECT r.rental_id  INTO v_jan_active FROM rental r WHERE r.end_time IS NULL;

    v_r_ok      := pg_temp.new_rental(v_rider_a, v_bike, v_station, v_tariff, 5.00);
    v_r_lost    := pg_temp.new_rental(v_rider_a, v_bike, v_station, v_tariff, 2.50);
    v_r_unavail := pg_temp.new_rental(v_rider_a, v_bike, v_station, v_tariff, 2.50);
    v_r_fail    := pg_temp.new_rental(v_rider_a, v_bike, v_station, v_tariff, 2.50);
    v_r_zero    := pg_temp.new_rental(v_rider_a, v_bike, v_station, v_tariff, 0);
    v_r_none    := pg_temp.new_rental(v_rider_a, v_bike, v_station, v_tariff, 2.50);
    v_r_manual  := pg_temp.new_rental(v_rider_a, v_bike, v_station, v_tariff, 2.50);
    v_r_cwf     := pg_temp.new_rental(v_rider_a, v_bike, v_station, v_tariff, 2.50);
    v_r_rb1     := pg_temp.new_rental(v_rider_a, v_bike, v_station, v_tariff, 2.50);
    v_r_rb2     := pg_temp.new_rental(v_rider_a, v_bike, v_station, v_tariff, 2.50);

    PERFORM set_config('bicycle_rental.privileged_setup', 'true', true);
    INSERT INTO payment_simulator_scenario (rental_id, scenario) VALUES
        (v_r_lost, 'success_lost_response'),
        (v_r_unavail, 'unavailable'),
        (v_r_fail, 'failure');
    PERFORM set_config('bicycle_rental.privileged_setup', 'false', true);

    -- T1: request creates one pending payment with the rental's amount and currency
    SELECT * INTO v_row FROM request_payment(v_rider_a, v_r_ok);
    ASSERT v_row.status = 'pending' AND v_row.amount = 5.00 AND v_row.currency = 'PLN', 'T1 request result';
    v_ok_ref := v_row.payment_reference;

    -- T2: repeated request reuses the payment
    SELECT * INTO v_row FROM request_payment(v_rider_a, v_r_ok);
    ASSERT v_row.payment_reference = v_ok_ref, 'T2 reference reused';
    SELECT count(*) INTO v_n FROM payment p WHERE p.rental_id = v_r_ok;
    ASSERT v_n = 1, 'T2 one payment per rental';
    ASSERT pg_temp.events(v_ok_ref) = 'requested', 'T2 repeated request adds no event';

    -- T3: success; resubmission returns the stored outcome without a new attempt
    SELECT * INTO v_row FROM submit_payment(v_rider_a, v_ok_ref);
    ASSERT v_row.status = 'successful' AND NOT v_row.uncertain, 'T3 settles successfully';
    SELECT * INTO v_row FROM submit_payment(v_rider_a, v_ok_ref);
    ASSERT v_row.status = 'successful', 'T3 resubmission returns stored outcome';
    SELECT count(*) INTO v_n FROM payment_simulator_record s WHERE s.payment_reference = v_ok_ref;
    ASSERT v_n = 1, 'T3 one simulator record';
    ASSERT pg_temp.events(v_ok_ref) = 'requested,submission_attempted,confirmed_successful', 'T3 events';

    -- T4: lost response, retry recovers without a second settlement
    SELECT * INTO v_row FROM request_payment(v_rider_a, v_r_lost);
    v_lost_ref := v_row.payment_reference;
    SELECT * INTO v_row FROM submit_payment(v_rider_a, v_lost_ref);
    ASSERT v_row.status = 'pending' AND v_row.uncertain, 'T4 lost response reported as uncertain';
    SELECT * INTO v_row FROM submit_payment(v_rider_a, v_lost_ref);
    ASSERT v_row.status = 'successful' AND NOT v_row.uncertain, 'T4 retry recovers success';
    SELECT count(*) INTO v_n FROM payment_simulator_record s WHERE s.payment_reference = v_lost_ref;
    ASSERT v_n = 1, 'T4 one settlement';
    SELECT * INTO v_row FROM submit_payment(v_rider_a, v_lost_ref);
    ASSERT pg_temp.events(v_lost_ref) =
        'requested,submission_attempted,submission_unconfirmed,submission_attempted,confirmed_successful',
        'T4 events';

    -- T5: unavailable simulator, adapter validation, later recovery
    SELECT * INTO v_row FROM request_payment(v_rider_a, v_r_unavail);
    v_ref := v_row.payment_reference;
    SELECT * INTO v_row FROM submit_payment(v_rider_a, v_ref);
    ASSERT v_row.status = 'pending' AND v_row.uncertain, 'T5 stays pending';
    SELECT count(*) INTO v_n FROM payment_simulator_record s WHERE s.payment_reference = v_ref;
    ASSERT v_n = 0, 'T5 nothing processed';

    PERFORM pg_temp.expect_error(format(
        'SELECT apply_payment_confirmation(%L, %s, 4.00, %L, %L)', v_ref, v_r_unavail, 'PLN', 'successful'), '22023');
    PERFORM pg_temp.expect_error(format(
        'SELECT apply_payment_confirmation(%L, %s, 2.50, %L, %L)', v_ref, v_r_unavail, 'EUR', 'successful'), '22023');
    PERFORM pg_temp.expect_error(format(
        'SELECT apply_payment_confirmation(%L, %s, 2.50, %L, %L)', v_ref, v_r_ok, 'PLN', 'successful'), '22023');
    PERFORM pg_temp.expect_error(format(
        'SELECT apply_payment_confirmation(%L, %s, 2.50, %L, %L)', v_ref, v_r_unavail, 'PLN', 'pending'), '22023');
    PERFORM pg_temp.expect_error(format(
        'SELECT apply_payment_confirmation(%L, %s, 2.50, %L, %L)', gen_random_uuid(), v_r_unavail, 'PLN', 'successful'), '22023');

    PERFORM set_config('bicycle_rental.privileged_setup', 'true', true);
    UPDATE payment_simulator_scenario SET scenario = 'success' WHERE rental_id = v_r_unavail;
    PERFORM set_config('bicycle_rental.privileged_setup', 'false', true);

    SELECT * INTO v_row FROM submit_payment(v_rider_a, v_ref);
    ASSERT v_row.status = 'successful', 'T5 recovery';

    PERFORM apply_payment_confirmation(v_ref, v_r_unavail, 2.50, 'PLN', 'successful');
    ASSERT pg_temp.events(v_ref) =
        'requested,submission_attempted,submission_unconfirmed,submission_attempted,confirmed_successful',
        'T5 identical confirmation adds no event';
    PERFORM pg_temp.expect_error(format(
        'SELECT apply_payment_confirmation(%L, %s, 2.50, %L, %L)', v_ref, v_r_unavail, 'PLN', 'failed'), '23514');

    -- T6: failed is terminal
    SELECT * INTO v_row FROM request_payment(v_rider_a, v_r_fail);
    v_ref := v_row.payment_reference;
    SELECT * INTO v_row FROM submit_payment(v_rider_a, v_ref);
    ASSERT v_row.status = 'failed', 'T6 failed';
    SELECT * INTO v_row FROM submit_payment(v_rider_a, v_ref);
    ASSERT v_row.status = 'failed', 'T6 stays failed';
    PERFORM pg_temp.expect_error(format(
        'SELECT apply_payment_confirmation(%L, %s, 2.50, %L, %L)', v_ref, v_r_fail, 'PLN', 'successful'), '23514');

    -- T7: direct writes rejected
    PERFORM pg_temp.expect_error(format('UPDATE payment SET status = %L WHERE payment_reference = %L', 'failed', v_ok_ref), '23514');
    PERFORM pg_temp.expect_error(format('UPDATE payment SET status = %L WHERE payment_reference = %L', 'pending', v_ok_ref), '23514');
    PERFORM pg_temp.expect_error(format('UPDATE payment SET amount = 1.00 WHERE payment_reference = %L', v_ok_ref), '23514');
    PERFORM pg_temp.expect_error(format('UPDATE payment SET payment_reference = gen_random_uuid() WHERE payment_reference = %L', v_ok_ref), '23514');
    PERFORM pg_temp.expect_error(format('DELETE FROM payment WHERE payment_reference = %L', v_ok_ref), '23000');
    PERFORM pg_temp.expect_error(format(
        'INSERT INTO payment (rental_id, rider_id, amount, currency, status) VALUES (%s, %s, 2.50, %L, %L)',
        v_r_none, v_rider_a, 'PLN', 'successful'), '23514');
    PERFORM pg_temp.expect_error(format(
        'INSERT INTO payment (rental_id, rider_id, amount, currency) VALUES (%s, %s, 9.99, %L)',
        v_r_none, v_rider_a, 'PLN'), '23503');
    PERFORM pg_temp.expect_error(format(
        'INSERT INTO payment (rental_id, rider_id, amount, currency) VALUES (%s, %s, 2.50, %L)',
        v_r_none, v_rider_b, 'PLN'), '23503');
    PERFORM pg_temp.expect_error(format(
        'INSERT INTO payment (rental_id, rider_id, amount, currency) VALUES (%s, %s, 2.50, %L)',
        v_r_none, v_rider_a, 'EUR'), '23503');
    PERFORM pg_temp.expect_error(format(
        'INSERT INTO payment (rental_id, rider_id, amount, currency) VALUES (%s, %s, 0, %L)',
        v_r_zero, v_rider_a, 'PLN'), '23514');

    -- T8: simulator payload reuse
    PERFORM pg_temp.expect_error(format('SELECT simulator_submit(%L, %s, 4.00, %L)', v_ok_ref, v_r_ok, 'PLN'), '22023');

    -- T9: ownership, role, eligibility
    PERFORM pg_temp.expect_error(format('SELECT 1 FROM request_payment(%s, %s)', v_rider_b, v_r_ok), '42501');
    PERFORM pg_temp.expect_error(format('SELECT 1 FROM request_payment(%s, %s)', v_staff, v_r_ok), '42501');
    PERFORM pg_temp.expect_error(format('SELECT 1 FROM request_payment(%s, %s)', v_rider_a, 999999999), '42501');
    PERFORM pg_temp.expect_error(format('SELECT 1 FROM request_payment(%s, %s)', v_jan, v_jan_active), '23514');
    PERFORM pg_temp.expect_error(format('SELECT 1 FROM request_payment(%s, %s)', v_rider_a, v_r_zero), '23514');
    PERFORM pg_temp.expect_error(format('SELECT 1 FROM submit_payment(%s, %L)', v_rider_b, v_ok_ref), '42501');
    PERFORM pg_temp.expect_error(format('SELECT 1 FROM submit_payment(%s, %L)', v_staff, v_ok_ref), '42501');
    SELECT count(*) INTO v_n FROM payment p WHERE p.rental_id IN (v_r_zero, v_jan_active, v_r_none);
    ASSERT v_n = 0, 'T9 rejected requests create no payment data';

    -- T10: status retrieval
    SELECT * INTO v_row FROM get_rental_payment(v_rider_a, v_r_ok);
    ASSERT v_row.charge = 5.00 AND v_row.payment_status = 'successful'
       AND v_row.display_state = 'successful' AND v_row.simulated, 'T10 rider view';
    SELECT * INTO v_row FROM get_rental_payment(v_staff, v_r_fail);
    ASSERT v_row.display_state = 'failed', 'T10 staff view';
    SELECT * INTO v_row FROM get_rental_payment(v_rider_a, v_r_zero);
    ASSERT v_row.display_state = 'not_required' AND v_row.charge = 0 AND v_row.payment_status IS NULL, 'T10 zero charge';
    SELECT * INTO v_row FROM get_rental_payment(v_rider_a, v_r_none);
    ASSERT v_row.display_state = 'not_requested' AND v_row.payment_status IS NULL, 'T10 not requested';
    SELECT * INTO v_row FROM get_rental_payment(v_jan, v_jan_active);
    ASSERT v_row.display_state = 'not_applicable', 'T10 active rental';
    PERFORM pg_temp.expect_error(format('SELECT 1 FROM get_rental_payment(%s, %s)', v_rider_b, v_r_ok), '42501');
    PERFORM pg_temp.expect_error(format('SELECT 1 FROM list_rider_payments(%s, %s)', v_rider_a, v_rider_a), '42501');
    SELECT count(*) INTO v_n FROM list_rider_payments(v_staff, v_rider_a);
    ASSERT v_n = 4, 'T10 staff lists rider payments';

    -- T11: privileged-only tables, retained simulator results
    PERFORM pg_temp.expect_error(format(
        'INSERT INTO payment_simulator_scenario (rental_id, scenario) VALUES (%s, %L)', v_r_none, 'failure'), '42501');
    PERFORM pg_temp.expect_error(format('DELETE FROM payment_simulator_record WHERE payment_reference = %L', v_ok_ref), '23000');
    PERFORM pg_temp.expect_error(format(
        'UPDATE payment_simulator_record SET outcome = %L WHERE payment_reference = %L', 'failed', v_ok_ref), '23514');

    -- T12: manual status override rejected
    SELECT * INTO v_row FROM request_payment(v_rider_a, v_r_manual);
    v_ref := v_row.payment_reference;
    PERFORM pg_temp.expect_error(format('UPDATE payment SET status = %L WHERE payment_reference = %L', 'successful', v_ref), '23514');
    PERFORM pg_temp.expect_error(format('UPDATE payment SET status = %L WHERE payment_reference = %L', 'failed', v_ref), '23514');
    SELECT * INTO v_row FROM get_rental_payment(v_rider_a, v_r_manual);
    ASSERT v_row.payment_status = 'pending', 'T12 still pending';

    -- T13: confirmation-write failure: simulator settled, payment still pending, retry recovers
    SELECT * INTO v_row FROM request_payment(v_rider_a, v_r_cwf);
    v_ref := v_row.payment_reference;
    ASSERT simulator_submit(v_ref, v_r_cwf, 2.50, 'PLN') = 'successful', 'T13 simulator settles';
    SELECT * INTO v_row FROM get_rental_payment(v_rider_a, v_r_cwf);
    ASSERT v_row.payment_status = 'pending', 'T13 payment still pending';
    SELECT * INTO v_row FROM submit_payment(v_rider_a, v_ref);
    ASSERT v_row.status = 'successful', 'T13 retry recovers';
    SELECT count(*) INTO v_n FROM payment_simulator_record s WHERE s.payment_reference = v_ref;
    ASSERT v_n = 1, 'T13 no second settlement';

    -- T14: rollback of a failed request leaves no payment, no event
    SELECT count(*) INTO v_events_before FROM payment_event;
    BEGIN
        PERFORM request_payment(v_rider_a, v_r_rb1);
        RAISE EXCEPTION 'forced failure';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'forced failure' THEN
            RAISE;
        END IF;
    END;
    SELECT count(*) INTO v_n FROM payment p WHERE p.rental_id = v_r_rb1;
    ASSERT v_n = 0, 'T14 payment rolled back';
    SELECT count(*) INTO v_n FROM payment_event;
    ASSERT v_n = v_events_before, 'T14 events rolled back';

    -- T15: rollback of a failed submission leaves payment pending, no simulator record, no event
    SELECT * INTO v_row FROM request_payment(v_rider_a, v_r_rb2);
    v_ref := v_row.payment_reference;
    SELECT count(*) INTO v_events_before FROM payment_event;
    BEGIN
        PERFORM submit_payment(v_rider_a, v_ref);
        RAISE EXCEPTION 'forced failure';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'forced failure' THEN
            RAISE;
        END IF;
    END;
    SELECT * INTO v_row FROM get_rental_payment(v_rider_a, v_r_rb2);
    ASSERT v_row.payment_status = 'pending', 'T15 payment still pending';
    SELECT count(*) INTO v_n FROM payment_simulator_record s WHERE s.payment_reference = v_ref;
    ASSERT v_n = 0, 'T15 simulator record rolled back';
    SELECT count(*) INTO v_n FROM payment_event;
    ASSERT v_n = v_events_before, 'T15 events rolled back';

    BEGIN
        PERFORM simulator_submit(v_rand, v_r_none, 2.50, 'PLN');
        RAISE EXCEPTION 'forced failure';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'forced failure' THEN
            RAISE;
        END IF;
    END;
    SELECT count(*) INTO v_n FROM payment_simulator_record s WHERE s.payment_reference = v_rand;
    ASSERT v_n = 0, 'T15 direct simulator write rolled back';

    -- T16: payment event log is append-only
    PERFORM pg_temp.expect_error('UPDATE payment_event SET new_status = ''failed''', '23000');
    PERFORM pg_temp.expect_error('DELETE FROM payment_event', '23000');

    -- T17: every terminal payment has a retained simulator result (includes the seeded payment)
    SELECT count(*) INTO v_n
      FROM payment p
     WHERE p.status <> 'pending'
       AND NOT EXISTS (SELECT 1 FROM payment_simulator_record s WHERE s.payment_reference = p.payment_reference);
    ASSERT v_n = 0, 'T17 terminal payments have simulator results';

    RAISE NOTICE 'V015: all payment tests passed';
END $test$;

ROLLBACK;

-- Retention purge tests (V024 purge_expired_records): rows past the 36-month cutoff are removed by the
-- privileged purge, younger rows and rows still in use are kept, and only bicycle_setup members may run it.
-- Run after all migrations with psql --set=ON_ERROR_STOP=1 as a superuser (it creates temporary login roles
-- and switches session authorization). Everything, including the roles, is rolled back.
BEGIN;
SET LOCAL search_path = bicycle_rental, public, pg_temp;

CREATE TEMP TABLE retention_test_results (description text NOT NULL);
GRANT ALL ON retention_test_results TO PUBLIC;

CREATE FUNCTION pg_temp.assert_true(p_condition boolean, p_description text)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    IF p_condition IS DISTINCT FROM true THEN
        RAISE EXCEPTION 'FAIL: %', p_description;
    END IF;
    INSERT INTO retention_test_results VALUES (p_description);
END $$;

-- Run p_sql and check its SQLSTATE; the rejected command is rolled back.
CREATE FUNCTION pg_temp.expect_error(p_state text, p_sql text, p_description text)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    BEGIN
        EXECUTE p_sql;
    EXCEPTION WHEN OTHERS THEN
        IF SQLSTATE <> p_state THEN
            RAISE EXCEPTION 'FAIL: %; expected SQLSTATE %, got %: %', p_description, p_state, SQLSTATE, SQLERRM;
        END IF;
        INSERT INTO retention_test_results VALUES (p_description);
        RETURN;
    END;
    RAISE EXCEPTION 'FAIL: %; expected SQLSTATE %, but command succeeded', p_description, p_state;
END $$;

DO $$
DECLARE
    v_prefix text := 'ret-' || gen_random_uuid();
    v_orig text := session_user;
    v_old timestamptz := now() - interval '37 months';
    v_recent timestamptz := now() - interval '35 months';
    v_staff bigint; v_rider bigint; v_a bigint; v_b bigint; v_bike bigint; v_tariff bigint;
    v_old_audit bigint; v_recent_audit bigint;
    v_old_transfer bigint; v_recent_transfer bigint;
    v_rental_old_paid bigint; v_rental_old_pending bigint; v_rental_recent bigint;
    v_pay_old_paid bigint; v_pay_old_pending bigint;
    v_fault_old bigint; v_fault_recent bigint; v_fault_open_old bigint;
    v_deleted jsonb;
BEGIN
    -- two temporary logins: one in bicycle_setup, one in bicycle_app only
    EXECUTE 'CREATE ROLE ret_setup_login LOGIN IN ROLE bicycle_setup';
    EXECUTE 'CREATE ROLE ret_app_login LOGIN IN ROLE bicycle_app';

    ---------------------------------------------------------------- fixtures (superuser, privileged setup)
    PERFORM set_config('bicycle_rental.privileged_setup', 'true', true);
    PERFORM set_config('bicycle_rental.privileged_reset', 'true', true);

    v_staff := provision_staff('Ret', 'Staff', v_prefix || '-s@test.invalid', 'pw');
    v_rider := register_rider('Ret', 'Rider', v_prefix || '-r@test.invalid', 'pw');
    v_a := create_station(v_staff, v_prefix || ' A', 'Street', 52, 21, true, true);
    v_b := create_station(v_staff, v_prefix || ' B', 'Street', 52, 21, true, true);
    v_bike := create_bicycle(v_staff, v_prefix || '-1', 'regular', 'serviceable', v_a);
    SELECT tariff_id INTO v_tariff FROM tariff WHERE bicycle_type = 'regular' AND is_active LIMIT 1;

    -- audit: one entry older than the cutoff, one younger. Audit rows cannot be updated (a privileged
    -- UPDATE is ignored), so they are inserted directly with their timestamps.
    INSERT INTO audit_entry (staff_id, action_type, primary_record_type, primary_record_id, created_at)
        VALUES (v_staff, 'rider_block', 'Rider', v_rider, v_old) RETURNING audit_id INTO v_old_audit;
    INSERT INTO audit_detail (audit_id, detail_no, subject_record_type, subject_record_id, field_name, previous_value, new_value)
        VALUES (v_old_audit, 1, 'Rider', v_rider, 'status', '"active"', '"blocked"');
    INSERT INTO audit_entry (staff_id, action_type, primary_record_type, primary_record_id, created_at)
        VALUES (v_staff, 'rider_unblock', 'Rider', v_rider, v_recent) RETURNING audit_id INTO v_recent_audit;
    INSERT INTO audit_detail (audit_id, detail_no, subject_record_type, subject_record_id, field_name, previous_value, new_value)
        VALUES (v_recent_audit, 1, 'Rider', v_rider, 'status', '"blocked"', '"active"');

    -- transfers (records cannot be updated, so they are inserted with their timestamps)
    INSERT INTO bicycle_transfer (bicycle_id, from_station_id, to_station_id, performed_by_staff_id, transferred_at, reason)
        VALUES (v_bike, v_a, v_b, v_staff, v_old, 'old') RETURNING transfer_id INTO v_old_transfer;
    INSERT INTO bicycle_transfer (bicycle_id, from_station_id, to_station_id, performed_by_staff_id, transferred_at, reason)
        VALUES (v_bike, v_a, v_b, v_staff, v_recent, 'recent') RETURNING transfer_id INTO v_recent_transfer;

    -- rentals and payments
    INSERT INTO rental (rider_id, bicycle_id, pickup_station_id, return_station_id, tariff_id, start_time, end_time,
                        captured_price_per_block, captured_block_length_seconds, captured_currency, final_charge, bicycle_type)
        VALUES (v_rider, v_bike, v_a, v_a, v_tariff, v_old - interval '1 hour', v_old, 2.50, 900, 'PLN', 10.00, 'regular')
        RETURNING rental_id INTO v_rental_old_paid;
    INSERT INTO rental (rider_id, bicycle_id, pickup_station_id, return_station_id, tariff_id, start_time, end_time,
                        captured_price_per_block, captured_block_length_seconds, captured_currency, final_charge, bicycle_type)
        VALUES (v_rider, v_bike, v_a, v_a, v_tariff, v_old - interval '2 hour', v_old - interval '1 hour', 2.50, 900, 'PLN', 10.00, 'regular')
        RETURNING rental_id INTO v_rental_old_pending;
    INSERT INTO rental (rider_id, bicycle_id, pickup_station_id, return_station_id, tariff_id, start_time, end_time,
                        captured_price_per_block, captured_block_length_seconds, captured_currency, final_charge, bicycle_type)
        VALUES (v_rider, v_bike, v_a, v_a, v_tariff, now() - interval '20 months' - interval '1 hour', now() - interval '20 months', 2.50, 900, 'PLN', 10.00, 'regular')
        RETURNING rental_id INTO v_rental_recent;

    INSERT INTO payment (rental_id, rider_id, amount, currency, status, created_at, updated_at)
        VALUES (v_rental_old_paid, v_rider, 10.00, 'PLN', 'successful', v_old, v_old) RETURNING payment_id INTO v_pay_old_paid;
    INSERT INTO payment (rental_id, rider_id, amount, currency, status, created_at, updated_at)
        VALUES (v_rental_old_pending, v_rider, 10.00, 'PLN', 'pending', v_old, v_old) RETURNING payment_id INTO v_pay_old_pending;

    -- fault reports: resolved before the cutoff, resolved after it, and an old one still open
    INSERT INTO fault_report (bicycle_id, reported_by_account_id, category, severity, description, status, reported_at, resolved_at)
        VALUES (v_bike, v_rider, 'brakes', 'minor', 'old resolved', 'resolved', v_old - interval '10 days', v_old) RETURNING report_id INTO v_fault_old;
    INSERT INTO fault_report (bicycle_id, reported_by_account_id, category, severity, description, status, reported_at, resolved_at)
        VALUES (v_bike, v_rider, 'brakes', 'minor', 'recent resolved', 'resolved', v_recent - interval '10 days', v_recent) RETURNING report_id INTO v_fault_recent;
    INSERT INTO fault_report (bicycle_id, reported_by_account_id, category, severity, description, status, reported_at)
        VALUES (v_bike, v_rider, 'brakes', 'minor', 'old but open', 'open', v_old) RETURNING report_id INTO v_fault_open_old;

    PERFORM set_config('bicycle_rental.privileged_setup', 'false', true);
    PERFORM set_config('bicycle_rental.privileged_reset', 'false', true);

    ---------------------------------------------------------------- who may purge
    EXECUTE 'SET SESSION AUTHORIZATION ret_app_login';
    BEGIN
        PERFORM purge_expired_records(now());
        EXECUTE format('SET SESSION AUTHORIZATION %I', v_orig);
        RAISE EXCEPTION 'FAIL: bicycle_app login was allowed to purge';
    EXCEPTION WHEN insufficient_privilege THEN
        EXECUTE format('SET SESSION AUTHORIZATION %I', v_orig);
        INSERT INTO retention_test_results VALUES ('a bicycle_app login cannot run the purge');
    END;

    EXECUTE 'SET SESSION AUTHORIZATION ret_setup_login';
    BEGIN
        PERFORM purge_expired_records(NULL);
        EXECUTE format('SET SESSION AUTHORIZATION %I', v_orig);
        RAISE EXCEPTION 'FAIL: NULL purge date was accepted';
    EXCEPTION WHEN invalid_parameter_value THEN
        EXECUTE format('SET SESSION AUTHORIZATION %I', v_orig);
        INSERT INTO retention_test_results VALUES ('a NULL purge date is rejected');
    END;

    ---------------------------------------------------------------- nothing is purged by a date in the past
    EXECUTE 'SET SESSION AUTHORIZATION ret_setup_login';
    PERFORM * FROM purge_expired_records(now() - interval '10 years');
    EXECUTE format('SET SESSION AUTHORIZATION %I', v_orig);
    PERFORM pg_temp.assert_true(EXISTS (SELECT 1 FROM audit_entry WHERE audit_id = v_old_audit)
        AND EXISTS (SELECT 1 FROM bicycle_transfer WHERE transfer_id = v_old_transfer)
        AND EXISTS (SELECT 1 FROM rental WHERE rental_id = v_rental_old_paid),
        'a purge dated ten years ago removes none of the test rows');

    ---------------------------------------------------------------- the purge itself
    EXECUTE 'SET SESSION AUTHORIZATION ret_setup_login';
    SELECT jsonb_object_agg(entity_name, deleted_rows) INTO v_deleted FROM purge_expired_records(now());
    EXECUTE format('SET SESSION AUTHORIZATION %I', v_orig);

    PERFORM pg_temp.assert_true(NOT EXISTS (SELECT 1 FROM audit_entry WHERE audit_id = v_old_audit)
        AND NOT EXISTS (SELECT 1 FROM audit_detail WHERE audit_id = v_old_audit),
        'an audit entry older than 36 months is removed together with its details');
    PERFORM pg_temp.assert_true(EXISTS (SELECT 1 FROM audit_entry WHERE audit_id = v_recent_audit)
        AND EXISTS (SELECT 1 FROM audit_detail WHERE audit_id = v_recent_audit),
        'an audit entry younger than 36 months is kept with its details');
    PERFORM pg_temp.assert_true(NOT EXISTS (SELECT 1 FROM bicycle_transfer WHERE transfer_id = v_old_transfer)
        AND EXISTS (SELECT 1 FROM bicycle_transfer WHERE transfer_id = v_recent_transfer),
        'a transfer older than 36 months is removed, a younger one is kept');
    PERFORM pg_temp.assert_true(NOT EXISTS (SELECT 1 FROM payment WHERE payment_id = v_pay_old_paid)
        AND NOT EXISTS (SELECT 1 FROM rental WHERE rental_id = v_rental_old_paid),
        'an old completed rental and its old terminal payment are removed');
    PERFORM pg_temp.assert_true(EXISTS (SELECT 1 FROM payment WHERE payment_id = v_pay_old_pending)
        AND EXISTS (SELECT 1 FROM rental WHERE rental_id = v_rental_old_pending),
        'an old pending payment and its rental are kept');
    PERFORM pg_temp.assert_true(EXISTS (SELECT 1 FROM rental WHERE rental_id = v_rental_recent),
        'a rental completed 20 months ago is kept');
    PERFORM pg_temp.assert_true(NOT EXISTS (SELECT 1 FROM fault_report WHERE report_id = v_fault_old)
        AND EXISTS (SELECT 1 FROM fault_report WHERE report_id = v_fault_recent)
        AND EXISTS (SELECT 1 FROM fault_report WHERE report_id = v_fault_open_old),
        'only a fault report resolved more than 36 months ago is removed; recent and open ones stay');
    PERFORM pg_temp.assert_true((v_deleted ->> 'audit_entry')::bigint >= 1 AND (v_deleted ->> 'bicycle_transfer')::bigint >= 1
        AND (v_deleted ->> 'rental')::bigint >= 1 AND (v_deleted ->> 'payment')::bigint >= 1 AND (v_deleted ->> 'fault_report')::bigint >= 1,
        'the purge reports the rows it deleted for each record type');
    PERFORM pg_temp.assert_true(EXISTS (SELECT 1 FROM account WHERE account_id IN (v_staff, v_rider)) AND EXISTS (SELECT 1 FROM bicycle WHERE bicycle_id = v_bike),
        'accounts and fleet are never purged');

    ---------------------------------------------------------------- repeat and afterwards
    EXECUTE 'SET SESSION AUTHORIZATION ret_setup_login';
    SELECT jsonb_object_agg(entity_name, deleted_rows) INTO v_deleted FROM purge_expired_records(now());
    EXECUTE format('SET SESSION AUTHORIZATION %I', v_orig);
    PERFORM pg_temp.assert_true(EXISTS (SELECT 1 FROM audit_entry WHERE audit_id = v_recent_audit)
        AND EXISTS (SELECT 1 FROM bicycle_transfer WHERE transfer_id = v_recent_transfer),
        'a second purge removes nothing more of the kept rows');
    PERFORM pg_temp.assert_true(current_setting('bicycle_rental.privileged_setup') = 'false'
        AND current_setting('bicycle_rental.privileged_reset') = 'false',
        'the purge switches its privileged flags off again');
    PERFORM pg_temp.expect_error('23000', format('DELETE FROM bicycle_rental.bicycle_transfer WHERE transfer_id = %s', v_recent_transfer),
        'operational deletes of transfers are still rejected after a purge');
    PERFORM pg_temp.expect_error('P0001', format('DELETE FROM bicycle_rental.audit_entry WHERE audit_id = %s', v_recent_audit),
        'operational deletes of audit entries are still rejected after a purge');
END $$;

SELECT count(*) AS retention_assertions_passed FROM retention_test_results;

ROLLBACK;

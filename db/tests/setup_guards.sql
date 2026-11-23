-- Run in a fresh psql connection after migrations, with ON_ERROR_STOP=1.
-- Test the genuinely absent setting before setting any custom GUC; RESET alone
-- cannot reproduce absence after a setting has existed in this connection.
-- All fixtures and setup-only operations are rolled back.
BEGIN;
SET LOCAL search_path = bicycle_rental, public, pg_temp;

CREATE TEMP TABLE setup_guard_results (description text NOT NULL);

CREATE FUNCTION pg_temp.assert_guard(p_condition boolean, p_description text)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    IF p_condition IS DISTINCT FROM true THEN
        RAISE EXCEPTION 'FAIL: %', p_description;
    END IF;
    INSERT INTO setup_guard_results VALUES (p_description);
END $$;

CREATE FUNCTION pg_temp.expect_guard_error(p_state text, p_sql text, p_description text)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    BEGIN
        EXECUTE p_sql;
    EXCEPTION WHEN OTHERS THEN
        IF SQLSTATE <> p_state THEN
            RAISE EXCEPTION 'FAIL: %; expected %, got %: %',
                p_description, p_state, SQLSTATE, SQLERRM;
        END IF;
        INSERT INTO setup_guard_results VALUES (p_description);
        RETURN;
    END;
    RAISE EXCEPTION 'FAIL: %; command unexpectedly succeeded', p_description;
END $$;

-- Use completed rows so a missing insert guard cannot be masked by a later
-- active-rental uniqueness or placement error.
CREATE FUNCTION pg_temp.insert_guard_rental(
    p_rider bigint, p_bike bigint, p_station bigint, p_tariff bigint,
    p_price numeric, p_block integer, p_currency text)
RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE
    v_id bigint;
BEGIN
    INSERT INTO rental (rider_id, bicycle_id, pickup_station_id, return_station_id,
                        tariff_id, bicycle_type, start_time, end_time, final_charge,
                        captured_price_per_block, captured_block_length_seconds, captured_currency)
    VALUES (p_rider, p_bike, p_station, p_station, p_tariff, 'regular',
            '2026-01-01 00:00:00+00', '2026-01-01 00:00:01+00', p_price,
            p_price, p_block, p_currency)
    RETURNING rental_id INTO v_id;
    RETURN v_id;
END $$;

DO $$
DECLARE
    v_prefix text := 'setup-guards-' || gen_random_uuid();
    v_staff bigint;
    v_rider bigint;
    v_blocked bigint;
    v_station bigint;
    v_bike bigint;
    v_active bigint;
    v_completed bigint;
    v_setup_rental bigint;
    v_payment bigint;
    v_setup_payment bigint;
    v_tariff tariff%ROWTYPE;
    v_flag text;
    v_label text;
BEGIN
    PERFORM pg_temp.assert_guard(
        current_setting('bicycle_rental.privileged_setup', true) IS NULL,
        'fresh connection starts with no privileged_setup setting');

    INSERT INTO account (first_name, last_name, email, password_hash, role)
    VALUES ('Guard', 'Staff', v_prefix || '-staff@test.invalid', '$2a$12$' || repeat('x', 53), 'staff')
    RETURNING account_id INTO v_staff;
    INSERT INTO staff (account_id) VALUES (v_staff);
    INSERT INTO account (first_name, last_name, email, password_hash, role)
    VALUES ('Guard', 'Rider', v_prefix || '-rider@test.invalid', '$2a$12$' || repeat('x', 53), 'rider')
    RETURNING account_id INTO v_rider;
    INSERT INTO rider (account_id) VALUES (v_rider);
    INSERT INTO account (first_name, last_name, email, password_hash, role)
    VALUES ('Guard', 'Blocked', v_prefix || '-blocked@test.invalid', '$2a$12$' || repeat('x', 53), 'rider')
    RETURNING account_id INTO v_blocked;
    INSERT INTO rider (account_id, status) VALUES (v_blocked, 'blocked');
    v_station := create_station(v_staff, v_prefix, 'Test street', 52, 21, true, true);
    v_bike := create_bicycle(v_staff, v_prefix, 'regular', 'serviceable', v_station);
    SELECT * INTO STRICT v_tariff FROM tariff WHERE bicycle_type = 'regular' AND is_active;
    v_active := (start_rental(v_rider, v_bike)).rental_id;
    v_completed := pg_temp.insert_guard_rental(v_rider, v_bike, v_station, v_tariff.tariff_id,
        v_tariff.price_per_block, v_tariff.block_length_seconds, v_tariff.currency);
    INSERT INTO payment (rental_id, rider_id, amount, currency)
    VALUES (v_completed, v_rider, v_tariff.price_per_block, v_tariff.currency)
    RETURNING payment_id INTO v_payment;

    FOREACH v_flag IN ARRAY ARRAY[NULL::text, '', 'false', 'off', 'unexpected'] LOOP
        IF v_flag IS NOT NULL THEN
            PERFORM set_config('bicycle_rental.privileged_setup', v_flag, true);
        END IF;
        v_label := coalesce(v_flag, '<unset>');
        PERFORM pg_temp.expect_guard_error('23000',
            format('DELETE FROM rental WHERE rental_id = %s', v_active),
            v_label || ': active rental cannot be deleted');
        PERFORM pg_temp.expect_guard_error('23000',
            format('DELETE FROM payment WHERE payment_id = %s', v_payment),
            v_label || ': payment cannot be deleted');
        PERFORM pg_temp.expect_guard_error('23514',
            format('SELECT pg_temp.insert_guard_rental(%s,%s,%s,%s,%L,%s,%L)',
                v_blocked, v_bike, v_station, v_tariff.tariff_id,
                v_tariff.price_per_block, v_tariff.block_length_seconds, v_tariff.currency),
            v_label || ': blocked rider insert rejected');
        PERFORM pg_temp.expect_guard_error('23514',
            format('SELECT pg_temp.insert_guard_rental(%s,%s,%s,%s,%L,%s,%L)',
                v_rider, v_bike, v_station, v_tariff.tariff_id,
                v_tariff.price_per_block + 1, v_tariff.block_length_seconds, v_tariff.currency),
            v_label || ': incorrect price snapshot rejected');
        PERFORM pg_temp.expect_guard_error('23514',
            format('SELECT pg_temp.insert_guard_rental(%s,%s,%s,%s,%L,%s,%L)',
                v_rider, v_bike, v_station, v_tariff.tariff_id,
                v_tariff.price_per_block, v_tariff.block_length_seconds + 1, v_tariff.currency),
            v_label || ': incorrect block length rejected');
        PERFORM pg_temp.expect_guard_error('23514',
            format('SELECT pg_temp.insert_guard_rental(%s,%s,%s,%s,%L,%s,%L)',
                v_rider, v_bike, v_station, v_tariff.tariff_id,
                v_tariff.price_per_block, v_tariff.block_length_seconds, v_tariff.currency || 'X'),
            v_label || ': incorrect currency rejected');
        PERFORM pg_temp.expect_guard_error('23514',
            format('INSERT INTO payment (rental_id,rider_id,amount,currency,status) VALUES (%s,%s,%L,%L,''successful'')',
                v_completed, v_rider, v_tariff.price_per_block, v_tariff.currency),
            v_label || ': terminal payment insert rejected before uniqueness checks');
        PERFORM pg_temp.assert_guard(
            EXISTS (SELECT 1 FROM rental WHERE rental_id = v_active AND end_time IS NULL)
            AND EXISTS (SELECT 1 FROM bicycle WHERE bicycle_id = v_bike AND placement = 'active_rental'),
            v_label || ': rejected deletion preserves rental and placement');
    END LOOP;

    -- Preserve the existing explicit setup/seed behavior for both accepted values.
    FOREACH v_flag IN ARRAY ARRAY['on', 'true'] LOOP
        PERFORM set_config('bicycle_rental.privileged_setup', v_flag, true);
        v_setup_rental := pg_temp.insert_guard_rental(v_blocked, v_bike, v_station, v_tariff.tariff_id,
            v_tariff.price_per_block + 1, v_tariff.block_length_seconds, v_tariff.currency);
        INSERT INTO payment (rental_id, rider_id, amount, currency, status)
        VALUES (v_setup_rental, v_blocked, v_tariff.price_per_block + 1, v_tariff.currency, 'successful')
        RETURNING payment_id INTO v_setup_payment;
        DELETE FROM payment WHERE payment_id = v_setup_payment;
        DELETE FROM rental WHERE rental_id = v_setup_rental;
        PERFORM pg_temp.assert_guard(
            NOT EXISTS (SELECT 1 FROM rental WHERE rental_id = v_setup_rental)
            AND NOT EXISTS (SELECT 1 FROM payment WHERE payment_id = v_setup_payment),
            v_flag || ': explicit setup inserts and deletes remain supported');
    END LOOP;
    SET CONSTRAINTS ALL IMMEDIATE;
END $$;

SELECT count(*) AS setup_guard_assertions_passed FROM setup_guard_results;
ROLLBACK;

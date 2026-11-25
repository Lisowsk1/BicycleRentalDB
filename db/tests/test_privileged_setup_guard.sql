\set ON_ERROR_STOP on

-- 1. Create temporary test logins
DROP ROLE IF EXISTS test_app_login;
DROP ROLE IF EXISTS test_setup_login;

CREATE ROLE test_app_login LOGIN PASSWORD 'test_app_pw';
GRANT bicycle_app TO test_app_login;

CREATE ROLE test_setup_login LOGIN PASSWORD 'test_setup_pw';
GRANT bicycle_setup TO test_setup_login;

-- 2. Verify unprivileged role (bicycle_app) cannot bypass guards via SET LOCAL
SET ROLE test_app_login;

DO $$
BEGIN
    BEGIN
        PERFORM set_config('bicycle_rental.privileged_setup', 'true', true);
        DELETE FROM bicycle_rental.payment;
        RAISE EXCEPTION 'FAIL: bicycle_app was able to delete from payment!';
    EXCEPTION WHEN insufficient_privilege OR integrity_constraint_violation THEN
        RAISE NOTICE 'PASS: payment delete blocked for bicycle_app (%)', SQLERRM;
    END;

    BEGIN
        PERFORM set_config('bicycle_rental.privileged_setup', 'true', true);
        UPDATE bicycle_rental.tariff SET price_per_block = 0.01;
        RAISE EXCEPTION 'FAIL: bicycle_app was able to update tariff!';
    EXCEPTION WHEN insufficient_privilege THEN
        RAISE NOTICE 'PASS: tariff update blocked for bicycle_app (%)', SQLERRM;
    END;

    BEGIN
        PERFORM set_config('bicycle_rental.privileged_reset', 'true', true);
        DELETE FROM bicycle_rental.audit_entry;
        RAISE EXCEPTION 'FAIL: bicycle_app was able to delete from audit_entry!';
    EXCEPTION WHEN insufficient_privilege OR integrity_constraint_violation THEN
        RAISE NOTICE 'PASS: audit_entry delete blocked for bicycle_app (%)', SQLERRM;
    END;
END $$;

-- 3. Look up test IDs as superuser, then run all application operations as test_app_login
RESET ROLE;

DO $$
DECLARE
    v_rider_id   bigint;
    v_station_id bigint;
    v_bike_id    bigint;
BEGIN
    SELECT account_id INTO v_rider_id FROM bicycle_rental.rider WHERE status = 'active' LIMIT 1;
    SELECT station_id INTO v_station_id FROM bicycle_rental.station WHERE rental_enabled AND return_enabled LIMIT 1;
    SELECT b.bicycle_id INTO v_bike_id
      FROM bicycle_rental.bicycle b
     WHERE b.placement = 'station' AND b.maintenance_state = 'serviceable' AND b.bicycle_type = 'regular'
     LIMIT 1;

    PERFORM set_config('test.rider_id', v_rider_id::text, false);
    PERFORM set_config('test.station_id', v_station_id::text, false);
    PERFORM set_config('test.bike_id', v_bike_id::text, false);
END $$;

SET ROLE test_app_login;

DO $$
DECLARE
    v_rider_id   bigint := current_setting('test.rider_id')::bigint;
    v_station_id bigint := current_setting('test.station_id')::bigint;
    v_bike_id    bigint := current_setting('test.bike_id')::bigint;
    v_rental     bicycle_rental.rental_details;
    v_pay        record;
BEGIN
    FOR v_rental IN SELECT * FROM bicycle_rental.get_active_rental(v_rider_id) LOOP
        PERFORM * FROM bicycle_rental.return_rental(v_rider_id, v_rental.rental_id, v_station_id);
    END LOOP;

    v_rental := bicycle_rental.start_rental(v_rider_id, v_bike_id, NULL);
    PERFORM pg_sleep(0.05);
    SELECT (r.details).* INTO v_rental
      FROM bicycle_rental.return_rental(v_rider_id, v_rental.rental_id, v_station_id) r;

    SELECT * INTO v_pay FROM bicycle_rental.request_payment(v_rider_id, v_rental.rental_id);
    PERFORM set_config('test.rental_id', v_rental.rental_id::text, false);
    PERFORM set_config('test.pay_ref', v_pay.payment_reference::text, false);
    RAISE NOTICE 'PASS: pending payment created (ref=%, amount=%)', v_pay.payment_reference, v_pay.amount;
END $$;

CALL bicycle_rental.submit_payment(
    current_setting('test.rider_id')::bigint,
    current_setting('test.pay_ref')::uuid,
    NULL,
    NULL
);

DO $$
DECLARE
    v_pay record;
BEGIN
    SELECT * INTO v_pay
      FROM bicycle_rental.get_rental_payment(
          current_setting('test.rider_id')::bigint,
          current_setting('test.rental_id')::bigint
      );

    IF v_pay.payment_status IS DISTINCT FROM 'successful' THEN
        RAISE EXCEPTION 'FAIL: expected successful payment, got %', v_pay.payment_status;
    END IF;
    RAISE NOTICE 'PASS: submit_payment succeeded with status = %', v_pay.payment_status;
END $$;

-- 4. Verify bicycle_setup CAN enable privileged_setup
RESET ROLE;
SET ROLE test_setup_login;

BEGIN;
SET LOCAL bicycle_rental.privileged_setup = 'true';
DO $$
BEGIN
    IF NOT bicycle_rental.is_privileged_setup() THEN
        RAISE EXCEPTION 'FAIL: bicycle_setup could not enable privileged_setup!';
    END IF;
    RAISE NOTICE 'PASS: bicycle_setup enabled privileged_setup';
END $$;
ROLLBACK;

-- 5. Clean up temporary test roles
RESET ROLE;
DROP ROLE test_app_login;
DROP ROLE test_setup_login;
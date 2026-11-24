-- Access-control tests (V022): the restricted application role bicycle_app may only call operation
-- functions; it has no table access, no helper/trigger access, and PUBLIC has nothing.
-- Run after all migrations with psql --set=ON_ERROR_STOP=1 as a superuser.
-- Role switching uses SET LOCAL ROLE; deferred constraint checks are forced with
-- SET CONSTRAINTS ALL IMMEDIATE while the restricted role is active (what COMMIT does as that role).
-- All fixtures and helper objects are rolled back.
BEGIN;
SET LOCAL search_path = bicycle_rental, public, pg_temp;

CREATE TEMP TABLE access_test_results (description text NOT NULL);
GRANT ALL ON access_test_results TO PUBLIC;

CREATE FUNCTION pg_temp.assert_true(p_condition boolean, p_description text)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    IF p_condition IS DISTINCT FROM true THEN
        RAISE EXCEPTION 'FAIL: %', p_description;
    END IF;
    INSERT INTO access_test_results VALUES (p_description);
END $$;

-- Run p_sql as p_role and check the SQLSTATE; the role is always reset afterwards.
CREATE FUNCTION pg_temp.expect_error_as(p_role text, p_state text, p_sql text, p_description text)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    BEGIN
        EXECUTE format('SET LOCAL ROLE %I', p_role);
        EXECUTE p_sql;
        RESET ROLE;
    EXCEPTION WHEN OTHERS THEN
        RESET ROLE;
        IF SQLSTATE <> p_state THEN
            RAISE EXCEPTION 'FAIL: %; expected SQLSTATE %, got %: %',
                p_description, p_state, SQLSTATE, SQLERRM;
        END IF;
        INSERT INTO access_test_results VALUES (p_description);
        RETURN;
    END;
    RAISE EXCEPTION 'FAIL: %; expected SQLSTATE %, but command succeeded', p_description, p_state;
END $$;

CREATE FUNCTION pg_temp.fake_hash() RETURNS text LANGUAGE sql IMMUTABLE AS
$$ SELECT '$2a$12$' || rpad('', 53, 'a') $$;

CREATE ROLE test_outsider NOLOGIN;
GRANT USAGE ON SCHEMA bicycle_rental TO test_outsider;

DO $$
DECLARE
    v_prefix text := 'acl-' || gen_random_uuid();
    v_staff bigint; v_rider bigint; v_other bigint; v_new bigint; v_blocked boolean;
    v_station bigint; v_bike bigint; v_rental bigint; v_ended timestamptz;
BEGIN
    ------ catalog state
    PERFORM pg_temp.assert_true(NOT EXISTS (SELECT 1 FROM pg_proc p
        WHERE p.pronamespace = 'bicycle_rental'::regnamespace
          AND has_function_privilege('public', p.oid, 'EXECUTE')),
        'no schema function is executable by PUBLIC');
    PERFORM pg_temp.assert_true(NOT EXISTS (SELECT 1 FROM pg_trigger t JOIN pg_proc p ON p.oid = t.tgfoid
        WHERE p.pronamespace = 'bicycle_rental'::regnamespace AND NOT t.tgisinternal
          AND t.tgconstraint <> 0 AND t.tgdeferrable
          AND NOT (p.prosecdef AND p.proconfig::text LIKE '%search_path=bicycle_rental%')),
        'deferred constraint-trigger functions are SECURITY DEFINER with a fixed search_path');
    PERFORM pg_temp.assert_true(NOT EXISTS (SELECT 1 FROM pg_proc p
        WHERE p.pronamespace = 'bicycle_rental'::regnamespace AND p.prokind IN ('f', 'p')
          AND p.proname <> 'provision_staff'
          AND p.prorettype <> 'trigger'::regtype AND p.prosecdef
          AND NOT has_function_privilege('bicycle_app', p.oid, 'EXECUTE')),
        'bicycle_app can execute every operation function');
    PERFORM pg_temp.assert_true(NOT EXISTS (SELECT 1 FROM pg_proc p
        WHERE p.pronamespace = 'bicycle_rental'::regnamespace
          AND p.proname <> 'submit_payment'
          AND (NOT p.prosecdef OR p.prorettype = 'trigger'::regtype)
          AND has_function_privilege('bicycle_app', p.oid, 'EXECUTE')),
        'bicycle_app cannot execute helpers, trigger functions or other non-definer functions');
    PERFORM pg_temp.assert_true(NOT EXISTS (SELECT 1 FROM pg_class c
        WHERE c.relnamespace = 'bicycle_rental'::regnamespace AND c.relkind IN ('r', 'v', 'm', 'p')
          AND (has_table_privilege('bicycle_app', c.oid, 'SELECT,INSERT,UPDATE,DELETE,TRUNCATE')
               OR has_table_privilege('test_outsider', c.oid, 'SELECT,INSERT,UPDATE,DELETE'))),
        'neither bicycle_app nor an outsider has any table privilege');

    PERFORM pg_temp.assert_true(NOT has_function_privilege('bicycle_app', 'bicycle_rental.provision_staff(text,text,text,text)', 'EXECUTE')
        AND has_function_privilege('bicycle_setup', 'bicycle_rental.provision_staff(text,text,text,text)', 'EXECUTE'),
        'only the setup role, not bicycle_app, may provision staff');

    PERFORM pg_temp.assert_true(has_function_privilege('bicycle_app', 'bicycle_rental.submit_payment(bigint,uuid,bicycle_rental.payment_status,boolean)', 'EXECUTE')
        AND has_function_privilege('bicycle_app', 'bicycle_rental.request_payment(bigint,bigint)', 'EXECUTE')
        AND NOT has_function_privilege('bicycle_app', 'bicycle_rental.simulator_submit(uuid,bigint,numeric,character varying)', 'EXECUTE')
        AND NOT has_function_privilege('bicycle_app', 'bicycle_rental.apply_payment_confirmation(uuid,bigint,numeric,character varying,text)', 'EXECUTE'),
        'bicycle_app can use the payment entry points but not the simulator or confirmation internals');

    ------ fixtures (as the owner)
    v_staff := provision_staff('Acl', 'Staff', v_prefix || '-staff@test.invalid', 'pw-staff');
    v_rider := register_rider('Acl', 'Rider', v_prefix || '-rider@test.invalid', 'pw-rider');
    v_other := register_rider('Acl', 'Other', v_prefix || '-other@test.invalid', 'pw-other');
    v_station := create_station(v_staff, v_prefix || ' A', 'Street', 52, 21, true, true);
    v_bike := create_bicycle(v_staff, v_prefix || '-1', 'regular', 'serviceable', v_station);

    ------ direct table and helper access is refused
    PERFORM pg_temp.expect_error_as('bicycle_app', '42501', 'SELECT * FROM bicycle_rental.account', 'app role cannot read account');
    PERFORM pg_temp.expect_error_as('bicycle_app', '42501', 'SELECT * FROM bicycle_rental.audit_entry', 'app role cannot read audit entries');
    PERFORM pg_temp.expect_error_as('bicycle_app', '42501', 'SELECT * FROM bicycle_rental.audit_detail', 'app role cannot read audit details');
    PERFORM pg_temp.expect_error_as('bicycle_app', '42501', 'SELECT * FROM bicycle_rental.rental', 'app role cannot read rentals');
    PERFORM pg_temp.expect_error_as('bicycle_app', '42501', $q$INSERT INTO bicycle_rental.account (first_name,last_name,email,password_hash,role)
        VALUES ('x','y','x@test.invalid',pg_temp.fake_hash(),'staff')$q$, 'app role cannot insert accounts directly');
    PERFORM pg_temp.expect_error_as('bicycle_app', '42501', 'UPDATE bicycle_rental.rider SET status = ''blocked''', 'app role cannot update riders directly');
    PERFORM pg_temp.expect_error_as('bicycle_app', '42501', 'DELETE FROM bicycle_rental.audit_entry', 'app role cannot delete audit entries');
    PERFORM pg_temp.expect_error_as('bicycle_app', '42501', format('SELECT bicycle_rental.require_staff(%s)', v_staff), 'app role cannot call internal helpers');
    PERFORM pg_temp.expect_error_as('bicycle_app', '42501',
        $q$SELECT bicycle_rental.provision_staff('x', 'y', 'x@test.invalid', 'pw')$q$, 'app role cannot provision staff');
    PERFORM pg_temp.expect_error_as('test_outsider', '42501',
        $q$SELECT bicycle_rental.provision_staff('x', 'y', 'x@test.invalid', 'pw')$q$, 'outsider cannot provision staff');
    PERFORM pg_temp.expect_error_as('bicycle_app', '42501',
        format($q$SELECT bicycle_rental.record_audit_event(%s, 'rider_block', 'Rider', %s, '[{}]'::jsonb)$q$, v_staff, v_rider),
        'app role cannot write audit entries directly');

    ------ an unrelated role gets nothing
    PERFORM pg_temp.expect_error_as('test_outsider', '42501',
        $q$SELECT * FROM bicycle_rental.authenticate_account('a@b.c', 'x')$q$, 'outsider cannot authenticate');
    PERFORM pg_temp.expect_error_as('test_outsider', '42501', format('SELECT bicycle_rental.register_rider(%L, %L, %L, %L)', 'A', 'B', 'o@test.invalid', 'pw'),
        'outsider cannot register');
    PERFORM pg_temp.expect_error_as('test_outsider', '42501', format('SELECT * FROM bicycle_rental.get_account(%s, %s)', v_staff, v_rider),
        'outsider cannot read accounts');

    ------ setup role can provision staff
    SET LOCAL ROLE bicycle_setup;
    v_new := provision_staff('Acl', 'Setup', v_prefix || '-setup@test.invalid', 'pw-setup');
    SET CONSTRAINTS ALL IMMEDIATE;
    SET CONSTRAINTS ALL DEFERRED;
    RESET ROLE;
    PERFORM pg_temp.assert_true(EXISTS (SELECT 1 FROM staff WHERE account_id = v_new), 'bicycle_setup can provision staff');

    ------ operations through the application role
    SET LOCAL ROLE bicycle_app;
    v_new := register_rider('Acl', 'New', v_prefix || '-new@test.invalid', 'pw-new');
    PERFORM authenticate_account(v_prefix || '-new@test.invalid', 'pw-new');
    SET CONSTRAINTS ALL IMMEDIATE;      -- deferred triggers run as bicycle_app here
    SET CONSTRAINTS ALL DEFERRED;
    RESET ROLE;
    PERFORM pg_temp.assert_true(EXISTS (SELECT 1 FROM rider WHERE account_id = v_new), 'bicycle_app can register a rider and pass the deferred subtype check');
    PERFORM pg_temp.assert_true((SELECT account_id = v_new FROM authenticate_account(v_prefix || '-new@test.invalid', 'pw-new')),
        'bicycle_app can authenticate');

    SET LOCAL ROLE bicycle_app;
    v_blocked := block_rider(v_staff, v_other, 'acl test');
    SET CONSTRAINTS ALL IMMEDIATE;      -- audit entry/detail deferred check as bicycle_app
    SET CONSTRAINTS ALL DEFERRED;
    RESET ROLE;
    PERFORM pg_temp.assert_true(v_blocked AND (SELECT status = 'blocked' FROM rider WHERE account_id = v_other),
        'bicycle_app can block a rider through the operation');
    PERFORM pg_temp.assert_true(EXISTS (SELECT 1 FROM audit_entry WHERE primary_record_id = v_other AND action_type = 'rider_block'),
        'blocking through bicycle_app wrote its audit entry');

    PERFORM pg_temp.expect_error_as('bicycle_app', '42501', format('SELECT * FROM bicycle_rental.get_account(%s, %s)', v_rider, v_other),
        'a rider cannot read another rider, even through bicycle_app');
    PERFORM pg_temp.expect_error_as('bicycle_app', '42501', format('SELECT bicycle_rental.block_rider(%s, %s)', v_rider, v_other),
        'a rider cannot block, even through bicycle_app');

    SET LOCAL ROLE bicycle_app;
    v_rental := (start_rental(v_rider, v_bike)).rental_id;
    SET CONSTRAINTS ALL IMMEDIATE;
    SET CONSTRAINTS ALL DEFERRED;
    PERFORM return_rental(v_rider, v_rental, v_station);
    SET CONSTRAINTS ALL IMMEDIATE;
    SET CONSTRAINTS ALL DEFERRED;
    RESET ROLE;
    SELECT end_time INTO v_ended FROM rental WHERE rental_id = v_rental;
    PERFORM pg_temp.assert_true(v_ended IS NOT NULL, 'bicycle_app can start and return a rental, deferred checks included');
    SET CONSTRAINTS ALL IMMEDIATE;
END $$;

SELECT count(*) AS access_control_assertions_passed FROM access_test_results;

ROLLBACK;

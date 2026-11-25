-- Account system tests (V004-V006): table constraints and subtype integrity, registration and login,
-- operation-level access rules, rider blocking with audit records, audit log integrity.
-- Run after all migrations with psql --set=ON_ERROR_STOP=1. Needs a superuser or the table owner
-- (it runs direct DML on protected tables). Each section is rolled back to its own savepoint,
-- so nothing is left behind.
BEGIN;
SET LOCAL search_path = bicycle_rental, public, pg_temp;

CREATE TEMP TABLE account_test_results (description text NOT NULL);

CREATE FUNCTION pg_temp.assert_true(p_condition boolean, p_description text)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    IF p_condition IS DISTINCT FROM true THEN
        RAISE EXCEPTION 'FAIL: %', p_description;
    END IF;
    INSERT INTO account_test_results VALUES (p_description);
END $$;

-- Check SQLSTATE of a rejected command; the rejected command is rolled back.
CREATE FUNCTION pg_temp.expect_error(p_state text, p_sql text, p_description text)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    BEGIN
        EXECUTE p_sql;
    EXCEPTION WHEN OTHERS THEN
        IF SQLSTATE <> p_state THEN
            RAISE EXCEPTION 'FAIL: %; expected SQLSTATE %, got %: %',
                p_description, p_state, SQLSTATE, SQLERRM;
        END IF;
        INSERT INTO account_test_results VALUES (p_description);
        RETURN;
    END;
    RAISE EXCEPTION 'FAIL: %; expected SQLSTATE %, but command succeeded', p_description, p_state;
END $$;

CREATE FUNCTION pg_temp.fake_hash() RETURNS text LANGUAGE sql IMMUTABLE AS
$$ SELECT '$2a$12$' || rpad('', 53, 'a') $$;

CREATE FUNCTION pg_temp.reject_audit_detail() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN RAISE EXCEPTION 'injected audit failure' USING ERRCODE = 'XX001'; END $$;

SAVEPOINT section;


------ account_constraints

DO $test$
DECLARE
    v_rid bigint;
    v_sid bigint;
BEGIN
    -- Table-level constraints and subtype integrity. Run via run-tests (helpers are prepended).
    INSERT INTO bicycle_rental.account (first_name, last_name, email, password_hash, role)
    VALUES ('Ann', 'Rider', 'Ann.Rider@Example.com', pg_temp.fake_hash(), 'rider');
    INSERT INTO bicycle_rental.rider (account_id)
    SELECT account_id FROM bicycle_rental.account WHERE email = 'Ann.Rider@Example.com';
    INSERT INTO bicycle_rental.account (first_name, last_name, email, password_hash, role)
    VALUES ('Sam', 'Staff', 'sam@example.com', pg_temp.fake_hash(), 'staff');
    INSERT INTO bicycle_rental.staff (account_id)
    SELECT account_id FROM bicycle_rental.account WHERE email = 'sam@example.com';
    SELECT account_id INTO v_rid FROM bicycle_rental.account WHERE email = 'Ann.Rider@Example.com';
    SELECT account_id INTO v_sid FROM bicycle_rental.account WHERE email = 'sam@example.com';

    SET CONSTRAINTS ALL IMMEDIATE;   -- simulate COMMIT-time checks: valid fixtures pass
    SET CONSTRAINTS ALL DEFERRED;
    PERFORM pg_temp.assert_true(
      (SELECT status = 'active' AND block_reason IS NULL FROM bicycle_rental.rider WHERE account_id = v_rid),
      'rider defaults to active without block reason');

    -- account column checks
    PERFORM pg_temp.expect_error('23514', $q$INSERT INTO bicycle_rental.account (first_name,last_name,email,password_hash,role)
      VALUES ('  ','X','a1@example.com',pg_temp.fake_hash(),'rider')$q$, 'blank first name rejected');
    PERFORM pg_temp.expect_error('23514', $q$INSERT INTO bicycle_rental.account (first_name,last_name,email,password_hash,role)
      VALUES ('X',E'\t','a2@example.com',pg_temp.fake_hash(),'rider')$q$, 'whitespace-only last name rejected');
    PERFORM pg_temp.expect_error('23514', $q$INSERT INTO bicycle_rental.account (first_name,last_name,email,password_hash,role)
      VALUES ('X','Y','   ',pg_temp.fake_hash(),'rider')$q$, 'blank email rejected');
    PERFORM pg_temp.expect_error('23514', $q$INSERT INTO bicycle_rental.account (first_name,last_name,email,password_hash,role)
      VALUES ('X','Y',' padded@example.com',pg_temp.fake_hash(),'rider')$q$, 'untrimmed email rejected');
    PERFORM pg_temp.expect_error('23514', $q$INSERT INTO bicycle_rental.account (first_name,last_name,email,password_hash,role)
      VALUES ('X','Y','a3@example.com','plaintext-password','rider')$q$, 'non-bcrypt password_hash rejected');
    PERFORM pg_temp.expect_error('23502', $q$INSERT INTO bicycle_rental.account (first_name,last_name,email,password_hash,role)
      VALUES ('X','Y','a4@example.com',NULL,'rider')$q$, 'NULL password_hash rejected');
    PERFORM pg_temp.expect_error('22P02', $q$INSERT INTO bicycle_rental.account (first_name,last_name,email,password_hash,role)
      VALUES ('X','Y','a5@example.com',pg_temp.fake_hash(),'admin')$q$, 'unsupported role rejected');
    PERFORM pg_temp.expect_error('23502', $q$INSERT INTO bicycle_rental.account (first_name,last_name,email,password_hash,role)
      VALUES ('X','Y','a6@example.com',pg_temp.fake_hash(),NULL)$q$, 'missing role rejected');

    -- F-002 / F-087 email uniqueness
    PERFORM pg_temp.expect_error('23505', $q$INSERT INTO bicycle_rental.account (first_name,last_name,email,password_hash,role)
      VALUES ('X','Y','ann.rider@example.com',pg_temp.fake_hash(),'rider')$q$, 'duplicate email differing only in case rejected');
    PERFORM pg_temp.expect_error('23505', $q$INSERT INTO bicycle_rental.account (first_name,last_name,email,password_hash,role)
      VALUES ('X','Y','ANN.RIDER@EXAMPLE.COM',pg_temp.fake_hash(),'staff')$q$, 'duplicate across rider and staff rejected');
    INSERT INTO bicycle_rental.account (first_name,last_name,email,password_hash,role)
      VALUES ('D','Ots','annrider@example.com',pg_temp.fake_hash(),'rider');
    INSERT INTO bicycle_rental.account (first_name,last_name,email,password_hash,role)
      VALUES ('P','Lus','ann.rider+x@example.com',pg_temp.fake_hash(),'rider');
    PERFORM pg_temp.assert_true(
      (SELECT email FROM bicycle_rental.account WHERE account_id = v_rid) = 'Ann.Rider@Example.com',
      'display email keeps original capitalization');
    -- the two helper accounts above have no subtype row yet: the deferred check must object
    PERFORM pg_temp.expect_error('23514', 'SET CONSTRAINTS ALL IMMEDIATE', 'account without subtype row fails at commit time');
    SET CONSTRAINTS ALL DEFERRED;

    -- rider / staff checks
    PERFORM pg_temp.expect_error('23514', $q$UPDATE bicycle_rental.rider SET status='blocked', block_reason='  '$q$, 'blank block reason rejected');
    PERFORM pg_temp.expect_error('23514', format($q$UPDATE bicycle_rental.rider SET block_reason='oops' WHERE account_id=%s$q$, v_rid), 'block reason on an active rider rejected');
    PERFORM pg_temp.expect_error('23502', format($q$UPDATE bicycle_rental.rider SET status=NULL WHERE account_id=%s$q$, v_rid), 'NULL rider status rejected');
    PERFORM pg_temp.expect_error('22P02', format($q$UPDATE bicycle_rental.rider SET status='suspended'::bicycle_rental.rider_status WHERE account_id=%s$q$, v_rid), 'unsupported rider status rejected');
    PERFORM pg_temp.expect_error('23503', 'INSERT INTO bicycle_rental.rider (account_id) VALUES (-1)', 'rider for unknown account rejected (FK)');
    PERFORM pg_temp.expect_error('23503', 'INSERT INTO bicycle_rental.staff (account_id) VALUES (-1)', 'staff for unknown account rejected (FK)');

    -- subtype specialization rules
    PERFORM pg_temp.expect_error('23503', format('INSERT INTO bicycle_rental.staff (account_id) VALUES (%s)', v_rid), 'staff row for a rider-role account rejected');
    PERFORM pg_temp.expect_error('23503', format('INSERT INTO bicycle_rental.rider (account_id) VALUES (%s)', v_sid), 'rider row for a staff-role account rejected');
    PERFORM pg_temp.expect_error('23505', format('INSERT INTO bicycle_rental.rider (account_id) VALUES (%s)', v_rid), 'second rider row for the same account rejected');
    PERFORM pg_temp.expect_error('23514', format('UPDATE bicycle_rental.rider SET account_id = %s WHERE account_id = %s', v_sid, v_rid), 'rider key cannot be re-pointed');
    PERFORM pg_temp.expect_error('23514', format($q$UPDATE bicycle_rental.account SET role='staff' WHERE account_id=%s$q$, v_rid), 'account role cannot change');
    PERFORM pg_temp.expect_error('428C9', format('UPDATE bicycle_rental.account SET account_id = 999999 WHERE account_id = %s', v_rid), 'account identity cannot change (generated always identity)');

    -- F-083 no deletion
    PERFORM pg_temp.expect_error('23000', format('DELETE FROM bicycle_rental.rider WHERE account_id=%s', v_rid), 'rider cannot be deleted');
    PERFORM pg_temp.expect_error('23000', format('DELETE FROM bicycle_rental.staff WHERE account_id=%s', v_sid), 'staff cannot be deleted');
    PERFORM pg_temp.expect_error('23000', format('DELETE FROM bicycle_rental.account WHERE account_id=%s', v_rid), 'account cannot be deleted');


END $test$;

SELECT '01_account_constraints' AS section, count(*) AS assertions_passed FROM account_test_results;
ROLLBACK TO SAVEPOINT section;
SAVEPOINT section;

------  registration_login
DO $test$
DECLARE
    v_rid bigint;
    v_sid bigint;
    v_ok1 bigint;
    v_ok2 bigint;
BEGIN
    -- Registration (F-003/F-004/F-087) and credential verification (F-006).
    v_rid := bicycle_rental.register_rider('Ann', 'Rider', '  Ann.Rider@Example.com ', 'S3cret pass!');
    v_sid := bicycle_rental.provision_staff('Sam', 'Staff', 'sam@example.com', 'StaffPass1');
    SET CONSTRAINTS ALL IMMEDIATE;
    SET CONSTRAINTS ALL DEFERRED;

    PERFORM pg_temp.assert_true((SELECT role = 'rider' FROM bicycle_rental.account WHERE account_id = v_rid), 'registration assigns rider role');
    PERFORM pg_temp.assert_true((SELECT status = 'active' FROM bicycle_rental.rider WHERE account_id = v_rid), 'registered rider is active');
    PERFORM pg_temp.assert_true(NOT EXISTS (SELECT 1 FROM bicycle_rental.staff WHERE account_id = v_rid), 'registered rider has no staff row');
    PERFORM pg_temp.assert_true((SELECT email FROM bicycle_rental.account WHERE account_id = v_rid) = 'Ann.Rider@Example.com',
      'email stored trimmed with original capitalization');
    PERFORM pg_temp.assert_true((SELECT password_hash <> 'S3cret pass!' AND password_hash LIKE '$2a$12$%' FROM bicycle_rental.account WHERE account_id = v_rid),
      'password stored as bcrypt hash, not plaintext');
    PERFORM pg_temp.assert_true(
      (SELECT count(DISTINCT password_hash) = 2 FROM (
         SELECT password_hash FROM bicycle_rental.account WHERE account_id = v_rid
         UNION ALL SELECT public.crypt('S3cret pass!', public.gen_salt('bf', 4))) h),
      'hashes use independent salts');

    -- duplicates (F-002)
    PERFORM pg_temp.expect_error('23505', $q$SELECT bicycle_rental.register_rider('A','B','ann.rider@example.com','pw')$q$, 'duplicate email (lower case) rejected');
    PERFORM pg_temp.expect_error('23505', $q$SELECT bicycle_rental.register_rider('A','B','ANN.RIDER@EXAMPLE.COM','pw')$q$, 'duplicate email (upper case) rejected');
    PERFORM pg_temp.expect_error('23505', $q$SELECT bicycle_rental.register_rider('A','B',E'\t ann.rider@example.com \n','pw')$q$, 'duplicate email with surrounding whitespace rejected');
    PERFORM pg_temp.expect_error('23505', $q$SELECT bicycle_rental.register_rider('A','B','SAM@example.com','pw')$q$, 'rider cannot reuse a staff email');
    PERFORM pg_temp.expect_error('23505', $q$SELECT bicycle_rental.provision_staff('A','B','ann.RIDER@example.com','pw')$q$, 'staff cannot reuse a rider email');
    v_ok1 := bicycle_rental.register_rider('Dot', 'Less', 'annrider@example.com', 'pw1');
    v_ok2 := bicycle_rental.register_rider('Plus', 'Tag', 'ann.rider+bikes@example.com', 'pw2');
    PERFORM pg_temp.assert_true(v_ok1 IS NOT NULL AND v_ok2 IS NOT NULL, 'dots and +suffix remain significant');

    -- validation (F-003)
    PERFORM pg_temp.expect_error('22023', $q$SELECT bicycle_rental.register_rider(NULL,'B','n1@example.com','pw')$q$, 'missing first name rejected');
    PERFORM pg_temp.expect_error('22023', $q$SELECT bicycle_rental.register_rider('  ','B','n2@example.com','pw')$q$, 'blank first name rejected');
    PERFORM pg_temp.expect_error('22023', $q$SELECT bicycle_rental.register_rider('A',' ','n3@example.com','pw')$q$, 'blank last name rejected');
    PERFORM pg_temp.expect_error('22023', $q$SELECT bicycle_rental.register_rider('A','B','   ','pw')$q$, 'email empty after trimming rejected');
    PERFORM pg_temp.expect_error('22023', $q$SELECT bicycle_rental.register_rider('A','B',NULL,'pw')$q$, 'missing email rejected');
    PERFORM pg_temp.expect_error('22023', $q$SELECT bicycle_rental.register_rider('A','B','n4@example.com','')$q$, 'empty password rejected');
    PERFORM pg_temp.expect_error('22023', $q$SELECT bicycle_rental.register_rider('A','B','n5@example.com',NULL)$q$, 'missing password rejected');
    PERFORM pg_temp.expect_error('22023', format($q$SELECT bicycle_rental.register_rider('A','B','n6@example.com',%L)$q$, repeat('x', 73)), 'password over 72 bytes rejected (no silent truncation)');
    PERFORM pg_temp.expect_error('22023', format($q$SELECT bicycle_rental.register_rider('A','B','n7@example.com',%L)$q$, repeat('é', 37)), 'password over 72 bytes (multi-byte) rejected');
    PERFORM pg_temp.assert_true(NOT EXISTS (SELECT 1 FROM bicycle_rental.account WHERE email LIKE 'n_@example.com'),
      'rejected registrations leave no partial account');

    -- login (F-006)
    PERFORM pg_temp.assert_true((SELECT account_id = v_rid AND role = 'rider' AND rider_status = 'active'
      FROM bicycle_rental.authenticate_account('Ann.Rider@Example.com', 'S3cret pass!')), 'valid rider credentials authenticate');
    PERFORM pg_temp.assert_true((SELECT account_id = v_rid FROM bicycle_rental.authenticate_account('  ANN.rider@example.COM ', 'S3cret pass!')),
      'login by an equivalent email (case/whitespace) succeeds');
    PERFORM pg_temp.assert_true((SELECT account_id = v_sid AND role = 'staff' AND rider_status IS NULL
      FROM bicycle_rental.authenticate_account('sam@example.com', 'StaffPass1')), 'valid staff credentials authenticate');
    PERFORM pg_temp.assert_true(NOT EXISTS (SELECT 1 FROM bicycle_rental.authenticate_account('ann.rider@example.com', 's3cret pass!')), 'wrong password (case differs) rejected');
    PERFORM pg_temp.assert_true(NOT EXISTS (SELECT 1 FROM bicycle_rental.authenticate_account('ann.rider@example.com', 'S3cret pass! ')), 'password is not trimmed');
    PERFORM pg_temp.assert_true(NOT EXISTS (SELECT 1 FROM bicycle_rental.authenticate_account('nobody@example.com', 'S3cret pass!')), 'unknown email rejected');
    PERFORM pg_temp.assert_true(NOT EXISTS (SELECT 1 FROM bicycle_rental.authenticate_account(NULL, 'x')), 'missing email rejected');
    PERFORM pg_temp.assert_true(NOT EXISTS (SELECT 1 FROM bicycle_rental.authenticate_account('ann.rider@example.com', NULL)), 'missing password rejected');
    PERFORM pg_temp.assert_true(NOT EXISTS (SELECT 1 FROM bicycle_rental.authenticate_account('ann.rider@example.com', '')), 'empty password rejected');
    PERFORM pg_temp.assert_true(NOT EXISTS (SELECT 1 FROM bicycle_rental.authenticate_account('ann.rider@example.com', 'S3cret pass!' || repeat('x', 70))),
      'over-long password never matches via truncation');
    PERFORM pg_temp.assert_true(
      (SELECT to_jsonb(t) ? 'password_hash' FROM bicycle_rental.authenticate_account('sam@example.com','StaffPass1') t) IS NOT TRUE,
      'login result contains no password hash');

    PERFORM bicycle_rental.block_rider(v_sid, v_rid, 'unpaid');
    PERFORM pg_temp.assert_true((SELECT rider_status = 'blocked' FROM bicycle_rental.authenticate_account('ann.rider@example.com', 'S3cret pass!')),
      'blocked rider can still log in and sees blocked status');


END $test$;

SELECT '02_registration_login' AS section, count(*) AS assertions_passed FROM account_test_results;
ROLLBACK TO SAVEPOINT section;
SAVEPOINT section;

------  access_restrictions
DO $test$
DECLARE
    v_r1 bigint;
    v_r2 bigint;
    v_s1 bigint;
    v_r3 bigint;
BEGIN
    -- Rider/Staff access restrictions at operation level (F-014..F-016, F-089).
    -- Database-role privilege checks belong to the later access-control migration.
    v_r1 := bicycle_rental.register_rider('Ann', 'Rider', 'ann@example.com', 'pw-ann');
    v_r2 := bicycle_rental.register_rider('Bob', 'Rider', 'bob@example.com', 'pw-bob');
    v_s1 := bicycle_rental.provision_staff('Sam', 'Staff', 'sam@example.com', 'pw-sam');

    -- operations through the application role
    v_r3 := bicycle_rental.register_rider('Cy', 'Rider', 'cy@example.com', 'pw-cy');
    PERFORM pg_temp.assert_true((SELECT account_id = v_r1 FROM bicycle_rental.authenticate_account('ann@example.com', 'pw-ann')), 'app role can register and authenticate');

    -- riders: own data only
    PERFORM pg_temp.assert_true((SELECT email = 'ann@example.com' AND rider_status = 'active' FROM bicycle_rental.get_account(v_r1, v_r1)), 'rider reads own account');
    PERFORM pg_temp.expect_error('42501', format('SELECT * FROM bicycle_rental.get_account(%s, %s)', v_r1, v_r2), 'rider cannot read another rider');
    PERFORM pg_temp.expect_error('42501', format('SELECT * FROM bicycle_rental.get_account(%s, %s)', v_r1, v_s1), 'rider cannot read a staff account');
    PERFORM pg_temp.expect_error('42501', format('SELECT * FROM bicycle_rental.get_account(%s, 99999999)', v_r1), 'rider probing an unknown id gets the same rejection');
    PERFORM pg_temp.expect_error('42501', 'SELECT * FROM bicycle_rental.get_account(NULL, 1)', 'missing actor rejected');
    PERFORM pg_temp.expect_error('42501', 'SELECT * FROM bicycle_rental.get_account(99999999, 99999999)', 'unknown actor rejected');
    PERFORM pg_temp.expect_error('42501', format('SELECT * FROM bicycle_rental.list_riders(%s)', v_r1), 'rider cannot list riders');
    PERFORM pg_temp.expect_error('42501', format('SELECT bicycle_rental.block_rider(%s, %s)', v_r1, v_r2), 'rider cannot block another rider');
    PERFORM pg_temp.expect_error('42501', format('SELECT bicycle_rental.block_rider(%s, %s)', v_r1, v_r1), 'rider cannot block themselves');
    PERFORM pg_temp.expect_error('42501', format('SELECT bicycle_rental.unblock_rider(%s, %s)', v_r1, v_r2), 'rider cannot unblock');
    PERFORM pg_temp.expect_error('42501', format('SELECT * FROM bicycle_rental.list_audit_entries(%s)', v_r1), 'rider cannot query the audit log');
    PERFORM pg_temp.expect_error('42501', format('SELECT * FROM bicycle_rental.get_audit_entry_details(%s, 1)', v_r1), 'rider cannot read audit details');
    PERFORM pg_temp.expect_error('42501', 'SELECT bicycle_rental.block_rider(NULL, 1)', 'NULL actor cannot block');
    PERFORM pg_temp.expect_error('42501', format('SELECT bicycle_rental.block_rider(99999999, %s)', v_r2), 'unknown actor cannot block');

    -- staff: broad read access, but riders are never staff
    PERFORM pg_temp.assert_true((SELECT email = 'bob@example.com' FROM bicycle_rental.get_account(v_s1, v_r2)), 'staff reads any rider');
    PERFORM pg_temp.assert_true((SELECT role = 'staff' AND rider_status IS NULL FROM bicycle_rental.get_account(v_s1, v_s1)), 'staff reads own staff account');
    PERFORM pg_temp.assert_true((SELECT count(*) = 3 FROM bicycle_rental.list_riders(v_s1) WHERE account_id IN (v_r1, v_r2, v_r3)), 'staff lists all riders');
    PERFORM pg_temp.assert_true(NOT EXISTS (SELECT 1 FROM bicycle_rental.list_riders(v_s1) WHERE account_id = v_s1), 'staff accounts are not listed as riders');
    PERFORM pg_temp.expect_error('P0002', format('SELECT bicycle_rental.block_rider(%s, %s)', v_s1, v_s1), 'blocking a staff account is rejected as unknown rider');
    PERFORM pg_temp.expect_error('P0002', format('SELECT bicycle_rental.block_rider(%s, 99999999)', v_s1), 'blocking an unknown rider rejected');

    PERFORM pg_temp.assert_true((SELECT count(*) = 0 FROM bicycle_rental.audit_entry), 'rejected operations wrote no audit entries');
    PERFORM pg_temp.assert_true((SELECT count(*) = 0 FROM bicycle_rental.rider WHERE status = 'blocked'), 'rejected operations changed no rider');


END $test$;

SELECT '03_access_restrictions' AS section, count(*) AS assertions_passed FROM account_test_results;
ROLLBACK TO SAVEPOINT section;
SAVEPOINT section;

------  blocking_and_audit
DO $test$
DECLARE
    v_r1 bigint;
    v_r2 bigint;
    v_s1 bigint;
    v_s2 bigint;
    v_changed boolean;
    v_e1 bigint;
    v_c2 boolean;
    v_c3 boolean;
    v_c4 boolean;
    v_c5 boolean;
    v_c5b boolean;
    v_u0 boolean;
    v_c6 boolean;
    v_u0b boolean;
    v_u1 boolean;
    v_u2 boolean;
    v_e2 bigint;
    v_c7 boolean;
BEGIN
    -- Rider blocking / unblocking (F-016, F-088) and its audit records (F-069..F-072, F-075, F-117).
    v_r1 := bicycle_rental.register_rider('Ann', 'Rider', 'ann@example.com', 'pw-ann');
    v_r2 := bicycle_rental.register_rider('Bob', 'Rider', 'bob@example.com', 'pw-bob');
    v_s1 := bicycle_rental.provision_staff('Sam', 'Staff', 'sam@example.com', 'pw-sam');
    v_s2 := bicycle_rental.provision_staff('Tia', 'Staff', 'tia@example.com', 'pw-tia');

    -- block with a reason
    v_changed := bicycle_rental.block_rider(v_s1, v_r1, '  unpaid fines ');
    PERFORM pg_temp.assert_true((v_changed)::boolean, 'block_rider reports a change');
    PERFORM pg_temp.assert_true((SELECT rider_status = 'blocked' AND block_reason = 'unpaid fines' FROM bicycle_rental.get_account(v_s1, v_r1)),
      'staff sees blocked status and trimmed reason');
    PERFORM pg_temp.assert_true((SELECT rider_status = 'blocked' AND block_reason IS NULL FROM bicycle_rental.get_account(v_r1, v_r1)),
      'blocked rider sees own status but not the staff-entered reason');
    PERFORM pg_temp.assert_true((SELECT rider_status = 'active' FROM bicycle_rental.get_account(v_s1, v_r2)), 'other riders unaffected');

    -- audit record for the block
    PERFORM pg_temp.assert_true((SELECT count(*) = 1 FROM bicycle_rental.list_audit_entries(v_s1, NULL, 'rider_block', 'Rider', v_r1)), 'exactly one audit entry for the block');
    SELECT audit_id INTO v_e1 FROM bicycle_rental.list_audit_entries(v_s1, NULL, 'rider_block', 'Rider', v_r1);
    PERFORM pg_temp.assert_true((SELECT staff_id = v_s1 AND primary_record_type = 'Rider' AND primary_record_id = v_r1
      FROM bicycle_rental.list_audit_entries(v_s1) WHERE audit_id = v_e1), 'audit entry records actor, record type and id');
    PERFORM pg_temp.assert_true((SELECT previous_value = '"active"'::jsonb AND new_value = '"blocked"'::jsonb
      FROM bicycle_rental.get_audit_entry_details(v_s1, v_e1) WHERE field_name = 'status'), 'audit detail stores previous/new status');
    PERFORM pg_temp.assert_true((SELECT previous_value IS NULL AND new_value = '"unpaid fines"'::jsonb
      FROM bicycle_rental.get_audit_entry_details(v_s1, v_e1) WHERE field_name = 'block_reason'), 'audit detail stores previous/new reason');
    PERFORM pg_temp.assert_true((SELECT array_agg(detail_no ORDER BY detail_no) = ARRAY[1,2] FROM bicycle_rental.get_audit_entry_details(v_s1, v_e1)), 'details are numbered within the entry');

    -- idempotent / no-op behaviour (F-069: no-op creates no entry)
    v_c2 := bicycle_rental.block_rider(v_s1, v_r1);
    v_c3 := bicycle_rental.block_rider(v_s2, v_r1, 'unpaid fines');
    PERFORM pg_temp.assert_true(NOT (v_c2)::boolean AND NOT (v_c3)::boolean, 're-blocking with no or identical reason is a no-op');
    PERFORM pg_temp.assert_true((SELECT count(*) = 1 FROM bicycle_rental.list_audit_entries(v_s1, NULL, NULL, 'Rider', v_r1)), 'no-op block created no extra audit entry');
    PERFORM pg_temp.assert_true((SELECT block_reason = 'unpaid fines' FROM bicycle_rental.get_account(v_s1, v_r1)), 're-block without reason keeps existing reason');

    -- changing the reason while blocked is an audited change
    v_c4 := bicycle_rental.block_rider(v_s2, v_r1, 'abuse');
    PERFORM pg_temp.assert_true((v_c4)::boolean, 'changing the reason of a blocked rider is a change');
    PERFORM pg_temp.assert_true((SELECT count(*) = 2 FROM bicycle_rental.list_audit_entries(v_s1, NULL, 'rider_block', 'Rider', v_r1)), 'reason change audited');

    -- block without reason (F-088)
    v_c5 := bicycle_rental.block_rider(v_s1, v_r2);
    v_c5b := bicycle_rental.block_rider(v_s1, v_r2);
    PERFORM pg_temp.assert_true((v_c5)::boolean AND (SELECT rider_status = 'blocked' AND block_reason IS NULL FROM bicycle_rental.get_account(v_s1, v_r2)), 'blocking works without a reason');
    v_u0 := bicycle_rental.unblock_rider(v_s1, v_r2);
    v_c6 := bicycle_rental.block_rider(v_s1, v_r2, '   ');
    PERFORM pg_temp.assert_true((SELECT block_reason IS NULL FROM bicycle_rental.get_account(v_s1, v_r2)), 'blank reason treated as no reason');
    v_u0b := bicycle_rental.unblock_rider(v_s1, v_r2);

    -- unblock
    v_u1 := bicycle_rental.unblock_rider(v_s2, v_r1);
    PERFORM pg_temp.assert_true((v_u1)::boolean AND (SELECT rider_status = 'active' AND block_reason IS NULL FROM bicycle_rental.get_account(v_s1, v_r1)),
      'staff can unblock; reason is cleared');
    v_u2 := bicycle_rental.unblock_rider(v_s2, v_r1);
    PERFORM pg_temp.assert_true(NOT (v_u2)::boolean, 'unblocking an active rider is a no-op');
    PERFORM pg_temp.assert_true((SELECT count(*) = 1 FROM bicycle_rental.list_audit_entries(v_s1, v_s2, 'rider_unblock', 'Rider', v_r1)), 'exactly one unblock entry, attributed to the acting staff');
    SELECT audit_id INTO v_e2 FROM bicycle_rental.list_audit_entries(v_s1, NULL, 'rider_unblock', 'Rider', v_r1);
    PERFORM pg_temp.assert_true((SELECT previous_value = '"blocked"'::jsonb AND new_value = '"active"'::jsonb
      FROM bicycle_rental.get_audit_entry_details(v_s1, v_e2) WHERE field_name = 'status'), 'unblock audit stores status change');
    PERFORM pg_temp.assert_true((SELECT previous_value = '"abuse"'::jsonb AND new_value IS NULL
      FROM bicycle_rental.get_audit_entry_details(v_s1, v_e2) WHERE field_name = 'block_reason'), 'unblock audit stores cleared reason');

    -- blocked rider keeps access to their account; login still works (F-016)
    v_c7 := bicycle_rental.block_rider(v_s1, v_r1, 'again');
    PERFORM pg_temp.assert_true((SELECT rider_status = 'blocked' FROM bicycle_rental.authenticate_account('ann@example.com', 'pw-ann')), 'blocked rider can authenticate');
    PERFORM pg_temp.assert_true((SELECT account_id = v_r1 FROM bicycle_rental.get_account(v_r1, v_r1)), 'blocked rider can read own account');
    PERFORM pg_temp.expect_error('42501', format('SELECT bicycle_rental.unblock_rider(%s, %s)', v_r1, v_r1), 'blocked rider cannot unblock themselves');

    -- ordering and filters (F-076)
    PERFORM pg_temp.assert_true((SELECT audit_id = max_id FROM bicycle_rental.list_audit_entries(v_s1) l,
       (SELECT max(audit_id) AS max_id FROM bicycle_rental.list_audit_entries(v_s1)) m LIMIT 1), 'audit log is returned newest first');
    PERFORM pg_temp.assert_true((SELECT count(*) = 0 FROM bicycle_rental.list_audit_entries(v_s1, NULL, NULL, NULL, NULL, now() + interval '1 day', NULL)), 'date filter with no matches returns empty');
    PERFORM pg_temp.assert_true((SELECT count(*) > 0 FROM bicycle_rental.list_audit_entries(v_s1, NULL, NULL, NULL, NULL, now() - interval '1 day', now() + interval '1 day')), 'date range filter');

    -- simulate COMMIT: deferred checks (subtype presence, >=1 audit detail per entry) must hold
    SET CONSTRAINTS ALL IMMEDIATE;
    SET CONSTRAINTS ALL DEFERRED;
    PERFORM pg_temp.assert_true((SELECT bool_and(c >= 1) FROM (SELECT count(d.*) c FROM bicycle_rental.audit_entry e
       JOIN bicycle_rental.audit_detail d USING (audit_id) GROUP BY e.audit_id) x), 'every entry has details');


END $test$;

SELECT '04_blocking_and_audit' AS section, count(*) AS assertions_passed FROM account_test_results;
ROLLBACK TO SAVEPOINT section;
SAVEPOINT section;

------  audit_integrity
DO $test$
DECLARE
    v_r1 bigint;
    v_s1 bigint;
    v_c boolean;
    v_e1 bigint;
    v_r2 bigint;
BEGIN
    -- Audit log integrity: append-only, atomic with the change, >=1 detail per entry.
    v_r1 := bicycle_rental.register_rider('Ann', 'Rider', 'ann@example.com', 'pw-ann');
    v_s1 := bicycle_rental.provision_staff('Sam', 'Staff', 'sam@example.com', 'pw-sam');
    v_c := bicycle_rental.block_rider(v_s1, v_r1, 'x');
    SELECT audit_id INTO v_e1 FROM bicycle_rental.audit_entry LIMIT 1;

    -- F-074 append-only
    PERFORM pg_temp.expect_error('P0001', 'UPDATE bicycle_rental.audit_entry SET action_type = ''rider_unblock''', 'audit entry cannot be updated');
    PERFORM pg_temp.expect_error('P0001', 'DELETE FROM bicycle_rental.audit_entry', 'audit entry cannot be deleted');
    PERFORM pg_temp.expect_error('P0001', 'UPDATE bicycle_rental.audit_detail SET new_value = NULL', 'audit detail cannot be updated');
    PERFORM pg_temp.expect_error('P0001', 'DELETE FROM bicycle_rental.audit_detail', 'audit detail cannot be deleted');

    -- F-070: the actor must be a staff account
    PERFORM pg_temp.expect_error('23503', format($q$INSERT INTO bicycle_rental.audit_entry (staff_id, action_type, primary_record_type, primary_record_id)
       VALUES (%s, 'rider_block', 'Rider', 1)$q$, v_r1), 'audit actor must be a staff account');

    -- detail number must be positive
    PERFORM pg_temp.expect_error('23514', format($q$INSERT INTO bicycle_rental.audit_detail (audit_id, detail_no, subject_record_type, subject_record_id, field_name)
       VALUES (%s, 0, 'Rider', 1, 'status')$q$, v_e1), 'detail number must be positive');
    PERFORM pg_temp.assert_true(NOT EXISTS (SELECT 1 FROM bicycle_rental.audit_detail WHERE new_value::text ~* 'pw-|\$2a\$' OR previous_value::text ~* 'pw-|\$2a\$'),
      'no password or hash content in stored audit details');

    -- F-117: entry without a detail is rejected at commit time
    PERFORM pg_temp.expect_error('P0001', format($q$INSERT INTO bicycle_rental.audit_entry (staff_id, action_type, primary_record_type, primary_record_id)
       VALUES (%s, 'rider_unblock', 'Rider', %s); SET CONSTRAINTS ALL IMMEDIATE$q$, v_s1, v_r1), 'audit entry without details rejected at commit time');
    PERFORM pg_temp.expect_error('P0001', format($q$SELECT bicycle_rental.record_audit_event(%s, 'rider_block', 'Rider', %s, '[]'::jsonb)$q$, v_s1, v_r1), 'record_audit_event refuses an empty detail list');

    -- F-075 atomicity: if the audit write fails, the change is not applied
    v_r2 := bicycle_rental.register_rider('Bob', 'Rider', 'bob@example.com', 'pw-bob');
    CREATE TRIGGER trg_test_boom BEFORE INSERT ON bicycle_rental.audit_detail FOR EACH ROW EXECUTE FUNCTION pg_temp.reject_audit_detail();
    PERFORM pg_temp.expect_error('XX001', format('SELECT bicycle_rental.block_rider(%s, %s, ''why'')', v_s1, v_r2), 'injected audit failure surfaces');
    DROP TRIGGER trg_test_boom ON bicycle_rental.audit_detail;
    PERFORM pg_temp.assert_true((SELECT status = 'active' FROM bicycle_rental.rider WHERE account_id = v_r2), 'failed audit write leaves the rider unchanged');
    PERFORM pg_temp.assert_true(NOT EXISTS (SELECT 1 FROM bicycle_rental.audit_entry WHERE primary_record_id = v_r2 AND action_type = 'rider_block'), 'failed change leaves no audit entry');


END $test$;

SELECT '05_audit_integrity' AS section, count(*) AS assertions_passed FROM account_test_results;
ROLLBACK TO SAVEPOINT section;
SAVEPOINT section;

ROLLBACK;

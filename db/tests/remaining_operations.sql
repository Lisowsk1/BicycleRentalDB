-- Remaining operations tests (V024):
--   01_tariffs:           get_active_tariffs (F-078, F-083) & configure_tariffs (F-079)
--   02_active_search:     search_active_rentals (F-107)
--   03_usage_statistics:  get_usage_statistics & get_station_pair_statistics (F-077, S-006)
--   04_retention_reset:   purge_expired_records (Section III) & reset_baseline (S-004)
--   05_role_privileges:   bicycle_app vs bicycle_setup & zero PUBLIC execution (V022/V023)
--
-- Run after all migrations with psql --set=ON_ERROR_STOP=1.
-- Wrapped in a transaction and rolled back so seed data remains intact.
BEGIN;
SET LOCAL search_path = bicycle_rental, public, pg_temp;

CREATE TEMP TABLE remaining_ops_results (description text NOT NULL);

CREATE FUNCTION pg_temp.assert_true(p_condition boolean, p_description text)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    IF p_condition IS DISTINCT FROM true THEN
        RAISE EXCEPTION 'FAIL: %', p_description;
    END IF;
    INSERT INTO remaining_ops_results VALUES (p_description);
END $$;

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
        INSERT INTO remaining_ops_results VALUES (p_description);
        RETURN;
    END;
    RAISE EXCEPTION 'FAIL: %; expected SQLSTATE %, but command succeeded', p_description, p_state;
END $$;

SAVEPOINT section;

------ 01_tariffs: active tariff lookup (F-078, F-083) & rotation (F-079)
DO $test$
DECLARE
    v_prefix text := 'tar-' || gen_random_uuid();
    v_staff  bigint;
    v_rider  bigint;
    v_st     bigint;
    v_bike   bigint;
    v_old_t  bigint;
    v_new_t  bigint;
    v_started bicycle_rental.rental_details;
BEGIN
    v_staff := bicycle_rental.provision_staff('Tar', 'Staff', v_prefix || '-s@test.invalid', 'StaffPass123!');
    v_rider := bicycle_rental.register_rider('Tar', 'Rider', v_prefix || '-r@test.invalid', 'RiderPass123!');
    v_st    := bicycle_rental.create_station(v_staff, v_prefix || ' St', 'Addr', 52.1, 21.1, true, true);
    v_bike  := bicycle_rental.create_bicycle(v_staff, v_prefix || '-B1', 'regular', 'serviceable', v_st);

    -- Validation & lookup
    PERFORM pg_temp.expect_error('42501', 'SELECT * FROM bicycle_rental.get_active_tariffs(NULL)', 'NULL actor rejected for tariff lookup');
    PERFORM pg_temp.expect_error('42501', 'SELECT * FROM bicycle_rental.get_active_tariffs(-1)',   'unknown actor rejected for tariff lookup');

    PERFORM pg_temp.assert_true(
        (SELECT count(*) = 2
            AND bool_and(currency = 'PLN' AND block_length_seconds = 900)
           FROM bicycle_rental.get_active_tariffs(v_rider)),
        'rider sees active regular and electric tariffs'
    );
    PERFORM pg_temp.assert_true(
        (SELECT count(*) = 2 FROM bicycle_rental.get_active_tariffs(v_staff)),
        'staff sees active tariffs'
    );

    SELECT tariff_id INTO v_old_t
      FROM bicycle_rental.get_active_tariffs(v_rider)
     WHERE bicycle_type = 'regular';

    -- Validation on configure_tariffs
    PERFORM pg_temp.expect_error('22023', 'SELECT * FROM bicycle_rental.configure_tariffs(-1.00, 900, 4.50, 900, ''EUR'')', 'negative regular price rejected');
    PERFORM pg_temp.expect_error('22023', 'SELECT * FROM bicycle_rental.configure_tariffs(2.50, 0, 4.50, 900, ''EUR'')', 'zero block length rejected');
    PERFORM pg_temp.expect_error('22023', 'SELECT * FROM bicycle_rental.configure_tariffs(2.50, 900, 4.50, 900, ''eur'')', 'lowercase currency code rejected');
    PERFORM pg_temp.expect_error('22023', 'SELECT * FROM bicycle_rental.configure_tariffs(2.50, 900, 4.50, 900, ''EURO'')', '4-letter currency code rejected');

    -- Rotate tariffs to EUR (including 0.00 free promotional pricing)
    PERFORM bicycle_rental.configure_tariffs(3.25, 600, 0.00, 600, 'EUR');

    PERFORM pg_temp.assert_true(
        (SELECT count(*) = 2
            AND bool_and(currency = 'EUR' AND block_length_seconds = 600)
            AND (SELECT price_per_block = 3.25 FROM bicycle_rental.get_active_tariffs(v_rider) WHERE bicycle_type = 'regular')
            AND (SELECT price_per_block = 0.00 FROM bicycle_rental.get_active_tariffs(v_rider) WHERE bicycle_type = 'electric')
           FROM bicycle_rental.get_active_tariffs(v_rider)),
        'configure_tariffs atomically activates new regular and electric terms'
    );
    PERFORM pg_temp.assert_true(
        (SELECT NOT is_active FROM bicycle_rental.tariff WHERE tariff_id = v_old_t),
        'previous tariff is deactivated but preserved'
    );

    -- Stale tariff ID is rejected by start_rental (F-083)
    PERFORM pg_temp.expect_error('22023', format('SELECT bicycle_rental.start_rental(%s, %s, %s)', v_rider, v_bike, v_old_t),
        'start_rental rejects stale tariff_id after tariff rotation');

    SELECT tariff_id INTO v_new_t
      FROM bicycle_rental.get_active_tariffs(v_rider)
     WHERE bicycle_type = 'regular';

    v_started := bicycle_rental.start_rental(v_rider, v_bike, v_new_t);
    PERFORM pg_temp.assert_true(
        v_started.currency = 'EUR'
        AND v_started.price_per_block = 3.25
        AND (SELECT rt.tariff_id = v_new_t FROM bicycle_rental.rental rt WHERE rt.rental_id = v_started.rental_id),
        'start_rental succeeds with current tariff_id and captures EUR terms'
    );
END $test$;

SELECT '01_tariffs' AS section, count(*) AS assertions_passed FROM remaining_ops_results;
ROLLBACK TO SAVEPOINT section;
SAVEPOINT section;

------ 02_active_search: staff active rental search (F-107)
DO $test$
DECLARE
    v_prefix text := 'srch-' || gen_random_uuid();
    v_staff  bigint;
    v_rider1 bigint;
    v_rider2 bigint;
    v_st_a   bigint;
    v_st_b   bigint;
    v_bike1  bigint;
    v_bike2  bigint;
    v_rent1  bigint;
    v_rent2  bigint;
BEGIN
    v_staff  := bicycle_rental.provision_staff('Srch', 'Staff', v_prefix || '-s@test.invalid', 'StaffPass123!');
    v_rider1 := bicycle_rental.register_rider('Srch', 'One',   v_prefix || '-r1@test.invalid', 'RiderPass123!');
    v_rider2 := bicycle_rental.register_rider('Srch', 'Two',   v_prefix || '-r2@test.invalid', 'RiderPass123!');
    v_st_a   := bicycle_rental.create_station(v_staff, v_prefix || ' A', 'Addr A', 52.1, 21.1, true, true);
    v_st_b   := bicycle_rental.create_station(v_staff, v_prefix || ' B', 'Addr B', 52.2, 21.2, true, true);
    v_bike1  := bicycle_rental.create_bicycle(v_staff, v_prefix || '-ALPHA', 'regular',  'serviceable', v_st_a);
    v_bike2  := bicycle_rental.create_bicycle(v_staff, v_prefix || '-BETA',  'electric', 'serviceable', v_st_b, 90);

    v_rent1 := (bicycle_rental.start_rental(v_rider1, v_bike1)).rental_id;
    v_rent2 := (bicycle_rental.start_rental(v_rider2, v_bike2)).rental_id;

    -- Access control
    PERFORM pg_temp.expect_error('42501', 'SELECT * FROM bicycle_rental.search_active_rentals(NULL)', 'NULL actor rejected');
    PERFORM pg_temp.expect_error('42501', format('SELECT * FROM bicycle_rental.search_active_rentals(%s)', v_rider1), 'rider cannot search active rentals');

    -- Search by rental_id, rider_id, bicycle_id, and case-insensitive/trimmed bicycle_identifier
    PERFORM pg_temp.assert_true(
        (SELECT count(*) = 1 AND bool_and(rental_id = v_rent1 AND rider_email = v_prefix || '-r1@test.invalid' AND pickup_station_name = v_prefix || ' A')
           FROM bicycle_rental.search_active_rentals(v_staff, p_rental_id => v_rent1)),
        'search by rental_id returns matching active rental with rider and station details'
    );
    PERFORM pg_temp.assert_true(
        (SELECT count(*) = 1 AND bool_and(rental_id = v_rent2 AND bicycle_type = 'electric')
           FROM bicycle_rental.search_active_rentals(v_staff, p_rider_id => v_rider2)),
        'search by rider_id returns that rider''s active rental'
    );
    PERFORM pg_temp.assert_true(
        (SELECT count(*) = 1 AND bool_and(rental_id = v_rent1)
           FROM bicycle_rental.search_active_rentals(v_staff, p_bicycle_id => v_bike1)),
        'search by bicycle_id returns active rental on that bicycle'
    );
    PERFORM pg_temp.assert_true(
        (SELECT count(*) = 1 AND bool_and(rental_id = v_rent2)
           FROM bicycle_rental.search_active_rentals(v_staff, p_bicycle_identifier => '  ' || lower(v_prefix || '-beta') || '  ')),
        'search by bicycle_identifier trims and ignores case'
    );
    PERFORM pg_temp.assert_true(
        (SELECT count(*) = 0
           FROM bicycle_rental.search_active_rentals(v_staff, p_rider_id => v_rider1, p_bicycle_id => v_bike2)),
        'conflicting filter combination returns empty result'
    );

    -- Completing a rental removes it from active search
    PERFORM bicycle_rental.staff_return_rental(v_staff, v_rent1, v_st_b);
    PERFORM pg_temp.assert_true(
        (SELECT count(*) = 0 FROM bicycle_rental.search_active_rentals(v_staff, p_rental_id => v_rent1)),
        'staff-returned rental no longer appears in search_active_rentals'
    );
END $test$;

SELECT '02_active_search' AS section, count(*) AS assertions_passed FROM remaining_ops_results;
ROLLBACK TO SAVEPOINT section;
SAVEPOINT section;

------ 03_usage_statistics: summary & station pairs (F-077, S-006)
DO $test$
DECLARE
    v_prefix text := 'stat-' || gen_random_uuid();
    v_staff  bigint;
    v_rider  bigint;
    v_st1    bigint;
    v_st2    bigint;
    v_st3    bigint;
    v_bike   bigint;
    v_active bigint;
BEGIN
    -- Start from empty baseline to verify S-006 empty-dataset semantics
    PERFORM bicycle_rental.reset_baseline();
    PERFORM bicycle_rental.configure_tariffs(2.50, 900, 4.50, 900, 'PLN');

    v_staff := bicycle_rental.provision_staff('Stat', 'Staff', v_prefix || '-s@test.invalid', 'StaffPass123!');
    v_rider := bicycle_rental.register_rider('Stat', 'Rider', v_prefix || '-r@test.invalid', 'RiderPass123!');

    PERFORM pg_temp.expect_error('42501', format('SELECT * FROM bicycle_rental.get_usage_statistics(%s)', v_rider),
        'rider cannot access usage statistics');
    PERFORM pg_temp.expect_error('42501', format('SELECT * FROM bicycle_rental.get_station_pair_statistics(%s)', v_rider),
        'rider cannot access station pair statistics');

    PERFORM pg_temp.assert_true(
        (SELECT completed_count = 0 AND total_duration_seconds = 0 AND average_duration_seconds IS NULL
           FROM bicycle_rental.get_usage_statistics(v_staff)),
        'S-006: zero completed rentals returns count=0, total=0, average=NULL'
    );
    PERFORM pg_temp.assert_true(
        (SELECT count(*) = 0 FROM bicycle_rental.get_station_pair_statistics(v_staff)),
        'S-006: zero completed rentals returns empty station pair list'
    );

    v_st1  := bicycle_rental.create_station(v_staff, v_prefix || ' S1', 'Addr 1', 52.1, 21.1, true, true);
    v_st2  := bicycle_rental.create_station(v_staff, v_prefix || ' S2', 'Addr 2', 52.2, 21.2, true, true);
    v_st3  := bicycle_rental.create_station(v_staff, v_prefix || ' S3', 'Addr 3', 52.3, 21.3, true, true);
    v_bike := bicycle_rental.create_bicycle(v_staff, v_prefix || '-B1', 'regular', 'serviceable', v_st1);

    -- Active rental must NOT be counted in usage statistics
    v_active := (bicycle_rental.start_rental(v_rider, v_bike)).rental_id;
    PERFORM pg_temp.assert_true(
        (SELECT completed_count = 0 AND average_duration_seconds IS NULL FROM bicycle_rental.get_usage_statistics(v_staff)),
        'active rentals are excluded from usage statistics'
    );
    PERFORM bicycle_rental.return_rental(v_rider, v_active, v_st1);

    -- Remove the 0-second test return and insert 4 deterministic completed rentals:
    -- Durations: 10s, 10s, 11s, 11s -> total = 42s, exact avg = 10.5s -> half-up rounded = 11s
    -- Station pairs:
    --   (st2 -> st1): 2 rentals (highest count -> first)
    --   (st1 -> st2): 1 rental  (tie on count=1, smaller pickup_station_id -> second)
    --   (st1 -> st3): 1 rental  (tie on count=1, same pickup, larger return_station_id -> third)
    PERFORM set_config('bicycle_rental.privileged_setup', 'true', true);
    DELETE FROM bicycle_rental.rental;
    PERFORM set_config('bicycle_rental.privileged_setup', 'false', true);

    INSERT INTO bicycle_rental.rental (
        rider_id, bicycle_id, pickup_station_id, return_station_id, tariff_id,
        start_time, end_time, captured_price_per_block, captured_block_length_seconds,
        captured_currency, final_charge, bicycle_type
    )
    SELECT v_rider, v_bike, p_from, p_to, t.tariff_id,
           '2026-02-01 10:00:00+00'::timestamptz, '2026-02-01 10:00:00+00'::timestamptz + make_interval(secs => p_dur),
           t.price_per_block, t.block_length_seconds, t.currency, 2.50, 'regular'
      FROM bicycle_rental.tariff t,
           (VALUES
               (v_st2, v_st1, 10),
               (v_st2, v_st1, 10),
               (v_st1, v_st2, 11),
               (v_st1, v_st3, 11)
           ) AS rows(p_from, p_to, p_dur)
     WHERE t.is_active AND t.bicycle_type = 'regular';

    PERFORM pg_temp.assert_true(
        (SELECT completed_count = 4 AND total_duration_seconds = 42 AND average_duration_seconds = 11
           FROM bicycle_rental.get_usage_statistics(v_staff)),
        'usage statistics computes exact count, total duration, and half-up rounded average'
    );

    PERFORM pg_temp.assert_true(
        (SELECT array_agg(ARRAY[pickup_station_id, return_station_id, completed_count] ORDER BY rn)
                = ARRAY[
                    ARRAY[v_st2, v_st1, 2::bigint],
                    ARRAY[v_st1, v_st2, 1::bigint],
                    ARRAY[v_st1, v_st3, 1::bigint]
                ]
           FROM (
               SELECT pickup_station_id, return_station_id, completed_count, row_number() OVER () AS rn
                 FROM bicycle_rental.get_station_pair_statistics(v_staff)
           ) ordered),
        'station pair statistics orders by count DESC, pickup_station_id ASC, return_station_id ASC'
    );
END $test$;

SELECT '03_usage_statistics' AS section, count(*) AS assertions_passed FROM remaining_ops_results;
ROLLBACK TO SAVEPOINT section;
SAVEPOINT section;

------ 04_retention_reset: 36-month purge (Section III) & reset_baseline (S-004)
DO $test$
DECLARE
    v_prefix  text := 'ret-' || gen_random_uuid();
    v_staff   bigint;
    v_rider   bigint;
    v_st1     bigint;
    v_st2     bigint;
    v_bike    bigint;
    v_old_r   bigint;
    v_recent  bigint;
    v_open_fr bigint;
    v_closed_fr bigint;
    v_old_tr  bigint;
BEGIN
    v_staff := bicycle_rental.provision_staff('Ret', 'Staff', v_prefix || '-s@test.invalid', 'StaffPass123!');
    v_rider := bicycle_rental.register_rider('Ret', 'Rider', v_prefix || '-r@test.invalid', 'RiderPass123!');
    v_st1   := bicycle_rental.create_station(v_staff, v_prefix || ' S1', 'Addr 1', 52.1, 21.1, true, true);
    v_st2   := bicycle_rental.create_station(v_staff, v_prefix || ' S2', 'Addr 2', 52.2, 21.2, true, true);
    v_bike  := bicycle_rental.create_bicycle(v_staff, v_prefix || '-B1', 'regular', 'serviceable', v_st1);

    PERFORM pg_temp.expect_error('22023', 'SELECT * FROM bicycle_rental.purge_expired_records(NULL)',
        'purge_expired_records rejects NULL p_as_of');

    -- Insert an old completed rental (40 months before 2026-11-25) and a recent one (2 months before)
    INSERT INTO bicycle_rental.rental (
        rider_id, bicycle_id, pickup_station_id, return_station_id, tariff_id,
        start_time, end_time, captured_price_per_block, captured_block_length_seconds,
        captured_currency, final_charge, bicycle_type
    )
    SELECT v_rider, v_bike, v_st1, v_st2, t.tariff_id,
           '2023-06-01 10:00:00+00', '2023-06-01 10:15:00+00',
           t.price_per_block, t.block_length_seconds, t.currency, 2.50, 'regular'
      FROM bicycle_rental.tariff t WHERE t.is_active AND t.bicycle_type = 'regular'
    RETURNING rental_id INTO v_old_r;

    INSERT INTO bicycle_rental.rental (
        rider_id, bicycle_id, pickup_station_id, return_station_id, tariff_id,
        start_time, end_time, captured_price_per_block, captured_block_length_seconds,
        captured_currency, final_charge, bicycle_type
    )
    SELECT v_rider, v_bike, v_st1, v_st2, t.tariff_id,
           '2026-09-01 10:00:00+00', '2026-09-01 10:15:00+00',
           t.price_per_block, t.block_length_seconds, t.currency, 2.50, 'regular'
      FROM bicycle_rental.tariff t WHERE t.is_active AND t.bicycle_type = 'regular'
    RETURNING rental_id INTO v_recent;

    -- Insert an old transfer (40 months old)
    INSERT INTO bicycle_rental.bicycle_transfer (bicycle_id, from_station_id, to_station_id, performed_by_staff_id, transferred_at)
    VALUES (v_bike, v_st1, v_st2, v_staff, '2023-06-01 12:00:00+00')
    RETURNING transfer_id INTO v_old_tr;

    -- Insert two old fault reports in 'open' state (as required by trg_fault_report_before_insert),
    -- then transition one to 'resolved' while leaving the other 'open'.
    INSERT INTO bicycle_rental.fault_report (bicycle_id, reported_by_account_id, category, severity, description, status, reported_at)
    VALUES
        (v_bike, v_rider, 'brakes', 'minor', 'Old resolved',   'open', '2023-06-01 09:00:00+00'),
        (v_bike, v_rider, 'tyres',  'major', 'Old still open', 'open', '2023-06-01 09:00:00+00');

    SELECT report_id INTO v_closed_fr FROM bicycle_rental.fault_report WHERE description = 'Old resolved';
    SELECT report_id INTO v_open_fr   FROM bicycle_rental.fault_report WHERE description = 'Old still open';

    UPDATE bicycle_rental.fault_report
       SET status      = 'resolved',
           resolved_at = '2023-06-02 09:00:00+00'
     WHERE report_id = v_closed_fr;

    PERFORM bicycle_rental.purge_expired_records('2026-11-25 00:00:00+00');

    PERFORM pg_temp.assert_true(
        NOT EXISTS (SELECT 1 FROM bicycle_rental.rental WHERE rental_id = v_old_r)
        AND EXISTS (SELECT 1 FROM bicycle_rental.rental WHERE rental_id = v_recent),
        'purge deletes expired completed rentals and retains recent ones'
    );
    PERFORM pg_temp.assert_true(
        NOT EXISTS (SELECT 1 FROM bicycle_rental.bicycle_transfer WHERE transfer_id = v_old_tr),
        'purge deletes expired bicycle transfers'
    );
    PERFORM pg_temp.assert_true(
        NOT EXISTS (SELECT 1 FROM bicycle_rental.fault_report WHERE report_id = v_closed_fr)
        AND EXISTS (SELECT 1 FROM bicycle_rental.fault_report WHERE report_id = v_open_fr),
        'purge deletes expired resolved fault reports but preserves open fault reports'
    );

    -- reset_baseline clears all tables and resets identities
    PERFORM bicycle_rental.reset_baseline();
    PERFORM pg_temp.assert_true(
        (SELECT count(*) = 0 FROM bicycle_rental.account)
        AND (SELECT count(*) = 0 FROM bicycle_rental.tariff)
        AND (SELECT count(*) = 0 FROM bicycle_rental.station)
        AND (SELECT count(*) = 0 FROM bicycle_rental.bicycle)
        AND (SELECT count(*) = 0 FROM bicycle_rental.rental)
        AND (SELECT count(*) = 0 FROM bicycle_rental.audit_entry),
        'reset_baseline clears all operational and baseline tables'
    );
END $test$;

SELECT '04_retention_reset' AS section, count(*) AS assertions_passed FROM remaining_ops_results;
ROLLBACK TO SAVEPOINT section;
SAVEPOINT section;

------ 05_role_privileges: bicycle_app vs bicycle_setup & zero PUBLIC routines
DO $test$
DECLARE
    v_app_role   text := 'rem_app_' || replace(gen_random_uuid()::text, '-', '');
    v_setup_role text := 'rem_setup_' || replace(gen_random_uuid()::text, '-', '');
    v_orig_user  text := session_user;
    v_denied     boolean;
BEGIN
    PERFORM pg_temp.assert_true(
        NOT EXISTS (
            SELECT 1 FROM pg_proc p
            WHERE p.pronamespace = 'bicycle_rental'::regnamespace
              AND has_function_privilege('public', p.oid, 'EXECUTE')
        ),
        'no routine in bicycle_rental is executable by PUBLIC'
    );

    IF (SELECT rolsuper FROM pg_catalog.pg_roles WHERE rolname = session_user) THEN
        EXECUTE format('CREATE ROLE %I', v_app_role);
        EXECUTE format('GRANT bicycle_app TO %I', v_app_role);
        EXECUTE format('CREATE ROLE %I', v_setup_role);
        EXECUTE format('GRANT bicycle_setup TO %I', v_setup_role);

        -- bicycle_app CANNOT call bicycle_setup functions
        EXECUTE format('SET SESSION AUTHORIZATION %I', v_app_role);
        v_denied := false;
        BEGIN
            PERFORM bicycle_rental.reset_baseline();
        EXCEPTION WHEN insufficient_privilege THEN
            v_denied := true;
        END;
        EXECUTE format('SET SESSION AUTHORIZATION %I', v_orig_user);
        PERFORM pg_temp.assert_true(v_denied, 'bicycle_app cannot execute reset_baseline');

        EXECUTE format('SET SESSION AUTHORIZATION %I', v_app_role);
        v_denied := false;
        BEGIN
            PERFORM bicycle_rental.configure_tariffs(2.50, 900, 4.50, 900, 'PLN');
        EXCEPTION WHEN insufficient_privilege THEN
            v_denied := true;
        END;
        EXECUTE format('SET SESSION AUTHORIZATION %I', v_orig_user);
        PERFORM pg_temp.assert_true(v_denied, 'bicycle_app cannot execute configure_tariffs');

        EXECUTE format('SET SESSION AUTHORIZATION %I', v_app_role);
        v_denied := false;
        BEGIN
            PERFORM bicycle_rental.purge_expired_records();
        EXCEPTION WHEN insufficient_privilege THEN
            v_denied := true;
        END;
        EXECUTE format('SET SESSION AUTHORIZATION %I', v_orig_user);
        PERFORM pg_temp.assert_true(v_denied, 'bicycle_app cannot execute purge_expired_records');

        -- bicycle_setup CAN call configure_tariffs, purge_expired_records, and reset_baseline
        EXECUTE format('SET SESSION AUTHORIZATION %I', v_setup_role);
        PERFORM bicycle_rental.configure_tariffs(2.50, 900, 4.50, 900, 'PLN');
        PERFORM bicycle_rental.purge_expired_records('2020-01-01 00:00:00+00');
        PERFORM bicycle_rental.reset_baseline();
        EXECUTE format('SET SESSION AUTHORIZATION %I', v_orig_user);
        PERFORM pg_temp.assert_true(true, 'bicycle_setup can execute configure_tariffs, purge_expired_records, and reset_baseline');
    END IF;
END $test$;

SELECT '05_role_privileges' AS section, count(*) AS assertions_passed FROM remaining_ops_results;
ROLLBACK TO SAVEPOINT section;

ROLLBACK;
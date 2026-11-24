-- Bicycle movement tests: station transfers, maintenance handover and return, eligibility, rollbacks,
-- immutable transfer records, audit counts and movement history queries.
-- Run after all migrations with psql --set=ON_ERROR_STOP=1. Needs a superuser or the table owner
-- (it reads catalog state and runs direct DML on protected tables).
-- All fixtures, helper functions and test-only triggers are rolled back.
-- Competing sessions are covered by db/tests/bicycle_movement_concurrency.sh.
BEGIN;
SET LOCAL search_path = bicycle_rental, public, pg_temp;

CREATE TEMP TABLE movement_test_results (description text NOT NULL);

CREATE FUNCTION pg_temp.assert_true(p_condition boolean, p_description text)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    IF p_condition IS DISTINCT FROM true THEN
        RAISE EXCEPTION 'FAIL: %', p_description;
    END IF;
    INSERT INTO movement_test_results VALUES (p_description);
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
        INSERT INTO movement_test_results VALUES (p_description);
        RETURN;
    END;
    RAISE EXCEPTION 'FAIL: %; expected SQLSTATE %, but command succeeded', p_description, p_state;
END $$;

-- One-line description of where a bicycle is and in which state.
CREATE FUNCTION pg_temp.snap(p_bicycle bigint) RETURNS text LANGUAGE sql AS $$
    SELECT placement || ':' || coalesce(current_station_id, 0) || ':' || coalesce(current_provider_id, 0)
           || ':' || maintenance_state
      FROM bicycle_rental.bicycle WHERE bicycle_id = p_bicycle
$$;

CREATE FUNCTION pg_temp.reject_bicycle_update() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN RAISE EXCEPTION 'injected bicycle failure'; END $$;
CREATE FUNCTION pg_temp.reject_transfer_insert() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN RAISE EXCEPTION 'injected transfer record failure'; END $$;
CREATE FUNCTION pg_temp.reject_audit() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN RAISE EXCEPTION 'injected audit failure'; END $$;

DO $$
DECLARE
    v_prefix   text := 'move-' || gen_random_uuid();
    v_staff    bigint; v_rider bigint;
    v_a        bigint; v_b bigint; v_c bigint;
    v_provider bigint; v_inactive bigint;
    v_bike     bigint; v_broken bigint; v_low bigint; v_rented bigint; v_other bigint; v_never bigint;
    v_rental   bigint;
    v_t1       bicycle_transfer; v_t2 bicycle_transfer; v_t3 bicycle_transfer; v_t4 bicycle_transfer;
    v_count    bigint; v_audits bigint; v_audit bigint; v_snap text;
BEGIN
    INSERT INTO account (first_name, last_name, email, password_hash, role)
    VALUES ('Move', 'Staff', 'move-staff-' || gen_random_uuid() || '@test.invalid', '$2a$12$' || repeat('x', 53), 'staff')
    RETURNING account_id INTO v_staff;
    INSERT INTO staff (account_id) VALUES (v_staff);
    INSERT INTO account (first_name, last_name, email, password_hash, role)
    VALUES ('Move', 'Rider', 'move-rider-' || gen_random_uuid() || '@test.invalid', '$2a$12$' || repeat('x', 53), 'rider')
    RETURNING account_id INTO v_rider;
    INSERT INTO rider (account_id) VALUES (v_rider);

    v_a := create_station(v_staff, v_prefix || ' A', 'Street', 52, 21, true, true);
    v_b := create_station(v_staff, v_prefix || ' B', 'Street', 52, 21, true, true);
    v_c := create_station(v_staff, v_prefix || ' C', 'Street', 52, 21, false, false);   -- both rider controls off
    v_provider := create_maintenance_provider(v_staff, v_prefix || ' Workshop');
    v_inactive := create_maintenance_provider(v_staff, v_prefix || ' Closed');
    PERFORM set_maintenance_provider_active(v_staff, v_inactive, false);

    v_bike   := create_bicycle(v_staff, v_prefix || '-1', 'regular',  'serviceable', v_a);
    v_broken := create_bicycle(v_staff, v_prefix || '-2', 'regular',  'unavailable_for_maintenance', v_a);
    v_low    := create_bicycle(v_staff, v_prefix || '-3', 'electric', 'serviceable', v_a, 10);
    v_rented := create_bicycle(v_staff, v_prefix || '-4', 'regular',  'serviceable', v_a);
    v_other  := create_bicycle(v_staff, v_prefix || '-5', 'regular',  'serviceable', v_a);
    v_never  := create_bicycle(v_staff, v_prefix || '-6', 'regular',  'serviceable', v_a);

    SELECT count(*) INTO v_audits FROM audit_entry;

    ---------------------------------------------------------------- station transfer (F-027, F-092, F-093)
    v_t1 := transfer_bicycle(v_staff, v_bike, v_a, v_b, '  Rebalance  ');
    PERFORM pg_temp.assert_true(v_t1.bicycle_id = v_bike AND v_t1.from_station_id = v_a AND v_t1.to_station_id = v_b
        AND v_t1.performed_by_staff_id = v_staff AND v_t1.reason = 'Rebalance'
        AND v_t1.transferred_at <= clock_timestamp() AND v_t1.transferred_at > clock_timestamp() - interval '1 minute',
        'transfer record keeps bicycle, stations, acting staff, server timestamp and trimmed reason');
    PERFORM pg_temp.assert_true(pg_temp.snap(v_bike) = 'station:' || v_b || ':0:serviceable', 'transfer moves the bicycle and keeps its maintenance state');
    PERFORM pg_temp.assert_true((SELECT count(*) = 1 FROM bicycle_transfer WHERE bicycle_id = v_bike), 'one record per successful transfer');
    PERFORM pg_temp.assert_true((SELECT count(*) = v_audits FROM audit_entry), 'station transfers add no audit entry (F-071)');

    -- Rider station controls and maintenance state do not restrict staff transfers.
    PERFORM transfer_bicycle(v_staff, v_broken, v_a, v_c);
    PERFORM pg_temp.assert_true(pg_temp.snap(v_broken) = 'station:' || v_c || ':0:unavailable_for_maintenance', 'transfer into a station with controls off works and keeps unavailable state');
    PERFORM transfer_bicycle(v_staff, v_low, v_a, v_c);
    PERFORM transfer_bicycle(v_staff, v_low, v_c, v_a);
    PERFORM pg_temp.assert_true(pg_temp.snap(v_low) = 'station:' || v_a || ':0:serviceable', 'transfer out of a station with controls off works for a low-battery bicycle');

    ---------------------------------------------------------------- rejected transfers change nothing
    SELECT count(*) INTO v_count FROM bicycle_transfer;
    v_snap := pg_temp.snap(v_bike);
    PERFORM pg_temp.expect_error('42501', format('SELECT transfer_bicycle(%s, %s, %s, %s)', v_rider, v_bike, v_b, v_a), 'riders cannot transfer bicycles');
    PERFORM pg_temp.expect_error('42501', format('SELECT transfer_bicycle(NULL, %s, %s, %s)', v_bike, v_b, v_a), 'a transfer needs an acting account');
    PERFORM pg_temp.expect_error('22023', format('SELECT transfer_bicycle(%s, NULL, %s, %s)', v_staff, v_b, v_a), 'a transfer needs a bicycle');
    PERFORM pg_temp.expect_error('22023', format('SELECT transfer_bicycle(%s, %s, NULL, %s)', v_staff, v_bike, v_a), 'a transfer needs a source station');
    PERFORM pg_temp.expect_error('22023', format('SELECT transfer_bicycle(%s, %s, %s, NULL)', v_staff, v_bike, v_b), 'a transfer needs a destination station');
    PERFORM pg_temp.expect_error('22023', format('SELECT transfer_bicycle(%s, %s, %s, %s)', v_staff, v_bike, v_b, v_b), 'same-station transfer is rejected');
    PERFORM pg_temp.expect_error('22023', format('SELECT transfer_bicycle(%s, %s, %s, -1)', v_staff, v_bike, v_b), 'unknown destination is rejected');
    PERFORM pg_temp.expect_error('P0002', format('SELECT transfer_bicycle(%s, -1, %s, %s)', v_staff, v_a, v_b), 'unknown bicycle is rejected');
    PERFORM pg_temp.expect_error('55000', format('SELECT transfer_bicycle(%s, %s, %s, %s)', v_staff, v_bike, v_a, v_c), 'wrong source station is rejected');
    PERFORM pg_temp.expect_error('55000', format('SELECT transfer_bicycle(%s, %s, %s, %s)', v_staff, v_bike, v_a, v_b), 'repeating a finished transfer is rejected');
    PERFORM pg_temp.expect_error('22023', format('SELECT transfer_bicycle(%s, %s, %s, %s, %L)', v_staff, v_bike, v_b, v_a, repeat('x', 501)), 'over-long reason is rejected');
    PERFORM pg_temp.assert_true((SELECT count(*) = v_count FROM bicycle_transfer) AND pg_temp.snap(v_bike) = v_snap, 'rejected transfers leave no record and no change');

    ---------------------------------------------------------------- direct writes are guarded (ERD constraints)
    PERFORM pg_temp.expect_error('23514', format('INSERT INTO bicycle_transfer (bicycle_id, from_station_id, to_station_id, performed_by_staff_id) VALUES (%s, %s, %s, %s)', v_bike, v_a, v_c, v_staff),
        'direct insert with a source that is not the current station is rejected');
    PERFORM pg_temp.expect_error('23514', format('INSERT INTO bicycle_transfer (bicycle_id, from_station_id, to_station_id, performed_by_staff_id) VALUES (%s, %s, %s, %s)', v_bike, v_b, v_b, v_staff),
        'direct insert with equal stations is rejected');
    PERFORM pg_temp.expect_error('23000', format('UPDATE bicycle_transfer SET reason = ''edited'' WHERE transfer_id = %s', v_t1.transfer_id), 'transfer records cannot be updated');
    PERFORM pg_temp.expect_error('23000', format('UPDATE bicycle_transfer SET to_station_id = %s WHERE transfer_id = %s', v_c, v_t1.transfer_id), 'transfer stations cannot be rewritten');
    PERFORM pg_temp.expect_error('23000', format('DELETE FROM bicycle_transfer WHERE transfer_id = %s', v_t1.transfer_id), 'transfer records cannot be deleted');
    PERFORM pg_temp.expect_error('P0001', format('DELETE FROM station WHERE station_id = %s', v_a), 'a station referenced by history cannot be deleted');
    PERFORM pg_temp.expect_error('P0001', format('DELETE FROM bicycle WHERE bicycle_id = %s', v_bike), 'a bicycle referenced by history cannot be deleted');
    PERFORM pg_temp.expect_error('23000', format('DELETE FROM staff WHERE account_id = %s', v_staff), 'staff referenced by history cannot be deleted');
    PERFORM pg_temp.assert_true((SELECT t = v_t1 FROM bicycle_transfer t WHERE t.transfer_id = v_t1.transfer_id), 'the stored record is unchanged by all of the above');

    ---------------------------------------------------------------- failed transactions leave no partial movement (R-004)
    CREATE TRIGGER zz_inject_bicycle_failure BEFORE UPDATE ON bicycle FOR EACH ROW EXECUTE FUNCTION pg_temp.reject_bicycle_update();
    PERFORM pg_temp.expect_error('P0001', format('SELECT transfer_bicycle(%s, %s, %s, %s)', v_staff, v_bike, v_b, v_a), 'injected bicycle failure aborts transfer');
    DROP TRIGGER zz_inject_bicycle_failure ON bicycle;
    CREATE TRIGGER zz_inject_transfer_failure AFTER INSERT ON bicycle_transfer FOR EACH ROW EXECUTE FUNCTION pg_temp.reject_transfer_insert();
    PERFORM pg_temp.expect_error('P0001', format('SELECT transfer_bicycle(%s, %s, %s, %s)', v_staff, v_bike, v_b, v_a), 'injected record failure aborts transfer');
    DROP TRIGGER zz_inject_transfer_failure ON bicycle_transfer;
    PERFORM pg_temp.assert_true((SELECT count(*) = v_count FROM bicycle_transfer) AND pg_temp.snap(v_bike) = v_snap, 'failed transfers leave neither the record nor the new station');

    ---------------------------------------------------------------- rentals and movements (F-024, F-025, R-005)
    v_rental := (start_rental(v_rider, v_rented)).rental_id;
    v_snap := pg_temp.snap(v_rented);
    PERFORM pg_temp.expect_error('55000', format('SELECT transfer_bicycle(%s, %s, %s, %s)', v_staff, v_rented, v_a, v_b), 'a bicycle on an active rental cannot be transferred');
    PERFORM pg_temp.expect_error('22023', format('SELECT handover_to_maintenance(%s, %s, %s)', v_staff, v_rented, v_provider), 'a bicycle on an active rental cannot be handed over');
    PERFORM pg_temp.assert_true(pg_temp.snap(v_rented) = v_snap AND (SELECT count(*) = v_audits FROM audit_entry), 'rejected movements of a rented bicycle change nothing and write no audit');
    PERFORM return_rental(v_rider, v_rental, v_b);
    PERFORM transfer_bicycle(v_staff, v_rented, v_b, v_c);
    PERFORM pg_temp.assert_true((SELECT pickup_station_id = v_a AND return_station_id = v_b AND end_time IS NOT NULL FROM rental WHERE rental_id = v_rental),
        'later movements do not change an earlier rental''s stations');
    -- A transfer first makes the next rental's pickup station the new station.
    PERFORM transfer_bicycle(v_staff, v_other, v_a, v_b);
    PERFORM pg_temp.assert_true((SELECT pickup_station_id = v_b FROM start_rental(v_rider, v_other)), 'a rental after a transfer picks up at the new station');
    PERFORM return_rental(v_rider, (SELECT rental_id FROM get_active_rental(v_rider)), v_a);

    ---------------------------------------------------------------- further transfers for the history
    v_t2 := transfer_bicycle(v_staff, v_bike, v_b, v_c, '   ');
    PERFORM pg_temp.assert_true(v_t2.reason IS NULL, 'blank reason is stored as absent');
    v_t3 := transfer_bicycle(v_staff, v_bike, v_c, v_a, 'Back');

    ---------------------------------------------------------------- maintenance handover (F-029, F-094)
    PERFORM pg_temp.expect_error('42501', format('SELECT handover_to_maintenance(%s, %s, %s)', v_rider, v_bike, v_provider), 'riders cannot hand over bicycles');
    PERFORM pg_temp.expect_error('22023', format('SELECT handover_to_maintenance(%s, %s, %s)', v_staff, v_bike, v_inactive), 'inactive provider rejects handover');
    PERFORM pg_temp.expect_error('22023', format('SELECT handover_to_maintenance(%s, %s, -1)', v_staff, v_bike), 'unknown provider rejects handover');
    PERFORM pg_temp.expect_error('P0002', format('SELECT handover_to_maintenance(%s, -1, %s)', v_staff, v_provider), 'unknown bicycle rejects handover');
    SELECT count(*) INTO v_audits FROM audit_entry;
    v_snap := pg_temp.snap(v_bike);
    CREATE TRIGGER zz_inject_audit_failure BEFORE INSERT ON audit_entry FOR EACH ROW EXECUTE FUNCTION pg_temp.reject_audit();
    PERFORM pg_temp.expect_error('P0001', format('SELECT handover_to_maintenance(%s, %s, %s)', v_staff, v_bike, v_provider), 'audit failure aborts handover');
    DROP TRIGGER zz_inject_audit_failure ON audit_entry;
    PERFORM pg_temp.assert_true(pg_temp.snap(v_bike) = v_snap AND (SELECT count(*) = v_audits FROM audit_entry), 'failed handover leaves placement and audit unchanged');

    PERFORM handover_to_maintenance(v_staff, v_bike, v_provider);
    PERFORM pg_temp.assert_true(pg_temp.snap(v_bike) = 'maintenance_provider:0:' || v_provider || ':unavailable_for_maintenance', 'handover clears the station, sets the provider and marks the bicycle unavailable');
    SELECT max(audit_id) INTO v_audit FROM audit_entry WHERE primary_record_type = 'Bicycle' AND primary_record_id = v_bike AND action_type = 'maintenance_handover';
    PERFORM pg_temp.assert_true((SELECT count(*) = v_audits + 1 FROM audit_entry) AND (SELECT count(*) = 4 FROM audit_detail WHERE audit_id = v_audit), 'handover writes one audit entry with four details');
    PERFORM handover_to_maintenance(v_staff, v_broken, v_provider);   -- source station has both controls off
    PERFORM pg_temp.assert_true((SELECT placement = 'maintenance_provider' FROM bicycle WHERE bicycle_id = v_broken), 'station controls do not restrict handover');
    SELECT count(*) INTO v_audits FROM audit_entry;
    PERFORM pg_temp.expect_error('22023', format('SELECT handover_to_maintenance(%s, %s, %s)', v_staff, v_bike, v_provider), 'repeated handover is rejected');
    PERFORM pg_temp.expect_error('55000', format('SELECT transfer_bicycle(%s, %s, %s, %s)', v_staff, v_bike, v_a, v_b), 'a bicycle with the provider cannot be transferred');
    PERFORM pg_temp.expect_error('23514', format('INSERT INTO bicycle_transfer (bicycle_id, from_station_id, to_station_id, performed_by_staff_id) VALUES (%s, %s, %s, %s)', v_bike, v_a, v_b, v_staff),
        'direct transfer record for a provider-held bicycle is rejected');
    PERFORM pg_temp.assert_true((SELECT count(*) = v_audits FROM audit_entry), 'rejected movements of a provider-held bicycle write no audit');

    ---------------------------------------------------------------- return from maintenance (F-030, F-095)
    PERFORM pg_temp.expect_error('42501', format('SELECT return_from_maintenance(%s, %s, %s, ''serviceable'')', v_rider, v_bike, v_b), 'riders cannot return bicycles from maintenance');
    PERFORM pg_temp.expect_error('22023', format('SELECT return_from_maintenance(%s, %s, %s, NULL)', v_staff, v_bike, v_b), 'maintenance return requires an explicit state');
    PERFORM pg_temp.expect_error('22023', format('SELECT return_from_maintenance(%s, %s, -1, ''serviceable'')', v_staff, v_bike), 'maintenance return rejects an unknown station');
    PERFORM pg_temp.expect_error('22023', format('SELECT return_from_maintenance(%s, %s, %s, ''serviceable'')', v_staff, v_never, v_b), 'a station bicycle cannot be returned from maintenance');
    CREATE TRIGGER zz_inject_audit_failure BEFORE INSERT ON audit_entry FOR EACH ROW EXECUTE FUNCTION pg_temp.reject_audit();
    PERFORM pg_temp.expect_error('P0001', format('SELECT return_from_maintenance(%s, %s, %s, ''serviceable'')', v_staff, v_bike, v_b), 'audit failure aborts maintenance return');
    DROP TRIGGER zz_inject_audit_failure ON audit_entry;
    PERFORM pg_temp.assert_true(pg_temp.snap(v_bike) = 'maintenance_provider:0:' || v_provider || ':unavailable_for_maintenance' AND (SELECT count(*) = v_audits FROM audit_entry),
        'failed maintenance return leaves placement and audit unchanged');
    PERFORM return_from_maintenance(v_staff, v_bike, v_b, 'serviceable');
    PERFORM pg_temp.assert_true(pg_temp.snap(v_bike) = 'station:' || v_b || ':0:serviceable', 'return sets station placement, clears the provider and applies the supplied state');
    PERFORM pg_temp.assert_true((SELECT count(*) = v_audits + 1 FROM audit_entry), 'maintenance return writes one audit entry');
    PERFORM return_from_maintenance(v_staff, v_broken, v_c, 'unavailable_for_maintenance');   -- destination controls off
    PERFORM pg_temp.assert_true(pg_temp.snap(v_broken) = 'station:' || v_c || ':0:unavailable_for_maintenance', 'station controls do not restrict maintenance return');
    SELECT count(*) INTO v_audits FROM audit_entry;
    PERFORM pg_temp.expect_error('22023', format('SELECT return_from_maintenance(%s, %s, %s, ''serviceable'')', v_staff, v_bike, v_b), 'repeated maintenance return is rejected');
    PERFORM pg_temp.assert_true((SELECT count(*) = v_audits FROM audit_entry), 'a repeated return writes no audit');

    v_t4 := transfer_bicycle(v_staff, v_bike, v_b, v_a);

    ---------------------------------------------------------------- history queries
    PERFORM pg_temp.assert_true((SELECT array_agg(transfer_id ORDER BY transferred_at DESC, transfer_id DESC) = ARRAY[v_t4.transfer_id, v_t3.transfer_id, v_t2.transfer_id, v_t1.transfer_id]
        FROM get_bicycle_transfer_history(v_staff, v_bike)), 'transfer history lists the bicycle''s transfers newest first');
    PERFORM pg_temp.assert_true((SELECT count(*) = 4 FROM get_bicycle_transfer_history(v_staff, v_bike)), 'transfer history contains only this bicycle''s transfers');
    PERFORM pg_temp.assert_true((SELECT transfer_id = v_t3.transfer_id FROM get_bicycle_transfer_history(v_staff, v_bike, 1, 1)), 'transfer history pages with limit and offset');
    PERFORM pg_temp.assert_true((SELECT count(*) = 0 FROM get_bicycle_transfer_history(v_staff, v_never)), 'a never-transferred bicycle has an empty history');
    PERFORM pg_temp.expect_error('P0002', format('SELECT * FROM get_bicycle_transfer_history(%s, -1)', v_staff), 'transfer history of an unknown bicycle is rejected');
    PERFORM pg_temp.expect_error('42501', format('SELECT * FROM get_bicycle_transfer_history(%s, %s)', v_rider, v_bike), 'riders cannot read transfer history');
    PERFORM pg_temp.expect_error('22023', format('SELECT * FROM get_bicycle_transfer_history(%s, %s, 0, 0)', v_staff, v_bike), 'transfer history rejects limit 0');
    PERFORM pg_temp.expect_error('22023', format('SELECT * FROM get_bicycle_transfer_history(%s, %s, 201, 0)', v_staff, v_bike), 'transfer history rejects limit above 200');
    PERFORM pg_temp.expect_error('22023', format('SELECT * FROM get_bicycle_transfer_history(%s, %s, 10, -1)', v_staff, v_bike), 'transfer history rejects a negative offset');

    PERFORM pg_temp.assert_true((SELECT count(*) = 6 FROM get_bicycle_movement_history(v_staff, v_bike)), 'movement history combines four transfers, one handover and one return');
    PERFORM pg_temp.assert_true((SELECT count(*) FILTER (WHERE movement_type = 'station_transfer') = 4
                                    AND count(*) FILTER (WHERE movement_type = 'maintenance_handover') = 1
                                    AND count(*) FILTER (WHERE movement_type = 'maintenance_return') = 1
                                   FROM get_bicycle_movement_history(v_staff, v_bike)), 'movement history labels each movement type');
    PERFORM pg_temp.assert_true((SELECT from_station_id = v_a AND to_station_id IS NULL AND provider_id = v_provider
                                    AND maintenance_state_before = 'serviceable' AND maintenance_state_after = 'unavailable_for_maintenance'
                                    AND performed_by_staff_id = v_staff
                                   FROM get_bicycle_movement_history(v_staff, v_bike) WHERE movement_type = 'maintenance_handover'), 'handover entry shows source station, provider and states');
    PERFORM pg_temp.assert_true((SELECT from_station_id IS NULL AND to_station_id = v_b AND provider_id = v_provider
                                    AND maintenance_state_before = 'unavailable_for_maintenance' AND maintenance_state_after = 'serviceable'
                                   FROM get_bicycle_movement_history(v_staff, v_bike) WHERE movement_type = 'maintenance_return'), 'return entry shows destination station, provider and states');
    PERFORM pg_temp.assert_true((SELECT from_station_id = v_a AND to_station_id = v_b AND reason = 'Rebalance' AND record_id = v_t1.transfer_id
                                   FROM get_bicycle_movement_history(v_staff, v_bike) WHERE movement_type = 'station_transfer' AND record_id = v_t1.transfer_id), 'transfer entry shows stations, reason and record id');
    PERFORM pg_temp.assert_true((SELECT count(*) = 2 FROM get_bicycle_movement_history(v_staff, v_bike, 2, 0)), 'movement history pages with a limit');
    PERFORM pg_temp.assert_true((SELECT count(*) = 0 FROM get_bicycle_movement_history(v_staff, v_never)), 'a never-moved bicycle has an empty movement history');
    PERFORM pg_temp.assert_true((SELECT count(*) = 3 FROM get_bicycle_movement_history(v_staff, v_broken)), 'movement history of another bicycle contains its own movements only');
    PERFORM pg_temp.expect_error('P0002', format('SELECT * FROM get_bicycle_movement_history(%s, -1)', v_staff), 'movement history of an unknown bicycle is rejected');
    PERFORM pg_temp.expect_error('42501', format('SELECT * FROM get_bicycle_movement_history(%s, %s)', v_rider, v_bike), 'riders cannot read movement history');
    PERFORM pg_temp.expect_error('22023', format('SELECT * FROM get_bicycle_movement_history(%s, %s, 0, 0)', v_staff, v_bike), 'movement history rejects limit 0');
    PERFORM pg_temp.assert_true((SELECT t = v_t1 FROM bicycle_transfer t WHERE t.transfer_id = v_t1.transfer_id), 'earlier transfer records are unchanged by later movements');

    ---------------------------------------------------------------- table shape follows the ERD
    PERFORM pg_temp.assert_true((SELECT array_agg(column_name::text ORDER BY ordinal_position) = ARRAY['transfer_id','bicycle_id','from_station_id','to_station_id','performed_by_staff_id','transferred_at','reason']
        FROM information_schema.columns WHERE table_schema = 'bicycle_rental' AND table_name = 'bicycle_transfer'), 'bicycle_transfer has the ERD columns');
    PERFORM pg_temp.assert_true((SELECT count(*) = 1 FROM pg_indexes WHERE schemaname = 'bicycle_rental' AND tablename = 'bicycle_transfer'
        AND indexdef LIKE '%(bicycle_id, transferred_at%'), 'bicycle_transfer has the (bicycle_id, transferred_at) index');
    PERFORM pg_temp.assert_true((SELECT count(*) = 4 FROM pg_constraint WHERE conrelid = 'bicycle_transfer'::regclass AND contype = 'f'), 'bicycle_transfer references bicycle, both stations and staff');

    ---------------------------------------------------------------- availability reflects movements (F-037)
    PERFORM pg_temp.assert_true((SELECT regular_available FROM get_station_availability(v_staff, v_a))
        = (SELECT count(*) FROM bicycle b WHERE b.current_station_id = v_a AND b.bicycle_type = 'regular' AND b.maintenance_state = 'serviceable'),
        'availability at the source station matches its serviceable bicycles');
    SELECT regular_available INTO v_count FROM get_station_availability(v_staff, v_b);
    PERFORM transfer_bicycle(v_staff, v_never, v_a, v_b);
    PERFORM pg_temp.assert_true((SELECT regular_available = v_count + 1 FROM get_station_availability(v_staff, v_b)), 'a transfer adds the bicycle to the destination''s availability');
    PERFORM handover_to_maintenance(v_staff, v_never, v_provider);
    PERFORM pg_temp.assert_true((SELECT regular_available = v_count FROM get_station_availability(v_staff, v_b)), 'a handover removes the bicycle from availability');

    ---------------------------------------------------------------- movement audit entries are append-only
    SELECT max(audit_id) INTO v_audit FROM audit_entry WHERE primary_record_type = 'Bicycle' AND action_type = 'maintenance_handover';
    PERFORM pg_temp.expect_error('P0001', format('UPDATE audit_entry SET staff_id = staff_id WHERE audit_id = %s', v_audit), 'handover audit entries cannot be updated');
    PERFORM pg_temp.expect_error('P0001', format('DELETE FROM audit_entry WHERE audit_id = %s', v_audit), 'handover audit entries cannot be deleted');
    PERFORM pg_temp.expect_error('P0001', format('DELETE FROM audit_detail WHERE audit_id = %s', v_audit), 'handover audit details cannot be deleted');

    ---------------------------------------------------------------- placement stays consistent for the fixtures
    PERFORM pg_temp.assert_true((SELECT count(*) = 0 FROM bicycle b
        WHERE b.bicycle_id IN (v_bike, v_broken, v_low, v_rented, v_other, v_never)
          AND (((b.placement = 'station') <> (b.current_station_id IS NOT NULL))
            OR ((b.placement = 'maintenance_provider') <> (b.current_provider_id IS NOT NULL))
            OR ((b.placement = 'active_rental') <> EXISTS (SELECT 1 FROM rental r WHERE r.bicycle_id = b.bicycle_id AND r.end_time IS NULL)))),
        'placement, station, provider and rental state agree for every fixture bicycle');
    SET CONSTRAINTS ALL IMMEDIATE;
END $$;

SELECT count(*) AS bicycle_movement_assertions_passed FROM movement_test_results;

ROLLBACK;

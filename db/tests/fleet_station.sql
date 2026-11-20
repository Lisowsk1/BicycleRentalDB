-- Run after all migrations with psql --set=ON_ERROR_STOP=1.
-- All fixtures, helper functions and test-only triggers are rolled back.
BEGIN;
SET LOCAL search_path = bicycle_rental, public, pg_temp;

CREATE TEMP TABLE fleet_test_results (description text NOT NULL);

CREATE FUNCTION pg_temp.assert_true(p_condition boolean, p_description text)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    IF p_condition IS DISTINCT FROM true THEN
        RAISE EXCEPTION 'FAIL: %', p_description;
    END IF;
    INSERT INTO fleet_test_results VALUES (p_description);
END $$;

-- Check SQLSTATE, including deferred constraints, and roll back rejected changes.
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
        INSERT INTO fleet_test_results VALUES (p_description);
        RETURN;
    END;
    RAISE EXCEPTION 'FAIL: %; expected SQLSTATE %, but command succeeded', p_description, p_state;
END $$;

CREATE FUNCTION pg_temp.reject_fleet_audit()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'injected audit failure';
END $$;

DO $$
DECLARE
    v_staff bigint;
    v_rider bigint;
    v_station bigint;
    v_disabled bigint;
    v_empty bigint;
    v_regular bigint;
    v_broken bigint;
    v_e19 bigint;
    v_e20 bigint;
    v_missing bigint;
    v_provider bigint;
    v_inactive bigint;
    v_count bigint;
    v_audit bigint;
    v_results text[];
    v_prefix text := 'fleet-' || gen_random_uuid();
    v_invalid numeric;
    v_baseline bigint;
    v_test_role text := 'fleet_baseline_' || replace(gen_random_uuid()::text, '-', '');
    v_denied boolean := false;
    v_original_session text := session_user;
BEGIN
    -- Random fixture emails/identifiers keep the suite usable on populated local databases.
    -- Fixed bcrypt-shaped hash: these tests do not authenticate or exercise password hashing.
    INSERT INTO account (first_name, last_name, email, password_hash, role)
    VALUES ('Fleet', 'Staff', 'fleet-staff-' || gen_random_uuid() || '@test.invalid',
            '$2a$12$' || repeat('x', 53), 'staff') RETURNING account_id INTO v_staff;
    INSERT INTO staff (account_id) VALUES (v_staff);
    INSERT INTO account (first_name, last_name, email, password_hash, role)
    VALUES ('Fleet', 'Rider', 'fleet-rider-' || gen_random_uuid() || '@test.invalid',
            '$2a$12$' || repeat('x', 53), 'rider') RETURNING account_id INTO v_rider;
    INSERT INTO rider (account_id) VALUES (v_rider);

    SELECT count(*) INTO v_count FROM audit_entry;
    v_station := create_station(v_staff, ' Central ', ' Main Street ', 52.2296756, 21.0122287, true, true);
    v_disabled := create_station(v_staff, 'Closed', 'Side Street', -90, -180, false, false);
    v_empty := create_station(v_staff, 'Empty', 'Other Street', 90, 180, true, false);
    PERFORM pg_temp.assert_true((SELECT count(*) = v_count + 3 FROM audit_entry), 'station creation is audited once per station');
    SELECT max(audit_id) INTO v_audit FROM audit_entry WHERE primary_record_type = 'Station' AND primary_record_id = v_station;
    PERFORM pg_temp.assert_true((SELECT count(*) = 6 AND bool_and(previous_value IS NULL) FROM audit_detail WHERE audit_id = v_audit),
        'station creation records all six fields with absent previous values');
    PERFORM pg_temp.assert_true((SELECT name = 'Central' AND address = 'Main Street' FROM station WHERE station_id = v_station), 'station strings are trimmed');
    PERFORM pg_temp.assert_true((SELECT latitude = 52.2296756 AND longitude = 21.0122287 FROM get_station_availability(v_rider, v_station)), 'station queries include location');

    PERFORM pg_temp.expect_error('42501', format('SELECT create_station(%s, ''Denied'', ''Street'', 0, 0, true, true)', v_rider), 'riders cannot create stations');
    PERFORM pg_temp.expect_error('42501', format('SELECT update_station(%s, %s, p_name => ''Denied'')', v_rider, v_station), 'riders cannot update stations');
    PERFORM pg_temp.expect_error('42501', 'SELECT * FROM get_station_availability(NULL)', 'availability requires an account');
    PERFORM pg_temp.expect_error('22023', format('SELECT create_station(%s, E''\t\n'', ''Street'', 0, 0, true, true)', v_staff), 'blank station names rejected');
    PERFORM pg_temp.expect_error('22023', format('SELECT create_station(%s, ''Name'', ''Street'', 91, 0, true, true)', v_staff), 'invalid station coordinates rejected');
    PERFORM pg_temp.expect_error('22023', format('SELECT create_station(%s, ''Name'', ''Street'', 0, 0, NULL, true)', v_staff), 'station controls must be supplied');
    PERFORM pg_temp.expect_error('23514', format('UPDATE station SET longitude = 181 WHERE station_id = %s', v_station), 'coordinate checks protect direct writes');
    PERFORM pg_temp.expect_error('P0002', format('SELECT update_station(%s, -1)', v_staff), 'unknown station updates rejected');

    SELECT count(*) INTO v_count FROM audit_entry;
    PERFORM pg_temp.assert_true(update_station(v_staff, v_station, p_name => 'Renamed', p_address => 'New Address', p_latitude => 50, p_longitude => 20), 'station descriptive updates succeed');
    PERFORM pg_temp.assert_true((SELECT count(*) = v_count + 1 FROM audit_entry), 'combined station update writes one audit entry');
    SELECT max(audit_id) INTO v_audit FROM audit_entry;
    PERFORM pg_temp.assert_true((SELECT count(*) = 4 FROM audit_detail WHERE audit_id = v_audit), 'combined update audits all changed fields');
    PERFORM pg_temp.assert_true((SELECT previous_value = to_jsonb('Central'::text) AND new_value = to_jsonb('Renamed'::text)
        FROM audit_detail WHERE audit_id = v_audit AND field_name = 'name'), 'audit values reflect before and after state');
    PERFORM pg_temp.assert_true(NOT update_station(v_staff, v_station, p_name => ' Renamed '), 'unchanged station update returns false');
    PERFORM pg_temp.assert_true((SELECT count(*) = v_count + 1 FROM audit_entry), 'station no-op produces no audit');

    v_regular := create_bicycle(v_staff, v_prefix || '-regular', 'regular', 'serviceable', v_station);
    v_broken := create_bicycle(v_staff, v_prefix || '-broken', 'regular', 'unavailable_for_maintenance', v_station);
    v_e19 := create_bicycle(v_staff, v_prefix || '-19', 'electric', 'serviceable', v_station, 19);
    v_e20 := create_bicycle(v_staff, v_prefix || '-20', 'electric', 'serviceable', v_station, 20);
    v_missing := create_bicycle(v_staff, v_prefix || '-missing', 'electric', 'serviceable', v_station);
    PERFORM create_bicycle(v_staff, v_prefix || '-closed', 'regular', 'serviceable', v_disabled);
    v_provider := create_maintenance_provider(v_staff, ' Workshop ', 'repair@test.invalid', '123');
    v_inactive := create_maintenance_provider(v_staff, 'Inactive');
    PERFORM set_maintenance_provider_active(v_staff, v_inactive, false);
    SET CONSTRAINTS ALL IMMEDIATE;
    SET CONSTRAINTS ALL DEFERRED;
    PERFORM pg_temp.assert_true((SELECT count(*) = v_count + 1 FROM audit_entry), 'bicycle and provider creation do not add mandatory audit events');
    PERFORM pg_temp.assert_true((SELECT name = 'Workshop' AND is_active FROM maintenance_provider WHERE provider_id = v_provider), 'provider creation trims name and defaults active');
    PERFORM pg_temp.assert_true((SELECT regular_available = 1 AND electric_available = 1 FROM get_station_availability(v_rider, v_station)), 'availability excludes maintenance, low and missing battery');
    PERFORM pg_temp.assert_true((SELECT regular_available = 0 AND electric_available = 0 FROM get_station_availability(v_rider, v_disabled)), 'rental-disabled stations report zero');
    PERFORM pg_temp.assert_true((SELECT regular_available = 0 AND electric_available = 0 FROM get_station_availability(v_rider, v_empty)), 'empty stations remain in availability results');

    PERFORM pg_temp.expect_error('23505', format('SELECT create_bicycle(%s, %L, ''regular'', ''serviceable'', %s)', v_staff, E'\t ' || upper(v_prefix || '-regular') || E'\n', v_station), 'identifier uniqueness ignores case and surrounding whitespace');
    PERFORM pg_temp.expect_error('22023', format('SELECT create_bicycle(%s, E''\t'', ''regular'', ''serviceable'', %s)', v_staff, v_station), 'blank bicycle identifiers rejected');
    PERFORM pg_temp.expect_error('42501', format('SELECT create_bicycle(%s, ''Denied'', ''regular'', ''serviceable'', %s)', v_rider, v_station), 'riders cannot register bicycles');
    PERFORM pg_temp.expect_error('22023', format('SELECT create_bicycle(%s, ''NoStation'', ''regular'', ''serviceable'', -1)', v_staff), 'unknown creation station rejected');
    PERFORM pg_temp.expect_error('22023', format('SELECT create_bicycle(%s, ''NoState'', ''regular'', NULL, %s)', v_staff, v_station), 'creation requires explicit maintenance state');
    PERFORM pg_temp.expect_error('22023', format('SELECT create_bicycle(%s, ''RegularBattery'', ''regular'', ''serviceable'', %s, 50)', v_staff, v_station), 'regular bicycles cannot have batteries');
    PERFORM pg_temp.expect_error('22P02', format('SELECT set_maintenance_state(%s, %s, ''invalid'')', v_staff, v_regular), 'invalid maintenance enum rejected');
    PERFORM pg_temp.expect_error('23503', format('UPDATE bicycle SET current_station_id = -1 WHERE bicycle_id = %s', v_regular), 'station foreign key enforced');
    PERFORM pg_temp.expect_error('23514', format('UPDATE bicycle SET current_station_id = NULL WHERE bicycle_id = %s', v_regular), 'station placement needs a station');
    PERFORM pg_temp.expect_error('23514', format('UPDATE bicycle SET current_provider_id = %s WHERE bicycle_id = %s', v_provider, v_regular), 'station bicycles cannot also reference providers');
    PERFORM pg_temp.expect_error('23503', format('UPDATE bicycle SET placement = ''maintenance_provider'', current_station_id = NULL, current_provider_id = -1 WHERE bicycle_id = %s', v_regular), 'provider foreign key rejects nonexistent providers');
    PERFORM pg_temp.expect_error('23514', format('UPDATE bicycle SET placement = ''maintenance_provider'', current_station_id = NULL WHERE bicycle_id = %s', v_regular), 'provider placement needs a provider');
    PERFORM pg_temp.expect_error('P0001', format('UPDATE bicycle SET identifier = ''Changed'' WHERE bicycle_id = %s', v_regular), 'bicycle identifiers immutable');
    PERFORM pg_temp.expect_error('P0001', format('UPDATE bicycle SET bicycle_type = ''electric'' WHERE bicycle_id = %s', v_regular), 'bicycle types immutable');
    PERFORM pg_temp.expect_error('23514', format('UPDATE bicycle SET bicycle_id = DEFAULT WHERE bicycle_id = %s', v_regular), 'bicycle primary keys immutable');

    PERFORM pg_temp.expect_error('23514', format('INSERT INTO bicycle (identifier, bicycle_type, maintenance_state, placement, current_station_id) VALUES (%L, ''electric'', ''serviceable'', ''station'', %s)', v_prefix || '-orphan', v_station), 'electric parent requires subtype at constraint check');
    PERFORM pg_temp.expect_error('23503', format('INSERT INTO electric_bicycle VALUES (%s, 50, ''electric'')', v_regular), 'regular bicycle cannot acquire electric subtype');
    PERFORM pg_temp.expect_error('23514', format('INSERT INTO electric_bicycle VALUES (%s, 50, ''regular'')', v_regular), 'subtype type check enforced');
    PERFORM pg_temp.expect_error('23514', format('DELETE FROM electric_bicycle WHERE bicycle_id = %s', v_e20), 'electric subtype cannot be removed leaving its parent');
    PERFORM pg_temp.expect_error('23514', format($sql$
        DO $reassign$ DECLARE new_id bigint; BEGIN
            INSERT INTO bicycle (identifier, bicycle_type, maintenance_state, placement, current_station_id)
            VALUES (%L, 'electric', 'serviceable', 'station', %s) RETURNING bicycle_id INTO new_id;
            UPDATE electric_bicycle SET bicycle_id = new_id WHERE bicycle_id = %s;
        END $reassign$
        $sql$, v_prefix || '-reparent', v_station, v_e20), 'electric subtype cannot be reassigned to a new electric parent');
    PERFORM pg_temp.assert_true((SELECT battery_percentage = 20 FROM electric_bicycle WHERE bicycle_id = v_e20), 'rejected subtype mutations leave original intact');

    FOREACH v_invalid IN ARRAY ARRAY[-1, 101, 19.5, NULL, 'NaN'::numeric] LOOP
        PERFORM pg_temp.expect_error('22023', format('SELECT update_battery(%s, %s, %L::numeric)', v_staff, v_e20, v_invalid), 'invalid battery update rejected: ' || coalesce(v_invalid::text, 'NULL'));
        PERFORM pg_temp.assert_true((SELECT battery_percentage = 20 FROM electric_bicycle WHERE bicycle_id = v_e20), 'rejected battery value preserves last reading');
    END LOOP;
    PERFORM pg_temp.expect_error('22023', format('SELECT create_bicycle(%s, ''BadBattery'', ''electric'', ''serviceable'', %s, 10.5)', v_staff, v_station), 'fractional creation battery rejected');
    PERFORM pg_temp.expect_error('22P02', format('SELECT update_battery(%s, %s, ''bad'')', v_staff, v_e20), 'nonnumeric battery update rejected');
    PERFORM pg_temp.expect_error('22023', format('SELECT update_battery(%s, %s, 50)', v_staff, v_regular), 'regular battery updates rejected');
    PERFORM pg_temp.expect_error('42501', format('SELECT update_battery(%s, %s, 50)', v_rider, v_e20), 'riders cannot update batteries');
    PERFORM pg_temp.expect_error('23514', format('UPDATE electric_bicycle SET battery_percentage = 101 WHERE bicycle_id = %s', v_e20), 'battery range check protects direct writes');
    PERFORM update_battery(v_staff, v_missing, 0);
    PERFORM update_battery(v_staff, v_missing, 100);
    PERFORM pg_temp.assert_true((SELECT regular_available = 1 AND electric_available = 2 FROM get_station_availability(v_rider, v_station)), 'valid boundary battery values update availability');

    SELECT array_agg(result ORDER BY record_no) INTO v_results
      FROM import_battery_readings(v_staff, jsonb_build_array(
          jsonb_build_object('bicycle_id', v_e19, 'battery_percentage', 30),
          jsonb_build_object('bicycle_id', v_e19, 'battery_percentage', 1.5),
          jsonb_build_object('bicycle_id', v_regular, 'battery_percentage', 50),
          jsonb_build_object('bicycle_id', -1, 'battery_percentage', 50),
          jsonb_build_object('bicycle_id', v_e19, 'battery_percentage', NULL),
          jsonb_build_object('bicycle_id', v_e19, 'battery_percentage', 'bad'),
          jsonb_build_object('bicycle_id', v_e19, 'battery_percentage', 25)));
    PERFORM pg_temp.assert_true(v_results = ARRAY['applied', 'invalid_value', 'not_electric', 'unknown_bicycle', 'invalid_value', 'invalid_value', 'applied'], 'battery import reports independent results in input order');
    PERFORM pg_temp.assert_true((SELECT battery_percentage = 25 FROM electric_bicycle WHERE bicycle_id = v_e19), 'last valid imported reading wins');

    -- Exercise the placement boundary used by the future rental lifecycle module.
    -- This does not create rental rows or test rider ownership/charges.
    PERFORM set_station_controls(v_staff, v_station, false, true);
    PERFORM pg_temp.expect_error('23514', format('UPDATE bicycle SET placement = ''active_rental'', current_station_id = NULL WHERE bicycle_id = %s', v_regular), 'rental-disabled station rejects rental placement');
    PERFORM pg_temp.assert_true((SELECT regular_available = 0 AND electric_available = 0 FROM get_station_availability(v_rider, v_station)), 'disabling rentals immediately changes availability');
    PERFORM set_station_controls(v_staff, v_station, true, false);
    PERFORM pg_temp.assert_true((SELECT regular_available = 1 AND electric_available = 3 AND NOT return_enabled FROM get_station_availability(v_rider, v_station)), 'return-disabled stations still allow rentals');
    PERFORM pg_temp.expect_error('23514', format('UPDATE bicycle SET placement = ''active_rental'', current_station_id = NULL WHERE bicycle_id = %s', v_broken), 'unserviceable bicycle cannot start rental');
    PERFORM update_battery(v_staff, v_e19, 19);
    PERFORM pg_temp.expect_error('23514', format('UPDATE bicycle SET placement = ''active_rental'', current_station_id = NULL WHERE bicycle_id = %s', v_e19), '19 percent battery prevents rental placement');
    UPDATE electric_bicycle SET battery_percentage = NULL WHERE bicycle_id = v_missing;
    PERFORM pg_temp.expect_error('23514', format('UPDATE bicycle SET placement = ''active_rental'', current_station_id = NULL WHERE bicycle_id = %s', v_missing), 'missing battery prevents rental placement');
    PERFORM pg_temp.expect_error('23514', format('INSERT INTO bicycle (identifier, bicycle_type, maintenance_state, placement) VALUES (%L, ''regular'', ''serviceable'', ''active_rental'')', v_prefix || '-direct-rental'), 'inserting rental placement cannot bypass station checks');

    UPDATE bicycle SET placement = 'active_rental', current_station_id = NULL WHERE bicycle_id = v_e20;
    PERFORM pg_temp.assert_true((SELECT regular_available = 1 AND electric_available = 0 FROM get_station_availability(v_rider, v_station)), 'successful rental placement removes bicycle from availability');
    PERFORM pg_temp.expect_error('23514', format('UPDATE bicycle SET placement = ''station'', current_station_id = %s WHERE bicycle_id = %s', v_disabled, v_e20), 'return-disabled station rejects rental return');
    PERFORM pg_temp.expect_error('23514', format('UPDATE bicycle SET placement = ''station'', current_station_id = -1 WHERE bicycle_id = %s', v_e20), 'unknown rental return destination rejected');
    PERFORM pg_temp.expect_error('23514', format('UPDATE bicycle SET placement = ''maintenance_provider'', current_provider_id = %s WHERE bicycle_id = %s', v_provider, v_e20), 'rented bicycles cannot bypass returns via provider placement');
    PERFORM set_maintenance_state(v_staff, v_e20, 'unavailable_for_maintenance');
    PERFORM update_battery(v_staff, v_e20, 0);
    PERFORM set_station_controls(v_staff, v_disabled, false, true);
    UPDATE bicycle SET placement = 'station', current_station_id = v_disabled WHERE bicycle_id = v_e20;
    PERFORM pg_temp.assert_true((SELECT placement = 'station' AND current_station_id = v_disabled AND maintenance_state = 'unavailable_for_maintenance' FROM bicycle WHERE bicycle_id = v_e20), 'return permits low battery and maintenance unavailability at rental-disabled station');

    SELECT count(*) INTO v_count FROM audit_entry;
    PERFORM pg_temp.expect_error('42501', format('SELECT handover_to_maintenance(%s, %s, %s)', v_rider, v_regular, v_provider), 'riders cannot perform maintenance handover');
    PERFORM pg_temp.expect_error('22023', format('SELECT handover_to_maintenance(%s, %s, %s)', v_staff, v_regular, v_inactive), 'inactive provider rejects handover');
    PERFORM pg_temp.expect_error('22023', format('SELECT handover_to_maintenance(%s, %s, -1)', v_staff, v_regular), 'unknown provider rejects handover');
    PERFORM handover_to_maintenance(v_staff, v_regular, v_provider);
    PERFORM pg_temp.assert_true((SELECT count(*) = v_count + 1 FROM audit_entry), 'maintenance handover writes exactly one audit entry');
    SELECT max(audit_id) INTO v_audit FROM audit_entry;
    PERFORM pg_temp.assert_true((SELECT count(*) = 4 FROM audit_detail WHERE audit_id = v_audit), 'handover audit includes state placement station and provider');
    PERFORM pg_temp.assert_true((SELECT placement = 'maintenance_provider' AND current_station_id IS NULL AND current_provider_id = v_provider AND maintenance_state = 'unavailable_for_maintenance' FROM bicycle WHERE bicycle_id = v_regular), 'handover changes placement references and maintenance state together');
    PERFORM pg_temp.expect_error('22023', format('SELECT handover_to_maintenance(%s, %s, %s)', v_staff, v_regular, v_provider), 'repeated handover rejected');
    PERFORM pg_temp.expect_error('23514', format('UPDATE bicycle SET placement = ''active_rental'', current_provider_id = NULL WHERE bicycle_id = %s', v_regular), 'provider bicycle cannot start rental');

    PERFORM pg_temp.assert_true(set_maintenance_state(v_staff, v_regular, 'serviceable'), 'maintenance state may change at provider placement');
    SELECT count(*) INTO v_count FROM audit_entry;
    SELECT max(audit_id) INTO v_audit FROM audit_entry;
    PERFORM pg_temp.assert_true((SELECT count(*) = 3 FROM audit_detail WHERE audit_id = v_audit), 'maintenance state audit includes unchanged placement and station context');
    PERFORM pg_temp.assert_true(NOT set_maintenance_state(v_staff, v_regular, 'serviceable'), 'unchanged maintenance state is a no-op');
    PERFORM pg_temp.assert_true((SELECT count(*) = v_count FROM audit_entry), 'maintenance no-op produces no audit');
    PERFORM set_maintenance_provider_active(v_staff, v_provider, false);
    PERFORM set_station_controls(v_staff, v_disabled, false, false);
    SELECT count(*) INTO v_count FROM audit_entry;
    PERFORM pg_temp.expect_error('22023', format('SELECT return_from_maintenance(%s, %s, %s, NULL)', v_staff, v_regular, v_disabled), 'maintenance return requires explicit state');
    PERFORM pg_temp.expect_error('22023', format('SELECT return_from_maintenance(%s, %s, -1, ''serviceable'')', v_staff, v_regular), 'maintenance return rejects unknown station');
    PERFORM return_from_maintenance(v_staff, v_regular, v_disabled, 'serviceable');
    PERFORM pg_temp.assert_true((SELECT count(*) = v_count + 1 FROM audit_entry), 'maintenance return writes exactly one audit entry');
    PERFORM pg_temp.assert_true((SELECT placement = 'station' AND current_station_id = v_disabled AND current_provider_id IS NULL AND maintenance_state = 'serviceable' FROM bicycle WHERE bicycle_id = v_regular), 'maintenance return clears provider and ignores rider station controls even for inactive provider');
    PERFORM pg_temp.expect_error('22023', format('SELECT return_from_maintenance(%s, %s, %s, ''serviceable'')', v_staff, v_regular, v_disabled), 'repeated maintenance return rejected');

    -- An audit failure must undo the administrative mutation in the same transaction.
    EXECUTE 'CREATE TRIGGER test_reject_fleet_audit BEFORE INSERT ON audit_entry FOR EACH ROW EXECUTE FUNCTION pg_temp.reject_fleet_audit()';
    SELECT count(*) INTO v_count FROM audit_entry;
    PERFORM pg_temp.expect_error('P0001', format('SELECT update_station(%s, %s, p_name => ''MustRollBack'')', v_staff, v_station), 'station audit failure rejects command');
    PERFORM pg_temp.assert_true((SELECT name = 'Renamed' FROM station WHERE station_id = v_station), 'station update rolls back on audit failure');
    PERFORM pg_temp.expect_error('P0001', format('SELECT set_maintenance_state(%s, %s, ''unavailable_for_maintenance'')', v_staff, v_regular), 'maintenance state audit failure rejects command');
    PERFORM pg_temp.assert_true((SELECT maintenance_state = 'serviceable' FROM bicycle WHERE bicycle_id = v_regular), 'maintenance state rolls back on audit failure');
    PERFORM set_maintenance_provider_active(v_staff, v_provider, true);
    PERFORM pg_temp.expect_error('P0001', format('SELECT handover_to_maintenance(%s, %s, %s)', v_staff, v_regular, v_provider), 'handover audit failure rejects command');
    PERFORM pg_temp.assert_true((SELECT placement = 'station' AND current_provider_id IS NULL FROM bicycle WHERE bicycle_id = v_regular), 'handover placement rolls back on audit failure');
    PERFORM pg_temp.assert_true((SELECT count(*) = v_count FROM audit_entry), 'failed administrative commands leave audit count unchanged');
    EXECUTE 'DROP TRIGGER test_reject_fleet_audit ON audit_entry';

    PERFORM handover_to_maintenance(v_staff, v_regular, v_provider);
    EXECUTE 'CREATE TRIGGER test_reject_fleet_audit BEFORE INSERT ON audit_entry FOR EACH ROW EXECUTE FUNCTION pg_temp.reject_fleet_audit()';
    SELECT count(*) INTO v_count FROM audit_entry;
    PERFORM pg_temp.expect_error('P0001', format('SELECT return_from_maintenance(%s, %s, %s, ''serviceable'')', v_staff, v_regular, v_station), 'maintenance return audit failure rejects command');
    PERFORM pg_temp.assert_true((SELECT placement = 'maintenance_provider' AND current_provider_id = v_provider AND current_station_id IS NULL FROM bicycle WHERE bicycle_id = v_regular), 'maintenance return rolls back on audit failure');
    PERFORM pg_temp.assert_true((SELECT count(*) = v_count FROM audit_entry), 'failed maintenance return leaves audit count unchanged');
    EXECUTE 'DROP TRIGGER test_reject_fleet_audit ON audit_entry';

    SELECT count(*) INTO v_count FROM audit_entry;
    PERFORM pg_temp.expect_error('22023', format('SELECT handover_to_maintenance(%s, %s, %s)', v_staff, v_regular, v_provider), 'rejected repeated handover emits no audit');
    PERFORM pg_temp.assert_true((SELECT count(*) = v_count FROM audit_entry), 'rejected command leaves audit count unchanged');
    PERFORM pg_temp.expect_error('23000', format('DELETE FROM maintenance_provider WHERE provider_id = %s', v_provider), 'providers cannot be deleted');
    PERFORM pg_temp.expect_error('P0001', format('DELETE FROM station WHERE station_id = %s', v_empty), 'stations cannot be deleted');
    PERFORM pg_temp.expect_error('P0001', format('DELETE FROM bicycle WHERE bicycle_id = %s', v_broken), 'bicycles cannot be deleted');

    -- F-026: privileged baseline loading may insert rental placement. This is not an
    -- operational rental start, and all structural constraints must still be enforced.
    PERFORM set_config('bicycle_rental.privileged_setup', 'true', true);
    INSERT INTO bicycle (identifier, bicycle_type, maintenance_state, placement)
    VALUES (v_prefix || '-baseline-rental', 'regular', 'serviceable', 'active_rental')
    RETURNING bicycle_id INTO v_baseline;
    INSERT INTO rental (
        rider_id, bicycle_id, pickup_station_id, tariff_id,
        captured_price_per_block, captured_block_length_seconds, captured_currency, bicycle_type
    )
    SELECT v_rider, v_baseline, v_station, t.tariff_id,
           t.price_per_block, t.block_length_seconds, t.currency, 'regular'
      FROM tariff t
     WHERE t.bicycle_type = 'regular' AND t.is_active
     LIMIT 1;
    PERFORM pg_temp.assert_true((SELECT placement = 'active_rental' AND current_station_id IS NULL FROM bicycle WHERE bicycle_id = v_baseline), 'privileged baseline accepts existing rental placement');
    PERFORM pg_temp.expect_error('23514', format('INSERT INTO bicycle (identifier, bicycle_type, maintenance_state, placement, current_station_id) VALUES (%L, ''regular'', ''serviceable'', ''active_rental'', %s)', v_prefix || '-bad-baseline', v_station), 'baseline import still enforces placement checks');
    PERFORM pg_temp.expect_error('23514', format('INSERT INTO bicycle (identifier, bicycle_type, maintenance_state, placement) VALUES (%L, ''electric'', ''serviceable'', ''active_rental'')', v_prefix || '-baseline-orphan'), 'baseline import still requires electric subtype');
    PERFORM set_config('bicycle_rental.privileged_setup', 'false', true);
    PERFORM pg_temp.expect_error('23514', format('INSERT INTO bicycle (identifier, bicycle_type, maintenance_state, placement) VALUES (%L, ''regular'', ''serviceable'', ''active_rental'')', v_prefix || '-after-baseline'), 'baseline privilege ends when setup flag is cleared');

    -- Compose/CI runs as a superuser. Exercise a separate login identity to prove that
    -- merely setting the custom GUC cannot enable the baseline exception. Non-superuser
    -- local test connections can run the remaining suite without role-creation privileges.
    IF (SELECT rolsuper FROM pg_catalog.pg_roles WHERE rolname = session_user) THEN
        EXECUTE format('CREATE ROLE %I', v_test_role);
        EXECUTE format('GRANT USAGE ON SCHEMA bicycle_rental TO %I', v_test_role);
        EXECUTE format('GRANT INSERT ON bicycle TO %I', v_test_role);
        EXECUTE format('GRANT USAGE ON ALL SEQUENCES IN SCHEMA bicycle_rental TO %I', v_test_role);
        PERFORM set_config('bicycle_rental.privileged_setup', 'true', true);
        EXECUTE format('SET SESSION AUTHORIZATION %I', v_test_role);
        BEGIN
            INSERT INTO bicycle (identifier, bicycle_type, maintenance_state, placement)
            VALUES (v_prefix || '-unprivileged-baseline', 'regular', 'serviceable', 'active_rental');
        EXCEPTION WHEN check_violation THEN
            v_denied := true;
        END;
        EXECUTE format('SET SESSION AUTHORIZATION %I', v_original_session);
        PERFORM set_config('bicycle_rental.privileged_setup', 'false', true);
        PERFORM pg_temp.assert_true(v_denied, 'setup flag alone cannot authorize an ordinary login to import rental placement');
    END IF;
    SET CONSTRAINTS ALL IMMEDIATE;
END $$;

SELECT count(*) AS fleet_station_assertions_passed FROM fleet_test_results;

ROLLBACK;

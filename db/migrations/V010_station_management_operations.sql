-- V010: Station and bicycle management operations.
--
-- Requirements: F-017..F-021, F-026, F-028, F-031, F-032, F-033, F-035, F-036, F-037,
--               F-069, F-071, F-072, F-075.
-- Style follows V006: SECURITY DEFINER, fixed search_path, acting account passed as p_actor_id.
-- Error codes: 42501 not permitted, 22023 invalid input, 23505 duplicate identifier, P0002 not found.
-- Tables, keys, checks and unique indexes already exist from V007-V009.

SET LOCAL search_path = bicycle_rental, public;

-- =====================================================================
-- Helpers and the shared rental-eligibility view
-- =====================================================================

-- Any authenticated account (rider or staff), used by read operations (F-015).
CREATE FUNCTION bicycle_rental.require_account(p_actor_id bigint)
RETURNS void
LANGUAGE plpgsql STABLE
SET search_path = bicycle_rental, public, pg_temp
AS $$
BEGIN
    IF p_actor_id IS NULL
       OR NOT EXISTS (SELECT 1 FROM account a WHERE a.account_id = p_actor_id) THEN
        RAISE EXCEPTION 'operation not permitted' USING ERRCODE = '42501';
    END IF;
END $$;

-- Single definition of "rentable" (F-036 / F-040): at a station, serviceable, station
-- rental-enabled, and for electric bicycles a battery reading of at least 20%.
-- Availability uses it now; rental start should use it later so the rules cannot drift apart.
CREATE VIEW bicycle_rental.v_rentable_bicycle AS
SELECT b.bicycle_id,
       b.bicycle_type,
       b.current_station_id AS station_id
  FROM bicycle_rental.bicycle b
  JOIN bicycle_rental.station s
    ON s.station_id = b.current_station_id
  LEFT JOIN bicycle_rental.electric_bicycle eb
    ON eb.bicycle_id = b.bicycle_id
 WHERE b.placement = 'station'
   AND b.maintenance_state = 'serviceable'
   AND s.rental_enabled
   AND (b.bicycle_type = 'regular' OR eb.battery_percentage >= 20);

-- =====================================================================
-- Stations
-- =====================================================================

-- F-020: explicit values for every field, including both controls. Audited (F-071).
CREATE FUNCTION bicycle_rental.create_station(
    p_actor_id bigint, p_name text, p_address text,
    p_latitude numeric, p_longitude numeric,
    p_rental_enabled boolean, p_return_enabled boolean)
RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = bicycle_rental, public, pg_temp
AS $$
DECLARE
    v_name    text    := trim_ws(coalesce(p_name, ''));
    v_address text    := trim_ws(coalesce(p_address, ''));
    v_lat     numeric := round(p_latitude, 7);
    v_lon     numeric := round(p_longitude, 7);
    v_id      bigint;
BEGIN
    PERFORM require_staff(p_actor_id);

    IF v_name = '' THEN
        RAISE EXCEPTION 'station name is required' USING ERRCODE = '22023';
    END IF;
    IF v_address = '' THEN
        RAISE EXCEPTION 'station address is required' USING ERRCODE = '22023';
    END IF;
    IF v_lat IS NULL OR v_lat NOT BETWEEN -90 AND 90 THEN
        RAISE EXCEPTION 'latitude must be between -90 and 90' USING ERRCODE = '22023';
    END IF;
    IF v_lon IS NULL OR v_lon NOT BETWEEN -180 AND 180 THEN
        RAISE EXCEPTION 'longitude must be between -180 and 180' USING ERRCODE = '22023';
    END IF;
    IF p_rental_enabled IS NULL OR p_return_enabled IS NULL THEN
        RAISE EXCEPTION 'rental_enabled and return_enabled must both be supplied' USING ERRCODE = '22023';
    END IF;

    INSERT INTO station (name, address, latitude, longitude, rental_enabled, return_enabled)
    VALUES (v_name, v_address, v_lat, v_lon, p_rental_enabled, p_return_enabled)
    RETURNING station_id INTO v_id;

    PERFORM record_audit_event(p_actor_id, 'station_create', 'Station', v_id, jsonb_build_array(
        audit_detail_json('Station', v_id, 'name',           NULL::text,    v_name),
        audit_detail_json('Station', v_id, 'address',        NULL::text,    v_address),
        audit_detail_json('Station', v_id, 'latitude',       NULL::numeric, v_lat),
        audit_detail_json('Station', v_id, 'longitude',      NULL::numeric, v_lon),
        audit_detail_json('Station', v_id, 'rental_enabled', NULL::boolean, p_rental_enabled),
        audit_detail_json('Station', v_id, 'return_enabled', NULL::boolean, p_return_enabled)));
    RETURN v_id;
END $$;

-- F-021: NULL means "leave unchanged". Returns true when something changed.
-- A no-op update writes no audit entry (F-069); otherwise exactly one entry lists all changes.
CREATE FUNCTION bicycle_rental.update_station(
    p_actor_id bigint, p_station_id bigint,
    p_name text DEFAULT NULL, p_address text DEFAULT NULL,
    p_latitude numeric DEFAULT NULL, p_longitude numeric DEFAULT NULL,
    p_rental_enabled boolean DEFAULT NULL, p_return_enabled boolean DEFAULT NULL)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = bicycle_rental, public, pg_temp
AS $$
DECLARE
    v_old     station%ROWTYPE;
    v_name    text;
    v_address text;
    v_lat     numeric;
    v_lon     numeric;
    v_rental  boolean;
    v_return  boolean;
    v_details jsonb := '[]'::jsonb;
BEGIN
    PERFORM require_staff(p_actor_id);

    SELECT * INTO v_old FROM station WHERE station_id = p_station_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'station % not found', p_station_id USING ERRCODE = 'P0002';
    END IF;

    v_name    := CASE WHEN p_name    IS NULL THEN v_old.name    ELSE trim_ws(p_name)    END;
    v_address := CASE WHEN p_address IS NULL THEN v_old.address ELSE trim_ws(p_address) END;
    v_lat     := coalesce(round(p_latitude, 7),  v_old.latitude);
    v_lon     := coalesce(round(p_longitude, 7), v_old.longitude);
    v_rental  := coalesce(p_rental_enabled, v_old.rental_enabled);
    v_return  := coalesce(p_return_enabled, v_old.return_enabled);

    IF v_name = '' THEN
        RAISE EXCEPTION 'station name cannot be blank' USING ERRCODE = '22023';
    END IF;
    IF v_address = '' THEN
        RAISE EXCEPTION 'station address cannot be blank' USING ERRCODE = '22023';
    END IF;
    IF v_lat NOT BETWEEN -90 AND 90 THEN
        RAISE EXCEPTION 'latitude must be between -90 and 90' USING ERRCODE = '22023';
    END IF;
    IF v_lon NOT BETWEEN -180 AND 180 THEN
        RAISE EXCEPTION 'longitude must be between -180 and 180' USING ERRCODE = '22023';
    END IF;

    IF v_name IS DISTINCT FROM v_old.name THEN
        v_details := v_details || audit_detail_json('Station', p_station_id, 'name', v_old.name::text, v_name);
    END IF;
    IF v_address IS DISTINCT FROM v_old.address THEN
        v_details := v_details || audit_detail_json('Station', p_station_id, 'address', v_old.address::text, v_address);
    END IF;
    IF v_lat IS DISTINCT FROM v_old.latitude THEN
        v_details := v_details || audit_detail_json('Station', p_station_id, 'latitude', v_old.latitude::numeric, v_lat);
    END IF;
    IF v_lon IS DISTINCT FROM v_old.longitude THEN
        v_details := v_details || audit_detail_json('Station', p_station_id, 'longitude', v_old.longitude::numeric, v_lon);
    END IF;
    IF v_rental IS DISTINCT FROM v_old.rental_enabled THEN
        v_details := v_details || audit_detail_json('Station', p_station_id, 'rental_enabled', v_old.rental_enabled, v_rental);
    END IF;
    IF v_return IS DISTINCT FROM v_old.return_enabled THEN
        v_details := v_details || audit_detail_json('Station', p_station_id, 'return_enabled', v_old.return_enabled, v_return);
    END IF;

    IF jsonb_array_length(v_details) = 0 THEN
        RETURN false;                      -- no-op: no change, no audit entry
    END IF;

    UPDATE station
       SET name = v_name, address = v_address, latitude = v_lat, longitude = v_lon,
           rental_enabled = v_rental, return_enabled = v_return
     WHERE station_id = p_station_id;

    PERFORM record_audit_event(p_actor_id, 'station_update', 'Station', p_station_id, v_details);
    RETURN true;
END $$;

-- F-018 / F-021: change only the rental and/or return controls. NULL leaves a control unchanged.
-- Delegates to update_station, so it is audited the same way (one entry, changed controls only).
CREATE FUNCTION bicycle_rental.set_station_controls(
    p_actor_id bigint, p_station_id bigint,
    p_rental_enabled boolean DEFAULT NULL, p_return_enabled boolean DEFAULT NULL)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = bicycle_rental, public, pg_temp
AS $$
BEGIN
    RETURN update_station(p_actor_id, p_station_id,
                          p_rental_enabled => p_rental_enabled,
                          p_return_enabled => p_return_enabled);
END $$;

-- F-019 / F-036 / F-037: station listing with controls and availability counts, any authenticated
-- account. One statement, so it reads one committed snapshot. Empty and disabled stations are kept.
CREATE FUNCTION bicycle_rental.get_station_availability(
    p_actor_id bigint, p_station_id bigint DEFAULT NULL)
RETURNS TABLE (station_id bigint, name text, address text,
               latitude numeric, longitude numeric,
               rental_enabled boolean, return_enabled boolean,
               regular_available integer, electric_available integer)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = bicycle_rental, public, pg_temp
AS $$
BEGIN
    PERFORM require_account(p_actor_id);
    RETURN QUERY
    SELECT s.station_id,
           s.name::text,
           s.address::text,
           s.latitude::numeric,
           s.longitude::numeric,
           s.rental_enabled,
           s.return_enabled,
           (count(*) FILTER (WHERE r.bicycle_type = 'regular'))::integer,
           (count(*) FILTER (WHERE r.bicycle_type = 'electric'))::integer
      FROM station s
      LEFT JOIN v_rentable_bicycle r ON r.station_id = s.station_id
     WHERE p_station_id IS NULL OR s.station_id = p_station_id
     GROUP BY s.station_id
     ORDER BY s.station_id;
END $$;

-- =====================================================================
-- Bicycles, maintenance state and batteries
-- =====================================================================

-- F-026: creates a bicycle at an existing station. Electric bicycles get their subtype row in
-- the same transaction, which satisfies the deferred subtype trigger from V009.
-- Not audited: F-071 excludes bicycle creation.
CREATE FUNCTION bicycle_rental.create_bicycle(
    p_actor_id bigint, p_identifier text,
    p_bicycle_type bicycle_rental.bicycle_type,
    p_maintenance_state bicycle_rental.maintenance_state,
    p_station_id bigint,
    p_battery_percentage numeric DEFAULT NULL)
RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = bicycle_rental, public, pg_temp
AS $$
DECLARE
    v_identifier text := trim_ws(coalesce(p_identifier, ''));
    v_id         bigint;
BEGIN
    PERFORM require_staff(p_actor_id);

    IF v_identifier = '' THEN
        RAISE EXCEPTION 'bicycle identifier is required' USING ERRCODE = '22023';
    END IF;
    IF p_bicycle_type IS NULL OR p_maintenance_state IS NULL THEN
        RAISE EXCEPTION 'bicycle type and maintenance state are required' USING ERRCODE = '22023';
    END IF;

    PERFORM 1 FROM station WHERE station_id = p_station_id FOR SHARE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'station % does not exist', p_station_id USING ERRCODE = '22023';
    END IF;

    IF p_bicycle_type = 'regular' AND p_battery_percentage IS NOT NULL THEN
        RAISE EXCEPTION 'regular bicycles cannot have a battery reading' USING ERRCODE = '22023';
    END IF;
    IF p_battery_percentage IS NOT NULL
       AND (p_battery_percentage <> trunc(p_battery_percentage)
            OR p_battery_percentage NOT BETWEEN 0 AND 100) THEN
        RAISE EXCEPTION 'battery percentage must be an integer from 0 to 100' USING ERRCODE = '22023';
    END IF;

    INSERT INTO bicycle (identifier, bicycle_type, maintenance_state, placement, current_station_id)
    VALUES (v_identifier, p_bicycle_type, p_maintenance_state, 'station', p_station_id)
    RETURNING bicycle_id INTO v_id;

    IF p_bicycle_type = 'electric' THEN
        INSERT INTO electric_bicycle (bicycle_id, battery_percentage, bicycle_type)
        VALUES (v_id, p_battery_percentage::smallint, 'electric');
    END IF;

    RETURN v_id;
EXCEPTION
    WHEN unique_violation THEN
        RAISE EXCEPTION 'bicycle identifier is already registered' USING ERRCODE = '23505';
END $$;

-- F-031: change maintenance state at any placement (also during a rental). Returns true if changed.
-- No-op => no change and no audit entry. Placement and station are unchanged context values (F-072).
CREATE FUNCTION bicycle_rental.set_maintenance_state(
    p_actor_id bigint, p_bicycle_id bigint,
    p_maintenance_state bicycle_rental.maintenance_state)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = bicycle_rental, public, pg_temp
AS $$
DECLARE
    v_b bicycle%ROWTYPE;
BEGIN
    PERFORM require_staff(p_actor_id);
    IF p_maintenance_state IS NULL THEN
        RAISE EXCEPTION 'maintenance state must be supplied' USING ERRCODE = '22023';
    END IF;

    SELECT * INTO v_b FROM bicycle WHERE bicycle_id = p_bicycle_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'bicycle % not found', p_bicycle_id USING ERRCODE = 'P0002';
    END IF;

    IF v_b.maintenance_state = p_maintenance_state THEN
        RETURN false;
    END IF;

    UPDATE bicycle SET maintenance_state = p_maintenance_state WHERE bicycle_id = p_bicycle_id;

    PERFORM record_audit_event(p_actor_id, 'maintenance_state_update', 'Bicycle', p_bicycle_id, jsonb_build_array(
        audit_detail_json('Bicycle', p_bicycle_id, 'maintenance_state',  v_b.maintenance_state::text, p_maintenance_state::text),
        audit_detail_json('Bicycle', p_bicycle_id, 'placement',          v_b.placement::text,         v_b.placement::text),
        audit_detail_json('Bicycle', p_bicycle_id, 'current_station_id', v_b.current_station_id,      v_b.current_station_id)));
    RETURN true;
END $$;

-- Core battery write, shared by update_battery and import_battery_readings (internal, no actor check).
-- Returns a result code instead of raising, so the import can report per record.
CREATE FUNCTION bicycle_rental.apply_battery_reading(p_bicycle_id bigint, p_value jsonb)
RETURNS text
LANGUAGE plpgsql
SET search_path = bicycle_rental, public, pg_temp
AS $$
DECLARE
    v_num numeric;
BEGIN
    IF p_value IS NULL OR jsonb_typeof(p_value) <> 'number' THEN
        RETURN 'invalid_value';                      -- missing / null / non-numeric (F-035: cannot clear)
    END IF;
    v_num := (p_value #>> '{}')::numeric;
    IF v_num <> trunc(v_num) OR v_num NOT BETWEEN 0 AND 100 THEN
        RETURN 'invalid_value';                      -- fractional or out of range (F-032)
    END IF;

    PERFORM 1 FROM electric_bicycle WHERE bicycle_id = p_bicycle_id FOR UPDATE;
    IF NOT FOUND THEN
        IF EXISTS (SELECT 1 FROM bicycle b WHERE b.bicycle_id = p_bicycle_id) THEN
            RETURN 'not_electric';
        END IF;
        RETURN 'unknown_bicycle';
    END IF;

    UPDATE electric_bicycle SET battery_percentage = v_num::smallint WHERE bicycle_id = p_bicycle_id;
    RETURN 'applied';
END $$;

-- Single battery update; raises on any rejection. Not audited (F-071).
CREATE FUNCTION bicycle_rental.update_battery(
    p_actor_id bigint, p_bicycle_id bigint, p_battery numeric)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = bicycle_rental, public, pg_temp
AS $$
DECLARE
    v_result text;
BEGIN
    PERFORM require_staff(p_actor_id);
    v_result := apply_battery_reading(p_bicycle_id, to_jsonb(p_battery));

    IF v_result = 'unknown_bicycle' THEN
        RAISE EXCEPTION 'bicycle % not found', p_bicycle_id USING ERRCODE = 'P0002';
    ELSIF v_result = 'not_electric' THEN
        RAISE EXCEPTION 'bicycle % is not electric', p_bicycle_id USING ERRCODE = '22023';
    ELSIF v_result = 'invalid_value' THEN
        RAISE EXCEPTION 'battery percentage must be an integer from 0 to 100' USING ERRCODE = '22023';
    END IF;
END $$;

-- F-033: p_records = [{"bicycle_id": 1, "battery_percentage": 80}, ...]
-- Each record is accepted or rejected on its own and gets an explicit result. Records are processed
-- in array order, so for duplicate bicycles the LAST valid record wins (documented order).
CREATE FUNCTION bicycle_rental.import_battery_readings(p_actor_id bigint, p_records jsonb)
RETURNS TABLE (record_no integer, bicycle_ref bigint, result text)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = bicycle_rental, public, pg_temp
AS $$
DECLARE
    v_rec    jsonb;
    v_idx    integer;
    v_id     bigint;
    v_result text;
BEGIN
    PERFORM require_staff(p_actor_id);
    IF p_records IS NULL OR jsonb_typeof(p_records) <> 'array' THEN
        RAISE EXCEPTION 'p_records must be a JSON array' USING ERRCODE = '22023';
    END IF;

    FOR v_rec, v_idx IN
        SELECT e, ord::integer FROM jsonb_array_elements(p_records) WITH ORDINALITY AS t(e, ord)
    LOOP
        v_id := NULL;
        BEGIN                                -- sub-transaction: one bad record cannot affect others
            IF jsonb_typeof(v_rec) <> 'object'
               OR coalesce(jsonb_typeof(v_rec -> 'bicycle_id'), '') <> 'number' THEN
                v_result := 'invalid_record';
            ELSE
                v_id     := (v_rec ->> 'bicycle_id')::bigint;
                v_result := apply_battery_reading(v_id, v_rec -> 'battery_percentage');
            END IF;
        EXCEPTION WHEN others THEN
            v_result := 'invalid_record';
        END;
        RETURN QUERY SELECT v_idx, v_id, v_result;
    END LOOP;
END $$;
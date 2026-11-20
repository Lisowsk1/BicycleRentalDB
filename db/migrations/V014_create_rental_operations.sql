-- V014: Rental lifecycle operations (eligibility, start, returns, pricing, lookups).
-- Tables, constraints and the placement/rental sync trigger exist from V008..V012.
--
-- Error codes:
--   42501  actor not permitted (not a rider / not staff)
--   22023  invalid input (unknown destination, stale pricing terms)
--   P0002  rental or bicycle not found (also another rider's rental: no disclosure)
--   55000  business rule (rider blocked or renting, bicycle not rentable, return-disabled station)
--   RT409  completed rental retried with a different destination
--
-- Assumes READ COMMITTED. Lock order: rider, rental, bicycle, station, battery.

SET LOCAL search_path = bicycle_rental, public;

-- =====================================================================
-- Helpers
-- =====================================================================

-- The actor must be a rider; staff cannot start or return as a rider (F-039, F-035).
CREATE FUNCTION bicycle_rental.require_rider(p_actor_id bigint)
RETURNS void
LANGUAGE plpgsql STABLE
SET search_path = bicycle_rental, public, pg_temp
AS $$
BEGIN
    IF p_actor_id IS NULL OR NOT EXISTS (SELECT 1 FROM rider r WHERE r.account_id = p_actor_id) THEN
        RAISE EXCEPTION 'operation not permitted' USING ERRCODE = '42501';
    END IF;
END $$;

-- Returns NULL when eligible. Pure read: callers that must act on the answer lock the rows first
-- (start_rental) so the answer cannot change before commit.
CREATE FUNCTION bicycle_rental.rental_start_blocker(p_rider_id bigint, p_bicycle_id bigint)
RETURNS text
LANGUAGE plpgsql STABLE
SET search_path = bicycle_rental, public, pg_temp
AS $$
DECLARE
    v_status    rider_status;
    v_b         bicycle%ROWTYPE;
    v_enabled   boolean;
    v_battery   smallint;
BEGIN
    SELECT r.status INTO v_status FROM rider r WHERE r.account_id = p_rider_id;
    IF NOT FOUND THEN
        RETURN 'rider_not_found';
    END IF;
    IF v_status <> 'active' THEN
        RETURN 'rider_blocked';
    END IF;
    IF EXISTS (SELECT 1 FROM rental x WHERE x.rider_id = p_rider_id AND x.end_time IS NULL) THEN
        RETURN 'rider_has_active_rental';
    END IF;

    SELECT * INTO v_b FROM bicycle b WHERE b.bicycle_id = p_bicycle_id;
    IF NOT FOUND THEN
        RETURN 'bicycle_not_found';
    END IF;
    IF v_b.placement = 'active_rental' OR EXISTS (SELECT 1 FROM rental x WHERE x.bicycle_id = p_bicycle_id AND x.end_time IS NULL) THEN
        RETURN 'bicycle_has_active_rental';
    END IF;
    IF v_b.placement <> 'station' THEN
        RETURN 'bicycle_not_at_station';
    END IF;
    IF v_b.maintenance_state <> 'serviceable' THEN
        RETURN 'bicycle_unavailable_for_maintenance';
    END IF;

    SELECT s.rental_enabled INTO v_enabled FROM station s WHERE s.station_id = v_b.current_station_id;
    IF NOT FOUND OR NOT v_enabled THEN
        RETURN 'station_rental_disabled';
    END IF;

    IF v_b.bicycle_type = 'electric' THEN
        SELECT e.battery_percentage INTO v_battery FROM electric_bicycle e WHERE e.bicycle_id = p_bicycle_id;
        IF v_battery IS NULL THEN
            RETURN 'battery_reading_missing';
        END IF;
        IF v_battery < 20 THEN
            RETURN 'battery_below_20_percent';
        END IF;
    END IF;
    RETURN NULL;
END $$;


-- The numeric(12,2) result raises 22003 on overflow. Pure, so it can be tested at exact boundaries.
CREATE FUNCTION bicycle_rental.calculate_rental_charge(
    p_start timestamptz, p_end timestamptz, p_block_length_seconds integer, p_price_per_block numeric)
RETURNS numeric
LANGUAGE sql IMMUTABLE
AS $$
    SELECT (CASE WHEN d.micros = 0 THEN 0::bigint
                 ELSE (d.micros + b.block_us - 1) / b.block_us END * p_price_per_block)::numeric(12, 2)
      FROM (SELECT (extract(epoch FROM (p_end - p_start)) * 1000000)::bigint AS micros) d,
           (SELECT p_block_length_seconds::bigint * 1000000 AS block_us) b
$$;

-- Result shape shared by rental lookups and returns.
CREATE TYPE bicycle_rental.rental_details AS (
    rental_id            bigint,
    rider_id             bigint,
    bicycle_id           bigint,
    bicycle_identifier   text,
    bicycle_type         bicycle_rental.bicycle_type,
    pickup_station_id    bigint,
    pickup_station_name  text,
    return_station_id    bigint,
    return_station_name  text,
    start_time           timestamptz,
    end_time             timestamptz,
    state                text,              -- 'active' or 'completed' (F-046)
    price_per_block      numeric,
    block_length_seconds integer,
    currency             text,
    final_charge         numeric,
    returned_by_staff    boolean            -- true when the first completion was staff-assisted (F-080, F-082)
);

CREATE FUNCTION bicycle_rental.rental_details_for(p_rental_id bigint)
RETURNS bicycle_rental.rental_details
LANGUAGE sql STABLE
SET search_path = bicycle_rental, public, pg_temp
AS $$
    SELECT r.rental_id, r.rider_id, r.bicycle_id, b.identifier::text, r.bicycle_type,
           r.pickup_station_id, ps.name::text, r.return_station_id, rs.name::text,
           r.start_time, r.end_time,
           CASE WHEN r.end_time IS NULL THEN 'active' ELSE 'completed' END,
           r.captured_price_per_block, r.captured_block_length_seconds, r.captured_currency::text,
           r.final_charge, r.returned_by_staff_id IS NOT NULL
      FROM rental r
      JOIN bicycle b ON b.bicycle_id = r.bicycle_id
      JOIN station ps ON ps.station_id = r.pickup_station_id
      LEFT JOIN station rs ON rs.station_id = r.return_station_id
     WHERE r.rental_id = p_rental_id
$$;

-- =====================================================================
-- Eligibility check (read-only, does not reserve anything)
-- =====================================================================

CREATE FUNCTION bicycle_rental.check_rental_eligibility(p_actor_id bigint, p_bicycle_id bigint)
RETURNS TABLE (eligible boolean, reason text)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = bicycle_rental, public, pg_temp
AS $$
DECLARE
    v_reason text;
BEGIN
    PERFORM require_rider(p_actor_id);
    v_reason := rental_start_blocker(p_actor_id, p_bicycle_id);
    RETURN QUERY SELECT v_reason IS NULL, v_reason;
END $$;

-- =====================================================================
-- Rental start (F-039..F-042, F-053, F-056, F-112, R-001, R-003)
-- =====================================================================

-- p_expected_tariff_id: the tariff the rider was shown (F-056). NULL accepts the current terms.
-- A repeated start by a rider who already rents is rejected like any second start (F-041);
-- get_active_rental recovers the state after an uncertain response (F-049).
CREATE FUNCTION bicycle_rental.start_rental(
    p_actor_id bigint, p_bicycle_id bigint, p_expected_tariff_id bigint DEFAULT NULL)
RETURNS bicycle_rental.rental_details
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = bicycle_rental, public, pg_temp
AS $$
DECLARE
    v_b         bicycle%ROWTYPE;
    v_tariff    tariff%ROWTYPE;
    v_reason    text;
    v_rental_id bigint;
BEGIN
    PERFORM require_rider(p_actor_id);

    -- 1. Lock the rider row: serializes this rider's starts with each other and with blocking.
    PERFORM 1 FROM rider r WHERE r.account_id = p_actor_id FOR UPDATE;

    -- 2. Lock the bicycle row: serializes against competing starts, maintenance, transfers.
    SELECT * INTO v_b FROM bicycle b WHERE b.bicycle_id = p_bicycle_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'bicycle % not found', p_bicycle_id USING ERRCODE = 'P0002';
    END IF;

    -- 3. Lock the pickup station and battery rows so station controls and battery updates
    --    ordered before this start are visible, and later ones wait for it (R-006).
    IF v_b.current_station_id IS NOT NULL THEN
        PERFORM 1 FROM station s WHERE s.station_id = v_b.current_station_id FOR SHARE;
    END IF;
    IF v_b.bicycle_type = 'electric' THEN
        PERFORM 1 FROM electric_bicycle e WHERE e.bicycle_id = p_bicycle_id FOR SHARE;
    END IF;

    -- 4. Re-validate everything against the now-locked, committed state (F-039, F-040, F-041).
    v_reason := rental_start_blocker(p_actor_id, p_bicycle_id);
    IF v_reason IS NOT NULL THEN
        RAISE EXCEPTION 'rental cannot start: %', v_reason USING ERRCODE = '55000';
    END IF;

    -- 5. Pricing snapshot from the active tariff of the bicycle's type (F-053, F-112).
    SELECT * INTO v_tariff FROM tariff t WHERE t.bicycle_type = v_b.bicycle_type AND t.is_active FOR SHARE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'rental cannot start: no active tariff for % bicycles', v_b.bicycle_type
            USING ERRCODE = '55000';
    END IF;
    IF p_expected_tariff_id IS NOT NULL AND p_expected_tariff_id <> v_tariff.tariff_id THEN
        RAISE EXCEPTION 'displayed pricing terms are stale; refresh and retry' USING ERRCODE = '22023';
    END IF;

    -- 6. Rental row and placement change in one transaction (R-001). The unique indexes are the
    --    last line of defence; the locks above mean they should never fire.
    BEGIN
        INSERT INTO rental (rider_id, bicycle_id, pickup_station_id, tariff_id, start_time,
                            captured_price_per_block, captured_block_length_seconds, captured_currency,
                            bicycle_type)
        VALUES (p_actor_id, p_bicycle_id, v_b.current_station_id, v_tariff.tariff_id, clock_timestamp(),
                v_tariff.price_per_block, v_tariff.block_length_seconds, v_tariff.currency,
                v_b.bicycle_type)
        RETURNING rental_id INTO v_rental_id;

        UPDATE bicycle SET placement = 'active_rental', current_station_id = NULL
         WHERE bicycle_id = p_bicycle_id;
    EXCEPTION WHEN unique_violation THEN
        RAISE EXCEPTION 'rental cannot start: rider or bicycle already has an active rental'
            USING ERRCODE = '55000';
    END;

    RETURN rental_details_for(v_rental_id);
END $$;

-- =====================================================================
-- Return completion shared by riders and staff (F-043..F-045, F-054, F-055, F-078..F-081, R-002)
-- =====================================================================

-- p_staff_id is NULL for a rider-initiated return. Authorization is done by the callers.
-- Returns the stored rental details; the second column is true when this call completed the rental
-- and false when it reported an earlier completion (retry).
CREATE FUNCTION bicycle_rental.complete_rental_internal(
    p_rental_id bigint, p_station_id bigint, p_staff_id bigint, p_rider_filter bigint)
RETURNS TABLE (details bicycle_rental.rental_details, completed_now boolean)
LANGUAGE plpgsql
SET search_path = bicycle_rental, public, pg_temp
AS $$
DECLARE
    v_r        rental%ROWTYPE;
    v_b        bicycle%ROWTYPE;
    v_return_enabled boolean;
    v_end      timestamptz;
    v_charge   numeric(12, 2);
BEGIN
    -- Lock the rental first: concurrent returns of the same rental queue here (R-006, F-079).
    SELECT * INTO v_r FROM rental r WHERE r.rental_id = p_rental_id FOR UPDATE;
    -- Unknown rental and another rider's rental look identical: no disclosure (F-035).
    IF NOT FOUND OR (p_rider_filter IS NOT NULL AND v_r.rider_id <> p_rider_filter) THEN
        RAISE EXCEPTION 'rental % not found', p_rental_id USING ERRCODE = 'P0002';
    END IF;

    -- Retry of a completed rental: same destination reports the original completion, different
    -- destination is a conflict. Nothing is modified, audited, or rechecked (F-045, F-079).
    IF v_r.end_time IS NOT NULL THEN
        IF v_r.return_station_id IS DISTINCT FROM p_station_id THEN
            RAISE EXCEPTION 'rental % was already completed at a different station', p_rental_id
                USING ERRCODE = 'RT409';
        END IF;
        RETURN QUERY SELECT rental_details_for(p_rental_id), false;
        RETURN;
    END IF;

    -- Active rental: bicycle row next, then the destination station (F-043).
    SELECT * INTO v_b FROM bicycle b WHERE b.bicycle_id = v_r.bicycle_id FOR UPDATE;
    IF v_b.placement <> 'active_rental' THEN
        RAISE EXCEPTION 'bicycle % placement (%) is inconsistent with active rental %',
            v_b.bicycle_id, v_b.placement, p_rental_id USING ERRCODE = '55000';
    END IF;

    IF p_station_id IS NULL THEN
        RAISE EXCEPTION 'return station must be supplied' USING ERRCODE = '22023';
    END IF;
    SELECT s.return_enabled INTO v_return_enabled FROM station s WHERE s.station_id = p_station_id FOR SHARE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'return station % does not exist', p_station_id USING ERRCODE = '22023';
    END IF;
    IF NOT v_return_enabled THEN
        RAISE EXCEPTION 'return station % does not accept returns', p_station_id USING ERRCODE = '55000';
    END IF;

    -- Server-assigned end time and charge from the captured pricing (F-047, F-054, F-055).
    v_end      := greatest(clock_timestamp(), v_r.start_time);
    v_charge   := calculate_rental_charge(v_r.start_time, v_end,
                      v_r.captured_block_length_seconds, v_r.captured_price_per_block);  -- 22003 on overflow

    UPDATE rental
       SET end_time = v_end, return_station_id = p_station_id,
           final_charge = v_charge, returned_by_staff_id = p_staff_id
     WHERE rental_id = p_rental_id;

    -- The bicycle keeps its maintenance state (F-044).
    UPDATE bicycle SET placement = 'station', current_station_id = p_station_id
     WHERE bicycle_id = v_r.bicycle_id;

    -- Exactly one audit entry for a first successful staff-assisted return, in this transaction (F-081).
    IF p_staff_id IS NOT NULL THEN
        PERFORM record_audit_event(p_staff_id, 'staff_return', 'Rental', p_rental_id, jsonb_build_array(
            audit_detail_json('Rental',  p_rental_id,     'rider_id',             v_r.rider_id, v_r.rider_id),
            audit_detail_json('Rental',  p_rental_id,     'bicycle_id',           v_r.bicycle_id, v_r.bicycle_id),
            audit_detail_json('Rental',  p_rental_id,     'return_station_id',    NULL::bigint, p_station_id),
            audit_detail_json('Rental',  p_rental_id,     'end_time',             NULL::timestamptz, v_end),
            audit_detail_json('Rental',  p_rental_id,     'final_charge',         NULL::numeric, v_charge),
            audit_detail_json('Rental',  p_rental_id,     'returned_by_staff_id', NULL::bigint, p_staff_id),
            audit_detail_json('Bicycle', v_r.bicycle_id,  'placement',            v_b.placement::text, 'station'::text),
            audit_detail_json('Bicycle', v_r.bicycle_id,  'current_station_id',   v_b.current_station_id, p_station_id)));
    END IF;

    RETURN QUERY SELECT rental_details_for(p_rental_id), true;
END $$;

-- Rider-initiated return of the rider's own rental (F-043..F-045).
CREATE FUNCTION bicycle_rental.return_rental(p_actor_id bigint, p_rental_id bigint, p_station_id bigint)
RETURNS TABLE (details bicycle_rental.rental_details, completed_now boolean)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = bicycle_rental, public, pg_temp
AS $$
BEGIN
    PERFORM require_rider(p_actor_id);
    RETURN QUERY SELECT * FROM complete_rental_internal(p_rental_id, p_station_id, NULL, p_actor_id);
END $$;

-- Staff-assisted return on behalf of the owning rider (F-078..F-081). Same rules as a rider return.
CREATE FUNCTION bicycle_rental.staff_return_rental(p_actor_id bigint, p_rental_id bigint, p_station_id bigint)
RETURNS TABLE (details bicycle_rental.rental_details, completed_now boolean)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = bicycle_rental, public, pg_temp
AS $$
BEGIN
    PERFORM require_staff(p_actor_id);
    RETURN QUERY SELECT * FROM complete_rental_internal(p_rental_id, p_station_id, p_actor_id, NULL);
END $$;

-- =====================================================================
-- Lookups (F-048, F-049, F-082)
-- =====================================================================

-- The rider's current active rental, or no row (F-049).
CREATE FUNCTION bicycle_rental.get_active_rental(p_actor_id bigint)
RETURNS SETOF bicycle_rental.rental_details
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = bicycle_rental, public, pg_temp
AS $$
BEGIN
    PERFORM require_rider(p_actor_id);
    RETURN QUERY
    SELECT (rental_details_for(r.rental_id)).*
      FROM rental r
     WHERE r.rider_id = p_actor_id AND r.end_time IS NULL;
END $$;

-- The rider's own rentals, newest first; empty when there is none (F-048).
-- Paged: at most p_limit rows (1..200), skipping p_offset.
CREATE FUNCTION bicycle_rental.get_rental_history(
    p_actor_id bigint,
    p_limit    integer DEFAULT 50,
    p_offset   integer DEFAULT 0)
RETURNS SETOF bicycle_rental.rental_details
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = bicycle_rental, public, pg_temp
AS $$
BEGIN
    PERFORM require_rider(p_actor_id);
    IF p_limit IS NULL OR p_limit NOT BETWEEN 1 AND 200
       OR p_offset IS NULL OR p_offset < 0 THEN
        RAISE EXCEPTION 'limit must be 1..200 and offset must not be negative'
            USING ERRCODE = '22023';
    END IF;
    RETURN QUERY
    SELECT (rental_details_for(r.rental_id)).*
      FROM rental r
     WHERE r.rider_id = p_actor_id
     ORDER BY r.start_time DESC, r.rental_id DESC
     LIMIT p_limit OFFSET p_offset;
END $$;

-- One rental by identity: the owning rider, or any staff member (F-082). Others get "not found".
CREATE FUNCTION bicycle_rental.get_rental(p_actor_id bigint, p_rental_id bigint)
RETURNS bicycle_rental.rental_details
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = bicycle_rental, public, pg_temp
AS $$
DECLARE
    v_owner bigint;
BEGIN
    PERFORM require_account(p_actor_id);
    SELECT r.rider_id INTO v_owner FROM rental r WHERE r.rental_id = p_rental_id;
    IF NOT FOUND
       OR (v_owner <> p_actor_id AND NOT EXISTS (SELECT 1 FROM staff s WHERE s.account_id = p_actor_id)) THEN
        RAISE EXCEPTION 'rental % not found', p_rental_id USING ERRCODE = 'P0002';
    END IF;
    RETURN rental_details_for(p_rental_id);
END $$;
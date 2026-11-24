-- V020: Bicycle transfers between stations and bicycle movement history.
--
-- Requirements: F-027, F-092, F-093, R-004, R-005 (transfers); F-076 (history through the audit log).
-- Handover to and return from maintenance already exist from V010 (F-029, F-030, F-094, F-095)
-- and are audited there. This migration adds the immutable BicycleTransfer table, the transfer
-- operation, and history queries over transfers and maintenance movements.
--
-- Error codes: 42501 not permitted, 22023 invalid input, P0002 bicycle not found,
--              55000 bicycle is not in a state that allows the move (wrong source, not at a station).
-- Assumes READ COMMITTED. Lock order is the same as the rental operations: bicycle, then station.

SET LOCAL search_path = bicycle_rental, public;

-- =====================================================================
-- Transfer records (F-092)
-- =====================================================================

CREATE TABLE bicycle_rental.bicycle_transfer (
    transfer_id           bigint GENERATED ALWAYS AS IDENTITY,
    bicycle_id            bigint NOT NULL,
    from_station_id       bigint NOT NULL,
    to_station_id         bigint NOT NULL,
    performed_by_staff_id bigint NOT NULL,
    transferred_at        timestamptz NOT NULL DEFAULT clock_timestamp(),
    reason                varchar(500),
    CONSTRAINT pk_bicycle_transfer PRIMARY KEY (transfer_id),
    -- Records are history: nothing they reference can be removed or re-keyed.
    CONSTRAINT fk_bicycle_transfer_bicycle FOREIGN KEY (bicycle_id)
        REFERENCES bicycle_rental.bicycle (bicycle_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT fk_bicycle_transfer_from_station FOREIGN KEY (from_station_id)
        REFERENCES bicycle_rental.station (station_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT fk_bicycle_transfer_to_station FOREIGN KEY (to_station_id)
        REFERENCES bicycle_rental.station (station_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT fk_bicycle_transfer_staff FOREIGN KEY (performed_by_staff_id)
        REFERENCES bicycle_rental.staff (account_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT ck_bicycle_transfer_distinct_stations CHECK (from_station_id <> to_station_id),
    CONSTRAINT ck_bicycle_transfer_reason_not_blank CHECK (reason IS NULL OR bicycle_rental.trim_ws(reason) <> '')
);

CREATE INDEX ix_bicycle_transfer_bicycle_time
    ON bicycle_rental.bicycle_transfer (bicycle_id, transferred_at, transfer_id);

-- Append-only (F-092). TRUNCATE is not blocked, so a full database reset still works.
CREATE FUNCTION bicycle_rental.trg_bicycle_transfer_immutable()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    RAISE EXCEPTION 'bicycle transfer records cannot be % operationally', lower(TG_OP) || 'd'
        USING ERRCODE = '23000';
END $$;

CREATE TRIGGER trg_bicycle_transfer_immutable
    BEFORE UPDATE OR DELETE ON bicycle_rental.bicycle_transfer
    FOR EACH ROW EXECUTE FUNCTION bicycle_rental.trg_bicycle_transfer_immutable();

-- A record may only be inserted for a bicycle that is at its source station right now (F-093).
-- Locks the bicycle row so the check holds until commit even for direct inserts.
CREATE FUNCTION bicycle_rental.trg_bicycle_transfer_check_source()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = bicycle_rental, public, pg_temp
AS $$
DECLARE
    v_b bicycle%ROWTYPE;
BEGIN
    SELECT * INTO v_b FROM bicycle b WHERE b.bicycle_id = NEW.bicycle_id FOR SHARE;
    IF NOT FOUND
       OR v_b.placement <> 'station'
       OR v_b.current_station_id IS DISTINCT FROM NEW.from_station_id THEN
        RAISE EXCEPTION 'transfer source must be the bicycle''s current station' USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER trg_bicycle_transfer_check_source
    BEFORE INSERT ON bicycle_rental.bicycle_transfer
    FOR EACH ROW EXECUTE FUNCTION bicycle_rental.trg_bicycle_transfer_check_source();

-- =====================================================================
-- Station transfer (F-027, F-092, F-093, R-004, R-005)
-- =====================================================================

-- A repeated request fails: after the move the source no longer matches, so nothing is added.
CREATE FUNCTION bicycle_rental.transfer_bicycle(
    p_actor_id bigint, p_bicycle_id bigint, p_from_station_id bigint, p_to_station_id bigint,
    p_reason text DEFAULT NULL)
RETURNS bicycle_rental.bicycle_transfer
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = bicycle_rental, public, pg_temp
AS $$
DECLARE
    v_b      bicycle%ROWTYPE;
    v_reason text;
    v_row    bicycle_transfer%ROWTYPE;
BEGIN
    PERFORM require_staff(p_actor_id);

    IF p_bicycle_id IS NULL OR p_from_station_id IS NULL OR p_to_station_id IS NULL THEN
        RAISE EXCEPTION 'bicycle, source station and destination station must be supplied' USING ERRCODE = '22023';
    END IF;
    IF p_from_station_id = p_to_station_id THEN
        RAISE EXCEPTION 'source and destination stations must differ' USING ERRCODE = '22023';
    END IF;
    v_reason := nullif(trim_ws(p_reason), '');
    IF length(v_reason) > 500 THEN
        RAISE EXCEPTION 'transfer reason is limited to 500 characters' USING ERRCODE = '22023';
    END IF;

    -- 1. Bicycle row first: serializes against rentals, handovers and other transfers.
    SELECT * INTO v_b FROM bicycle b WHERE b.bicycle_id = p_bicycle_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'bicycle % not found', p_bicycle_id USING ERRCODE = 'P0002';
    END IF;

    -- 2. Destination station must exist; the lock keeps it that way until commit.
    PERFORM 1 FROM station s WHERE s.station_id = p_to_station_id FOR SHARE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'destination station % does not exist', p_to_station_id USING ERRCODE = '22023';
    END IF;

    -- 3. Eligibility against the locked, committed state (F-027, F-093).
    IF v_b.placement <> 'station' THEN
        RAISE EXCEPTION 'only a bicycle at a station can be transferred (placement: %)', v_b.placement
            USING ERRCODE = '55000';
    END IF;
    IF v_b.current_station_id <> p_from_station_id THEN
        RAISE EXCEPTION 'bicycle % is not at station %', p_bicycle_id, p_from_station_id
            USING ERRCODE = '55000';
    END IF;

    -- 4. Record and move in one transaction (F-093). The insert comes first because its trigger
    --    checks the source against the bicycle's current station.
    INSERT INTO bicycle_transfer (bicycle_id, from_station_id, to_station_id,
                                  performed_by_staff_id, transferred_at, reason)
    VALUES (p_bicycle_id, p_from_station_id, p_to_station_id, p_actor_id, clock_timestamp(), v_reason)
    RETURNING * INTO v_row;

    UPDATE bicycle SET current_station_id = p_to_station_id WHERE bicycle_id = p_bicycle_id;

    RETURN v_row;
END $$;

-- =====================================================================
-- Movement history (staff only)
-- =====================================================================

-- Station transfers of one bicycle, newest first. An unknown bicycle is an error;
-- a bicycle that was never transferred gives an empty result.
CREATE FUNCTION bicycle_rental.get_bicycle_transfer_history(
    p_actor_id bigint, p_bicycle_id bigint, p_limit integer DEFAULT 50, p_offset integer DEFAULT 0)
RETURNS SETOF bicycle_rental.bicycle_transfer
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = bicycle_rental, public, pg_temp
AS $$
BEGIN
    PERFORM require_staff(p_actor_id);
    IF p_limit IS NULL OR p_limit NOT BETWEEN 1 AND 200
       OR p_offset IS NULL OR p_offset < 0 THEN
        RAISE EXCEPTION 'limit must be 1..200 and offset must not be negative' USING ERRCODE = '22023';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM bicycle b WHERE b.bicycle_id = p_bicycle_id) THEN
        RAISE EXCEPTION 'bicycle % not found', p_bicycle_id USING ERRCODE = 'P0002';
    END IF;
    RETURN QUERY
    SELECT t.*
      FROM bicycle_transfer t
     WHERE t.bicycle_id = p_bicycle_id
     ORDER BY t.transferred_at DESC, t.transfer_id DESC
     LIMIT p_limit OFFSET p_offset;
END $$;

-- Result row of the combined movement history.
CREATE TYPE bicycle_rental.bicycle_movement AS (
    movement_type            text,
    occurred_at              timestamptz,
    performed_by_staff_id    bigint,
    from_station_id          bigint,
    to_station_id            bigint,
    provider_id              bigint,
    maintenance_state_before text,
    maintenance_state_after  text,
    reason                   text,          -- transfers only
    record_id                bigint
);

-- Staff-performed movements of one bicycle, newest first: transfers from BicycleTransfer and
-- handovers and returns from the audit log (F-076 keeps no separate maintenance history).
-- Rentals are not included; they are in the rental history.
CREATE FUNCTION bicycle_rental.get_bicycle_movement_history(
    p_actor_id bigint, p_bicycle_id bigint, p_limit integer DEFAULT 50, p_offset integer DEFAULT 0)
RETURNS SETOF bicycle_rental.bicycle_movement
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = bicycle_rental, public, pg_temp
AS $$
BEGIN
    PERFORM require_staff(p_actor_id);
    IF p_limit IS NULL OR p_limit NOT BETWEEN 1 AND 200
       OR p_offset IS NULL OR p_offset < 0 THEN
        RAISE EXCEPTION 'limit must be 1..200 and offset must not be negative' USING ERRCODE = '22023';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM bicycle b WHERE b.bicycle_id = p_bicycle_id) THEN
        RAISE EXCEPTION 'bicycle % not found', p_bicycle_id USING ERRCODE = 'P0002';
    END IF;

    RETURN QUERY
    SELECT m.*
      FROM (
        SELECT 'station_transfer'::text, t.transferred_at, t.performed_by_staff_id,
               t.from_station_id, t.to_station_id, NULL::bigint,
               NULL::text, NULL::text, t.reason::text, t.transfer_id
          FROM bicycle_transfer t
         WHERE t.bicycle_id = p_bicycle_id
        UNION ALL
        SELECT e.action_type::text, e.created_at, e.staff_id,
               (SELECT (d.previous_value #>> '{}')::bigint FROM audit_detail d
                 WHERE d.audit_id = e.audit_id AND d.field_name = 'current_station_id'),
               (SELECT (d.new_value #>> '{}')::bigint FROM audit_detail d
                 WHERE d.audit_id = e.audit_id AND d.field_name = 'current_station_id'),
               (SELECT coalesce((d.new_value #>> '{}')::bigint, (d.previous_value #>> '{}')::bigint)
                  FROM audit_detail d
                 WHERE d.audit_id = e.audit_id AND d.field_name = 'current_provider_id'),
               (SELECT d.previous_value #>> '{}' FROM audit_detail d
                 WHERE d.audit_id = e.audit_id AND d.field_name = 'maintenance_state'),
               (SELECT d.new_value #>> '{}' FROM audit_detail d
                 WHERE d.audit_id = e.audit_id AND d.field_name = 'maintenance_state'),
               NULL::text, e.audit_id
          FROM audit_entry e
         WHERE e.primary_record_type = 'Bicycle'
           AND e.primary_record_id = p_bicycle_id
           AND e.action_type IN ('maintenance_handover', 'maintenance_return')
      ) AS m(movement_type, occurred_at, performed_by_staff_id, from_station_id, to_station_id,
             provider_id, maintenance_state_before, maintenance_state_after, reason, record_id)
     ORDER BY m.occurred_at DESC, m.record_id DESC
     LIMIT p_limit OFFSET p_offset;
END $$;

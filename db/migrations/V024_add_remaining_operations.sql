-- V024: Add remaining required functional & setup operations:
--   - get_active_tariffs (F-078, F-083)
--   - configure_tariffs (F-079)
--   - search_active_rentals (F-107)
--   - get_usage_statistics & get_station_pair_statistics (F-077, S-006)
--   - reset_baseline (S-004)
--   - purge_expired_records (Section III: 36-month retention policy)

SET LOCAL search_path = bicycle_rental, public;

-- =============================================================================
-- 0. Allow privileged retention purge on bicycle_transfer (Section III)
--    Operational UPDATE and DELETE remain strictly forbidden (F-092).
-- =============================================================================
CREATE OR REPLACE FUNCTION bicycle_rental.trg_bicycle_transfer_immutable()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF TG_OP = 'DELETE' AND bicycle_rental.is_privileged_reset() THEN
        RETURN OLD;
    END IF;
    RAISE EXCEPTION 'bicycle transfer records cannot be % operationally', lower(TG_OP) || 'd'
        USING ERRCODE = '23000';
END $$;

-- =============================================================================
-- 1. Active Tariff Lookup (F-078, F-083)
--    Callable by any authenticated rider or staff member.
-- =============================================================================
CREATE OR REPLACE FUNCTION bicycle_rental.get_active_tariffs(
    p_actor_id bigint
)
RETURNS TABLE (
    tariff_id            bigint,
    bicycle_type         bicycle_rental.bicycle_type,
    price_per_block      numeric(12,2),
    block_length_seconds integer,
    currency             varchar(10)
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = bicycle_rental, public
AS $$
BEGIN
    IF p_actor_id IS NULL OR NOT EXISTS (
        SELECT 1 FROM bicycle_rental.account a WHERE a.account_id = p_actor_id
    ) THEN
        RAISE EXCEPTION 'Authenticated rider or staff account required.'
            USING ERRCODE = '42501';
    END IF;

    RETURN QUERY
    SELECT t.tariff_id,
           t.bicycle_type,
           t.price_per_block,
           t.block_length_seconds,
           t.currency
      FROM bicycle_rental.tariff t
     WHERE t.is_active
     ORDER BY t.bicycle_type ASC;
END;
$$;

-- =============================================================================
-- 2. Privileged Tariff Configuration (F-079)
--    Deactivates current tariffs and activates a new regular + electric pair
--    sharing a single ISO 4217 currency.
-- =============================================================================
CREATE OR REPLACE FUNCTION bicycle_rental.configure_tariffs(
    p_regular_price_per_block       numeric(12,2),
    p_regular_block_length_seconds  integer,
    p_electric_price_per_block      numeric(12,2),
    p_electric_block_length_seconds integer,
    p_currency                      text
)
RETURNS TABLE (
    tariff_id            bigint,
    bicycle_type         bicycle_rental.bicycle_type,
    price_per_block      numeric(12,2),
    block_length_seconds integer,
    currency             varchar(10)
)
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = bicycle_rental, public
AS $$
DECLARE
    v_currency varchar(10);
BEGIN
    IF NOT pg_has_role(session_user, 'bicycle_setup', 'USAGE') THEN
        RAISE EXCEPTION 'Only bicycle_setup may configure tariffs.'
            USING ERRCODE = '42501';
    END IF;

    IF p_regular_price_per_block IS NULL OR p_regular_price_per_block < 0
       OR p_electric_price_per_block IS NULL OR p_electric_price_per_block < 0 THEN
        RAISE EXCEPTION 'Tariff price_per_block must be non-negative.'
            USING ERRCODE = '22023';
    END IF;

    IF p_regular_block_length_seconds IS NULL OR p_regular_block_length_seconds <= 0
       OR p_electric_block_length_seconds IS NULL OR p_electric_block_length_seconds <= 0 THEN
        RAISE EXCEPTION 'Tariff block_length_seconds must be positive.'
            USING ERRCODE = '22023';
    END IF;

    IF p_currency IS NULL OR btrim(p_currency) !~ '^[A-Z]{3}$' THEN
        RAISE EXCEPTION 'Tariff currency must be a 3-letter uppercase ISO 4217 code.'
            USING ERRCODE = '22023';
    END IF;
    v_currency := btrim(p_currency);

    PERFORM set_config('bicycle_rental.privileged_setup', 'true', true);

    UPDATE bicycle_rental.tariff
       SET is_active = false
     WHERE is_active;

    INSERT INTO bicycle_rental.tariff (
        bicycle_type, price_per_block, block_length_seconds, currency, is_active
    )
    VALUES
        ('regular',  p_regular_price_per_block,  p_regular_block_length_seconds,  v_currency, true),
        ('electric', p_electric_price_per_block, p_electric_block_length_seconds, v_currency, true);

    PERFORM set_config('bicycle_rental.privileged_setup', 'false', true);

    RETURN QUERY
    SELECT t.tariff_id,
           t.bicycle_type,
           t.price_per_block,
           t.block_length_seconds,
           t.currency
      FROM bicycle_rental.tariff t
     WHERE t.is_active
     ORDER BY t.bicycle_type ASC;
END;
$$;

-- =============================================================================
-- 3. Staff Active Rental Search (F-107)
--    Staff-only search across active rentals (end_time IS NULL) filtered by
--    rental_id, rider_id, bicycle_id, and/or case-insensitive bicycle identifier.
-- =============================================================================
CREATE OR REPLACE FUNCTION bicycle_rental.search_active_rentals(
    p_staff_id           bigint,
    p_rental_id          bigint  DEFAULT NULL,
    p_rider_id           bigint  DEFAULT NULL,
    p_bicycle_id         bigint  DEFAULT NULL,
    p_bicycle_identifier text    DEFAULT NULL
)
RETURNS TABLE (
    rental_id            bigint,
    rider_id             bigint,
    rider_first_name     text,
    rider_last_name      text,
    rider_email          text,
    bicycle_id           bigint,
    bicycle_identifier   text,
    bicycle_type         bicycle_rental.bicycle_type,
    pickup_station_id    bigint,
    pickup_station_name  text,
    start_time           timestamptz,
    price_per_block      numeric(12,2),
    block_length_seconds integer,
    currency             varchar
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = bicycle_rental, public
AS $$
DECLARE
    v_ident text := NULLIF(btrim(p_bicycle_identifier), '');
BEGIN
    IF p_staff_id IS NULL OR NOT EXISTS (
        SELECT 1 FROM bicycle_rental.staff st WHERE st.account_id = p_staff_id
    ) THEN
        RAISE EXCEPTION 'Staff account required.'
            USING ERRCODE = '42501';
    END IF;

    RETURN QUERY
    SELECT r.rental_id,
           r.rider_id,
           a.first_name::text,
           a.last_name::text,
           a.email::text,
           r.bicycle_id,
           b.identifier::text,
           r.bicycle_type,
           r.pickup_station_id,
           s.name::text,
           r.start_time,
           r.captured_price_per_block,
           r.captured_block_length_seconds,
           r.captured_currency
      FROM bicycle_rental.rental r
      JOIN bicycle_rental.account a ON a.account_id = r.rider_id
      JOIN bicycle_rental.bicycle b ON b.bicycle_id = r.bicycle_id
      JOIN bicycle_rental.station s ON s.station_id = r.pickup_station_id
     WHERE r.end_time IS NULL
       AND (p_rental_id  IS NULL OR r.rental_id  = p_rental_id)
       AND (p_rider_id   IS NULL OR r.rider_id   = p_rider_id)
       AND (p_bicycle_id IS NULL OR r.bicycle_id = p_bicycle_id)
       AND (v_ident      IS NULL OR lower(b.identifier) = lower(v_ident))
     ORDER BY r.start_time ASC, r.rental_id ASC;
END;
$$;

-- =============================================================================
-- 4. Usage Statistics (F-077, S-006)
--    Completed rentals only (end_time IS NOT NULL).
--    Duration precision: integer seconds (halves rounded up for average).
--    Empty dataset: completed_count = 0, total_duration_seconds = 0,
--                   average_duration_seconds = NULL.
-- =============================================================================
CREATE OR REPLACE FUNCTION bicycle_rental.get_usage_statistics(
    p_staff_id bigint
)
RETURNS TABLE (
    completed_count          bigint,
    total_duration_seconds   bigint,
    average_duration_seconds bigint
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = bicycle_rental, public
AS $$
DECLARE
    v_count    bigint;
    v_interval interval;
    v_total    bigint;
    v_avg      bigint;
BEGIN
    IF p_staff_id IS NULL OR NOT EXISTS (
        SELECT 1 FROM bicycle_rental.staff st WHERE st.account_id = p_staff_id
    ) THEN
        RAISE EXCEPTION 'Staff account required.'
            USING ERRCODE = '42501';
    END IF;

    SELECT count(*), sum(r.end_time - r.start_time)
      INTO v_count, v_interval
      FROM bicycle_rental.rental r
     WHERE r.end_time IS NOT NULL;

    IF v_count = 0 THEN
        v_total := 0;
        v_avg   := NULL;
    ELSE
        v_total := ROUND(EXTRACT(EPOCH FROM v_interval))::bigint;
        v_avg   := ROUND(EXTRACT(EPOCH FROM v_interval) / v_count)::bigint;
    END IF;

    RETURN QUERY SELECT v_count, v_total, v_avg;
END;
$$;

CREATE OR REPLACE FUNCTION bicycle_rental.get_station_pair_statistics(
    p_staff_id bigint
)
RETURNS TABLE (
    pickup_station_id   bigint,
    pickup_station_name text,
    return_station_id   bigint,
    return_station_name text,
    completed_count     bigint
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = bicycle_rental, public
AS $$
BEGIN
    IF p_staff_id IS NULL OR NOT EXISTS (
        SELECT 1 FROM bicycle_rental.staff st WHERE st.account_id = p_staff_id
    ) THEN
        RAISE EXCEPTION 'Staff account required.'
            USING ERRCODE = '42501';
    END IF;

    RETURN QUERY
    SELECT r.pickup_station_id,
           sp.name::text AS pickup_station_name,
           r.return_station_id,
           sr.name::text AS return_station_name,
           count(*) AS completed_count
      FROM bicycle_rental.rental r
      JOIN bicycle_rental.station sp ON sp.station_id = r.pickup_station_id
      JOIN bicycle_rental.station sr ON sr.station_id = r.return_station_id
     WHERE r.end_time IS NOT NULL
     GROUP BY r.pickup_station_id, sp.name, r.return_station_id, sr.name
     ORDER BY completed_count DESC, r.pickup_station_id ASC, r.return_station_id ASC;
END;
$$;

-- =============================================================================
-- 5. Privileged Baseline Reset (S-004)
--    Clears all operational and test data and resets sequences cleanly so
--    automated tests or baseline loaders can start from an empty schema.
-- =============================================================================
CREATE OR REPLACE FUNCTION bicycle_rental.reset_baseline()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = bicycle_rental, public
AS $$
BEGIN
    IF NOT pg_has_role(session_user, 'bicycle_setup', 'USAGE') THEN
        RAISE EXCEPTION 'Only bicycle_setup may reset the baseline.'
            USING ERRCODE = '42501';
    END IF;

    PERFORM set_config('bicycle_rental.privileged_setup', 'true', true);
    PERFORM set_config('bicycle_rental.privileged_reset', 'true', true);

    -- Flush queued deferred constraint triggers so TRUNCATE succeeds mid-transaction,
    -- then restore DEFERRED mode for subsequent multi-statement operations.
    SET CONSTRAINTS ALL IMMEDIATE;
    SET CONSTRAINTS ALL DEFERRED;

    TRUNCATE TABLE
        bicycle_rental.audit_detail,
        bicycle_rental.audit_entry,
        bicycle_rental.payment_event,
        bicycle_rental.payment_simulator_record,
        bicycle_rental.payment_simulator_scenario,
        bicycle_rental.payment,
        bicycle_rental.fault_report,
        bicycle_rental.maintenance_task,
        bicycle_rental.maintenance_job,
        bicycle_rental.bicycle_transfer,
        bicycle_rental.rental,
        bicycle_rental.electric_bicycle,
        bicycle_rental.bicycle,
        bicycle_rental.maintenance_provider,
        bicycle_rental.station,
        bicycle_rental.rider,
        bicycle_rental.staff,
        bicycle_rental.account,
        bicycle_rental.tariff
    RESTART IDENTITY CASCADE;

    PERFORM set_config('bicycle_rental.privileged_setup', 'false', true);
    PERFORM set_config('bicycle_rental.privileged_reset', 'false', true);
END;
$$;

-- =============================================================================
-- 6. 36-Month Retention Purge (Section III: Data Retention)
--    Deletes closed/completed historical records older than 36 months from
--    p_as_of while preserving active rentals, pending payments, open jobs,
--    open fault reports, and any records still referenced by active rows.
-- =============================================================================
CREATE OR REPLACE FUNCTION bicycle_rental.purge_expired_records(
    p_as_of timestamptz DEFAULT clock_timestamp()
)
RETURNS TABLE (
    entity_name  text,
    deleted_rows bigint
)
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = bicycle_rental, public
AS $$
DECLARE
    v_cutoff timestamptz;
    v_rows   bigint;
BEGIN
    IF NOT pg_has_role(session_user, 'bicycle_setup', 'USAGE') THEN
        RAISE EXCEPTION 'Only bicycle_setup may run retention purges.'
            USING ERRCODE = '42501';
    END IF;

    IF p_as_of IS NULL THEN
        RAISE EXCEPTION 'p_as_of timestamp must not be NULL.'
            USING ERRCODE = '22023';
    END IF;

    v_cutoff := p_as_of - interval '36 months';

    PERFORM set_config('bicycle_rental.privileged_setup', 'true', true);
    PERFORM set_config('bicycle_rental.privileged_reset', 'true', true);

    -- 1. Audit details & entries older than 36 months
    DELETE FROM bicycle_rental.audit_detail ad
     USING bicycle_rental.audit_entry ae
     WHERE ad.audit_id = ae.audit_id
       AND ae.created_at < v_cutoff;

    DELETE FROM bicycle_rental.audit_entry
     WHERE created_at < v_cutoff;
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    entity_name := 'audit_entry'; deleted_rows := v_rows; RETURN NEXT;

    -- 2. Terminal payment events, simulator records, and terminal payments
    DELETE FROM bicycle_rental.payment_event pe
     USING bicycle_rental.payment p
     WHERE pe.payment_id = p.payment_id
       AND p.status IN ('successful', 'failed')
       AND p.updated_at < v_cutoff;
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    entity_name := 'payment_event'; deleted_rows := v_rows; RETURN NEXT;

    DELETE FROM bicycle_rental.payment_simulator_record sr
     WHERE sr.created_at < v_cutoff
       AND NOT EXISTS (
           SELECT 1 FROM bicycle_rental.payment p
            WHERE p.payment_reference = sr.payment_reference
              AND p.status = 'pending'
       );
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    entity_name := 'payment_simulator_record'; deleted_rows := v_rows; RETURN NEXT;

    DELETE FROM bicycle_rental.payment
     WHERE status IN ('successful', 'failed')
       AND updated_at < v_cutoff;
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    entity_name := 'payment'; deleted_rows := v_rows; RETURN NEXT;

    -- 3. Resolved / rejected fault reports older than 36 months
    DELETE FROM bicycle_rental.fault_report
     WHERE (status = 'resolved' AND resolved_at < v_cutoff)
        OR (status = 'rejected' AND reported_at < v_cutoff);
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    entity_name := 'fault_report'; deleted_rows := v_rows; RETURN NEXT;

    -- 4. Terminal maintenance jobs (and tasks) not referenced by fault reports
    DELETE FROM bicycle_rental.maintenance_task mt
     USING bicycle_rental.maintenance_job mj
     WHERE mt.maintenance_job_id = mj.job_id
       AND mj.status IN ('completed', 'cancelled')
       AND mj.closed_at < v_cutoff
       AND NOT EXISTS (
           SELECT 1 FROM bicycle_rental.fault_report fr
            WHERE fr.maintenance_job_id = mj.job_id
       );

    DELETE FROM bicycle_rental.maintenance_job mj
     WHERE mj.status IN ('completed', 'cancelled')
       AND mj.closed_at < v_cutoff
       AND NOT EXISTS (
           SELECT 1 FROM bicycle_rental.fault_report fr
            WHERE fr.maintenance_job_id = mj.job_id
       );
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    entity_name := 'maintenance_job'; deleted_rows := v_rows; RETURN NEXT;

    -- 5. Bicycle transfers older than 36 months
    DELETE FROM bicycle_rental.bicycle_transfer
     WHERE transferred_at < v_cutoff;
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    entity_name := 'bicycle_transfer'; deleted_rows := v_rows; RETURN NEXT;

    -- 6. Simulator scenarios for expired completed rentals, then the rentals themselves
    DELETE FROM bicycle_rental.payment_simulator_scenario s
     USING bicycle_rental.rental r
     WHERE s.rental_id = r.rental_id
       AND r.end_time IS NOT NULL
       AND r.end_time < v_cutoff
       AND NOT EXISTS (SELECT 1 FROM bicycle_rental.payment p WHERE p.rental_id = r.rental_id)
       AND NOT EXISTS (SELECT 1 FROM bicycle_rental.fault_report fr WHERE fr.rental_id = r.rental_id);

    DELETE FROM bicycle_rental.rental r
     WHERE r.end_time IS NOT NULL
       AND r.end_time < v_cutoff
       AND NOT EXISTS (SELECT 1 FROM bicycle_rental.payment p WHERE p.rental_id = r.rental_id)
       AND NOT EXISTS (SELECT 1 FROM bicycle_rental.fault_report fr WHERE fr.rental_id = r.rental_id);
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    entity_name := 'rental'; deleted_rows := v_rows; RETURN NEXT;

    PERFORM set_config('bicycle_rental.privileged_setup', 'false', true);
    PERFORM set_config('bicycle_rental.privileged_reset', 'false', true);
END;
$$;

-- =============================================================================
-- 7. Security Boundaries (V022 / V023 rule: zero PUBLIC execution)
-- =============================================================================
REVOKE ALL ON ALL ROUTINES IN SCHEMA bicycle_rental FROM PUBLIC;

GRANT EXECUTE ON FUNCTION bicycle_rental.get_active_tariffs(bigint) TO bicycle_app;
GRANT EXECUTE ON FUNCTION bicycle_rental.search_active_rentals(bigint, bigint, bigint, bigint, text) TO bicycle_app;
GRANT EXECUTE ON FUNCTION bicycle_rental.get_usage_statistics(bigint) TO bicycle_app;
GRANT EXECUTE ON FUNCTION bicycle_rental.get_station_pair_statistics(bigint) TO bicycle_app;
GRANT EXECUTE ON FUNCTION bicycle_rental.reset_baseline() TO bicycle_app;

GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA bicycle_rental TO bicycle_setup;
GRANT USAGE, SELECT, UPDATE ON ALL SEQUENCES IN SCHEMA bicycle_rental TO bicycle_setup;

GRANT EXECUTE ON FUNCTION bicycle_rental.configure_tariffs(numeric, integer, numeric, integer, text) TO bicycle_setup;
GRANT EXECUTE ON FUNCTION bicycle_rental.reset_baseline() TO bicycle_setup;
GRANT EXECUTE ON FUNCTION bicycle_rental.purge_expired_records(timestamptz) TO bicycle_setup;
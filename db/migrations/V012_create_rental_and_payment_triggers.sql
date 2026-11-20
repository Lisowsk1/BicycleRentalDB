-- V012: Transaction-level invariants, immutability, and state-transition triggers for Rental and Payment.
-- Requirements: F-029, F-065, F-069, F-072, F-080, F-082, F-085, F-089..F-091, F-110, F-113, F-114, S-004.

SET LOCAL search_path = bicycle_rental, public;

-- 1. Validate new rentals on operational INSERT (bypassed only during privileged seed/setup)
CREATE FUNCTION bicycle_rental.trg_rental_before_insert()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = bicycle_rental, pg_temp
AS $$
DECLARE
    v_rider_status bicycle_rental.rider_status;
    v_tariff       bicycle_rental.tariff%ROWTYPE;
BEGIN
    IF current_setting('bicycle_rental.privileged_setup', true) NOT IN ('on', 'true') THEN
        -- Active rider check (F-065)
        SELECT r.status
          INTO v_rider_status
          FROM bicycle_rental.rider r
         WHERE r.account_id = NEW.rider_id;

        IF v_rider_status IS DISTINCT FROM 'active' THEN
            RAISE EXCEPTION 'Rental cannot start for blocked or non-existent rider %', NEW.rider_id
                USING ERRCODE = '23514';
        END IF;

        -- Pricing snapshot must match the active tariff at start (F-080, F-085)
        SELECT *
          INTO v_tariff
          FROM bicycle_rental.tariff t
         WHERE t.tariff_id = NEW.tariff_id;

        IF NOT FOUND OR NOT v_tariff.is_active THEN
            RAISE EXCEPTION 'Rental must reference an active tariff (tariff_id=%)', NEW.tariff_id
                USING ERRCODE = '23514';
        END IF;

        IF NEW.captured_price_per_block IS DISTINCT FROM v_tariff.price_per_block
           OR NEW.captured_block_length_seconds IS DISTINCT FROM v_tariff.block_length_seconds
           OR NEW.captured_currency IS DISTINCT FROM v_tariff.currency THEN
            RAISE EXCEPTION 'Captured rental pricing snapshot must match active tariff %', NEW.tariff_id
                USING ERRCODE = '23514';
        END IF;
    END IF;

    RETURN NEW;
END $$;

CREATE TRIGGER trg_rental_before_insert
    BEFORE INSERT ON bicycle_rental.rental
    FOR EACH ROW EXECUTE FUNCTION bicycle_rental.trg_rental_before_insert();

-- 2. Enforce Rental immutability on UPDATE (F-069, F-072, F-080, F-082, F-085, F-110)
CREATE FUNCTION bicycle_rental.trg_rental_before_update()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    -- Core identity, references, start_time, and pricing snapshot are always immutable
    IF NEW.rental_id IS DISTINCT FROM OLD.rental_id
       OR NEW.rider_id IS DISTINCT FROM OLD.rider_id
       OR NEW.bicycle_id IS DISTINCT FROM OLD.bicycle_id
       OR NEW.pickup_station_id IS DISTINCT FROM OLD.pickup_station_id
       OR NEW.tariff_id IS DISTINCT FROM OLD.tariff_id
       OR NEW.bicycle_type IS DISTINCT FROM OLD.bicycle_type
       OR NEW.start_time IS DISTINCT FROM OLD.start_time
       OR NEW.captured_price_per_block IS DISTINCT FROM OLD.captured_price_per_block
       OR NEW.captured_block_length_seconds IS DISTINCT FROM OLD.captured_block_length_seconds
       OR NEW.captured_currency IS DISTINCT FROM OLD.captured_currency THEN
        RAISE EXCEPTION 'Rental identity, references, start_time, and pricing snapshot are immutable'
            USING ERRCODE = '23514';
    END IF;

    -- First completion is final; completed return fields cannot be overwritten
    IF OLD.end_time IS NOT NULL THEN
        IF NEW.return_station_id IS DISTINCT FROM OLD.return_station_id
           OR NEW.end_time IS DISTINCT FROM OLD.end_time
           OR NEW.final_charge IS DISTINCT FROM OLD.final_charge
           OR NEW.returned_by_staff_id IS DISTINCT FROM OLD.returned_by_staff_id THEN
            RAISE EXCEPTION 'Completed rental % cannot be modified', OLD.rental_id
                USING ERRCODE = '23514';
        END IF;
    END IF;

    RETURN NEW;
END $$;

CREATE TRIGGER trg_rental_before_update
    BEFORE UPDATE ON bicycle_rental.rental
    FOR EACH ROW EXECUTE FUNCTION bicycle_rental.trg_rental_before_update();

-- 3. Prohibit operational DELETE on Rental (F-113, F-114; reset uses TRUNCATE or privileged_setup)
CREATE FUNCTION bicycle_rental.trg_rental_forbid_delete()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF current_setting('bicycle_rental.privileged_setup', true) NOT IN ('on', 'true') THEN
        RAISE EXCEPTION 'Rental records cannot be deleted operationally'
            USING ERRCODE = '23000';
    END IF;
    RETURN OLD;
END $$;

CREATE TRIGGER trg_rental_no_delete
    BEFORE DELETE ON bicycle_rental.rental
    FOR EACH ROW EXECUTE FUNCTION bicycle_rental.trg_rental_forbid_delete();

-- 4. Deferred cross-table check: bicycle.placement = 'active_rental' IFF an active rental exists (F-029, ERD)
CREATE FUNCTION bicycle_rental.trg_check_bicycle_active_rental_sync()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = bicycle_rental, pg_temp
AS $$
DECLARE
    v_bicycle_id        bigint;
    v_placement         bicycle_rental.bicycle_placement;
    v_has_active_rental boolean;
BEGIN
    v_bicycle_id := NEW.bicycle_id;

    SELECT b.placement
      INTO v_placement
      FROM bicycle_rental.bicycle b
     WHERE b.bicycle_id = v_bicycle_id;

    IF NOT FOUND THEN
        RETURN NULL;
    END IF;

    SELECT EXISTS (
        SELECT 1
          FROM bicycle_rental.rental r
         WHERE r.bicycle_id = v_bicycle_id
           AND r.end_time IS NULL
    ) INTO v_has_active_rental;

    IF (v_placement = 'active_rental') IS DISTINCT FROM v_has_active_rental THEN
        RAISE EXCEPTION 'Bicycle % placement (%) must match active rental existence (%) at commit',
            v_bicycle_id, v_placement, v_has_active_rental
            USING ERRCODE = '23514';
    END IF;

    RETURN NULL;
END $$;

CREATE CONSTRAINT TRIGGER ctrg_rental_bicycle_placement_sync
    AFTER INSERT OR UPDATE OF end_time, bicycle_id ON bicycle_rental.rental
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION bicycle_rental.trg_check_bicycle_active_rental_sync();

CREATE CONSTRAINT TRIGGER ctrg_bicycle_rental_placement_sync
    AFTER INSERT OR UPDATE OF placement ON bicycle_rental.bicycle
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION bicycle_rental.trg_check_bicycle_active_rental_sync();

-- 5. Validate new Payment records on operational INSERT (F-090)
CREATE FUNCTION bicycle_rental.trg_payment_before_insert()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF current_setting('bicycle_rental.privileged_setup', true) NOT IN ('on', 'true') THEN
        IF NEW.status IS DISTINCT FROM 'pending' THEN
            RAISE EXCEPTION 'New payment records must start in pending status'
                USING ERRCODE = '23514';
        END IF;
    END IF;

    RETURN NEW;
END $$;

CREATE TRIGGER trg_payment_before_insert
    BEFORE INSERT ON bicycle_rental.payment
    FOR EACH ROW EXECUTE FUNCTION bicycle_rental.trg_payment_before_insert();

-- 6. Enforce Payment immutability and terminal state transitions on UPDATE (F-089, F-090, F-091)
CREATE FUNCTION bicycle_rental.trg_payment_before_update()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.payment_id IS DISTINCT FROM OLD.payment_id
       OR NEW.rental_id IS DISTINCT FROM OLD.rental_id
       OR NEW.rider_id IS DISTINCT FROM OLD.rider_id
       OR NEW.amount IS DISTINCT FROM OLD.amount
       OR NEW.currency IS DISTINCT FROM OLD.currency
       OR NEW.created_at IS DISTINCT FROM OLD.created_at THEN
        RAISE EXCEPTION 'Payment identity, rental, rider, amount, currency, and created_at are immutable'
            USING ERRCODE = '23514';
    END IF;

    IF OLD.status <> 'pending' THEN
        RAISE EXCEPTION 'Payment % is in terminal status (%) and cannot be updated', OLD.payment_id, OLD.status
            USING ERRCODE = '23514';
    END IF;

    IF NEW.status NOT IN ('successful', 'failed') THEN
        RAISE EXCEPTION 'Payment % can only transition from pending to successful or failed', OLD.payment_id
            USING ERRCODE = '23514';
    END IF;

    IF NEW.updated_at = OLD.updated_at THEN
        NEW.updated_at := clock_timestamp();
    END IF;

    RETURN NEW;
END $$;

CREATE TRIGGER trg_payment_before_update
    BEFORE UPDATE ON bicycle_rental.payment
    FOR EACH ROW EXECUTE FUNCTION bicycle_rental.trg_payment_before_update();

-- 7. Prohibit operational DELETE on Payment (F-090, S-004)
CREATE FUNCTION bicycle_rental.trg_payment_forbid_delete()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF current_setting('bicycle_rental.privileged_setup', true) NOT IN ('on', 'true') THEN
        RAISE EXCEPTION 'Payment records cannot be deleted operationally'
            USING ERRCODE = '23000';
    END IF;
    RETURN OLD;
END $$;

CREATE TRIGGER trg_payment_no_delete
    BEFORE DELETE ON bicycle_rental.payment
    FOR EACH ROW EXECUTE FUNCTION bicycle_rental.trg_payment_forbid_delete();
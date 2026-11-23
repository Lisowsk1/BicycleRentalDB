-- V015: Make the V012 setup guards reject by default when the setting is absent.
-- Keep the existing explicit on/true setup bypass for seed and reset operations.
-- SQL NULL must not skip operational validation or deletion protection.

CREATE OR REPLACE FUNCTION bicycle_rental.trg_rental_before_insert()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = bicycle_rental, pg_temp
AS $$
DECLARE
    v_rider_status bicycle_rental.rider_status;
    v_tariff       bicycle_rental.tariff%ROWTYPE;
BEGIN
    IF (current_setting('bicycle_rental.privileged_setup', true) IN ('on', 'true')) IS NOT TRUE THEN
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

CREATE OR REPLACE FUNCTION bicycle_rental.trg_rental_forbid_delete()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF (current_setting('bicycle_rental.privileged_setup', true) IN ('on', 'true')) IS NOT TRUE THEN
        RAISE EXCEPTION 'Rental records cannot be deleted operationally'
            USING ERRCODE = '23000';
    END IF;
    RETURN OLD;
END $$;

CREATE OR REPLACE FUNCTION bicycle_rental.trg_payment_before_insert()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF (current_setting('bicycle_rental.privileged_setup', true) IN ('on', 'true')) IS NOT TRUE THEN
        IF NEW.status IS DISTINCT FROM 'pending' THEN
            RAISE EXCEPTION 'New payment records must start in pending status'
                USING ERRCODE = '23514';
        END IF;
    END IF;

    RETURN NEW;
END $$;

CREATE OR REPLACE FUNCTION bicycle_rental.trg_payment_forbid_delete()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF (current_setting('bicycle_rental.privileged_setup', true) IN ('on', 'true')) IS NOT TRUE THEN
        RAISE EXCEPTION 'Payment records cannot be deleted operationally'
            USING ERRCODE = '23000';
    END IF;
    RETURN OLD;
END $$;


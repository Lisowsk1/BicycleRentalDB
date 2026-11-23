-- V014: Simulated payment processing, payment-state management and recovery.
-- Requirements: F-058..F-068, F-114.

SET LOCAL search_path = bicycle_rental, public;

-- 1. NULL-safe privileged-setup test (current_setting returns NULL when the setting was never set)
CREATE FUNCTION bicycle_rental.is_privileged_setup()
RETURNS boolean
LANGUAGE sql STABLE
AS $$
    SELECT COALESCE(current_setting('bicycle_rental.privileged_setup', true) IN ('on', 'true'), false)
$$;

-- 2. V012 trigger functions rewritten with the NULL-safe test
CREATE OR REPLACE FUNCTION bicycle_rental.trg_rental_before_insert()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = bicycle_rental, pg_temp
AS $$
DECLARE
    v_rider_status bicycle_rental.rider_status;
    v_tariff       bicycle_rental.tariff%ROWTYPE;
BEGIN
    IF NOT bicycle_rental.is_privileged_setup() THEN
        SELECT r.status INTO v_rider_status
          FROM bicycle_rental.rider r
         WHERE r.account_id = NEW.rider_id;

        IF v_rider_status IS DISTINCT FROM 'active' THEN
            RAISE EXCEPTION 'Rental cannot start for blocked or non-existent rider %', NEW.rider_id
                USING ERRCODE = '23514';
        END IF;

        SELECT * INTO v_tariff
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
    IF NOT bicycle_rental.is_privileged_setup() THEN
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
    IF NOT bicycle_rental.is_privileged_setup() AND NEW.status IS DISTINCT FROM 'pending' THEN
        RAISE EXCEPTION 'New payment records must start in pending status'
            USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END $$;

CREATE OR REPLACE FUNCTION bicycle_rental.trg_payment_forbid_delete()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF NOT bicycle_rental.is_privileged_setup() THEN
        RAISE EXCEPTION 'Payment records cannot be deleted operationally'
            USING ERRCODE = '23000';
    END IF;
    RETURN OLD;
END $$;

-- 3. Payment reference
ALTER TABLE bicycle_rental.payment
    ADD COLUMN payment_reference uuid NOT NULL DEFAULT gen_random_uuid(),
    ADD CONSTRAINT uq_payment_reference UNIQUE (payment_reference);

-- Immutable fields, terminal states, and status changes only through the trusted adapter (F-060, F-061, F-062, F-114)
CREATE OR REPLACE FUNCTION bicycle_rental.trg_payment_before_update()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.payment_id IS DISTINCT FROM OLD.payment_id
       OR NEW.payment_reference IS DISTINCT FROM OLD.payment_reference
       OR NEW.rental_id IS DISTINCT FROM OLD.rental_id
       OR NEW.rider_id IS DISTINCT FROM OLD.rider_id
       OR NEW.amount IS DISTINCT FROM OLD.amount
       OR NEW.currency IS DISTINCT FROM OLD.currency
       OR NEW.created_at IS DISTINCT FROM OLD.created_at THEN
        RAISE EXCEPTION 'Payment identity, reference, rental, rider, amount, currency, and created_at are immutable'
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

    IF NOT bicycle_rental.is_privileged_setup()
       AND COALESCE(current_setting('bicycle_rental.payment_adapter', true), '') <> 'on' THEN
        RAISE EXCEPTION 'Payment status can only be changed by the trusted simulator adapter'
            USING ERRCODE = '23514';
    END IF;

    IF NEW.updated_at = OLD.updated_at THEN
        NEW.updated_at := clock_timestamp();
    END IF;

    RETURN NEW;
END $$;

-- 4. Simulator state and payment event log
CREATE TYPE bicycle_rental.simulator_scenario AS ENUM (
    'success',
    'failure',
    'success_lost_response',
    'unavailable'
);

CREATE TYPE bicycle_rental.payment_event_type AS ENUM (
    'requested',
    'submission_attempted',
    'submission_unconfirmed',
    'confirmed_successful',
    'confirmed_failed'
);

CREATE TABLE bicycle_rental.payment_simulator_scenario (
    rental_id bigint PRIMARY KEY
        REFERENCES bicycle_rental.rental (rental_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    scenario  bicycle_rental.simulator_scenario NOT NULL
);

CREATE TABLE bicycle_rental.payment_simulator_record (
    payment_reference  uuid PRIMARY KEY,
    rental_id          bigint NOT NULL
        REFERENCES bicycle_rental.rental (rental_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    amount             numeric(12, 2) NOT NULL,
    currency           varchar NOT NULL,
    outcome            bicycle_rental.payment_status NOT NULL,
    response_delivered boolean NOT NULL,
    created_at         timestamptz NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT ck_simulator_record_outcome CHECK (outcome IN ('successful', 'failed'))
);

CREATE TABLE bicycle_rental.payment_event (
    event_id        bigint GENERATED ALWAYS AS IDENTITY,
    payment_id      bigint NOT NULL,
    actor_id        bigint,
    event_type      bicycle_rental.payment_event_type NOT NULL,
    previous_status bicycle_rental.payment_status,
    new_status      bicycle_rental.payment_status NOT NULL,
    created_at      timestamptz NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT pk_payment_event PRIMARY KEY (event_id),
    CONSTRAINT fk_payment_event_payment FOREIGN KEY (payment_id)
        REFERENCES bicycle_rental.payment (payment_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT fk_payment_event_actor FOREIGN KEY (actor_id)
        REFERENCES bicycle_rental.account (account_id) ON UPDATE RESTRICT ON DELETE RESTRICT
);

CREATE INDEX ix_payment_event_payment ON bicycle_rental.payment_event (payment_id, event_id);

CREATE FUNCTION bicycle_rental.trg_require_privileged_setup()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF NOT bicycle_rental.is_privileged_setup() THEN
        RAISE EXCEPTION '% on % requires privileged setup', TG_OP, TG_TABLE_NAME
            USING ERRCODE = '42501';
    END IF;
    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER trg_simulator_scenario_privileged
    BEFORE INSERT OR UPDATE OR DELETE ON bicycle_rental.payment_simulator_scenario
    FOR EACH ROW EXECUTE FUNCTION bicycle_rental.trg_require_privileged_setup();

CREATE FUNCTION bicycle_rental.trg_simulator_record_guard()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN
        IF NOT bicycle_rental.is_privileged_setup() THEN
            RAISE EXCEPTION 'simulator results are kept until a privileged reset'
                USING ERRCODE = '23000';
        END IF;
        RETURN OLD;
    END IF;

    IF NEW.payment_reference IS DISTINCT FROM OLD.payment_reference
       OR NEW.rental_id IS DISTINCT FROM OLD.rental_id
       OR NEW.amount IS DISTINCT FROM OLD.amount
       OR NEW.currency IS DISTINCT FROM OLD.currency
       OR NEW.outcome IS DISTINCT FROM OLD.outcome
       OR NEW.created_at IS DISTINCT FROM OLD.created_at
       OR (OLD.response_delivered AND NOT NEW.response_delivered) THEN
        RAISE EXCEPTION 'simulator result % is immutable', OLD.payment_reference
            USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER trg_simulator_record_guard
    BEFORE UPDATE OR DELETE ON bicycle_rental.payment_simulator_record
    FOR EACH ROW EXECUTE FUNCTION bicycle_rental.trg_simulator_record_guard();

CREATE FUNCTION bicycle_rental.trg_payment_event_append_only()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF NOT bicycle_rental.is_privileged_setup() THEN
        RAISE EXCEPTION 'Payment events are append-only: % is prohibited', TG_OP
            USING ERRCODE = '23000';
    END IF;
    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER trg_payment_event_append_only
    BEFORE UPDATE OR DELETE ON bicycle_rental.payment_event
    FOR EACH ROW EXECUTE FUNCTION bicycle_rental.trg_payment_event_append_only();

-- Seeded terminal payments get the matching retained simulator result
INSERT INTO bicycle_rental.payment_simulator_record (
    payment_reference, rental_id, amount, currency, outcome, response_delivered, created_at)
SELECT p.payment_reference, p.rental_id, p.amount, p.currency, p.status, true, p.updated_at
  FROM bicycle_rental.payment p
 WHERE p.status <> 'pending';

-- 5. Simulator (internal): returns the outcome, or NULL when no response reaches the application
CREATE FUNCTION bicycle_rental.simulator_submit(
    p_payment_reference uuid,
    p_rental_id         bigint,
    p_amount            numeric,
    p_currency          varchar)
RETURNS text
LANGUAGE plpgsql
SET search_path = bicycle_rental, pg_temp
AS $$
DECLARE
    v_rec       payment_simulator_record%ROWTYPE;
    v_scenario  simulator_scenario;
    v_outcome   text;
    v_delivered boolean;
BEGIN
    SELECT * INTO v_rec
      FROM payment_simulator_record s
     WHERE s.payment_reference = p_payment_reference
       FOR UPDATE;

    IF FOUND THEN
        IF v_rec.rental_id IS DISTINCT FROM p_rental_id
           OR v_rec.amount IS DISTINCT FROM p_amount
           OR v_rec.currency IS DISTINCT FROM p_currency THEN
            RAISE EXCEPTION 'payment reference % was already used with a different payload', p_payment_reference
                USING ERRCODE = '22023';
        END IF;

        UPDATE payment_simulator_record AS s
           SET response_delivered = true
         WHERE s.payment_reference = p_payment_reference
           AND NOT s.response_delivered;

        RETURN v_rec.outcome::text;
    END IF;

    SELECT s.scenario INTO v_scenario
      FROM payment_simulator_scenario s
     WHERE s.rental_id = p_rental_id;

    IF v_scenario IS NULL THEN
        v_scenario := 'success';
    END IF;

    IF v_scenario = 'unavailable' THEN
        RETURN NULL;
    END IF;

    v_outcome   := CASE WHEN v_scenario = 'failure' THEN 'failed' ELSE 'successful' END;
    v_delivered := v_scenario <> 'success_lost_response';

    INSERT INTO payment_simulator_record (
        payment_reference, rental_id, amount, currency, outcome, response_delivered)
    VALUES (
        p_payment_reference, p_rental_id, p_amount, p_currency,
        v_outcome::bicycle_rental.payment_status, v_delivered);

    IF NOT v_delivered THEN
        RETURN NULL;
    END IF;
    RETURN v_outcome;
END $$;

-- 6. Trusted adapter (internal): the only path that changes payment status (F-060, F-061)
CREATE FUNCTION bicycle_rental.apply_payment_confirmation(
    p_payment_reference uuid,
    p_rental_id         bigint,
    p_amount            numeric,
    p_currency          varchar,
    p_outcome           text)
RETURNS void
LANGUAGE plpgsql
SET search_path = bicycle_rental, pg_temp
AS $$
DECLARE
    v_payment payment%ROWTYPE;
BEGIN
    IF p_outcome NOT IN ('successful', 'failed') THEN
        RAISE EXCEPTION 'unsupported simulator outcome %', p_outcome USING ERRCODE = '22023';
    END IF;

    SELECT p.* INTO v_payment
      FROM payment p
     WHERE p.payment_reference = p_payment_reference
       FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'unknown payment reference' USING ERRCODE = '22023';
    END IF;

    IF v_payment.rental_id IS DISTINCT FROM p_rental_id
       OR v_payment.amount IS DISTINCT FROM p_amount
       OR v_payment.currency IS DISTINCT FROM p_currency THEN
        RAISE EXCEPTION 'confirmation does not match the stored payment' USING ERRCODE = '22023';
    END IF;

    IF v_payment.status = 'pending' THEN
        PERFORM set_config('bicycle_rental.payment_adapter', 'on', true);

        UPDATE payment AS p
           SET status     = p_outcome::bicycle_rental.payment_status,
               updated_at = clock_timestamp()
         WHERE p.payment_id = v_payment.payment_id;

        PERFORM set_config('bicycle_rental.payment_adapter', 'off', true);

        INSERT INTO payment_event (payment_id, actor_id, event_type, previous_status, new_status)
        VALUES (v_payment.payment_id, NULL,
                CASE WHEN p_outcome = 'successful'
                     THEN 'confirmed_successful' ELSE 'confirmed_failed' END::payment_event_type,
                'pending', p_outcome::bicycle_rental.payment_status);
        RETURN;
    END IF;

    IF v_payment.status::text = p_outcome THEN
        RETURN;
    END IF;

    RAISE EXCEPTION 'payment % is already % and cannot become %', v_payment.payment_id, v_payment.status, p_outcome
        USING ERRCODE = '23514';
END $$;

-- 7. Rider operations

-- F-058, F-059: creates the pending payment or reuses the existing one; does not call the simulator
CREATE FUNCTION bicycle_rental.request_payment(p_actor_id bigint, p_rental_id bigint)
RETURNS TABLE (payment_reference uuid, status bicycle_rental.payment_status,
               amount numeric, currency varchar)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = bicycle_rental, public, pg_temp
AS $$
DECLARE
    v_rental     rental%ROWTYPE;
    v_payment_id bigint;
BEGIN
    SELECT r.* INTO v_rental
      FROM rental r
     WHERE r.rental_id = p_rental_id
       AND r.rider_id = p_actor_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'operation not permitted' USING ERRCODE = '42501';
    END IF;

    IF v_rental.end_time IS NULL THEN
        RAISE EXCEPTION 'an active rental has no final charge to pay' USING ERRCODE = '23514';
    END IF;

    IF v_rental.final_charge <= 0 THEN
        RAISE EXCEPTION 'a zero-charge rental needs no payment' USING ERRCODE = '23514';
    END IF;

    INSERT INTO payment (rental_id, rider_id, amount, currency)
    VALUES (v_rental.rental_id, v_rental.rider_id, v_rental.final_charge, v_rental.captured_currency)
    ON CONFLICT (rental_id) DO NOTHING
    RETURNING payment_id INTO v_payment_id;

    IF FOUND THEN
        INSERT INTO payment_event (payment_id, actor_id, event_type, previous_status, new_status)
        VALUES (v_payment_id, p_actor_id, 'requested', NULL, 'pending');
    END IF;

    RETURN QUERY
    SELECT p.payment_reference, p.status, p.amount, p.currency
      FROM payment p
     WHERE p.rental_id = v_rental.rental_id;
END $$;

-- F-059, F-061, F-064: submits a pending payment; uncertain = true while no definitive result exists
CREATE FUNCTION bicycle_rental.submit_payment(p_actor_id bigint, p_payment_reference uuid)
RETURNS TABLE (payment_reference uuid, status bicycle_rental.payment_status,
               amount numeric, currency varchar, uncertain boolean)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = bicycle_rental, public, pg_temp
AS $$
DECLARE
    v_payment payment%ROWTYPE;
    v_outcome text;
BEGIN
    SELECT p.* INTO v_payment
      FROM payment p
     WHERE p.payment_reference = p_payment_reference
       AND p.rider_id = p_actor_id
       FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'operation not permitted' USING ERRCODE = '42501';
    END IF;

    IF v_payment.status = 'pending' THEN
        INSERT INTO payment_event (payment_id, actor_id, event_type, previous_status, new_status)
        VALUES (v_payment.payment_id, p_actor_id, 'submission_attempted', 'pending', 'pending');

        v_outcome := bicycle_rental.simulator_submit(
            v_payment.payment_reference, v_payment.rental_id, v_payment.amount, v_payment.currency);

        IF v_outcome IS NULL THEN
            INSERT INTO payment_event (payment_id, actor_id, event_type, previous_status, new_status)
            VALUES (v_payment.payment_id, p_actor_id, 'submission_unconfirmed', 'pending', 'pending');
        ELSE
            PERFORM bicycle_rental.apply_payment_confirmation(
                v_payment.payment_reference, v_payment.rental_id,
                v_payment.amount, v_payment.currency, v_outcome);
        END IF;
    END IF;

    RETURN QUERY
    SELECT p.payment_reference, p.status, p.amount, p.currency, p.status = 'pending'
      FROM payment p
     WHERE p.payment_reference = p_payment_reference;
END $$;

-- F-067, F-068: owner or staff
CREATE FUNCTION bicycle_rental.get_rental_payment(p_actor_id bigint, p_rental_id bigint)
RETURNS TABLE (rental_id bigint, charge numeric, currency varchar,
               payment_reference uuid, payment_status bicycle_rental.payment_status,
               display_state text, simulated boolean)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = bicycle_rental, public, pg_temp
AS $$
DECLARE
    v_rental      rental%ROWTYPE;
    v_payment     payment%ROWTYPE;
    v_has_payment boolean;
    v_is_staff    boolean;
    v_display     text;
BEGIN
    v_is_staff := EXISTS (SELECT 1 FROM staff s WHERE s.account_id = p_actor_id);

    SELECT r.* INTO v_rental
      FROM rental r
     WHERE r.rental_id = p_rental_id;

    IF NOT FOUND OR (NOT v_is_staff AND v_rental.rider_id IS DISTINCT FROM p_actor_id) THEN
        RAISE EXCEPTION 'operation not permitted' USING ERRCODE = '42501';
    END IF;

    SELECT p.* INTO v_payment
      FROM payment p
     WHERE p.rental_id = p_rental_id;
    v_has_payment := FOUND;

    v_display := CASE
        WHEN v_rental.end_time IS NULL THEN 'not_applicable'
        WHEN v_rental.final_charge = 0 THEN 'not_required'
        WHEN NOT v_has_payment         THEN 'not_requested'
        ELSE v_payment.status::text
    END;

    RETURN QUERY
    SELECT v_rental.rental_id, v_rental.final_charge, v_rental.captured_currency,
           v_payment.payment_reference, v_payment.status, v_display, true;
END $$;

-- F-067: staff lookup by rider
CREATE FUNCTION bicycle_rental.list_rider_payments(p_actor_id bigint, p_rider_id bigint)
RETURNS TABLE (rental_id bigint, payment_reference uuid,
               payment_status bicycle_rental.payment_status, amount numeric, currency varchar)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = bicycle_rental, public, pg_temp
AS $$
BEGIN
    PERFORM require_staff(p_actor_id);

    RETURN QUERY
    SELECT p.rental_id, p.payment_reference, p.status, p.amount, p.currency
      FROM payment p
     WHERE p.rider_id = p_rider_id
     ORDER BY p.created_at DESC, p.payment_id DESC;
END $$;

REVOKE ALL ON FUNCTION bicycle_rental.simulator_submit(uuid, bigint, numeric, varchar) FROM PUBLIC;
REVOKE ALL ON FUNCTION bicycle_rental.apply_payment_confirmation(uuid, bigint, numeric, varchar, text) FROM PUBLIC;

-- Deployment: GRANT EXECUTE on request_payment, submit_payment, get_rental_payment and list_rider_payments to the application role.

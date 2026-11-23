-- Integration tests for the public CALL and its real commit boundaries.
-- Run using psql -X --set=ON_ERROR_STOP=1 after all migrations.
-- Commits fixtures: use a disposable database, as with payment_concurrency_test.sh.
-- Do not wrap this file in BEGIN or psql --single-transaction.
SET search_path = bicycle_rental, public, pg_temp;
CREATE TEMP TABLE recovery_results (description text NOT NULL);
CREATE TEMP TABLE recovery_fixtures (
    label text PRIMARY KEY, rental_id bigint, rider_id bigint,
    payment_reference uuid, payment_id bigint, pending_updated_at timestamptz);

CREATE FUNCTION pg_temp.check_recovery(p_ok boolean, p_description text)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    IF p_ok IS DISTINCT FROM true THEN
        RAISE EXCEPTION 'FAIL: %', p_description;
    END IF;
    INSERT INTO recovery_results VALUES (p_description);
END $$;

CREATE FUNCTION pg_temp.reject_confirmation_write()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'injected confirmation-write failure';
END $$;

DO $$
DECLARE
    v_label text;
    v_rental bigint;
    v_rider bigint;
BEGIN
    FOREACH v_label IN ARRAY ARRAY['write', 'event', 'transaction'] LOOP
        INSERT INTO rental (rider_id, bicycle_id, pickup_station_id, return_station_id, tariff_id,
                            start_time, end_time, captured_price_per_block,
                            captured_block_length_seconds, captured_currency, final_charge, bicycle_type)
        SELECT r.rider_id, r.bicycle_id, r.pickup_station_id, r.return_station_id, r.tariff_id,
               r.start_time, r.end_time, r.captured_price_per_block,
               r.captured_block_length_seconds, r.captured_currency, r.final_charge, r.bicycle_type
          FROM rental r WHERE r.end_time IS NOT NULL AND r.final_charge > 0
          ORDER BY r.rental_id LIMIT 1
        RETURNING rental_id, rider_id INTO v_rental, v_rider;
        PERFORM request_payment(v_rider, v_rental);
        INSERT INTO recovery_fixtures
        SELECT v_label, p.rental_id, p.rider_id, p.payment_reference, p.payment_id, p.updated_at
          FROM payment p WHERE p.rental_id = v_rental;
    END LOOP;
END $$;

SELECT rider_id AS write_actor, payment_reference AS write_ref
  FROM recovery_fixtures WHERE label = 'write' \gset
SELECT rider_id AS event_actor, payment_reference AS event_ref
  FROM recovery_fixtures WHERE label = 'event' \gset
SELECT rider_id AS transaction_actor, payment_reference AS transaction_ref
  FROM recovery_fixtures WHERE label = 'transaction' \gset

-- A failing confirmation UPDATE must not undo the committed simulator result.
SELECT format('CREATE TRIGGER zz_reject_confirmation BEFORE UPDATE ON bicycle_rental.payment
    FOR EACH ROW WHEN (NEW.payment_reference = %L::uuid)
    EXECUTE FUNCTION pg_temp.reject_confirmation_write()', :'write_ref') \gexec
\set ON_ERROR_STOP off
CALL bicycle_rental.submit_payment(:write_actor, :'write_ref');
\set write_failure_state :SQLSTATE
\set ON_ERROR_STOP on
DROP TRIGGER zz_reject_confirmation ON payment;
SELECT pg_temp.check_recovery(:'write_failure_state' = 'P0001', 'confirmation write failure was injected');
SELECT pg_temp.check_recovery(
    (SELECT p.status = 'pending' AND p.updated_at = f.pending_updated_at
       FROM payment p JOIN recovery_fixtures f USING (payment_id) WHERE f.label = 'write'),
    'confirmation failure leaves application payment pending and timestamp unchanged');
SELECT pg_temp.check_recovery(
    (SELECT count(*) = 1 FROM payment_simulator_record WHERE payment_reference = :'write_ref'),
    'simulator settlement survives failed CALL');
CREATE TEMP TABLE write_settlement AS
    SELECT * FROM payment_simulator_record WHERE payment_reference = :'write_ref';
SELECT pg_temp.check_recovery(
    NOT EXISTS (SELECT 1 FROM payment_event e JOIN recovery_fixtures f USING (payment_id)
                 WHERE f.label = 'write' AND e.event_type = 'confirmed_successful'),
    'failed confirmation creates no confirmation event');

-- Changing the setup scenario after settlement must not change a replayed result.
SET bicycle_rental.privileged_setup = 'true';
INSERT INTO payment_simulator_scenario (rental_id, scenario)
    SELECT rental_id, 'failure' FROM recovery_fixtures WHERE label = 'write';
SET bicycle_rental.privileged_setup = 'false';
CALL bicycle_rental.submit_payment(:write_actor, :'write_ref');
SELECT pg_temp.check_recovery(
    (SELECT status = 'successful' FROM payment WHERE payment_reference = :'write_ref'),
    'retry recovers original success despite a changed scenario');
SELECT pg_temp.check_recovery(
    (SELECT s IS NOT DISTINCT FROM w FROM payment_simulator_record s
       JOIN write_settlement w USING (payment_reference)),
    'retry preserves the complete original simulator record');
SELECT pg_temp.check_recovery(
    (SELECT count(*) = 1 FROM payment_event e JOIN recovery_fixtures f USING (payment_id)
      WHERE f.label = 'write' AND e.event_type = 'confirmed_successful'),
    'recovery records exactly one successful confirmation');

-- The confirmation-event insert is part of the same phase as the status UPDATE.
SELECT format('CREATE TRIGGER zz_reject_confirmation_event BEFORE INSERT ON bicycle_rental.payment_event
    FOR EACH ROW WHEN (NEW.payment_id = %s AND NEW.event_type = ''confirmed_successful'')
    EXECUTE FUNCTION pg_temp.reject_confirmation_write()', payment_id)
  FROM recovery_fixtures WHERE label = 'event' \gexec
\set ON_ERROR_STOP off
CALL bicycle_rental.submit_payment(:event_actor, :'event_ref');
\set event_failure_state :SQLSTATE
\set ON_ERROR_STOP on
DROP TRIGGER zz_reject_confirmation_event ON payment_event;
SELECT pg_temp.check_recovery(:'event_failure_state' = 'P0001', 'confirmation event failure was injected');
SELECT pg_temp.check_recovery(
    (SELECT p.status = 'pending' AND p.updated_at = f.pending_updated_at
       FROM payment p JOIN recovery_fixtures f USING (payment_id) WHERE f.label = 'event'),
    'event failure rolls back the application status and timestamp');
CREATE TEMP TABLE event_settlement AS
    SELECT * FROM payment_simulator_record WHERE payment_reference = :'event_ref';
SELECT pg_temp.check_recovery((SELECT count(*) = 1 FROM event_settlement),
    'event failure preserves the simulator settlement');
CALL bicycle_rental.submit_payment(:event_actor, :'event_ref');
SELECT pg_temp.check_recovery(
    (SELECT status = 'successful' FROM payment WHERE payment_reference = :'event_ref'),
    'event failure can be recovered');
SELECT pg_temp.check_recovery(
    (SELECT s IS NOT DISTINCT FROM old FROM payment_simulator_record s
       JOIN event_settlement old USING (payment_reference)),
    'event failure recovery reuses the original settlement');
SELECT pg_temp.check_recovery(
    (SELECT count(*) = 1 FROM payment_event e JOIN recovery_fixtures f USING (payment_id)
      WHERE f.label = 'event' AND e.event_type = 'confirmed_successful'),
    'event failure recovery records exactly one confirmation');
CREATE TEMP TABLE terminal_payment AS
    SELECT * FROM payment WHERE payment_reference = :'event_ref';
CREATE TEMP TABLE terminal_events AS
    SELECT e.* FROM payment_event e JOIN terminal_payment p USING (payment_id);
CALL bicycle_rental.submit_payment(:event_actor, :'event_ref');
SELECT pg_temp.check_recovery(
    (SELECT p IS NOT DISTINCT FROM old FROM payment p JOIN terminal_payment old USING (payment_id)),
    'terminal retry leaves payment and timestamps unchanged');
SELECT pg_temp.check_recovery(
    (SELECT count(*) FROM payment_event e JOIN terminal_payment p USING (payment_id))
        = (SELECT count(*) FROM terminal_events),
    'terminal retry adds no attempt or confirmation events');

-- An explicit caller transaction cannot absorb the simulator commit boundary.
BEGIN;
\set ON_ERROR_STOP off
CALL bicycle_rental.submit_payment(:transaction_actor, :'transaction_ref');
\set transaction_failure_state :SQLSTATE
ROLLBACK;
\set ON_ERROR_STOP on
SELECT pg_temp.check_recovery(:'transaction_failure_state' = '2D000',
    'submission inside an explicit transaction is rejected');
SELECT pg_temp.check_recovery(
    NOT EXISTS (SELECT 1 FROM payment_simulator_record WHERE payment_reference = :'transaction_ref'),
    'invalid transaction context contacts no simulator');
SELECT pg_temp.check_recovery(
    (SELECT status = 'pending' FROM payment WHERE payment_reference = :'transaction_ref'),
    'invalid transaction context leaves payment pending');

SELECT count(*) AS payment_recovery_assertions_passed FROM recovery_results;

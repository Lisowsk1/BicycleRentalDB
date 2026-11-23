-- V017: Commit simulator settlement before applying application confirmation.
-- The public submission entry point is now CALL submit_payment(...), in autocommit
-- mode. A function cannot provide the required transaction boundary (F-059/F-064).

CREATE FUNCTION bicycle_rental.prepare_payment_submission(p_actor_id bigint, p_payment_reference uuid)
RETURNS TABLE (payment_reference uuid, status bicycle_rental.payment_status,
               amount numeric, currency varchar, uncertain boolean, confirmation_available boolean)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = bicycle_rental, public, pg_temp
AS $$
DECLARE
    v_payment payment%ROWTYPE;
    v_outcome text;
BEGIN
    SELECT p.* INTO v_payment FROM payment p
     WHERE p.payment_reference = p_payment_reference AND p.rider_id = p_actor_id
       FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'operation not permitted' USING ERRCODE = '42501';
    END IF;

    IF v_payment.status = 'pending' THEN
        INSERT INTO payment_event (payment_id, actor_id, event_type, previous_status, new_status)
        VALUES (v_payment.payment_id, p_actor_id, 'submission_attempted', 'pending', 'pending');

        v_outcome := simulator_submit(v_payment.payment_reference, v_payment.rental_id,
                                      v_payment.amount, v_payment.currency);
        IF v_outcome IS NULL THEN
            INSERT INTO payment_event (payment_id, actor_id, event_type, previous_status, new_status)
            VALUES (v_payment.payment_id, p_actor_id, 'submission_unconfirmed', 'pending', 'pending');
        END IF;
    END IF;

    RETURN QUERY SELECT v_payment.payment_reference, v_payment.status, v_payment.amount,
                        v_payment.currency, v_payment.status = 'pending', v_outcome IS NOT NULL;
END $$;

-- Both phase functions authorize the owner independently. Confirmation accepts
-- no client-supplied outcome: it reads and verifies the retained simulator result.
CREATE FUNCTION bicycle_rental.confirm_payment_submission(p_actor_id bigint, p_payment_reference uuid)
RETURNS TABLE (payment_reference uuid, status bicycle_rental.payment_status,
               amount numeric, currency varchar, uncertain boolean)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = bicycle_rental, public, pg_temp
AS $$
DECLARE
    v_payment payment%ROWTYPE;
    v_result payment_simulator_record%ROWTYPE;
BEGIN
    SELECT p.* INTO v_payment FROM payment p
     WHERE p.payment_reference = p_payment_reference AND p.rider_id = p_actor_id
       FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'operation not permitted' USING ERRCODE = '42501';
    END IF;

    IF v_payment.status = 'pending' THEN
        SELECT s.* INTO v_result FROM payment_simulator_record s
         WHERE s.payment_reference = p_payment_reference;
        IF NOT FOUND OR NOT v_result.response_delivered
           OR v_result.rental_id IS DISTINCT FROM v_payment.rental_id
           OR v_result.amount IS DISTINCT FROM v_payment.amount
           OR v_result.currency IS DISTINCT FROM v_payment.currency THEN
            RAISE EXCEPTION 'no matching definitive simulator confirmation'
                USING ERRCODE = '22023';
        END IF;
        PERFORM apply_payment_confirmation(v_payment.payment_reference, v_payment.rental_id,
            v_payment.amount, v_payment.currency, v_result.outcome::text);
    END IF;

    RETURN QUERY SELECT p.payment_reference, p.status, p.amount, p.currency, p.status = 'pending'
                   FROM payment p WHERE p.payment_reference = p_payment_reference;
END $$;

DROP FUNCTION bicycle_rental.submit_payment(bigint, uuid);

-- Transaction control requires SECURITY INVOKER and no procedure-level SET clause.
-- All data access is through the schema-qualified, owner-authorized phase functions.
CREATE PROCEDURE bicycle_rental.submit_payment(
    IN p_actor_id bigint, IN p_payment_reference uuid,
    INOUT status bicycle_rental.payment_status DEFAULT NULL,
    INOUT uncertain boolean DEFAULT NULL)
LANGUAGE plpgsql
AS $$
DECLARE
    v_submission record;
BEGIN
    -- Reject an explicit caller transaction before contacting the simulator.
    -- Pending payment creation must already have committed in request_payment.
    COMMIT;

    SELECT * INTO v_submission
      FROM bicycle_rental.prepare_payment_submission(p_actor_id, p_payment_reference);
    status := v_submission.status;
    uncertain := v_submission.uncertain;
    COMMIT;

    -- Settlement is now durable. Any confirmation or confirmation-event failure
    -- rolls back only this phase; retry recovers the original reference/result.
    IF v_submission.confirmation_available THEN
        SELECT c.status, c.uncertain INTO status, uncertain
          FROM bicycle_rental.confirm_payment_submission(p_actor_id, p_payment_reference) c;
        COMMIT;
    END IF;
END $$;

COMMENT ON PROCEDURE bicycle_rental.submit_payment(bigint, uuid, bicycle_rental.payment_status, boolean)
IS 'Call at top level in autocommit mode after request_payment commits; retry the same reference after uncertainty or a confirmation failure.';

-- V009: Electric bicycle subtype table and subtype consistency checks
--
-- Scope:
--   * Creates electric_bicycle (subtype of bicycle).
--   * Creates the subtype consistency check function.
--   * Creates deferred constraint triggers on bicycle and electric_bicycle
--     so that every 'electric' bicycle has exactly one electric_bicycle
--     record and no 'regular' bicycle has one.

BEGIN;

SET LOCAL search_path = bicycle_rental, public;

-- 1. Electric bicycle table
CREATE TABLE bicycle_rental.electric_bicycle (
    bicycle_id BIGINT NOT NULL,
    battery_percentage SMALLINT,
    bicycle_type bicycle_rental.bicycle_type NOT NULL,

    CONSTRAINT electric_bicycle_pkey
        PRIMARY KEY (bicycle_id),

    -- Composite FK guarantees the parent bicycle is of the same type
    CONSTRAINT electric_bicycle_bicycle_id_type_fkey
        FOREIGN KEY (bicycle_id, bicycle_type)
        REFERENCES bicycle_rental.bicycle (bicycle_id, bicycle_type)
        MATCH SIMPLE
        ON UPDATE NO ACTION
        ON DELETE NO ACTION,

    CONSTRAINT chk_electric_bicycle_type_electric
        CHECK (bicycle_type = 'electric'::bicycle_rental.bicycle_type),

    CONSTRAINT chk_electric_bicycle_battery_in_range
        CHECK (
            battery_percentage IS NULL
            OR (battery_percentage >= 0 AND battery_percentage <= 100)
        )
);

ALTER TABLE bicycle_rental.electric_bicycle OWNER TO bicycle_rental;

-- 2. Subtype consistency check function
CREATE FUNCTION bicycle_rental.check_electric_bicycle_subtype()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $function$
DECLARE
    checked_bicycle_id BIGINT;
    checked_bicycle_type TEXT;
    subtype_exists BOOLEAN;
BEGIN
    IF TG_OP = 'DELETE' THEN
        checked_bicycle_id := OLD.bicycle_id;
    ELSE
        checked_bicycle_id := NEW.bicycle_id;
    END IF;

    SELECT b.bicycle_type::TEXT
    INTO checked_bicycle_type
    FROM bicycle_rental.bicycle AS b
    WHERE b.bicycle_id = checked_bicycle_id;

    -- The parent bicycle may no longer exist.
    IF NOT FOUND THEN
        RETURN NULL;
    END IF;

    SELECT EXISTS (
        SELECT 1
        FROM bicycle_rental.electric_bicycle AS eb
        WHERE eb.bicycle_id = checked_bicycle_id
    )
    INTO subtype_exists;

    IF checked_bicycle_type = 'electric'
       AND NOT subtype_exists THEN
        RAISE EXCEPTION
            'Electric bicycle % must have an electric bicycle record',
            checked_bicycle_id;
    END IF;

    IF checked_bicycle_type = 'regular'
       AND subtype_exists THEN
        RAISE EXCEPTION
            'Regular bicycle % cannot have an electric bicycle record',
            checked_bicycle_id;
    END IF;

    RETURN NULL;
END;
$function$;

ALTER FUNCTION bicycle_rental.check_electric_bicycle_subtype()
    OWNER TO bicycle_rental;

-- 3. Deferred constraint triggers
CREATE CONSTRAINT TRIGGER trg_electric_bicycle_check_subtype
    AFTER INSERT OR UPDATE OR DELETE
    ON bicycle_rental.electric_bicycle
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW
    EXECUTE FUNCTION bicycle_rental.check_electric_bicycle_subtype();

CREATE CONSTRAINT TRIGGER trg_bicycle_check_subtype
    AFTER INSERT OR UPDATE
    ON bicycle_rental.bicycle
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW
    EXECUTE FUNCTION bicycle_rental.check_electric_bicycle_subtype();

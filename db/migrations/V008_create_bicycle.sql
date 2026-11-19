-- V008: Bicycle table, bicycle types, identifier uniqueness and immutability
--
-- Scope:
--   * Creates the bicycle-related ENUM types.
--   * Creates bicycle and its constraints.
--   * Enforces case-insensitive, whitespace-trimmed identifier uniqueness.
--   * Prevents bicycle deletion and changes to identifier/bicycle_type.

BEGIN;

SET LOCAL search_path = bicycle_rental, public;

-- 1. Bicycle ENUM types
CREATE TYPE bicycle_rental.bicycle_placement AS ENUM (
    'station',
    'active_rental',
    'maintenance_provider'
);

ALTER TYPE bicycle_rental.bicycle_placement OWNER TO bicycle_rental;

CREATE TYPE bicycle_rental.bicycle_type AS ENUM (
    'regular',
    'electric'
);

ALTER TYPE bicycle_rental.bicycle_type OWNER TO bicycle_rental;

CREATE TYPE bicycle_rental.maintenance_state AS ENUM (
    'serviceable',
    'unavailable_for_maintenance'
);

ALTER TYPE bicycle_rental.maintenance_state OWNER TO bicycle_rental;

-- 2. Bicycle table
CREATE TABLE bicycle_rental.bicycle (
    bicycle_id BIGINT NOT NULL,
    identifier VARCHAR(100) NOT NULL,
    bicycle_type bicycle_rental.bicycle_type NOT NULL,
    maintenance_state bicycle_rental.maintenance_state NOT NULL,
    placement bicycle_rental.bicycle_placement NOT NULL,
    current_station_id BIGINT,
    current_provider_id BIGINT,

    CONSTRAINT bicycle_pkey
        PRIMARY KEY (bicycle_id),

    -- Supports the composite foreign key from ElectricBicycle.
    CONSTRAINT uq_bicycle_bicycle_id_type
        UNIQUE (bicycle_id, bicycle_type),

    CONSTRAINT bicycle_station_id_fkey
        FOREIGN KEY (current_station_id)
        REFERENCES bicycle_rental.station (station_id)
        ON UPDATE NO ACTION
        ON DELETE NO ACTION,

    CONSTRAINT chk_bicycle_placement_maintenance_not_null
        CHECK (
            (placement = 'maintenance_provider')
            = (current_provider_id IS NOT NULL)
        ),

    CONSTRAINT chk_bicycle_placement_station_not_null
        CHECK (
            (placement = 'station')
            = (current_station_id IS NOT NULL)
        ),

    CONSTRAINT chk_bicycle_identifier_not_blank
        CHECK (BTRIM(identifier) <> '')
);

ALTER TABLE bicycle_rental.bicycle OWNER TO bicycle_rental;

-- 3. Identifier uniqueness after trimming whitespace and ignoring case.
CREATE UNIQUE INDEX uq_bicycle_identifier
    ON bicycle_rental.bicycle (LOWER(BTRIM(identifier)));

-- 4. Prevent bicycle deletion and changes to immutable attributes.
CREATE FUNCTION bicycle_rental.bicycle_protect_immutable()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $function$
BEGIN
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'Deleting bicycles is prohibited';
    END IF;

    IF NEW.identifier IS DISTINCT FROM OLD.identifier THEN
        RAISE EXCEPTION 'Bicycle identifier cannot be changed';
    END IF;

    IF NEW.bicycle_type IS DISTINCT FROM OLD.bicycle_type THEN
        RAISE EXCEPTION 'Bicycle type cannot be changed';
    END IF;

    RETURN NEW;
END;
$function$;

ALTER FUNCTION bicycle_rental.bicycle_protect_immutable()
    OWNER TO bicycle_rental;

CREATE TRIGGER trg_bicycle_protect_immutable
    BEFORE UPDATE OR DELETE
    ON bicycle_rental.bicycle
    FOR EACH ROW
    EXECUTE FUNCTION bicycle_rental.bicycle_protect_immutable();

COMMIT;
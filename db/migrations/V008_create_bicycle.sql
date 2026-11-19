-- V008: Bicycle table, bicycle types, identifier uniqueness and immutability
--
-- Scope:
--   * Creates the bicycle-related ENUM types.
--   * Creates maintenance_provider and enforces provider placement references.
--   * Creates bicycle and its constraints.
--   * Enforces case-insensitive, whitespace-trimmed identifier uniqueness.
--   * Prevents bicycle deletion and changes to identifier/bicycle_type.

SET LOCAL search_path = bicycle_rental, public;

-- 1. Bicycle ENUM types
CREATE TYPE bicycle_rental.bicycle_placement AS ENUM (
    'station',
    'active_rental',
    'maintenance_provider'
);

CREATE TYPE bicycle_rental.maintenance_state AS ENUM (
    'serviceable',
    'unavailable_for_maintenance'
);

-- 2. Maintenance providers, required by the bicycle placement foreign key (F-091).
CREATE TABLE bicycle_rental.maintenance_provider (
    provider_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name VARCHAR(100) NOT NULL,
    contact_email TEXT,
    contact_phone TEXT,
    is_active BOOLEAN NOT NULL DEFAULT true,
    CONSTRAINT chk_provider_name_not_blank
        CHECK (bicycle_rental.trim_ws(name) <> '')
);

CREATE TRIGGER trg_maintenance_provider_no_delete
    BEFORE DELETE ON bicycle_rental.maintenance_provider
    FOR EACH ROW EXECUTE FUNCTION bicycle_rental.trg_forbid_delete();

-- 3. Bicycle table
CREATE TABLE bicycle_rental.bicycle (
    bicycle_id bigint NOT NULL GENERATED ALWAYS AS IDENTITY ( INCREMENT 1 START 1 MINVALUE 1 MAXVALUE 9223372036854775807 CACHE 1 ),
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

    CONSTRAINT bicycle_provider_id_fkey
        FOREIGN KEY (current_provider_id)
        REFERENCES bicycle_rental.maintenance_provider (provider_id)
        ON UPDATE RESTRICT
        ON DELETE RESTRICT,

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
        CHECK (bicycle_rental.trim_ws(identifier) <> '')
);

CREATE INDEX ix_bicycle_station ON bicycle_rental.bicycle (current_station_id)
    WHERE current_station_id IS NOT NULL;
CREATE INDEX ix_bicycle_provider ON bicycle_rental.bicycle (current_provider_id)
    WHERE current_provider_id IS NOT NULL;

-- 4. Identifier uniqueness after trimming whitespace and ignoring case.
CREATE UNIQUE INDEX uq_bicycle_identifier
    ON bicycle_rental.bicycle (LOWER(bicycle_rental.trim_ws(identifier)));

-- 5. Prevent bicycle deletion and changes to immutable attributes.
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

    IF NEW.bicycle_id IS DISTINCT FROM OLD.bicycle_id THEN
        RAISE EXCEPTION 'Bicycle identity cannot be changed' USING ERRCODE = '23514';
    END IF;

    IF NEW.bicycle_type IS DISTINCT FROM OLD.bicycle_type THEN
        RAISE EXCEPTION 'Bicycle type cannot be changed';
    END IF;

    RETURN NEW;
END;
$function$;

CREATE TRIGGER trg_bicycle_protect_immutable
    BEFORE UPDATE OR DELETE
    ON bicycle_rental.bicycle
    FOR EACH ROW
    EXECUTE FUNCTION bicycle_rental.bicycle_protect_immutable();

-- V007: Create Station
--
-- Creates the station table, validates station location/name fields,
-- and prevents station deletion.

BEGIN;

-- 1. Station table
CREATE TABLE bicycle_rental.station (
    station_id BIGINT NOT NULL,
    name VARCHAR(100) NOT NULL,
    address VARCHAR(200) NOT NULL,
    latitude NUMERIC(10,7) NOT NULL,
    longitude NUMERIC(10,7) NOT NULL,
    rental_enabled BOOLEAN NOT NULL,
    return_enabled BOOLEAN NOT NULL,

    CONSTRAINT station_pkey
        PRIMARY KEY (station_id),

    CONSTRAINT chk_station_latitude
        CHECK (latitude BETWEEN -90 AND 90),

    CONSTRAINT chk_station_longitude
        CHECK (longitude BETWEEN -180 AND 180),

    CONSTRAINT chk_station_name_address
        CHECK (
            BTRIM(name) <> ''
            AND BTRIM(address) <> ''
        )
);

ALTER TABLE bicycle_rental.station OWNER TO bicycle_rental;

-- 2. Prevent station deletion
CREATE FUNCTION bicycle_rental.prevent_station_deletion()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $function$
BEGIN
    RAISE EXCEPTION 'Deleting stations is prohibited';
END;
$function$;

ALTER FUNCTION bicycle_rental.prevent_station_deletion()
    OWNER TO bicycle_rental;

CREATE TRIGGER trg_prevent_station_deletion
    BEFORE DELETE
    ON bicycle_rental.station
    FOR EACH ROW
    EXECUTE FUNCTION bicycle_rental.prevent_station_deletion();

COMMIT;

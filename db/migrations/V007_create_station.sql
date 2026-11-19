-- V007: Create Station
--
-- Creates the station table, validates station location/name fields,
-- and prevents station deletion.

-- 1. Station table
CREATE TABLE bicycle_rental.station (
    station_id bigint NOT NULL GENERATED ALWAYS AS IDENTITY ( INCREMENT 1 START 1 MINVALUE 1 MAXVALUE 9223372036854775807 CACHE 1 ),
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
            bicycle_rental.trim_ws(name) <> ''
            AND bicycle_rental.trim_ws(address) <> ''
        )
);

-- 2. Prevent station deletion
CREATE FUNCTION bicycle_rental.prevent_station_deletion()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $function$
BEGIN
    RAISE EXCEPTION 'Deleting stations is prohibited';
END;
$function$;

CREATE TRIGGER trg_prevent_station_deletion
    BEFORE DELETE
    ON bicycle_rental.station
    FOR EACH ROW
    EXECUTE FUNCTION bicycle_rental.prevent_station_deletion();


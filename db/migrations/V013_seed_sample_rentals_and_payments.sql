-- V013: Basic seed data for Rental and Payment (S-001, S-002).
-- Seeds sample stations, bicycles, an active rider, one completed rental with a
-- successful payment, and one active rental using the seeded tariffs from V003.

SET LOCAL search_path = bicycle_rental, public;
SET LOCAL bicycle_rental.privileged_setup = 'true';

DO $$
DECLARE
    v_station_1_id        bigint;
    v_station_2_id        bigint;
    v_reg_bike_id         bigint;
    v_elc_bike_id         bigint;
    v_rider_id            bigint;
    v_regular_tariff      bicycle_rental.tariff%ROWTYPE;
    v_electric_tariff     bicycle_rental.tariff%ROWTYPE;
    v_completed_rental_id bigint;
BEGIN
    SELECT *
      INTO v_regular_tariff
      FROM bicycle_rental.tariff
     WHERE bicycle_type = 'regular' AND is_active = true
     LIMIT 1;

    SELECT *
      INTO v_electric_tariff
      FROM bicycle_rental.tariff
     WHERE bicycle_type = 'electric' AND is_active = true
     LIMIT 1;

    -- 1. Seed two stations
    INSERT INTO bicycle_rental.station (name, address, latitude, longitude, rental_enabled, return_enabled)
    VALUES ('Central Station', 'ul. Pilsudskiego 105, Wroclaw', 51.0988890, 17.0366670, true, true)
    RETURNING station_id INTO v_station_1_id;

    INSERT INTO bicycle_rental.station (name, address, latitude, longitude, rental_enabled, return_enabled)
    VALUES ('Market Square', 'Rynek 1, Wroclaw', 51.1097220, 17.0319440, true, true)
    RETURNING station_id INTO v_station_2_id;

    -- 2. Seed one regular bicycle and one electric bicycle (with subtype row)
    INSERT INTO bicycle_rental.bicycle (identifier, bicycle_type, maintenance_state, placement, current_station_id)
    VALUES ('BIKE-REG-001', 'regular', 'serviceable', 'station', v_station_2_id)
    RETURNING bicycle_id INTO v_reg_bike_id;

    INSERT INTO bicycle_rental.bicycle (identifier, bicycle_type, maintenance_state, placement, current_station_id)
    VALUES ('BIKE-ELC-001', 'electric', 'serviceable', 'station', v_station_1_id)
    RETURNING bicycle_id INTO v_elc_bike_id;

    INSERT INTO bicycle_rental.electric_bicycle (bicycle_id, battery_percentage, bicycle_type)
    VALUES (v_elc_bike_id, 85, 'electric');

    -- 3. Seed one active rider account + subtype atomically (V004/V005)
    INSERT INTO bicycle_rental.account (first_name, last_name, email, password_hash, role)
    VALUES (
        'Jan',
        'Kowalski',
        'jan.kowalski@bicyclerental.local',
        public.crypt('SampleRider123!', public.gen_salt('bf', 10)),
        'rider'
    )
    RETURNING account_id INTO v_rider_id;

    INSERT INTO bicycle_rental.rider (account_id, status, role)
    VALUES (v_rider_id, 'active', 'rider');

    -- 4. Completed rental: 25 min = 2 started 900s blocks * 2.50 PLN = 5.00 PLN (F-081)
    INSERT INTO bicycle_rental.rental (
        rider_id,
        bicycle_id,
        pickup_station_id,
        return_station_id,
        tariff_id,
        start_time,
        end_time,
        captured_price_per_block,
        captured_block_length_seconds,
        captured_currency,
        final_charge,
        bicycle_type
    )
    VALUES (
        v_rider_id,
        v_reg_bike_id,
        v_station_1_id,
        v_station_2_id,
        v_regular_tariff.tariff_id,
        '2026-10-01 10:00:00+00',
        '2026-10-01 10:25:00+00',
        v_regular_tariff.price_per_block,
        v_regular_tariff.block_length_seconds,
        v_regular_tariff.currency,
        ROUND(2 * v_regular_tariff.price_per_block, 2),
        'regular'
    )
    RETURNING rental_id INTO v_completed_rental_id;

    -- 5. Successful payment matching the completed rental's rider, final_charge, and currency
    INSERT INTO bicycle_rental.payment (
        rental_id,
        rider_id,
        amount,
        currency,
        status,
        created_at,
        updated_at
    )
    VALUES (
        v_completed_rental_id,
        v_rider_id,
        ROUND(2 * v_regular_tariff.price_per_block, 2),
        v_regular_tariff.currency,
        'successful',
        '2026-10-01 10:26:00+00',
        '2026-10-01 10:26:05+00'
    );

    -- 6. Active rental on BIKE-ELC-001 + matching placement update on bicycle
    INSERT INTO bicycle_rental.rental (
        rider_id,
        bicycle_id,
        pickup_station_id,
        tariff_id,
        start_time,
        captured_price_per_block,
        captured_block_length_seconds,
        captured_currency,
        bicycle_type
    )
    VALUES (
        v_rider_id,
        v_elc_bike_id,
        v_station_1_id,
        v_electric_tariff.tariff_id,
        '2026-10-01 11:00:00+00',
        v_electric_tariff.price_per_block,
        v_electric_tariff.block_length_seconds,
        v_electric_tariff.currency,
        'electric'
    );

    UPDATE bicycle_rental.bicycle
       SET placement = 'active_rental',
           current_station_id = NULL
     WHERE bicycle_id = v_elc_bike_id;
END $$;

RESET bicycle_rental.privileged_setup;
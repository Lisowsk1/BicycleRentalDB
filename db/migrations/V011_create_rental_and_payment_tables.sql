-- V011: Create Rental and Payment tables, PKs, FKs, composite FKs, checks, and unique indexes.
-- Requirements: F-029, F-064..F-074, F-077, F-080..F-082, F-085..F-091, F-097, F-110.

SET LOCAL search_path = bicycle_rental, public;

-- 1. Payment status enum
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_type t
        JOIN pg_namespace n ON n.oid = t.typnamespace
        WHERE t.typname = 'payment_status'
          AND n.nspname = 'bicycle_rental'
    ) THEN
        CREATE TYPE bicycle_rental.payment_status AS ENUM (
            'pending',
            'successful',
            'failed'
        );
    END IF;
END $$;

-- 2. Rental table
CREATE TABLE bicycle_rental.rental (
    rental_id                     bigint GENERATED ALWAYS AS IDENTITY,
    rider_id                      bigint NOT NULL,
    bicycle_id                    bigint NOT NULL,
    pickup_station_id             bigint NOT NULL,
    return_station_id             bigint,
    tariff_id                     bigint NOT NULL,
    start_time                    timestamptz NOT NULL DEFAULT clock_timestamp(),
    end_time                      timestamptz,
    captured_price_per_block      numeric(12, 2) NOT NULL,
    captured_block_length_seconds integer NOT NULL,
    captured_currency             varchar NOT NULL,
    final_charge                  numeric(12, 2),
    returned_by_staff_id          bigint,
    bicycle_type                  bicycle_rental.bicycle_type NOT NULL,

    CONSTRAINT pk_rental PRIMARY KEY (rental_id),

    -- ERD composite unique keys referenced by FaultReport and Payment
    CONSTRAINT uq_rental_id_bicycle UNIQUE (rental_id, bicycle_id),
    CONSTRAINT uq_rental_payment_snapshot UNIQUE (rental_id, rider_id, final_charge, captured_currency),

    -- Foreign keys to Stage 1 entities
    CONSTRAINT fk_rental_rider FOREIGN KEY (rider_id)
        REFERENCES bicycle_rental.rider (account_id)
        ON UPDATE RESTRICT ON DELETE RESTRICT,

    CONSTRAINT fk_rental_bicycle FOREIGN KEY (bicycle_id)
        REFERENCES bicycle_rental.bicycle (bicycle_id)
        ON UPDATE RESTRICT ON DELETE RESTRICT,

    CONSTRAINT fk_rental_bicycle_type FOREIGN KEY (bicycle_id, bicycle_type)
        REFERENCES bicycle_rental.bicycle (bicycle_id, bicycle_type)
        ON UPDATE RESTRICT ON DELETE RESTRICT,

    CONSTRAINT fk_rental_pickup_station FOREIGN KEY (pickup_station_id)
        REFERENCES bicycle_rental.station (station_id)
        ON UPDATE RESTRICT ON DELETE RESTRICT,

    CONSTRAINT fk_rental_return_station FOREIGN KEY (return_station_id)
        REFERENCES bicycle_rental.station (station_id)
        ON UPDATE RESTRICT ON DELETE RESTRICT,

    CONSTRAINT fk_rental_tariff FOREIGN KEY (tariff_id)
        REFERENCES bicycle_rental.tariff (tariff_id)
        ON UPDATE RESTRICT ON DELETE RESTRICT,

    CONSTRAINT fk_rental_tariff_type FOREIGN KEY (tariff_id, bicycle_type)
        REFERENCES bicycle_rental.tariff (tariff_id, bicycle_type)
        ON UPDATE RESTRICT ON DELETE RESTRICT,

    CONSTRAINT fk_rental_returned_by_staff FOREIGN KEY (returned_by_staff_id)
        REFERENCES bicycle_rental.staff (account_id)
        ON UPDATE RESTRICT ON DELETE RESTRICT,

    -- Active vs. completed field consistency (F-071, F-073)
    CONSTRAINT ck_rental_state_fields_consistency CHECK (
        (end_time IS NULL AND return_station_id IS NULL AND final_charge IS NULL)
        OR
        (end_time IS NOT NULL AND return_station_id IS NOT NULL AND final_charge IS NOT NULL)
    ),

    -- Staff attribution allowed only on completed rentals; end_time >= start_time (F-073, F-074, F-110)
    CONSTRAINT ck_rental_staff_return_and_time_order CHECK (
        (end_time IS NULL AND returned_by_staff_id IS NULL)
        OR
        (end_time IS NOT NULL AND end_time >= start_time)
    ),

    -- Pricing snapshot and charge domain checks (F-078, F-080, F-082)
    CONSTRAINT ck_rental_pricing_snapshot_valid CHECK (
        captured_price_per_block >= 0
        AND captured_block_length_seconds > 0
        AND bicycle_rental.trim_ws(captured_currency) <> ''
        AND (final_charge IS NULL OR final_charge >= 0)
    )
);

-- Enforce at most one active rental per rider and per bicycle (F-029, F-065, F-067)
CREATE UNIQUE INDEX ux_rental_active_rider
    ON bicycle_rental.rental (rider_id)
    WHERE end_time IS NULL;

CREATE UNIQUE INDEX ux_rental_active_bicycle
    ON bicycle_rental.rental (bicycle_id)
    WHERE end_time IS NULL;

-- Lookup & statistics indexes from ERD
CREATE INDEX ix_rental_rider_start_time
    ON bicycle_rental.rental (rider_id, start_time DESC);

CREATE INDEX ix_rental_bicycle_start_time
    ON bicycle_rental.rental (bicycle_id, start_time DESC);

CREATE INDEX ix_rental_completed_station_pair
    ON bicycle_rental.rental (pickup_station_id, return_station_id)
    WHERE end_time IS NOT NULL;

-- 3. Payment table
CREATE TABLE bicycle_rental.payment (
    payment_id bigint GENERATED ALWAYS AS IDENTITY,
    rental_id  bigint NOT NULL,
    rider_id   bigint NOT NULL,
    amount     numeric(12, 2) NOT NULL,
    currency   varchar NOT NULL,
    status     bicycle_rental.payment_status NOT NULL DEFAULT 'pending',
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),

    CONSTRAINT pk_payment PRIMARY KEY (payment_id),

    -- At most one payment per rental (F-090)
    CONSTRAINT uq_payment_rental_id UNIQUE (rental_id),

    CONSTRAINT fk_payment_rental FOREIGN KEY (rental_id)
        REFERENCES bicycle_rental.rental (rental_id)
        ON UPDATE RESTRICT ON DELETE RESTRICT,

    CONSTRAINT fk_payment_rider FOREIGN KEY (rider_id)
        REFERENCES bicycle_rental.rider (account_id)
        ON UPDATE RESTRICT ON DELETE RESTRICT,

    -- Composite FK enforcing completed rental (non-null final_charge) and matching rider, amount, and currency
    CONSTRAINT fk_payment_rental_snapshot FOREIGN KEY (rental_id, rider_id, amount, currency)
        REFERENCES bicycle_rental.rental (rental_id, rider_id, final_charge, captured_currency)
        ON UPDATE RESTRICT ON DELETE RESTRICT,

    -- Positive amount and non-blank currency (F-086, F-090)
    CONSTRAINT ck_payment_amount_and_currency CHECK (
        amount > 0 AND bicycle_rental.trim_ws(currency) <> ''
    ),

    CONSTRAINT ck_payment_updated_after_created CHECK (
        updated_at >= created_at
    )
);

CREATE INDEX ix_payment_rider_created_at
    ON bicycle_rental.payment (rider_id, created_at DESC);
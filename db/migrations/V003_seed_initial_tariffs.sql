-- Privileged setup transaction for initial tariff configuration (F-078, F-079)
SET LOCAL bicycle_rental.privileged_setup = 'true';

INSERT INTO bicycle_rental.tariff (
    bicycle_type,
    price_per_block,
    block_length_seconds,
    currency,
    is_active
)
VALUES
    ('regular',  2.50, 900, 'PLN', TRUE),
    ('electric', 4.50, 900, 'PLN', TRUE);
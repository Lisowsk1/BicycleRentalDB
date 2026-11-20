-- Verify the scaffold after Flyway has applied migrations.
-- This script does not create or modify database objects.
DO $$
DECLARE
    expected_table TEXT;
    expected_enum RECORD;
    actual_labels TEXT[];
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_namespace WHERE nspname = 'bicycle_rental'
    ) THEN
        RAISE EXCEPTION 'Expected bicycle_rental schema is missing';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM public.flyway_schema_history
        WHERE success AND type = 'SQL'
    ) THEN
        RAISE EXCEPTION 'Expected a successfully applied SQL migration';
    END IF;

    IF EXISTS (
        SELECT 1 FROM public.flyway_schema_history WHERE NOT success
    ) THEN
        RAISE EXCEPTION 'Flyway history contains a failed migration';
    END IF;

    FOREACH expected_table IN ARRAY ARRAY[
        'tariff', 'audit_entry', 'audit_detail', 'account', 'rider', 'staff',
        'station', 'bicycle', 'electric_bicycle', 'maintenance_provider', 'rental', 'payment'
    ]
    LOOP
        IF NOT EXISTS (
            SELECT 1 FROM pg_class c
            JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = 'bicycle_rental'
              AND c.relname = expected_table
              AND c.relkind IN ('r', 'p')
        ) THEN
            RAISE EXCEPTION 'Expected table bicycle_rental.% is missing', expected_table;
        END IF;
    END LOOP;

    FOR expected_enum IN
        SELECT * FROM (VALUES
            ('bicycle_type', ARRAY['regular', 'electric']::TEXT[]),
            ('bicycle_placement', ARRAY['station', 'active_rental', 'maintenance_provider']::TEXT[]),
            ('maintenance_state', ARRAY['serviceable', 'unavailable_for_maintenance']::TEXT[]),
            ('audit_action_type', ARRAY[
                'rider_block', 'rider_unblock', 'station_create', 'station_update',
                'maintenance_handover', 'maintenance_return',
                'maintenance_state_update', 'staff_return'
            ]::TEXT[]),
            ('audit_record_type', ARRAY['Rider', 'Bicycle', 'Station', 'Rental']::TEXT[])
        ) AS expected(type_name, labels)
    LOOP
        SELECT array_agg(e.enumlabel::TEXT ORDER BY e.enumsortorder)
        INTO actual_labels
        FROM pg_type t
        JOIN pg_namespace n ON n.oid = t.typnamespace
        JOIN pg_enum e ON e.enumtypid = t.oid
        WHERE n.nspname = 'bicycle_rental' AND t.typname = expected_enum.type_name;

        IF actual_labels IS DISTINCT FROM expected_enum.labels THEN
            RAISE EXCEPTION 'Enum bicycle_rental.%: expected %, found %',
                expected_enum.type_name, expected_enum.labels, actual_labels;
        END IF;
    END LOOP;

    -- These values describe the initial scaffold; update this check if a future
    -- migration intentionally changes the initial active tariff configuration.
    IF (SELECT count(*) FROM bicycle_rental.tariff WHERE is_active) <> 2
       OR EXISTS (
           SELECT 1
           FROM (VALUES ('regular', 2.50), ('electric', 4.50))
               AS expected(bicycle_type, price_per_block)
           WHERE NOT EXISTS (
               SELECT 1 FROM bicycle_rental.tariff t
               WHERE t.bicycle_type::TEXT = expected.bicycle_type
                 AND t.price_per_block = expected.price_per_block
                 AND t.block_length_seconds = 900
                 AND t.currency = 'PLN'
                 AND t.is_active
           )
       ) THEN
        RAISE EXCEPTION 'Expected active seed tariffs: regular 2.50 and electric 4.50 PLN per 900 seconds';
    END IF;
END;
$$;

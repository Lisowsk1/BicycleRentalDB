-- Verify the scaffold after Flyway has applied migrations.
-- This script does not create or modify database objects.
DO $$
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
END;
$$;

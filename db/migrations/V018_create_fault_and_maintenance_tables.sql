-- V018: Create FaultReport, MaintenanceJob, and MaintenanceTask tables,
-- composite FKs, checks, partial unique indexes, and query indexes.
-- Requirements: F-038..F-051, R-007.
--
-- Declarative constraint error codes:
--   23505  unique violation (duplicate PK, composite key, or second open/in_progress job per bicycle)
--   23503  foreign key violation (missing bicycle, account, provider, staff, rental, or job; or bicycle mismatch)
--   23514  check constraint violation (invalid status/timestamp combinations, blank text, or task_no <= 0)

SET LOCAL search_path = bicycle_rental, public;

-- 1. Enum types
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_type t
        JOIN pg_namespace n ON n.oid = t.typnamespace
        WHERE t.typname = 'fault_category' AND n.nspname = 'bicycle_rental'
    ) THEN
        CREATE TYPE bicycle_rental.fault_category AS ENUM (
            'brakes',
            'tyres',
            'drivetrain',
            'battery',
            'electrical',
            'other'
        );
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_type t
        JOIN pg_namespace n ON n.oid = t.typnamespace
        WHERE t.typname = 'fault_severity' AND n.nspname = 'bicycle_rental'
    ) THEN
        CREATE TYPE bicycle_rental.fault_severity AS ENUM (
            'minor',
            'major',
            'critical'
        );
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_type t
        JOIN pg_namespace n ON n.oid = t.typnamespace
        WHERE t.typname = 'fault_status' AND n.nspname = 'bicycle_rental'
    ) THEN
        CREATE TYPE bicycle_rental.fault_status AS ENUM (
            'open',
            'resolved',
            'rejected'
        );
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_type t
        JOIN pg_namespace n ON n.oid = t.typnamespace
        WHERE t.typname = 'maintenance_job_status' AND n.nspname = 'bicycle_rental'
    ) THEN
        CREATE TYPE bicycle_rental.maintenance_job_status AS ENUM (
            'open',
            'in_progress',
            'completed',
            'cancelled'
        );
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_type t
        JOIN pg_namespace n ON n.oid = t.typnamespace
        WHERE t.typname = 'maintenance_task_type' AND n.nspname = 'bicycle_rental'
    ) THEN
        CREATE TYPE bicycle_rental.maintenance_task_type AS ENUM (
            'inspection',
            'repair',
            'battery_check',
            'test'
        );
    END IF;
END $$;

-- 2. MaintenanceJob table (F-044..F-051, R-007)
CREATE TABLE bicycle_rental.maintenance_job (
    job_id            bigint GENERATED ALWAYS AS IDENTITY,
    bicycle_id        bigint NOT NULL,
    provider_id       bigint,
    assigned_staff_id bigint,
    status            bicycle_rental.maintenance_job_status NOT NULL DEFAULT 'open',
    opened_at         timestamptz NOT NULL DEFAULT clock_timestamp(),
    started_at        timestamptz,
    closed_at         timestamptz,
    resolution        text,

    CONSTRAINT pk_maintenance_job PRIMARY KEY (job_id),

    -- Referenced by FaultReport composite FK (maintenance_job_id, bicycle_id)
    CONSTRAINT uq_maintenance_job_id_bicycle UNIQUE (job_id, bicycle_id),

    CONSTRAINT fk_maintenance_job_bicycle FOREIGN KEY (bicycle_id)
        REFERENCES bicycle_rental.bicycle (bicycle_id)
        ON UPDATE RESTRICT ON DELETE RESTRICT,

    CONSTRAINT fk_maintenance_job_provider FOREIGN KEY (provider_id)
        REFERENCES bicycle_rental.maintenance_provider (provider_id)
        ON UPDATE RESTRICT ON DELETE RESTRICT,

    CONSTRAINT fk_maintenance_job_assigned_staff FOREIGN KEY (assigned_staff_id)
        REFERENCES bicycle_rental.staff (account_id)
        ON UPDATE RESTRICT ON DELETE RESTRICT,

    -- Status vs. started_at consistency (ERD)
    CONSTRAINT ck_maintenance_job_status_started_at CHECK (
        (status = 'open' AND started_at IS NULL)
        OR (status = 'in_progress' AND started_at IS NOT NULL)
        OR (status IN ('completed', 'cancelled'))
    ),

    -- Terminal states require closed_at and nonblank resolution; active states forbid them (F-047)
    CONSTRAINT ck_maintenance_job_closed_at_iff_terminal CHECK (
        (status IN ('completed', 'cancelled')) = (closed_at IS NOT NULL)
    ),

    CONSTRAINT ck_maintenance_job_resolution_iff_terminal CHECK (
        (status IN ('completed', 'cancelled'))
        = (resolution IS NOT NULL AND bicycle_rental.trim_ws(resolution) <> '')
    ),

    -- Timestamp ordering within job lifetime (F-047)
    CONSTRAINT ck_maintenance_job_time_order CHECK (
        (started_at IS NULL OR started_at >= opened_at)
        AND (closed_at IS NULL OR closed_at >= opened_at)
        AND (closed_at IS NULL OR started_at IS NULL OR closed_at >= started_at)
    )
);

-- Enforce at most one open or in_progress job per bicycle (F-045, R-007)
CREATE UNIQUE INDEX ux_maintenance_job_one_active_per_bicycle
    ON bicycle_rental.maintenance_job (bicycle_id)
    WHERE status IN ('open', 'in_progress');

-- Lookup indexes from ERD
CREATE INDEX ix_maintenance_job_bicycle_opened_at
    ON bicycle_rental.maintenance_job (bicycle_id, opened_at DESC);

CREATE INDEX ix_maintenance_job_provider_status
    ON bicycle_rental.maintenance_job (provider_id, status)
    WHERE provider_id IS NOT NULL;

CREATE INDEX ix_maintenance_job_assigned_staff_status
    ON bicycle_rental.maintenance_job (assigned_staff_id, status)
    WHERE assigned_staff_id IS NOT NULL;

-- 3. MaintenanceTask table (F-048..F-050)
CREATE TABLE bicycle_rental.maintenance_task (
    maintenance_job_id bigint NOT NULL,
    task_no            integer NOT NULL,
    task_type          bicycle_rental.maintenance_task_type NOT NULL,
    description        text NOT NULL,
    outcome            text,
    completed_at       timestamptz,

    CONSTRAINT pk_maintenance_task PRIMARY KEY (maintenance_job_id, task_no),

    CONSTRAINT fk_maintenance_task_job FOREIGN KEY (maintenance_job_id)
        REFERENCES bicycle_rental.maintenance_job (job_id)
        ON UPDATE RESTRICT ON DELETE RESTRICT,

    CONSTRAINT ck_maintenance_task_no_positive CHECK (task_no > 0),

    CONSTRAINT ck_maintenance_task_description_not_blank CHECK (
        bicycle_rental.trim_ws(description) <> ''
    ),

    -- Outcome and completion timestamp must be both present (with nonblank outcome) or both absent (F-049)
    CONSTRAINT ck_maintenance_task_completion_pair CHECK (
        (outcome IS NULL AND completed_at IS NULL)
        OR (outcome IS NOT NULL AND bicycle_rental.trim_ws(outcome) <> '' AND completed_at IS NOT NULL)
    )
);

-- 4. FaultReport table (F-038..F-043)
CREATE TABLE bicycle_rental.fault_report (
    report_id              bigint GENERATED ALWAYS AS IDENTITY,
    bicycle_id             bigint NOT NULL,
    reported_by_account_id bigint NOT NULL,
    rental_id              bigint,
    maintenance_job_id     bigint,
    category               bicycle_rental.fault_category NOT NULL,
    severity               bicycle_rental.fault_severity NOT NULL,
    description            text NOT NULL,
    status                 bicycle_rental.fault_status NOT NULL DEFAULT 'open',
    reported_at            timestamptz NOT NULL DEFAULT clock_timestamp(),
    resolved_at            timestamptz,

    CONSTRAINT pk_fault_report PRIMARY KEY (report_id),

    CONSTRAINT fk_fault_report_bicycle FOREIGN KEY (bicycle_id)
        REFERENCES bicycle_rental.bicycle (bicycle_id)
        ON UPDATE RESTRICT ON DELETE RESTRICT,

    CONSTRAINT fk_fault_report_reported_by FOREIGN KEY (reported_by_account_id)
        REFERENCES bicycle_rental.account (account_id)
        ON UPDATE RESTRICT ON DELETE RESTRICT,

    CONSTRAINT fk_fault_report_rental FOREIGN KEY (rental_id)
        REFERENCES bicycle_rental.rental (rental_id)
        ON UPDATE RESTRICT ON DELETE RESTRICT,

    -- Composite FK guaranteeing linked rental belongs to the same bicycle (F-040)
    CONSTRAINT fk_fault_report_rental_bicycle FOREIGN KEY (rental_id, bicycle_id)
        REFERENCES bicycle_rental.rental (rental_id, bicycle_id)
        ON UPDATE RESTRICT ON DELETE RESTRICT,

    CONSTRAINT fk_fault_report_job FOREIGN KEY (maintenance_job_id)
        REFERENCES bicycle_rental.maintenance_job (job_id)
        ON UPDATE RESTRICT ON DELETE RESTRICT,

    -- Composite FK guaranteeing linked maintenance job belongs to the same bicycle (F-041)
    CONSTRAINT fk_fault_report_job_bicycle FOREIGN KEY (maintenance_job_id, bicycle_id)
        REFERENCES bicycle_rental.maintenance_job (job_id, bicycle_id)
        ON UPDATE RESTRICT ON DELETE RESTRICT,

    CONSTRAINT ck_fault_report_description_not_blank CHECK (
        bicycle_rental.trim_ws(description) <> ''
    ),

    -- resolved_at exists if and only if status = 'resolved' (F-042)
    CONSTRAINT ck_fault_report_resolved_at_iff_resolved CHECK (
        (status = 'resolved') = (resolved_at IS NOT NULL)
    ),

    CONSTRAINT ck_fault_report_time_order CHECK (
        resolved_at IS NULL OR resolved_at >= reported_at
    )
);

-- Query indexes for fault reports
CREATE INDEX ix_fault_report_bicycle_status
    ON bicycle_rental.fault_report (bicycle_id, status);

CREATE INDEX ix_fault_report_status_reported_at
    ON bicycle_rental.fault_report (status, reported_at DESC);

CREATE INDEX ix_fault_report_maintenance_job
    ON bicycle_rental.fault_report (maintenance_job_id)
    WHERE maintenance_job_id IS NOT NULL;

CREATE INDEX ix_fault_report_reported_by
    ON bicycle_rental.fault_report (reported_by_account_id, reported_at DESC);
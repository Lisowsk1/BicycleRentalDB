-- V019: Cross-table invariants, lifecycle rules, immutability, and delete protection
-- for MaintenanceJob, MaintenanceTask, and FaultReport.
-- Requirements: F-037, F-038, F-040, F-042, F-044, F-046, F-047, F-049, F-050.
--
-- Trigger error codes:
--   23514  invariant/lifecycle violation (immutable fields, terminal record edits, invalid status/time transitions,
--          inactive provider assignment, deleting a completed task, or rider referencing another rider's rental)
--   55000  prerequisite state violation (completing a job with incomplete tasks, or modifying tasks of a terminal job)
--   23000  integrity constraint violation (operational DELETE prohibited on MaintenanceJob and FaultReport)
--   23503  foreign key violation (task references a non-existent maintenance job)

SET LOCAL search_path = bicycle_rental, public;

-- =====================================================================
-- 1. MaintenanceJob triggers
-- =====================================================================

CREATE FUNCTION bicycle_rental.trg_maintenance_job_before_insert()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = bicycle_rental, pg_temp
AS $$
DECLARE
    v_provider_active boolean;
BEGIN
    IF NOT bicycle_rental.is_privileged_setup() THEN
        IF NEW.status IS DISTINCT FROM 'open'
           OR NEW.started_at IS NOT NULL
           OR NEW.closed_at IS NOT NULL
           OR NEW.resolution IS NOT NULL THEN
            RAISE EXCEPTION 'New maintenance jobs must start in open status without start/close fields'
                USING ERRCODE = '23514';
        END IF;

        IF NEW.provider_id IS NOT NULL THEN
            SELECT mp.is_active INTO v_provider_active
              FROM bicycle_rental.maintenance_provider mp
             WHERE mp.provider_id = NEW.provider_id;

            IF v_provider_active IS NOT TRUE THEN
                RAISE EXCEPTION 'Assigned maintenance provider % must be active', NEW.provider_id
                    USING ERRCODE = '23514';
            END IF;
        END IF;
    END IF;

    RETURN NEW;
END $$;

CREATE TRIGGER trg_maintenance_job_before_insert
    BEFORE INSERT ON bicycle_rental.maintenance_job
    FOR EACH ROW EXECUTE FUNCTION bicycle_rental.trg_maintenance_job_before_insert();

CREATE FUNCTION bicycle_rental.trg_maintenance_job_before_update()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = bicycle_rental, pg_temp
AS $$
DECLARE
    v_provider_active       boolean;
    v_max_task_completed_at timestamptz;
BEGIN
    -- Core identity fields are immutable
    IF NEW.job_id IS DISTINCT FROM OLD.job_id
       OR NEW.bicycle_id IS DISTINCT FROM OLD.bicycle_id
       OR NEW.opened_at IS DISTINCT FROM OLD.opened_at THEN
        RAISE EXCEPTION 'Maintenance job identity, bicycle_id, and opened_at are immutable'
            USING ERRCODE = '23514';
    END IF;

    -- Terminal states are immutable (F-046)
    IF OLD.status IN ('completed', 'cancelled') THEN
        RAISE EXCEPTION 'Maintenance job % is in terminal status (%) and cannot be modified',
            OLD.job_id, OLD.status
            USING ERRCODE = '23514';
    END IF;

    -- Prevent backwards transition from in_progress to open
    IF OLD.status = 'in_progress' AND NEW.status = 'open' THEN
        RAISE EXCEPTION 'Maintenance job % cannot revert from in_progress to open', OLD.job_id
            USING ERRCODE = '23514';
    END IF;

    -- Once started, started_at cannot change
    IF OLD.started_at IS NOT NULL AND NEW.started_at IS DISTINCT FROM OLD.started_at THEN
        RAISE EXCEPTION 'Maintenance job % started_at cannot be changed once set', OLD.job_id
            USING ERRCODE = '23514';
    END IF;

    -- If provider_id changes to a non-null provider, that provider must be active (F-037)
    IF NEW.provider_id IS NOT NULL AND NEW.provider_id IS DISTINCT FROM OLD.provider_id THEN
        SELECT mp.is_active INTO v_provider_active
          FROM bicycle_rental.maintenance_provider mp
         WHERE mp.provider_id = NEW.provider_id;

        IF v_provider_active IS NOT TRUE THEN
            RAISE EXCEPTION 'Assigned maintenance provider % must be active', NEW.provider_id
                USING ERRCODE = '23514';
        END IF;
    END IF;

    -- Job completion requires all child tasks to be completed (F-050)
    IF NEW.status = 'completed' THEN
        IF EXISTS (
            SELECT 1
              FROM bicycle_rental.maintenance_task mt
             WHERE mt.maintenance_job_id = NEW.job_id
               AND mt.completed_at IS NULL
        ) THEN
            RAISE EXCEPTION 'Maintenance job % cannot be completed while incomplete tasks exist',
                NEW.job_id
                USING ERRCODE = '55000';
        END IF;
    END IF;

    -- On closing (completed or cancelled), closed_at must be >= MAX(completed_at) of child tasks (F-049)
    IF NEW.status IN ('completed', 'cancelled') THEN
        SELECT MAX(mt.completed_at)
          INTO v_max_task_completed_at
          FROM bicycle_rental.maintenance_task mt
         WHERE mt.maintenance_job_id = NEW.job_id;

        IF v_max_task_completed_at IS NOT NULL AND NEW.closed_at < v_max_task_completed_at THEN
            RAISE EXCEPTION 'Maintenance job % closed_at (%) cannot precede task completion (%)',
                NEW.job_id, NEW.closed_at, v_max_task_completed_at
                USING ERRCODE = '23514';
        END IF;
    END IF;

    RETURN NEW;
END $$;

CREATE TRIGGER trg_maintenance_job_before_update
    BEFORE UPDATE ON bicycle_rental.maintenance_job
    FOR EACH ROW EXECUTE FUNCTION bicycle_rental.trg_maintenance_job_before_update();

CREATE FUNCTION bicycle_rental.trg_maintenance_job_forbid_delete()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF NOT bicycle_rental.is_privileged_setup() THEN
        RAISE EXCEPTION 'Maintenance jobs cannot be deleted operationally'
            USING ERRCODE = '23000';
    END IF;
    RETURN OLD;
END $$;

CREATE TRIGGER trg_maintenance_job_no_delete
    BEFORE DELETE ON bicycle_rental.maintenance_job
    FOR EACH ROW EXECUTE FUNCTION bicycle_rental.trg_maintenance_job_forbid_delete();

-- =====================================================================
-- 2. MaintenanceTask triggers
-- =====================================================================

CREATE FUNCTION bicycle_rental.trg_maintenance_task_guard()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = bicycle_rental, pg_temp
AS $$
DECLARE
    v_job_id     bigint;
    v_job_status bicycle_rental.maintenance_job_status;
    v_opened_at  timestamptz;
    v_closed_at  timestamptz;
BEGIN
    IF TG_OP = 'DELETE' THEN
        IF bicycle_rental.is_privileged_setup() THEN
            RETURN OLD;
        END IF;
        v_job_id := OLD.maintenance_job_id;
    ELSE
        v_job_id := NEW.maintenance_job_id;
    END IF;

    SELECT mj.status, mj.opened_at, mj.closed_at
      INTO v_job_status, v_opened_at, v_closed_at
      FROM bicycle_rental.maintenance_job mj
     WHERE mj.job_id = v_job_id
       FOR SHARE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Maintenance job % does not exist', v_job_id
            USING ERRCODE = '23503';
    END IF;

    -- Tasks cannot be inserted, updated, or deleted once parent job is terminal (ERD)
    IF v_job_status IN ('completed', 'cancelled') THEN
        RAISE EXCEPTION 'Tasks of % maintenance job % cannot be inserted, updated, or deleted',
            v_job_status, v_job_id
            USING ERRCODE = '55000';
    END IF;

    IF TG_OP = 'DELETE' THEN
        IF OLD.completed_at IS NOT NULL THEN
            RAISE EXCEPTION 'Completed task % of job % cannot be deleted', OLD.task_no, OLD.maintenance_job_id
                USING ERRCODE = '23514';
        END IF;
        RETURN OLD;
    END IF;

    IF TG_OP = 'UPDATE' THEN
        IF NEW.maintenance_job_id IS DISTINCT FROM OLD.maintenance_job_id
           OR NEW.task_no IS DISTINCT FROM OLD.task_no
           OR NEW.task_type IS DISTINCT FROM OLD.task_type
           OR NEW.description IS DISTINCT FROM OLD.description THEN
            RAISE EXCEPTION 'Task identity, type, and description are immutable'
                USING ERRCODE = '23514';
        END IF;

        IF OLD.completed_at IS NOT NULL THEN
            RAISE EXCEPTION 'Task % of job % is already completed and cannot be modified',
                OLD.task_no, OLD.maintenance_job_id
                USING ERRCODE = '23514';
        END IF;
    END IF;

    -- Task completion timestamp must lie within parent job's lifetime (F-049)
    IF NEW.completed_at IS NOT NULL THEN
        IF NEW.completed_at < v_opened_at THEN
            RAISE EXCEPTION 'Task completion time (%) cannot be earlier than job opened_at (%)',
                NEW.completed_at, v_opened_at
                USING ERRCODE = '23514';
        END IF;

        IF v_closed_at IS NOT NULL AND NEW.completed_at > v_closed_at THEN
            RAISE EXCEPTION 'Task completion time (%) cannot be later than job closed_at (%)',
                NEW.completed_at, v_closed_at
                USING ERRCODE = '23514';
        END IF;
    END IF;

    RETURN NEW;
END $$;

CREATE TRIGGER trg_maintenance_task_guard
    BEFORE INSERT OR UPDATE OR DELETE ON bicycle_rental.maintenance_task
    FOR EACH ROW EXECUTE FUNCTION bicycle_rental.trg_maintenance_task_guard();

-- =====================================================================
-- 3. FaultReport triggers
-- =====================================================================

CREATE FUNCTION bicycle_rental.trg_fault_report_before_insert()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = bicycle_rental, pg_temp
AS $$
DECLARE
    v_reporter_role bicycle_rental.account_role;
    v_rental_rider  bigint;
BEGIN
    IF NOT bicycle_rental.is_privileged_setup() THEN
        IF NEW.status IS DISTINCT FROM 'open' OR NEW.resolved_at IS NOT NULL THEN
            RAISE EXCEPTION 'New fault reports must start in open status with resolved_at NULL'
                USING ERRCODE = '23514';
        END IF;
    END IF;

    -- Rider-submitted report with rental_id must reference that rider's own rental (F-040)
    IF NEW.rental_id IS NOT NULL THEN
        SELECT a.role INTO v_reporter_role
          FROM bicycle_rental.account a
         WHERE a.account_id = NEW.reported_by_account_id;

        IF v_reporter_role = 'rider' THEN
            SELECT r.rider_id INTO v_rental_rider
              FROM bicycle_rental.rental r
             WHERE r.rental_id = NEW.rental_id;

            IF v_rental_rider IS DISTINCT FROM NEW.reported_by_account_id THEN
                RAISE EXCEPTION 'Rider % cannot link fault report to another rider''s rental %',
                    NEW.reported_by_account_id, NEW.rental_id
                    USING ERRCODE = '23514';
            END IF;
        END IF;
    END IF;

    RETURN NEW;
END $$;

CREATE TRIGGER trg_fault_report_before_insert
    BEFORE INSERT ON bicycle_rental.fault_report
    FOR EACH ROW EXECUTE FUNCTION bicycle_rental.trg_fault_report_before_insert();

CREATE FUNCTION bicycle_rental.trg_fault_report_before_update()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    -- Core report fields are immutable after creation (ERD)
    IF NEW.report_id IS DISTINCT FROM OLD.report_id
       OR NEW.bicycle_id IS DISTINCT FROM OLD.bicycle_id
       OR NEW.reported_by_account_id IS DISTINCT FROM OLD.reported_by_account_id
       OR NEW.rental_id IS DISTINCT FROM OLD.rental_id
       OR NEW.category IS DISTINCT FROM OLD.category
       OR NEW.severity IS DISTINCT FROM OLD.severity
       OR NEW.description IS DISTINCT FROM OLD.description
       OR NEW.reported_at IS DISTINCT FROM OLD.reported_at THEN
        RAISE EXCEPTION 'Fault report identity, references, content, and reported_at are immutable'
            USING ERRCODE = '23514';
    END IF;

    -- Once resolved or rejected, a fault report cannot be reopened or altered (F-042)
    IF OLD.status IN ('resolved', 'rejected') THEN
        RAISE EXCEPTION 'Fault report % is in terminal status (%) and cannot be modified',
            OLD.report_id, OLD.status
            USING ERRCODE = '23514';
    END IF;

    RETURN NEW;
END $$;

CREATE TRIGGER trg_fault_report_before_update
    BEFORE UPDATE ON bicycle_rental.fault_report
    FOR EACH ROW EXECUTE FUNCTION bicycle_rental.trg_fault_report_before_update();

CREATE FUNCTION bicycle_rental.trg_fault_report_forbid_delete()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF NOT bicycle_rental.is_privileged_setup() THEN
        RAISE EXCEPTION 'Fault reports cannot be deleted operationally'
            USING ERRCODE = '23000';
    END IF;
    RETURN OLD;
END $$;

CREATE TRIGGER trg_fault_report_no_delete
    BEFORE DELETE ON bicycle_rental.fault_report
    FOR EACH ROW EXECUTE FUNCTION bicycle_rental.trg_fault_report_forbid_delete();
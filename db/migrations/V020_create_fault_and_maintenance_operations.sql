-- Verify FaultReport, MaintenanceProvider, MaintenanceJob, MaintenanceTask,
-- and maintenance audit logging (Issue #15).
-- Wrapped in a transaction and rolled back so the baseline seed remains intact.
--
-- Asserted error codes:
--   42501  not permitted (rider calling staff-only functions or linking another rider's rental to a fault report)
--   22023  invalid input (mismatched bicycle on rental/job links, or assigning a deactivated maintenance provider)
--   55000  business rule violation (duplicate active maintenance job on a bicycle, or completing a job with open tasks)
--   P0001  test assertion failure (raised if any expected rejection or post-condition check fails)

SET LOCAL search_path = bicycle_rental, public;

-- =====================================================================
-- 1. MaintenanceProvider management (F-019, F-036, F-037)
-- (create_maintenance_provider & set_maintenance_provider_active exist in V010)
-- =====================================================================

CREATE FUNCTION bicycle_rental.update_maintenance_provider(
    p_actor_id            bigint,
    p_provider_id         bigint,
    p_name                text DEFAULT NULL,
    p_contact_email       text DEFAULT NULL,
    p_clear_contact_email boolean DEFAULT false,
    p_contact_phone       text DEFAULT NULL,
    p_clear_contact_phone boolean DEFAULT false
)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = bicycle_rental, public, pg_temp
AS $$
DECLARE
    v_old   maintenance_provider%ROWTYPE;
    v_name  text;
    v_email text;
    v_phone text;
BEGIN
    PERFORM require_staff(p_actor_id);

    SELECT * INTO v_old
      FROM maintenance_provider mp
     WHERE mp.provider_id = p_provider_id
       FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'provider % not found', p_provider_id USING ERRCODE = 'P0002';
    END IF;

    v_name := CASE WHEN p_name IS NULL THEN v_old.name ELSE trim_ws(p_name) END;
    IF v_name = '' THEN
        RAISE EXCEPTION 'provider name cannot be blank' USING ERRCODE = '22023';
    END IF;

    v_email := CASE
        WHEN p_clear_contact_email THEN NULL
        WHEN p_contact_email IS NOT NULL THEN nullif(trim_ws(p_contact_email), '')
        ELSE v_old.contact_email
    END;

    v_phone := CASE
        WHEN p_clear_contact_phone THEN NULL
        WHEN p_contact_phone IS NOT NULL THEN nullif(trim_ws(p_contact_phone), '')
        ELSE v_old.contact_phone
    END;

    IF v_name IS NOT DISTINCT FROM v_old.name
       AND v_email IS NOT DISTINCT FROM v_old.contact_email
       AND v_phone IS NOT DISTINCT FROM v_old.contact_phone THEN
        RETURN false;
    END IF;

    UPDATE maintenance_provider
       SET name = v_name,
           contact_email = v_email,
           contact_phone = v_phone
     WHERE provider_id = p_provider_id;

    RETURN true;
END $$;

CREATE FUNCTION bicycle_rental.get_maintenance_provider(
    p_actor_id    bigint,
    p_provider_id bigint
)
RETURNS TABLE (
    provider_id   bigint,
    name          text,
    contact_email text,
    contact_phone text,
    is_active     boolean
)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = bicycle_rental, public, pg_temp
AS $$
BEGIN
    PERFORM require_staff(p_actor_id);

    RETURN QUERY
    SELECT mp.provider_id, mp.name::text, mp.contact_email, mp.contact_phone, mp.is_active
      FROM maintenance_provider mp
     WHERE mp.provider_id = p_provider_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'provider % not found', p_provider_id USING ERRCODE = 'P0002';
    END IF;
END $$;

CREATE FUNCTION bicycle_rental.list_maintenance_providers(
    p_actor_id  bigint,
    p_is_active boolean DEFAULT NULL
)
RETURNS TABLE (
    provider_id   bigint,
    name          text,
    contact_email text,
    contact_phone text,
    is_active     boolean
)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = bicycle_rental, public, pg_temp
AS $$
BEGIN
    PERFORM require_staff(p_actor_id);

    RETURN QUERY
    SELECT mp.provider_id, mp.name::text, mp.contact_email, mp.contact_phone, mp.is_active
      FROM maintenance_provider mp
     WHERE p_is_active IS NULL OR mp.is_active = p_is_active
     ORDER BY mp.provider_id;
END $$;

-- =====================================================================
-- 2. FaultReport operations (F-019, F-020, F-038..F-043)
-- =====================================================================

-- Authenticated riders and staff can submit fault reports (F-039).
-- Does not alter bicycle availability, rental state, or placement (F-043).
CREATE FUNCTION bicycle_rental.submit_fault_report(
    p_actor_id    bigint,
    p_bicycle_id  bigint,
    p_category    bicycle_rental.fault_category,
    p_severity    bicycle_rental.fault_severity,
    p_description text,
    p_rental_id   bigint DEFAULT NULL
)
RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = bicycle_rental, public, pg_temp
AS $$
DECLARE
    v_desc        text := trim_ws(coalesce(p_description, ''));
    v_actor_role  account_role;
    v_rental      rental%ROWTYPE;
    v_report_id   bigint;
BEGIN
    PERFORM require_account(p_actor_id);

    IF p_category IS NULL OR p_severity IS NULL THEN
        RAISE EXCEPTION 'fault category and severity are required' USING ERRCODE = '22023';
    END IF;
    IF v_desc = '' THEN
        RAISE EXCEPTION 'fault description is required' USING ERRCODE = '22023';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM bicycle b WHERE b.bicycle_id = p_bicycle_id) THEN
        RAISE EXCEPTION 'bicycle % not found', p_bicycle_id USING ERRCODE = 'P0002';
    END IF;

    IF p_rental_id IS NOT NULL THEN
        SELECT * INTO v_rental FROM rental r WHERE r.rental_id = p_rental_id;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'rental % not found', p_rental_id USING ERRCODE = 'P0002';
        END IF;

        IF v_rental.bicycle_id <> p_bicycle_id THEN
            RAISE EXCEPTION 'rental % does not belong to bicycle %', p_rental_id, p_bicycle_id
                USING ERRCODE = '22023';
        END IF;

        SELECT a.role INTO v_actor_role FROM account a WHERE a.account_id = p_actor_id;
        IF v_actor_role = 'rider' AND v_rental.rider_id <> p_actor_id THEN
            RAISE EXCEPTION 'riders may only reference their own rentals on fault reports'
                USING ERRCODE = '42501';
        END IF;
    END IF;

    INSERT INTO fault_report (
        bicycle_id,
        reported_by_account_id,
        rental_id,
        category,
        severity,
        description,
        status,
        reported_at
    )
    VALUES (
        p_bicycle_id,
        p_actor_id,
        p_rental_id,
        p_category,
        p_severity,
        v_desc,
        'open',
        clock_timestamp()
    )
    RETURNING report_id INTO v_report_id;

    RETURN v_report_id;
END $$;

-- Staff links a fault report to a maintenance job for the same bicycle (F-019, F-041, F-043).
CREATE FUNCTION bicycle_rental.link_fault_report_to_job(
    p_actor_id  bigint,
    p_report_id bigint,
    p_job_id    bigint
)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = bicycle_rental, public, pg_temp
AS $$
DECLARE
    v_report      fault_report%ROWTYPE;
    v_job_bicycle bigint;
BEGIN
    PERFORM require_staff(p_actor_id);

    SELECT * INTO v_report FROM fault_report fr WHERE fr.report_id = p_report_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'fault report % not found', p_report_id USING ERRCODE = 'P0002';
    END IF;

    IF v_report.status <> 'open' THEN
        RAISE EXCEPTION 'fault report % is already % and cannot be modified', p_report_id, v_report.status
            USING ERRCODE = '55000';
    END IF;

    SELECT mj.bicycle_id INTO v_job_bicycle FROM maintenance_job mj WHERE mj.job_id = p_job_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'maintenance job % not found', p_job_id USING ERRCODE = 'P0002';
    END IF;

    IF v_job_bicycle <> v_report.bicycle_id THEN
        RAISE EXCEPTION 'maintenance job % does not belong to bicycle %', p_job_id, v_report.bicycle_id
            USING ERRCODE = '22023';
    END IF;

    IF v_report.maintenance_job_id IS NOT DISTINCT FROM p_job_id THEN
        RETURN false;
    END IF;

    UPDATE fault_report
       SET maintenance_job_id = p_job_id
     WHERE report_id = p_report_id;

    RETURN true;
END $$;

-- Staff reviews a fault report and sets status to 'resolved' or 'rejected' (F-019, F-042, F-043).
CREATE FUNCTION bicycle_rental.review_fault_report(
    p_actor_id           bigint,
    p_report_id          bigint,
    p_status             bicycle_rental.fault_status,
    p_maintenance_job_id bigint DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = bicycle_rental, public, pg_temp
AS $$
DECLARE
    v_report      fault_report%ROWTYPE;
    v_job_bicycle bigint;
    v_resolved_at timestamptz;
BEGIN
    PERFORM require_staff(p_actor_id);

    IF p_status IS NULL OR p_status NOT IN ('resolved', 'rejected') THEN
        RAISE EXCEPTION 'review status must be resolved or rejected' USING ERRCODE = '22023';
    END IF;

    SELECT * INTO v_report FROM fault_report fr WHERE fr.report_id = p_report_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'fault report % not found', p_report_id USING ERRCODE = 'P0002';
    END IF;

    IF v_report.status <> 'open' THEN
        RAISE EXCEPTION 'fault report % is already % and cannot be reviewed again', p_report_id, v_report.status
            USING ERRCODE = '55000';
    END IF;

    IF p_maintenance_job_id IS NOT NULL THEN
        SELECT mj.bicycle_id INTO v_job_bicycle
          FROM maintenance_job mj
         WHERE mj.job_id = p_maintenance_job_id;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'maintenance job % not found', p_maintenance_job_id USING ERRCODE = 'P0002';
        END IF;
        IF v_job_bicycle <> v_report.bicycle_id THEN
            RAISE EXCEPTION 'maintenance job % does not belong to bicycle %',
                p_maintenance_job_id, v_report.bicycle_id
                USING ERRCODE = '22023';
        END IF;
    END IF;

    v_resolved_at := CASE
        WHEN p_status = 'resolved' THEN greatest(clock_timestamp(), v_report.reported_at)
        ELSE NULL
    END;

    UPDATE fault_report
       SET status = p_status,
           resolved_at = v_resolved_at,
           maintenance_job_id = coalesce(p_maintenance_job_id, v_report.maintenance_job_id)
     WHERE report_id = p_report_id;

    RETURN true;
END $$;

CREATE FUNCTION bicycle_rental.get_fault_report(
    p_actor_id  bigint,
    p_report_id bigint
)
RETURNS TABLE (
    report_id              bigint,
    bicycle_id             bigint,
    bicycle_identifier     text,
    reported_by_account_id bigint,
    rental_id              bigint,
    maintenance_job_id     bigint,
    category               bicycle_rental.fault_category,
    severity               bicycle_rental.fault_severity,
    description            text,
    status                 bicycle_rental.fault_status,
    reported_at            timestamptz,
    resolved_at            timestamptz
)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = bicycle_rental, public, pg_temp
AS $$
DECLARE
    v_is_staff boolean;
    v_owner    bigint;
BEGIN
    PERFORM require_account(p_actor_id);
    v_is_staff := EXISTS (SELECT 1 FROM staff s WHERE s.account_id = p_actor_id);

    SELECT fr.reported_by_account_id INTO v_owner
      FROM fault_report fr
     WHERE fr.report_id = p_report_id;

    IF NOT FOUND OR (NOT v_is_staff AND v_owner <> p_actor_id) THEN
        RAISE EXCEPTION 'fault report % not found', p_report_id USING ERRCODE = 'P0002';
    END IF;

    RETURN QUERY
    SELECT fr.report_id, fr.bicycle_id, b.identifier::text,
           fr.reported_by_account_id, fr.rental_id, fr.maintenance_job_id,
           fr.category, fr.severity, fr.description, fr.status,
           fr.reported_at, fr.resolved_at
      FROM fault_report fr
      JOIN bicycle b ON b.bicycle_id = fr.bicycle_id
     WHERE fr.report_id = p_report_id;
END $$;

CREATE FUNCTION bicycle_rental.list_fault_reports(
    p_actor_id   bigint,
    p_bicycle_id bigint DEFAULT NULL,
    p_status     bicycle_rental.fault_status DEFAULT NULL,
    p_job_id     bigint DEFAULT NULL
)
RETURNS TABLE (
    report_id              bigint,
    bicycle_id             bigint,
    bicycle_identifier     text,
    reported_by_account_id bigint,
    rental_id              bigint,
    maintenance_job_id     bigint,
    category               bicycle_rental.fault_category,
    severity               bicycle_rental.fault_severity,
    description            text,
    status                 bicycle_rental.fault_status,
    reported_at            timestamptz,
    resolved_at            timestamptz
)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = bicycle_rental, public, pg_temp
AS $$
BEGIN
    PERFORM require_staff(p_actor_id);

    RETURN QUERY
    SELECT fr.report_id, fr.bicycle_id, b.identifier::text,
           fr.reported_by_account_id, fr.rental_id, fr.maintenance_job_id,
           fr.category, fr.severity, fr.description, fr.status,
           fr.reported_at, fr.resolved_at
      FROM fault_report fr
      JOIN bicycle b ON b.bicycle_id = fr.bicycle_id
     WHERE (p_bicycle_id IS NULL OR fr.bicycle_id = p_bicycle_id)
       AND (p_status     IS NULL OR fr.status = p_status)
       AND (p_job_id     IS NULL OR fr.maintenance_job_id = p_job_id)
     ORDER BY fr.reported_at DESC, fr.report_id DESC;
END $$;

-- =====================================================================
-- 3. MaintenanceJob & MaintenanceTask operations (F-019, F-044..F-051, R-007)
-- =====================================================================

-- Opens a maintenance job for a bicycle; enforces at most one open/in_progress job (F-044, F-045, R-007).
-- Does not alter bicycle placement or maintenance state (F-051).
CREATE FUNCTION bicycle_rental.open_maintenance_job(
    p_actor_id          bigint,
    p_bicycle_id        bigint,
    p_provider_id       bigint DEFAULT NULL,
    p_assigned_staff_id bigint DEFAULT NULL
)
RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = bicycle_rental, public, pg_temp
AS $$
DECLARE
    v_provider_active boolean;
    v_job_id          bigint;
BEGIN
    PERFORM require_staff(p_actor_id);

    -- Lock bicycle row to serialize concurrent job openings (R-007)
    PERFORM 1 FROM bicycle b WHERE b.bicycle_id = p_bicycle_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'bicycle % not found', p_bicycle_id USING ERRCODE = 'P0002';
    END IF;

    IF EXISTS (
        SELECT 1
          FROM maintenance_job mj
         WHERE mj.bicycle_id = p_bicycle_id
           AND mj.status IN ('open', 'in_progress')
    ) THEN
        RAISE EXCEPTION 'bicycle % already has an open or in-progress maintenance job', p_bicycle_id
            USING ERRCODE = '55000';
    END IF;

    IF p_provider_id IS NOT NULL THEN
        SELECT mp.is_active INTO v_provider_active
          FROM maintenance_provider mp
         WHERE mp.provider_id = p_provider_id
           FOR SHARE;
        IF NOT FOUND OR NOT v_provider_active THEN
            RAISE EXCEPTION 'maintenance provider must exist and be active' USING ERRCODE = '22023';
        END IF;
    END IF;

    IF p_assigned_staff_id IS NOT NULL THEN
        IF NOT EXISTS (SELECT 1 FROM staff s WHERE s.account_id = p_assigned_staff_id) THEN
            RAISE EXCEPTION 'assigned staff % does not exist', p_assigned_staff_id USING ERRCODE = '22023';
        END IF;
    END IF;

    BEGIN
        INSERT INTO maintenance_job (
            bicycle_id,
            provider_id,
            assigned_staff_id,
            status,
            opened_at
        )
        VALUES (
            p_bicycle_id,
            p_provider_id,
            p_assigned_staff_id,
            'open',
            clock_timestamp()
        )
        RETURNING job_id INTO v_job_id;
    EXCEPTION WHEN unique_violation THEN
        RAISE EXCEPTION 'bicycle % already has an open or in-progress maintenance job', p_bicycle_id
            USING ERRCODE = '55000';
    END;

    RETURN v_job_id;
END $$;

-- Assigns or updates provider / staff on an active (open or in_progress) maintenance job (F-019, F-037, F-051).
CREATE FUNCTION bicycle_rental.assign_maintenance_job(
    p_actor_id             bigint,
    p_job_id               bigint,
    p_provider_id          bigint DEFAULT NULL,
    p_clear_provider       boolean DEFAULT false,
    p_assigned_staff_id    bigint DEFAULT NULL,
    p_clear_assigned_staff boolean DEFAULT false
)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = bicycle_rental, public, pg_temp
AS $$
DECLARE
    v_job             maintenance_job%ROWTYPE;
    v_new_provider    bigint;
    v_new_staff       bigint;
    v_provider_active boolean;
BEGIN
    PERFORM require_staff(p_actor_id);

    SELECT * INTO v_job FROM maintenance_job mj WHERE mj.job_id = p_job_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'maintenance job % not found', p_job_id USING ERRCODE = 'P0002';
    END IF;

    IF v_job.status NOT IN ('open', 'in_progress') THEN
        RAISE EXCEPTION 'maintenance job % is already % and cannot be reassigned', p_job_id, v_job.status
            USING ERRCODE = '55000';
    END IF;

    v_new_provider := CASE
        WHEN p_clear_provider THEN NULL
        WHEN p_provider_id IS NOT NULL THEN p_provider_id
        ELSE v_job.provider_id
    END;

    v_new_staff := CASE
        WHEN p_clear_assigned_staff THEN NULL
        WHEN p_assigned_staff_id IS NOT NULL THEN p_assigned_staff_id
        ELSE v_job.assigned_staff_id
    END;

    IF v_new_provider IS NOT NULL AND v_new_provider IS DISTINCT FROM v_job.provider_id THEN
        SELECT mp.is_active INTO v_provider_active
          FROM maintenance_provider mp
         WHERE mp.provider_id = v_new_provider
           FOR SHARE;
        IF NOT FOUND OR NOT v_provider_active THEN
            RAISE EXCEPTION 'maintenance provider must exist and be active' USING ERRCODE = '22023';
        END IF;
    END IF;

    IF v_new_staff IS NOT NULL AND v_new_staff IS DISTINCT FROM v_job.assigned_staff_id THEN
        IF NOT EXISTS (SELECT 1 FROM staff s WHERE s.account_id = v_new_staff) THEN
            RAISE EXCEPTION 'assigned staff % does not exist', v_new_staff USING ERRCODE = '22023';
        END IF;
    END IF;

    IF v_new_provider IS NOT DISTINCT FROM v_job.provider_id
       AND v_new_staff IS NOT DISTINCT FROM v_job.assigned_staff_id THEN
        RETURN false;
    END IF;

    UPDATE maintenance_job
       SET provider_id = v_new_provider,
           assigned_staff_id = v_new_staff
     WHERE job_id = p_job_id;

    RETURN true;
END $$;

-- Transitions an open maintenance job to in_progress (F-046, F-047).
CREATE FUNCTION bicycle_rental.start_maintenance_job(
    p_actor_id bigint,
    p_job_id   bigint
)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = bicycle_rental, public, pg_temp
AS $$
DECLARE
    v_job maintenance_job%ROWTYPE;
BEGIN
    PERFORM require_staff(p_actor_id);

    SELECT * INTO v_job FROM maintenance_job mj WHERE mj.job_id = p_job_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'maintenance job % not found', p_job_id USING ERRCODE = 'P0002';
    END IF;

    IF v_job.status = 'in_progress' THEN
        RETURN false;
    END IF;

    IF v_job.status <> 'open' THEN
        RAISE EXCEPTION 'maintenance job % cannot be started from status %', p_job_id, v_job.status
            USING ERRCODE = '55000';
    END IF;

    UPDATE maintenance_job
       SET status = 'in_progress',
           started_at = greatest(clock_timestamp(), v_job.opened_at)
     WHERE job_id = p_job_id;

    RETURN true;
END $$;

-- Adds a numbered task to an open or in_progress maintenance job (F-048).
-- If p_task_no is NULL, assigns MAX(task_no) + 1 within the locked job.
CREATE FUNCTION bicycle_rental.add_maintenance_task(
    p_actor_id    bigint,
    p_job_id      bigint,
    p_task_type   bicycle_rental.maintenance_task_type,
    p_description text,
    p_task_no     integer DEFAULT NULL
)
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = bicycle_rental, public, pg_temp
AS $$
DECLARE
    v_job     maintenance_job%ROWTYPE;
    v_desc    text := trim_ws(coalesce(p_description, ''));
    v_task_no integer;
BEGIN
    PERFORM require_staff(p_actor_id);

    IF p_task_type IS NULL THEN
        RAISE EXCEPTION 'task type is required' USING ERRCODE = '22023';
    END IF;
    IF v_desc = '' THEN
        RAISE EXCEPTION 'task description is required' USING ERRCODE = '22023';
    END IF;

    SELECT * INTO v_job FROM maintenance_job mj WHERE mj.job_id = p_job_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'maintenance job % not found', p_job_id USING ERRCODE = 'P0002';
    END IF;

    IF v_job.status NOT IN ('open', 'in_progress') THEN
        RAISE EXCEPTION 'cannot add tasks to % maintenance job %', v_job.status, p_job_id
            USING ERRCODE = '55000';
    END IF;

    IF p_task_no IS NULL THEN
        SELECT coalesce(max(mt.task_no), 0) + 1
          INTO v_task_no
          FROM maintenance_task mt
         WHERE mt.maintenance_job_id = p_job_id;
    ELSE
        IF p_task_no <= 0 THEN
            RAISE EXCEPTION 'task_no must be positive' USING ERRCODE = '22023';
        END IF;
        v_task_no := p_task_no;
    END IF;

    BEGIN
        INSERT INTO maintenance_task (
            maintenance_job_id,
            task_no,
            task_type,
            description
        )
        VALUES (
            p_job_id,
            v_task_no,
            p_task_type,
            v_desc
        );
    EXCEPTION WHEN unique_violation THEN
        RAISE EXCEPTION 'task_no % already exists in maintenance job %', v_task_no, p_job_id
            USING ERRCODE = '23505';
    END;

    RETURN v_task_no;
END $$;

-- Records task outcome and server completion timestamp within parent job lifetime (F-049).
CREATE FUNCTION bicycle_rental.complete_maintenance_task(
    p_actor_id bigint,
    p_job_id   bigint,
    p_task_no  integer,
    p_outcome  text
)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = bicycle_rental, public, pg_temp
AS $$
DECLARE
    v_job     maintenance_job%ROWTYPE;
    v_task    maintenance_task%ROWTYPE;
    v_outcome text := trim_ws(coalesce(p_outcome, ''));
BEGIN
    PERFORM require_staff(p_actor_id);

    IF v_outcome = '' THEN
        RAISE EXCEPTION 'task outcome is required' USING ERRCODE = '22023';
    END IF;

    SELECT * INTO v_job FROM maintenance_job mj WHERE mj.job_id = p_job_id FOR SHARE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'maintenance job % not found', p_job_id USING ERRCODE = 'P0002';
    END IF;

    IF v_job.status NOT IN ('open', 'in_progress') THEN
        RAISE EXCEPTION 'cannot complete tasks on % maintenance job %', v_job.status, p_job_id
            USING ERRCODE = '55000';
    END IF;

    SELECT * INTO v_task
      FROM maintenance_task mt
     WHERE mt.maintenance_job_id = p_job_id
       AND mt.task_no = p_task_no
       FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'task % of maintenance job % not found', p_task_no, p_job_id
            USING ERRCODE = 'P0002';
    END IF;

    IF v_task.completed_at IS NOT NULL THEN
        RAISE EXCEPTION 'task % of maintenance job % is already completed', p_task_no, p_job_id
            USING ERRCODE = '55000';
    END IF;

    UPDATE maintenance_task
       SET outcome = v_outcome,
           completed_at = greatest(clock_timestamp(), v_job.opened_at)
     WHERE maintenance_job_id = p_job_id
       AND task_no = p_task_no;
END $$;

-- Completes a maintenance job only when all tasks are completed (F-046, F-047, F-050, F-051).
CREATE FUNCTION bicycle_rental.complete_maintenance_job(
    p_actor_id   bigint,
    p_job_id     bigint,
    p_resolution text
)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = bicycle_rental, public, pg_temp
AS $$
DECLARE
    v_job        maintenance_job%ROWTYPE;
    v_resolution text := trim_ws(coalesce(p_resolution, ''));
    v_max_task   timestamptz;
    v_closed_at  timestamptz;
BEGIN
    PERFORM require_staff(p_actor_id);

    IF v_resolution = '' THEN
        RAISE EXCEPTION 'resolution is required to complete a maintenance job' USING ERRCODE = '22023';
    END IF;

    SELECT * INTO v_job FROM maintenance_job mj WHERE mj.job_id = p_job_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'maintenance job % not found', p_job_id USING ERRCODE = 'P0002';
    END IF;

    IF v_job.status NOT IN ('open', 'in_progress') THEN
        RAISE EXCEPTION 'maintenance job % is already % and cannot be completed', p_job_id, v_job.status
            USING ERRCODE = '55000';
    END IF;

    -- Lock child tasks so concurrent task additions/updates cannot race with completion
    PERFORM 1 FROM maintenance_task mt WHERE mt.maintenance_job_id = p_job_id FOR SHARE;

    IF EXISTS (
        SELECT 1
          FROM maintenance_task mt
         WHERE mt.maintenance_job_id = p_job_id
           AND mt.completed_at IS NULL
    ) THEN
        RAISE EXCEPTION 'maintenance job % cannot be completed while tasks remain incomplete', p_job_id
            USING ERRCODE = '55000';
    END IF;

    SELECT max(mt.completed_at)
      INTO v_max_task
      FROM maintenance_task mt
     WHERE mt.maintenance_job_id = p_job_id;

    v_closed_at := greatest(
        clock_timestamp(),
        v_job.opened_at,
        coalesce(v_job.started_at, v_job.opened_at),
        coalesce(v_max_task, v_job.opened_at)
    );

    UPDATE maintenance_job
       SET status = 'completed',
           closed_at = v_closed_at,
           resolution = v_resolution
     WHERE job_id = p_job_id;
END $$;

-- Cancels an open or in_progress maintenance job with a required nonblank resolution (F-046, F-047, F-051).
CREATE FUNCTION bicycle_rental.cancel_maintenance_job(
    p_actor_id   bigint,
    p_job_id     bigint,
    p_resolution text
)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = bicycle_rental, public, pg_temp
AS $$
DECLARE
    v_job        maintenance_job%ROWTYPE;
    v_resolution text := trim_ws(coalesce(p_resolution, ''));
    v_max_task   timestamptz;
    v_closed_at  timestamptz;
BEGIN
    PERFORM require_staff(p_actor_id);

    IF v_resolution = '' THEN
        RAISE EXCEPTION 'resolution is required to cancel a maintenance job' USING ERRCODE = '22023';
    END IF;

    SELECT * INTO v_job FROM maintenance_job mj WHERE mj.job_id = p_job_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'maintenance job % not found', p_job_id USING ERRCODE = 'P0002';
    END IF;

    IF v_job.status NOT IN ('open', 'in_progress') THEN
        RAISE EXCEPTION 'maintenance job % is already % and cannot be cancelled', p_job_id, v_job.status
            USING ERRCODE = '55000';
    END IF;

    PERFORM 1 FROM maintenance_task mt WHERE mt.maintenance_job_id = p_job_id FOR SHARE;

    SELECT max(mt.completed_at)
      INTO v_max_task
      FROM maintenance_task mt
     WHERE mt.maintenance_job_id = p_job_id;

    v_closed_at := greatest(
        clock_timestamp(),
        v_job.opened_at,
        coalesce(v_job.started_at, v_job.opened_at),
        coalesce(v_max_task, v_job.opened_at)
    );

    UPDATE maintenance_job
       SET status = 'cancelled',
           closed_at = v_closed_at,
           resolution = v_resolution
     WHERE job_id = p_job_id;
END $$;

CREATE FUNCTION bicycle_rental.get_maintenance_job(
    p_actor_id bigint,
    p_job_id   bigint
)
RETURNS TABLE (
    job_id             bigint,
    bicycle_id         bigint,
    bicycle_identifier text,
    provider_id        bigint,
    assigned_staff_id  bigint,
    status             bicycle_rental.maintenance_job_status,
    opened_at          timestamptz,
    started_at         timestamptz,
    closed_at          timestamptz,
    resolution         text
)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = bicycle_rental, public, pg_temp
AS $$
BEGIN
    PERFORM require_staff(p_actor_id);

    RETURN QUERY
    SELECT mj.job_id, mj.bicycle_id, b.identifier::text,
           mj.provider_id, mj.assigned_staff_id,
           mj.status, mj.opened_at, mj.started_at, mj.closed_at, mj.resolution
      FROM maintenance_job mj
      JOIN bicycle b ON b.bicycle_id = mj.bicycle_id
     WHERE mj.job_id = p_job_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'maintenance job % not found', p_job_id USING ERRCODE = 'P0002';
    END IF;
END $$;

CREATE FUNCTION bicycle_rental.list_maintenance_jobs(
    p_actor_id          bigint,
    p_bicycle_id        bigint DEFAULT NULL,
    p_status            bicycle_rental.maintenance_job_status DEFAULT NULL,
    p_provider_id       bigint DEFAULT NULL,
    p_assigned_staff_id bigint DEFAULT NULL
)
RETURNS TABLE (
    job_id             bigint,
    bicycle_id         bigint,
    bicycle_identifier text,
    provider_id        bigint,
    assigned_staff_id  bigint,
    status             bicycle_rental.maintenance_job_status,
    opened_at          timestamptz,
    started_at         timestamptz,
    closed_at          timestamptz,
    resolution         text
)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = bicycle_rental, public, pg_temp
AS $$
BEGIN
    PERFORM require_staff(p_actor_id);

    RETURN QUERY
    SELECT mj.job_id, mj.bicycle_id, b.identifier::text,
           mj.provider_id, mj.assigned_staff_id,
           mj.status, mj.opened_at, mj.started_at, mj.closed_at, mj.resolution
      FROM maintenance_job mj
      JOIN bicycle b ON b.bicycle_id = mj.bicycle_id
     WHERE (p_bicycle_id        IS NULL OR mj.bicycle_id = p_bicycle_id)
       AND (p_status            IS NULL OR mj.status = p_status)
       AND (p_provider_id       IS NULL OR mj.provider_id = p_provider_id)
       AND (p_assigned_staff_id IS NULL OR mj.assigned_staff_id = p_assigned_staff_id)
     ORDER BY mj.opened_at DESC, mj.job_id DESC;
END $$;

CREATE FUNCTION bicycle_rental.list_maintenance_tasks(
    p_actor_id bigint,
    p_job_id   bigint
)
RETURNS TABLE (
    maintenance_job_id bigint,
    task_no            integer,
    task_type          bicycle_rental.maintenance_task_type,
    description        text,
    outcome            text,
    completed_at       timestamptz
)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = bicycle_rental, public, pg_temp
AS $$
BEGIN
    PERFORM require_staff(p_actor_id);

    IF NOT EXISTS (SELECT 1 FROM maintenance_job mj WHERE mj.job_id = p_job_id) THEN
        RAISE EXCEPTION 'maintenance job % not found', p_job_id USING ERRCODE = 'P0002';
    END IF;

    RETURN QUERY
    SELECT mt.maintenance_job_id, mt.task_no, mt.task_type,
           mt.description, mt.outcome, mt.completed_at
      FROM maintenance_task mt
     WHERE mt.maintenance_job_id = p_job_id
     ORDER BY mt.task_no;
END $$;
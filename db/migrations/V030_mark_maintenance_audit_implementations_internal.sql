-- These implementation routines are only called by their audited
-- SECURITY DEFINER wrappers. Keep them unavailable to application roles and
-- make them SECURITY INVOKER so access-control checks classify them as helpers.
ALTER FUNCTION bicycle_rental.submit_fault_report_without_audit(
    bigint, bigint, bicycle_rental.fault_category, bicycle_rental.fault_severity, text, bigint
) SECURITY INVOKER;
ALTER FUNCTION bicycle_rental.link_fault_report_to_job_without_audit(
    bigint, bigint, bigint
) SECURITY INVOKER;
ALTER FUNCTION bicycle_rental.review_fault_report_without_audit(
    bigint, bigint, bicycle_rental.fault_status, bigint
) SECURITY INVOKER;
ALTER FUNCTION bicycle_rental.open_maintenance_job_without_audit(
    bigint, bigint, bigint, bigint
) SECURITY INVOKER;
ALTER FUNCTION bicycle_rental.assign_maintenance_job_without_audit(
    bigint, bigint, bigint, boolean, bigint, boolean
) SECURITY INVOKER;
ALTER FUNCTION bicycle_rental.start_maintenance_job_without_audit(
    bigint, bigint
) SECURITY INVOKER;
ALTER FUNCTION bicycle_rental.add_maintenance_task_without_audit(
    bigint, bigint, bicycle_rental.maintenance_task_type, text, integer
) SECURITY INVOKER;
ALTER FUNCTION bicycle_rental.complete_maintenance_task_without_audit(
    bigint, bigint, integer, text
) SECURITY INVOKER;
ALTER FUNCTION bicycle_rental.complete_maintenance_job_without_audit(
    bigint, bigint, text
) SECURITY INVOKER;
ALTER FUNCTION bicycle_rental.cancel_maintenance_job_without_audit(
    bigint, bigint, text
) SECURITY INVOKER;

REVOKE ALL ON FUNCTION bicycle_rental.submit_fault_report_without_audit(
    bigint, bigint, bicycle_rental.fault_category, bicycle_rental.fault_severity, text, bigint
) FROM PUBLIC, bicycle_app;
REVOKE ALL ON FUNCTION bicycle_rental.link_fault_report_to_job_without_audit(
    bigint, bigint, bigint
) FROM PUBLIC, bicycle_app;
REVOKE ALL ON FUNCTION bicycle_rental.review_fault_report_without_audit(
    bigint, bigint, bicycle_rental.fault_status, bigint
) FROM PUBLIC, bicycle_app;
REVOKE ALL ON FUNCTION bicycle_rental.open_maintenance_job_without_audit(
    bigint, bigint, bigint, bigint
) FROM PUBLIC, bicycle_app;
REVOKE ALL ON FUNCTION bicycle_rental.assign_maintenance_job_without_audit(
    bigint, bigint, bigint, boolean, bigint, boolean
) FROM PUBLIC, bicycle_app;
REVOKE ALL ON FUNCTION bicycle_rental.start_maintenance_job_without_audit(
    bigint, bigint
) FROM PUBLIC, bicycle_app;
REVOKE ALL ON FUNCTION bicycle_rental.add_maintenance_task_without_audit(
    bigint, bigint, bicycle_rental.maintenance_task_type, text, integer
) FROM PUBLIC, bicycle_app;
REVOKE ALL ON FUNCTION bicycle_rental.complete_maintenance_task_without_audit(
    bigint, bigint, integer, text
) FROM PUBLIC, bicycle_app;
REVOKE ALL ON FUNCTION bicycle_rental.complete_maintenance_job_without_audit(
    bigint, bigint, text
) FROM PUBLIC, bicycle_app;
REVOKE ALL ON FUNCTION bicycle_rental.cancel_maintenance_job_without_audit(
    bigint, bigint, text
) FROM PUBLIC, bicycle_app;

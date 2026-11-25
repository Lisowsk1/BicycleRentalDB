-- V027: Give fault-report and maintenance-job operations distinct audit actions
-- and logical record types. This is separate from the migration that first
-- introduces the values so they are usable in V028.

ALTER TYPE bicycle_rental.audit_action_type ADD VALUE IF NOT EXISTS 'fault_report_submit';
ALTER TYPE bicycle_rental.audit_action_type ADD VALUE IF NOT EXISTS 'fault_report_link';
ALTER TYPE bicycle_rental.audit_action_type ADD VALUE IF NOT EXISTS 'fault_report_review';
ALTER TYPE bicycle_rental.audit_action_type ADD VALUE IF NOT EXISTS 'maintenance_job_open';
ALTER TYPE bicycle_rental.audit_action_type ADD VALUE IF NOT EXISTS 'maintenance_job_assign';
ALTER TYPE bicycle_rental.audit_action_type ADD VALUE IF NOT EXISTS 'maintenance_job_start';
ALTER TYPE bicycle_rental.audit_action_type ADD VALUE IF NOT EXISTS 'maintenance_job_complete';
ALTER TYPE bicycle_rental.audit_action_type ADD VALUE IF NOT EXISTS 'maintenance_job_cancel';
ALTER TYPE bicycle_rental.audit_action_type ADD VALUE IF NOT EXISTS 'maintenance_task_add';
ALTER TYPE bicycle_rental.audit_action_type ADD VALUE IF NOT EXISTS 'maintenance_task_complete';

ALTER TYPE bicycle_rental.audit_record_type ADD VALUE IF NOT EXISTS 'FaultReport';
ALTER TYPE bicycle_rental.audit_record_type ADD VALUE IF NOT EXISTS 'MaintenanceJob';

-- V025: Add a stable textual operation label without changing the existing
-- audit enums. The existing setup check intentionally verifies those enum
-- labels, while operation_type supports finer-grained audit filtering.

ALTER TABLE bicycle_rental.audit_entry
    ADD COLUMN operation_type text NOT NULL DEFAULT 'legacy';

ALTER TABLE bicycle_rental.audit_entry
    ADD CONSTRAINT chk_audit_entry_operation_type_nonblank
    CHECK (btrim(operation_type) <> '');

ALTER TABLE bicycle_rental.audit_entry
    ALTER COLUMN operation_type SET DEFAULT
        coalesce(nullif(current_setting('bicycle_rental.audit_operation_type', true), ''), 'legacy');

CREATE INDEX idx_audit_entry_operation_created_at
    ON bicycle_rental.audit_entry (operation_type, created_at DESC, audit_id DESC);

# Audit and cross-stage integration tests

The audit infrastructure is extended by four forward-only migrations:
[`V025_extend_audit_event_types.sql`](../db/migrations/V025_extend_audit_event_types.sql),
[`V026_complete_audit_infrastructure.sql`](../db/migrations/V026_complete_audit_infrastructure.sql),
[`V027_add_maintenance_audit_types.sql`](../db/migrations/V027_add_maintenance_audit_types.sql), and
[`V028_correct_maintenance_audit_records.sql`](../db/migrations/V028_correct_maintenance_audit_records.sql).
V026 adds query indexes, filters audit entries by primary **or detail** record,
provides `list_audit_entries_with_details`, and adds maintenance event capture.
V027/V028 give fault-report and maintenance-job/task events distinct action and
record types and correctly typed details. Task details are associated with
their parent job and identify the task number in the field name. Fine-grained
operation names are also stored in `audit_entry.operation_type`. Free-text
fault descriptions, task descriptions/outcomes, and job resolutions are
excluded from the new maintenance audit details.
Audit records are append-only, so entries written by an earlier V026 build are
retained as they were; the corrected record/action attribution applies to
operations executed after V028 is installed.
The existing account, station, maintenance handover/return, and staff-assisted
rental-return events remain in place. Maintenance-provider management remains
outside the required audit event set defined by the existing requirements.
Station transfers remain in their dedicated immutable history table; the
existing movement tests require them not to create additional audit entries.

All mutation audit writes occur in the same PostgreSQL transaction as the
change. The maintenance operation wrappers retain the original validation and
row-locking implementations; their row triggers append audit details before
the operation can commit. A failed audit insert therefore fails and rolls back
the corresponding operation. Rider fault submissions do not create staff
audit entries, while staff-submitted reports are attributed to the acting staff.
Payment request/submission history continues to be stored in `payment_event`.

## Run the integration checks

Run on a disposable database after Flyway has applied every migration:

```bash
docker compose run --rm flyway migrate
docker compose exec -T db psql --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
  --set=ON_ERROR_STOP=1 < db/tests/audit_integration.sql
```

The new [`audit_integration.sql`](../db/tests/audit_integration.sql) exercises
the complete fault-to-repair-to-return flow, accurate fault/job/task audit
events, transfer integration, staff/action/affected-record/date filtering,
detail retrieval, deferred audit constraints, and atomic rollback when an
audit insert fails. It rolls back all fixtures.

The existing integration suite covers the related stages:

| Area | Test |
|---|---|
| Account block/unblock audit events, audit filtering and detail ordering | [`account_system.sql`](../db/tests/account_system.sql) |
| Rental lifecycle, staff-assisted return, and rollback | [`rental_lifecycle.sql`](../db/tests/rental_lifecycle.sql) |
| Competing rental, maintenance, and return-control operations | [`rental_concurrency.sh`](../db/tests/rental_concurrency.sh) |
| Payment processing and transaction recovery | [`payment_processing_tests.sql`](../db/tests/payment_processing_tests.sql), [`payment_recovery_tests.sql`](../db/tests/payment_recovery_tests.sql) |
| Concurrent payment requests/submissions | [`payment_concurrency_test.sh`](../db/tests/payment_concurrency_test.sh) |
| Fault reports and maintenance lifecycle | [`fault_and_maintenance.sql`](../db/tests/fault_and_maintenance.sql) |
| Transfers, maintenance handover/return, audit behavior and movement history | [`bicycle_movement.sql`](../db/tests/bicycle_movement.sql) |
| Concurrent transfers and movement conflicts | [`bicycle_movement_concurrency.sh`](../db/tests/bicycle_movement_concurrency.sh) |
| Concurrent maintenance-job creation for one bicycle | [`maintenance_job_concurrency.sh`](../db/tests/maintenance_job_concurrency.sh) |

Run the complete workflow on CI to validate all migrations, setup checks,
integration tests, concurrency tests, and seed scripts together. The
maintenance-job concurrency script commits its staff, station, bicycle, job,
and audit fixtures, so it must run only against a disposable database. The
local execution environment used to prepare these additions did not include
`docker` or `psql`; no local runtime pass is claimed here. A successful CI run
is still required before release.

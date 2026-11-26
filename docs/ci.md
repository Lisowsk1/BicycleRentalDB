# Continuous integration

The [Database workflow](../.github/workflows/database.yml) checks the PostgreSQL scaffold on every push and pull request. You can also start it manually from GitHub's **Actions > Database > Run workflow** once the workflow is on the default branch.

## What runs

On pull requests, before starting Docker, the workflow runs a [migration history check](../.github/scripts/check-migration-history.ps1). Files already in `db/migrations/` on the PR's target branch must remain unchanged. Editing, deleting, renaming, or replacing them fails the **Database setup** check; adding new migrations is allowed. The checkout fetches full Git history so the target commit is available. Pushes and manual runs skip this comparison and run the database checks below.

1. Validate the [Compose configuration](../compose.yml).
2. Start PostgreSQL in a fresh Docker volume and wait for its health check.
3. Apply every Flyway migration.
4. Validate migration naming and checksums.
5. Run migration again to confirm the completed history can be rerun.
6. Show migration status and run [setup checks](../db/checks/setup.sql). These verify the project schema, successful migration history, account/fleet/tariff/audit tables, fleet and audit enum labels, and the two active seed tariffs (regular 2.50 and electric 4.50 PLN per 900 seconds). Failed migration history also fails the check. Update the expected values when a future migration intentionally changes the initial configuration.
7. Run [account system tests](../db/tests/account_system.sql): table constraints and subtype integrity, registration and credential checks, case-insensitive duplicate emails, operation-level access rules, rider blocking and unblocking with their audit records, and audit-log integrity (append-only, atomic with the change, at least one detail per entry). The script rolls back its fixtures.
8. Run [fleet and station tests](../db/tests/fleet_station.sql), including uniqueness, subtype integrity, availability, rental/return placement restrictions, provider references, maintenance operations, authorization, and audit rollback. The script rolls back its fixtures and test-only triggers.
9. Run [setup guard tests](../db/tests/setup_guards.sql) in a fresh connection, so the privileged-setup setting is genuinely absent when the checks start.
10. Run [rental lifecycle tests](../db/tests/rental_lifecycle.sql): eligibility, atomic start, pricing capture, rider and staff-assisted returns, retries, charge arithmetic, history paging, audit, and rollback on injected failures. The script rolls back its fixtures.
11. Run [competing-request tests](../db/tests/rental_concurrency.sh): separate database sessions race to start the same bicycle, start with the same rider, return the same rental (rider and staff, same and different destinations), and race blocking, maintenance updates and return-disabling against rental operations. This script commits its fixtures, so it only belongs on a disposable database such as the CI one.
12. Run the payment tests: [payment processing](../db/tests/payment_processing_tests.sql), [committed payment recovery](../db/tests/payment_recovery_tests.sql) and the [concurrent payment script](../db/tests/payment_concurrency_test.sh). See [payments](payments.md). The concurrency script commits its fixtures.
13. Run [fault report and maintenance tests](../db/tests/fault_and_maintenance.sql): fault reports, maintenance jobs and tasks, providers, and their state rules. The script rolls back its fixtures.
14. Run [bicycle movement tests](../db/tests/bicycle_movement.sql): station-to-station transfers, handover to and return from maintenance, eligibility and conflict rejection, atomic rollback, immutable transfer records, and the movement history queries with paging. Then run the [competing movement script](../db/tests/bicycle_movement_concurrency.sh): separate sessions race transfers, handovers, returns, rental starts and maintenance-state updates on the same bicycle and check that placement stays consistent with no deadlocks. It commits its fixtures.
15. Run [audit integration tests](../db/tests/audit_integration.sql) (see [audit integration](audit-integration.md)) and the [competing maintenance job script](../db/tests/maintenance_job_concurrency.sh). The script commits its fixtures.
16. Run [role access control tests](../db/tests/access_control.sql). Using the restricted `bicycle_app` and `bicycle_setup` roles, they check that PUBLIC executes nothing, that `bicycle_app` has no table access and can only call operation functions, that only the setup role may provision staff, and that registration, blocking, rental start/return and the deferred commit-time checks work as the application role. The script rolls back its fixtures.
17. Run [retention purge tests](../db/tests/retention_purge.sql): the purge removes audit entries, transfers, terminal payments with their rentals and resolved fault reports past 36 months, keeps younger rows, pending payments and open reports, refuses callers outside `bicycle_setup`, and leaves operational deletes blocked afterwards. The script creates two temporary login roles and rolls everything back.
18. Run [remaining operations tests](../db/tests/remaining_operations.sql): tariff lookup and configuration, active-rental search, usage and station-pair statistics, the purge and baseline reset operations, and the role privileges of `bicycle_app` and `bicycle_setup`.
19. Run the [privileged setup guard test](../db/tests/test_privileged_setup_guard.sql): the application login cannot bypass the guard triggers by setting the privileged flags, while the setup login can. It creates temporary login roles and commits its data, so it runs last.
20. Show PostgreSQL logs on failure and remove the job's containers and volumes on completion.

The job has a ten-minute timeout, read-only repository permissions, and disposable database credentials defined in the workflow. No GitHub secrets or local `.env` file are required. A newer run cancels an older run for the same branch or pull request and event type.

## Enable it for the team

1. Create or choose the team's GitHub repository, then commit and push this scaffold, including the `.github` directory. Keep `.env` untracked.
2. Open **Actions** and confirm the **Database** workflow runs. If Actions is disabled for the repository or organization, an owner must enable it.
3. Open a pull request and check that **Database setup** succeeds.
4. In the default branch's ruleset or branch protection settings, require pull requests and select **Database setup** as a required status check. The check may need to run once before GitHub offers it. Availability depends on the repository and GitHub plan.

The workflow runs without changing repository settings. Required checks and collaborator access are configured separately by the repository owner.

## Preserve merged migrations

To change the schema, add the next versioned SQL migration instead of changing an existing one. The history check compares the target branch commit recorded by the pull request event with the checked-out result. It protects migrations in Git even though CI creates an empty database, where Flyway alone would accept a rewritten migration.

If another PR has added migrations to the target branch, merge or rebase the latest target branch into your branch before rerunning CI. Preserve its migrations and resolve any new version conflicts. This check does not determine which migrations were applied to an external database; Flyway validation is still required there.

To run the history check locally from the repository root, fetch your target branch and replace `origin/main` below if it has a different name. Commit your changes first: this check compares Git commits, so it does not inspect uncommitted edits.

```powershell
git fetch origin
./.github/scripts/check-migration-history.ps1 -BaselineCommit origin/main
```

## Reproduce a failure locally

Follow the [first-start instructions](../README.md#first-start), then run:

```text
docker compose config --quiet
docker compose up -d --wait db
docker compose run --rm flyway migrate
docker compose run --rm flyway validate
docker compose run --rm flyway migrate
docker compose run --rm flyway info
```

To run the same SQL setup check and tests in PowerShell using the container's configured username and database, run the files you need (this is the workflow order; run `test_privileged_setup_guard.sql` last because it commits its data):

```powershell
$tests = 'db/checks/setup.sql',
  'db/tests/account_system.sql', 'db/tests/fleet_station.sql', 'db/tests/setup_guards.sql',
  'db/tests/rental_lifecycle.sql', 'db/tests/payment_processing_tests.sql',
  'db/tests/payment_recovery_tests.sql', 'db/tests/fault_and_maintenance.sql',
  'db/tests/bicycle_movement.sql', 'db/tests/audit_integration.sql', 'db/tests/access_control.sql',
  'db/tests/retention_purge.sql', 'db/tests/remaining_operations.sql', 'db/tests/test_privileged_setup_guard.sql'
foreach ($t in $tests) {
  Write-Host "== $t"
  Get-Content -Raw $t | docker compose exec -T db sh -c 'psql --username=$POSTGRES_USER --dbname=$POSTGRES_DB --set=ON_ERROR_STOP=1'
  if ($LASTEXITCODE -ne 0) { throw "$t failed" }
}
```

A passing file finishes without an error (some print a count of passed checks); a failure stops with an `ERROR: FAIL ...` message naming the failed check. The tests roll back, so you can rerun them. The account, access-control, retention, remaining-operations and guard tests switch roles, create temporary logins or write to protected tables directly, so run them as the superuser account created by the container (the `.env` user). Run `test_privileged_setup_guard.sql` last: it commits its data.

Against a native PostgreSQL install, use `psql -U postgres -d <database> -v ON_ERROR_STOP=1 -q -f <file>` instead. Apply all migrations to that database first.

The competing-request scripts need bash (Git Bash or WSL on Windows). They commit their fixtures, so run them against a disposable database only:

```bash
export PSQL_CMD='docker compose exec -T db psql --username bicycle --dbname bicycle_rental'
bash db/tests/rental_concurrency.sh
bash db/tests/bicycle_movement_concurrency.sh
bash db/tests/maintenance_job_concurrency.sh
# the payment script reads PGUSER and PGDATABASE instead of PSQL_CMD:
docker compose exec -T db sh -c 'export PGUSER="$POSTGRES_USER" PGDATABASE="$POSTGRES_DB"; exec bash' < db/tests/payment_concurrency_test.sh
```

Replace the username and database with the values from your `.env`.

CI always starts with an empty database. It does not yet test upgrades with production data or implement application-level tests.

## Fleet operation boundary

The fleet migrations enforce rental eligibility and destination controls on bicycle placement
transitions. A transition to `active_rental` requires a rentable station bicycle; a transition
from `active_rental` requires an existing return-enabled station. Operational inserts into rental
placement are rejected. F-026 permits privileged baseline imports: a login with the bicycle
table owner's privileges may insert existing rental placement while
`SET LOCAL bicycle_rental.privileged_setup = 'true'` is active in its import transaction.
The flag alone grants no privilege. Structural CHECKs, FKs and electric subtype constraints still
apply; when the rental module exists its corresponding rental rows must be loaded in the same
transaction. Station and battery row locks protect operational checks against concurrent
changes. Maintenance handover/return ignores rider station controls, as required by F-029/F-030.

The rental lifecycle operations manage rider eligibility, rental records, pricing and completion in
the same transaction as bicycle placement. The fleet tests exercise the placement boundary directly;
the rental tests cover ownership, charging and concurrent requests from separate database sessions.

These unmerged fleet migrations were edited in place. If you already applied their old versions
to a disposable local database, recreate that database using the documented local reset before
running Flyway again. Existing databases are not upgraded automatically by changing migration files.

## Database roles in tests and local use

The migrations create two roles without login (see [access control](access-control.md)): `bicycle_app` (operation functions only, no table access) and `bicycle_setup` (setup administration, including staff provisioning). CI connects as the database superuser, so ordinary tests are unaffected by them. A real application login must be a member of `bicycle_app`; an administration login that creates staff or runs resets must be a member of `bicycle_setup`. A login that belongs to both can also run `reset_baseline()`, so keep application and setup logins separate. Migrations run as the owner; if that login is not a superuser it must be a member of `bicycle_setup` for any migration that uses `SET LOCAL bicycle_rental.privileged_setup = 'true'`.

## Demo data

[`db/seeds/demo_seed.sql`](../db/seeds/demo_seed.sql) is a manual script, not a migration, and CI does not run it. It adds demo staff, riders, stations, bicycles, a transfer, a fault report with a maintenance job, and sample payments. It can be run repeatedly (it skips when already applied). It creates accounts with fixed demo passwords, so use it only on a local or disposable database:

```powershell
Get-Content -Raw db/seeds/demo_seed.sql | docker compose exec -T db sh -c 'psql --username=$POSTGRES_USER --dbname=$POSTGRES_DB --set=ON_ERROR_STOP=1'
```

## Deployment

This repository currently has no deployment destination. Continuous deployment requires choosing a shared server or managed PostgreSQL service, configuring its credentials, and defining when migrations should be applied. The CI job only changes its disposable database.

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
7. Run [fleet and station tests](../db/tests/fleet_station.sql), including uniqueness, subtype integrity, availability, rental/return placement restrictions, provider references, maintenance operations, authorization, and audit rollback. The script rolls back its fixtures and test-only triggers.
8. Show PostgreSQL logs on failure and remove the job's containers and volumes on completion.

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

To run the same SQL setup check in PowerShell using the container's configured username and database:

```powershell
Get-Content -Raw db/checks/setup.sql | docker compose exec -T db sh -c 'psql --username=$POSTGRES_USER --dbname=$POSTGRES_DB --set=ON_ERROR_STOP=1'
Get-Content -Raw db/tests/fleet_station.sql | docker compose exec -T db sh -c 'psql --username=$POSTGRES_USER --dbname=$POSTGRES_DB --set=ON_ERROR_STOP=1'
```

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

The rental lifecycle module is not implemented yet. Its future commands must manage rider
eligibility, rental records, pricing and completion in the same transaction as bicycle placement.
The fleet tests exercise the placement boundary directly; they do not claim to test rental
ownership, charging or concurrent requests from separate database sessions.

These unmerged fleet migrations were edited in place. If you already applied their old versions
to a disposable local database, recreate that database using the documented local reset before
running Flyway again. Existing databases are not upgraded automatically by changing migration files.

## Deployment

This repository currently has no deployment destination. Continuous deployment requires choosing a shared server or managed PostgreSQL service, configuring its credentials, and defining when migrations should be applied. The CI job only changes its disposable database.

# Bicycle Rental

PostgreSQL project scaffold for the Bicycle Sharing System. This repository currently contains local database tooling, an initial `bicycle_rental` schema migration, and the [requirements specification](docs/latex/Bicycle_Rental_V1.4.tex). Domain tables, seed data, and application features are not implemented yet.

## Prerequisites

- Git.
- Docker Desktop with Linux containers and Docker Compose v2. Start Docker Desktop before running the commands below.
- An optional PostgreSQL client, such as DataGrip, for browsing the database. A local PostgreSQL installation is not required.

Run all commands from the repository root.

## Team collaboration

See [CONTRIBUTING.md](CONTRIBUTING.md) for inviting collaborators, cloning the repository, working on branches, reviewing pull requests, and coordinating migrations. Each teammate runs a separate local database with the same Compose configuration. Git shares migrations; it does not share live database contents.

The [GitHub Actions database check](.github/workflows/database.yml) starts PostgreSQL and checks all migrations on pushes and pull requests once this repository is published on GitHub.

See the [CI setup guide](docs/ci.md) for enabling the workflow, requiring a passing check before merging, and reproducing failures locally.

## First start

1. Create your local configuration in PowerShell (skip this if `.env` already exists):

   ```powershell
   Copy-Item .env.example .env
   ```

2. Edit `.env` and choose a local development password. The template defines `POSTGRES_DB`, `POSTGRES_USER`, `POSTGRES_PASSWORD`, and optional `POSTGRES_PORT` (defaults to `5432`). Keep `.env` out of Git.

3. Validate the configuration and start PostgreSQL:

   ```powershell
   docker compose config --quiet
   docker compose up -d --wait db
   ```

4. Apply the versioned migrations, then inspect their status:

   ```powershell
   docker compose run --rm flyway migrate
   docker compose run --rm flyway info
   ```

   The `flyway` service uses the `tools` profile so it does not run during a normal `docker compose up`. Explicitly targeting it with `run` enables it automatically. It waits for the database health check before connecting. The first migration creates only the empty `bicycle_rental` schema.

## Logins and passwords explained simply

Think of PostgreSQL as a locked house:

- `POSTGRES_DB` is the house's name: which database to open.
- `POSTGRES_USER` is the login name.
- `POSTGRES_PASSWORD` is that login's secret password.
- `POSTGRES_PORT` is the door number your computer connects through, usually `5432`.

[.env.example](.env.example) is a **blank instruction card shared with your friends**. Its password is just a placeholder.

[.env](.env) is **your filled-in private card**. Docker Compose reads it to configure your local database login. Git ignores it, so it stays on your computer. You create it by copying the example during the first-start steps above.

Each friend makes their own copy and chooses their own password. You do not need matching passwords because everyone runs a separate database.

**One catch:** these values create the database and login the first time PostgreSQL starts with an empty data volume. Changing the password in `.env` afterward does **not** change the existing database password.

## Connect

Use these settings in your database client:

| Setting | Value |
| --- | --- |
| Host | `127.0.0.1` |
| Port | `POSTGRES_PORT` from `.env`, or `5432` |
| Database | `POSTGRES_DB` from `.env` |
| Username | `POSTGRES_USER` from `.env` |
| Password | `POSTGRES_PASSWORD` from `.env` |
| Project schema | `bicycle_rental` |

PostgreSQL is exposed only on the local loopback interface. Flyway connects internally to `db:5432`, regardless of the host port. These credentials are for local development; the image creates `POSTGRES_USER` as a database superuser.

To open `psql` inside the container from PowerShell:

```powershell
docker compose exec db sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB"'
```

In `psql`, use `\dn` to list schemas and `\q` to exit. Flyway stores migration history in `public.flyway_schema_history`; future project objects should be schema-qualified with `bicycle_rental.`.

## Daily commands

```powershell
# Start the existing database
docker compose up -d --wait db

# Check service status and logs
docker compose ps
docker compose logs --tail 100 db

# Validate applied migration checksums and apply new migrations
docker compose run --rm flyway validate
docker compose run --rm flyway migrate

# Stop containers while keeping the database volume
docker compose down
```

Database files persist in the Compose-managed `postgres_data` volume. PostgreSQL 18 mounts its data under `/var/lib/postgresql`, as configured in [compose.yml](compose.yml).

## Migration workflow

Store SQL migrations in [db/migrations](db/migrations). Use one underscore between the version and description: `V001_create_schema.sql`, then `V002_short_description.sql`, and so on. Flyway is configured with `FLYWAY_SQL_MIGRATION_SEPARATOR: "_"` in [compose.yml](compose.yml). Coordinate version numbers with other contributors. Add a new migration for each change; do not edit migrations that have already been applied to a shared database, because Flyway validates their checksums. Migration filenames are validated, and Flyway `clean` is disabled.

Migrations run explicitly through Flyway. They are not mounted into PostgreSQL's first-start initialization directory, so new migrations can also be applied to an existing database.

## Troubleshooting and local reset

- If `docker` is not recognized, install Docker Desktop or reopen your terminal after installation. If the engine is unavailable, start Docker Desktop and ensure Linux containers are selected.
- If port `5432` is in use, set a different `POSTGRES_PORT` in `.env` and rerun `docker compose up -d --wait db`.
- Database name, user, and password are initialized only when the data volume is empty. Editing `.env` does not change credentials in an existing database. Restore the original values or deliberately reset disposable local data.
- To recreate a disposable local database, the following command **permanently deletes all database data in this Compose project's volumes**:

  ```powershell
  docker compose down --volumes
  docker compose up -d --wait db
  docker compose run --rm flyway migrate
  ```

Keep backups of any data you need before resetting. This scaffold does not configure production deployment or automated backups.

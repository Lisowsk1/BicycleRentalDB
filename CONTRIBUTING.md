# Working together

Each contributor runs their own PostgreSQL container and data volume using [compose.yml](compose.yml). Git shares the SQL migrations, configuration, and documentation. Database contents and local passwords stay on each person's machine.

## Repository access (owner)

1. Create a repository on GitHub. Use an empty repository when publishing this existing folder.
2. Commit and push the scaffold from this folder. Before committing, check `git status --short` and confirm `.env` is ignored with `git check-ignore .env`.
3. In the GitHub repository, open **Settings > Collaborators** and invite the team by GitHub username. Each friend must accept their invitation.
4. Share the repository's clone URL. Set the default branch in GitHub and have everyone use that branch as the base for their work.
5. Once GitHub Actions has run successfully, consider protecting the default branch: require pull requests and the `Database setup` check before merging, where your GitHub plan supports these settings.

No GitHub remote is configured in this scaffold. The repository owner must create or choose the shared repository before the team can push or open pull requests.

## Join the project

1. Clone the shared repository with `git clone <repository-url>` and open the cloned folder.
2. Follow [First start in the README](README.md#first-start). On macOS/Linux, use `cp .env.example .env` instead of the PowerShell copy command.
3. Choose your own local password. Everyone can use port `5432` on separate computers; change `POSTGRES_PORT` only if it conflicts with another service on your machine.

## Make a change

Start from the latest default branch. Replace `<default-branch>` below with the branch configured on GitHub, such as `main` or `master`.

```text
git switch <default-branch>
git pull --ff-only
git switch -c feature/short-description
```

Make your changes, then run these checks with your local database:

```text
docker compose config --quiet
docker compose up -d --wait db
docker compose run --rm flyway migrate
docker compose run --rm flyway validate
docker compose run --rm flyway info
```

Review `git diff` and `git status --short`, stage the files you intend to share, commit, and push your branch:

```text
git add <changed-files>
git commit -m "Describe the change"
git push -u origin feature/short-description
```

Open a pull request against the default branch. Ask a teammate to review it and check the database workflow result before merging. After pulling merged changes, run `docker compose run --rm flyway migrate` to update your own database.

## Coordinate database changes

- Agree on the next migration version before starting. Use `V002_short_description.sql` after the existing `V001_create_schema.sql` migration, then keep increasing the version. Separate the version and description with one underscore.
- Check open pull requests as well as the default branch for reserved migration numbers. Two different filenames with the same Flyway version still conflict.
- Before merging, bring the latest default branch into your feature branch and rerun the checks. If a migration version conflicts, coordinate with its author. Renumber only an unmerged migration used on disposable local databases; reset those local databases as described in the [README](README.md#troubleshooting-and-local-reset) before rerunning migrations.
- Once a migration is merged or applied to a shared database, preserve it. Add another migration to change its result.
- Use explicit `bicycle_rental.` schema names for project objects. Keep versioned migrations in [db/migrations](db/migrations).
- Changes made manually in a database GUI are local until represented by a migration. Git does not synchronize rows or database files.
- Commit configuration templates and migrations. Keep credentials, database volumes, and private data out of commits.

## Automated database check

The [database workflow](.github/workflows/database.yml) runs on pushes and pull requests. It starts a fresh PostgreSQL instance using the same Compose file, applies all migrations, validates their checksums, and runs migration again to check that the completed history can be rerun. It also checks that the project schema and successful migration history exist. Its credentials and database exist only for that CI job. See the [CI setup guide](docs/ci.md) for activation and required-check settings.

This checks setup and migration execution on an empty database. Future changes may also need tests against an existing populated database.

## Shared remote database

The current setup supports collaboration through Git with separate local databases. `127.0.0.1` always points to the contributor's own computer. A single database that everyone connects to requires a separate shared server and connection/access configuration; this Compose file does not expose your computer's PostgreSQL service to the internet.

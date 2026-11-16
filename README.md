# Bicycle Rental

A PostgreSQL 18 database project using Docker and Flyway. The setup currently creates an empty `bicycle_rental` schema. Everyone runs their own database; Git shares the SQL changes.

The commands below use **PowerShell**. Run them from the project folder containing [compose.yml](compose.yml). Replace anything in `<angle-brackets>` with your own value before running a command.

## First start

### 1. Install the tools

Install **Git** and **Docker Desktop**. Open Docker Desktop, select Linux containers if needed, and wait for it to finish starting. Then open a new terminal and check:

```powershell
git --version
docker --version
docker compose version
```

You do not need to install PostgreSQL or Flyway separately.

### 2. Get the project

Accept the owner's GitHub invitation, then copy the repository's clone URL from its **Code** button:

```powershell
git clone <repository-url>
cd BicycleRental
```

If you already have the project, open its folder and skip cloning. The owner can find publishing and invitation instructions in [CONTRIBUTING.md](CONTRIBUTING.md).

### 3. Create your local settings

Copy the shared template once. Skip this command if you already have `.env`:

```powershell
Copy-Item .env.example .env
```

Open `.env` in your editor. Keep these defaults and replace the password with one of your own:

```dotenv
POSTGRES_DB=bicycle_rental
POSTGRES_USER=bicycle_rental
POSTGRES_PASSWORD=replace_with_your_local_password
POSTGRES_PORT=5432
```

Think of the database as a locked house:

| Setting | Meaning |
| --- | --- |
| `POSTGRES_DB` | The database's name |
| `POSTGRES_USER` | Your database login name |
| `POSTGRES_PASSWORD` | The login's secret password |
| `POSTGRES_PORT` | The door number, usually `5432` |

[.env.example](.env.example) is the shared blank instruction card. `.env` is your private filled-in copy, ignored by Git. Each friend can choose a different password because each database is separate. These are database credentials, not your GitHub login.

### 4. Start the database

```powershell
docker compose config --quiet
docker compose up -d --wait db
```

The first command produces no output when the configuration is valid. The second downloads PostgreSQL if needed and waits until it is ready. Stop and fix any error before continuing.

### 5. Apply the SQL migrations

A migration is a numbered SQL file that records a database change. Flyway applies new files in order and remembers which ones have run.

```powershell
docker compose run --rm flyway migrate
docker compose run --rm flyway validate
docker compose run --rm flyway info
```

All three commands should finish successfully. The migration list should show `V001` as applied, with no pending migrations. Your database is ready.

### 6. Open the database

You can use the included `psql` terminal:

```powershell
docker compose exec db sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB"'
```

Type `\dn` to list schemas, `\dt bicycle_rental.*` to list project tables, and `\q` to exit. An empty project schema is expected until table migrations are added.

Alternatively, connect from a database client such as pgAdmin or DBeaver:

| Connection field | Value |
| --- | --- |
| Host | `127.0.0.1` |
| Port | Your `POSTGRES_PORT`, normally `5432` |
| Database | Your `POSTGRES_DB` |
| Username | Your `POSTGRES_USER` |
| Password | Your `POSTGRES_PASSWORD` |
| Project schema | `bicycle_rental` |

## Work on the project

### 1. Get the latest changes and create a branch

Start Docker Desktop. From the project folder, run the following with a clean Git working directory. Replace `<default-branch>` with the team's branch, usually `main` or `master`:

```powershell
git switch <default-branch>
git pull --ff-only
git switch -c feature/your-change
docker compose up -d --wait db
docker compose run --rm flyway migrate
```

Use a new branch name for each task. Pulling Git changes downloads migration files; running Flyway updates your local database.

### 2. Make your SQL change

Agree on the next available version with the team. Create a new SQL file in [db/migrations](db/migrations), for example `V002_short_description.sql`.

Use **one underscore** between the version and description. Write project objects with the `bicycle_rental.` schema prefix. Preserve migrations already merged or shared; add a new migration to change their result. Changes made only in a database GUI will not reach your friends.

### 3. Apply and check your change

```powershell
docker compose run --rm flyway migrate
docker compose run --rm flyway validate
docker compose run --rm flyway info
```

Check the result in your database client. Fix errors before sharing the change.

### 4. Share it for review

```powershell
git diff
git status --short
git add <changed-file-path>
git commit -m "Describe your change"
git push -u origin feature/your-change
```

Repeat `git add` for each file you want to include. Never commit `.env` or private data.

Open a pull request on GitHub. Wait for the **Database setup** CI check to pass and ask a teammate to review before merging. CI starts a fresh database and checks the migrations automatically. See [the CI guide](docs/ci.md) for enabling it and [CONTRIBUTING.md](CONTRIBUTING.md) for team rules.

### 5. Stop when finished

```powershell
docker compose down
```

Your database data stays saved. Next time, start Docker Desktop and run `docker compose up -d --wait db` again.

## Troubleshooting and local reset

- **Docker command missing:** install Docker Desktop and reopen your terminal.
- **Cannot connect to Docker:** start Docker Desktop and wait until it is ready.
- **Port already in use:** change `POSTGRES_PORT` in `.env` to `5433`, run `docker compose up -d --wait db` again, and use `5433` in your database client.
- **Login fails after editing `.env`:** the database login is created only on the first start with an empty volume. Editing `.env` does not change an existing password. Restore the original settings or reset disposable local data below.
- **Need logs:** run `docker compose logs --tail 100 db`.

To start over, **these commands permanently delete your local database data** and recreate it from the migrations. Back up anything you need first:

```powershell
docker compose down --volumes
docker compose up -d --wait db
docker compose run --rm flyway migrate
```

The [requirements specification](docs/latex) describes the planned project features.

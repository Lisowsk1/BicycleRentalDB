# Bicycle Rental

A PostgreSQL 18 database project using Docker and Flyway. The migrations create the `bicycle_rental` schema, tariff and audit tables, and initial regular/electric tariffs. Everyone runs their own database; Git shares the SQL changes.

The commands below use **PowerShell**. Run them from the project folder containing [compose.yml](compose.yml). Replace anything in `<angle-brackets>` with your own value before running a command.

## First start

### 1. Install the tools

Install **Git** and **Docker Desktop**. Open Docker Desktop, select Linux containers if needed, and wait for it to finish starting. Then open a new terminal and check:

```powershell
git --version
docker --version
docker compose version
docker info
```

`docker info` must show a **Server** section without an error before you continue. `docker --version` only checks the client; Docker Desktop's window being open does not mean its Linux engine is ready. If the server check fails, see [Troubleshooting](#troubleshooting-and-local-reset).

You do not need to install PostgreSQL or Flyway separately.

### 2. Get the project

Accept the owner's GitHub invitation, then copy the repository's clone URL from its **Code** button:

```powershell
git clone <repository-url> BicycleRentalDB
cd BicycleRentalDB
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
docker compose up -d --wait --wait-timeout 120 db
```

The first command produces no output when the configuration is valid. The second downloads PostgreSQL if needed and waits until it is ready. Stop and fix any error before continuing.

### 5. Apply the SQL migrations

A migration is a numbered SQL file that records a database change. Flyway applies new files in order and remembers which ones have run.

```powershell
docker compose run --rm flyway migrate
docker compose run --rm flyway validate
docker compose run --rm flyway info
```

All three commands should finish successfully. The migration list should show versions `001`, `002`, and `003` as **Success**, with no pending migrations (plus any newer migrations added by the team). Flyway stores its history in `public.flyway_schema_history`; project tables are in `bicycle_rental`.

### 6. Open the database

You can use the included `psql` terminal:

```powershell
docker compose exec db sh -c 'psql --username=$POSTGRES_USER --dbname=$POSTGRES_DB'
```

Type `\dn` to list schemas and `\dt bicycle_rental.*` to list project tables. You should see `tariff`, `audit_entry`, and `audit_detail`. Check the seed data with:

```sql
SELECT bicycle_type, price_per_block, block_length_seconds, currency
FROM bicycle_rental.tariff
ORDER BY bicycle_type;
```

Expect two tariffs: regular at `2.50` PLN and electric at `4.50` PLN, both per `900` seconds. Type `\q` to exit.

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

Agree on the next available version with the team. Versions `001` through `003` already exist. Create a new SQL file in [db/migrations](db/migrations), for example `V004_short_description.sql` if that version has not been reserved.

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

## Documentation

- [Continuous integration and running the tests](docs/ci.md)
- [Access control and database roles](docs/access-control.md): `bicycle_app`, `bicycle_setup`, grants, retention purge
- [Bicycle movements](docs/bicycle-movements.md): station transfers, maintenance handover and return, history
- [Payments](docs/payments.md) and [audit integration](docs/audit-integration.md)
- [Entity-relationship diagram](docs/diagrams/Bike%20Rental%20v2%20ERD.mmd) and [component diagram](docs/diagrams/Bike%20Rental%20v2%20Component%20Diagram.mmd)
- Requirements: [docs/requirements](docs/requirements/Bicycle_Rental_V2.pdf)

## Troubleshooting and local reset

- **Docker command missing:** install Docker Desktop and reopen your terminal. If you use VS Code, fully close and reopen VS Code so its terminals inherit the updated PATH.
- **Cannot connect to Docker / HTTP 500 from `dockerDesktopLinuxEngine`:** run `docker info`. If it cannot show server details, resolve Docker Desktop/WSL startup before running Compose or Flyway. An open Docker Desktop window and a working `docker --version` are not sufficient.
- **WSL reports `HCS_E_SERVICE_NOT_AVAILABLE` or virtualization unavailable:** run `wsl --status`. For the WSL 2 backend, enable **Virtual Machine Platform** in Windows and hardware virtualization (Intel VT-x / AMD-V) in BIOS/UEFI. If firmware virtualization is already enabled, check the Windows feature and hypervisor startup settings. In **PowerShell as Administrator**, run:

  ```powershell
  wsl --install --no-distribution
  bcdedit /set hypervisorlaunchtype auto
  ```

  Restart Windows after saving your work, start Docker Desktop using Linux containers, and run `docker info` again. Once the server responds, repeat steps 4 and 5. This Windows prerequisite error occurs before PostgreSQL or migrations can run; changing database credentials or deleting the data volume will not fix it.
- **Port already in use:** change `POSTGRES_PORT` in `.env` to `5433`, run `docker compose up -d --wait db` again, and use `5433` in your database client.
- **Flyway reports `password authentication failed` after editing `.env`:** PostgreSQL keeps the password saved in its data volume. Editing `.env` or recreating the container does not update that saved login, and a healthy container does not verify password authentication. If you changed only the password, sync the existing login to the current settings without deleting data:

  ```powershell
  docker compose up -d --wait db
  $sql = @'
  \set ON_ERROR_STOP on
  \getenv local_password POSTGRES_PASSWORD
  SELECT format('ALTER ROLE %I PASSWORD %L', current_user, :'local_password') \gexec
  '@
  $sql | docker compose exec -T db sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB"'
  ```

  Run each command from the project folder. The here-string closing `'@` must start at the beginning of its line in PowerShell. This uses the official image's trusted local connection and reads the password inside the container, without printing it. If the `ALTER ROLE` command succeeds, repeat step 5. If you also changed `POSTGRES_USER` or `POSTGRES_DB`, restore their original values first.
- **Need logs:** run `docker compose logs --tail 100 db`.

To start over, **these commands permanently delete your local database data** and recreate it from the migrations. Back up anything you need first:

```powershell
docker compose down --volumes
docker compose up -d --wait db
docker compose run --rm flyway migrate
```

See [simulated payment usage and recovery](docs/payments.md) for the payment procedure,
transaction boundaries, and retry behavior.

The [requirements specification](docs/requirements/Bicycle_Rental_V2.pdf) describes the planned project features.

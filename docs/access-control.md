# Access control and database roles

The `bicycle_rental` schema is used through **operation functions**. An application never reads or writes the tables directly: each function checks who is acting, applies the business rules, changes the data and writes the audit record in one transaction. Database privileges enforce that, so a stolen application login cannot bypass the rules.

The privileges are set by [V022](../db/migrations/V022_restrict_function_access.sql) and refined by V023, V024 and V029.

## Roles

| Role | Purpose | What it may do |
| --- | --- | --- |
| `bicycle_app` | The running application | Execute the operation functions (register, log in, rent and return, pay, block and unblock riders, manage fleet, move bicycles, faults and maintenance, audit queries, tariff and statistics reads). **No table privileges.** |
| `bicycle_setup` | Setup administration | Create staff accounts (`provision_staff`), configure tariffs, run the retention purge and the baseline reset, and the privileged-setup checks. Also has direct table access for baseline loading. |
| PUBLIC | Everyone else | **Nothing.** Every function and procedure in the schema is closed to PUBLIC, including routines added later. |

Both roles are created without login. Attach real logins to them:

```sql
CREATE ROLE app_login LOGIN PASSWORD '<password>';
GRANT bicycle_app TO app_login;       -- the application connects as this

CREATE ROLE admin_login LOGIN PASSWORD '<password>';
GRANT bicycle_setup TO admin_login;   -- used only for setup and administration
```

Keep application and setup logins separate. A login that belongs to both roles can also run `reset_baseline()`, which empties every table.

The database owner and superusers (for example `postgres`) are not restricted. Migrations, the demo seeder and the tests run as such a login.

## How the functions are protected

- **Operation functions are `SECURITY DEFINER`.** They run with the owner's rights, so `bicycle_app` does not need table access. Each has a fixed `search_path`.
- **The acting account is a parameter.** Most operations take `p_actor_id` and call `require_staff`, `require_rider` or `require_account` to check it. These helpers, the `*_internal` and `*_without_audit` functions, and all trigger functions are not granted to `bicycle_app`.
- **Deferred constraint triggers.** Some integrity checks run when a transaction commits (for example "every account has a rider or staff row", "every audit entry has details"). They run as the connected user, so the few trigger functions involved are `SECURITY DEFINER` too; otherwise a commit as `bicycle_app` would fail.
- **`submit_payment` is the one granted routine that is not `SECURITY DEFINER`.** It is a procedure that needs transaction control, and it only calls granted `SECURITY DEFINER` functions.
- **Staff provisioning** (`provision_staff`) is granted to `bicycle_setup` only. The application cannot create staff accounts.

## Setup operations

| Operation | Who | Notes |
| --- | --- | --- |
| `provision_staff(first, last, email, password)` | `bicycle_setup` | Creates a staff account. |
| `configure_tariffs(...)` | `bicycle_setup` | Retires the active tariffs and creates new active regular and electric tariffs (F-079). Earlier tariffs stay in the table, and existing rentals keep their captured prices. |
| `reset_baseline()` | `bicycle_setup` members | Truncates **every** table (accounts, fleet, rentals, payments, audit log, tariffs) and restarts the identity counters. Nothing is reloaded, so reapply the baseline data afterwards. Checks the **session user** is in `bicycle_setup`. Destructive: use only on disposable databases. |
| `purge_expired_records(as_of)` | `bicycle_setup` | Retention purge (below). |

### Privileged setup flag

Baseline data (the seed tariffs, sample rentals, the demo seeder) is loaded with `SET LOCAL bicycle_rental.privileged_setup = 'true'`. The guard triggers allow protected writes only when the flag is on **and** the session user belongs to `bicycle_setup` (or is a superuser). Setting the flag alone grants nothing, so `bicycle_app` cannot bypass the guards. If migrations run as a non-superuser owner, that login must be a member of `bicycle_setup`.

### Retention purge

`purge_expired_records(as_of)` deletes records past their retention period using a cutoff of `as_of` minus 36 months, in an order that respects references: audit entries and details, terminal payments with their events and simulator records, resolved or rejected fault reports, closed maintenance jobs and tasks that no fault report references, bicycle transfers, and completed rentals that have no remaining payment or fault report. It returns the number of rows deleted per record type, and switches its privileged flags off again afterwards. Accounts, riders, staff, stations and bicycles are never purged. Pending payments and open work are kept.

Operational `DELETE` and `UPDATE` stay blocked on all of these tables. Only the purge and the baseline reset may remove rows.

## Known limits

- **The database trusts the acting account id.** `bicycle_app` can pass any staff or rider id as `p_actor_id`. The application must authenticate users and pass the right id. A compromised application can act as any user, so this limits what a stolen login can do but does not replace application security.
- **`reset_baseline()` is also granted to `bicycle_app`.** It refuses any caller whose login is not a member of `bicycle_setup`, so an ordinary application login is rejected; the grant is still broader than needed and should move to `bicycle_setup` only.
- **`bicycle_setup` has broad table access.** Treat it as an administrator role.
- **Retention periods.** The purge applies one 36-month cutoff to every record type. The requirements list 24 months for rentals (after completion) and for payments (after rental deletion). A rental older than 24 months but younger than 36 months is therefore kept, and rentals with a payment are removed only after the payment is.
- **Future routines.** Routines added by later migrations are closed to PUBLIC automatically. Grant each operation function to `bicycle_app` (or `bicycle_setup`) explicitly:

  ```sql
  GRANT EXECUTE ON FUNCTION bicycle_rental.<name>(<argument types>) TO bicycle_app;
  ```

## Tests

- [`db/tests/access_control.sql`](../db/tests/access_control.sql) runs as `bicycle_app` and `bicycle_setup`: PUBLIC has nothing, `bicycle_app` has no table access and can only call operation functions, only the setup role may provision staff, and registration, blocking and rental start/return work with their deferred checks.
- [`db/tests/test_privileged_setup_guard.sql`](../db/tests/test_privileged_setup_guard.sql) checks that the application login cannot forge the privileged flags.
- [`db/tests/retention_purge.sql`](../db/tests/retention_purge.sql) checks the purge removes only expired rows and only for `bicycle_setup` members.
- [`db/tests/account_system.sql`](../db/tests/account_system.sql) checks account constraints, registration, authentication, access rules, blocking and audit integrity.

See [CI](ci.md) for how to run them.

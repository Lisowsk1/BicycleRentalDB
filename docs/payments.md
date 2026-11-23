# Simulated payments

Apply all migrations before using the payment operations. Actor IDs must come from
the application's validated session. All payments are simulated; no real money moves.

Create or recover the payment for an owned, completed rental with a positive charge:

```sql
SELECT * FROM bicycle_rental.request_payment(42, 123);
```

Commit this request before submitting. It returns the stable payment reference,
status, amount, and currency. Repeating it returns the same payment/reference.

Starting with migration V015, submission is a **procedure**, replacing the previous
`SELECT ... FROM submit_payment(...)` function. In an autocommit connection, call:

```sql
CALL bicycle_rental.submit_payment(42, '00000000-0000-0000-0000-000000000001');
```

Replace the example IDs and UUID with the authenticated rider and returned reference.
The result contains `status` and `uncertain`. Do not put the `CALL` in `BEGIN` or a
client-managed transaction: it uses transaction control and rejects that context
before contacting the simulator. Drivers must enable autocommit for this operation.

The procedure first commits the simulator result and submission events, then applies
the payment confirmation and its event in a separate transaction. If confirmation
fails, the payment stays pending and the original simulator result remains committed.
Retry the same `CALL` with the same reference after a write error, timeout, or lost
response. The simulator replays its retained result rather than creating a new
settlement. A successful or failed payment is terminal; retries add no events or
timestamp changes. An unavailable simulator or its deliberately lost first response
returns `pending` with `uncertain = true`.

Read the latest state separately (the owning rider or an authorized staff actor):

```sql
SELECT * FROM bicycle_rental.get_rental_payment(42, 123);
```

The owner-authorized `prepare_payment_submission` and `confirm_payment_submission`
functions are the lower-level adapter phases. Normal callers should use the procedure,
which supplies their required commit boundary. Confirmation reads the retained result
and accepts no caller-supplied status, amount, or currency. The internal simulator and
raw confirmation functions remain unavailable to `PUBLIC`. Deployments must grant
the application role schema usage and execute access to the public procedure and
its two owner-authorized phase functions; these functions provide the data access
under a fixed search path. They must not grant direct writes to payment tables.

CI runs the constraint/phase tests, committed recovery tests, and concurrent public
calls. The latter two suites commit fixtures and must run on a disposable database.
The recovery suite injects both payment-update and confirmation-event failures after
settlement, checks the retained result, and retries through the public procedure.

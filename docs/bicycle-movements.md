# Bicycle movements

A bicycle is always in exactly one place: at a **station**, on an **active rental**, or with a **maintenance provider**. Staff move bicycles between stations and to and from maintenance providers with the operations below. Each movement keeps placement and maintenance state consistent and leaves a permanent record.

## Operations

| Operation | Moves | Audited |
| --- | --- | --- |
| `transfer_bicycle(actor, bicycle, from_station, to_station, reason)` | station to station | No (F-071) |
| `handover_to_maintenance(actor, bicycle, provider)` | station to provider | Yes, one audit entry |
| `return_from_maintenance(actor, bicycle, station, maintenance_state)` | provider to station | Yes, one audit entry |
| `get_bicycle_movement_history(actor, bicycle, limit, offset)` | read | |
| `get_bicycle_transfer_history(actor, bicycle, limit, offset)` | read | |

All are staff-only. `reason` is optional (up to 500 characters; blank counts as none).

```sql
SELECT bicycle_rental.transfer_bicycle(:staff_id, :bicycle_id, :from_station, :to_station, 'rebalancing');
SELECT bicycle_rental.handover_to_maintenance(:staff_id, :bicycle_id, :provider_id);
SELECT bicycle_rental.return_from_maintenance(:staff_id, :bicycle_id, :station_id, 'serviceable');
SELECT * FROM bicycle_rental.get_bicycle_movement_history(:staff_id, :bicycle_id, 50, 0);
```

## Rules

- **Transfer:** the bicycle must be at the named source station, not on a rental and not at a provider. Source and destination must differ and the destination must exist. A destination with rider controls switched off is allowed. A transfer keeps the maintenance state and does not change rentals.
- **Handover:** the bicycle must be at a station and not rented. The provider must exist and be active. The station is cleared, placement becomes `maintenance_provider` and the state becomes `unavailable_for_maintenance`. Rider station controls do not block a handover.
- **Return:** the bicycle must be at a provider. The state is supplied explicitly (`serviceable` or `unavailable_for_maintenance`), the provider reference is cleared and the bicycle is placed at the given station. It may return to a different station than it left.
- **Repeats and conflicts** (second handover, second return, moving a bicycle that is not where the caller says) are rejected and change nothing.

## Atomic and concurrency-safe

Every movement runs in one transaction: the record, the placement change and the audit entry commit together or not at all. Operations lock rows in a fixed order (bicycle, then station), so concurrent attempts on the same bicycle serialize and the loser sees the committed state and is rejected, with no deadlocks. A rental start racing a transfer or handover of the same bicycle has exactly one winner.

## History

`bicycle_transfer` holds station transfers: bicycle, source, destination, staff actor, server timestamp and reason. It is append-only: updates and deletes are rejected (SQLSTATE `23000`), and references to stations, bicycles and staff are restricted so history cannot be orphaned. A database trigger also checks that a record's source equals the bicycle's current station. An index on `(bicycle_id, transferred_at, transfer_id)` serves the history queries.

`get_bicycle_movement_history` merges transfers with the maintenance handovers and returns recorded in the audit log, newest first, with `limit` 1 to 200 and `offset` of 0 or more. Each row has a `movement_type` of `station_transfer`, `maintenance_handover` or `maintenance_return`. Rentals are not included; see the rental history.

Only the retention purge (36 months after the transfer) may delete transfer records. See [access control](access-control.md#retention-purge).

## Errors

| SQLSTATE | Meaning |
| --- | --- |
| `42501` | Actor is not a staff account |
| `22023` | Invalid input: NULL arguments, same station, unknown destination or provider, over-long reason, bad paging values, repeated handover or return |
| `P0002` | Unknown bicycle |
| `55000` | State conflict: bicycle not at the stated source, on a rental, or at a provider |
| `23000` / `23514` | Attempt to change a transfer record, or to insert one that conflicts with the bicycle's location |

## Tests

[`db/tests/bicycle_movement.sql`](../db/tests/bicycle_movement.sql) covers the rules, rollback, immutability and history paging. [`db/tests/bicycle_movement_concurrency.sh`](../db/tests/bicycle_movement_concurrency.sh) races movements, rental starts and maintenance updates on the same bicycle.

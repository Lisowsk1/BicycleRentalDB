# Database operations

The `bicycle_rental` schema exposes its functionality through a fixed set of `SECURITY DEFINER` functions and procedures granted to `bicycle_app` (and administrative routines granted to `bicycle_setup`). Internal helpers (`*_internal`, `*_without_audit`, `require_*`), the raw simulator routines, and trigger functions are not callable by application logins.

See [Access control](access-control.md) for role boundaries, [Bicycle movements](bicycle-movements.md) for placement rules, and [Simulated payments](payments.md) for payment transaction semantics.

## Runnable operation examples (U-003)

After running all Flyway migrations (`V001`-`V030`), the baseline seed (`V003` and `V013`) provides two active tariffs (`regular` at `2.50 PLN / 900s`, `electric` at `4.50 PLN / 900s`), two stations (`Central Station` and `Market Square`), an active rider (`jan.kowalski@bicyclerental.local`), and an available regular bicycle (`BIKE-REG-001` at `Market Square`).

```sql
-- 1. Query station availability (returns regular and electric counts per station)
SELECT station_id, name, rental_enabled, return_enabled,
       regular_available, electric_available
  FROM bicycle_rental.get_station_availability(
         (SELECT account_id FROM bicycle_rental.account WHERE email = 'jan.kowalski@bicyclerental.local'),
         NULL
       );

-- 2. Start a rental for BIKE-REG-001 using the active regular tariff
SELECT *
  FROM bicycle_rental.start_rental(
         (SELECT account_id FROM bicycle_rental.account WHERE email = 'jan.kowalski@bicyclerental.local'),
         (SELECT bicycle_id FROM bicycle_rental.bicycle WHERE identifier = 'BIKE-REG-001'),
         (SELECT tariff_id  FROM bicycle_rental.tariff WHERE bicycle_type = 'regular' AND is_active)
       );

-- 3. Return that active rental to Central Station (computes final_charge and sets completed_now = true)
SELECT (details).rental_id,
       (details).state,
       (details).return_station_name,
       (details).final_charge,
       (details).currency,
       completed_now
  FROM bicycle_rental.return_rental(
         (SELECT account_id FROM bicycle_rental.account WHERE email = 'jan.kowalski@bicyclerental.local'),
         (SELECT rental_id  FROM bicycle_rental.rental
           WHERE bicycle_id = (SELECT bicycle_id FROM bicycle_rental.bicycle WHERE identifier = 'BIKE-REG-001')
             AND end_time IS NULL),
         (SELECT station_id FROM bicycle_rental.station WHERE name = 'Central Station')
       );
```

---

## Accounts and authentication

| Routine | Caller | Returns | Audited |
| --- | --- | --- | --- |
| `register_rider(p_first_name text, p_last_name text, p_email text, p_password text)` | Unauthenticated | `bigint` (`account_id`) | No |
| `authenticate_account(p_email text, p_password text)` | Unauthenticated | `TABLE (account_id, role, first_name, last_name, email, rider_status)` | No |
| `get_account(p_actor_id bigint, p_account_id bigint)` | Rider (self only) or Staff | `TABLE (account_id, first_name, last_name, email, role, rider_status, block_reason)` | No |
| `list_riders(p_actor_id bigint, p_status rider_status DEFAULT NULL)` | Staff | `TABLE (account_id, first_name, last_name, email, rider_status, block_reason)` | No |
| `block_rider(p_actor_id bigint, p_rider_id bigint, p_reason text DEFAULT NULL)` | Staff | `boolean` | Yes |
| `unblock_rider(p_actor_id bigint, p_rider_id bigint)` | Staff | `boolean` | Yes |

## Stations and fleet

| Routine | Caller | Returns | Audited |
| --- | --- | --- | --- |
| `create_station(p_actor_id bigint, p_name text, p_address text, p_latitude numeric, p_longitude numeric, p_rental_enabled boolean, p_return_enabled boolean)` | Staff | `bigint` (`station_id`) | Yes |
| `update_station(p_actor_id bigint, p_station_id bigint, p_name text DEFAULT NULL, p_address text DEFAULT NULL, p_latitude numeric DEFAULT NULL, p_longitude numeric DEFAULT NULL, p_rental_enabled boolean DEFAULT NULL, p_return_enabled boolean DEFAULT NULL)` | Staff | `boolean` | Yes |
| `set_station_controls(p_actor_id bigint, p_station_id bigint, p_rental_enabled boolean DEFAULT NULL, p_return_enabled boolean DEFAULT NULL)` | Staff | `boolean` | Yes |
| `get_station_availability(p_actor_id bigint, p_station_id bigint DEFAULT NULL)` | Rider or Staff | `TABLE (station_id, name, address, latitude, longitude, rental_enabled, return_enabled, regular_available, electric_available)` | No |
| `create_bicycle(p_actor_id bigint, p_identifier text, p_bicycle_type bicycle_type, p_maintenance_state maintenance_state, p_station_id bigint, p_battery_percentage numeric DEFAULT NULL)` | Staff | `bigint` (`bicycle_id`) | No |
| `set_maintenance_state(p_actor_id bigint, p_bicycle_id bigint, p_maintenance_state maintenance_state)` | Staff | `boolean` | Yes |
| `update_battery(p_actor_id bigint, p_bicycle_id bigint, p_battery numeric)` | Staff | `void` | No |
| `import_battery_readings(p_actor_id bigint, p_records jsonb)` | Staff | `TABLE (record_no integer, bicycle_ref bigint, result text)` | No |

## Bicycle movements

Details in [Bicycle movements](bicycle-movements.md).

| Routine | Caller | Returns | Audited |
| --- | --- | --- | --- |
| `transfer_bicycle(p_actor_id bigint, p_bicycle_id bigint, p_from_station_id bigint, p_to_station_id bigint, p_reason text DEFAULT NULL)` | Staff | `bicycle_transfer` | No |
| `handover_to_maintenance(p_actor_id bigint, p_bicycle_id bigint, p_provider_id bigint)` | Staff | `void` | Yes |
| `return_from_maintenance(p_actor_id bigint, p_bicycle_id bigint, p_station_id bigint, p_maintenance_state maintenance_state)` | Staff | `void` | Yes |
| `get_bicycle_movement_history(p_actor_id bigint, p_bicycle_id bigint, p_limit integer DEFAULT 50, p_offset integer DEFAULT 0)` | Staff | `SETOF bicycle_movement` | No |
| `get_bicycle_transfer_history(p_actor_id bigint, p_bicycle_id bigint, p_limit integer DEFAULT 50, p_offset integer DEFAULT 0)` | Staff | `SETOF bicycle_transfer` | No |

## Tariffs, rentals, and usage statistics

| Routine | Caller | Returns | Audited |
| --- | --- | --- | --- |
| `get_active_tariffs(p_actor_id bigint)` | Rider or Staff | `TABLE (tariff_id, bicycle_type, price_per_block, block_length_seconds, currency)` | No |
| `check_rental_eligibility(p_actor_id bigint, p_bicycle_id bigint)` | Rider | `TABLE (eligible boolean, reason text)` | No |
| `start_rental(p_actor_id bigint, p_bicycle_id bigint, p_expected_tariff_id bigint DEFAULT NULL)` | Rider | `rental_details` | No |
| `return_rental(p_actor_id bigint, p_rental_id bigint, p_station_id bigint)` | Rider (owner) | `TABLE (details rental_details, completed_now boolean)` | No |
| `staff_return_rental(p_actor_id bigint, p_rental_id bigint, p_station_id bigint)` | Staff | `TABLE (details rental_details, completed_now boolean)` | Yes (first completion) |
| `get_rental(p_actor_id bigint, p_rental_id bigint)` | Rider (owner) or Staff | `rental_details` | No |
| `get_active_rental(p_actor_id bigint)` | Rider | `SETOF rental_details` | No |
| `get_rental_history(p_actor_id bigint, p_limit integer DEFAULT 50, p_offset integer DEFAULT 0)` | Rider | `SETOF rental_details` | No |
| `search_active_rentals(p_staff_id bigint, p_rental_id bigint DEFAULT NULL, p_rider_id bigint DEFAULT NULL, p_bicycle_id bigint DEFAULT NULL, p_bicycle_identifier text DEFAULT NULL)` | Staff | `TABLE (rental_id, rider_id, rider_first_name, rider_last_name, rider_email, bicycle_id, bicycle_identifier, bicycle_type, pickup_station_id, pickup_station_name, start_time, price_per_block, block_length_seconds, currency)` | No |
| `get_usage_statistics(p_staff_id bigint)` | Staff | `TABLE (completed_count, total_duration_seconds, average_duration_seconds)` | No |
| `get_station_pair_statistics(p_staff_id bigint)` | Staff | `TABLE (pickup_station_id, pickup_station_name, return_station_id, return_station_name, completed_count)` | No |

## Faults and maintenance

| Routine | Caller | Returns | Audited |
| --- | --- | --- | --- |
| `create_maintenance_provider(p_actor_id bigint, p_name text, p_contact_email text DEFAULT NULL, p_contact_phone text DEFAULT NULL)` | Staff | `bigint` (`provider_id`) | No |
| `update_maintenance_provider(p_actor_id bigint, p_provider_id bigint, p_name text DEFAULT NULL, p_contact_email text DEFAULT NULL, p_clear_contact_email boolean DEFAULT false, p_contact_phone text DEFAULT NULL, p_clear_contact_phone boolean DEFAULT false)` | Staff | `boolean` | No |
| `set_maintenance_provider_active(p_actor_id bigint, p_provider_id bigint, p_is_active boolean)` | Staff | `boolean` | No |
| `get_maintenance_provider(p_actor_id bigint, p_provider_id bigint)` | Staff | `TABLE (provider_id, name, contact_email, contact_phone, is_active)` | No |
| `list_maintenance_providers(p_actor_id bigint, p_is_active boolean DEFAULT NULL)` | Staff | `TABLE (provider_id, name, contact_email, contact_phone, is_active)` | No |
| `submit_fault_report(p_actor_id bigint, p_bicycle_id bigint, p_category fault_category, p_severity fault_severity, p_description text, p_rental_id bigint DEFAULT NULL)` | Rider or Staff | `bigint` (`report_id`) | Staff only |
| `link_fault_report_to_job(p_actor_id bigint, p_report_id bigint, p_job_id bigint)` | Staff | `boolean` | Yes |
| `review_fault_report(p_actor_id bigint, p_report_id bigint, p_status fault_status, p_maintenance_job_id bigint DEFAULT NULL)` | Staff | `boolean` | Yes |
| `get_fault_report(p_actor_id bigint, p_report_id bigint)` | Rider (reporter) or Staff | `TABLE (report_id, bicycle_id, bicycle_identifier, reported_by_account_id, rental_id, maintenance_job_id, category, severity, description, status, reported_at, resolved_at)` | No |
| `list_fault_reports(p_actor_id bigint, p_bicycle_id bigint DEFAULT NULL, p_status fault_status DEFAULT NULL, p_job_id bigint DEFAULT NULL)` | Staff | `TABLE (report_id, bicycle_id, bicycle_identifier, reported_by_account_id, rental_id, maintenance_job_id, category, severity, description, status, reported_at, resolved_at)` | No |
| `open_maintenance_job(p_actor_id bigint, p_bicycle_id bigint, p_provider_id bigint DEFAULT NULL, p_assigned_staff_id bigint DEFAULT NULL)` | Staff | `bigint` (`job_id`) | Yes |
| `assign_maintenance_job(p_actor_id bigint, p_job_id bigint, p_provider_id bigint DEFAULT NULL, p_clear_provider boolean DEFAULT false, p_assigned_staff_id bigint DEFAULT NULL, p_clear_assigned_staff boolean DEFAULT false)` | Staff | `boolean` | Yes |
| `start_maintenance_job(p_actor_id bigint, p_job_id bigint)` | Staff | `boolean` | Yes |
| `add_maintenance_task(p_actor_id bigint, p_job_id bigint, p_task_type maintenance_task_type, p_description text, p_task_no integer DEFAULT NULL)` | Staff | `integer` (`task_no`) | Yes |
| `complete_maintenance_task(p_actor_id bigint, p_job_id bigint, p_task_no integer, p_outcome text)` | Staff | `void` | Yes |
| `complete_maintenance_job(p_actor_id bigint, p_job_id bigint, p_resolution text)` | Staff | `void` | Yes |
| `cancel_maintenance_job(p_actor_id bigint, p_job_id bigint, p_resolution text)` | Staff | `void` | Yes |
| `get_maintenance_job(p_actor_id bigint, p_job_id bigint)` | Staff | `TABLE (job_id, bicycle_id, bicycle_identifier, provider_id, assigned_staff_id, status, opened_at, started_at, closed_at, resolution)` | No |
| `list_maintenance_jobs(p_actor_id bigint, p_bicycle_id bigint DEFAULT NULL, p_status maintenance_job_status DEFAULT NULL, p_provider_id bigint DEFAULT NULL, p_assigned_staff_id bigint DEFAULT NULL)` | Staff | `TABLE (job_id, bicycle_id, bicycle_identifier, provider_id, assigned_staff_id, status, opened_at, started_at, closed_at, resolution)` | No |
| `list_maintenance_tasks(p_actor_id bigint, p_job_id bigint)` | Staff | `TABLE (maintenance_job_id, task_no, task_type, description, outcome, completed_at)` | No |

## Payments

Details in [Simulated payments](payments.md).

| Routine | Caller | Returns | Audited |
| --- | --- | --- | --- |
| `request_payment(p_actor_id bigint, p_rental_id bigint)` | Rider (owner) | `TABLE (payment_reference, status, amount, currency)` | No |
| `CALL submit_payment(p_actor_id bigint, p_payment_reference uuid, INOUT status payment_status DEFAULT NULL, INOUT uncertain boolean DEFAULT NULL)` | Rider (owner, autocommit only) | Procedure (`status`, `uncertain`) | No |
| `prepare_payment_submission(p_actor_id bigint, p_payment_reference uuid)` | Rider (owner, adapter phase 1) | `TABLE (payment_reference, status, amount, currency, uncertain, confirmation_available)` | No |
| `confirm_payment_submission(p_actor_id bigint, p_payment_reference uuid)` | Rider (owner, adapter phase 2) | `TABLE (payment_reference, status, amount, currency, uncertain)` | No |
| `get_rental_payment(p_actor_id bigint, p_rental_id bigint)` | Rider (owner) or Staff | `TABLE (rental_id, charge, currency, payment_reference, payment_status, display_state, simulated)` | No |
| `list_rider_payments(p_actor_id bigint, p_rider_id bigint)` | Rider (self) or Staff | `TABLE (rental_id, payment_reference, payment_status, amount, currency)` | No |

## Audit log queries

Details in [Audit integration](audit-integration.md).

| Routine | Caller | Returns | Audited |
| --- | --- | --- | --- |
| `list_audit_entries(p_actor_id bigint, p_staff_id bigint DEFAULT NULL, p_action_type audit_action_type DEFAULT NULL, p_record_type audit_record_type DEFAULT NULL, p_record_id bigint DEFAULT NULL, p_from timestamptz DEFAULT NULL, p_to timestamptz DEFAULT NULL)` | Staff | `TABLE (audit_id, staff_id, action_type, primary_record_type, primary_record_id, created_at)` | No |
| `list_audit_entries_with_details(p_actor_id bigint, p_staff_id bigint DEFAULT NULL, p_action_type audit_action_type DEFAULT NULL, p_record_type audit_record_type DEFAULT NULL, p_record_id bigint DEFAULT NULL, p_from timestamptz DEFAULT NULL, p_to timestamptz DEFAULT NULL, p_operation_type text DEFAULT NULL)` | Staff | `TABLE (audit_id, staff_id, action_type, primary_record_type, primary_record_id, created_at, operation_type, detail_no, subject_record_type, subject_record_id, field_name, previous_value, new_value)` | No |
| `get_audit_entry_details(p_actor_id bigint, p_audit_id bigint)` | Staff | `TABLE (detail_no, subject_record_type, subject_record_id, field_name, previous_value, new_value)` | No |

## Privileged setup and administration

Details in [Access control](access-control.md).

| Routine | Caller | Returns | Audited |
| --- | --- | --- | --- |
| `provision_staff(p_first_name text, p_last_name text, p_email text, p_password text)` | `bicycle_setup` | `bigint` (`account_id`) | No |
| `configure_tariffs(p_regular_price_per_block numeric(12,2), p_regular_block_length_seconds integer, p_electric_price_per_block numeric(12,2), p_electric_block_length_seconds integer, p_currency text)` | `bicycle_setup` | `TABLE (tariff_id, bicycle_type, price_per_block, block_length_seconds, currency)` | No |
| `purge_expired_records(p_as_of timestamptz DEFAULT clock_timestamp())` | `bicycle_setup` | `TABLE (entity_name text, deleted_rows bigint)` | No |
| `reset_baseline()` | `bicycle_setup` members | `void` | No |
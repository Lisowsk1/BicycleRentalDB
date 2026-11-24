#!/usr/bin/env bash
# Competing bicycle movements from separate sessions (R-004, R-005, F-027, F-029, F-030, F-093).
#
# Every worker is its own psql session that blocks on a shared advisory lock; once all workers are
# waiting, the lock holder is terminated and they all run at the same moment.
#
# This script COMMITS its fixtures (transfer records and audit entries cannot be deleted), so run it
# against a disposable database, such as the CI database or a freshly migrated local one.
#
# Usage:  bash db/tests/bicycle_movement_concurrency.sh
#   PSQL_CMD overrides the client, e.g.
#   PSQL_CMD="docker compose exec -T db psql --username bicycle --dbname bicycle_rental" bash db/tests/bicycle_movement_concurrency.sh
set -u
PSQL=${PSQL_CMD:-psql}
KEY=${BARRIER_KEY:-48212}
ITER=${ITERATIONS:-8}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

q() { printf '%s\n' "$1" | $PSQL -X -At -q 2>&1 | tr -d '\r'; }
ok()  { PASS=$((PASS+1)); printf 'PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL  %s\n' "$1"; }
check() { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (expected '$2', got '$1')"; fi; }

# race <name> <sql>...   one worker per sql argument; results in $TMP/<name>.<i> as "OK|<output>" or "ERR|<sqlstate>"
race() {
    local name=$1; shift
    local n=$#
    printf 'SELECT pg_advisory_lock(7, %s);\nSELECT pg_sleep(60);\n' "$KEY" | $PSQL -X -At -q >/dev/null 2>&1 &
    local holder=$!
    for _ in $(seq 200); do
        [ "$(q "SELECT count(*) FROM pg_locks WHERE locktype='advisory' AND classid=7 AND objid=$KEY AND granted")" = 1 ] && break
        sleep 0.05
    done
    local i=0 pids=()
    for sql in "$@"; do
        i=$((i+1))
        ( printf 'SELECT pg_advisory_lock_shared(7, %s);\n%s\n\\echo RESULT_SQLSTATE=:LAST_ERROR_SQLSTATE\n' "$KEY" "$sql" \
            | $PSQL -X -At -q 2>&1 | tr -d '\r' | grep -v '^$' > "$TMP/raw.$name.$i"
          # The SQLSTATE comes from psql itself, so this works with any server or client language.
          code=$(grep -o 'RESULT_SQLSTATE=.*' "$TMP/raw.$name.$i" | tail -n 1 | cut -d= -f2)
          if [ -z "$code" ]; then
              echo "ERR|no-result" > "$TMP/$name.$i"
          elif [ "$code" != 00000 ]; then
              echo "ERR|$code" > "$TMP/$name.$i"
          else
              echo "OK|$(grep -v 'RESULT_SQLSTATE=' "$TMP/raw.$name.$i" | tr '\n' ' ' | sed 's/ $//')" > "$TMP/$name.$i"
          fi ) &
        pids+=($!)
    done
    for _ in $(seq 200); do
        [ "$(q "SELECT count(*) FROM pg_locks WHERE locktype='advisory' AND classid=7 AND objid=$KEY AND NOT granted")" -ge "$n" ] && break
        sleep 0.05
    done
    q "SELECT pg_terminate_backend(pid) FROM pg_locks WHERE locktype='advisory' AND classid=7 AND objid=$KEY AND granted AND mode='ExclusiveLock'" >/dev/null
    wait "${pids[@]}"; wait "$holder" 2>/dev/null
}
count_out() { cat "$TMP/$1".[0-9]* 2>/dev/null | grep -c "^$2" ; }
errors_of() { cat "$TMP/$1".[0-9]* 2>/dev/null | grep '^ERR|' | sed 's/^ERR|//' | sort | uniq -c | tr '\n' ' '; }

# Fixture builder: prints "staff station_a station_b ..." ids. Fake bcrypt-shaped hash: no logins here.
new_fixture() {
    q "
    SET search_path = bicycle_rental, public;
    WITH s AS (INSERT INTO account (first_name,last_name,email,password_hash,role)
               VALUES ('C','Staff','conc-'||gen_random_uuid()||'@test.invalid','\$2a\$12\$'||repeat('x',53),'staff') RETURNING account_id),
         s2 AS (INSERT INTO staff (account_id) SELECT account_id FROM s RETURNING account_id)
    SELECT account_id FROM s2;"
}
new_rider() {
    q "
    SET search_path = bicycle_rental, public;
    WITH a AS (INSERT INTO account (first_name,last_name,email,password_hash,role)
               VALUES ('C','Rider','conc-'||gen_random_uuid()||'@test.invalid','\$2a\$12\$'||repeat('x',53),'rider') RETURNING account_id),
         r AS (INSERT INTO rider (account_id) SELECT account_id FROM a RETURNING account_id)
    SELECT account_id FROM r;"
}
new_station() { q "SELECT bicycle_rental.create_station($1, 'conc-'||gen_random_uuid(), 'Street', 52, 21, true, true);"; }
new_bike() { q "SELECT bicycle_rental.create_bicycle($1, 'conc-'||gen_random_uuid(), 'regular', 'serviceable', $2);"; }

new_provider() { q "SELECT bicycle_rental.create_maintenance_provider($1, 'conc-'||gen_random_uuid());"; }
audits() { q "SELECT count(*) FROM bicycle_rental.audit_entry WHERE primary_record_type='Bicycle' AND primary_record_id=$1 AND action_type='$2'"; }
snap() { q "SELECT placement||':'||coalesce(current_station_id,0)||':'||coalesce(current_provider_id,0)||':'||maintenance_state FROM bicycle_rental.bicycle WHERE bicycle_id=$1"; }
transfers() { q "SELECT count(*) FROM bicycle_rental.bicycle_transfer WHERE bicycle_id=$1"; }
only_errors() { [ "$(count_out "$1" 'ERR')" = "$(cat "$TMP/$1".[0-9]* 2>/dev/null | grep -c "^ERR|$2")" ]; }

STAFF=$(new_fixture)
[ -n "$STAFF" ] || { echo "cannot create fixtures; is the database migrated and reachable?"; exit 2; }
ST_A=$(new_station "$STAFF"); ST_B=$(new_station "$STAFF"); ST_C=$(new_station "$STAFF")
PROV=$(new_provider "$STAFF"); PROV2=$(new_provider "$STAFF")

# -- competing transfers of one bicycle to different destinations
BIKE=$(new_bike "$STAFF" "$ST_A")
args=(); for i in 1 2 3; do
    args+=("SELECT 'moved' FROM bicycle_rental.transfer_bicycle($STAFF, $BIKE, $ST_A, $ST_B, 'race');")
    args+=("SELECT 'moved' FROM bicycle_rental.transfer_bicycle($STAFF, $BIKE, $ST_A, $ST_C, 'race');")
done
race m1 "${args[@]}"
check "$(count_out m1 'OK|moved')" 1 "competing transfers: exactly one succeeds"
check "$(count_out m1 'ERR|55000')" 5 "competing transfers: the others are rejected for the wrong source (55000)"
check "$(transfers "$BIKE")" 1 "competing transfers: exactly one record stored"
check "$(q "SELECT (b.current_station_id = t.to_station_id AND t.from_station_id = $ST_A)::int FROM bicycle_rental.bicycle b JOIN bicycle_rental.bicycle_transfer t USING (bicycle_id) WHERE b.bicycle_id=$BIKE")" 1 "competing transfers: the bicycle is at the recorded destination"

# competing handovers
BIKE=$(new_bike "$STAFF" "$ST_A")
args=(); for p in "$PROV" "$PROV2" "$PROV" "$PROV2"; do args+=("SELECT 'handed' FROM (SELECT bicycle_rental.handover_to_maintenance($STAFF, $BIKE, $p)) x;"); done
race m2 "${args[@]}"
check "$(count_out m2 'OK|handed')" 1 "competing handovers: exactly one succeeds"
check "$(count_out m2 'ERR|22023')" 3 "competing handovers: the others are rejected (22023)"
check "$(audits "$BIKE" maintenance_handover)" 1 "competing handovers: exactly one audit entry"
check "$(q "SELECT (placement='maintenance_provider' AND current_station_id IS NULL AND current_provider_id IS NOT NULL AND maintenance_state='unavailable_for_maintenance')::int FROM bicycle_rental.bicycle WHERE bicycle_id=$BIKE")" 1 "competing handovers: bicycle is with one provider"

# competing maintenance returns to different stations
args=(); for s in "$ST_A" "$ST_B" "$ST_A" "$ST_B"; do args+=("SELECT 'back' FROM (SELECT bicycle_rental.return_from_maintenance($STAFF, $BIKE, $s, 'serviceable')) x;"); done
race m3 "${args[@]}"
check "$(count_out m3 'OK|back')" 1 "competing maintenance returns: exactly one succeeds"
check "$(count_out m3 'ERR|22023')" 3 "competing maintenance returns: the others are rejected (22023)"
check "$(audits "$BIKE" maintenance_return)" 1 "competing maintenance returns: exactly one audit entry"
check "$(q "SELECT (b.placement='station' AND b.current_provider_id IS NULL AND b.maintenance_state='serviceable' AND b.current_station_id = (SELECT (d.new_value #>> '{}')::bigint FROM bicycle_rental.audit_entry e JOIN bicycle_rental.audit_detail d USING (audit_id) WHERE e.primary_record_id=$BIKE AND e.action_type='maintenance_return' AND d.field_name='current_station_id'))::int FROM bicycle_rental.bicycle b WHERE b.bicycle_id=$BIKE")" 1 "competing maintenance returns: bicycle is at the audited destination"

# transfer vs handover, repeated to hit both orders: the handover always works, the transfer only if it came first
okc=0
for i in $(seq "$ITER"); do
    B=$(new_bike "$STAFF" "$ST_A")
    race m4 "SELECT 'moved' FROM bicycle_rental.transfer_bicycle($STAFF, $B, $ST_A, $ST_B);" "SELECT 'handed' FROM (SELECT bicycle_rental.handover_to_maintenance($STAFF, $B, $PROV)) x;"
    moved=$(count_out m4 'OK|moved'); handed=$(count_out m4 'OK|handed')
    src=$([ "$moved" = 1 ] && echo "$ST_B" || echo "$ST_A")
    audited_src=$(q "SELECT (d.previous_value #>> '{}') FROM bicycle_rental.audit_entry e JOIN bicycle_rental.audit_detail d USING (audit_id) WHERE e.primary_record_id=$B AND e.action_type='maintenance_handover' AND d.field_name='current_station_id'")
    if [ "$handed" = 1 ] && [ "$(transfers "$B")" = "$moved" ] && only_errors m4 55000 && [ "$audited_src" = "$src" ] && [ "$(snap "$B" | cut -d: -f1)" = maintenance_provider ]; then okc=$((okc+1)); else echo "   transfer/handover outcome: moved=$moved handed=$handed audited_src=$audited_src errors=$(errors_of m4)"; fi
done
check "$okc" "$ITER" "transfer vs handover ($ITER runs): the handover always applies, the transfer is recorded exactly when it came first"

# transfer vs rental start (R-005): the rental always starts, at the old or the new station
okc=0
for i in $(seq "$ITER"); do
    R=$(new_rider); B=$(new_bike "$STAFF" "$ST_A")
    race m5 "SELECT 'moved' FROM bicycle_rental.transfer_bicycle($STAFF, $B, $ST_A, $ST_B);" "SELECT 'started' FROM bicycle_rental.start_rental($R, $B);"
    moved=$(count_out m5 'OK|moved')
    want=$([ "$moved" = 1 ] && echo "$ST_B" || echo "$ST_A")
    pickup=$(q "SELECT pickup_station_id FROM bicycle_rental.rental WHERE bicycle_id=$B AND end_time IS NULL")
    if [ "$(count_out m5 'OK|started')" = 1 ] && [ "$pickup" = "$want" ] && [ "$(transfers "$B")" = "$moved" ] && only_errors m5 55000 && [ "$(snap "$B")" = "active_rental:0:0:serviceable" ]; then okc=$((okc+1)); else echo "   transfer/start outcome: moved=$moved pickup=$pickup want=$want errors=$(errors_of m5)"; fi
done
check "$okc" "$ITER" "transfer vs rental start ($ITER runs): the start succeeds and records the pickup station that matches the transfer order"

# handover vs rental start: exactly one wins
okc=0
for i in $(seq "$ITER"); do
    R=$(new_rider); B=$(new_bike "$STAFF" "$ST_A")
    race m6 "SELECT 'handed' FROM (SELECT bicycle_rental.handover_to_maintenance($STAFF, $B, $PROV)) x;" "SELECT 'started' FROM bicycle_rental.start_rental($R, $B);"
    handed=$(count_out m6 'OK|handed'); started=$(count_out m6 'OK|started')
    rentals=$(q "SELECT count(*) FROM bicycle_rental.rental WHERE bicycle_id=$B")
    want=$([ "$handed" = 1 ] && echo "maintenance_provider:0:$PROV:unavailable_for_maintenance" || echo "active_rental:0:0:serviceable")
    if [ $((handed + started)) = 1 ] && [ "$(snap "$B")" = "$want" ] && [ "$rentals" = "$started" ] && [ "$(audits "$B" maintenance_handover)" = "$handed" ]; then okc=$((okc+1)); else echo "   handover/start outcome: handed=$handed started=$started state=$(snap "$B") errors=$(errors_of m6)"; fi
done
check "$okc" "$ITER" "handover vs rental start ($ITER runs): exactly one wins and the stored state, rental and audit all match it"

# transfer vs maintenance-state update: both apply, in either order
okc=0
for i in $(seq "$ITER"); do
    B=$(new_bike "$STAFF" "$ST_A")
    race m7 "SELECT 'moved' FROM bicycle_rental.transfer_bicycle($STAFF, $B, $ST_A, $ST_B);" "SELECT 'set' FROM (SELECT bicycle_rental.set_maintenance_state($STAFF, $B, 'unavailable_for_maintenance')) x;"
    if [ "$(count_out m7 'OK|moved')" = 1 ] && [ "$(count_out m7 'OK|set')" = 1 ] && [ "$(snap "$B")" = "station:$ST_B:0:unavailable_for_maintenance" ] && [ "$(transfers "$B")" = 1 ]; then okc=$((okc+1)); else echo "   transfer/state outcome: state=$(snap "$B") errors=$(errors_of m7)"; fi
done
check "$okc" "$ITER" "transfer vs maintenance-state update ($ITER runs): both apply and the transfer keeps the new state"

# global invariants
check "$(q "SELECT count(*) FROM bicycle_rental.bicycle b WHERE ((b.placement='station') <> (b.current_station_id IS NOT NULL)) OR ((b.placement='maintenance_provider') <> (b.current_provider_id IS NOT NULL)) OR ((b.placement='active_rental') <> EXISTS (SELECT 1 FROM bicycle_rental.rental r WHERE r.bicycle_id=b.bicycle_id AND r.end_time IS NULL))")" 0 "invariant: placement, station, provider and rental state agree for every bicycle"
check "$(q "SELECT count(*) FROM bicycle_rental.bicycle_transfer WHERE from_station_id = to_station_id")" 0 "invariant: no transfer has equal stations"
check "$(q "SELECT count(*) FROM (SELECT bicycle_id FROM bicycle_rental.rental WHERE end_time IS NULL GROUP BY 1 HAVING count(*)>1) x")" 0 "invariant: no bicycle has two active rentals"
check "$(q "SELECT count(*) FROM bicycle_rental.audit_entry e WHERE NOT EXISTS (SELECT 1 FROM bicycle_rental.audit_detail d WHERE d.audit_id = e.audit_id)")" 0 "invariant: every audit entry has details"
if cat "$TMP"/*.[0-9]* 2>/dev/null | grep -q '40P01\|40001'; then bad "no deadlocks or serialization failures"; else ok "no deadlocks or serialization failures"; fi

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

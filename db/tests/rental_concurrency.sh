#!/usr/bin/env bash
# Competing rental starts and returns from separate sessions (R-003, R-005, R-006, F-041, F-045, F-079).
#
# Every worker is its own psql session that blocks on a shared advisory lock; once all workers are
# waiting, the lock holder is terminated and they all run at the same moment.
#
# This script COMMITS its fixtures (rentals cannot be deleted), so run it against a disposable
# database, such as the CI database or a freshly migrated local one, not a shared one.
#
# Usage:  bash db/tests/rental_concurrency.sh
#   PSQL_CMD overrides the client, e.g.
#   PSQL_CMD="docker compose exec -T db psql --username bicycle --dbname bicycle_rental" bash db/tests/rental_concurrency.sh
set -u
PSQL=${PSQL_CMD:-psql}
KEY=${BARRIER_KEY:-48211}
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

STAFF=$(new_fixture)
[ -n "$STAFF" ] || { echo "cannot create fixtures; is the database migrated and reachable?"; exit 2; }
ST_A=$(new_station "$STAFF"); ST_B=$(new_station "$STAFF")

# -- competing starts, same bicycle
BIKE=$(new_bike "$STAFF" "$ST_A")
RIDERS=(); for _ in 1 2 3 4 5 6 7 8; do RIDERS+=("$(new_rider)"); done
args=(); for r in "${RIDERS[@]}"; do args+=("SELECT 'started' FROM bicycle_rental.start_rental($r, $BIKE);"); done
race s1 "${args[@]}"
check "$(count_out s1 'OK|started')" 1 "same bicycle, 8 riders: exactly one start succeeds"
check "$(count_out s1 'ERR|55000')" 7 "same bicycle: the other 7 get a business-rule rejection (55000)"
check "$(q "SELECT count(*) FROM bicycle_rental.rental WHERE bicycle_id=$BIKE AND end_time IS NULL")" 1 "same bicycle: one active rental stored"
check "$(q "SELECT placement FROM bicycle_rental.bicycle WHERE bicycle_id=$BIKE")" active_rental "same bicycle: placement is active_rental"

# -- competing starts, same rider
RIDER=$(new_rider); BIKES=(); for _ in 1 2 3 4 5 6; do BIKES+=("$(new_bike "$STAFF" "$ST_A")"); done
args=(); for b in "${BIKES[@]}"; do args+=("SELECT 'started' FROM bicycle_rental.start_rental($RIDER, $b);"); done
race s2 "${args[@]}"
check "$(count_out s2 'OK|started')" 1 "same rider, 6 bicycles: exactly one start succeeds"
check "$(count_out s2 'ERR|55000')" 5 "same rider: the other 5 get a business-rule rejection (55000)"
check "$(q "SELECT count(*) FROM bicycle_rental.bicycle WHERE bicycle_id IN ($(IFS=,; echo "${BIKES[*]}")) AND placement='active_rental'")" 1 "same rider: only one bicycle left its station"

# -- competing returns, same destination (rider and staff)
RIDER=$(new_rider); BIKE=$(new_bike "$STAFF" "$ST_A")
RENTAL=$(q "SELECT rental_id FROM bicycle_rental.start_rental($RIDER, $BIKE);")
AUD0=$(q "SELECT count(*) FROM bicycle_rental.audit_entry WHERE primary_record_id=$RENTAL AND action_type='staff_return'")
args=()
for _ in 1 2 3; do
    args+=("SELECT 'done:'||completed_now FROM bicycle_rental.return_rental($RIDER, $RENTAL, $ST_B);")
    args+=("SELECT 'done:'||completed_now FROM bicycle_rental.staff_return_rental($STAFF, $RENTAL, $ST_B);")
done
race s3 "${args[@]}"
check "$(count_out s3 'OK|done:true')" 1 "competing returns: exactly one completes the rental"
check "$(count_out s3 'OK|done:false')" 5 "competing returns: the others report the original completion"
check "$(count_out s3 'ERR')" 0 "competing returns: no errors for the same destination"
check "$(q "SELECT count(*) FROM bicycle_rental.rental WHERE rental_id=$RENTAL AND end_time IS NOT NULL AND final_charge IS NOT NULL")" 1 "competing returns: one stored completion and charge"
WON_STAFF=$(q "SELECT (returned_by_staff_id IS NOT NULL)::int FROM bicycle_rental.rental WHERE rental_id=$RENTAL")
check "$(q "SELECT count(*) FROM bicycle_rental.audit_entry WHERE primary_record_id=$RENTAL AND action_type='staff_return'")" "$WON_STAFF" "competing returns: audit entry exists only if staff completed it, and only once"
check "$(q "SELECT placement||':'||current_station_id FROM bicycle_rental.bicycle WHERE bicycle_id=$BIKE")" "station:$ST_B" "competing returns: bicycle is at the return station"

# -- competing returns, different destinations
RIDER=$(new_rider); BIKE=$(new_bike "$STAFF" "$ST_A")
RENTAL=$(q "SELECT rental_id FROM bicycle_rental.start_rental($RIDER, $BIKE);")
args=()
for _ in 1 2; do
    args+=("SELECT 'done:'||completed_now||':$ST_A' FROM bicycle_rental.return_rental($RIDER, $RENTAL, $ST_A);")
    args+=("SELECT 'done:'||completed_now||':$ST_B' FROM bicycle_rental.staff_return_rental($STAFF, $RENTAL, $ST_B);")
done
race s4 "${args[@]}"
check "$(count_out s4 'OK|done:true')" 1 "different destinations: exactly one completion"
WIN=$(q "SELECT return_station_id FROM bicycle_rental.rental WHERE rental_id=$RENTAL")
check "$(cat "$TMP"/s4.[0-9]* | grep -c "^OK|done:true:$WIN")" 1 "different destinations: the stored station belongs to the winning request"
check "$(count_out s4 'ERR|RT409')" 2 "different destinations: both requests for the other station are conflicts (RT409)"
check "$(q "SELECT current_station_id FROM bicycle_rental.bicycle WHERE bicycle_id=$BIKE")" "$WIN" "different destinations: bicycle is at the winning station"

# -- start vs block, repeated to hit both orders
okc=0
for i in $(seq "$ITER"); do
    R=$(new_rider); B=$(new_bike "$STAFF" "$ST_A")
    race s5 "SELECT 'started' FROM bicycle_rental.start_rental($R, $B);" "SELECT 'blocked' FROM (SELECT bicycle_rental.block_rider($STAFF, $R, 'race')) x;"
    started=$(count_out s5 'OK|started'); rentals=$(q "SELECT count(*) FROM bicycle_rental.rental WHERE rider_id=$R AND end_time IS NULL")
    status=$(q "SELECT status FROM bicycle_rental.rider WHERE account_id=$R")
    if [ "$status" = blocked ] && [ "$started" = "$rentals" ] && [ "$(count_out s5 'ERR')" = "$(count_out s5 'ERR|55000')" ]; then okc=$((okc+1)); else echo "   start/block outcome: started=$started rentals=$rentals status=$status errors=$(errors_of s5)"; fi
done
check "$okc" "$ITER" "start vs block ($ITER runs): rider ends blocked, and a rental exists exactly when the start succeeded"

# -- start vs maintenance update
okc=0
for i in $(seq "$ITER"); do
    R=$(new_rider); B=$(new_bike "$STAFF" "$ST_A")
    race s6 "SELECT 'started' FROM bicycle_rental.start_rental($R, $B);" "SELECT 'set' FROM (SELECT bicycle_rental.set_maintenance_state($STAFF, $B, 'unavailable_for_maintenance')) x;"
    started=$(count_out s6 'OK|started'); rentals=$(q "SELECT count(*) FROM bicycle_rental.rental WHERE bicycle_id=$B AND end_time IS NULL")
    pl=$(q "SELECT placement||':'||maintenance_state FROM bicycle_rental.bicycle WHERE bicycle_id=$B")
    exp_pl=$([ "$started" = 1 ] && echo active_rental || echo station):unavailable_for_maintenance
    if [ "$rentals" = "$started" ] && [ "$pl" = "$exp_pl" ] && [ "$(count_out s6 'ERR')" = "$(count_out s6 'ERR|55000')" ]; then okc=$((okc+1)); else echo "   start/maintenance outcome: started=$started rentals=$rentals placement=$pl errors=$(errors_of s6)"; fi
done
check "$okc" "$ITER" "start vs maintenance update ($ITER runs): start is either fully applied or fully rejected, the update always applies"

# -- return vs destination return-disable
okc=0
for i in $(seq "$ITER"); do
    R=$(new_rider); B=$(new_bike "$STAFF" "$ST_A"); DST=$(new_station "$STAFF")
    RENTAL=$(q "SELECT rental_id FROM bicycle_rental.start_rental($R, $B);")
    race s7 "SELECT 'returned' FROM bicycle_rental.return_rental($R, $RENTAL, $DST);" "SELECT 'disabled' FROM (SELECT bicycle_rental.set_station_controls($STAFF, $DST, true, false)) x;"
    done_=$(q "SELECT (end_time IS NOT NULL)::int FROM bicycle_rental.rental WHERE rental_id=$RENTAL")
    ret=$(count_out s7 'OK|returned'); dis=$(q "SELECT NOT return_enabled FROM bicycle_rental.station WHERE station_id=$DST")
    if [ "$done_" = "$ret" ] && [ "$dis" = t ] && [ "$(count_out s7 'ERR')" = "$(count_out s7 'ERR|55000')" ]; then okc=$((okc+1)); else echo "   return/disable outcome: returned=$ret completed=$done_ disabled=$dis errors=$(errors_of s7)"; fi
done
check "$okc" "$ITER" "return vs return-disable ($ITER runs): a return either completes at the station or is rejected, the disable always applies"

# -- global invariants
check "$(q "SELECT count(*) FROM (SELECT rider_id FROM bicycle_rental.rental WHERE end_time IS NULL GROUP BY 1 HAVING count(*)>1) x")" 0 "invariant: no rider has two active rentals"
check "$(q "SELECT count(*) FROM (SELECT bicycle_id FROM bicycle_rental.rental WHERE end_time IS NULL GROUP BY 1 HAVING count(*)>1) x")" 0 "invariant: no bicycle has two active rentals"
check "$(q "SELECT count(*) FROM bicycle_rental.bicycle b WHERE (b.placement='active_rental') <> EXISTS (SELECT 1 FROM bicycle_rental.rental r WHERE r.bicycle_id=b.bicycle_id AND r.end_time IS NULL)")" 0 "invariant: placement matches rental state for every bicycle"
check "$(q "SELECT count(*) FROM bicycle_rental.rental WHERE (end_time IS NULL) <> (return_station_id IS NULL) OR (end_time IS NULL) <> (final_charge IS NULL)")" 0 "invariant: rental return fields are all present or all absent"
if cat "$TMP"/*.[0-9]* 2>/dev/null | grep -q '40P01\|40001'; then bad "no deadlocks or serialization failures"; else ok "no deadlocks or serialization failures"; fi

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
#!/usr/bin/env bash
# V016: Concurrent payment requests and submissions, using parallel psql sessions.
# Commits data: run against a disposable database with V001..V014 applied.
# Usage: PGDATABASE=rental_test [PGUSER=... PGHOST=...] ./V016_payment_concurrency_test.sh
set -euo pipefail

N=${N:-20}
PSQL="psql -X -q -At -v ON_ERROR_STOP=1"
RUN=$(date +%s%N)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
check() { [ "$2" = "$3" ] || fail "$1: expected $3, got $2"; }
q() { $PSQL -c "$1" | head -1; }

RIDER=$(q "SELECT bicycle_rental.register_rider('Conc','Test','conc.$RUN@example.test','ConcPass123!')")

new_rental() {
    q "INSERT INTO bicycle_rental.rental (
           rider_id, bicycle_id, pickup_station_id, return_station_id, tariff_id, start_time, end_time,
           captured_price_per_block, captured_block_length_seconds, captured_currency, final_charge, bicycle_type)
       SELECT $RIDER, b.bicycle_id, s.station_id, s.station_id, t.tariff_id,
              clock_timestamp() - interval '1 hour', clock_timestamp(),
              t.price_per_block, t.block_length_seconds, t.currency, 5.00, t.bicycle_type
         FROM bicycle_rental.bicycle b, bicycle_rental.station s, bicycle_rental.tariff t
        WHERE b.identifier = 'BIKE-REG-001' AND s.name = 'Market Square'
          AND t.bicycle_type = 'regular' AND t.is_active
       RETURNING rental_id"
}

set_scenario() {
    $PSQL <<SQL
SET bicycle_rental.privileged_setup = 'true';
INSERT INTO bicycle_rental.payment_simulator_scenario (rental_id, scenario) VALUES ($1, '$2');
SQL
}

count() { q "SELECT count(*) FROM $1"; }

parallel() {
    local out=$1 sql=$2 i
    for i in $(seq "$N"); do
        $PSQL -c "$sql" > "$TMP/$out.$i" 2>"$TMP/$out.$i.err" &
    done
    wait
    [ "$(cat "$TMP"/$out.*.err | grep -c .)" = 0 ] || fail "$out: sessions reported errors: $(cat "$TMP"/$out.*.err | head -3)"
}

# C1: concurrent requests for one rental converge on one payment and one reference
R1=$(new_rental)
parallel c1 "SELECT payment_reference FROM bicycle_rental.request_payment($RIDER, $R1)"
check "C1 responses" "$(cat "$TMP"/c1.? "$TMP"/c1.?? 2>/dev/null | grep -c .)" "$N"
check "C1 distinct references" "$(cat "$TMP"/c1.? "$TMP"/c1.?? 2>/dev/null | sort -u | grep -c .)" 1
check "C1 payments" "$(count "bicycle_rental.payment WHERE rental_id = $R1")" 1
REF1=$(head -1 "$TMP/c1.1")
check "C1 requested events" "$(count "bicycle_rental.payment_event e JOIN bicycle_rental.payment p USING (payment_id) WHERE p.payment_reference = '$REF1' AND e.event_type = 'requested'")" 1

# C2: concurrent submissions of one payment settle once
parallel c2 "SELECT status FROM bicycle_rental.submit_payment($RIDER, '$REF1')"
check "C2 successful responses" "$(cat "$TMP"/c2.? "$TMP"/c2.?? 2>/dev/null | grep -c '^successful$')" "$N"
check "C2 simulator records" "$(count "bicycle_rental.payment_simulator_record WHERE payment_reference = '$REF1'")" 1
check "C2 attempts" "$(count "bicycle_rental.payment_event e JOIN bicycle_rental.payment p USING (payment_id) WHERE p.payment_reference = '$REF1' AND e.event_type = 'submission_attempted'")" 1
check "C2 confirmations" "$(count "bicycle_rental.payment_event e JOIN bicycle_rental.payment p USING (payment_id) WHERE p.payment_reference = '$REF1' AND e.event_type = 'confirmed_successful'")" 1

# C3: concurrent submissions with a lost first response: one uncertain answer, one settlement, final success
R3=$(new_rental)
set_scenario "$R3" success_lost_response
REF3=$(q "SELECT payment_reference FROM bicycle_rental.request_payment($RIDER, $R3)")
parallel c3 "SELECT status FROM bicycle_rental.submit_payment($RIDER, '$REF3')"
check "C3 pending responses" "$(cat "$TMP"/c3.? "$TMP"/c3.?? 2>/dev/null | grep -c '^pending$')" 1
check "C3 successful responses" "$(cat "$TMP"/c3.? "$TMP"/c3.?? 2>/dev/null | grep -c '^successful$')" "$((N - 1))"
check "C3 simulator records" "$(count "bicycle_rental.payment_simulator_record WHERE payment_reference = '$REF3'")" 1
check "C3 final status" "$(q "SELECT status FROM bicycle_rental.payment WHERE payment_reference = '$REF3'")" successful

# C4: concurrent submissions of a failing payment settle once as failed
R4=$(new_rental)
set_scenario "$R4" failure
REF4=$(q "SELECT payment_reference FROM bicycle_rental.request_payment($RIDER, $R4)")
parallel c4 "SELECT status FROM bicycle_rental.submit_payment($RIDER, '$REF4')"
check "C4 failed responses" "$(cat "$TMP"/c4.? "$TMP"/c4.?? 2>/dev/null | grep -c '^failed$')" "$N"
check "C4 simulator records" "$(count "bicycle_rental.payment_simulator_record WHERE payment_reference = '$REF4'")" 1
check "C4 final status" "$(q "SELECT status FROM bicycle_rental.payment WHERE payment_reference = '$REF4'")" failed

# C5: concurrent request + submit mix on a fresh rental produces one payment and one settlement
R5=$(new_rental)
REF5=$(q "SELECT payment_reference FROM bicycle_rental.request_payment($RIDER, $R5)")
for i in $(seq "$N"); do
    $PSQL -c "SELECT payment_reference FROM bicycle_rental.request_payment($RIDER, $R5)" > "$TMP/c5r.$i" 2>>"$TMP/c5.err" &
    $PSQL -c "SELECT status FROM bicycle_rental.submit_payment($RIDER, '$REF5')" > "$TMP/c5s.$i" 2>>"$TMP/c5.err" &
done
wait
[ ! -s "$TMP/c5.err" ] || fail "C5 errors: $(head -3 "$TMP/c5.err")"
check "C5 payments" "$(count "bicycle_rental.payment WHERE rental_id = $R5")" 1
check "C5 simulator records" "$(count "bicycle_rental.payment_simulator_record WHERE payment_reference = '$REF5'")" 1
check "C5 final status" "$(q "SELECT status FROM bicycle_rental.payment WHERE payment_reference = '$REF5'")" successful

echo "V016: all payment concurrency tests passed (N=$N)"

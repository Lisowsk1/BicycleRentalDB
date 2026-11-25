#!/usr/bin/env bash
# Two separate sessions race to open an active maintenance job for one bicycle.
# Run only against a disposable database; the script commits its fixtures.
#
# Usage:
#   PSQL_CMD="docker compose exec -T db psql --username bicycle --dbname bicycle_rental" \
#     bash db/tests/maintenance_job_concurrency.sh
set -euo pipefail

PSQL=${PSQL_CMD:-psql}
KEY=${BARRIER_KEY:-48214}
TMP=$(mktemp -d)
trap 'rm -f "$TMP/raw.1" "$TMP/raw.2" "$TMP/result.1" "$TMP/result.2"; rmdir "$TMP"' EXIT

q() {
    printf '%s\n' "$1" | $PSQL -X -At -q -v ON_ERROR_STOP=1 2>&1 | tr -d '\r'
}

# Each psql worker queues behind an advisory-lock barrier, then runs the same
# operation at once. A PL/pgSQL exception block emits one explicit result marker
# for each request instead of inferring the outcome from psql's last-error state.
race_job_open() {
    printf 'SELECT pg_advisory_lock(7, %s);\nSELECT pg_sleep(60);\n' "$KEY" \
        | $PSQL -X -At -q >/dev/null 2>&1 &
    local holder=$!
    for _ in $(seq 200); do
        [ "$(q "SELECT count(*) FROM pg_locks WHERE locktype='advisory' AND classid=7 AND objid=$KEY AND granted")" = 1 ] && break
        sleep 0.05
    done

    local -a pids=()
    local i=0
    for _ in 1 2; do
        i=$((i + 1))
        (
            if ! printf "SELECT pg_advisory_lock_shared(7, %s);\nDO \$job_race\$\nBEGIN\n    PERFORM bicycle_rental.open_maintenance_job(%s, %s, NULL, %s);\n    RAISE NOTICE 'JOB_OPEN_RESULT|success';\nEXCEPTION WHEN SQLSTATE '55000' THEN\n    RAISE NOTICE 'JOB_OPEN_RESULT|conflict';\nEND\n\$job_race\$;\n" \
                "$KEY" "$STAFF" "$BIKE" "$STAFF" |
                $PSQL -X -q -v ON_ERROR_STOP=1 > "$TMP/raw.$i" 2>&1; then
                printf 'ERROR\n' > "$TMP/result.$i"
            elif grep -Fq 'JOB_OPEN_RESULT|success' "$TMP/raw.$i"; then
                printf 'SUCCESS\n' > "$TMP/result.$i"
            elif grep -Fq 'JOB_OPEN_RESULT|conflict' "$TMP/raw.$i"; then
                printf 'CONFLICT\n' > "$TMP/result.$i"
            else
                printf 'ERROR\n' > "$TMP/result.$i"
            fi
        ) &
        pids+=("$!")
    done

    for _ in $(seq 200); do
        [ "$(q "SELECT count(*) FROM pg_locks WHERE locktype='advisory' AND classid=7 AND objid=$KEY AND NOT granted")" -ge 2 ] && break
        sleep 0.05
    done
    q "SELECT pg_terminate_backend(pid) FROM pg_locks WHERE locktype='advisory' AND classid=7 AND objid=$KEY AND granted AND mode='ExclusiveLock'" >/dev/null
    wait "${pids[@]}"
    wait "$holder" 2>/dev/null || true
}

PASS=0
FAIL=0
check() {
    if [ "$1" = "$2" ]; then
        PASS=$((PASS + 1))
        printf 'PASS  %s\n' "$3"
    else
        FAIL=$((FAIL + 1))
        printf 'FAIL  %s (expected %s, got %s)\n' "$3" "$2" "$1"
    fi
}

STAFF=$(q "
WITH account_row AS (
    INSERT INTO bicycle_rental.account(first_name,last_name,email,password_hash,role)
    VALUES ('Concurrency','Staff','job-race-'||gen_random_uuid()||'@test.invalid',
            '\$2a\$12\$'||repeat('x',53),'staff')
    RETURNING account_id
)
INSERT INTO bicycle_rental.staff(account_id)
SELECT account_id FROM account_row
RETURNING account_id;")
if [ -z "$STAFF" ]; then
    printf 'Could not create staff fixture; verify the database is migrated and reachable.\n' >&2
    exit 2
fi

STATION=$(q "SELECT bicycle_rental.create_station($STAFF, 'job-race-'||gen_random_uuid(), 'Concurrency test', 52, 21, true, true)")
BIKE=$(q "SELECT bicycle_rental.create_bicycle($STAFF, 'job-race-'||gen_random_uuid(), 'regular', 'serviceable', $STATION)")
if [ -z "$STATION" ] || [ -z "$BIKE" ]; then
    printf 'Could not create station/bicycle fixtures.\n' >&2
    exit 2
fi

race_job_open
check "$(awk '$0 == "SUCCESS" { n++ } END { print n+0 }' "$TMP/result.1" "$TMP/result.2")" \
    1 'exactly one competing job opening succeeds'
check "$(awk '$0 == "CONFLICT" { n++ } END { print n+0 }' "$TMP/result.1" "$TMP/result.2")" \
    1 'losing request is rejected as an active-job business conflict'
check "$(awk '$0 == "ERROR" { n++ } END { print n+0 }' "$TMP/result.1" "$TMP/result.2")" \
    0 'both concurrent requests returned a classified result'
check "$(q "SELECT count(*) FROM bicycle_rental.maintenance_job WHERE bicycle_id=$BIKE AND status IN ('open','in_progress')")" \
    1 'at most one active maintenance job is persisted'
check "$(q "SELECT count(*) FROM bicycle_rental.audit_entry WHERE primary_record_type='MaintenanceJob' AND primary_record_id=(SELECT job_id FROM bicycle_rental.maintenance_job WHERE bicycle_id=$BIKE) AND action_type='maintenance_job_open' AND operation_type='maintenance_job_open'")" \
    1 'the winning job and its accurate audit event commit together'

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

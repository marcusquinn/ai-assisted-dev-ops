#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SCRIPTS_DIR="${SCRIPT_DIR}/.."
HELPER="${SCRIPTS_DIR}/screen-time-helper.sh"
TMPDIR_TEST=""

cleanup() {
	if [[ -n "$TMPDIR_TEST" ]]; then
		rm -rf "$TMPDIR_TEST"
	fi
	return 0
}

fail() {
	local message="$1"
	printf 'FAIL: %s\n' "$message" >&2
	return 1
}

pass() {
	local message="$1"
	printf 'PASS: %s\n' "$message"
	return 0
}

core_data_offset() {
	local epoch="$1"
	printf '%s\n' "$((epoch - 978307200))"
	return 0
}

local_day_epoch() {
	local now="$1"
	local days_ago="$2"
	local hour="$3"
	python3 -c 'import datetime as d,sys; day=d.datetime.fromtimestamp(int(sys.argv[1])).date()-d.timedelta(days=int(sys.argv[2])); print(int(d.datetime.combine(day,d.time(int(sys.argv[3]))).timestamp()))' "$now" "$days_ago" "$hour"
	return 0
}

insert_backlit_pair() {
	local db="$1"
	local on_epoch="$2"
	local off_epoch="$3"
	sqlite3 "$db" "
		INSERT INTO ZOBJECT (ZSTREAMNAME, ZCREATIONDATE, ZVALUEINTEGER) VALUES ('/display/isBacklit', $(core_data_offset "$on_epoch"), 1);
		INSERT INTO ZOBJECT (ZSTREAMNAME, ZCREATIONDATE, ZVALUEINTEGER) VALUES ('/display/isBacklit', $(core_data_offset "$off_epoch"), 0);"
	return 0
}

insert_app_usage() {
	local db="$1"
	local start_epoch="$2"
	local end_epoch="$3"
	sqlite3 "$db" "
		INSERT INTO ZOBJECT (ZSTREAMNAME, ZSTARTDATE, ZENDDATE) VALUES ('/app/usage', $(core_data_offset "$start_epoch"), $(core_data_offset "$end_epoch"));"
	return 0
}

query_hours() {
	local db="$1"
	local days="$2"
	AIDEVOPS_SCREEN_TIME_OS_TYPE=Darwin AIDEVOPS_KNOWLEDGE_DB="$db" "$HELPER" query "$days" | awk '{print $1}' | tr -d 'h'
	return 0
}

profile_stats() {
	local db="$1"
	AIDEVOPS_SCREEN_TIME_OS_TYPE=Darwin AIDEVOPS_KNOWLEDGE_DB="$db" "$HELPER" profile-stats
	return 0
}

create_knowledge_db() {
	local db="$1"
	sqlite3 "$db" "
		CREATE TABLE ZOBJECT (
			ZSTREAMNAME TEXT,
			ZCREATIONDATE REAL,
			ZVALUEINTEGER INTEGER,
			ZSTARTDATE REAL,
			ZENDDATE REAL,
			ZVALUESTRING TEXT
		);"
	return 0
}

test_union_clipping_and_failure_status() {
	local tmpdir="$1"
	local now="$2"
	local one_hour=3600
	local overlap_db="${tmpdir}/overlap.db"
	create_knowledge_db "$overlap_db"

	# Force app fallback with overlapping/repeated intervals. The union is 5h,
	# not the additive 9h. Use a 48h query so yesterday noon remains in the
	# rolling window regardless of the local time when this test runs.
	local previous_noon
	previous_noon=$(local_day_epoch "$now" 1 12)
	insert_app_usage "$overlap_db" "$previous_noon" "$((previous_noon + one_hour * 5))"
	insert_app_usage "$overlap_db" "$((previous_noon + one_hour))" "$((previous_noon + one_hour * 4))"
	insert_app_usage "$overlap_db" "$previous_noon" "$((previous_noon + one_hour * 5))"
	local overlap_hours
	overlap_hours=$(query_hours "$overlap_db" 2)
	[[ "$overlap_hours" == "5.0" ]] || fail "expected app intervals to union to 5.0h, got ${overlap_hours}"
	sqlite3 "$overlap_db" "UPDATE ZOBJECT SET ZVALUESTRING='app.one' WHERE ZSTREAMNAME='/app/usage';"
	local app_json app_seconds
	app_json=$(AIDEVOPS_SCREEN_TIME_NOW_EPOCH="$now" python3 "${SCRIPTS_DIR}/screen-time-interval-engine.py" apps --os-type Darwin --db "$overlap_db")
	app_seconds=$(printf '%s' "$app_json" | jq -r '.[0].month_seconds')
	[[ "$app_seconds" == "18000" ]] || fail "expected repeated/overlapping top-app intervals to union to 18000s, got ${app_seconds}"

	local clip_db="${tmpdir}/clip.db"
	create_knowledge_db "$clip_db"
	insert_app_usage "$clip_db" "$((now - one_hour * 30))" "$now"
	local clipped_hours
	clipped_hours=$(query_hours "$clip_db" 1)
	[[ "$clipped_hours" == "24.0" ]] || fail "expected one-day result capped by clipping at 24.0h, got ${clipped_hours}"

	local repeated_db="${tmpdir}/repeated.db"
	create_knowledge_db "$repeated_db"
	sqlite3 "$repeated_db" "
		INSERT INTO ZOBJECT VALUES('/display/isBacklit', $(core_data_offset "$((now - one_hour * 3))"), 1, NULL, NULL, NULL);
		INSERT INTO ZOBJECT VALUES('/display/isBacklit', $(core_data_offset "$((now - one_hour * 2))"), 1, NULL, NULL, NULL);
		INSERT INTO ZOBJECT VALUES('/display/isBacklit', $(core_data_offset "$((now - one_hour))"), 0, NULL, NULL, NULL);"
	local repeated_hours
	repeated_hours=$(query_hours "$repeated_db" 1)
	[[ "$repeated_hours" == "2.0" ]] || fail "expected repeated ON events not to double count, got ${repeated_hours}"

	local invalid_db="${tmpdir}/invalid.db"
	printf '%s\n' 'not sqlite' >"$invalid_db"
	local failure_json
	mkdir -p "${tmpdir}/failure-home"
	failure_json=$(HOME="${tmpdir}/failure-home" profile_stats "$invalid_db")
	[[ "$(printf '%s' "$failure_json" | jq -r '.collection_status')" == "unavailable" ]] || fail "database access failure was not surfaced"
	[[ "$(printf '%s' "$failure_json" | jq -r '.today_hours')" == "null" ]] || fail "database failure was rendered as a zero"
	pass "macOS intervals union, clip, deduplicate, and surface access failures"
	return 0
}

test_empty_zero_and_sparse_source_semantics() {
	local tmpdir="$1"
	local now="$2"
	local empty_db="${tmpdir}/empty.db"
	create_knowledge_db "$empty_db"
	local empty_json
	empty_json=$(AIDEVOPS_SCREEN_TIME_NOW_EPOCH="$now" profile_stats "$empty_db")
	[[ "$(printf '%s' "$empty_json" | jq -r '.collection_status')" == "unavailable" ]] || fail "readable empty macOS DB was not unavailable"
	local fallback_home="${tmpdir}/empty-fallback-home"
	mkdir -p "${fallback_home}/.aidevops/.agent-workspace/observability"
	python3 - "${fallback_home}/.aidevops/.agent-workspace/observability/screen-time.jsonl" "$now" <<'PY'
import datetime as dt
import json
import sys
date = dt.datetime.fromtimestamp(int(sys.argv[2])).date() - dt.timedelta(days=1)
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    handle.write(json.dumps({"date": str(date), "screen_hours": 2}) + "\n")
PY
	local empty_fallback
	empty_fallback=$(HOME="$fallback_home" AIDEVOPS_SCREEN_TIME_NOW_EPOCH="$now" AIDEVOPS_SCREEN_TIME_OS_TYPE=Darwin AIDEVOPS_KNOWLEDGE_DB="$empty_db" "$HELPER" profile-stats)
	[[ "$(printf '%s' "$empty_fallback" | jq -r '.today_hours')" == "2" || "$(printf '%s' "$empty_fallback" | jq -r '.today_hours')" == "2.0" ]] || fail "empty readable macOS source did not fall back to history: ${empty_fallback}"
	[[ "$(printf '%s' "$empty_fallback" | jq -r '.periods.day.source')" == "screen-time-history:daily-observations" ]] || fail "empty-source history provenance missing"

	local zero_db="${tmpdir}/observed-zero.db"
	create_knowledge_db "$zero_db"
	sqlite3 "$zero_db" "INSERT INTO ZOBJECT (ZSTREAMNAME,ZCREATIONDATE,ZVALUEINTEGER) VALUES('/display/isBacklit',$(core_data_offset "$((now - 3600))"),0);"
	local zero_json
	zero_json=$(AIDEVOPS_SCREEN_TIME_NOW_EPOCH="$now" profile_stats "$zero_db")
	[[ "$(printf '%s' "$zero_json" | jq -r '.today_hours')" == "0" || "$(printf '%s' "$zero_json" | jq -r '.today_hours')" == "0.0" ]] || fail "explicit OFF observation was not preserved as legitimate zero: ${zero_json}"
	[[ "$(printf '%s' "$zero_json" | jq -r '.periods.day.status')" == "ok" ]] || fail "explicit zero observation was marked unavailable"

	local sparse_db="${tmpdir}/relative-sparse.db"
	create_knowledge_db "$sparse_db"
	insert_backlit_pair "$sparse_db" "$((now - 2 * 86400))" "$((now - 2 * 86400 + 3600))"
	insert_backlit_pair "$sparse_db" "$((now - 3600))" "$now"
	local day
	for day in 1 2 3 4 5 6 7 8; do
		insert_app_usage "$sparse_db" "$((now - day * 86400))" "$((now - day * 86400 + 4 * 3600))"
	done
	local sparse_json
	mkdir -p "${tmpdir}/sparse-home"
	sparse_json=$(HOME="${tmpdir}/sparse-home" AIDEVOPS_SCREEN_TIME_NOW_EPOCH="$now" profile_stats "$sparse_db")
	[[ "$(printf '%s' "$sparse_json" | jq -r '.periods.month.source')" == "macos-knowledge-db:/app/usage-union" ]] || fail "two sparse backlit days incorrectly beat eight app-usage days"
	[[ "$(printf '%s' "$sparse_json" | jq -r '.month_hours')" == "32" || "$(printf '%s' "$sparse_json" | jq -r '.month_hours')" == "32.0" ]] || fail "relative app coverage duration was not selected"
	pass "empty sources, explicit zero, and relative sparse-source selection are distinct"
	return 0
}

test_snapshot_omits_unobserved_stale_dates() {
	local tmpdir="$1"
	local fixture_home="${tmpdir}/snapshot-home"
	local db="${tmpdir}/snapshot-evidence.db"
	mkdir -p "$fixture_home"
	create_knowledge_db "$db"
	local fixture_values observed_date zero_date observed_start observed_end zero_event
	fixture_values=$(python3 -c 'import datetime as d; today=d.date.today(); observed=today-d.timedelta(days=5); zero=today-d.timedelta(days=4); epoch=lambda day,h:int(d.datetime.combine(day,d.time(h)).timestamp()); print(observed,zero,epoch(observed,10),epoch(observed,11),epoch(zero,12))')
	read -r observed_date zero_date observed_start observed_end zero_event <<<"$fixture_values"
	insert_backlit_pair "$db" "$observed_start" "$observed_end"
	sqlite3 "$db" "INSERT INTO ZOBJECT (ZSTREAMNAME,ZCREATIONDATE,ZVALUEINTEGER) VALUES('/display/isBacklit',$(core_data_offset "$zero_event"),0);"
	HOME="$fixture_home" AIDEVOPS_SCREEN_TIME_OS_TYPE=Darwin AIDEVOPS_KNOWLEDGE_DB="$db" "$HELPER" snapshot >/dev/null
	local history="${fixture_home}/.aidevops/.agent-workspace/observability/screen-time.jsonl"
	local rows dates zero_hours
	rows=$(wc -l <"$history" | tr -d ' ')
	dates=$(jq -r '.date' "$history" | sort | tr '\n' ' ')
	zero_hours=$(jq -r --arg date "$zero_date" 'select(.date == $date) | .screen_hours' "$history")
	if [[ "$rows" != "2" || "$dates" != "${observed_date} ${zero_date} " || ("$zero_hours" != "0" && "$zero_hours" != "0.0") ]]; then
		fail "snapshot fabricated stale gap coverage or lost explicit zero: rows=${rows} dates=${dates} zero=${zero_hours}"
	fi
	pass "snapshot omits unobserved stale dates and records explicit zero-event dates"
	return 0
}

test_top_apps_sql_and_sweep_are_bounded() {
	local tmpdir="$1"
	local now="$2"
	local db="${tmpdir}/bounded-apps.db"
	local instrument="${tmpdir}/bounded-apps-instrument.json"
	create_knowledge_db "$db"
	local cd_now=$((now - 978307200))
	sqlite3 "$db" "
		WITH RECURSIVE old_rows(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM old_rows WHERE i < 5000)
		INSERT INTO ZOBJECT (ZSTREAMNAME,ZSTARTDATE,ZENDDATE,ZVALUESTRING)
		SELECT '/app/usage', ${cd_now} - 86400*60 - i*60, ${cd_now} - 86400*60 - i*60 + 30, 'old.app' FROM old_rows;
		WITH RECURSIVE recent_rows(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM recent_rows WHERE i < 200)
		INSERT INTO ZOBJECT (ZSTREAMNAME,ZSTARTDATE,ZENDDATE,ZVALUESTRING)
		SELECT '/app/usage', ${cd_now} - 86400 - i*300, ${cd_now} - 86400 - i*300 + 600, 'recent.' || (i % 3) FROM recent_rows;"
	AIDEVOPS_SCREEN_TIME_NOW_EPOCH="$now" AIDEVOPS_APP_STATS_INSTRUMENT_FILE="$instrument" \
		python3 "${SCRIPTS_DIR}/screen-time-interval-engine.py" apps --os-type Darwin --db "$db" >/dev/null
	local selected valid boundaries segments elapsed
	selected=$(jq -r '.rows_selected' "$instrument")
	valid=$(jq -r '.valid_intervals' "$instrument")
	boundaries=$(jq -r '.boundaries' "$instrument")
	segments=$(jq -r '.attributed_segments' "$instrument")
	elapsed=$(jq -r '.elapsed_ms' "$instrument")
	if [[ "$selected" -lt 1 || "$selected" -gt 200 || "$valid" != "$selected" || "$boundaries" -gt 402 || "$segments" -gt 401 ]] ||
		! awk -v elapsed="$elapsed" 'BEGIN {exit !(elapsed < 5000)}'; then
		fail "top-app query/sweep was unbounded: $(<"$instrument")"
	fi
	pass "top-app SQL excludes 5000 old rows and sweep remains boundary-linear"
	return 0
}

test_local_midnight_dst_boundaries() {
	local tmpdir="$1"
	local db="${tmpdir}/dst.db"
	create_knowledge_db "$db"
	local bounds
	bounds=$(TZ=America/New_York python3 -c 'import datetime as d,time; time.tzset(); dates=(d.date(2026,3,8),d.date(2026,11,1)); print(" ".join(str(int(d.datetime.combine(x,d.time.min).timestamp()))+" "+str(int(d.datetime.combine(x+d.timedelta(days=1),d.time.min).timestamp())) for x in dates))')
	local spring_start spring_end fall_start fall_end
	read -r spring_start spring_end fall_start fall_end <<<"$bounds"
	insert_app_usage "$db" "$spring_start" "$spring_end"
	insert_app_usage "$db" "$fall_start" "$fall_end"
	local spring_hours fall_hours
	spring_hours=$(TZ=America/New_York AIDEVOPS_SCREEN_TIME_NOW_EPOCH="$((fall_end + 3600))" python3 "${SCRIPTS_DIR}/screen-time-interval-engine.py" date --date 2026-03-08 --os-type Darwin --db "$db")
	fall_hours=$(TZ=America/New_York AIDEVOPS_SCREEN_TIME_NOW_EPOCH="$((fall_end + 3600))" python3 "${SCRIPTS_DIR}/screen-time-interval-engine.py" date --date 2026-11-01 --os-type Darwin --db "$db")
	[[ "$((spring_end - spring_start))" == "82800" && "$spring_hours" == "23.0" ]] || fail "spring DST local day was not bounded by consecutive midnights"
	[[ "$((fall_end - fall_start))" == "90000" && "$fall_hours" == "24.0" ]] || fail "fall DST local day was not bounded then capped at 24h"
	pass "date collection uses host-local consecutive-midnight DST boundaries"
	return 0
}

test_profile_completed_day_dst_semantics() {
	local tmpdir="$1"
	local db="${tmpdir}/profile-dst.db"
	create_knowledge_db "$db"
	local values spring_start spring_end spring_now fall_start fall_end fall_now
	values=$(TZ=America/New_York python3 -c 'import datetime as d,time; time.tzset(); epoch=lambda x:int(x.timestamp()); s=d.date(2026,3,8); f=d.date(2026,11,1); print(epoch(d.datetime.combine(s,d.time.min)),epoch(d.datetime.combine(s+d.timedelta(days=1),d.time.min)),epoch(d.datetime(2026,3,9,12)),epoch(d.datetime.combine(f,d.time.min)),epoch(d.datetime.combine(f+d.timedelta(days=1),d.time.min)),epoch(d.datetime(2026,11,2,12)))')
	read -r spring_start spring_end spring_now fall_start fall_end fall_now <<<"$values"
	insert_app_usage "$db" "$spring_start" "$spring_end"
	insert_app_usage "$db" "$fall_start" "$fall_end"
	local spring_json fall_json
	spring_json=$(TZ=America/New_York AIDEVOPS_SCREEN_TIME_NOW_EPOCH="$spring_now" profile_stats "$db")
	fall_json=$(TZ=America/New_York AIDEVOPS_SCREEN_TIME_NOW_EPOCH="$fall_now" profile_stats "$db")
	[[ "$(printf '%s' "$spring_json" | jq -r '.today_hours')" == "23" || "$(printf '%s' "$spring_json" | jq -r '.today_hours')" == "23.0" ]] || fail "spring profile day was not the completed 23-hour local day"
	[[ "$(printf '%s' "$fall_json" | jq -r '.today_hours')" == "25" || "$(printf '%s' "$fall_json" | jq -r '.today_hours')" == "25.0" ]] || fail "fall profile day was not the completed 25-hour local day"
	[[ "$(printf '%s' "$spring_json" | jq -r '.periods.day.period_semantics')" == "completed-local-calendar-days" ]] || fail "screen profile omitted completed-day semantics"
	[[ "$(printf '%s' "$spring_json" | jq -r '.periods.day.period_start_epoch | floor')" == "$spring_start" && "$(printf '%s' "$spring_json" | jq -r '.periods.day.period_end_epoch | floor')" == "$spring_end" ]] || fail "screen profile exposed incorrect completed-day bounds"
	pass "profile screen periods use completed local days across DST"
	return 0
}

test_pmset_permission_free_fallback() {
	local tmpdir="$1"
	local now db fixture yesterday_start
	now=$(python3 -c 'import datetime as d; print(int(d.datetime(2026,7,12,12).astimezone().timestamp()))')
	yesterday_start=$(local_day_epoch "$now" 1 0)
	db="${tmpdir}/unreadable-knowledge.db"
	fixture="${tmpdir}/pmset.log"
	printf '%s\n' 'not sqlite' >"$db"
	python3 - "$fixture" "$yesterday_start" <<'PY'
import datetime as dt
import sys

target, start = sys.argv[1], int(sys.argv[2])
def display_row(offset, state):
    stamp = dt.datetime.fromtimestamp(start + offset).astimezone().strftime("%Y-%m-%d %H:%M:%S %z")
    return f"{stamp} Notification         Display is turned {state}"
def assertion_row(offset, duration):
    stamp = dt.datetime.fromtimestamp(start + offset).astimezone().strftime("%Y-%m-%d %H:%M:%S %z")
    return f'{stamp} Assertions PID 592(powerd) Released PreventUserIdleSystemSleep "Powerd - Prevent sleep while display is on" {duration}  id:0x1'
with open(target, "w", encoding="utf-8") as handle:
    # This unmatched state event previously remained open across the overnight
    # gap and inflated the completed day. Assertion durations are authoritative.
    handle.write(display_row(-2 * 3600, "on") + "\n")
    handle.write("malformed Display is turned on\n")
    handle.write(assertion_row(12 * 3600, "04:00:00") + "\n")
    handle.write(assertion_row(15 * 3600, "02:00:00") + "\n")
PY
	local fixture_home="${tmpdir}/pmset-home"
	mkdir -p "${fixture_home}/.aidevops/.agent-workspace/observability"
	python3 - "${fixture_home}/.aidevops/.agent-workspace/observability/screen-time.jsonl" "$now" <<'PY'
import datetime as dt
import json
import sys

today = dt.datetime.fromtimestamp(int(sys.argv[2])).date()
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    for age in range(2, 30):
        handle.write(json.dumps({"date": str(today - dt.timedelta(days=age)), "screen_hours": 1}) + "\n")
PY
	local output
	output=$(HOME="$fixture_home" AIDEVOPS_PMSET_FIXTURE="$fixture" AIDEVOPS_SCREEN_TIME_NOW_EPOCH="$now" profile_stats "$db")
	[[ "$(printf '%s' "$output" | jq -r '.today_hours')" == "6" || "$(printf '%s' "$output" | jq -r '.today_hours')" == "6.0" ]] || fail "pmset fallback did not union completed-day display intervals"
	[[ "$(printf '%s' "$output" | jq -r '.periods.day.source')" == "macos-pmset-display-assertions" ]] || fail "pmset fallback provenance missing"
	[[ "$(printf '%s' "$output" | jq -r '.periods.day.period_semantics')" == "completed-local-calendar-days" ]] || fail "pmset fallback changed profile period semantics"
	[[ "$(printf '%s' "$output" | jq -r '.periods.month.source')" == "screen-time-history:daily-observations" ]] || fail "short pmset coverage displaced richer month history"
	[[ "$(printf '%s' "$output" | jq -r '.periods.month.reason')" == "richer-calendar-coverage" ]] || fail "richer history selection reason missing"
	pass "permission-free pmset fallback supplies completed-day screen time"
	return 0
}

test_linux_state_machine() {
	local tmpdir="$1"
	local now
	now=$(python3 -c 'import datetime as d; print(int(d.datetime(2033,5,19,12).timestamp()))')
	local fixture="${tmpdir}/logind.txt"
	python3 - "$fixture" "$now" <<'PY'
import datetime as dt
import sys

target = sys.argv[1]
now = int(sys.argv[2])
events = [
    (-30, "New session c1 of user fixture."),
    (-29, "Session c1 locked."),
    (-28, "Session c1 unlocked."),
    (-27, "Lid closed."),
    (-26, "Lid opened."),
    (-25, "Removed session c1."),
]
with open(target, "w", encoding="utf-8") as handle:
    for hours, message in events:
        stamp = dt.datetime.fromtimestamp(now + hours * 3600, dt.timezone.utc).isoformat()
        handle.write(f"{stamp} host systemd-logind[1]: {message}\n")
PY
	local output hours source
	output=$(AIDEVOPS_SCREEN_TIME_OS_TYPE=Linux AIDEVOPS_LOGIND_FIXTURE="$fixture" \
		AIDEVOPS_SCREEN_TIME_NOW_EPOCH="$now" AIDEVOPS_SCREEN_TIME_USER=fixture "$HELPER" profile-stats)
	hours=$(printf '%s' "$output" | jq -r '.today_hours')
	source=$(printf '%s' "$output" | jq -r '.periods.day.source')
	[[ "$hours" == "3" || "$hours" == "3.0" ]] || fail "expected lock/lid/session state to produce 3.0h, got ${hours}"
	[[ "$source" == *"session-lid-lock-state"* ]] || fail "Linux provenance missing state semantics: ${source}"
	pass "Linux state retains username-less session OFF events and clips active windows"
	local zero_fixture="${tmpdir}/logind-zero.txt"
	python3 - "$zero_fixture" "$now" <<'PY'
import datetime as dt
import sys
stamp = dt.datetime.fromtimestamp(int(sys.argv[2]) - 30 * 3600, dt.timezone.utc).isoformat()
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    handle.write(f"{stamp} host systemd-logind[1]: New session z1 of user fixture.\n")
    handle.write(f"{stamp} host systemd-logind[1]: Removed session z1.\n")
PY
	local zero_output
	zero_output=$(AIDEVOPS_SCREEN_TIME_OS_TYPE=Linux AIDEVOPS_LOGIND_FIXTURE="$zero_fixture" \
		AIDEVOPS_SCREEN_TIME_NOW_EPOCH="$now" AIDEVOPS_SCREEN_TIME_USER=fixture "$HELPER" profile-stats)
	[[ "$(printf '%s' "$zero_output" | jq -r '.today_hours')" == "0" || "$(printf '%s' "$zero_output" | jq -r '.today_hours')" == "0.0" ]] || fail "explicit zero-duration logind events were not preserved"
	[[ "$(printf '%s' "$zero_output" | jq -r '.periods.day.status')" == "ok" ]] || fail "explicit logind zero was treated as source failure"

	local missing_journal="${tmpdir}/missing-journal"
	local wtmp_fixture="${tmpdir}/wtmp.txt"
	printf '%s|%s\n' "$((now - 30 * 3600))" "$((now - 29 * 3600))" >"$wtmp_fixture"
	local fallback
	fallback=$(AIDEVOPS_SCREEN_TIME_OS_TYPE=Linux AIDEVOPS_LOGIND_FIXTURE="$missing_journal" \
		AIDEVOPS_LAST_FIXTURE="$wtmp_fixture" AIDEVOPS_SCREEN_TIME_NOW_EPOCH="$now" \
		AIDEVOPS_SCREEN_TIME_USER=fixture "$HELPER" profile-stats)
	[[ "$(printf '%s' "$fallback" | jq -r '.today_hours')" == "1" || "$(printf '%s' "$fallback" | jq -r '.today_hours')" == "1.0" ]] || fail "wtmp fallback hours were not parsed"
	[[ "$(printf '%s' "$fallback" | jq -r '.periods.day.source')" == "linux-wtmp:login-session-proxy" ]] || fail "wtmp fallback provenance was not truthful"
	pass "Linux collection failure falls back to clipped wtmp sessions with proxy provenance"

	local empty_journal="${tmpdir}/empty-logind.txt"
	local realistic_last="${tmpdir}/last-F.txt"
	: >"$empty_journal"
	cat >"$realistic_last" <<'EOF'
fixture  pts/0  host  Wed May 18 01:00:00 2033 - Wed May 18 02:00:00 2033  (01:00)
fixture  pts/1  host  Wed May 18 03:00:00 2033   still logged in
EOF
	local empty_fallback
	empty_fallback=$(TZ=UTC AIDEVOPS_SCREEN_TIME_OS_TYPE=Linux AIDEVOPS_LOGIND_FIXTURE="$empty_journal" \
		AIDEVOPS_LAST_FIXTURE="$realistic_last" AIDEVOPS_SCREEN_TIME_NOW_EPOCH="$now" \
		AIDEVOPS_SCREEN_TIME_USER=fixture "$HELPER" profile-stats)
	[[ "$(printf '%s' "$empty_fallback" | jq -r '.today_hours')" == "22" || "$(printf '%s' "$empty_fallback" | jq -r '.today_hours')" == "22.0" ]] || fail "real last -F completed+active records were not clipped to the completed day"
	[[ "$(printf '%s' "$empty_fallback" | jq -r '.periods.day.reason')" == *"journal-readable-no-user-observations"* ]] || fail "empty readable logind did not truthfully fall back"
	pass "empty logind falls back and parses realistic local last -F records"
	return 0
}

test_history_calendar_coverage_and_staleness() {
	local tmpdir="$1"
	local fixture_home="${tmpdir}/history-home"
	mkdir -p "${fixture_home}/.aidevops/.agent-workspace/observability"
	local history="${fixture_home}/.aidevops/.agent-workspace/observability/screen-time.jsonl"
	python3 - "$history" <<'PY'
import datetime as dt
import json
import sys

today = dt.datetime.now(dt.timezone.utc).date()
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    for age, hours in ((20, 30), (10, 12), (5, 6)):
        handle.write(json.dumps({"date": str(today - dt.timedelta(days=age)), "screen_hours": hours}) + "\n")
    handle.write("not-json\n")
    handle.write(json.dumps({"date": "bad-date", "screen_hours": 5}) + "\n")
    handle.write(json.dumps({"date": str(today - dt.timedelta(days=4)), "screen_hours": "broken"}) + "\n")
PY
	local output estimate span status skipped
	output=$(HOME="$fixture_home" AIDEVOPS_SCREEN_TIME_OS_TYPE=Unsupported "$HELPER" profile-stats)
	estimate=$(printf '%s' "$output" | jq -r '.year_hours')
	span=$(printf '%s' "$output" | jq -r '.periods.year.calendar_span_days')
	status=$(printf '%s' "$output" | jq -r '.periods.year.status')
	skipped=$(printf '%s' "$output" | jq -r '.history_skipped_rows')
	[[ "$span" == "16" ]] || fail "expected calendar span 16 rather than active row count 3, got ${span}"
	[[ "$estimate" == "958.1" ]] || fail "expected clamped 24h rows and calendar-span estimate 958.1h, got ${estimate}"
	[[ "$status" == "stale" ]] || fail "expected stale history estimate to remain visibly stale"
	[[ "$skipped" == "3" ]] || fail "expected three malformed history rows to be skipped individually, got ${skipped}"
	pass "history skips malformed rows individually and reports provenance"
	return 0
}

test_corrupt_core_data_and_history_paths_are_safe() {
	local tmpdir="$1"
	local now="$2"
	local db="${tmpdir}/corrupt-core-data.db"
	create_knowledge_db "$db"
	local previous_noon
	previous_noon=$(local_day_epoch "$now" 1 12)
	insert_app_usage "$db" "$previous_noon" "$((previous_noon + 3600))"
	sqlite3 "$db" "
		UPDATE ZOBJECT SET ZVALUESTRING='valid.app' WHERE ZSTREAMNAME='/app/usage';
		INSERT INTO ZOBJECT (ZSTREAMNAME,ZCREATIONDATE,ZVALUEINTEGER) VALUES('/display/isBacklit','broken',1);
		INSERT INTO ZOBJECT (ZSTREAMNAME,ZCREATIONDATE,ZVALUEINTEGER) VALUES('/display/isBacklit',1e999,1);
		INSERT INTO ZOBJECT (ZSTREAMNAME,ZSTARTDATE,ZENDDATE,ZVALUESTRING) VALUES('/app/usage','broken','also-broken','bad.app');
		INSERT INTO ZOBJECT (ZSTREAMNAME,ZSTARTDATE,ZENDDATE,ZVALUESTRING) VALUES('/app/usage',1e999,1e999,'infinite.app');"
	local profile_json app_json
	mkdir -p "${tmpdir}/corrupt-home"
	profile_json=$(HOME="${tmpdir}/corrupt-home" AIDEVOPS_SCREEN_TIME_NOW_EPOCH="$now" profile_stats "$db")
	app_json=$(AIDEVOPS_SCREEN_TIME_NOW_EPOCH="$now" python3 "${SCRIPTS_DIR}/screen-time-interval-engine.py" apps --os-type Darwin --db "$db")
	local python_ok=0
	PYTHONPATH="$SCRIPTS_DIR" python3 - <<'PY' || python_ok=1
from screen_time_interval_common import local_date, safe_core_epoch

assert local_date(10**500) is None
assert local_date("corrupt") is None
assert safe_core_epoch("corrupt") is None
assert safe_core_epoch(float("inf")) is None
PY
	local history_json
	history_json=$(python3 "${SCRIPTS_DIR}/screen-time-interval-engine.py" history-summary --os-type Unsupported --history "$tmpdir")
	if [[ "$(printf '%s' "$profile_json" | jq -r '.month_hours')" != "1" && "$(printf '%s' "$profile_json" | jq -r '.month_hours')" != "1.0" ]] ||
		[[ "$(printf '%s' "$app_json" | jq -r 'length')" != "1" ]] ||
		[[ "$(printf '%s' "$history_json" | jq -r '.valid_rows')" != "0" || "$python_ok" -ne 0 ]]; then
		fail "corrupt Core Data values or directory history path escaped defensive parsing"
	fi
	pass "corrupt Core Data values, local dates, and directory history paths are safe"
	return 0
}

test_screen_engine_sibling_modules_deploy_together() {
	local tmpdir="$1"
	local deploy_dir="${tmpdir}/deployed-screen-engine"
	mkdir -p "$deploy_dir"
	cp "${SCRIPTS_DIR}/screen-time-interval-engine.py" \
		"${SCRIPTS_DIR}/screen_time_interval_common.py" \
		"${SCRIPTS_DIR}/screen_time_macos.py" \
		"${SCRIPTS_DIR}/screen_time_macos_apps.py" \
		"${SCRIPTS_DIR}/screen_time_macos_pmset.py" \
		"${SCRIPTS_DIR}/screen_time_linux.py" \
		"${SCRIPTS_DIR}/screen_time_linux_wtmp.py" \
		"${SCRIPTS_DIR}/screen_time_linux_logind.py" \
		"${SCRIPTS_DIR}/screen_time_history.py" "$deploy_dir/"
	local output
	output=$(python3 "${deploy_dir}/screen-time-interval-engine.py" history-summary --os-type Unsupported)
	[[ "$(printf '%s' "$output" | jq -r '.valid_rows')" == "0" ]] || fail "deployed screen engine could not load sibling modules"
	pass "screen engine loads deployed sibling modules"
	return 0
}

test_leading_zero_dates_and_malformed_profile_payload_are_safe() {
	local tmpdir="$1"
	local fixture_home="${tmpdir}/leading-zero-home"
	local history="${fixture_home}/.aidevops/.agent-workspace/observability/screen-time.jsonl"
	mkdir -p "${history%/*}"
	printf '%s\n' \
		'{"date":"2026-08-08","screen_hours":1}' \
		'{"date":"2026-08-09","screen_hours":2}' >"$history"

	local now profile_json history_output
	now=$(python3 -c 'import datetime as d; print(int(d.datetime(2026, 8, 10, 12).astimezone().timestamp()))')
	profile_json=$(HOME="$fixture_home" AIDEVOPS_SCREEN_TIME_NOW_EPOCH="$now" \
		AIDEVOPS_SCREEN_TIME_OS_TYPE=Unsupported "$HELPER" profile-stats)
	history_output=$(HOME="$fixture_home" AIDEVOPS_SCREEN_TIME_OS_TYPE=Unsupported "$HELPER" history)
	if ! printf '%s' "$profile_json" | jq -e 'type == "object"' >/dev/null ||
		[[ "$(printf '%s' "$profile_json" | jq -r '.today_hours')" != "2" && "$(printf '%s' "$profile_json" | jq -r '.today_hours')" != "2.0" ]] ||
		[[ "$history_output" != *"Range: 2026-08-08 to 2026-08-09"* ]]; then
		fail "leading-zero history dates did not remain valid through profile-stats/history paths: ${profile_json} ${history_output}"
	fi

	local invalid_dir invalid_json
	invalid_dir="${tmpdir}/invalid-screen-time-helper"
	mkdir -p "$invalid_dir"
	printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\\n" not-json' >"${invalid_dir}/screen-time-helper.sh"
	chmod +x "${invalid_dir}/screen-time-helper.sh"
	invalid_json=$(SCRIPT_DIR="$invalid_dir" bash -c 'source "$1"; _get_screen_time' _ "${SCRIPTS_DIR}/profile-readme-data-lib.sh")
	[[ "$(printf '%s' "$invalid_json" | jq -r '.collection_status')" == "unavailable" ]] ||
		fail "malformed screen-time output was not converted to unavailable JSON: ${invalid_json}"
	pass "leading-zero dates and malformed screen-time output stay JSON-safe"
	return 0
}

main() {
	local tmpdir
	tmpdir=$(mktemp -d)
	TMPDIR_TEST="$tmpdir"
	trap cleanup EXIT

	local db="${tmpdir}/knowledgeC.db"
	create_knowledge_db "$db"
	: >"${tmpdir}/empty-pmset.log"
	export AIDEVOPS_PMSET_FIXTURE="${tmpdir}/empty-pmset.log"

	local now
	now=$(date +%s)
	local one_hour=3600
	local one_day=86400

	# Sparse backlit: one recent day only. App usage spans multiple active days.
	insert_backlit_pair "$db" "$((now - one_hour * 8))" "$((now - one_hour))"
	insert_app_usage "$db" "$((now - one_hour * 8))" "$((now - one_hour))"
	insert_app_usage "$db" "$((now - one_day * 2))" "$((now - one_day * 2 + one_hour * 6))"
	insert_app_usage "$db" "$((now - one_day * 4))" "$((now - one_day * 4 + one_hour * 5))"

	local day_hours
	local week_hours
	day_hours=$(query_hours "$db" 1)
	week_hours=$(query_hours "$db" 7)

	[[ "$day_hours" == "7.0" ]] || fail "expected 1d backlit hours to stay primary at 7.0, got ${day_hours}"
	[[ "$week_hours" == "18.0" ]] || fail "expected sparse 7d backlit window to fall back to app usage at 18.0, got ${week_hours}"

	# Healthy backlit: events on multiple days should remain primary even when app usage exists.
	local healthy_db="${tmpdir}/healthy-knowledgeC.db"
	create_knowledge_db "$healthy_db"
	insert_backlit_pair "$healthy_db" "$((now - one_hour * 8))" "$((now - one_hour))"
	insert_backlit_pair "$healthy_db" "$((now - one_day * 2))" "$((now - one_day * 2 + one_hour * 4))"
	insert_app_usage "$healthy_db" "$((now - one_hour * 8))" "$((now - one_hour))"
	insert_app_usage "$healthy_db" "$((now - one_day * 2))" "$((now - one_day * 2 + one_hour * 4))"

	local healthy_week_hours
	healthy_week_hours=$(query_hours "$healthy_db" 7)
	[[ "$healthy_week_hours" == "11.0" ]] || fail "expected healthy 7d backlit stream to remain primary at 11.0, got ${healthy_week_hours}"

	pass "screen-time helper falls back only for sparse backlit windows"
	test_union_clipping_and_failure_status "$tmpdir" "$now"
	test_empty_zero_and_sparse_source_semantics "$tmpdir" "$now"
	test_snapshot_omits_unobserved_stale_dates "$tmpdir"
	test_top_apps_sql_and_sweep_are_bounded "$tmpdir" "$now"
	test_local_midnight_dst_boundaries "$tmpdir"
	test_profile_completed_day_dst_semantics "$tmpdir"
	test_pmset_permission_free_fallback "$tmpdir"
	test_linux_state_machine "$tmpdir"
	test_history_calendar_coverage_and_staleness "$tmpdir"
	test_corrupt_core_data_and_history_paths_are_safe "$tmpdir" "$now"
	test_screen_engine_sibling_modules_deploy_together "$tmpdir"
	test_leading_zero_dates_and_malformed_profile_payload_are_safe "$tmpdir"
	return 0
}

main "$@"

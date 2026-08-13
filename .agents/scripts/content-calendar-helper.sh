#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# shellcheck disable=SC2034
set -euo pipefail

# Content Calendar & Posting Cadence Engine
# SQLite-backed content calendar with cadence tracking, gap analysis,
# and platform-aware scheduling recommendations.
#
# Usage: ./content-calendar-helper.sh [command] [args] [options]
# Commands:
#   add <title>                 - Add a content item to the calendar
#   list [--status STATUS]      - List calendar items (optionally filtered)
#   schedule <id> <date> <platform> - Schedule a content item
#   cadence [--platform PLAT]   - Show posting cadence analysis
#   status [id]                 - Show calendar status or item details
#   gaps [--days 30]            - Identify content gaps in the schedule
#   advance <id> <stage>        - Move item through lifecycle stages
#   due [--days 7]              - Show items due within N days
#   stats                       - Show calendar statistics
#   export [--format json|csv]  - Export calendar data
#   help                        - Show this help message
#
# Lifecycle stages: ideation -> draft -> review -> publish -> promote -> analyze
#
# Author: AI DevOps Framework
# Version: 1.0.0
# License: MIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

init_log_file

# Constants
readonly CC_DATA_DIR="${HOME}/.aidevops/.agent-workspace/work/content-calendar"
readonly CC_DB="${CC_DATA_DIR}/calendar.db"
readonly CC_STAGES="ideation draft review publish promote analyze"

# Valid platforms for scheduling
readonly CC_PLATFORMS="blog youtube shorts tiktok reels linkedin x reddit email podcast instagram"

# Cadence targets (posts per week) — evidence-based defaults from content/optimization.md
# Format: platform:min:max:optimal
readonly -a CC_CADENCE_TARGETS=(
	"blog:1:2:1"
	"youtube:2:3:2"
	"shorts:5:7:7"
	"tiktok:5:7:7"
	"reels:5:7:7"
	"linkedin:3:5:5"
	"x:7:21:14"
	"reddit:2:3:2"
	"email:0.5:1:1"
	"podcast:0.5:1:1"
	"instagram:3:5:3"
)

# Optimal posting windows (UTC) from content-calendar.md
readonly -a CC_POSTING_WINDOWS=(
	"blog:Tue-Thu:09:00-11:00"
	"youtube:Thu-Sat:14:00-16:00"
	"shorts:Mon-Fri:12:00-15:00"
	"tiktok:Mon-Fri:12:00-15:00"
	"reels:Mon,Wed,Fri:11:00-13:00"
	"linkedin:Tue-Thu:07:00-08:30"
	"x:Mon-Fri:12:00-15:00"
	"reddit:Mon-Fri:09:00-11:00"
	"email:Tue,Thu:10:00-10:00"
	"podcast:Mon,Wed:09:00-11:00"
	"instagram:Mon,Wed,Fri:11:00-13:00"
)

# =============================================================================
# Input Validation & SQL Safety
# =============================================================================

# Escape a string for safe interpolation into SQL single-quoted literals.
# Doubles single quotes per SQL standard (the only escape needed for SQLite
# string literals). Usage: escaped="$(sql_escape "$raw")"
sql_escape() {
	local raw="$1"
	printf '%s' "${raw//\'/\'\'}"
	return 0
}

# Validate that a value is a strictly numeric (positive integer) ID.
# Returns 0 if valid, 1 if not. Usage: validate_numeric_id "$id" "content_id"
validate_numeric_id() {
	local value="$1"
	local label="${2:-id}"
	if ! [[ "$value" =~ ^[0-9]+$ ]]; then
		print_error "Invalid ${label}: '${value}' — must be a positive integer"
		return 1
	fi
	return 0
}

# Validate that a value is a positive integer (for counts, days, limits, weeks).
validate_positive_int() {
	local value="$1"
	local label="${2:-value}"
	if ! [[ "$value" =~ ^[0-9]+$ ]]; then
		print_error "Invalid ${label}: '${value}' — must be a positive integer"
		return 1
	fi
	return 0
}

# Validate a real Gregorian calendar date without accepting platform-specific
# normalisation such as 2026-02-30.
validate_calendar_date() {
	local value="$1"
	python3 -c 'import datetime, sys; datetime.date.fromisoformat(sys.argv[1])' "$value" >/dev/null 2>&1 || return 1
	return 0
}

# =============================================================================
# Database Initialization
# =============================================================================

init_db() {
	mkdir -p "$CC_DATA_DIR" 2>/dev/null || true

	sqlite3 "$CC_DB" "
        CREATE TABLE IF NOT EXISTS content_items (
            id          INTEGER PRIMARY KEY AUTOINCREMENT,
            title       TEXT NOT NULL,
            pillar      TEXT DEFAULT '',
            cluster     TEXT DEFAULT '',
            stage       TEXT DEFAULT 'ideation',
            intent      TEXT DEFAULT 'informational',
            word_count  INTEGER DEFAULT 0,
            tags        TEXT DEFAULT '',
            author      TEXT DEFAULT '',
            created_at  TEXT DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
            updated_at  TEXT DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
            notes       TEXT DEFAULT ''
        );

        CREATE TABLE IF NOT EXISTS schedule (
            id              INTEGER PRIMARY KEY AUTOINCREMENT,
            content_id      INTEGER NOT NULL,
            platform        TEXT NOT NULL,
            scheduled_date  TEXT NOT NULL,
            scheduled_time  TEXT DEFAULT '',
            status          TEXT DEFAULT 'scheduled',
            published_url   TEXT DEFAULT '',
            distribution_id TEXT DEFAULT '',
            operation_id    TEXT DEFAULT '',
            operation_state TEXT DEFAULT '',
            remote_id       TEXT DEFAULT '',
            created_at      TEXT DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
            FOREIGN KEY (content_id) REFERENCES content_items(id)
        );

        CREATE TABLE IF NOT EXISTS cadence_log (
            id          INTEGER PRIMARY KEY AUTOINCREMENT,
            platform    TEXT NOT NULL,
            post_date   TEXT NOT NULL,
            content_id  INTEGER,
            metric_type TEXT DEFAULT '',
            metric_val  REAL DEFAULT 0,
            created_at  TEXT DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
            FOREIGN KEY (content_id) REFERENCES content_items(id)
        );

        CREATE INDEX IF NOT EXISTS idx_schedule_date ON schedule(scheduled_date);
        CREATE INDEX IF NOT EXISTS idx_schedule_platform ON schedule(platform);
        CREATE UNIQUE INDEX IF NOT EXISTS idx_schedule_idempotency ON schedule(content_id, platform, scheduled_date, scheduled_time);
        CREATE INDEX IF NOT EXISTS idx_content_stage ON content_items(stage);
        CREATE INDEX IF NOT EXISTS idx_cadence_platform ON cadence_log(platform, post_date);
    " 2>/dev/null || {
		print_error "Failed to initialize content calendar database"
		return 1
	}
	# Existing calendars retain their rows; new nullable bridge projection columns
	# are added independently because CREATE TABLE does not migrate old databases.
	for column in distribution_id operation_id operation_state remote_id; do
		sqlite3 "$CC_DB" "ALTER TABLE schedule ADD COLUMN ${column} TEXT DEFAULT '';" 2>/dev/null || true
	done

	return 0
}

# =============================================================================
# Commands
# =============================================================================

# Add a content item to the calendar
cmd_add() {
	local title="${1:-}"
	if [[ -z "$title" ]]; then
		print_error "Title is required. Usage: content-calendar-helper.sh add \"Title\" [--pillar X] [--cluster Y] [--intent Z] [--author A] [--tags t1,t2]"
		return 1
	fi
	shift

	local pillar="" cluster="" intent="informational" author="" tags="" notes=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--pillar)
			pillar="${2:-}"
			shift 2
			;;
		--cluster)
			cluster="${2:-}"
			shift 2
			;;
		--intent)
			intent="${2:-}"
			shift 2
			;;
		--author)
			author="${2:-}"
			shift 2
			;;
		--tags)
			tags="${2:-}"
			shift 2
			;;
		--notes)
			notes="${2:-}"
			shift 2
			;;
		*) shift ;;
		esac
	done

	init_db

	local escaped_title escaped_pillar escaped_cluster escaped_notes
	local escaped_intent escaped_author escaped_tags
	escaped_title="$(sql_escape "$title")"
	escaped_pillar="$(sql_escape "$pillar")"
	escaped_cluster="$(sql_escape "$cluster")"
	escaped_notes="$(sql_escape "$notes")"
	escaped_intent="$(sql_escape "$intent")"
	escaped_author="$(sql_escape "$author")"
	escaped_tags="$(sql_escape "$tags")"

	local new_id
	new_id=$(sqlite3 "$CC_DB" "
        INSERT INTO content_items (title, pillar, cluster, intent, author, tags, notes)
        VALUES ('${escaped_title}', '${escaped_pillar}', '${escaped_cluster}', '${escaped_intent}', '${escaped_author}', '${escaped_tags}', '${escaped_notes}');
        SELECT last_insert_rowid();
    ")

	print_success "Added content item #${new_id}: ${title}"
	echo "  Stage: ideation | Intent: ${intent}"
	[[ -n "$pillar" ]] && echo "  Pillar: ${pillar}"
	[[ -n "$cluster" ]] && echo "  Cluster: ${cluster}"

	return 0
}

# List calendar items
cmd_list() {
	local status_filter="" platform_filter="" limit="50" stage_filter=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--status)
			status_filter="${2:-}"
			shift 2
			;;
		--stage)
			stage_filter="${2:-}"
			shift 2
			;;
		--platform)
			platform_filter="${2:-}"
			shift 2
			;;
		--limit)
			limit="${2:-50}"
			shift 2
			;;
		*) shift ;;
		esac
	done

	init_db

	# Validate numeric limit
	validate_positive_int "$limit" "limit" || return 1

	# Build WHERE clause with escaped values
	local where_clause="1=1"
	if [[ -n "$stage_filter" ]]; then
		local escaped_stage
		escaped_stage="$(sql_escape "$stage_filter")"
		where_clause="${where_clause} AND c.stage = '${escaped_stage}'"
	fi
	if [[ -n "$status_filter" ]]; then
		local escaped_status
		escaped_status="$(sql_escape "$status_filter")"
		where_clause="${where_clause} AND s.status = '${escaped_status}'"
	fi

	local query
	if [[ -n "$platform_filter" ]]; then
		local escaped_platform
		escaped_platform="$(sql_escape "$platform_filter")"
		query="SELECT c.id, c.title, c.stage, c.pillar, s.platform, s.scheduled_date, s.status
               FROM content_items c
               LEFT JOIN schedule s ON c.id = s.content_id
               WHERE ${where_clause} AND s.platform = '${escaped_platform}'
               ORDER BY s.scheduled_date ASC
               LIMIT ${limit};"
	else
		query="SELECT c.id, c.title, c.stage, c.pillar,
                      COALESCE(GROUP_CONCAT(DISTINCT s.platform), '-') as platforms,
                      MIN(s.scheduled_date) as next_date
               FROM content_items c
               LEFT JOIN schedule s ON c.id = s.content_id
               WHERE ${where_clause}
               GROUP BY c.id
               ORDER BY c.updated_at DESC
               LIMIT ${limit};"
	fi

	echo ""
	echo "Content Calendar Items"
	echo "======================"
	echo ""
	printf "%-4s %-40s %-10s %-15s %-15s %-12s\n" "ID" "Title" "Stage" "Pillar" "Platforms" "Next Date"
	printf "%-4s %-40s %-10s %-15s %-15s %-12s\n" "---" "----" "-----" "------" "---------" "---------"

	sqlite3 -separator '|' "$CC_DB" "$query" | while IFS='|' read -r id title stage pillar platforms next_date; do
		# Truncate long titles
		local display_title="$title"
		if [[ ${#display_title} -gt 38 ]]; then
			display_title="${display_title:0:35}..."
		fi
		printf "%-4s %-40s %-10s %-15s %-15s %-12s\n" \
			"$id" "$display_title" "$stage" "${pillar:-'-'}" "${platforms:-'-'}" "${next_date:-'-'}"
	done

	echo ""
	local total
	if [[ -n "$status_filter" ]]; then
		# When filtering by schedule status, must join schedule table
		total=$(sqlite3 "$CC_DB" "SELECT COUNT(DISTINCT c.id) FROM content_items c LEFT JOIN schedule s ON c.id = s.content_id WHERE ${where_clause};")
	else
		total=$(sqlite3 "$CC_DB" "SELECT COUNT(*) FROM content_items c WHERE ${where_clause};")
	fi
	echo "Total items: ${total}"

	return 0
}

# Schedule a content item for a platform
cmd_schedule() {
	local content_id="${1:-}"
	local sched_date="${2:-}"
	local platform="${3:-}"

	if [[ -z "$content_id" || -z "$sched_date" || -z "$platform" ]]; then
		print_error "Usage: content-calendar-helper.sh schedule <content_id> <YYYY-MM-DD> <platform> [--time HH:MM]"
		return 1
	fi
	validate_numeric_id "$content_id" "content_id" || return 1
	shift 3

	local sched_time=""
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--time)
			sched_time="${2:-}"
			shift 2
			;;
		*) shift ;;
		esac
	done

	# Validate platform
	if ! echo "$CC_PLATFORMS" | grep -qw "$platform"; then
		print_error "Invalid platform: ${platform}. Valid: ${CC_PLATFORMS}"
		return 1
	fi

	# Validate an actual UTC calendar date and optional time, not only its shape.
	if ! [[ "$sched_date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
		print_error "Invalid date format. Use YYYY-MM-DD"
		return 1
	fi
	if ! validate_calendar_date "$sched_date"; then
		print_error "Invalid calendar date: ${sched_date}"
		return 1
	fi
	if [[ -n "$sched_time" && ! "$sched_time" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
		print_error "Invalid time format. Use HH:MM (UTC)"
		return 1
	fi

	init_db

	# Check content item exists
	local exists
	exists=$(sqlite3 "$CC_DB" "SELECT COUNT(*) FROM content_items WHERE id = ${content_id};")
	if [[ "$exists" -eq 0 ]]; then
		print_error "Content item #${content_id} not found"
		return 1
	fi

	local escaped_platform escaped_date escaped_time
	escaped_platform="$(sql_escape "$platform")"
	escaped_date="$(sql_escape "$sched_date")"
	escaped_time="$(sql_escape "$sched_time")"
	if sqlite3 "$CC_DB" "SELECT 1 FROM schedule WHERE content_id=${content_id} AND platform='${escaped_platform}' AND scheduled_date='${escaped_date}' AND scheduled_time='${escaped_time}' LIMIT 1;" | grep -q 1; then
		print_error "An identical schedule already exists for content item #${content_id}"
		return 1
	fi

	sqlite3 "$CC_DB" "
        INSERT INTO schedule (content_id, platform, scheduled_date, scheduled_time)
        VALUES (${content_id}, '${escaped_platform}', '${escaped_date}', '${escaped_time}');
    "

	local title
	title=$(sqlite3 "$CC_DB" "SELECT title FROM content_items WHERE id = ${content_id};")
	print_success "Scheduled #${content_id} (${title}) on ${platform} for ${sched_date}${sched_time:+ at ${sched_time}}"

	# Show optimal window recommendation
	_show_posting_window "$platform"

	return 0
}

# Show posting cadence analysis
cmd_cadence() {
	local platform_filter=""
	local weeks=4

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--platform)
			platform_filter="${2:-}"
			shift 2
			;;
		--weeks)
			weeks="${2:-4}"
			shift 2
			;;
		*) shift ;;
		esac
	done

	init_db

	echo ""
	echo "Posting Cadence Analysis (last ${weeks} weeks)"
	echo "=============================================="
	echo ""

	local today
	today=$(date -u +%Y-%m-%d)
	local start_date
	start_date=$(date -u -v-"${weeks}"w +%Y-%m-%d 2>/dev/null || date -u -d "${weeks} weeks ago" +%Y-%m-%d 2>/dev/null || echo "$today")

	printf "%-12s %-8s %-8s %-8s %-10s %-20s\n" "Platform" "Actual" "Target" "Gap" "Status" "Recommendation"
	printf "%-12s %-8s %-8s %-8s %-10s %-20s\n" "--------" "------" "------" "---" "------" "--------------"

	for target_entry in "${CC_CADENCE_TARGETS[@]}"; do
		local plat min_rate max_rate optimal_rate
		IFS=':' read -r plat min_rate max_rate optimal_rate <<<"$target_entry"

		if [[ -n "$platform_filter" && "$plat" != "$platform_filter" ]]; then
			continue
		fi

		# Count scheduled posts in the period
		local actual_count
		actual_count=$(sqlite3 "$CC_DB" "
            SELECT COUNT(*) FROM schedule
            WHERE platform = '${plat}'
              AND scheduled_date >= '${start_date}'
              AND scheduled_date <= '${today}';
        ")

		# Calculate weekly rate
		local actual_weekly
		if [[ "$weeks" -gt 0 ]]; then
			actual_weekly=$(echo "scale=1; ${actual_count} / ${weeks}" | bc 2>/dev/null || echo "0")
		else
			actual_weekly="0"
		fi

		# Determine status and recommendation
		local status recommendation
		if (($(echo "$actual_weekly < $min_rate" | bc -l 2>/dev/null || echo "1"))); then
			status="UNDER"
			recommendation="Increase to ${optimal_rate}/week"
		elif (($(echo "$actual_weekly > $max_rate" | bc -l 2>/dev/null || echo "0"))); then
			status="OVER"
			recommendation="Reduce to ${optimal_rate}/week"
		else
			status="ON TRACK"
			recommendation="Maintain current pace"
		fi

		printf "%-12s %-8s %-8s %-8s %-10s %-20s\n" \
			"$plat" "${actual_weekly}/w" "${optimal_rate}/w" \
			"$(echo "scale=1; ${optimal_rate} - ${actual_weekly}" | bc 2>/dev/null || echo "?")" \
			"$status" "$recommendation"
	done

	echo ""
	echo "Cadence targets from content/optimization.md and content/distribution/social.md"

	return 0
}

# Show calendar status or item details
cmd_status() {
	local item_id="${1:-}"

	init_db

	if [[ -n "$item_id" ]]; then
		validate_numeric_id "$item_id" "item_id" || return 1

		# Show specific item details
		local item_data
		item_data=$(sqlite3 -separator '|' "$CC_DB" "
            SELECT id, title, pillar, cluster, stage, intent, word_count, tags, author, created_at, updated_at, notes
            FROM content_items WHERE id = ${item_id};
        ")

		if [[ -z "$item_data" ]]; then
			print_error "Content item #${item_id} not found"
			return 1
		fi

		local id title pillar cluster stage intent word_count tags author created updated notes
		IFS='|' read -r id title pillar cluster stage intent word_count tags author created updated notes <<<"$item_data"

		echo ""
		echo "Content Item #${id}"
		echo "==================="
		echo "Title:      ${title}"
		echo "Stage:      ${stage}"
		echo "Pillar:     ${pillar:-'-'}"
		echo "Cluster:    ${cluster:-'-'}"
		echo "Intent:     ${intent}"
		echo "Word Count: ${word_count}"
		echo "Author:     ${author:-'-'}"
		echo "Tags:       ${tags:-'-'}"
		echo "Created:    ${created}"
		echo "Updated:    ${updated}"
		[[ -n "$notes" ]] && echo "Notes:      ${notes}"

		echo ""
		echo "Schedule:"
		sqlite3 -separator '|' "$CC_DB" "
            SELECT platform, scheduled_date, scheduled_time, status, published_url
            FROM schedule WHERE content_id = ${item_id}
            ORDER BY scheduled_date;
        " | while IFS='|' read -r plat sdate stime sstatus url; do
			echo "  ${plat}: ${sdate}${stime:+ ${stime}} [${sstatus}]${url:+ -> ${url}}"
		done
	else
		# Show overall calendar status
		echo ""
		echo "Content Calendar Status"
		echo "======================="
		echo ""

		echo "Items by Stage:"
		for stage in $CC_STAGES; do
			local count
			count=$(sqlite3 "$CC_DB" "SELECT COUNT(*) FROM content_items WHERE stage = '${stage}';")
			printf "  %-12s %d\n" "${stage}:" "$count"
		done

		echo ""
		echo "Upcoming Schedule (next 14 days):"
		local upcoming_end
		upcoming_end=$(date -u -v+14d +%Y-%m-%d 2>/dev/null || date -u -d "14 days" +%Y-%m-%d 2>/dev/null || echo "2099-12-31")
		local today_date
		today_date=$(date -u +%Y-%m-%d)

		sqlite3 -separator '|' "$CC_DB" "
            SELECT s.scheduled_date, s.platform, c.title, s.status
            FROM schedule s
            JOIN content_items c ON s.content_id = c.id
            WHERE s.scheduled_date >= '${today_date}'
              AND s.scheduled_date <= '${upcoming_end}'
            ORDER BY s.scheduled_date, s.platform;
        " | while IFS='|' read -r sdate plat title sstatus; do
			local display_title="$title"
			if [[ ${#display_title} -gt 35 ]]; then
				display_title="${display_title:0:32}..."
			fi
			printf "  %-12s %-10s %-35s [%s]\n" "$sdate" "$plat" "$display_title" "$sstatus"
		done

		echo ""
		local total_items total_scheduled
		total_items=$(sqlite3 "$CC_DB" "SELECT COUNT(*) FROM content_items;")
		total_scheduled=$(sqlite3 "$CC_DB" "SELECT COUNT(*) FROM schedule WHERE status = 'scheduled';")
		echo "Total items: ${total_items} | Scheduled: ${total_scheduled}"
	fi

	return 0
}

# Advance a content item through lifecycle stages
cmd_advance() {
	local item_id="${1:-}"
	local target_stage="${2:-}"

	if [[ -z "$item_id" || -z "$target_stage" ]]; then
		print_error "Usage: content-calendar-helper.sh advance <id> <stage>"
		echo "  Stages: ${CC_STAGES}"
		return 1
	fi
	validate_numeric_id "$item_id" "item_id" || return 1

	# Validate stage
	if ! echo "$CC_STAGES" | grep -qw "$target_stage"; then
		print_error "Invalid stage: ${target_stage}. Valid: ${CC_STAGES}"
		return 1
	fi

	init_db

	local current_stage
	current_stage=$(sqlite3 "$CC_DB" "SELECT stage FROM content_items WHERE id = ${item_id};" 2>/dev/null || echo "")

	if [[ -z "$current_stage" ]]; then
		print_error "Content item #${item_id} not found"
		return 1
	fi

	sqlite3 "$CC_DB" "
        UPDATE content_items
        SET stage = '${target_stage}',
            updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
        WHERE id = ${item_id};
    "

	local title
	title=$(sqlite3 "$CC_DB" "SELECT title FROM content_items WHERE id = ${item_id};")
	print_success "Advanced #${item_id} (${title}): ${current_stage} -> ${target_stage}"

	# If advancing to publish, update schedule status
	if [[ "$target_stage" == "publish" ]]; then
		local today_date
		today_date=$(date -u +%Y-%m-%d)
		sqlite3 "$CC_DB" "
            UPDATE schedule
            SET status = 'published'
            WHERE content_id = ${item_id}
              AND scheduled_date <= '${today_date}'
              AND status = 'scheduled';
        "

		# Log to cadence tracker
		sqlite3 "$CC_DB" "
            INSERT INTO cadence_log (platform, post_date, content_id)
            SELECT platform, '${today_date}', content_id
            FROM schedule
            WHERE content_id = ${item_id}
              AND status = 'published';
        "
	fi

	return 0
}

# Show items due within N days
cmd_due() {
	local days=7

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--days)
			days="${2:-7}"
			shift 2
			;;
		*) shift ;;
		esac
	done

	validate_positive_int "$days" "days" || return 1
	init_db

	local today_date
	today_date=$(date -u +%Y-%m-%d)
	local end_date
	end_date=$(date -u -v+"${days}"d +%Y-%m-%d 2>/dev/null || date -u -d "${days} days" +%Y-%m-%d 2>/dev/null || echo "2099-12-31")

	echo ""
	echo "Content Due Within ${days} Days (${today_date} to ${end_date})"
	echo "================================================="
	echo ""

	printf "%-12s %-10s %-35s %-10s %-8s\n" "Date" "Platform" "Title" "Stage" "Status"
	printf "%-12s %-10s %-35s %-10s %-8s\n" "----" "--------" "-----" "-----" "------"

	sqlite3 -separator '|' "$CC_DB" "
        SELECT s.scheduled_date, s.platform, c.title, c.stage, s.status
        FROM schedule s
        JOIN content_items c ON s.content_id = c.id
        WHERE s.scheduled_date >= '${today_date}'
          AND s.scheduled_date <= '${end_date}'
          AND s.status = 'scheduled'
        ORDER BY s.scheduled_date, s.platform;
    " | while IFS='|' read -r sdate plat title stage sstatus; do
		local display_title="$title"
		if [[ ${#display_title} -gt 33 ]]; then
			display_title="${display_title:0:30}..."
		fi
		printf "%-12s %-10s %-35s %-10s %-8s\n" "$sdate" "$plat" "$display_title" "$stage" "$sstatus"
	done

	echo ""
	local overdue_count
	overdue_count=$(sqlite3 "$CC_DB" "
        SELECT COUNT(*) FROM schedule s
        JOIN content_items c ON s.content_id = c.id
        WHERE s.scheduled_date < '${today_date}'
          AND s.status = 'scheduled';
    ")
	if [[ "$overdue_count" -gt 0 ]]; then
		print_warning "${overdue_count} overdue items found! Run 'content-calendar-helper.sh list --stage draft' to review."
	fi

	return 0
}

# Print platform coverage table for gap analysis
# Args: today_date end_date weeks_ahead
_gaps_platform_coverage() {
	local today_date="$1"
	local end_date="$2"
	local weeks_ahead="$3"

	echo "Platform Coverage:"
	printf "%-12s %-10s %-10s %-10s %-30s\n" "Platform" "Scheduled" "Target" "Gap" "Action"
	printf "%-12s %-10s %-10s %-10s %-30s\n" "--------" "---------" "------" "---" "------"

	for target_entry in "${CC_CADENCE_TARGETS[@]}"; do
		local plat optimal_rate
		IFS=':' read -r plat _ _ optimal_rate <<<"$target_entry"

		local scheduled_count
		scheduled_count=$(sqlite3 "$CC_DB" "
            SELECT COUNT(*) FROM schedule
            WHERE platform = '${plat}'
              AND scheduled_date >= '${today_date}'
              AND scheduled_date <= '${end_date}';
        ")

		local target_count
		target_count=$(echo "scale=0; ${optimal_rate} * ${weeks_ahead} / 1" | bc 2>/dev/null || echo "0")

		local gap
		gap=$((target_count - scheduled_count))

		local action=""
		if [[ "$gap" -gt 0 ]]; then
			action="Need ${gap} more posts"
		elif [[ "$gap" -lt 0 ]]; then
			action="Over-scheduled by $((gap * -1))"
		else
			action="On track"
		fi

		printf "%-12s %-10s %-10s %-10s %-30s\n" "$plat" "$scheduled_count" "$target_count" "$gap" "$action"
	done

	return 0
}

# Print pillar coverage section for gap analysis
_gaps_pillar_coverage() {
	echo "Pillar Coverage:"
	sqlite3 -separator '|' "$CC_DB" "
        SELECT COALESCE(NULLIF(pillar, ''), 'Unassigned') as p, COUNT(*) as cnt,
               SUM(CASE WHEN stage IN ('ideation', 'draft') THEN 1 ELSE 0 END) as in_progress,
               SUM(CASE WHEN stage = 'publish' THEN 1 ELSE 0 END) as published
        FROM content_items
        GROUP BY p
        ORDER BY cnt DESC;
    " | while IFS='|' read -r pillar_name cnt in_prog pub; do
		echo "  ${pillar_name}: ${cnt} total (${in_prog} in progress, ${pub} published)"
	done

	return 0
}

# Count and report empty weekdays in the schedule window
# Args: today_date days
_gaps_empty_days() {
	local today_date="$1"
	local days="$2"

	echo "Empty Days (no content scheduled):"
	local empty_days=0
	local check_date="$today_date"
	local i=0
	while [[ $i -lt $days ]]; do
		local day_count
		day_count=$(sqlite3 "$CC_DB" "
            SELECT COUNT(*) FROM schedule
            WHERE scheduled_date = '${check_date}';
        ")
		if [[ "$day_count" -eq 0 ]]; then
			# Only flag weekdays as gaps
			local day_of_week
			day_of_week=$(date -j -f "%Y-%m-%d" "$check_date" "+%u" 2>/dev/null || date -d "$check_date" "+%u" 2>/dev/null || echo "1")
			if [[ "$day_of_week" -le 5 ]]; then
				empty_days=$((empty_days + 1))
			fi
		fi
		check_date=$(date -j -v+1d -f "%Y-%m-%d" "$check_date" "+%Y-%m-%d" 2>/dev/null || date -d "$check_date + 1 day" "+%Y-%m-%d" 2>/dev/null || echo "")
		if [[ -z "$check_date" ]]; then
			break
		fi
		i=$((i + 1))
	done

	if [[ "$empty_days" -gt 0 ]]; then
		print_warning "${empty_days} weekdays with no content scheduled in the next ${days} days"
	else
		print_success "All weekdays have content scheduled"
	fi

	return 0
}

# Identify content gaps in the schedule
cmd_gaps() {
	local days=30

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--days)
			days="${2:-30}"
			shift 2
			;;
		*) shift ;;
		esac
	done

	validate_positive_int "$days" "days" || return 1
	init_db

	local today_date
	today_date=$(date -u +%Y-%m-%d)
	local end_date
	end_date=$(date -u -v+"${days}"d +%Y-%m-%d 2>/dev/null || date -u -d "${days} days" +%Y-%m-%d 2>/dev/null || echo "2099-12-31")
	local weeks_ahead
	weeks_ahead=$(echo "scale=1; ${days} / 7" | bc 2>/dev/null || echo "4")

	echo ""
	echo "Content Gap Analysis (next ${days} days)"
	echo "========================================="
	echo ""

	_gaps_platform_coverage "$today_date" "$end_date" "$weeks_ahead"

	echo ""
	_gaps_pillar_coverage

	echo ""
	_gaps_empty_days "$today_date" "$days"

	return 0
}

# Show calendar statistics
cmd_stats() {
	init_db

	echo ""
	echo "Content Calendar Statistics"
	echo "==========================="
	echo ""

	echo "Items by Stage:"
	for stage in $CC_STAGES; do
		local count
		count=$(sqlite3 "$CC_DB" "SELECT COUNT(*) FROM content_items WHERE stage = '${stage}';")
		printf "  %-12s %d\n" "${stage}:" "$count"
	done

	echo ""
	echo "Items by Intent:"
	sqlite3 -separator '|' "$CC_DB" "
        SELECT intent, COUNT(*) FROM content_items GROUP BY intent ORDER BY COUNT(*) DESC;
    " | while IFS='|' read -r intent cnt; do
		printf "  %-20s %d\n" "${intent}:" "$cnt"
	done

	echo ""
	echo "Schedule by Platform:"
	sqlite3 -separator '|' "$CC_DB" "
        SELECT platform, COUNT(*),
               SUM(CASE WHEN status = 'scheduled' THEN 1 ELSE 0 END),
               SUM(CASE WHEN status = 'published' THEN 1 ELSE 0 END)
        FROM schedule
        GROUP BY platform
        ORDER BY COUNT(*) DESC;
    " | while IFS='|' read -r plat total sched pub; do
		printf "  %-12s %d total (%d scheduled, %d published)\n" "${plat}:" "$total" "$sched" "$pub"
	done

	echo ""
	echo "Top Pillars:"
	sqlite3 -separator '|' "$CC_DB" "
        SELECT COALESCE(NULLIF(pillar, ''), 'Unassigned'), COUNT(*)
        FROM content_items
        GROUP BY pillar
        ORDER BY COUNT(*) DESC
        LIMIT 10;
    " | while IFS='|' read -r pillar_name cnt; do
		printf "  %-20s %d items\n" "${pillar_name}:" "$cnt"
	done

	echo ""
	local total_items total_scheduled total_published
	total_items=$(sqlite3 "$CC_DB" "SELECT COUNT(*) FROM content_items;")
	total_scheduled=$(sqlite3 "$CC_DB" "SELECT COUNT(*) FROM schedule;")
	total_published=$(sqlite3 "$CC_DB" "SELECT COUNT(*) FROM schedule WHERE status = 'published';")
	echo "Totals: ${total_items} items | ${total_scheduled} scheduled | ${total_published} published"

	return 0
}

# Export calendar data
cmd_export() {
	local format="json"

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--format)
			format="${2:-json}"
			shift 2
			;;
		*) shift ;;
		esac
	done

	init_db

	case "$format" in
	json)
		sqlite3 "$CC_DB" "
                SELECT json_group_array(json_object(
                    'id', c.id,
                    'title', c.title,
                    'pillar', c.pillar,
                    'cluster', c.cluster,
                    'stage', c.stage,
                    'intent', c.intent,
                    'author', c.author,
                    'tags', c.tags,
                    'created_at', c.created_at,
                    'schedules', (
                        SELECT json_group_array(json_object(
                            'platform', s.platform,
                            'date', s.scheduled_date,
                            'time', s.scheduled_time,
                            'status', s.status,
                            'url', s.published_url
                        ))
                        FROM schedule s WHERE s.content_id = c.id
                    )
                ))
                FROM content_items c;
            "
		;;
	csv)
		echo "id,title,pillar,cluster,stage,intent,author,tags,platform,scheduled_date,status"
		sqlite3 -csv "$CC_DB" "
                SELECT c.id, c.title, c.pillar, c.cluster, c.stage, c.intent, c.author, c.tags,
                       COALESCE(s.platform, ''), COALESCE(s.scheduled_date, ''), COALESCE(s.status, '')
                FROM content_items c
                LEFT JOIN schedule s ON c.id = s.content_id
                ORDER BY c.id;
            "
		;;
	*)
		print_error "Invalid format: ${format}. Use json or csv."
		return 1
		;;
	esac

	return 0
}

# =============================================================================
# Helper Functions
# =============================================================================

# Show optimal posting window for a platform
_show_posting_window() {
	local platform="$1"

	for window_entry in "${CC_POSTING_WINDOWS[@]}"; do
		local plat days times
		IFS=':' read -r plat days times <<<"$window_entry"
		if [[ "$plat" == "$platform" ]]; then
			print_info "Optimal posting window for ${platform}: ${days} at ${times} UTC"
			return 0
		fi
	done

	return 0
}

# Show help
cmd_help() {
	echo ""
	echo "Content Calendar & Posting Cadence Engine"
	echo "=========================================="
	echo ""
	echo "${HELP_LABEL_USAGE}"
	echo "  content-calendar-helper.sh [command] [args] [options]"
	echo ""
	echo "${HELP_LABEL_COMMANDS}"
	echo "  add <title> [opts]              Add a content item"
	echo "    --pillar <name>               Content pillar (e.g., DevOps, AI/ML)"
	echo "    --cluster <name>              Topic cluster within pillar"
	echo "    --intent <type>               Search intent: informational|commercial|transactional|navigational"
	echo "    --author <name>               Content author"
	echo "    --tags <t1,t2>                Comma-separated tags"
	echo "    --notes <text>                Additional notes"
	echo ""
	echo "  list [opts]                     List calendar items"
	echo "    --stage <stage>               Filter by lifecycle stage"
	echo "    --platform <platform>         Filter by scheduled platform"
	echo "    --limit <n>                   Max items to show (default: 50)"
	echo ""
	echo "  schedule <id> <date> <plat>     Schedule item for a platform"
	echo "    --time <HH:MM>                Optional posting time (UTC)"
	echo ""
	echo "  cadence [opts]                  Show posting cadence analysis"
	echo "    --platform <platform>         Filter to specific platform"
	echo "    --weeks <n>                   Analysis window (default: 4)"
	echo ""
	echo "  status [id]                     Show calendar overview or item details"
	echo "  advance <id> <stage>            Move item through lifecycle"
	echo "  due [--days N]                  Show items due within N days"
	echo "  gaps [--days N]                 Identify content gaps"
	echo "  stats                           Show calendar statistics"
	echo "  export [--format json|csv]      Export calendar data"
	echo "  help                            Show this help message"
	echo ""
	echo "Lifecycle Stages:"
	echo "  ideation -> draft -> review -> publish -> promote -> analyze"
	echo ""
	echo "Platforms:"
	echo "  ${CC_PLATFORMS}"
	echo ""
	echo "Cadence Targets (posts/week):"
	for target_entry in "${CC_CADENCE_TARGETS[@]}"; do
		local plat min_rate max_rate optimal_rate
		IFS=':' read -r plat min_rate max_rate optimal_rate <<<"$target_entry"
		printf "  %-12s %s-%s/week (optimal: %s)\n" "${plat}:" "$min_rate" "$max_rate" "$optimal_rate"
	done
	echo ""
	echo "${HELP_LABEL_EXAMPLES}"
	echo "  content-calendar-helper.sh add \"CI/CD Pipeline Guide\" --pillar DevOps --intent informational"
	echo "  content-calendar-helper.sh schedule 1 2026-02-15 blog --time 10:00"
	echo "  content-calendar-helper.sh cadence --platform youtube --weeks 8"
	echo "  content-calendar-helper.sh gaps --days 14"
	echo "  content-calendar-helper.sh advance 1 draft"
	echo "  content-calendar-helper.sh due --days 3"
	echo ""

	return 0
}

# =============================================================================
# Main
# =============================================================================

main() {
	local command="${1:-help}"
	shift 2>/dev/null || true

	case "$command" in
	add) cmd_add "$@" ;;
	list) cmd_list "$@" ;;
	schedule) cmd_schedule "$@" ;;
	cadence) cmd_cadence "$@" ;;
	status) cmd_status "$@" ;;
	advance) cmd_advance "$@" ;;
	due) cmd_due "$@" ;;
	gaps) cmd_gaps "$@" ;;
	stats) cmd_stats "$@" ;;
	export) cmd_export "$@" ;;
	help | --help | -h) cmd_help ;;
	*)
		print_error "${ERROR_UNKNOWN_COMMAND}: ${command}"
		cmd_help
		return 1
		;;
	esac
}

main "$@"

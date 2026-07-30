#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Mission Progress Dashboard — CLI + optional browser view (t1362)
# Commands: status | summary | browser | json | help
# Data sources: mission state files, observability-helper.sh, budget-tracker-helper.sh, ps, gh
# Storage: mission.md files in todo/missions/ or ~/.aidevops/missions/

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
# shellcheck source=shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh"
set -euo pipefail
init_log_file

readonly MISSIONS_HOME="${HOME}/.aidevops/missions"
readonly DASHBOARD_HTML_DIR="${HOME}/.aidevops/.agent-workspace/tmp"
readonly OBS_METRICS="${HOME}/.aidevops/.agent-workspace/observability/metrics.jsonl"
readonly COST_LOG="${HOME}/.aidevops/.agent-workspace/cost-log.tsv"

# =============================================================================
# Mission Discovery
# =============================================================================

# Find all mission state files across repos and homeless missions.
# Outputs one path per line.
find_mission_files() {
	local -a paths=()

	# Homeless missions
	if [[ -d "$MISSIONS_HOME" ]]; then
		while IFS= read -r f; do
			[[ -n "$f" ]] && paths+=("$f")
		done < <(find "$MISSIONS_HOME" -name "mission.md" -type f 2>/dev/null)
	fi

	# Repo-attached missions from repos.json
	local repos_json="${HOME}/.config/aidevops/repos.json"
	if [[ -f "$repos_json" ]] && command -v jq &>/dev/null; then
		while IFS= read -r repo_path; do
			[[ -z "$repo_path" ]] && continue
			local missions_dir="${repo_path}/todo/missions"
			if [[ -d "$missions_dir" ]]; then
				while IFS= read -r f; do
					[[ -n "$f" ]] && paths+=("$f")
				done < <(find "$missions_dir" -name "mission.md" -type f 2>/dev/null)
			fi
		done < <(jq -r '.[].path // empty' "$repos_json" 2>/dev/null)
	fi

	# Also check current repo if in one
	local repo_root
	repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || repo_root=""
	if [[ -n "$repo_root" && -d "${repo_root}/todo/missions" ]]; then
		while IFS= read -r f; do
			[[ -n "$f" ]] && paths+=("$f")
		done < <(find "${repo_root}/todo/missions" -name "mission.md" -type f 2>/dev/null)
	fi

	# Deduplicate by realpath
	# Bash 3.2 compat: no associative arrays — use string-based seen list
	local seen=" "
	for p in "${paths[@]}"; do
		local rp
		rp=$(realpath "$p" 2>/dev/null) || rp="$p"
		if [[ "$seen" != *" ${rp} "* ]]; then
			seen="${seen}${rp} "
			echo "$p"
		fi
	done
	return 0
}

# =============================================================================
# Mission State Parsing
# =============================================================================

# Parse YAML-ish frontmatter from a mission.md file.
# Extracts key fields into shell variables via stdout (eval-safe).
parse_mission_frontmatter() {
	local file="$1"
	[[ -f "$file" ]] || return 1

	local in_frontmatter=false
	local id="" title="" status="" mode="" created="" started="" completed=""
	local budget_time="" budget_money="" budget_tokens="" alert_threshold=""

	while IFS= read -r line; do
		if [[ "$line" == "---" ]]; then
			if [[ "$in_frontmatter" == "false" ]]; then
				in_frontmatter=true
				continue
			else
				break
			fi
		fi
		[[ "$in_frontmatter" == "false" ]] && continue

		# Strip comments
		local val
		val=$(echo "$line" | sed 's/#.*//' | xargs)

		case "$line" in
		id:*) id=$(echo "$val" | sed 's/^id:[[:space:]]*//' | tr -d '"') ;;
		title:*) title=$(echo "$val" | sed 's/^title:[[:space:]]*//' | tr -d '"') ;;
		status:*) status=$(echo "$val" | sed 's/^status:[[:space:]]*//' | tr -d '"') ;;
		mode:*) mode=$(echo "$val" | sed 's/^mode:[[:space:]]*//' | tr -d '"') ;;
		created:*) created=$(echo "$val" | sed 's/^created:[[:space:]]*//' | tr -d '"') ;;
		started:*) started=$(echo "$val" | sed 's/^started:[[:space:]]*//' | tr -d '"') ;;
		completed:*) completed=$(echo "$val" | sed 's/^completed:[[:space:]]*//' | tr -d '"') ;;
		*time_hours:*) budget_time=$(echo "$val" | sed 's/.*time_hours:[[:space:]]*//' | tr -d '"') ;;
		*money_usd:*) budget_money=$(echo "$val" | sed 's/.*money_usd:[[:space:]]*//' | tr -d '"') ;;
		*token_limit:*) budget_tokens=$(echo "$val" | sed 's/.*token_limit:[[:space:]]*//' | tr -d '"') ;;
		*alert_threshold_pct:*) alert_threshold=$(echo "$val" | sed 's/.*alert_threshold_pct:[[:space:]]*//' | tr -d '"') ;;
		esac
	done <"$file"

	# Fallback: parse title from first H1 heading if not in frontmatter
	if [[ -z "$title" ]]; then
		title=$(grep -m1 '^# ' "$file" | sed 's/^# //')
	fi

	# Fallback: parse ID from body if not in frontmatter
	if [[ -z "$id" ]]; then
		id=$(grep -m1 '^\*\*ID:\*\*\|^- \*\*ID:\*\*' "$file" | sed 's/.*ID:\*\*[[:space:]]*//' | tr -d '`')
	fi

	# Fallback: parse status from body
	if [[ -z "$status" || "$status" == "subagent" ]]; then
		status=$(grep -m1 '^\*\*Status:\*\*\|^- \*\*Status:\*\*' "$file" | sed 's/.*Status:\*\*[[:space:]]*//')
	fi

	printf 'MISSION_ID=%q\n' "${id:-unknown}"
	printf 'MISSION_TITLE=%q\n' "${title:-Untitled Mission}"
	printf 'MISSION_STATUS=%q\n' "${status:-unknown}"
	printf 'MISSION_MODE=%q\n' "${mode:-full}"
	printf 'MISSION_CREATED=%q\n' "${created:-}"
	printf 'MISSION_STARTED=%q\n' "${started:-}"
	printf 'MISSION_COMPLETED=%q\n' "${completed:-}"
	printf 'BUDGET_TIME=%q\n' "${budget_time:-0}"
	printf 'BUDGET_MONEY=%q\n' "${budget_money:-0}"
	printf 'BUDGET_TOKENS=%q\n' "${budget_tokens:-0}"
	printf 'ALERT_THRESHOLD=%q\n' "${alert_threshold:-80}"
	return 0
}

# Parse milestones from a mission.md file.
# Outputs: milestone_num|name|status|total_features|completed_features|estimate
parse_milestones() {
	local file="$1"
	[[ -f "$file" ]] || return 1

	local current_milestone="" current_name="" current_status="pending" current_estimate=""
	local total_features=0 completed_features=0

	while IFS= read -r line; do
		# Detect milestone heading: ### Milestone N: Name or ### MN: Name
		if echo "$line" | grep -qE '^### (Milestone |M)[0-9]+'; then
			# Emit previous milestone if any
			if [[ -n "$current_milestone" ]]; then
				echo "${current_milestone}|${current_name}|${current_status}|${total_features}|${completed_features}|${current_estimate}"
			fi
			current_milestone=$(echo "$line" | grep -oE '[0-9]+' | head -1)
			current_name=$(echo "$line" | sed -E 's/^### (Milestone |M)[0-9]+:[[:space:]]*//')
			current_status="pending"
			current_estimate=""
			total_features=0
			completed_features=0
		fi

		# Parse milestone status
		if [[ -n "$current_milestone" ]] && echo "$line" | grep -qiE '^\*\*Status:\*\*|^- \*\*Status:\*\*'; then
			current_status=$(echo "$line" | sed -E 's/.*Status:\*\*[[:space:]]*//' | sed 's/[[:space:]]*<!--.*//' | tr -d '`')
		fi

		# Parse milestone estimate
		if [[ -n "$current_milestone" ]] && echo "$line" | grep -qiE '^\*\*Estimate:\*\*|^- \*\*Estimate:\*\*'; then
			current_estimate=$(echo "$line" | grep -oE '~?[0-9]+h?' | head -1)
		fi

		# Count features (table rows or checklist items)
		if [[ -n "$current_milestone" ]]; then
			# Table row: | N.N | description | tNNN | status | ...
			if echo "$line" | grep -qE '^\|[[:space:]]*[0-9]+\.[0-9]+'; then
				total_features=$((total_features + 1))
				if echo "$line" | grep -qiE '\bcompleted\b|\bdone\b|\bmerged\b'; then
					completed_features=$((completed_features + 1))
				fi
			fi
			# Checklist: - [x] FN: description or - [ ] FN: description
			if echo "$line" | grep -qE '^[[:space:]]*- \[[ xX]\] F?[0-9]'; then
				total_features=$((total_features + 1))
				if echo "$line" | grep -qE '^\s*- \[[xX]\]'; then
					completed_features=$((completed_features + 1))
				fi
			fi
		fi
	done <"$file"

	# Emit last milestone
	if [[ -n "$current_milestone" ]]; then
		echo "${current_milestone}|${current_name}|${current_status}|${total_features}|${completed_features}|${current_estimate}"
	fi
	return 0
}

# Parse budget tracking table from mission.md.
# Outputs: category|budget|spent|remaining|pct
parse_budget_table() {
	local file="$1"
	[[ -f "$file" ]] || return 1

	local in_budget=false
	while IFS= read -r line; do
		# Detect budget section
		if echo "$line" | grep -qiE '^## Budget Tracking|^### Summary'; then
			in_budget=true
			continue
		fi
		# Exit on next section
		if [[ "$in_budget" == "true" ]] && echo "$line" | grep -qE '^## [^B]|^### [^S]'; then
			break
		fi
		# Parse table rows: | Category | Budget | Spent | Remaining | % Used |
		if [[ "$in_budget" == "true" ]] && echo "$line" | grep -qE '^\|[[:space:]]*(Time|Money|Token|Cost)'; then
			local category budget spent remaining pct
			category=$(echo "$line" | awk -F'|' '{gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); print $2}')
			budget=$(echo "$line" | awk -F'|' '{gsub(/^[[:space:]]+|[[:space:]]+$/, "", $3); print $3}')
			spent=$(echo "$line" | awk -F'|' '{gsub(/^[[:space:]]+|[[:space:]]+$/, "", $4); print $4}')
			remaining=$(echo "$line" | awk -F'|' '{gsub(/^[[:space:]]+|[[:space:]]+$/, "", $5); print $5}')
			pct=$(echo "$line" | awk -F'|' '{gsub(/^[[:space:]]+|[[:space:]]+$/, "", $6); print $6}')
			echo "${category}|${budget}|${spent}|${remaining}|${pct}"
		fi
	done <"$file"
	return 0
}

# =============================================================================
# Active Workers Detection
# =============================================================================

count_active_workers() {
	local count
	# t2190: ps axwwo to avoid Linux procps ~80-col truncation of full-loop marker.
	count=$(ps axwwo command 2>/dev/null | grep -c '/full-loop' | tr -d ' ') || count=0
	# Subtract grep itself
	count=$((count > 0 ? count - 1 : 0))
	echo "$count"
	return 0
}

get_active_workers() {
	# t2190: ps axwwo to avoid Linux procps ~80-col truncation of full-loop marker.
	ps axwwo pid,etime,command 2>/dev/null | grep '/full-loop' | grep -v grep || true
	return 0
}

# =============================================================================
# Burn Rate from observability/budget-tracker
# =============================================================================

get_burn_rate_json() {
	local result
	if [[ -x "${SCRIPT_DIR}/budget-tracker-helper.sh" ]]; then
		result=$("${SCRIPT_DIR}/budget-tracker-helper.sh" burn-rate --json 2>/dev/null) || result=""
		# Validate it's actual JSON (starts with {)
		if [[ "$result" == "{"* ]]; then
			echo "$result"
			return 0
		fi
	fi
	echo '{}'
	return 0
}

get_cost_status_json() {
	local result
	if [[ -x "${SCRIPT_DIR}/budget-tracker-helper.sh" ]]; then
		result=$("${SCRIPT_DIR}/budget-tracker-helper.sh" status --json --days 30 2>/dev/null) || result=""
		# Validate it's actual JSON (starts with {)
		if [[ "$result" == "{"* ]]; then
			echo "$result"
			return 0
		fi
	fi
	echo '{}'
	return 0
}

# =============================================================================
# Progress Bar Rendering
# =============================================================================

# Render a progress bar: [=========>          ] 45%
# Args: completed total width
render_progress_bar() {
	local completed="$1"
	local total="$2"
	local width="${3:-30}"

	if [[ "$total" -eq 0 ]]; then
		printf '[%*s] n/a' "$width" ""
		return 0
	fi

	local pct=$((completed * 100 / total))
	local filled=$((completed * width / total))
	local empty=$((width - filled))

	local bar=""
	if [[ "$filled" -gt 0 ]]; then
		bar=$(printf '%0.s=' $(seq 1 "$filled"))
		# Add arrow tip if not complete
		if [[ "$filled" -lt "$width" ]]; then
			bar="${bar:0:$((${#bar} - 1))}>"
		fi
	fi
	local spaces=""
	if [[ "$empty" -gt 0 ]]; then
		spaces=$(printf '%0.s ' $(seq 1 "$empty"))
	fi

	printf '[%s%s] %3d%%' "$bar" "$spaces" "$pct"
	return 0
}

# Color a status string
color_status() {
	local status="$1"
	case "$status" in
	completed | passed | done | merged) echo -e "${GREEN}${status}${NC}" ;;
	active | in_progress | dispatched) echo -e "${CYAN}${status}${NC}" ;;
	failed | abandoned | cancelled) echo -e "${RED}${status}${NC}" ;;
	blocked | paused) echo -e "${YELLOW}${status}${NC}" ;;
	validating) echo -e "${PURPLE}${status}${NC}" ;;
	*) echo "$status" ;;
	esac
	return 0
}

# =============================================================================
# CLI Dashboard Command — helpers
# =============================================================================

# Print dashboard header: title, timestamp, separator, workers, burn rate.
# Args: verbose worker_count max_workers
_status_print_header() {
	local verbose="$1"
	local worker_count="$2"
	local max_workers="$3"

	echo ""
	echo -e "${BOLD:-}${WHITE}Mission Progress Dashboard${NC}"
	echo -e "${CYAN}$(date '+%Y-%m-%d %H:%M:%S')${NC}"
	printf '%.0s─' {1..60}
	echo ""

	echo -e "\n${WHITE}Workers:${NC} ${worker_count}/${max_workers} active"

	if [[ "$verbose" == "true" ]]; then
		local workers
		workers=$(get_active_workers)
		if [[ -n "$workers" ]]; then
			echo "$workers" | while IFS= read -r w; do
				local pid etime cmd
				pid=$(echo "$w" | awk '{print $1}')
				etime=$(echo "$w" | awk '{print $2}')
				cmd=$(echo "$w" | awk '{for(i=3;i<=NF;i++) printf "%s ", $i; print ""}' | head -c 80)
				echo -e "  ${CYAN}PID ${pid}${NC} (${etime}) ${cmd}"
			done
		fi
	fi

	local burn_json
	burn_json=$(get_burn_rate_json)
	if [[ "$burn_json" != "{}" ]] && command -v jq &>/dev/null; then
		local today_spend hourly_rate avg_daily
		today_spend=$(echo "$burn_json" | jq -r '.today_spend // 0' 2>/dev/null)
		hourly_rate=$(echo "$burn_json" | jq -r '.hourly_rate // 0' 2>/dev/null)
		avg_daily=$(echo "$burn_json" | jq -r '.avg_daily // 0' 2>/dev/null)
		echo -e "${WHITE}Burn Rate:${NC} \$${today_spend}/today | \$${hourly_rate}/hr | \$${avg_daily}/day avg"
	fi

	echo ""
	return 0
}

# Print a single mission block: header, overall progress, per-milestone rows, budget.
# Args: mission_file mission_filter
_status_print_mission() {
	local mission_file="$1"
	local mission_filter="$2"

	local MISSION_ID MISSION_TITLE MISSION_STATUS MISSION_MODE
	local MISSION_CREATED MISSION_STARTED MISSION_COMPLETED
	local BUDGET_TIME BUDGET_MONEY BUDGET_TOKENS ALERT_THRESHOLD
	eval "$(parse_mission_frontmatter "$mission_file")"

	if [[ -n "$mission_filter" && "$MISSION_ID" != *"$mission_filter"* && "$MISSION_TITLE" != *"$mission_filter"* ]]; then
		return 0
	fi

	local status_colored
	status_colored=$(color_status "$MISSION_STATUS")
	echo -e "${WHITE}${MISSION_TITLE}${NC} (${MISSION_ID})"
	echo -e "  Status: ${status_colored} | Mode: ${MISSION_MODE} | Created: ${MISSION_CREATED}"

	local -a milestones=()
	while IFS= read -r ms; do
		[[ -n "$ms" ]] && milestones+=("$ms")
	done < <(parse_milestones "$mission_file")

	if [[ ${#milestones[@]} -eq 0 ]]; then
		echo "  No milestones defined."
		echo ""
		return 0
	fi

	local total_features=0 total_completed=0 total_milestones=${#milestones[@]}
	local passed_milestones=0
	for ms in "${milestones[@]}"; do
		local ms_total ms_completed ms_status
		ms_total=$(echo "$ms" | cut -d'|' -f4)
		ms_completed=$(echo "$ms" | cut -d'|' -f5)
		ms_status=$(echo "$ms" | cut -d'|' -f3)
		total_features=$((total_features + ms_total))
		total_completed=$((total_completed + ms_completed))
		if echo "$ms_status" | grep -qiE 'passed|completed|done'; then
			passed_milestones=$((passed_milestones + 1))
		fi
	done

	echo -n "  Overall: "
	render_progress_bar "$total_completed" "$total_features" 30
	echo " (${total_completed}/${total_features} features, ${passed_milestones}/${total_milestones} milestones)"

	for ms in "${milestones[@]}"; do
		local ms_num ms_name ms_status ms_total ms_completed ms_estimate
		IFS='|' read -r ms_num ms_name ms_status ms_total ms_completed ms_estimate <<<"$ms"
		local ms_status_colored
		ms_status_colored=$(color_status "$ms_status")
		echo -n "  M${ms_num}: ${ms_name} "
		render_progress_bar "$ms_completed" "$ms_total" 20
		echo -e " ${ms_status_colored} (${ms_completed}/${ms_total}) ${ms_estimate:-}"
	done

	local -a budget_rows=()
	while IFS= read -r br; do
		[[ -n "$br" ]] && budget_rows+=("$br")
	done < <(parse_budget_table "$mission_file")

	if [[ ${#budget_rows[@]} -gt 0 ]]; then
		echo "  Budget:"
		for br in "${budget_rows[@]}"; do
			local cat bgt spt rem pct
			IFS='|' read -r cat bgt spt rem pct <<<"$br"
			local pct_num
			pct_num=$(echo "$pct" | tr -dc '0-9')
			local color="$NC"
			if [[ -n "$pct_num" && "$pct_num" -ge 80 ]]; then
				color="$RED"
			elif [[ -n "$pct_num" && "$pct_num" -ge 60 ]]; then
				color="$YELLOW"
			fi
			echo -e "    ${cat}: ${spt} / ${bgt} (${color}${pct}${NC})"
		done
	fi

	echo ""
	return 0
}

# Print blocked issues across all pulse repos (verbose mode only).
_status_print_blockers() {
	echo -e "${WHITE}Blockers:${NC}"
	local repos_json="${HOME}/.config/aidevops/repos.json"
	if [[ -f "$repos_json" ]] && command -v jq &>/dev/null; then
		local found_blockers=false
		while IFS= read -r slug; do
			[[ -z "$slug" ]] && continue
			local blocked_issues
			blocked_issues=$(gh issue list --repo "$slug" --label "status:blocked" --json number,title --jq '.[] | "  #\(.number): \(.title)"' 2>/dev/null) || continue
			if [[ -n "$blocked_issues" ]]; then
				found_blockers=true
				echo -e "  ${YELLOW}${slug}:${NC}"
				echo "$blocked_issues"
			fi
		done < <(jq -r '.initialized_repos[]? | select(.maintenance != false and .pulse == true) | .slug // empty' "$repos_json" 2>/dev/null)
		if [[ "$found_blockers" == "false" ]]; then
			echo "  None"
		fi
	else
		echo "  (repos.json not found or jq not available)"
	fi
	echo ""
	return 0
}

# =============================================================================
# CLI Dashboard Command
# =============================================================================

# Parse --mission and --verbose flags for cmd_status.
# Usage: _status_parse_args "$@"
# Outputs: newline-separated KEY=VALUE pairs
_status_parse_args() {
	local mission_filter="" verbose=false
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--mission | -m)
			mission_filter="${2:-}"
			shift 2
			;;
		--verbose | -v)
			verbose=true
			shift
			;;
		*) shift ;;
		esac
	done
	printf '%s\n' \
		"mission_filter=${mission_filter}" \
		"verbose=${verbose}"
	return 0
}

cmd_status() {
	local parsed
	parsed=$(_status_parse_args "$@")

	local mission_filter="" verbose=""
	while IFS='=' read -r key val; do
		case "$key" in
		mission_filter) mission_filter="$val" ;;
		verbose) verbose="$val" ;;
		esac
	done <<<"$parsed"

	local -a mission_files=()
	while IFS= read -r f; do
		[[ -n "$f" ]] && mission_files+=("$f")
	done < <(find_mission_files)

	if [[ ${#mission_files[@]} -eq 0 ]]; then
		print_info "No missions found. Create one with /mission."
		return 0
	fi

	local worker_count max_workers
	worker_count=$(count_active_workers)
	max_workers=$(cat ~/.aidevops/logs/pulse-max-workers 2>/dev/null || echo 4)

	_status_print_header "$verbose" "$worker_count" "$max_workers"

	for mission_file in "${mission_files[@]}"; do
		_status_print_mission "$mission_file" "$mission_filter"
	done

	if [[ "$verbose" == "true" ]]; then
		_status_print_blockers
	fi

	return 0
}

# =============================================================================
# Summary Command (compact single-line per mission)
# =============================================================================

cmd_summary() {
	local -a mission_files=()
	while IFS= read -r f; do
		[[ -n "$f" ]] && mission_files+=("$f")
	done < <(find_mission_files)

	if [[ ${#mission_files[@]} -eq 0 ]]; then
		print_info "No missions found."
		return 0
	fi

	printf "\n%-14s %-30s %-12s %s\n" "ID" "Title" "Status" "Progress"
	printf '%.0s─' {1..70}
	echo ""

	for mission_file in "${mission_files[@]}"; do
		local MISSION_ID MISSION_TITLE MISSION_STATUS MISSION_MODE
		local MISSION_CREATED MISSION_STARTED MISSION_COMPLETED
		local BUDGET_TIME BUDGET_MONEY BUDGET_TOKENS ALERT_THRESHOLD
		eval "$(parse_mission_frontmatter "$mission_file")"

		local total_features=0 total_completed=0
		while IFS= read -r ms; do
			[[ -z "$ms" ]] && continue
			local ms_total ms_completed
			ms_total=$(echo "$ms" | cut -d'|' -f4)
			ms_completed=$(echo "$ms" | cut -d'|' -f5)
			total_features=$((total_features + ms_total))
			total_completed=$((total_completed + ms_completed))
		done < <(parse_milestones "$mission_file")

		local pct=0
		if [[ "$total_features" -gt 0 ]]; then
			pct=$((total_completed * 100 / total_features))
		fi

		local title_short="${MISSION_TITLE:0:28}"
		local status_colored
		status_colored=$(color_status "$MISSION_STATUS")
		printf "%-14s %-30s %b %3d%% (%d/%d)\n" "$MISSION_ID" "$title_short" "$status_colored" "$pct" "$total_completed" "$total_features"
	done
	echo ""
	return 0
}

# =============================================================================
# JSON Output Command — helpers
# =============================================================================

# Build a JSON array of milestones for one mission file.
# Also writes total_features and total_completed to the named variables via stdout
# in the format "TOTAL_FEATURES=N\nTOTAL_COMPLETED=N" on the last two lines.
# Callers must separate the JSON array (first line) from the counters.
# Args: mission_file
# Stdout: milestones_json_array|total_features|total_completed
_json_build_milestones() {
	local mission_file="$1"
	local milestones_json="["
	local first_ms=true
	local total_features=0 total_completed=0

	while IFS= read -r ms; do
		[[ -z "$ms" ]] && continue
		local ms_num ms_name ms_status ms_total ms_completed ms_estimate
		IFS='|' read -r ms_num ms_name ms_status ms_total ms_completed ms_estimate <<<"$ms"
		total_features=$((total_features + ms_total))
		total_completed=$((total_completed + ms_completed))

		[[ "$first_ms" == "true" ]] || milestones_json="${milestones_json},"
		first_ms=false
		milestones_json="${milestones_json}$(jq -c -n \
			--argjson num "$ms_num" \
			--arg name "$ms_name" \
			--arg status "$ms_status" \
			--argjson total "$ms_total" \
			--argjson completed "$ms_completed" \
			--arg estimate "${ms_estimate:-}" \
			'{number:$num, name:$name, status:$status, total_features:$total, completed_features:$completed, estimate:$estimate}')"
	done < <(parse_milestones "$mission_file")
	milestones_json="${milestones_json}]"

	echo "${milestones_json}|${total_features}|${total_completed}"
	return 0
}

# Build a single mission JSON object.
# Args: mission_file mission_filter
# Stdout: JSON object string, or empty string if filtered out
_json_build_mission() {
	local mission_file="$1"
	local mission_filter="$2"

	local MISSION_ID MISSION_TITLE MISSION_STATUS MISSION_MODE
	local MISSION_CREATED MISSION_STARTED MISSION_COMPLETED
	local BUDGET_TIME BUDGET_MONEY BUDGET_TOKENS ALERT_THRESHOLD
	eval "$(parse_mission_frontmatter "$mission_file")"

	if [[ -n "$mission_filter" && "$MISSION_ID" != *"$mission_filter"* ]]; then
		return 0
	fi

	local ms_result milestones_json total_features total_completed
	ms_result=$(_json_build_milestones "$mission_file")
	milestones_json=$(echo "$ms_result" | cut -d'|' -f1)
	total_features=$(echo "$ms_result" | cut -d'|' -f2)
	total_completed=$(echo "$ms_result" | cut -d'|' -f3)

	local pct=0
	if [[ "$total_features" -gt 0 ]]; then
		pct=$((total_completed * 100 / total_features))
	fi

	jq -c -n \
		--arg id "$MISSION_ID" \
		--arg title "$MISSION_TITLE" \
		--arg status "$MISSION_STATUS" \
		--arg mode "$MISSION_MODE" \
		--arg created "$MISSION_CREATED" \
		--arg started "$MISSION_STARTED" \
		--arg completed "$MISSION_COMPLETED" \
		--argjson total_features "$total_features" \
		--argjson completed_features "$total_completed" \
		--argjson progress_pct "$pct" \
		--argjson milestones "$milestones_json" \
		--arg file "$mission_file" \
		'{id:$id, title:$title, status:$status, mode:$mode, created:$created,
		  started:$started, completed:$completed, total_features:$total_features,
		  completed_features:$completed_features, progress_pct:$progress_pct,
		  milestones:$milestones, file:$file}'
	return 0
}

# =============================================================================
# JSON Output Command
# =============================================================================

# Build the missions JSON array from a list of mission files.
# Args: mission_filter mission_files...
# Outputs: JSON array string to stdout
_json_build_missions_array() {
	local mission_filter="$1"
	shift
	local mission_files=("$@")

	local missions_json="["
	local first_mission=true
	for mission_file in "${mission_files[@]}"; do
		local mission_obj
		mission_obj=$(_json_build_mission "$mission_file" "$mission_filter")
		[[ -z "$mission_obj" ]] && continue
		[[ "$first_mission" == "true" ]] || missions_json="${missions_json},"
		first_mission=false
		missions_json="${missions_json}${mission_obj}"
	done
	missions_json="${missions_json}]"
	printf '%s' "$missions_json"
	return 0
}

cmd_json() {
	local mission_filter=""
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--mission | -m)
			mission_filter="${2:-}"
			shift 2
			;;
		*) shift ;;
		esac
	done

	command -v jq &>/dev/null || {
		print_error "jq required for JSON output"
		return 1
	}

	local -a mission_files=()
	while IFS= read -r f; do
		[[ -n "$f" ]] && mission_files+=("$f")
	done < <(find_mission_files)

	local worker_count max_workers burn_json cost_json
	worker_count=$(count_active_workers)
	max_workers=$(cat ~/.aidevops/logs/pulse-max-workers 2>/dev/null || echo 4)
	burn_json=$(get_burn_rate_json)
	cost_json=$(get_cost_status_json)

	local missions_json
	missions_json=$(_json_build_missions_array "$mission_filter" "${mission_files[@]+"${mission_files[@]}"}")

	# Assemble full dashboard JSON.
	# Note: bash ${var:-{}} is ambiguous — the first } closes the expansion.
	# Use explicit empty-object fallback variables instead.
	local empty_obj='{}'
	local br="${burn_json:-$empty_obj}"
	local cs="${cost_json:-$empty_obj}"
	jq -c -n \
		--arg timestamp "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
		--argjson workers "$worker_count" \
		--argjson max_workers "$max_workers" \
		--argjson missions "$missions_json" \
		--argjson burn_rate "$br" \
		--argjson cost_status "$cs" \
		'{timestamp:$timestamp, workers:$workers, max_workers:$max_workers,
		  missions:$missions, burn_rate:$burn_rate, cost_status:$cost_status}' | jq .
	return 0
}

# =============================================================================
# Browser Dashboard Command
# =============================================================================

generate_html() {
	local json_data="$1"
	local output_file="$2"

	# Generate self-contained HTML dashboard
	cat >"$output_file" <<'HTMLEOF'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Mission Progress Dashboard</title>
<style>
  :root {
    --bg: #0d1117; --surface: #161b22; --border: #30363d;
    --text: #e6edf3; --text-muted: #8b949e; --text-dim: #484f58;
    --green: #3fb950; --yellow: #d29922; --red: #f85149;
    --blue: #58a6ff; --purple: #bc8cff; --cyan: #39d353;
  }
  * { margin: 0; padding: 0; box-sizing: border-box; }
  body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Helvetica, Arial, sans-serif;
    background: var(--bg); color: var(--text); padding: 24px; line-height: 1.5; }
  .header { display: flex; justify-content: space-between; align-items: center;
    margin-bottom: 24px; padding-bottom: 16px; border-bottom: 1px solid var(--border); }
  .header h1 { font-size: 24px; font-weight: 600; }
  .header .timestamp { color: var(--text-muted); font-size: 14px; }
  .stats-row { display: flex; gap: 16px; margin-bottom: 24px; }
  .stat-card { background: var(--surface); border: 1px solid var(--border);
    border-radius: 8px; padding: 16px; flex: 1; }
  .stat-card .label { color: var(--text-muted); font-size: 12px; text-transform: uppercase;
    letter-spacing: 0.5px; margin-bottom: 4px; }
  .stat-card .value { font-size: 28px; font-weight: 600; }
  .stat-card .sub { color: var(--text-muted); font-size: 13px; margin-top: 4px; }
  .mission-card { background: var(--surface); border: 1px solid var(--border);
    border-radius: 8px; padding: 20px; margin-bottom: 16px; }
  .mission-header { display: flex; justify-content: space-between; align-items: center;
    margin-bottom: 12px; }
  .mission-title { font-size: 18px; font-weight: 600; }
  .mission-id { color: var(--text-muted); font-size: 13px; font-family: monospace; }
  .status-badge { display: inline-block; padding: 2px 10px; border-radius: 12px;
    font-size: 12px; font-weight: 500; }
  .status-active { background: rgba(88,166,255,0.15); color: var(--blue); }
  .status-completed, .status-passed { background: rgba(63,185,80,0.15); color: var(--green); }
  .status-blocked, .status-paused { background: rgba(210,153,34,0.15); color: var(--yellow); }
  .status-failed { background: rgba(248,81,73,0.15); color: var(--red); }
  .status-planning, .status-pending { background: rgba(139,148,158,0.15); color: var(--text-muted); }
  .status-validating { background: rgba(188,140,255,0.15); color: var(--purple); }
  .progress-section { margin-top: 12px; }
  .progress-bar-container { background: var(--border); border-radius: 4px; height: 8px;
    overflow: hidden; margin: 6px 0; }
  .progress-bar-fill { height: 100%; border-radius: 4px; transition: width 0.3s ease; }
  .progress-bar-fill.green { background: var(--green); }
  .progress-bar-fill.blue { background: var(--blue); }
  .progress-bar-fill.yellow { background: var(--yellow); }
  .progress-bar-fill.red { background: var(--red); }
  .milestone-row { display: flex; align-items: center; gap: 12px; padding: 8px 0;
    border-bottom: 1px solid var(--border); }
  .milestone-row:last-child { border-bottom: none; }
  .milestone-name { flex: 1; font-size: 14px; }
  .milestone-progress { width: 200px; }
  .milestone-stats { color: var(--text-muted); font-size: 13px; min-width: 80px; text-align: right; }
  .budget-row { display: flex; justify-content: space-between; padding: 6px 0;
    font-size: 14px; border-bottom: 1px solid var(--border); }
  .budget-row:last-child { border-bottom: none; }
  .budget-label { color: var(--text-muted); }
  .no-missions { text-align: center; padding: 60px 20px; color: var(--text-muted); }
  .no-missions h2 { margin-bottom: 8px; }
</style>
</head>
<body>
<div class="header">
  <h1>Mission Progress Dashboard</h1>
  <span class="timestamp" id="timestamp"></span>
</div>
<div class="stats-row" id="stats-row"></div>
<div id="missions-container"></div>
<script>
HTMLEOF

	# Inject JSON data
	echo "const data = ${json_data};" >>"$output_file"

	cat >>"$output_file" <<'HTMLEOF2'
function statusClass(s) {
  s = (s || '').toLowerCase().replace(/\s+/g, '');
  const map = {active:'active',completed:'completed',passed:'passed',blocked:'blocked',
    paused:'paused',failed:'failed',planning:'planning',pending:'pending',validating:'validating'};
  return 'status-' + (map[s] || 'pending');
}
function progressColor(pct) {
  if (pct >= 100) return 'green';
  if (pct >= 60) return 'blue';
  if (pct >= 30) return 'yellow';
  return 'red';
}
function render() {
  document.getElementById('timestamp').textContent = new Date(data.timestamp).toLocaleString();
  const statsRow = document.getElementById('stats-row');
  const br = data.burn_rate || {};
  statsRow.innerHTML = `
    <div class="stat-card">
      <div class="label">Active Workers</div>
      <div class="value">${data.workers}/${data.max_workers}</div>
    </div>
    <div class="stat-card">
      <div class="label">Missions</div>
      <div class="value">${data.missions.length}</div>
      <div class="sub">${data.missions.filter(m=>m.status==='active').length} active</div>
    </div>
    <div class="stat-card">
      <div class="label">Today's Spend</div>
      <div class="value">$${(br.today_spend || 0).toFixed(2)}</div>
      <div class="sub">$${(br.hourly_rate || 0).toFixed(2)}/hr</div>
    </div>
    <div class="stat-card">
      <div class="label">Avg Daily</div>
      <div class="value">$${(br.avg_daily || 0).toFixed(2)}</div>
    </div>`;
  const container = document.getElementById('missions-container');
  if (data.missions.length === 0) {
    container.innerHTML = '<div class="no-missions"><h2>No missions found</h2><p>Create one with /mission</p></div>';
    return;
  }
  container.innerHTML = data.missions.map(m => {
    const pct = m.progress_pct || 0;
    const milestoneHtml = (m.milestones || []).map(ms => {
      const msPct = ms.total_features > 0 ? Math.round(ms.completed_features * 100 / ms.total_features) : 0;
      return `<div class="milestone-row">
        <span class="status-badge ${statusClass(ms.status)}">${ms.status}</span>
        <span class="milestone-name">M${ms.number}: ${ms.name}</span>
        <div class="milestone-progress">
          <div class="progress-bar-container">
            <div class="progress-bar-fill ${progressColor(msPct)}" style="width:${msPct}%"></div>
          </div>
        </div>
        <span class="milestone-stats">${ms.completed_features}/${ms.total_features} (${msPct}%)</span>
      </div>`;
    }).join('');
    return `<div class="mission-card">
      <div class="mission-header">
        <div>
          <span class="mission-title">${m.title}</span>
          <span class="mission-id">${m.id}</span>
        </div>
        <span class="status-badge ${statusClass(m.status)}">${m.status}</span>
      </div>
      <div class="progress-section">
        <div style="display:flex;justify-content:space-between;font-size:14px;color:var(--text-muted)">
          <span>Overall Progress</span>
          <span>${m.completed_features}/${m.total_features} features (${pct}%)</span>
        </div>
        <div class="progress-bar-container">
          <div class="progress-bar-fill ${progressColor(pct)}" style="width:${pct}%"></div>
        </div>
      </div>
      <div style="margin-top:16px">${milestoneHtml}</div>
    </div>`;
  }).join('');
}
render();
</script>
</body>
</html>
HTMLEOF2

	return 0
}

cmd_browser() {
	local mission_filter=""
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--mission | -m)
			mission_filter="${2:-}"
			shift 2
			;;
		*) shift ;;
		esac
	done

	mkdir -p "$DASHBOARD_HTML_DIR" 2>/dev/null || true
	local html_file="${DASHBOARD_HTML_DIR}/mission-dashboard.html"

	# Generate JSON data
	local json_data
	if [[ -n "$mission_filter" ]]; then
		json_data=$(cmd_json --mission "$mission_filter" 2>/dev/null)
	else
		json_data=$(cmd_json 2>/dev/null)
	fi

	if [[ -z "$json_data" || "$json_data" == "null" ]]; then
		print_error "Failed to generate dashboard data"
		return 1
	fi

	generate_html "$json_data" "$html_file"
	print_success "Dashboard generated: ${html_file}"

	# Try to open in browser
	if command -v xdg-open &>/dev/null; then
		xdg-open "$html_file" 2>/dev/null &
	elif command -v open &>/dev/null; then
		open "$html_file" 2>/dev/null &
	else
		print_info "Open in browser: file://${html_file}"
	fi
	return 0
}

# =============================================================================
# Help
# =============================================================================

cmd_help() {
	cat <<'EOF'
Mission Progress Dashboard (t1362)

Usage: mission-dashboard-helper.sh [command] [options]

Commands:
  status            Full CLI dashboard with progress bars and details
  summary           Compact one-line-per-mission overview
  json              Machine-readable JSON output
  browser           Generate HTML dashboard and open in browser
  help              Show this help

Options:
  --mission, -m ID  Filter to a specific mission (by ID or title substring)
  --verbose, -v     Show extra detail (active worker commands, blockers)

Examples:
  mission-dashboard-helper.sh status
  mission-dashboard-helper.sh status --verbose
  mission-dashboard-helper.sh status --mission m-20260227
  mission-dashboard-helper.sh json | jq '.missions[0].progress_pct'
  mission-dashboard-helper.sh browser
EOF
	return 0
}

# =============================================================================
# Main
# =============================================================================

main() {
	local command="${1:-status}"
	shift || true

	case "$command" in
	status | s | dashboard | dash) cmd_status "$@" ;;
	summary | sum | list | ls) cmd_summary "$@" ;;
	json | j) cmd_json "$@" ;;
	browser | html | web | open) cmd_browser "$@" ;;
	help | --help | -h) cmd_help ;;
	*)
		print_error "Unknown command: $command"
		cmd_help
		return 1
		;;
	esac
	return $?
}

main "$@"

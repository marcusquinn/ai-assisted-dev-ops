#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Profile README Render Library — Content Generation and Markdown Rendering
# =============================================================================
# Functions for rendering profile stats sections into markdown:
#   1. Apps     — macOS/Linux app name mapping and screen time section
#   2. Tables   — model usage table rendering with savings calculations
#   3. Generate — high-level section generators and cmd_generate entry point
#
# Usage: source "${SCRIPT_DIR}/profile-readme-render-lib.sh"
#        (Sourced automatically by profile-readme-helper.sh)
#
# Dependencies:
#   - profile-readme-data-lib.sh (format_*, cost_*, token_*, model usage)
#   - SCRIPT_DIR — set by orchestrator; this file provides a fallback
#   - sqlite3 (optional), jq
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_PROFILE_README_RENDER_LIB_LOADED:-}" ]] && return 0
_PROFILE_README_RENDER_LIB_LOADED=1

# Defensive SCRIPT_DIR fallback — needed when sourced from test harnesses
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

PROFILE_STATUS_UNAVAILABLE="unavailable"
PROFILE_BOOLEAN_TRUE="true"

# =============================================================================
# Apps — App Name Mapping and Screen Time Section
# =============================================================================

# --- Map bundle ID to friendly app name ---
_friendly_app_name() {
	local bundle="$1"
	case "$bundle" in
	# System apps
	com.apple.mail) echo "Mail" ;;
	com.apple.finder) echo "Finder" ;;
	com.apple.MobileSMS) echo "Messages" ;;
	com.apple.Photos) echo "Photos" ;;
	com.apple.Preview) echo "Preview" ;;
	com.apple.Safari) echo "Safari" ;;
	com.apple.iCal) echo "Calendar" ;;
	com.apple.systempreferences) echo "System Settings" ;;
	com.apple.AddressBook) echo "Contacts" ;;
	com.apple.Terminal) echo "Terminal" ;;
	com.apple.dt.Xcode) echo "Xcode" ;;
	com.apple.Notes) echo "Notes" ;;
	# Third-party apps
	org.tabby) echo "Tabby" ;;
	com.brave.Browser) echo "Brave Browser" ;;
	com.tinyspeck.slackmacgap) echo "Slack" ;;
	net.whatsapp.WhatsApp) echo "WhatsApp" ;;
	org.whispersystems.signal-desktop) echo "Signal" ;;
	com.spotify.client) echo "Spotify" ;;
	org.mozilla.firefox) echo "Firefox" ;;
	com.google.Chrome) echo "Chrome" ;;
	com.microsoft.VSCode) echo "VS Code" ;;
	com.canva.affinity) echo "Affinity" ;;
	org.libreoffice.script) echo "LibreOffice" ;;
	com.webcatalog.juli.facebook) echo "Facebook" ;;
	# Brave PWAs — extract from known mappings
	com.brave.Browser.app.mjoklplbddabcmpepnokjaffbmgbkkgg) echo "GitHub" ;;
	com.brave.Browser.app.lodlkdfmihgonocnmddehnfgiljnadcf) echo "X" ;;
	com.brave.Browser.app.agimnkijcaahngcdmfeangaknmldooml) echo "YouTube" ;;
	com.brave.Browser.app.imdajkchfecmmahjodnfnpihejhejdgo) echo "Amazon" ;;
	com.brave.Browser.app.ggjocahimgaohmigbfhghnlfcnjemagj) echo "Grok" ;;
	com.brave.Browser.app.mmkpebkcahljniimmcipdlmdonpnlild) echo "Nextcloud Talk" ;;
	com.brave.Browser.app.bkmlmojhimpoiaopgajnfcgdknkaklcc) echo "Nextcloud Talk 2" ;;
	com.brave.Browser.app.ohghonlafcimfigiajnmhdklcbjlbfda) echo "LinkedIn" ;;
	com.brave.Browser.app.akpamiohjfcnimfljfndmaldlcfphjmp) echo "Instagram" ;;
	com.brave.Browser.app.fmpnliohjhemenmnlpbfagaolkdacoja) echo "Claude" ;;
	com.brave.Browser.app.cadlkienfkclaiaibeoongdcgmdikeeg) echo "ChatGPT" ;;
	com.brave.Browser.app.gogeloecmlhfmifbfchpldmjclnfoiho) echo "Search Console" ;;
	com.brave.Browser.app.fbamlndehdinmdbhpcihcihhmjmmpgjn) echo "TradingView" ;;
	com.brave.Browser.app.fbjnhnmfhfifmkmokgjddadhphahbkpp) echo "Spaceship" ;;
	com.brave.Browser.app.mnhkaebcjjhencmpkapnbdaogjamfbcj) echo "Google Maps" ;;
	com.brave.Browser.app.kpmdbogdmbfckbgdfdffkleoleokbhod) echo "Perplexity" ;;
	com.brave.Browser.app.allndljdpmepdafjbbilonjhdgmlohlh) echo "X Pro" ;;
	com.brave.Browser.app.*)
		# Unknown Brave PWA — try to extract a readable suffix
		echo "Brave PWA"
		;;
	*)
		# Unknown — use last component of bundle ID
		local short
		short="${bundle##*.}"
		echo "$short"
		;;
	esac
	return 0
}

# --- Get top apps by screen time percentage (macOS only) ---
# Returns JSON array: [{"app":"Name","today_pct":N,"week_pct":N,"month_pct":N}, ...]
_get_top_apps() {
	local knowledge_db="${AIDEVOPS_KNOWLEDGE_DB:-${HOME}/Library/Application Support/Knowledge/knowledgeC.db}"

	if [[ "$(uname -s)" != "Darwin" ]] || [[ ! -f "$knowledge_db" ]]; then
		echo "[]"
		return 0
	fi

	local app_data
	app_data=$(python3 "${SCRIPT_DIR}/screen-time-interval-engine.py" apps \
		--os-type Darwin --db "$knowledge_db" 2>/dev/null) || app_data="[]"
	local app_rows=""
	local bundle today_pct week_pct month_pct name
	while IFS=$'\t' read -r bundle today_pct week_pct month_pct; do
		[[ -n "$bundle" ]] || continue
		name=$(_friendly_app_name "$bundle")
		app_rows="${app_rows}${name}	${today_pct:-0}	${week_pct:-0}	${month_pct:-0}"$'\n'
	done < <(printf '%s' "$app_data" | jq -r '.[] | [.bundle, .today_pct, .week_pct, .month_pct] | @tsv')

	printf '%s' "$app_rows" | jq -Rn '[inputs | split("\t") | {app: .[0], today_pct: (.[1] | tonumber), week_pct: (.[2] | tonumber), month_pct: (.[3] | tonumber)}]'
	return 0
}

# =============================================================================
# Tables — Model Usage Table Rendering
# =============================================================================

# --- Render a model usage table ---
# Usage: _render_model_usage_table <heading> <model_json> <token_totals_json>
# Outputs a markdown table with model usage, cache efficiency, and session totals.
_render_model_usage_table() {
	local heading="$1"
	local model_json="$2"
	local token_totals="$3"

	# Skip entirely if no model data
	local model_count
	model_count=$(echo "$model_json" | jq -r 'if type == "array" then [.[] | select((.requests // 0) > 0)] | length else 0 end' 2>/dev/null)
	if [[ "${model_count:-0}" == "0" ]]; then
		return 0
	fi

	local total_requests=0 total_input=0 total_output=0 total_cache=0
	local total_session_hours="0" session_hours_complete=true total_sessions=0
	local model_rows=""
	total_sessions=$(echo "$model_json" | jq -r '[.[] | .total_session_count // 0] | max // 0' 2>/dev/null || printf '0\n')
	if [[ "$total_sessions" -eq 0 ]]; then
		total_sessions=$(echo "$model_json" | jq -r '[.[] | .session_count // 0] | add // 0' 2>/dev/null || printf '0\n')
	fi

	while IFS= read -r row; do
		local model requests input output cache cache_write session_count session_hours
		model=$(echo "$row" | jq -r '.model')
		requests=$(echo "$row" | jq -r '.requests // 0')
		input=$(echo "$row" | jq -r '.input_tokens // 0')
		output=$(echo "$row" | jq -r '.output_tokens // 0')
		cache=$(echo "$row" | jq -r '.cache_read_tokens // 0')
		cache_write=$(echo "$row" | jq -r '.cache_write_tokens // 0')
		session_count=$(echo "$row" | jq -r '.session_count // 0')
		session_hours=$(echo "$row" | jq -r '.session_hours // empty')

		total_requests=$((total_requests + requests))
		total_input=$((total_input + input))
		total_output=$((total_output + output))
		total_cache=$((total_cache + cache))
		if [[ "$session_hours" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
			total_session_hours=$(echo "$total_session_hours + $session_hours" | bc)
		else
			session_hours_complete=false
		fi

		local clean_model cache_hit_pct
		clean_model=$(_clean_model_name "$model")
		cache_hit_pct=$(echo "$row" | jq -r '
			((.input_tokens // 0) + (.cache_read_tokens // 0)) as $total
			| if $total > 0 then (((.cache_read_tokens // 0) / $total * 1000 | round) / 10) else 0 end')
		local f_requests f_input f_output f_cache f_cache_hit f_session_count f_session_hours
		f_requests=$(_format_number "$requests")
		f_input=$(_format_tokens "$input")
		f_output=$(_format_tokens "$output")
		f_cache=$(_format_tokens "$cache")
		f_cache_hit=$(_format_hours "$cache_hit_pct")
		f_session_count=$(_format_number "$session_count")
		if [[ "$session_hours" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
			f_session_hours="$(_format_number "$(_format_hours "$session_hours")")h"
		else
			f_session_hours="—"
		fi

		model_rows="${model_rows}| ${clean_model} | ${f_requests} | ${f_input} | ${f_output} | ${f_cache} | ${f_cache_hit}% | ${f_session_count} | ${f_session_hours} |
"
	done < <(echo "$model_json" | jq -c 'sort_by(-(.requests // 0)) | .[] | select((.requests // 0) > 0)')

	# Format totals
	local f_total_req f_total_in f_total_out f_total_cache f_total_sessions f_total_session_hours
	f_total_req=$(_format_number "$total_requests")
	f_total_in=$(_format_tokens "$total_input")
	f_total_out=$(_format_tokens "$total_output")
	f_total_cache=$(_format_tokens "$total_cache")
	f_total_sessions=$(_format_number "$total_sessions")
	if [[ "$session_hours_complete" == true ]]; then
		f_total_session_hours="$(_format_number "$(_format_hours "$total_session_hours")")h"
	else
		f_total_session_hours="—"
	fi

	# Token totals for footer
	local all_tokens cache_pct
	all_tokens=$(echo "$token_totals" | jq -r '.total_all')
	cache_pct=$(echo "$token_totals" | jq -r '.cache_hit_pct')
	local f_all_tokens
	f_all_tokens=$(_format_tokens "$all_tokens")

	cat <<EOF

## ${heading}

| Model | Requests | Input | Output | Cache read | Cache Hit-Rate % | Session Count | Session Hours |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
${model_rows}| **Total** | **${f_total_req}** | **${f_total_in}** | **${f_total_out}** | **${f_total_cache}** | **${cache_pct}%** | **${f_total_sessions}** | **${f_total_session_hours}** |

_${f_all_tokens} total tokens processed. ${cache_pct}% cache hit rate._
EOF

	return 0
}

# =============================================================================
# Generate — Section Generators and cmd_generate Entry Point
# =============================================================================

# --- Extract and format session time variables for all periods ---
# Populates variables in the caller's scope via stdout as shell assignments.
# Usage: eval "$(_generate_session_time_vars <day_json> <week_json> <month_json> <year_json>)"
_generate_session_time_vars() {
	local day_json="$1"
	local week_json="$2"
	local month_json="$3"
	local year_json="$4"

	local day_human day_interactive_machine day_worker_human day_worker day_total day_interactive day_workers
	day_human=$(_format_hours "$(echo "$day_json" | jq -r '(.interactive_human_hours // 0)')")
	day_interactive_machine=$(_format_hours "$(echo "$day_json" | jq -r '(.interactive_machine_hours // 0)')")
	day_worker_human=$(_format_hours "$(echo "$day_json" | jq -r '(.worker_human_hours // 0)')")
	day_worker=$(_format_hours "$(echo "$day_json" | jq -r '(.worker_machine_hours // 0)')")
	day_total=$(_format_hours "$(echo "$day_json" | jq -r '(.total_human_hours // 0) + (.total_machine_hours // 0)')")
	# Keep counts raw here; _generate_work_with_ai_table formats them once.
	# Pre-formatting creates comma strings that _format_number later rejects as
	# non-numeric, turning 1,000+ session counts into 0.
	day_interactive=$(echo "$day_json" | jq -r '(.interactive_sessions // 0)')
	day_workers=$(echo "$day_json" | jq -r '(.worker_sessions // 0)')

	local week_human week_interactive_machine week_worker_human week_worker week_total week_interactive week_workers
	week_human=$(_format_hours "$(echo "$week_json" | jq -r '(.interactive_human_hours // 0)')")
	week_interactive_machine=$(_format_hours "$(echo "$week_json" | jq -r '(.interactive_machine_hours // 0)')")
	week_worker_human=$(_format_hours "$(echo "$week_json" | jq -r '(.worker_human_hours // 0)')")
	week_worker=$(_format_hours "$(echo "$week_json" | jq -r '(.worker_machine_hours // 0)')")
	week_total=$(_format_hours "$(echo "$week_json" | jq -r '(.total_human_hours // 0) + (.total_machine_hours // 0)')")
	week_interactive=$(echo "$week_json" | jq -r '(.interactive_sessions // 0)')
	week_workers=$(echo "$week_json" | jq -r '(.worker_sessions // 0)')

	local month_human month_interactive_machine month_worker_human month_worker month_total month_interactive month_workers
	month_human=$(_format_hours "$(echo "$month_json" | jq -r '(.interactive_human_hours // 0)')")
	month_interactive_machine=$(_format_hours "$(echo "$month_json" | jq -r '(.interactive_machine_hours // 0)')")
	month_worker_human=$(_format_hours "$(echo "$month_json" | jq -r '(.worker_human_hours // 0)')")
	month_worker=$(_format_hours "$(echo "$month_json" | jq -r '(.worker_machine_hours // 0)')")
	month_total=$(_format_hours "$(echo "$month_json" | jq -r '(.total_human_hours // 0) + (.total_machine_hours // 0)')")
	month_interactive=$(echo "$month_json" | jq -r '(.interactive_sessions // 0)')
	month_workers=$(echo "$month_json" | jq -r '(.worker_sessions // 0)')

	local year_human year_interactive_machine year_worker_human year_worker year_total year_interactive year_workers
	year_human=$(_format_hours "$(echo "$year_json" | jq -r '(.interactive_human_hours // 0)')")
	year_interactive_machine=$(_format_hours "$(echo "$year_json" | jq -r '(.interactive_machine_hours // 0)')")
	year_worker_human=$(_format_hours "$(echo "$year_json" | jq -r '(.worker_human_hours // 0)')")
	year_worker=$(_format_hours "$(echo "$year_json" | jq -r '(.worker_machine_hours // 0)')")
	year_total=$(_format_hours "$(echo "$year_json" | jq -r '(.total_human_hours // 0) + (.total_machine_hours // 0)')")
	year_interactive=$(echo "$year_json" | jq -r '(.interactive_sessions // 0)')
	year_workers=$(echo "$year_json" | jq -r '(.worker_sessions // 0)')

	# Emit as shell variable assignments for eval
	printf 'day_human=%q day_interactive_machine=%q day_worker_human=%q day_worker=%q day_total=%q day_interactive=%q day_workers=%q\n' \
		"$day_human" "$day_interactive_machine" "$day_worker_human" "$day_worker" "$day_total" "$day_interactive" "$day_workers"
	printf 'week_human=%q week_interactive_machine=%q week_worker_human=%q week_worker=%q week_total=%q week_interactive=%q week_workers=%q\n' \
		"$week_human" "$week_interactive_machine" "$week_worker_human" "$week_worker" "$week_total" "$week_interactive" "$week_workers"
	printf 'month_human=%q month_interactive_machine=%q month_worker_human=%q month_worker=%q month_total=%q month_interactive=%q month_workers=%q\n' \
		"$month_human" "$month_interactive_machine" "$month_worker_human" "$month_worker" "$month_total" "$month_interactive" "$month_workers"
	printf 'year_human=%q year_interactive_machine=%q year_worker_human=%q year_worker=%q year_total=%q year_interactive=%q year_workers=%q\n' \
		"$year_human" "$year_interactive_machine" "$year_worker_human" "$year_worker" "$year_total" "$year_interactive" "$year_workers"
	return 0
}

# --- Generate the Top Apps by Screen Time markdown section ---
# Outputs the full markdown block, or nothing if no app data available.
_generate_top_apps_section() {
	local top_apps_json
	top_apps_json=$(_get_top_apps)

	if ! printf '%s' "$top_apps_json" | jq -e 'length > 0' >/dev/null 2>&1; then
		return 0
	fi

	local app_rows
	app_rows=$(printf '%s' "$top_apps_json" | jq -r '
		def pct: if . == 0 then "--" else (tostring + "%") end;
		.[] | "| \(.app) | \(.today_pct | pct) | \(.week_pct | pct) | \(.month_pct | pct) |"
	')

	cat <<EOF

## Top Apps by Screen Time

| App | Yesterday | Prior 7 Days | Prior 28 Days |
| --- | ---: | ---: | ---: |
${app_rows}
_Top 10 apps by foreground time share across completed local calendar days. Mac only._
EOF
	return 0
}

# --- Generate the Work with AI markdown table ---
# Usage: _generate_work_with_ai_table <screen_json> <day_json> <week_json> <month_json> <year_json>
_generate_screen_time_vars() {
	local screen_json="$1"
	local values screen_today screen_week screen_month screen_year screen_status year_estimated screen_source
	if ! values=$(printf '%s' "$screen_json" | jq -er --arg unavailable "$PROFILE_STATUS_UNAVAILABLE" '
		if type != "object" then error("screen payload must be an object") else . end |
		[
			(if .today_hours == null then $unavailable else ((.today_hours * 10 | round / 10 | tostring) + "h") end),
			(if .week_hours == null then $unavailable else ((.week_hours * 10 | round / 10 | tostring) + "h") end),
			(if .month_hours == null then $unavailable else ((.month_hours * 10 | round / 10 | tostring) + "h") end),
			(if .year_hours == null then $unavailable else ((.year_hours | round | tostring) + "h") end),
			([.periods?.day?.status // $unavailable, .periods?.week?.status // $unavailable, .periods?.month?.status // $unavailable, .periods?.year?.status // $unavailable] | unique | join(", ")),
			(.periods?.year?.estimated // false),
			(.periods?.month?.source // $unavailable)
		] | @tsv
	'); then
		echo "Warning: screen-time payload is invalid; rendering unavailable values" >&2
		printf -v values '%s\t%s\t%s\t%s\t%s\tfalse\t%s' \
			"$PROFILE_STATUS_UNAVAILABLE" "$PROFILE_STATUS_UNAVAILABLE" "$PROFILE_STATUS_UNAVAILABLE" \
			"$PROFILE_STATUS_UNAVAILABLE" "$PROFILE_STATUS_UNAVAILABLE" "$PROFILE_STATUS_UNAVAILABLE"
	fi
	IFS=$'\t' read -r screen_today screen_week screen_month screen_year screen_status year_estimated screen_source <<<"$values"
	local year_prefix="" year_suffix=""
	if [[ "$year_estimated" == "$PROFILE_BOOLEAN_TRUE" ]]; then
		year_prefix="~"
		year_suffix="*"
	fi
	printf 'screen_today=%q screen_week=%q screen_month=%q screen_year=%q screen_status=%q screen_source=%q year_prefix=%q year_suffix=%q\n' \
		"$screen_today" "$screen_week" "$screen_month" "$screen_year" "$screen_status" "$screen_source" "$year_prefix" "$year_suffix"
	return 0
}

_generate_work_count_vars() {
	local day_interactive="$1" week_interactive="$2" month_interactive="$3" year_interactive="$4"
	local day_workers="$5" week_workers="$6" month_workers="$7" year_workers="$8"
	local month_total="$9"
	shift 9
	local year_total="$1"
	printf 'f_day_int=%q f_week_int=%q f_month_int=%q f_year_int=%q f_day_wrk=%q f_week_wrk=%q f_month_wrk=%q f_year_wrk=%q f_month_total=%q f_year_total=%q\n' \
		"$(_format_number "$day_interactive")" "$(_format_number "$week_interactive")" \
		"$(_format_number "$month_interactive")" "$(_format_number "$year_interactive")" \
		"$(_format_number "$day_workers")" "$(_format_number "$week_workers")" \
		"$(_format_number "$month_workers")" "$(_format_number "$year_workers")" \
		"$(_format_number "$month_total")" "$(_format_number "$year_total")"
	return 0
}

_period_unavailable_assignments() {
	local period_json="$1"
	shift
	if ! printf '%s' "$period_json" | jq -e --arg unavailable "$PROFILE_STATUS_UNAVAILABLE" '(.status // "ok") == $unavailable' >/dev/null 2>&1; then
		return 0
	fi
	local variable_name
	for variable_name in "$@"; do
		printf '%s=%q ' "$variable_name" "$PROFILE_STATUS_UNAVAILABLE"
	done
	printf '\n'
	return 0
}

_format_work_hour_cell() {
	local value="$1"
	if [[ "$value" == "$PROFILE_STATUS_UNAVAILABLE" ]]; then
		printf '%s' "$value"
	else
		printf '%sh' "$value"
	fi
	return 0
}

_profile_period_json() {
	local periods_json="$1"
	local period_key="$2"
	printf '%s' "$periods_json" | jq -c --arg key "$period_key" --arg unavailable "$PROFILE_STATUS_UNAVAILABLE" '.[$key] // {status:$unavailable}'
	return 0
}

_generate_work_with_ai_table() {
	local screen_json="$1"
	local day_json="$2"
	local week_json="$3"
	local month_json="$4"
	local year_json="$5"

	local screen_today screen_week screen_month screen_year screen_status screen_source year_prefix year_suffix
	eval "$(_generate_screen_time_vars "$screen_json")"

	# Extract and format session time variables for all periods
	local day_human day_interactive_machine day_worker_human day_worker day_total day_interactive day_workers
	local week_human week_interactive_machine week_worker_human week_worker week_total week_interactive week_workers
	local month_human month_interactive_machine month_worker_human month_worker month_total month_interactive month_workers
	local year_human year_interactive_machine year_worker_human year_worker year_total year_interactive year_workers
	eval "$(_generate_session_time_vars "$day_json" "$week_json" "$month_json" "$year_json")"

	local f_day_int f_week_int f_month_int f_year_int
	local f_day_wrk f_week_wrk f_month_wrk f_year_wrk
	local f_month_total f_year_total
	eval "$(_generate_work_count_vars "$day_interactive" "$week_interactive" "$month_interactive" "$year_interactive" \
		"$day_workers" "$week_workers" "$month_workers" "$year_workers" "$month_total" "$year_total")"

	# A failed collector is not a valid zero. Preserve legitimate zero values only
	# when the corresponding period explicitly reports status=ok.
	eval "$(_period_unavailable_assignments "$day_json" day_human day_interactive_machine day_worker_human day_worker day_total f_day_int f_day_wrk)"
	eval "$(_period_unavailable_assignments "$week_json" week_human week_interactive_machine week_worker_human week_worker week_total f_week_int f_week_wrk)"
	eval "$(_period_unavailable_assignments "$month_json" month_human month_interactive_machine month_worker_human month_worker f_month_total f_month_int f_month_wrk)"
	eval "$(_period_unavailable_assignments "$year_json" year_human year_interactive_machine year_worker_human year_worker f_year_total f_year_int f_year_wrk)"

	# Determine platform label for screen time row
	local os_type screen_label
	os_type="$(uname -s)"
	case "$os_type" in
	Darwin)
		screen_label="Screen time (Mac)"
		;;
	Linux)
		screen_label="Screen time (Linux)"
		;;
	*)
		screen_label="Screen time"
		;;
	esac

	local session_coverage_note=""
	local session_observed_days
	session_observed_days=$(echo "$year_json" | jq -r '(.observed_days // 0 | floor)')
	if [[ "$session_observed_days" =~ ^[0-9]+$ ]] &&
		[[ "$session_observed_days" -gt 0 && "$session_observed_days" -lt 330 ]]; then
		session_coverage_note=$'\n\n'"_AI session 365-day totals cover ${session_observed_days} days of local assistant session history (not extrapolated)._"
	fi

	cat <<EOF
## Work with AI

| Metric | Yesterday | Prior 7 Days | Prior 28 Days | Prior 365 Days |
| --- | ---: | ---: | ---: | ---: |
| ${screen_label} | ${screen_today} | ${screen_week} | ${screen_month} | ${year_prefix}${screen_year}${year_suffix} |
| Interactive human attention | $(_format_work_hour_cell "$day_human") | $(_format_work_hour_cell "$week_human") | $(_format_work_hour_cell "$month_human") | $(_format_work_hour_cell "$year_human") |
| Interactive AI generation | $(_format_work_hour_cell "$day_interactive_machine") | $(_format_work_hour_cell "$week_interactive_machine") | $(_format_work_hour_cell "$month_interactive_machine") | $(_format_work_hour_cell "$year_interactive_machine") |
| Worker-classified human attention | $(_format_work_hour_cell "$day_worker_human") | $(_format_work_hour_cell "$week_worker_human") | $(_format_work_hour_cell "$month_worker_human") | $(_format_work_hour_cell "$year_worker_human") |
| Worker/headless AI generation | $(_format_work_hour_cell "$day_worker") | $(_format_work_hour_cell "$week_worker") | $(_format_work_hour_cell "$month_worker") | $(_format_work_hour_cell "$year_worker") |
| Additive observed work | $(_format_work_hour_cell "$day_total") | $(_format_work_hour_cell "$week_total") | $(_format_work_hour_cell "$f_month_total") | $(_format_work_hour_cell "$f_year_total") |
| Interactive sessions | ${f_day_int} | ${f_week_int} | ${f_month_int} | ${f_year_int} |
| Worker sessions | ${f_day_wrk} | ${f_week_wrk} | ${f_month_wrk} | ${f_year_wrk} |

_Screen time from ${screen_source}; collection status: ${screen_status}.$([ -n "$year_suffix" ] && echo " *365-day estimate uses observed calendar coverage.")_

_Periods are completed local calendar days ending at midnight; today is excluded._

_Human attention is unioned wall-clock time, so overlapping sessions are not double-counted. AI generation is additive machine work across sessions; it is not wall-clock concurrency._${session_coverage_note}
EOF
	return 0
}

# --- Generate the stats markdown ---
cmd_generate() {
	# Gather all data
	local screen_json
	screen_json=$(_get_screen_time)

	local session_periods day_json week_json month_json year_json
	session_periods=$(_get_profile_session_times)
	day_json=$(_profile_period_json "$session_periods" "day")
	week_json=$(_profile_period_json "$session_periods" "week")
	month_json=$(_profile_period_json "$session_periods" "28d")
	year_json=$(_profile_period_json "$session_periods" "year")

	local model_usage_bundle model_json_30d model_json_all
	model_usage_bundle=$(_get_profile_model_usage_bundle)
	model_json_30d=$(printf '%s' "$model_usage_bundle" | jq -c '.recent // []')
	model_json_all=$(printf '%s' "$model_usage_bundle" | jq -c '.all // []')

	local token_totals_30d token_totals_all
	token_totals_30d=$(_token_totals_from_model_usage "$model_json_30d")
	token_totals_all=$(_token_totals_from_model_usage "$model_json_all")

	# Detect if there's any meaningful data to display.
	local has_data=false
	local has_session_time has_model_usage has_screen_time
	has_session_time=$(echo "$month_json" | jq -r '((.total_human_hours + .total_machine_hours) // 0) > 0')
	has_model_usage=$(echo "$model_json_all" | jq -r '((if type == "array" then length else 0 end) // 0) > 0')
	has_screen_time=$(echo "$screen_json" | jq -r '(.month_hours // 0) > 0')

	if [[ "$has_session_time" == "$PROFILE_BOOLEAN_TRUE" ]] ||
		[[ "$has_model_usage" == "$PROFILE_BOOLEAN_TRUE" ]] ||
		[[ "$has_screen_time" == "$PROFILE_BOOLEAN_TRUE" ]]; then
		has_data="$PROFILE_BOOLEAN_TRUE"
	fi

	if [[ "$has_data" != "$PROFILE_BOOLEAN_TRUE" ]]; then
		cat <<'EOF'
## Work with AI

_Stats will appear here automatically once [aidevops](https://aidevops.sh) has been running locally. Includes AI session hours, model usage, token costs, and screen time._
EOF
		return 0
	fi

	_generate_work_with_ai_table "$screen_json" "$day_json" "$week_json" "$month_json" "$year_json"
	_render_model_usage_table "AI Model Usage (last 30 days)" "$model_json_30d" "$token_totals_30d"
	_render_model_usage_table "AI Model Usage (all time)" "$model_json_all" "$token_totals_all"
	_generate_top_apps_section

	return 0
}

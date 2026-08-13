#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# campaign-helper.sh — _campaigns/ plane CLI surface (P2) + creative drafting (P5) + performance/learnings (P6)
#
# P2 commands (campaign lifecycle management):
#   campaign-helper.sh new <name> [--channel <ch>] [--repo <path>]
#       Scaffold _campaigns/active/<id>/ with brief.md + research/ + creative/
#       Campaign IDs auto-provisioned via sequential .campaign-counter (c001, c002, ...).
#   campaign-helper.sh list [--repo <path>]
#       Show all campaigns across active/, launched/, archive/ with status.
#   campaign-helper.sh status <id> [--repo <path>]
#       Detailed dossier for a campaign (brief + file inventory + lifecycle state).
#   campaign-helper.sh archive <id> [--repo <path>]
#       Move _campaigns/launched/<id>/ → archive/<id>/
#
# P5 commands (AI creative agent):
#   campaign-helper.sh draft <id> --channel <ch> [--tone <tone>] [--variant N] [--model <m>]
#       AI-generated content draft grounded in brief + brand + swipe context.
#       Channels: facebook, instagram, linkedin, twitter, email, blog.
#       Output: _campaigns/active/<id>/drafts/<channel>-v<N>.md
#       Human-gated: requires manual review before promotion to creative/.
#
# P6 commands (post-launch cross-plane integration):
#   campaign-helper.sh launch <id> [--repo <path>]
#       Move _campaigns/active/<id>/ → launched/<id>/, stamp dates,
#       create results.md + learnings.md templates.
#   campaign-helper.sh promote <id> [--results] [--learnings] [--repo <path>]
#       --results    Push metrics to _performance/marketing/<id>.md
#       --learnings  Promote insights to _knowledge/insights/marketing/<YYYY-MM>/<id>-learnings.md
#   campaign-helper.sh feedback [<id>] [--repo <path>]
#       Surface _feedback/ insights as campaign research input.
#       If <id> given, writes to _campaigns/active/<id>/research/feedback-insights.md
#   campaign-helper.sh help
#       Show this help.
#
# Prerequisites: _campaigns/ plane (P1 — t2962 #21250). Graceful error if absent.
#                ANTHROPIC_API_KEY for draft command (gopass or env var).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/shared-constants.sh"

init_log_file

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

readonly CAMPAIGNS_DIR_NAME="_campaigns"
readonly CAMPAIGNS_ACTIVE_DIR="active"
readonly CAMPAIGNS_LAUNCHED_DIR="launched"
readonly CAMPAIGNS_ARCHIVE_DIR="archive"
readonly CAMPAIGNS_COUNTER_FILE=".campaign-counter"
readonly CAMPAIGNS_BRIEF_FILE="brief.md"
readonly CAMPAIGNS_RESULTS_FILE="results.md"
readonly CAMPAIGNS_LEARNINGS_FILE="learnings.md"
readonly CAMPAIGNS_DRAFTS_DIR="drafts"
readonly CAMPAIGNS_INTAKE_FILE="intake.json"
readonly CAMPAIGNS_CHANNEL_SPECS="${SCRIPT_DIR}/../configs/campaign-channel-specs.json"
readonly CAMPAIGNS_VALID_CHANNELS="facebook instagram linkedin twitter reddit email blog"
readonly CAMPAIGN_RESEARCH_HELPER="${SCRIPT_DIR}/campaign-research-helper.py"
readonly CAMPAIGN_PRODUCTION_HELPER="${SCRIPT_DIR}/campaign-production-helper.py"
readonly CAMPAIGN_DISTRIBUTION_HELPER="${SCRIPT_DIR}/campaign-distribution-helper.py"

# ---------------------------------------------------------------------------
# Error helpers — centralise repeated messages to satisfy string-literal ratchet
# ---------------------------------------------------------------------------

_err_opt_unknown() {
	local _o="${1:-}"
	print_error "Unknown option: ${_o}"
	return 1
}

_err_active_not_found() {
	local campaign_id="${1:-}"
	print_error "Active campaign not found: ${campaign_id}"
	return 0
}

_print_next_steps() {
	echo "Next steps:"
	return 0
}

_err_results_missing() {
	local results_file="${1:-}"
	print_error "results.md not found — fill it in first: ${results_file}"
	return 1
}

_err_learnings_missing() {
	local learnings_file="${1:-}"
	print_error "learnings.md not found — fill it in first: ${learnings_file}"
	return 1
}

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

_resolve_campaigns_dir() {
	local repo_path="${1:-$(pwd)}"
	echo "${repo_path}/${CAMPAIGNS_DIR_NAME}"
	return 0
}

_require_campaigns_plane() {
	local campaigns_dir="$1"
	if [[ ! -d "$campaigns_dir" ]]; then
		print_error "_campaigns/ plane not found at: ${campaigns_dir}"
		print_error "Run 'aidevops campaign init' first (requires P1 to be deployed)."
		return 1
	fi
	return 0
}

_require_launched_campaign() {
	local campaigns_dir="$1" campaign_id="$2"
	local launched_dir="${campaigns_dir}/${CAMPAIGNS_LAUNCHED_DIR}/${campaign_id}"
	if [[ ! -d "$launched_dir" ]]; then
		print_error "Launched campaign not found: ${campaign_id}"
		print_error "Path checked: ${launched_dir}"
		print_error "Run: aidevops campaign launch ${campaign_id}"
		return 1
	fi
	echo "$launched_dir"
	return 0
}

_require_campaign_production_eligibility() {
	local campaign_dir="$1"
	if [[ ! -f "$CAMPAIGN_PRODUCTION_HELPER" ]]; then
		print_error "Campaign production helper not found: ${CAMPAIGN_PRODUCTION_HELPER}"
		return 1
	fi
	python3 "$CAMPAIGN_PRODUCTION_HELPER" eligibility "$campaign_dir"
	return $?
}

_current_ym() {
	date -u '+%Y-%m'
	return 0
}

_current_date() {
	date -u '+%Y-%m-%d'
	return 0
}

# Slugify a human name into a lowercase-hyphen slug (ASCII-safe, no jq needed)
_slugify() {
	local input="${1:-}"
	# lowercase, replace non-alphanumeric runs with hyphens, strip leading/trailing hyphens
	local slug
	slug="$(printf '%s' "$input" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed 's/^-//;s/-$//')"
	echo "$slug"
	return 0
}

# Allocate the next campaign ID from .campaign-counter (c001, c002, ...)
# Writes the incremented counter back. Creates the counter file at 0 if absent.
_next_campaign_id() {
	local campaigns_dir="$1"
	local counter_file="${campaigns_dir}/${CAMPAIGNS_COUNTER_FILE}"
	local current=0
	if [[ -f "$counter_file" ]]; then
		current="$(cat "$counter_file" 2>/dev/null || echo "0")"
		[[ "$current" =~ ^[0-9]+$ ]] || current=0
	fi
	local next=$((current + 1))
	printf '%d' "$next" >"$counter_file"
	printf 'c%03d' "$next"
	return 0
}

_read_validated_intake() {
	local intake_file="${1:-}" json_array='array' json_object='object' json_string='string'
	local approved='approved' pending='pending' rejected='rejected' required='required'
	if [[ -z "$intake_file" || ! -f "$intake_file" ]]; then
		print_error "Campaign intake file not found: ${intake_file:-missing --intake <file>}"
		return 1
	fi
	if ! jq empty "$intake_file" 2>/dev/null; then
		print_error "Campaign intake must be valid JSON: ${intake_file}"
		return 1
	fi
	if ! jq -e --arg json_array "$json_array" --arg json_object "$json_object" --arg json_string "$json_string" --arg approved "$approved" --arg pending "$pending" --arg rejected "$rejected" --arg required "$required" '
		type == $json_object and .schema_version == 1 and
		(.brand | type == $json_object) and (.brand.name | type == $json_string and length > 0) and (.brand.reference | type == $json_string and test("^(context/brand-identity\\.toon|DESIGN\\.md|_campaigns/lib/brand/)")) and
		(.product | type == $json_object) and (.product.name | type == $json_string and length > 0) and (.product.description | type == $json_string and length > 0) and
		(.offer | type == $json_object) and (.offer.summary | type == $json_string and length > 0) and (.offer.terms | type == $json_string and length > 0) and
		(.objectives | type == $json_array and length > 0) and (.audiences | type == $json_array and length > 0) and
		(.positioning | type == $json_object) and (.positioning.statement | type == $json_string and length > 0) and (.proof | type == $json_array and length > 0) and
		(all(.proof[]; type == $json_object and (.claim | type == $json_string and length > 0) and (.evidence_reference | type == $json_string and length > 0 and test("^(?!/)(?!~)(?!.*(^|/)\\.\\.(/|$)).+")) and (.approval_status | IN($approved, $pending, $rejected)))) and
		(.channels | type == $json_array and length > 0 and all(.[]; IN("facebook", "instagram", "linkedin", "twitter", "reddit", "email", "blog"))) and
		(.dates | type == $json_object) and (.dates.start | type == $json_string and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$")) and (.dates.end | type == $json_string and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$")) and .dates.start <= .dates.end and
		(.kpis | type == $json_array and length > 0) and (.disclosures | type == $json_array) and (.sensitivity | IN("public", "internal", "sensitive")) and
		(.approvals | type == $json_object) and (.approvals.owner | type == $json_string and length > 0) and (.approvals.claims | IN($approved, $pending, $required)) and (.approvals.creative | IN($approved, $pending, $required))
	' "$intake_file" >/dev/null 2>&1; then
		print_error "Invalid campaign intake: missing required fields or unsafe claim evidence. See .agents/schemas/campaign-intake.schema.json."
		return 1
	fi
	jq -S -c . "$intake_file"
	return 0
}

_render_campaign_brief() {
	local intake="$1" campaign_id="$2" created="$3" separator=', '
	local brand_name brand_reference product_name product_description offer_summary offer_terms positioning
	local objectives audiences proof channels dates kpis disclosures approval_owner claims_approval creative_approval sensitivity
	brand_name="$(jq -r '.brand.name' <<<"$intake")"
	brand_reference="$(jq -r '.brand.reference' <<<"$intake")"
	product_name="$(jq -r '.product.name' <<<"$intake")"
	product_description="$(jq -r '.product.description' <<<"$intake")"
	offer_summary="$(jq -r '.offer.summary' <<<"$intake")"
	offer_terms="$(jq -r '.offer.terms' <<<"$intake")"
	positioning="$(jq -r '.positioning.statement' <<<"$intake")"
	objectives="$(_format_intake_metrics "$intake" objectives)"
	audiences="$(jq -r --arg separator "$separator" '.audiences | map("- **\(.segment):** buying roles — \(.buying_roles | join($separator))") | join("\n")' <<<"$intake")"
	proof="$(jq -r '.proof | map("- **\(.approval_status):** \(.claim) — evidence: `\(.evidence_reference)`") | join("\n")' <<<"$intake")"
	channels="$(jq -r --arg separator "$separator" '.channels | join($separator)' <<<"$intake")"
	dates="$(jq -r '.dates | "\(.start) to \(.end)"' <<<"$intake")"
	kpis="$(_format_intake_metrics "$intake" kpis)"
	disclosures="$(jq -r '.disclosures | if length == 0 then "None specified" else join("; ") end' <<<"$intake")"
	approval_owner="$(jq -r '.approvals.owner' <<<"$intake")"
	claims_approval="$(jq -r '.approvals.claims' <<<"$intake")"
	creative_approval="$(jq -r '.approvals.creative' <<<"$intake")"
	sensitivity="$(jq -r '.sensitivity' <<<"$intake")"
	cat <<BRIEF
# Campaign Brief: ${campaign_id}

**Intake schema:** v1
**Created:** ${created}
**Status:** active
**Sensitivity:** ${sensitivity}

## Brand and product

**Brand:** ${brand_name}
**Canonical brand reference:** \`${brand_reference}\`
**Product:** ${product_name}

${product_description}

## Offer and positioning

**Offer:** ${offer_summary}
**Terms:** ${offer_terms}

${positioning}

## Objectives and audiences

${objectives}

${audiences}

## Proof-linked claims

${proof}

## Channels, dates, and KPIs

**Channels:** ${channels}
**Dates:** ${dates}

${kpis}

## Disclosures and approvals

**Disclosures:** ${disclosures}
**Approval owner:** ${approval_owner}
**Claims approval:** ${claims_approval}
**Creative approval:** ${creative_approval}

<!-- CAMPAIGN_INTAKE_JSON_V1
${intake}
-->
BRIEF
	return 0
}

_format_intake_metrics() {
	local intake="$1" field="$2"
	jq -r --arg field "$field" '.[$field] | map("- **\(.metric):** \(.target)") | join("\n")' <<<"$intake"
	return 0
}

_write_intake_atomically() {
	local campaign_dir="$1" intake="$2" campaign_id="$3" created="$4" intake_tmp='' brief_tmp=''
	intake_tmp="$(mktemp "${campaign_dir}/.intake.XXXXXX")" || return 1
	brief_tmp="$(mktemp "${campaign_dir}/.brief.XXXXXX")" || { rm -f "$intake_tmp"; return 1; }
	printf '%s\n' "$intake" > "$intake_tmp"
	if ! _render_campaign_brief "$intake" "$campaign_id" "$created" > "$brief_tmp"; then
		rm -f "$intake_tmp" "$brief_tmp"
		print_error "Unable to render campaign brief; no existing brief was replaced."
		return 1
	fi
	mv "$intake_tmp" "${campaign_dir}/${CAMPAIGNS_INTAKE_FILE}"
	mv "$brief_tmp" "${campaign_dir}/${CAMPAIGNS_BRIEF_FILE}"
	return 0
}

_find_matching_intake() {
	local active_base="$1" intake="$2" candidate existing
	for candidate in "$active_base"/*; do
		[[ -f "${candidate}/${CAMPAIGNS_INTAKE_FILE}" ]] || continue
		existing="$(jq -S -c . "${candidate}/${CAMPAIGNS_INTAKE_FILE}" 2>/dev/null || true)"
		if [[ "$existing" == "$intake" ]]; then
			basename "$candidate"
			return 0
		fi
	done
	return 1
}

# ---------------------------------------------------------------------------
# cmd_new — scaffold active/<id>/ directory + brief.md
# ---------------------------------------------------------------------------

cmd_new() {
	local name='' channel='' intake_file='' repo_path=''

	while [[ $# -gt 0 ]]; do
		local _cur="${1:-}" _nxt="${2:-}"
		case "$_cur" in
		--channel) channel="$_nxt"; shift 2 ;;
		--intake) intake_file="$_nxt"; shift 2 ;;
		--repo) repo_path="$_nxt"; shift 2 ;;
		-*) _err_opt_unknown "$_cur"; return 1 ;;
		*) name="$_cur"; shift ;;
		esac
	done

	[[ -z "$name" ]] && { print_error "Usage: campaign new <name> --intake <file> [--channel <ch>]"; return 1; }
	[[ -z "$repo_path" ]] && repo_path="$(pwd)"
	local intake
	intake="$(_read_validated_intake "$intake_file")" || return 1
	if [[ -n "$channel" ]] && ! jq -e --arg channel "$channel" '.channels | index($channel) != null' <<<"$intake" >/dev/null; then
		print_error "Channel must be declared by intake: ${channel}"
		return 1
	fi

	local campaigns_dir
	campaigns_dir="$(_resolve_campaigns_dir "$repo_path")"
	_require_campaigns_plane "$campaigns_dir" || return 1

	local active_base="${campaigns_dir}/${CAMPAIGNS_ACTIVE_DIR}"
	mkdir -p "$active_base"
	local existing_id
	if existing_id="$(_find_matching_intake "$active_base" "$intake")"; then
		print_success "Campaign already exists for this intake: ${existing_id}"
		return 0
	fi

	local slug
	slug="$(_slugify "$name")"
	local campaign_id
	campaign_id="$(_next_campaign_id "$campaigns_dir")"
	local dir_name="${campaign_id}-${slug}"
	local campaign_dir="${active_base}/${dir_name}"

	if [[ -d "$campaign_dir" ]]; then
		print_error "Campaign directory already exists: ${campaign_dir}"
		return 1
	fi

	local created
	created="$(_current_date)"
	local staging_dir
	staging_dir="$(mktemp -d "${active_base}/.campaign.XXXXXX")" || return 1
	mkdir -p "${staging_dir}/research" "${staging_dir}/creative"
	[[ -n "$channel" ]] && mkdir -p "${staging_dir}/distribution/${channel}"
	if ! _write_intake_atomically "$staging_dir" "$intake" "$dir_name" "$created"; then
		rm -rf "$staging_dir"
		return 1
	fi
	mv "$staging_dir" "$campaign_dir"

	print_success "Campaign created: ${dir_name}"
	echo "  Path:    ${campaign_dir}"
	echo "  Brief:   ${campaign_dir}/${CAMPAIGNS_BRIEF_FILE}"
	local channel_summary
	channel_summary="$(jq -r --arg separator ', ' '.channels | join($separator)' <<<"$intake")"
	echo "  Channels: ${channel_summary}"
	echo ""
	_print_next_steps
	echo "  1. Edit brief:   ${campaign_dir}/${CAMPAIGNS_BRIEF_FILE}"
	echo "  2. Status:       aidevops campaign status ${dir_name}"
	echo "  3. Launch:       aidevops campaign launch ${dir_name}"
	return 0
}

cmd_update_intake() {
	local command_name="${1:-update}" campaign_id='' intake_file='' repo_path=''
	shift || true
	while [[ $# -gt 0 ]]; do
		local _cur="${1:-}" _nxt="${2:-}"
		case "$_cur" in
		--intake) intake_file="$_nxt"; shift 2 ;;
		--repo) repo_path="$_nxt"; shift 2 ;;
		-*) _err_opt_unknown "$_cur"; return 1 ;;
		*) campaign_id="$_cur"; shift ;;
		esac
	done
	[[ -n "$campaign_id" && -n "$intake_file" ]] || { print_error "Usage: campaign ${command_name} <id> --intake <file> [--repo <path>]"; return 1; }
	[[ -z "$repo_path" ]] && repo_path="$(pwd)"
	local intake campaigns_dir campaign_dir created
	intake="$(_read_validated_intake "$intake_file")" || return 1
	campaigns_dir="$(_resolve_campaigns_dir "$repo_path")"
	_require_campaigns_plane "$campaigns_dir" || return 1
	campaign_dir="${campaigns_dir}/${CAMPAIGNS_ACTIVE_DIR}/${campaign_id}"
	[[ -d "$campaign_dir" ]] || { _err_active_not_found "$campaign_id"; return 1; }
	if [[ "$command_name" == "update" && ! -f "${campaign_dir}/${CAMPAIGNS_INTAKE_FILE}" ]]; then
		print_error "Legacy brief detected. Migrate explicitly: aidevops campaign migrate ${campaign_id} --intake <file>"
		return 1
	fi
	created="$(_current_date)"
	_write_intake_atomically "$campaign_dir" "$intake" "$campaign_id" "$created" || return 1
	print_success "Campaign intake ${command_name}d: ${campaign_id}"
	return 0
}

cmd_update() { cmd_update_intake update "$@"; return $?; }
cmd_migrate() { cmd_update_intake migrate "$@"; return $?; }

# ---------------------------------------------------------------------------
# _list_campaigns_in — enumerate campaigns in a phase directory
# ---------------------------------------------------------------------------

_list_campaigns_in() {
	local campaigns_dir="$1" phase="$2"
	local phase_dir="${campaigns_dir}/${phase}"
	[[ ! -d "$phase_dir" ]] && return 0

	local found=false
	local item
	for item in "${phase_dir}"/*/; do
		[[ -d "$item" ]] || continue
		found=true
		local id
		id="$(basename "$item")"
		local brief_file="${item}${CAMPAIGNS_BRIEF_FILE}"
		local channel='' created=''
		if [[ -f "$brief_file" ]]; then
			channel="$(grep -m1 '^\*\*Channel:\*\*' "$brief_file" 2>/dev/null | sed 's/\*\*Channel:\*\* *//' || true)"
			created="$(grep -m1 '^\*\*Created:\*\*' "$brief_file" 2>/dev/null | sed 's/\*\*Created:\*\* *//' || true)"
		fi
		printf '  %-10s  %-32s  %-14s  %s\n' "[$phase]" "$id" "${channel:-—}" "${created:-—}"
	done
	[[ "$found" == false ]] && return 0
	return 0
}

# ---------------------------------------------------------------------------
# cmd_list — show all campaigns across phases
# ---------------------------------------------------------------------------

cmd_list() {
	local repo_path=''

	while [[ $# -gt 0 ]]; do
		local _cur="${1:-}" _nxt="${2:-}"
		case "$_cur" in
		--repo) repo_path="$_nxt"; shift 2 ;;
		-*) _err_opt_unknown "$_cur"; return 1 ;;
		*) shift ;;
		esac
	done

	[[ -z "$repo_path" ]] && repo_path="$(pwd)"

	local campaigns_dir
	campaigns_dir="$(_resolve_campaigns_dir "$repo_path")"
	_require_campaigns_plane "$campaigns_dir" || return 1

	printf '  %-10s  %-32s  %-14s  %s\n' "Phase" "ID" "Channel" "Created"
	printf '  %s\n' "-----------------------------------------------------------------------"
	_list_campaigns_in "$campaigns_dir" "$CAMPAIGNS_ACTIVE_DIR"
	_list_campaigns_in "$campaigns_dir" "$CAMPAIGNS_LAUNCHED_DIR"
	_list_campaigns_in "$campaigns_dir" "$CAMPAIGNS_ARCHIVE_DIR"
	return 0
}

# ---------------------------------------------------------------------------
# cmd_status — detailed dossier for a single campaign
# ---------------------------------------------------------------------------

cmd_status() {
	local campaign_id='' repo_path=''

	while [[ $# -gt 0 ]]; do
		local _cur="${1:-}" _nxt="${2:-}"
		case "$_cur" in
		--repo) repo_path="$_nxt"; shift 2 ;;
		-*) _err_opt_unknown "$_cur"; return 1 ;;
		*) campaign_id="$_cur"; shift ;;
		esac
	done

	[[ -z "$campaign_id" ]] && { print_error "Usage: campaign status <id>"; return 1; }
	[[ -z "$repo_path" ]] && repo_path="$(pwd)"

	local campaigns_dir
	campaigns_dir="$(_resolve_campaigns_dir "$repo_path")"
	_require_campaigns_plane "$campaigns_dir" || return 1

	# Locate the campaign across all phases
	local campaign_dir='' phase=''
	local p
	for p in "$CAMPAIGNS_ACTIVE_DIR" "$CAMPAIGNS_LAUNCHED_DIR" "$CAMPAIGNS_ARCHIVE_DIR"; do
		local candidate="${campaigns_dir}/${p}/${campaign_id}"
		if [[ -d "$candidate" ]]; then
			campaign_dir="$candidate"
			phase="$p"
			break
		fi
	done

	if [[ -z "$campaign_dir" ]]; then
		print_error "Campaign not found: ${campaign_id}"
		print_error "Searched: active/, launched/, archive/"
		return 1
	fi

	print_info "Campaign: ${campaign_id}  [${phase}]"
	echo "  Path: ${campaign_dir}"
	echo ""

	local brief_file="${campaign_dir}/${CAMPAIGNS_BRIEF_FILE}"
	if [[ -f "$brief_file" ]]; then
		echo "--- Brief ---"
		cat "$brief_file"
		echo ""
	fi

	echo "--- Files ---"
	find "$campaign_dir" -type f | sort | while read -r f; do
		echo "  ${f#"$campaign_dir"/}"
	done
	return 0
}

# ---------------------------------------------------------------------------
# cmd_archive — move launched/<id> → archive/<id>
# ---------------------------------------------------------------------------

cmd_archive() {
	local campaign_id='' repo_path=''

	while [[ $# -gt 0 ]]; do
		local _cur="${1:-}" _nxt="${2:-}"
		case "$_cur" in
		--repo) repo_path="$_nxt"; shift 2 ;;
		-*) _err_opt_unknown "$_cur"; return 1 ;;
		*) campaign_id="$_cur"; shift ;;
		esac
	done

	[[ -z "$campaign_id" ]] && { print_error "Usage: campaign archive <id>"; return 1; }
	[[ -z "$repo_path" ]] && repo_path="$(pwd)"

	local campaigns_dir
	campaigns_dir="$(_resolve_campaigns_dir "$repo_path")"
	_require_campaigns_plane "$campaigns_dir" || return 1

	local launched_dir="${campaigns_dir}/${CAMPAIGNS_LAUNCHED_DIR}/${campaign_id}"
	if [[ ! -d "$launched_dir" ]]; then
		print_error "Launched campaign not found: ${campaign_id}"
		print_error "Path checked: ${launched_dir}"
		print_error "Only launched campaigns can be archived."
		return 1
	fi

	local archive_base="${campaigns_dir}/${CAMPAIGNS_ARCHIVE_DIR}"
	mkdir -p "$archive_base"
	local archive_dir="${archive_base}/${campaign_id}"

	if [[ -d "$archive_dir" ]]; then
		print_error "Campaign already archived: ${campaign_id}"
		print_error "Archived path exists: ${archive_dir}"
		return 1
	fi

	local archived_date
	archived_date="$(_current_date)"

	# Move launched → archive (git-aware)
	if command -v git >/dev/null 2>&1 && git -C "$repo_path" rev-parse --git-dir >/dev/null 2>&1; then
		git -C "$repo_path" mv "$launched_dir" "$archive_dir" 2>/dev/null || mv "$launched_dir" "$archive_dir"
	else
		mv "$launched_dir" "$archive_dir"
	fi

	# Stamp archived date
	printf '%s\n' "$archived_date" > "${archive_dir}/archived.stamp"

	print_success "Campaign archived: ${campaign_id}"
	echo "  Archive path: ${archive_dir}"
	echo "  Archived:     ${archived_date}"
	return 0
}

# ---------------------------------------------------------------------------
# cmd_launch — move active/<id> → launched/<id>, stamp, create templates
# ---------------------------------------------------------------------------

_write_results_fallback() {
	local dest="$1" campaign_id="$2" launched_date="$3"
	cat >"$dest" <<RESULTS
# Campaign Results: ${campaign_id}

**Launched:** ${launched_date}
**Status:** in-progress

## Metrics

| Metric | Value |
|--------|-------|
| Impressions | |
| Clicks | |
| CTR (%) | |
| Conversions | |
| Cost | |
| Revenue / Value | |
| ROI | |

## Channel Breakdown

| Channel | Impressions | Clicks | Conversions | Cost |
|---------|-------------|--------|-------------|------|
| | | | | |

## Audience Highlights

<!-- Key audience segments that over- or under-performed expectations. -->

## Summary

<!-- Brief narrative of the campaign performance. What happened, what mattered. -->

---

_Promote with: \`aidevops campaign promote ${campaign_id} --results\`_
RESULTS
	return 0
}

_write_learnings_fallback() {
	local dest="$1" campaign_id="$2" launched_date="$3"
	cat >"$dest" <<LEARNINGS
# Campaign Learnings: ${campaign_id}

**Launched:** ${launched_date}
**Reviewed:** 

## What Worked

<!-- Creative, targeting, or channel elements that performed well. -->

## What Didn't Work

<!-- Underperformers and their likely root causes. -->

## Audience Insights

<!-- Unexpected audience segments, behaviours, or engagement patterns. -->

## Channel Insights

<!-- Platform-specific observations: algorithmic changes, creative fatigue, format preferences. -->

## Recommendations for Next Campaign

1. 
2. 
3. 

## Open Questions

<!-- Hypotheses needing more data. Experiments to run next time. -->

---

_Promote with: \`aidevops campaign promote ${campaign_id} --learnings\`_
LEARNINGS
	return 0
}

cmd_launch() {
	local campaign_id='' repo_path=''

	while [[ $# -gt 0 ]]; do
		local _cur="${1:-}" _nxt="${2:-}"
		case "$_cur" in
		--repo) repo_path="$_nxt"; shift 2 ;;
		-*) _err_opt_unknown "$_cur"; return 1 ;;
		*) campaign_id="$_cur"; shift ;;
		esac
	done

	[[ -z "$campaign_id" ]] && { print_error "Usage: campaign launch <id>"; return 1; }
	[[ -z "$repo_path" ]] && repo_path="$(pwd)"

	local campaigns_dir
	campaigns_dir="$(_resolve_campaigns_dir "$repo_path")"
	_require_campaigns_plane "$campaigns_dir" || return 1

	local active_dir="${campaigns_dir}/${CAMPAIGNS_ACTIVE_DIR}/${campaign_id}"
	if [[ ! -d "$active_dir" ]]; then
		_err_active_not_found "$campaign_id"
		print_error "Path checked: ${active_dir}"
		return 1
	fi
	_require_campaign_production_eligibility "$active_dir" || return 1

	local launched_base="${campaigns_dir}/${CAMPAIGNS_LAUNCHED_DIR}"
	mkdir -p "$launched_base"
	local launched_dir="${launched_base}/${campaign_id}"

	if [[ -d "$launched_dir" ]]; then
		print_error "Campaign already launched: ${campaign_id}"
		print_error "Launched path exists: ${launched_dir}"
		return 1
	fi

	local launch_date
	launch_date="$(_current_date)"

	# Move active → launched (git-aware)
	if command -v git >/dev/null 2>&1 && git -C "$repo_path" rev-parse --git-dir >/dev/null 2>&1; then
		git -C "$repo_path" mv "$active_dir" "$launched_dir" 2>/dev/null || mv "$active_dir" "$launched_dir"
	else
		mv "$active_dir" "$launched_dir"
	fi

	# Stamp launch date
	printf '%s\n' "$launch_date" > "${launched_dir}/launched.stamp"

	# Create results.md and learnings.md templates (P6 deliverable)
	local results_file="${launched_dir}/${CAMPAIGNS_RESULTS_FILE}"
	local learnings_file="${launched_dir}/${CAMPAIGNS_LEARNINGS_FILE}"

	[[ ! -f "$results_file" ]] && _write_results_fallback "$results_file" "$campaign_id" "$launch_date"
	[[ ! -f "$learnings_file" ]] && _write_learnings_fallback "$learnings_file" "$campaign_id" "$launch_date"

	print_success "Campaign launched: ${campaign_id}"
	echo "  Launched path:   ${launched_dir}"
	echo "  Results:         ${results_file}"
	echo "  Learnings:       ${learnings_file}"
	echo ""
	_print_next_steps
	echo "  1. Fill in ${CAMPAIGNS_RESULTS_FILE} with post-launch metrics"
	echo "  2. Run: aidevops campaign promote ${campaign_id} --results"
	echo "  3. Fill in ${CAMPAIGNS_LEARNINGS_FILE} with retrospective insights"
	echo "  4. Run: aidevops campaign promote ${campaign_id} --learnings"
	return 0
}

# ---------------------------------------------------------------------------
# Promote sub-helpers — cross-plane write functions
# ---------------------------------------------------------------------------

_promote_results() {
	local launched_dir="$1" campaign_id="$2" repo_path="$3"
	local results_file="${launched_dir}/${CAMPAIGNS_RESULTS_FILE}"
	[[ ! -f "$results_file" ]] && { _err_results_missing "$results_file"; return 1; }

	local perf_dir="${repo_path}/_performance/marketing"
	mkdir -p "$perf_dir"
	local dest="${perf_dir}/${campaign_id}.md"
	cp "$results_file" "$dest"
	print_success "Promoted results to: ${dest}"
	return 0
}

_promote_learnings() {
	local launched_dir="$1" campaign_id="$2" repo_path="$3"
	local learnings_file="${launched_dir}/${CAMPAIGNS_LEARNINGS_FILE}"
	[[ ! -f "$learnings_file" ]] && { _err_learnings_missing "$learnings_file"; return 1; }

	local ym
	ym="$(_current_ym)"
	local insights_dir="${repo_path}/_knowledge/insights/marketing/${ym}"
	mkdir -p "$insights_dir"
	local dest="${insights_dir}/${campaign_id}-learnings.md"
	cp "$learnings_file" "$dest"
	print_success "Promoted learnings to: ${dest}"
	return 0
}

# ---------------------------------------------------------------------------
# cmd_promote — cross-plane promotion dispatcher
# ---------------------------------------------------------------------------

cmd_promote() {
	local campaign_id='' repo_path='' do_results=false do_learnings=false

	while [[ $# -gt 0 ]]; do
		local _cur="${1:-}" _nxt="${2:-}"
		case "$_cur" in
		--results) do_results=true; shift ;;
		--learnings) do_learnings=true; shift ;;
		--repo) repo_path="$_nxt"; shift 2 ;;
		-*) _err_opt_unknown "$_cur"; return 1 ;;
		*) campaign_id="$_cur"; shift ;;
		esac
	done

	if [[ -z "$campaign_id" ]]; then
		print_error "Usage: campaign promote <id> [--results] [--learnings]"
		return 1
	fi
	if [[ "$do_results" == false && "$do_learnings" == false ]]; then
		print_error "Specify at least one of: --results, --learnings"
		return 1
	fi
	[[ -z "$repo_path" ]] && repo_path="$(pwd)"

	local campaigns_dir
	campaigns_dir="$(_resolve_campaigns_dir "$repo_path")"
	_require_campaigns_plane "$campaigns_dir" || return 1

	local launched_dir
	launched_dir="$(_require_launched_campaign "$campaigns_dir" "$campaign_id")" || return 1
	_require_campaign_production_eligibility "$launched_dir" || return 1

	local exit_code=0
	[[ "$do_results" == true ]] && { _promote_results "$launched_dir" "$campaign_id" "$repo_path" || exit_code=1; }
	[[ "$do_learnings" == true ]] && { _promote_learnings "$launched_dir" "$campaign_id" "$repo_path" || exit_code=1; }
	return "$exit_code"
}

# ---------------------------------------------------------------------------
# cmd_feedback — surface _feedback/ insights for campaign research
# ---------------------------------------------------------------------------

cmd_feedback() {
	local campaign_id='' repo_path=''

	while [[ $# -gt 0 ]]; do
		local _cur="${1:-}" _nxt="${2:-}"
		case "$_cur" in
		--repo) repo_path="$_nxt"; shift 2 ;;
		-*) _err_opt_unknown "$_cur"; return 1 ;;
		*) campaign_id="$_cur"; shift ;;
		esac
	done

	[[ -z "$repo_path" ]] && repo_path="$(pwd)"

	local feedback_dir="${repo_path}/_feedback"
	if [[ ! -d "$feedback_dir" ]]; then
		print_warning "_feedback/ plane not found at: ${feedback_dir}"
		print_warning "No feedback insights available. Provision _feedback/ first."
		return 0
	fi

	local insights_count=0
	local insight_files=()
	while IFS= read -r -d '' f; do
		insight_files+=("$f")
		insights_count=$((insights_count + 1))
	done < <(find "$feedback_dir" -name "*.md" -print0 2>/dev/null || true)

	if [[ $insights_count -eq 0 ]]; then
		print_info "No feedback insights found in: ${feedback_dir}"
		return 0
	fi

	print_info "Found ${insights_count} feedback file(s) in _feedback/"

	if [[ -z "$campaign_id" ]]; then
		print_info "Feedback files:"
		for f in "${insight_files[@]}"; do
			echo "  ${f#"$repo_path"/}"
		done
		echo ""
		echo "Import into a campaign: aidevops campaign feedback <id>"
		return 0
	fi

	local campaigns_dir
	campaigns_dir="$(_resolve_campaigns_dir "$repo_path")"
	local active_campaign_dir="${campaigns_dir}/${CAMPAIGNS_ACTIVE_DIR}/${campaign_id}"
	if [[ ! -d "$active_campaign_dir" ]]; then
		_err_active_not_found "$campaign_id"
		return 1
	fi

	local research_dir="${active_campaign_dir}/research"
	mkdir -p "$research_dir"
	local dest="${research_dir}/feedback-insights.md"
	{
		printf "# Feedback Insights for Campaign: %s\n\n" "$campaign_id"
		printf "_Collected from _feedback/ on %s_\n\n" "$(_current_date)"
		printf "## Sources\n\n"
		for f in "${insight_files[@]}"; do
			printf "- %s\n" "${f#"$repo_path"/}"
		done
		printf "\n## Content\n\n"
		for f in "${insight_files[@]}"; do
			printf "### %s\n\n" "$(basename "$f")"
			cat "$f"
			printf "\n\n"
		done
	} >"$dest"
	print_success "Feedback insights written to: ${dest}"
	return 0
}

# ---------------------------------------------------------------------------
# Draft helpers — channel-aware AI content generation (P5)
# ---------------------------------------------------------------------------

_validate_channel() {
	local channel="${1:-}"
	local valid
	for valid in $CAMPAIGNS_VALID_CHANNELS; do
		[[ "$channel" == "$valid" ]] && return 0
	done
	print_error "Invalid channel: ${channel}"
	print_error "Valid channels: ${CAMPAIGNS_VALID_CHANNELS}"
	return 1
}

_get_channel_spec() {
	local channel="${1:-}" field="${2:-}"
	if [[ ! -f "$CAMPAIGNS_CHANNEL_SPECS" ]]; then
		print_error "Channel specs not found: ${CAMPAIGNS_CHANNEL_SPECS}"
		return 1
	fi
	jq -r --arg ch "$channel" --arg f "$field" '.channels[$ch][$f] // empty' "$CAMPAIGNS_CHANNEL_SPECS"
	return 0
}

_get_channel_sections() {
	local channel="${1:-}"
	if [[ ! -f "$CAMPAIGNS_CHANNEL_SPECS" ]]; then
		return 1
	fi
	jq -r --arg ch "$channel" '.channels[$ch].sections[]? // empty' "$CAMPAIGNS_CHANNEL_SPECS"
	return 0
}

_gather_brand_context() {
	local campaigns_dir="${1:-}"
	local brand_dir="${campaigns_dir}/lib/brand"
	local context=""
	if [[ ! -d "$brand_dir" ]]; then
		echo ""
		return 0
	fi
	local f
	while IFS= read -r -d '' f; do
		# Only read text-based files (md, txt, json, yaml)
		case "$f" in
		*.md | *.txt | *.json | *.yaml | *.yml)
			local basename_f
			basename_f="$(basename "$f")"
			local content
			content=$(head -c 4096 "$f" | tr -d '\0')
			if [[ -n "$content" ]]; then
				context="${context}--- ${basename_f} ---
${content}

"
			fi
			;;
		esac
	done < <(find "$brand_dir" -type f -print0 2>/dev/null || true)
	echo "$context"
	return 0
}

_gather_swipe_context() {
	local campaigns_dir="${1:-}" channel="${2:-}"
	local swipe_dir="${campaigns_dir}/lib/swipe"
	local context=""
	if [[ ! -d "$swipe_dir" ]]; then
		echo ""
		return 0
	fi
	# Prefer channel-specific swipe, fall back to general
	local search_dirs=()
	[[ -d "${swipe_dir}/${channel}" ]] && search_dirs+=("${swipe_dir}/${channel}")
	search_dirs+=("$swipe_dir")

	local count=0
	local max_swipe=3
	local dir f
	for dir in "${search_dirs[@]}"; do
		[[ $count -ge $max_swipe ]] && break
		while IFS= read -r -d '' f; do
			[[ $count -ge $max_swipe ]] && break
			case "$f" in
			*.md | *.txt)
				local basename_f
				basename_f="$(basename "$f")"
				local content
				content=$(head -c 2048 "$f" | tr -d '\0')
				if [[ -n "$content" ]]; then
					context="${context}--- swipe: ${basename_f} ---
${content}

"
					count=$((count + 1))
				fi
				;;
			esac
		done < <(find "$dir" -maxdepth 1 -type f -print0 2>/dev/null || true)
	done
	echo "$context"
	return 0
}

_build_draft_prompt() {
	local channel="${1:-}" brief_content="${2:-}" brand_context="${3:-}"
	local swipe_context="${4:-}" tone="${5:-professional}"

	local max_words guidelines display_name
	max_words="$(_get_channel_spec "$channel" "max_words")"
	guidelines="$(_get_channel_spec "$channel" "guidelines")"
	display_name="$(_get_channel_spec "$channel" "display_name")"
	local sections
	sections="$(_get_channel_sections "$channel")"

	local sections_list=""
	if [[ -n "$sections" ]]; then
		sections_list="Structure the draft with these sections:
$(echo "$sections" | sed 's/^/- /')"
	fi

	local prompt="You are a creative marketing copywriter drafting content for ${display_name}.

## Campaign Brief
${brief_content}

## Channel Constraints
- Channel: ${display_name}
- Maximum words: ${max_words:-500}
- Tone: ${tone}
- ${guidelines:-Write clear, compelling content appropriate for this channel.}

${sections_list}

## Brand Context
${brand_context:-No brand assets available. Use a neutral professional voice.}

## Inspiration / Swipe Reference
${swipe_context:-No swipe files available. Create original content based on the brief.}

## Instructions
Write a single draft for this campaign on ${display_name}. Follow the channel constraints exactly. Match the brand voice if brand context is provided. Output ONLY the draft content — no meta-commentary, no explanations, no markdown headers like '## Draft'. Just the content itself, ready to post/send."

	echo "$prompt"
	return 0
}

_write_draft_file() {
	local dest="${1:-}" channel="${2:-}" variant="${3:-}" campaign_id="${4:-}"
	local tone="${5:-}" content="${6:-}" model_used="${7:-}"

	local draft_date
	draft_date="$(_current_date)"
	local display_name
	display_name="$(_get_channel_spec "$channel" "display_name")"
	local max_words
	max_words="$(_get_channel_spec "$channel" "max_words")"

	{
		cat <<EOF
---
channel: ${channel}
display_name: ${display_name:-${channel}}
variant: ${variant}
campaign: ${campaign_id}
tone: ${tone}
max_words: ${max_words:-500}
generated_at: ${draft_date}
model: ${model_used}
status: draft
reviewed: false
promoted: false
---

EOF
		printf '%s\n' "$content"
		cat <<EOF

---

_Draft generated by aidevops campaign draft on ${draft_date}._
_Model: ${model_used} | Channel: ${display_name} | Variant: ${variant}_
_Status: **draft** — requires human review before promotion to creative/._
_Promote: copy approved content to \`creative/${channel}/\` after review._
EOF
	} >"$dest"
	return 0
}

_require_draft_inputs() {
	local campaign_id="${1:-}" channel="${2:-}"
	if [[ -z "$campaign_id" ]] || [[ -z "$channel" ]]; then
		print_error "Usage: campaign draft <id> --channel <channel> [--tone <tone>] [--variant N]"
		print_error "Channels: ${CAMPAIGNS_VALID_CHANNELS}"
		return 1
	fi

	_validate_channel "$channel" || return 1
	return 0
}

_require_active_campaign_dir() {
	local campaigns_dir="${1:-}" campaign_id="${2:-}"
	if [[ -z "$campaigns_dir" ]] || [[ -z "$campaign_id" ]]; then
		print_error "Invalid campaigns directory or campaign ID."
		return 1
	fi

	local campaign_dir="${campaigns_dir}/${CAMPAIGNS_ACTIVE_DIR}/${campaign_id}"
	if [[ ! -d "$campaign_dir" ]]; then
		_err_active_not_found "$campaign_id"
		print_error "Path checked: ${campaign_dir}"
		print_error "Draft generation only works on active campaigns."
		return 1
	fi

	printf '%s\n' "$campaign_dir"
	return 0
}

_read_campaign_brief() {
	local campaign_dir="${1:-}"
	if [[ -z "$campaign_dir" ]]; then
		print_error "Campaign directory is required to read brief."
		return 1
	fi

	local brief_file="${campaign_dir}/${CAMPAIGNS_BRIEF_FILE}"
	if [[ ! -f "$brief_file" ]]; then
		print_error "Campaign brief not found: ${brief_file}"
		print_error "Create a brief first: edit ${brief_file}"
		return 1
	fi

	printf '%s\n' "$(<"$brief_file")"
	return 0
}

_prepare_draft_file() {
	local campaign_dir="${1:-}" channel="${2:-}" variant="${3:-}"
	if [[ -z "$campaign_dir" ]] || [[ -z "$channel" ]] || [[ -z "$variant" ]]; then
		print_error "Invalid inputs for preparing draft file."
		return 1
	fi

	local drafts_dir="${campaign_dir}/${CAMPAIGNS_DRAFTS_DIR}"
	mkdir -p "$drafts_dir" || return 1

	local draft_file="${drafts_dir}/${channel}-v${variant}.md"
	printf '%s\n' "$draft_file"
	return 0
}

_warn_existing_draft_file() {
	local draft_file="${1:-}"
	if [[ -f "$draft_file" ]]; then
		print_warning "Draft already exists: ${draft_file}"
		print_warning "Use --variant N to create a different variant."
	fi

	return 0
}

_generate_draft_content() {
	local channel="${1:-}" brief_content="${2:-}" brand_context="${3:-}"
	local swipe_context="${4:-}" tone="${5:-}" model="${6:-}"
	if [[ -z "$channel" ]] || [[ -z "$brief_content" ]]; then
		print_error "Missing channel or brief content for draft generation."
		return 1
	fi

	local ai_helper="${SCRIPT_DIR}/ai-research-helper.sh"
	if [[ ! -x "$ai_helper" ]]; then
		print_error "ai-research-helper.sh not found or not executable."
		print_error "The draft command requires the AI research helper for content generation."
		return 1
	fi

	local prompt max_words max_tokens draft_content
	prompt="$(_build_draft_prompt "$channel" "$brief_content" "$brand_context" "$swipe_context" "$tone")"
	max_words="$(_get_channel_spec "$channel" "max_words")"
	max_tokens=$(( (${max_words:-500} * 2) + 200 ))
	draft_content=$(printf '%s\n' "$prompt" | "$ai_helper" --stdin --model "$model" --max-tokens "$max_tokens") || {
		print_error "AI content generation failed. Check API key and model availability."
		return 1
	}

	if [[ -z "$draft_content" ]]; then
		print_error "AI returned empty content. Try a different model or check the brief."
		return 1
	fi

	printf '%s\n' "$draft_content"
	return 0
}

_print_draft_summary() {
	local campaign_id="${1:-}" channel="${2:-}" variant="${3:-}" tone="${4:-}"
	local model="${5:-}" draft_file="${6:-}" campaign_dir="${7:-}"
	local display_name
	display_name="$(_get_channel_spec "$channel" "display_name")"

	print_success "Draft created: ${draft_file}"
	echo "  Campaign:  ${campaign_id}"
	echo "  Channel:   ${display_name}"
	echo "  Variant:   ${variant}"
	echo "  Tone:      ${tone}"
	echo "  Model:     ${model}"
	echo "  Status:    draft (requires human review)"
	echo ""
	_print_next_steps
	echo "  1. Review:  cat ${draft_file}"
	echo "  2. Edit:    refine the draft as needed"
	echo "  3. Variant: aidevops campaign draft ${campaign_id} --channel ${channel} --variant $((variant + 1))"
	echo "  4. Promote: copy approved content to ${campaign_dir}/creative/${channel}/"
	return 0
}

# ---------------------------------------------------------------------------
# cmd_draft — AI creative agent for campaign content drafting (P5)
# ---------------------------------------------------------------------------

cmd_draft() {
	local campaign_id='' channel='' tone='professional' variant='1' repo_path='' model='sonnet'

	while [[ $# -gt 0 ]]; do
		local _cur="${1:-}" _nxt="${2:-}"
		case "$_cur" in
		--channel) channel="$_nxt"; shift 2 ;;
		--tone) tone="$_nxt"; shift 2 ;;
		--variant) variant="$_nxt"; shift 2 ;;
		--repo) repo_path="$_nxt"; shift 2 ;;
		--model) model="$_nxt"; shift 2 ;;
		-*) _err_opt_unknown "$_cur"; return 1 ;;
		*) campaign_id="$_cur"; shift ;;
		esac
	done

	_require_draft_inputs "$campaign_id" "$channel" || return 1

	[[ -z "$repo_path" ]] && repo_path="$(pwd)"

	local campaigns_dir
	campaigns_dir="$(_resolve_campaigns_dir "$repo_path")"
	_require_campaigns_plane "$campaigns_dir" || return 1

	local campaign_dir
	campaign_dir="$(_require_active_campaign_dir "$campaigns_dir" "$campaign_id")" || return 1

	local brief_content
	brief_content="$(_read_campaign_brief "$campaign_dir")" || return 1

	print_info "Gathering brand context from lib/brand/..."
	local brand_context
	brand_context="$(_gather_brand_context "$campaigns_dir")"

	print_info "Gathering swipe inspiration from lib/swipe/..."
	local swipe_context
	swipe_context="$(_gather_swipe_context "$campaigns_dir" "$channel")"

	local draft_file
	draft_file="$(_prepare_draft_file "$campaign_dir" "$channel" "$variant")" || return 1
	_warn_existing_draft_file "$draft_file"

	local display_name
	display_name="$(_get_channel_spec "$channel" "display_name")"
	print_info "Generating ${display_name:-${channel}} draft (variant ${variant}, tone: ${tone}, model: ${model})..."

	local draft_content
	draft_content="$(_generate_draft_content "$channel" "$brief_content" "$brand_context" "$swipe_context" "$tone" "$model")" || return 1

	_write_draft_file "$draft_file" "$channel" "$variant" "$campaign_id" \
		"$tone" "$draft_content" "$model" || return 1

	_print_draft_summary "$campaign_id" "$channel" "$variant" "$tone" "$model" "$draft_file" "$campaign_dir"
	return 0
}

# ---------------------------------------------------------------------------
# cmd_help
# ---------------------------------------------------------------------------

cmd_help() {
	cat <<HELP
campaign-helper.sh — _campaigns/ plane CLI (P2) + creative drafting (P5) + performance (P6)

P2 Commands (lifecycle management):
  new <name> --intake <file> [--channel <ch>] [--repo <path>]
      Create an active campaign with a validated schema-v1 intake-backed brief.
      Campaign ID auto-provisioned (c001, c002, ...) from .campaign-counter.

  update <id> --intake <file> [--repo <path>]
      Atomically replace the structured intake and rendered brief for an active campaign.

  migrate <id> --intake <file> [--repo <path>]
      Explicitly upgrade a legacy brief before structured updates.

  list [--repo <path>]
      Show all campaigns across active/, launched/, archive/ with status.

  status <id> [--repo <path>]
      Detailed dossier: brief, file inventory, lifecycle state.

  archive <id> [--repo <path>]
      Move _campaigns/launched/<id>/ → archive/<id>/.

P5 Commands (AI creative agent):
  draft <id> --channel <ch> [--tone <tone>] [--variant N] [--model <m>] [--repo <path>]
      AI-generated content draft grounded in campaign brief, brand assets, and swipe files.
      Channels: facebook, instagram, linkedin, twitter, email, blog.
      Tone defaults to 'professional'. Variant defaults to 1.
      Model defaults to 'standard' (simple|standard|thinking).
      Output: _campaigns/active/<id>/drafts/<channel>-v<N>.md
       Human-gated: drafts require manual review before promotion to creative/.

  production create <id> --channel <ch> [--variant N] [--asset-class writing|image|video|audio|editor] [--capability <class>] [--repo <path>]
      Create a schema-v1 creative brief and a truthful, provider-neutral production job.
      Jobs remain brief_ready or blocked until a downstream owner records verified evidence.
  production list <id> [--repo <path>]
      List schema-v1 production jobs and their verified lifecycle states.
   production validate <manifest-path>
       Validate a production manifest before consuming it downstream.
   production eligibility <campaign-dir>
       Verify every recorded job has approved review, rights, provenance, and output integrity.

Campaign research:
  research <id> [--source <evidence.json>]... [--repo <path>]
       Build a schema-v1, provenance-led research dossier from supplied exports,
       authorized collector results, manual evidence, or lawful public research.
       Raw sensitive evidence stays in _campaigns/intel/; no collector is implied.

P6 Commands (post-launch cross-plane):
   launch <id> [--repo <path>]
       Move _campaigns/active/<id>/ → launched/<id>/
       Requires eligible, approved production manifests; creates results.md + learnings.md templates.

  promote <id> [--results] [--learnings] [--repo <path>]
      --results    Push launched/<id>/results.md to _performance/marketing/<id>.md
      --learnings  Push launched/<id>/learnings.md to
                   _knowledge/insights/marketing/<YYYY-MM>/<id>-learnings.md

  feedback [<id>] [--repo <path>]
      Surface _feedback/ insights as campaign research input.
      If <id> given, writes aggregated insights to
      _campaigns/active/<id>/research/feedback-insights.md

  help   Show this help.

Examples:
  campaign-helper.sh new "Q2 Brand Awareness" --channel paid-social
  campaign-helper.sh list
  campaign-helper.sh status c001-q2-brand-awareness
  campaign-helper.sh draft c001-q2-brand-awareness --channel linkedin --tone conversational
  campaign-helper.sh draft c001-q2-brand-awareness --channel email --variant 2
  campaign-helper.sh launch c001-q2-brand-awareness
  campaign-helper.sh promote c001-q2-brand-awareness --results --learnings
  campaign-helper.sh archive c001-q2-brand-awareness

Prerequisites:
  _campaigns/ plane (P1 — aidevops t2962 #21250)
  ANTHROPIC_API_KEY for draft command (gopass or env var)
HELP
	return 0
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
	local command="${1:-help}"
	shift || true

	case "$command" in
	new) cmd_new "$@" ;;
	update) cmd_update "$@" ;;
	migrate) cmd_migrate "$@" ;;
	list | ls) cmd_list "$@" ;;
	status | show) cmd_status "$@" ;;
	archive) cmd_archive "$@" ;;
	draft) cmd_draft "$@" ;;
	launch) cmd_launch "$@" ;;
	promote) cmd_promote "$@" ;;
	feedback) cmd_feedback "$@" ;;
	production)
		[[ -f "$CAMPAIGN_PRODUCTION_HELPER" ]] || { print_error "Campaign production helper not found: ${CAMPAIGN_PRODUCTION_HELPER}"; return 1; }
		python3 "$CAMPAIGN_PRODUCTION_HELPER" "$@"
		;;
	distribution)
		[[ -f "$CAMPAIGN_DISTRIBUTION_HELPER" ]] || { print_error "Campaign distribution helper not found: ${CAMPAIGN_DISTRIBUTION_HELPER}"; return 1; }
		python3 "$CAMPAIGN_DISTRIBUTION_HELPER" "$@"
		;;
	research)
		[[ -x "$CAMPAIGN_RESEARCH_HELPER" || -f "$CAMPAIGN_RESEARCH_HELPER" ]] || { print_error "Campaign research helper not found: ${CAMPAIGN_RESEARCH_HELPER}"; return 1; }
		python3 "$CAMPAIGN_RESEARCH_HELPER" "$@"
		;;
	help | --help | -h) cmd_help ;;
	*)
		print_error "Unknown command: ${command}"
		cmd_help
		return 1
		;;
	esac
}

main "$@"

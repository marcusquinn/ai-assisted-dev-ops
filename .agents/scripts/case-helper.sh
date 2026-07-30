#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# shellcheck disable=SC2034
set -euo pipefail

# =============================================================================
# Case Helper (t2851 foundation + t2852 extended CLI)
# =============================================================================
# Manages the _cases/ plane: provisioning, open, attach, status, close,
# archive, list, show, note, deadline, party, comm.
#
# Usage:
#   case-helper.sh <command> [args] [options]
#
# Commands:
#   init [<repo-path>]              Provision _cases/ skeleton for a repo
#   open <slug> [options]           Open a new case
#   attach <case-id> <source-id>    Attach a knowledge source to a case
#   status <case-id> <new-status>   Update case status (open|hold|closed)
#   close <case-id> --outcome <x>   Close a case with outcome (shorthand)
#   archive <case-id>               Move case to _cases/archived/
#   list [options]                  List cases (default: open, table output)
#   show <case-id>                  Pretty-print dossier + timeline + sources
#   note <case-id> [options]        Append a note to case
#   deadline add|remove <case-id>   Manage case deadlines
#   party add|remove <case-id>      Manage case parties
#   comm log <case-id>              Log a communication entry
#   help                            Show this help
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/shared-constants.sh"

init_log_file

# =============================================================================
# Constants
# =============================================================================

readonly CASES_DIR_NAME="_cases"
readonly CASE_COUNTER_FILE=".case-counter"
readonly CASE_DOSSIER_FILE="dossier.toon"
readonly CASE_TIMELINE_FILE="timeline.jsonl"
readonly CASE_SOURCES_FILE="sources.toon"
readonly CASES_ARCHIVE_DIR="archived"
readonly CASE_NOTES_DIR="notes"
readonly CASE_COMMS_DIR="comms"
readonly CASE_DRAFTS_DIR="drafts"
readonly CASE_NOTES_FILE="notes.md"

CASES_SCHEMA_FILE="${SCRIPT_DIR}/../templates/case-dossier-schema.json"
CASES_GITIGNORE_TEMPLATE="${SCRIPT_DIR}/../templates/cases-gitignore.txt"
KNOWLEDGE_SOURCE_CONTRACT="${SCRIPT_DIR}/knowledge_source_contract.py"

# =============================================================================
# Error helpers — centralise repeated messages to satisfy string-literal ratchet
# =============================================================================

_err_opt_unknown() {
	local _o="${1:-}"
	print_error "Unknown option: ${_o}"
	return 1
}

_err_case_missing() {
	local _id="${1:-}"
	print_error "Case not found: ${_id}"
	return 1
}

_err_case_archived() {
	print_error "Case is archived. Use --unarchive to operate on it."
	return 1
}

# =============================================================================
# Internal helpers
# =============================================================================

# _iso_ts_full — current UTC timestamp ISO 8601 full
_iso_ts_full() {
	date -u '+%Y%m%dT%H%M%SZ'
	return 0
}

# _current_year — 4-digit current year
_current_year() {
	date -u '+%Y'
	return 0
}

# _resolve_cases_dir <repo-path>
_resolve_cases_dir() {
	local repo_path="${1:-$(pwd)}"
	echo "${repo_path}/${CASES_DIR_NAME}"
	return 0
}

# _current_actor — best-effort actor name (git user, env, or "unknown")
_current_actor() {
	local actor
	actor="$(git config user.name 2>/dev/null)" || true
	[[ -z "$actor" ]] && actor="${USER:-unknown}"
	echo "$actor"
	return 0
}

# _require_jq — error if jq is not available
_require_jq() {
	if ! command -v jq >/dev/null 2>&1; then
		print_error "jq is required but not found. Install: brew install jq"
		return 1
	fi
	return 0
}

# _case_id_claim <cases-dir> — claim the next sequential case ID atomically.
# Returns the full case ID string: case-YYYY-NNNN
_case_id_claim() {
	local cases_dir="$1"
	local counter_file="${cases_dir}/${CASE_COUNTER_FILE}"
	local year seq new_seq padded
	year="$(_current_year)"

	# Acquire lock via atomic mkdir (POSIX-compatible)
	local lock_dir="${counter_file}.lock"
	local max_wait=10 waited=0
	while ! mkdir "$lock_dir" 2>/dev/null; do
		sleep 0.2
		waited=$((waited + 1))
		if [[ $waited -ge $((max_wait * 5)) ]]; then
			print_error "Timeout waiting for case counter lock"
			return 1
		fi
	done
	# Ensure lock is always released
	# shellcheck disable=SC2064
	trap "rmdir '${lock_dir}' 2>/dev/null || true" EXIT

	if [[ -f "$counter_file" ]]; then
		local stored_year stored_seq
		stored_year="$(cut -d: -f1 "$counter_file")"
		stored_seq="$(cut -d: -f2 "$counter_file")"
		if [[ "$stored_year" == "$year" ]]; then
			seq=$((stored_seq + 1))
		else
			seq=1
		fi
	else
		seq=1
	fi

	padded="$(printf '%04d' "$seq")"
	printf '%s:%s\n' "$year" "$seq" >"$counter_file"
	rmdir "$lock_dir" 2>/dev/null || true
	trap - EXIT

	echo "case-${year}-${padded}"
	return 0
}

# _case_find <cases-dir> <case-id-or-slug> — resolve full case directory path.
# Accepts full case-id (case-YYYY-NNNN-slug) or partial slug match.
_case_find() {
	local cases_dir="$1" query="$2"
	local matched=""

	# Direct directory match first
	if [[ -d "${cases_dir}/${query}" ]]; then
		echo "${cases_dir}/${query}"
		return 0
	fi

	# Prefix match: case-YYYY-NNNN-<slug>
	local dir
	for dir in "${cases_dir}"/case-*-"${query}" "${cases_dir}"/case-*-*"${query}"*; do
		[[ -d "$dir" ]] || continue
		# Skip archived sub-dir entries when searching active
		[[ "$dir" == *"/archived/"* ]] && continue
		matched="$dir"
		break
	done

	if [[ -z "$matched" ]]; then
		# Try archived
		for dir in "${cases_dir}/${CASES_ARCHIVE_DIR}"/case-*-"${query}" \
			"${cases_dir}/${CASES_ARCHIVE_DIR}"/case-*-*"${query}"*; do
			[[ -d "$dir" ]] || continue
			matched="$dir"
			break
		done
	fi

	if [[ -n "$matched" ]]; then
		echo "$matched"
		return 0
	fi

	return 1
}

# _dossier_load <case-dir> — prints dossier JSON to stdout
_dossier_load() {
	local case_dir="$1"
	local dossier_path="${case_dir}/${CASE_DOSSIER_FILE}"
	if [[ ! -f "$dossier_path" ]]; then
		print_error "Dossier not found: ${dossier_path}"
		return 1
	fi
	jq '.' "$dossier_path"
	return 0
}

# _dossier_save <case-dir> — reads JSON from stdin, writes to dossier.toon
_dossier_save() {
	local case_dir="$1"
	local dossier_path="${case_dir}/${CASE_DOSSIER_FILE}"
	jq '.' >"$dossier_path"
	return 0
}

# _timeline_append <case-dir> <kind> <actor> <content> [ref]
# Appends a JSONL event line to timeline.jsonl
_timeline_append() {
	local case_dir="$1" kind="$2" actor="$3" content="$4" ref="${5:-}"
	local timeline_path="${case_dir}/${CASE_TIMELINE_FILE}"
	local ts
	ts="$(_iso_ts_full)"
	local event
	# Use -c (compact) so each event is a single line — proper JSONL format.
	event="$(jq -cn \
		--arg ts "$ts" \
		--arg kind "$kind" \
		--arg actor "$actor" \
		--arg content "$content" \
		--arg ref "$ref" \
		'{ts:$ts, kind:$kind, actor:$actor, content:$content, ref:$ref}')"
	echo "$event" >>"$timeline_path"
	return 0
}

# _is_archived <case-dir> — returns 0 if case is in archived/ sub-dir
_is_archived() {
	local case_dir="$1"
	[[ "$case_dir" == *"/${CASES_ARCHIVE_DIR}/"* ]]
	return $?
}

# =============================================================================
# cmd_init — provision _cases/ skeleton for a repo
# =============================================================================

cmd_init() {
	local repo_path="${1:-$(pwd)}"
	local cases_dir
	cases_dir="$(_resolve_cases_dir "$repo_path")"

	print_info "Provisioning cases plane at: ${cases_dir}"

	mkdir -p "${cases_dir}"
	mkdir -p "${cases_dir}/${CASES_ARCHIVE_DIR}"

	# .gitignore
	local gitignore_path="${cases_dir}/.gitignore"
	if [[ ! -f "$gitignore_path" ]]; then
		if [[ -f "$CASES_GITIGNORE_TEMPLATE" ]]; then
			cp "$CASES_GITIGNORE_TEMPLATE" "$gitignore_path"
		else
			printf '# _cases/ — drafts excluded\ndrafts/\n.DS_Store\n' >"$gitignore_path"
		fi
	fi

	# Case counter
	local counter_path="${cases_dir}/${CASE_COUNTER_FILE}"
	if [[ ! -f "$counter_path" ]]; then
		local year
		year="$(_current_year)"
		printf '%s:0\n' "$year" >"$counter_path"
	fi

	# README
	local readme_path="${cases_dir}/README.md"
	if [[ ! -f "$readme_path" ]]; then
		printf '%s\n' \
			"# Cases" \
			"" \
			"Managed by \`aidevops case\`. See \`.agents/aidevops/cases-plane.md\`." \
			>"$readme_path"
	fi

	print_success "Cases plane provisioned: ${cases_dir}"
	return 0
}

# =============================================================================
# cmd_open — open a new case
# =============================================================================

cmd_open() {
	_require_jq || return 1

	local slug='' kind='' party_name='' party_role="client" deadline_date='' deadline_label=''
	local repo_path="" json_mode=false

	while [[ $# -gt 0 ]]; do
		local _cur="${1:-}" _nxt="${2:-}"
		case "$_cur" in
		--kind) kind="$_nxt"; shift 2 ;;
		--party) party_name="$_nxt"; shift 2 ;;
		--party-role) party_role="$_nxt"; shift 2 ;;
		--deadline) deadline_date="$_nxt"; shift 2 ;;
		--deadline-label) deadline_label="$_nxt"; shift 2 ;;
		--repo) repo_path="$_nxt"; shift 2 ;;
		--json) json_mode=true; shift ;;
		-*) _err_opt_unknown "$_cur"; return 1 ;;
		*) slug="$_cur"; shift ;;
		esac
	done

	[[ -z "$slug" ]] && { print_error "Usage: case open <slug> [--kind <type>] [--party <name>]"; return 1; }
	[[ -z "$repo_path" ]] && repo_path="$(pwd)"

	local cases_dir
	cases_dir="$(_resolve_cases_dir "$repo_path")"
	[[ ! -d "$cases_dir" ]] && { print_error "Cases plane not provisioned. Run: aidevops case init"; return 1; }

	local case_prefix
	case_prefix="$(_case_id_claim "$cases_dir")"
	local case_id="${case_prefix}-${slug}"
	local case_dir="${cases_dir}/${case_id}"

	mkdir -p "${case_dir}/${CASE_NOTES_DIR}"
	mkdir -p "${case_dir}/${CASE_COMMS_DIR}"
	mkdir -p "${case_dir}/${CASE_DRAFTS_DIR}"

	local actor ts
	actor="$(_current_actor)"
	ts="$(_iso_ts_full)"

	# Build parties JSON array
	local parties_json="[]"
	if [[ -n "$party_name" ]]; then
		parties_json="$(jq -n --arg n "$party_name" --arg r "$party_role" \
			'[{name:$n, role:$r}]')"
	fi

	# Build deadlines JSON array
	local deadlines_json="[]"
	if [[ -n "$deadline_date" ]]; then
		local dl_label="${deadline_label:-deadline}"
		deadlines_json="$(jq -n --arg d "$deadline_date" --arg l "$dl_label" \
			'[{label:$l, date:$d}]')"
	fi

	# chasers_enabled defaults to false — must be explicitly set to true per-case
	# before case-chase-helper.sh send will proceed (t2858 opt-in gate).
	# Write dossier.toon
	jq -n \
		--arg id "$case_id" \
		--arg slug "$slug" \
		--arg kind "${kind:-general}" \
		--arg opened_at "$ts" \
		--arg initial_status "open" \
		--argjson parties "$parties_json" \
		--argjson deadlines "$deadlines_json" \
		'{id:$id, slug:$slug, kind:$kind, opened_at:$opened_at,
		  status:$initial_status, outcome:"", outcome_summary:"",
		  parties:$parties, deadlines:$deadlines,
		  chasers_enabled: false,
		  related_cases:[], related_repos:[]}' \
		>"${case_dir}/${CASE_DOSSIER_FILE}"

	# Initialize timeline
	printf '' >"${case_dir}/${CASE_TIMELINE_FILE}"
	_timeline_append "$case_dir" "open" "$actor" "Case opened: ${case_id}" ""

	# Initialize sources.toon as empty array
	printf '[]\n' >"${case_dir}/${CASE_SOURCES_FILE}"

	# Initialize notes file
	printf '# Notes: %s\n\n' "$case_id" >"${case_dir}/${CASE_NOTES_DIR}/${CASE_NOTES_FILE}"

	if [[ "$json_mode" == true ]]; then
		jq '.' "${case_dir}/${CASE_DOSSIER_FILE}"
	else
		print_success "Case opened: ${case_id}"
		echo "  Path:   ${case_dir}"
		echo "  Kind:   ${kind:-general}"
		echo "  Status: open"
		[[ -n "$party_name" ]] && echo "  Party:  ${party_name} (${party_role})"
	fi
	return 0
}

# =============================================================================
# cmd_attach — attach a knowledge source to a case
# =============================================================================

cmd_attach() {
	_require_jq || return 1

	local case_id='' source_id='' role="reference"
	local repo_path="" json_mode=false unarchive=false

	while [[ $# -gt 0 ]]; do
		local _cur="${1:-}" _nxt="${2:-}"
		case "$_cur" in
		--role) role="$_nxt"; shift 2 ;;
		--repo) repo_path="$_nxt"; shift 2 ;;
		--json) json_mode=true; shift ;;
		--unarchive) unarchive=true; shift ;;
		-*) _err_opt_unknown "$_cur"; return 1 ;;
		*) [[ -z "$case_id" ]] && { case_id="$_cur"; shift; } || { source_id="$_cur"; shift; } ;;
		esac
	done

	[[ -z "$case_id" || -z "$source_id" ]] && {
		print_error "Usage: case attach <case-id> <source-id> [--role evidence|reference|background]"
		return 1
	}
	[[ -z "$repo_path" ]] && repo_path="$(pwd)"

	local cases_dir
	cases_dir="$(_resolve_cases_dir "$repo_path")"
	local case_dir
	case_dir="$(_case_find "$cases_dir" "$case_id")" || {
		_err_case_missing "$case_id"
		return 1
	}

	# Refuse to operate on archived case without --unarchive
	if _is_archived "$case_dir" && [[ "$unarchive" != true ]]; then
		_err_case_archived
		return 1
	fi

	# Validate role
	case "$role" in
	evidence | reference | background) ;;
	*) print_error "Invalid role: ${role}. Must be evidence|reference|background"; return 1 ;;
	esac

	# Verify source exists in _knowledge/sources/
	local knowledge_src="${repo_path}/_knowledge/sources/${source_id}"
	if [[ ! -d "$knowledge_src" ]]; then
		print_error "Source not found: ${knowledge_src}"
		print_error "Sources must be promoted from _knowledge before attaching."
		return 1
	fi

	# Check not already attached
	local sources_file="${case_dir}/${CASE_SOURCES_FILE}"
	local already
	already="$(jq -r --arg id "$source_id" '.[] | select(.id == $id) | .id' "$sources_file" 2>/dev/null)" || true
	if [[ -n "$already" ]]; then
		print_error "Source already attached: ${source_id}"
		return 1
	fi

	local actor ts
	actor="$(_current_actor)"
	ts="$(_iso_ts_full)"

	# Append a projection pointer for contract-v2 sources; retain the legacy shape
	# for existing source directories that have not been migrated yet.
	local entry meta_path corpus_id evidence_id
	meta_path="${knowledge_src}/meta.json"
	corpus_id="$(jq -r '.corpus_id // empty' "$meta_path" 2>/dev/null || true)"
	evidence_id="$(jq -r '.evidence_id // empty' "$meta_path" 2>/dev/null || true)"
	if [[ -n "$corpus_id" && "$evidence_id" == "ev1:${corpus_id}:"* ]]; then
		if [[ ! -r "$KNOWLEDGE_SOURCE_CONTRACT" ]] || \
			! python3 "$KNOWLEDGE_SOURCE_CONTRACT" validate-meta --meta "$meta_path" >/dev/null; then
			print_error "Source manifest failed canonical evidence validation: ${source_id}"
			return 1
		fi
		entry="$(jq -n --arg id "$source_id" --arg ts "$ts" --arg by "$actor" \
			--arg role "$role" --arg corpus "$corpus_id" --arg evidence "$evidence_id" \
			'{id:$id, contract_version:1, corpus_id:$corpus, evidence_id:$evidence,
			  canonical_plane:"_knowledge", authority:"projection",
			  projection_kind:"case-source-pointer", attached_at:$ts,
			  attached_by:$by, role:$role}')"
	else
		entry="$(jq -n --arg id "$source_id" --arg ts "$ts" --arg by "$actor" --arg role "$role" \
			'{id:$id, attached_at:$ts, attached_by:$by, role:$role}')"
	fi
	local updated
	updated="$(jq --argjson e "$entry" '. + [$e]' "$sources_file")"
	echo "$updated" >"$sources_file"

	_timeline_append "$case_dir" "attach" "$actor" \
		"Attached source: ${source_id} (role: ${role})" "$source_id"

	if [[ "$json_mode" == true ]]; then
		echo "$entry"
	else
		print_success "Source attached: ${source_id} → ${case_id} (${role})"
	fi
	return 0
}

# =============================================================================
# cmd_status — update case status
# =============================================================================

cmd_status() {
	_require_jq || return 1

	local case_id='' new_status='' reason=''
	local repo_path="" json_mode=false unarchive=false

	while [[ $# -gt 0 ]]; do
		local _cur="${1:-}" _nxt="${2:-}"
		case "$_cur" in
		--reason) reason="$_nxt"; shift 2 ;;
		--repo) repo_path="$_nxt"; shift 2 ;;
		--json) json_mode=true; shift ;;
		--unarchive) unarchive=true; shift ;;
		-*) _err_opt_unknown "$_cur"; return 1 ;;
		*) [[ -z "$case_id" ]] && { case_id="$_cur"; shift; } || { new_status="$_cur"; shift; } ;;
		esac
	done

	[[ -z "$case_id" || -z "$new_status" ]] && {
		print_error "Usage: case status <case-id> <open|hold|closed> [--reason \"...\"]"
		return 1
	}
	[[ -z "$repo_path" ]] && repo_path="$(pwd)"

	case "$new_status" in
	open | hold | closed) ;;
	*) print_error "Invalid status: ${new_status}. Must be open|hold|closed"; return 1 ;;
	esac

	local cases_dir
	cases_dir="$(_resolve_cases_dir "$repo_path")"
	local case_dir
	case_dir="$(_case_find "$cases_dir" "$case_id")" || {
		_err_case_missing "$case_id"
		return 1
	}

	if _is_archived "$case_dir" && [[ "$unarchive" != true ]]; then
		_err_case_archived
		return 1
	fi

	# Closed without outcome goes through cmd_close which enforces --outcome
	if [[ "$new_status" == "closed" ]]; then
		print_error "Use 'case close <case-id> --outcome <x>' to close a case (outcome is required)."
		return 1
	fi

	local actor
	actor="$(_current_actor)"

	local dossier
	dossier="$(_dossier_load "$case_dir")"
	local old_status
	old_status="$(echo "$dossier" | jq -r '.status')"

	local updated
	updated="$(echo "$dossier" | jq --arg s "$new_status" '.status = $s')"
	echo "$updated" | _dossier_save "$case_dir"

	local content="Status changed: ${old_status} → ${new_status}"
	[[ -n "$reason" ]] && content="${content}. Reason: ${reason}"
	_timeline_append "$case_dir" "status_change" "$actor" "$content" ""

	if [[ "$json_mode" == true ]]; then
		echo "$updated"
	else
		print_success "Case status updated: ${case_id} → ${new_status}"
	fi
	return 0
}

# =============================================================================
# cmd_close — close a case with outcome (shorthand for status closed + outcome)
# =============================================================================

cmd_close() {
	_require_jq || return 1

	local case_id='' outcome='' summary=''
	local repo_path="" json_mode=false unarchive=false

	while [[ $# -gt 0 ]]; do
		local _cur="${1:-}" _nxt="${2:-}"
		case "$_cur" in
		--outcome) outcome="$_nxt"; shift 2 ;;
		--summary) summary="$_nxt"; shift 2 ;;
		--repo) repo_path="$_nxt"; shift 2 ;;
		--json) json_mode=true; shift ;;
		--unarchive) unarchive=true; shift ;;
		-*) _err_opt_unknown "$_cur"; return 1 ;;
		*) case_id="$_cur"; shift ;;
		esac
	done

	[[ -z "$case_id" ]] && { print_error "Usage: case close <case-id> --outcome <outcome>"; return 1; }
	[[ -z "$outcome" ]] && { print_error "Outcome is required when closing a case. Use --outcome <x>"; return 1; }
	[[ -z "$repo_path" ]] && repo_path="$(pwd)"

	local cases_dir
	cases_dir="$(_resolve_cases_dir "$repo_path")"
	local case_dir
	case_dir="$(_case_find "$cases_dir" "$case_id")" || {
		_err_case_missing "$case_id"
		return 1
	}

	if _is_archived "$case_dir" && [[ "$unarchive" != true ]]; then
		_err_case_archived
		return 1
	fi

	local actor
	actor="$(_current_actor)"

	local dossier
	dossier="$(_dossier_load "$case_dir")"
	local updated
	updated="$(echo "$dossier" | jq \
		--arg outcome "$outcome" \
		--arg summary "$summary" \
		'.status = "closed" | .outcome = $outcome | .outcome_summary = $summary')"
	echo "$updated" | _dossier_save "$case_dir"

	local content="Case closed. Outcome: ${outcome}"
	[[ -n "$summary" ]] && content="${content}. ${summary}"
	_timeline_append "$case_dir" "status_change" "$actor" "$content" ""

	if [[ "$json_mode" == true ]]; then
		echo "$updated"
	else
		print_success "Case closed: ${case_id} (outcome: ${outcome})"
	fi
	return 0
}

# =============================================================================
# cmd_archive — move case directory to _cases/archived/
# =============================================================================

cmd_archive() {
	local case_id='' repo_path='' json_mode=false

	while [[ $# -gt 0 ]]; do
		local _cur="${1:-}" _nxt="${2:-}"
		case "$_cur" in
		--repo) repo_path="$_nxt"; shift 2 ;;
		--json) json_mode=true; shift ;;
		-*) _err_opt_unknown "$_cur"; return 1 ;;
		*) case_id="$_cur"; shift ;;
		esac
	done

	[[ -z "$case_id" ]] && { print_error "Usage: case archive <case-id>"; return 1; }
	[[ -z "$repo_path" ]] && repo_path="$(pwd)"
	_require_jq || return 1

	local cases_dir
	cases_dir="$(_resolve_cases_dir "$repo_path")"
	local case_dir
	case_dir="$(_case_find "$cases_dir" "$case_id")" || {
		_err_case_missing "$case_id"
		return 1
	}

	if _is_archived "$case_dir"; then
		print_error "Case is already archived."
		return 1
	fi

	local actor
	actor="$(_current_actor)"
	local case_basename
	case_basename="$(basename "$case_dir")"
	local archive_dir="${cases_dir}/${CASES_ARCHIVE_DIR}"
	mkdir -p "$archive_dir"
	local dest="${archive_dir}/${case_basename}"

	_timeline_append "$case_dir" "archive" "$actor" "Case archived" ""

	if command -v git >/dev/null 2>&1 && git -C "$repo_path" rev-parse --git-dir >/dev/null 2>&1; then
		git -C "$repo_path" mv "$case_dir" "$dest" 2>/dev/null || mv "$case_dir" "$dest"
	else
		mv "$case_dir" "$dest"
	fi

	if [[ "$json_mode" == true ]]; then
		jq -n --arg id "$case_basename" --arg dest "$dest" \
			--arg arch_status "${CASES_ARCHIVE_DIR}" \
			'{status:$arch_status, case_id:$id, path:$dest}'
	else
		print_success "Case archived: ${case_basename}"
		echo "  Path: ${dest}"
	fi
	return 0
}

# =============================================================================
# cmd_list — list cases
# =============================================================================

# _list_match_case <case_dir> <status_filter> <kind_filter> <party_filter> <json_mode>
# Returns 0 if case matches all filters and prints a table row (text) or JSON object.
# Returns 1 if filtered out (no output).
_list_match_case() {
	local case_dir="$1" status_filter="$2" kind_filter="$3" party_filter="$4" json_mode="$5"
	local dossier_path="${case_dir}/${CASE_DOSSIER_FILE}"
	[[ ! -f "$dossier_path" ]] && return 1

	local dossier
	dossier="$(jq '.' "$dossier_path" 2>/dev/null)" || return 1

	local cs_status cs_kind cs_id
	cs_status="$(echo "$dossier" | jq -r '.status')"
	cs_kind="$(echo "$dossier" | jq -r '.kind')"
	cs_id="$(echo "$dossier" | jq -r '.id')"

	# Status filter
	if [[ "$status_filter" != "all" ]]; then
		if [[ "$cs_status" != "$status_filter" ]]; then
			_is_archived "$case_dir" && [[ "$status_filter" != "${CASES_ARCHIVE_DIR}" ]] && return 1
			! _is_archived "$case_dir" && return 1
		fi
	fi

	# Kind filter
	[[ -n "$kind_filter" && "$cs_kind" != "$kind_filter" ]] && return 1

	# Party filter
	if [[ -n "$party_filter" ]]; then
		local party_match
		party_match="$(echo "$dossier" | jq -r \
			--arg p "$party_filter" '.parties[] | select(.name | test($p;"i")) | .name' \
			2>/dev/null)" || true
		[[ -z "$party_match" ]] && return 1
	fi

	if [[ "$json_mode" == true ]]; then
		echo "$dossier"
	else
		local cs_parties cs_deadline
		cs_parties="$(echo "$dossier" | jq -r '[.parties[].name] | join(", ")')"
		cs_deadline="$(echo "$dossier" | jq -r '(.deadlines | sort_by(.date) | first | .date) // ""')"
		printf '%-36s %-16s %-8s %-24s %-12s\n' \
			"$cs_id" "$cs_kind" "$cs_status" "${cs_parties:0:24}" "${cs_deadline}"
	fi
	return 0
}

cmd_list() {
	_require_jq || return 1

	local status_filter='open' kind_filter='' party_filter=''
	local repo_path="" json_mode=false

	while [[ $# -gt 0 ]]; do
		local _cur="${1:-}" _nxt="${2:-}"
		case "$_cur" in
		--status) status_filter="$_nxt"; shift 2 ;;
		--kind) kind_filter="$_nxt"; shift 2 ;;
		--party) party_filter="$_nxt"; shift 2 ;;
		--repo) repo_path="$_nxt"; shift 2 ;;
		--json) json_mode=true; shift ;;
		-*) _err_opt_unknown "$_cur"; return 1 ;;
		*) shift ;;
		esac
	done

	[[ -z "$repo_path" ]] && repo_path="$(pwd)"

	local cases_dir
	cases_dir="$(_resolve_cases_dir "$repo_path")"
	[[ ! -d "$cases_dir" ]] && { print_error "Cases plane not provisioned. Run: aidevops case init"; return 1; }

	# Collect candidate directories (active + optionally archived)
	local -a case_dirs=()
	local dir
	for dir in "${cases_dir}"/case-*/; do
		[[ -d "$dir" ]] || continue
		[[ "$dir" == *"/${CASES_ARCHIVE_DIR}/"* ]] && continue
		case_dirs+=("$dir")
	done

	if [[ "$status_filter" == "all" || "$status_filter" == "${CASES_ARCHIVE_DIR}" ]]; then
		for dir in "${cases_dir}/${CASES_ARCHIVE_DIR}"/case-*/; do
			[[ -d "$dir" ]] || continue
			case_dirs+=("$dir")
		done
	fi

	# Filter cases and accumulate output
	local -a rows=()
	local results_json="[]" case_dir match_out
	for case_dir in "${case_dirs[@]:-}"; do
		[[ -z "$case_dir" ]] && continue
		match_out="$(_list_match_case \
			"$case_dir" "$status_filter" "$kind_filter" "$party_filter" "$json_mode")" || continue
		if [[ "$json_mode" == true ]]; then
			results_json="$(echo "$results_json" | jq --argjson d "$match_out" '. + [$d]')"
		else
			rows+=("$match_out")
		fi
	done

	if [[ "$json_mode" == true ]]; then
		echo "$results_json"; return 0
	fi

	if [[ ${#rows[@]} -eq 0 ]]; then
		echo "No cases found (status: ${status_filter})"; return 0
	fi

	printf '%-36s %-16s %-8s %-24s %-12s\n' "CASE-ID" "KIND" "STATUS" "PARTIES" "NEXT-DEADLINE"
	printf '%s\n' "$(printf '%.0s-' {1..100})"
	for row in "${rows[@]}"; do echo "$row"; done
	return 0
}

# =============================================================================
# cmd_show — pretty-print a case
# =============================================================================

cmd_show() {
	_require_jq || return 1

	local case_id='' repo_path='' json_mode=false

	while [[ $# -gt 0 ]]; do
		local _cur="${1:-}" _nxt="${2:-}"
		case "$_cur" in
		--repo) repo_path="$_nxt"; shift 2 ;;
		--json) json_mode=true; shift ;;
		-*) _err_opt_unknown "$_cur"; return 1 ;;
		*) case_id="$_cur"; shift ;;
		esac
	done

	[[ -z "$case_id" ]] && { print_error "Usage: case show <case-id>"; return 1; }
	[[ -z "$repo_path" ]] && repo_path="$(pwd)"

	local cases_dir
	cases_dir="$(_resolve_cases_dir "$repo_path")"
	local case_dir
	case_dir="$(_case_find "$cases_dir" "$case_id")" || {
		_err_case_missing "$case_id"
		return 1
	}

	local dossier
	dossier="$(_dossier_load "$case_dir")"

	if [[ "$json_mode" == true ]]; then
		local sources timeline_events
		sources="$(jq '.' "${case_dir}/${CASE_SOURCES_FILE}" 2>/dev/null)" || sources="[]"
		timeline_events="$(jq -s '.' "${case_dir}/${CASE_TIMELINE_FILE}" 2>/dev/null)" || timeline_events="[]"
		jq -n \
			--argjson dossier "$dossier" \
			--argjson sources "$sources" \
			--argjson timeline "$timeline_events" \
			'{dossier:$dossier, sources:$sources, timeline:$timeline}'
		return 0
	fi

	_show_dossier_text "$dossier" "$case_dir"
	return 0
}

# _show_dossier_text <dossier-json> <case-dir>
_show_dossier_text() {
	local dossier="$1" case_dir="$2"

	local cs_id cs_kind cs_status cs_opened cs_outcome
	cs_id="$(echo "$dossier" | jq -r '.id')"
	cs_kind="$(echo "$dossier" | jq -r '.kind')"
	cs_status="$(echo "$dossier" | jq -r '.status')"
	cs_opened="$(echo "$dossier" | jq -r '.opened_at')"
	cs_outcome="$(echo "$dossier" | jq -r '.outcome // ""')"
	local _none='  (none)'

	echo ""
	echo "## Case: ${cs_id}"
	echo ""
	printf '  Kind:    %s\n' "$cs_kind"
	printf '  Status:  %s\n' "$cs_status"
	printf '  Opened:  %s\n' "$cs_opened"
	[[ -n "$cs_outcome" ]] && printf '  Outcome: %s\n' "$cs_outcome"

	echo ""
	echo "### Parties"
	echo "$dossier" | jq -r '.parties[] | "  - \(.name) (\(.role))"' 2>/dev/null || echo "$_none"

	echo ""
	echo "### Deadlines"
	echo "$dossier" | jq -r '.deadlines[] | "  - \(.label): \(.date)"' 2>/dev/null || echo "$_none"

	echo ""
	echo "### Attached Sources"
	local sources_file="${case_dir}/${CASE_SOURCES_FILE}"
	if [[ -f "$sources_file" ]]; then
		jq -r '.[] | "  - \(.id) (\(.role), attached \(.attached_at))"' "$sources_file" 2>/dev/null || echo "$_none"
	else
		echo "$_none"
	fi

	echo ""
	echo "### Timeline"
	local timeline_file="${case_dir}/${CASE_TIMELINE_FILE}"
	if [[ -f "$timeline_file" ]]; then
		while IFS= read -r line; do
			[[ -z "$line" ]] && continue
			local ts kind content
			ts="$(echo "$line" | jq -r '.ts')"
			kind="$(echo "$line" | jq -r '.kind')"
			content="$(echo "$line" | jq -r '.content')"
			printf '  [%s] %s: %s\n' "$ts" "$kind" "$content"
		done <"$timeline_file"
	else
		echo "  (empty)"
	fi
	echo ""
	return 0
}

# =============================================================================
# cmd_note — append a note to the case
# =============================================================================

cmd_note() {
	_require_jq || return 1

	local case_id='' message='' repo_path='' json_mode=false unarchive=false

	while [[ $# -gt 0 ]]; do
		local _cur="${1:-}" _nxt="${2:-}"
		case "$_cur" in
		--message | -m) message="$_nxt"; shift 2 ;;
		--repo) repo_path="$_nxt"; shift 2 ;;
		--json) json_mode=true; shift ;;
		--unarchive) unarchive=true; shift ;;
		-*) _err_opt_unknown "$_cur"; return 1 ;;
		*) case_id="$_cur"; shift ;;
		esac
	done

	[[ -z "$case_id" ]] && { print_error "Usage: case note <case-id> --message \"...\""; return 1; }
	[[ -z "$message" ]] && { print_error "Note message required. Use --message \"...\""; return 1; }
	[[ -z "$repo_path" ]] && repo_path="$(pwd)"

	local cases_dir
	cases_dir="$(_resolve_cases_dir "$repo_path")"
	local case_dir
	case_dir="$(_case_find "$cases_dir" "$case_id")" || {
		_err_case_missing "$case_id"
		return 1
	}

	if _is_archived "$case_dir" && [[ "$unarchive" != true ]]; then
		_err_case_archived
		return 1
	fi

	local actor ts
	actor="$(_current_actor)"
	ts="$(_iso_ts_full)"

	# Append to notes/notes.md
	local notes_file="${case_dir}/${CASE_NOTES_DIR}/${CASE_NOTES_FILE}"
	mkdir -p "${case_dir}/${CASE_NOTES_DIR}"
	[[ ! -f "$notes_file" ]] && printf '# Notes: %s\n\n' "$case_id" >"$notes_file"
	printf '\n---\n**%s** (%s)\n\n%s\n' "$actor" "$ts" "$message" >>"$notes_file"

	local ref="${CASE_NOTES_DIR}/${CASE_NOTES_FILE}"
	_timeline_append "$case_dir" "note" "$actor" "$message" "$ref"

	if [[ "$json_mode" == true ]]; then
		jq -n --arg ts "$ts" --arg actor "$actor" --arg msg "$message" --arg ref "$ref" \
			'{kind:"note", ts:$ts, actor:$actor, content:$msg, ref:$ref}'
	else
		print_success "Note appended to: ${case_id}"
	fi
	return 0
}

# =============================================================================
# cmd_deadline — add or remove a deadline from a case
# =============================================================================

cmd_deadline() {
	_require_jq || return 1

	local action="${1:-add}"
	shift || true

	case "$action" in
	add) _cmd_deadline_add "$@" ;;
	remove | rm) _cmd_deadline_remove "$@" ;;
	*) print_error "Usage: case deadline add|remove <case-id> [--date ISO] [--label \"...\"]"; return 1 ;;
	esac
	return 0
}

_cmd_deadline_add() {
	local case_id='' date_val='' label='' repo_path='' json_mode=false unarchive=false

	while [[ $# -gt 0 ]]; do
		local _cur="${1:-}" _nxt="${2:-}"
		case "$_cur" in
		--date) date_val="$_nxt"; shift 2 ;;
		--label) label="$_nxt"; shift 2 ;;
		--repo) repo_path="$_nxt"; shift 2 ;;
		--json) json_mode=true; shift ;;
		--unarchive) unarchive=true; shift ;;
		-*) _err_opt_unknown "$_cur"; return 1 ;;
		*) case_id="$_cur"; shift ;;
		esac
	done

	[[ -z "$case_id" ]] && { print_error "Usage: case deadline add <case-id> --date ISO --label \"...\""; return 1; }
	[[ -z "$date_val" ]] && { print_error "--date is required"; return 1; }
	[[ -z "$repo_path" ]] && repo_path="$(pwd)"

	local cases_dir
	cases_dir="$(_resolve_cases_dir "$repo_path")"
	local case_dir
	case_dir="$(_case_find "$cases_dir" "$case_id")" || { _err_case_missing "$case_id"; return 1; }

	if _is_archived "$case_dir" && [[ "$unarchive" != true ]]; then
		_err_case_archived
		return 1
	fi

	local actor dl_label
	actor="$(_current_actor)"
	dl_label="${label:-deadline}"

	local dossier
	dossier="$(_dossier_load "$case_dir")"
	local entry
	entry="$(jq -n --arg d "$date_val" --arg l "$dl_label" '{label:$l, date:$d}')"
	local updated
	updated="$(echo "$dossier" | jq --argjson e "$entry" '.deadlines += [$e]')"
	echo "$updated" | _dossier_save "$case_dir"

	_timeline_append "$case_dir" "deadline" "$actor" \
		"Deadline added: ${dl_label} on ${date_val}" ""

	if [[ "$json_mode" == true ]]; then
		echo "$entry"
	else
		print_success "Deadline added: ${dl_label} (${date_val}) to ${case_id}"
	fi
	return 0
}

_cmd_deadline_remove() {
	local case_id='' label='' repo_path='' json_mode=false unarchive=false

	while [[ $# -gt 0 ]]; do
		local _cur="${1:-}" _nxt="${2:-}"
		case "$_cur" in
		--label) label="$_nxt"; shift 2 ;;
		--repo) repo_path="$_nxt"; shift 2 ;;
		--json) json_mode=true; shift ;;
		--unarchive) unarchive=true; shift ;;
		-*) _err_opt_unknown "$_cur"; return 1 ;;
		*) case_id="$_cur"; shift ;;
		esac
	done

	[[ -z "$case_id" || -z "$label" ]] && {
		print_error "Usage: case deadline remove <case-id> --label \"deadline label\""
		return 1
	}
	[[ -z "$repo_path" ]] && repo_path="$(pwd)"

	local cases_dir
	cases_dir="$(_resolve_cases_dir "$repo_path")"
	local case_dir
	case_dir="$(_case_find "$cases_dir" "$case_id")" || { _err_case_missing "$case_id"; return 1; }

	if _is_archived "$case_dir" && [[ "$unarchive" != true ]]; then
		_err_case_archived
		return 1
	fi

	local actor
	actor="$(_current_actor)"
	local dossier
	dossier="$(_dossier_load "$case_dir")"
	local updated
	updated="$(echo "$dossier" | jq --arg l "$label" '.deadlines = [.deadlines[] | select(.label != $l)]')"
	echo "$updated" | _dossier_save "$case_dir"

	_timeline_append "$case_dir" "deadline" "$actor" "Deadline removed: ${label}" ""

	if [[ "$json_mode" == true ]]; then
		echo "$updated"
	else
		print_success "Deadline removed: ${label} from ${case_id}"
	fi
	return 0
}

# =============================================================================
# cmd_party — add or remove a party from a case
# =============================================================================

cmd_party() {
	_require_jq || return 1

	local action="${1:-add}"
	shift || true

	case "$action" in
	add) _cmd_party_add "$@" ;;
	remove | rm) _cmd_party_remove "$@" ;;
	*) print_error "Usage: case party add|remove <case-id> --name \"...\" --role \"...\""; return 1 ;;
	esac
	return 0
}

_cmd_party_add() {
	local case_id='' name='' role='' repo_path='' json_mode=false unarchive=false

	while [[ $# -gt 0 ]]; do
		local _cur="${1:-}" _nxt="${2:-}"
		case "$_cur" in
		--name) name="$_nxt"; shift 2 ;;
		--role) role="$_nxt"; shift 2 ;;
		--repo) repo_path="$_nxt"; shift 2 ;;
		--json) json_mode=true; shift ;;
		--unarchive) unarchive=true; shift ;;
		-*) _err_opt_unknown "$_cur"; return 1 ;;
		*) case_id="$_cur"; shift ;;
		esac
	done

	[[ -z "$case_id" || -z "$name" || -z "$role" ]] && {
		print_error "Usage: case party add <case-id> --name \"name\" --role \"role\""
		return 1
	}
	[[ -z "$repo_path" ]] && repo_path="$(pwd)"

	local cases_dir
	cases_dir="$(_resolve_cases_dir "$repo_path")"
	local case_dir
	case_dir="$(_case_find "$cases_dir" "$case_id")" || { _err_case_missing "$case_id"; return 1; }

	if _is_archived "$case_dir" && [[ "$unarchive" != true ]]; then
		_err_case_archived
		return 1
	fi

	local actor
	actor="$(_current_actor)"
	local entry
	entry="$(jq -n --arg n "$name" --arg r "$role" '{name:$n, role:$r}')"
	local dossier
	dossier="$(_dossier_load "$case_dir")"
	local updated
	updated="$(echo "$dossier" | jq --argjson e "$entry" '.parties += [$e]')"
	echo "$updated" | _dossier_save "$case_dir"

	_timeline_append "$case_dir" "party" "$actor" "Party added: ${name} (${role})" ""

	if [[ "$json_mode" == true ]]; then
		echo "$entry"
	else
		print_success "Party added: ${name} (${role}) to ${case_id}"
	fi
	return 0
}

_cmd_party_remove() {
	local case_id='' name='' repo_path='' json_mode=false unarchive=false

	while [[ $# -gt 0 ]]; do
		local _cur="${1:-}" _nxt="${2:-}"
		case "$_cur" in
		--name) name="$_nxt"; shift 2 ;;
		--repo) repo_path="$_nxt"; shift 2 ;;
		--json) json_mode=true; shift ;;
		--unarchive) unarchive=true; shift ;;
		-*) _err_opt_unknown "$_cur"; return 1 ;;
		*) case_id="$_cur"; shift ;;
		esac
	done

	[[ -z "$case_id" || -z "$name" ]] && {
		print_error "Usage: case party remove <case-id> --name \"name\""
		return 1
	}
	[[ -z "$repo_path" ]] && repo_path="$(pwd)"

	local cases_dir
	cases_dir="$(_resolve_cases_dir "$repo_path")"
	local case_dir
	case_dir="$(_case_find "$cases_dir" "$case_id")" || { _err_case_missing "$case_id"; return 1; }

	if _is_archived "$case_dir" && [[ "$unarchive" != true ]]; then
		_err_case_archived
		return 1
	fi

	local actor
	actor="$(_current_actor)"
	local dossier
	dossier="$(_dossier_load "$case_dir")"
	local updated
	updated="$(echo "$dossier" | jq --arg n "$name" '.parties = [.parties[] | select(.name != $n)]')"
	echo "$updated" | _dossier_save "$case_dir"

	_timeline_append "$case_dir" "party" "$actor" "Party removed: ${name}" ""

	if [[ "$json_mode" == true ]]; then
		echo "$updated"
	else
		print_success "Party removed: ${name} from ${case_id}"
	fi
	return 0
}

# =============================================================================
# cmd_comm — log a communication entry
# =============================================================================

cmd_comm() {
	_require_jq || return 1

	local action="${1:-log}"
	shift || true

	case "$action" in
	log) _cmd_comm_log "$@" ;;
	*) print_error "Usage: case comm log <case-id> --direction in|out --channel <c> --summary \"...\""; return 1 ;;
	esac
	return 0
}

_cmd_comm_log() {
	local case_id='' direction='' channel='' summary='' repo_path='' json_mode=false unarchive=false

	while [[ $# -gt 0 ]]; do
		local _cur="${1:-}" _nxt="${2:-}"
		case "$_cur" in
		--direction) direction="$_nxt"; shift 2 ;;
		--channel) channel="$_nxt"; shift 2 ;;
		--summary) summary="$_nxt"; shift 2 ;;
		--repo) repo_path="$_nxt"; shift 2 ;;
		--json) json_mode=true; shift ;;
		--unarchive) unarchive=true; shift ;;
		-*) _err_opt_unknown "$_cur"; return 1 ;;
		*) case_id="$_cur"; shift ;;
		esac
	done

	[[ -z "$case_id" || -z "$direction" || -z "$channel" || -z "$summary" ]] && {
		print_error "Usage: case comm log <case-id> --direction in|out --channel <c> --summary \"...\""
		return 1
	}
	case "$direction" in
	in | out) ;;
	*) print_error "Invalid direction: ${direction}. Must be in|out"; return 1 ;;
	esac
	[[ -z "$repo_path" ]] && repo_path="$(pwd)"

	local cases_dir
	cases_dir="$(_resolve_cases_dir "$repo_path")"
	local case_dir
	case_dir="$(_case_find "$cases_dir" "$case_id")" || {
		_err_case_missing "$case_id"
		return 1
	}

	if _is_archived "$case_dir" && [[ "$unarchive" != true ]]; then
		_err_case_archived
		return 1
	fi

	local actor ts
	actor="$(_current_actor)"
	ts="$(_iso_ts_full)"

	mkdir -p "${case_dir}/${CASE_COMMS_DIR}"
	local comm_file="${case_dir}/${CASE_COMMS_DIR}/comms.log"
	printf '\n---\n[%s] %s via %s (%s)\n\n%s\n' \
		"$ts" "$direction" "$channel" "$actor" "$summary" >>"$comm_file"

	local ref="${CASE_COMMS_DIR}/comms.log"
	local content="Comm logged: ${direction} via ${channel} — ${summary}"
	_timeline_append "$case_dir" "comm" "$actor" "$content" "$ref"

	if [[ "$json_mode" == true ]]; then
		jq -n --arg ts "$ts" --arg dir "$direction" --arg ch "$channel" \
			--arg actor "$actor" --arg summary "$summary" --arg ref "$ref" \
			'{kind:"comm", ts:$ts, direction:$dir, channel:$ch, actor:$actor, summary:$summary, ref:$ref}'
	else
		print_success "Communication logged on: ${case_id}"
	fi
	return 0
}

# =============================================================================
# cmd_help
# =============================================================================

cmd_help() {
	cat <<'HELP'
Case Helper — manage case dossiers with timeline audit trail

Usage: case-helper.sh <command> [args] [options]

Commands:
  init [<repo-path>]                    Provision _cases/ plane for a repo
  open <slug> [options]                 Open a new case
  attach <case-id> <source-id>          Attach a knowledge source
  status <case-id> <open|hold>          Update case status
  close <case-id> --outcome <x>         Close a case with required outcome
  archive <case-id>                     Move to _cases/archived/
  list [options]                        List cases (default: open)
  show <case-id>                        Show dossier + timeline + sources
  note <case-id> --message "..."        Append internal note
  deadline add|remove <case-id>         Manage deadlines
  party add|remove <case-id>            Manage parties
  comm log <case-id>                    Log a communication entry
  chase <case-id> --template <name>     Send a template chase email (opt-in)
  chase-template add|list|test          Manage chase templates
  help                                  Show this help

Open options:
  --kind <type>           Case type (dispute, contract, compliance, ...)
  --party <name>          Initial party name
  --party-role <role>     Initial party role (default: client)
  --deadline <ISO-date>   Initial deadline date
  --deadline-label <txt>  Deadline label

List options:
  --status <open|hold|closed|archived|all>  Filter by status (default: open)
  --kind <type>                              Filter by kind
  --party <name>                             Filter by party name (regex)
  --json                                     Machine-readable JSON output

Attach options:
  --role <evidence|reference|background>   Source role (default: reference)

All mutating commands support:
  --json          Output result as JSON
  --unarchive     Allow operating on archived cases
  --repo <path>   Target repo path (default: current directory)

Examples:
  case-helper.sh init
  case-helper.sh open acme-dispute --kind dispute --party "ACME Ltd" --deadline 2026-08-31
  case-helper.sh list
  case-helper.sh list --status all --json
  case-helper.sh show case-2026-0001-acme-dispute
  case-helper.sh attach case-2026-0001-acme-dispute src-001 --role evidence
  case-helper.sh status case-2026-0001-acme-dispute hold --reason "awaiting client"
  case-helper.sh close case-2026-0001-acme-dispute --outcome settled --summary "Agreed in mediation"
  case-helper.sh note case-2026-0001-acme-dispute --message "Reviewed contract terms"
  case-helper.sh deadline add case-2026-0001-acme-dispute --date 2026-08-31 --label "filing deadline"
  case-helper.sh party add case-2026-0001-acme-dispute --name "Opposing Counsel" --role "opponent"
  case-helper.sh comm log case-2026-0001-acme-dispute --direction in --channel email --summary "Received settlement offer"
  case-helper.sh archive case-2026-0001-acme-dispute
HELP
	return 0
}

# =============================================================================
# Main
# =============================================================================

main() {
	local command="${1:-help}"
	shift || true

	case "$command" in
	init) cmd_init "$@" ;;
	open | new) cmd_open "$@" ;;
	attach) cmd_attach "$@" ;;
	status) cmd_status "$@" ;;
	close) cmd_close "$@" ;;
	archive) cmd_archive "$@" ;;
	list | ls) cmd_list "$@" ;;
	show | view) cmd_show "$@" ;;
	note) cmd_note "$@" ;;
	deadline | dl) cmd_deadline "$@" ;;
	party) cmd_party "$@" ;;
	comm | comms) cmd_comm "$@" ;;
	chase) bash "${SCRIPT_DIR}/case-chase-helper.sh" send "$@" ;;
	chase-template) bash "${SCRIPT_DIR}/case-chase-helper.sh" template "$@" ;;
	help | --help | -h) cmd_help ;;
	*)
		print_error "Unknown command: ${command}"
		cmd_help
		return 1
		;;
	esac
}

main "$@"

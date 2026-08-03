#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# knowledge-review-helper.sh — Knowledge plane review gate routine (t2845)
#
# Scans _knowledge/inbox/ for pending sources, classifies them by trust ladder,
# auto-promotes maintainer/trusted drops, and files explicitly held GitHub
# review issues for untrusted sources. Designed to run as pulse routine r040.
#
# Usage (pulse routine r040):
#   scripts/knowledge-review-helper.sh tick
#
# Usage (after explicit maintainer content review):
#   knowledge-review-helper.sh promote <source-id>
#
# Usage (manual audit entry):
#   knowledge-review-helper.sh audit-log <action> <source-id> [extra]
#
# Trust classification (from _knowledge/_config/knowledge.json → trust):
#   auto_promote  → maintainer drops / trusted paths+emails+bots → promote directly
#   review_gate   → trusted partner emails → file kind:knowledge-review + auto-dispatch
#   untrusted     → default ("*") → file kind:knowledge-review + hold-for-review
#
# Audit log: _knowledge/index/audit.log (JSONL, one record per action)
#
# Pattern reference: .agents/scripts/knowledge-helper.sh (provisioning)
#                    .agents/scripts/email-poll-helper.sh (pulse routine)
#                    .agents/reference/dispatch-blockers.md (review holds)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=shared-constants.sh
[[ -f "${SCRIPT_DIR}/shared-constants.sh" ]] && source "${SCRIPT_DIR}/shared-constants.sh"
# shellcheck source=shared-gh-wrappers.sh
[[ -f "${SCRIPT_DIR}/shared-gh-wrappers.sh" ]] && source "${SCRIPT_DIR}/shared-gh-wrappers.sh"

# Guard color fallbacks when shared-constants.sh is absent
[[ -z "${GREEN+x}" ]] && GREEN='\033[0;32m'
[[ -z "${YELLOW+x}" ]] && YELLOW='\033[1;33m'
[[ -z "${RED+x}" ]] && RED='\033[0;31m'
[[ -z "${BLUE+x}" ]] && BLUE='\033[0;34m'
[[ -z "${NC+x}" ]] && NC='\033[0m'

if ! declare -f print_info >/dev/null 2>&1; then
	print_info() { local _m="$1"; printf "${BLUE}[INFO]${NC} %s\n" "$_m"; return 0; }
fi
if ! declare -f print_success >/dev/null 2>&1; then
	print_success() { local _m="$1"; printf "${GREEN}[OK]${NC} %s\n" "$_m"; return 0; }
fi
if ! declare -f print_warning >/dev/null 2>&1; then
	print_warning() { local _m="$1"; printf "${YELLOW}[WARN]${NC} %s\n" "$_m"; return 0; }
fi
if ! declare -f print_error >/dev/null 2>&1; then
	print_error() { local _m="$1"; printf "${RED}[ERROR]${NC} %s\n" "$_m"; return 0; }
fi

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

REPOS_FILE="${REPOS_FILE:-${HOME}/.config/aidevops/repos.json}"
PERSONAL_PLANE_BASE="${PERSONAL_PLANE_BASE:-${HOME}/.aidevops/.agent-workspace/knowledge}"
KNOWLEDGE_ROOT="${KNOWLEDGE_ROOT:-_knowledge}"
AUDIT_LOG_NAME="audit.log"
LOGFILE="${LOGFILE:-/dev/null}"

SCRIPT_TEMPLATES_DIR="${SCRIPT_DIR%/scripts}/templates"

# ---------------------------------------------------------------------------
# _find_knowledge_root — locate the active knowledge plane root
# ---------------------------------------------------------------------------

_find_knowledge_root() {
	local cwd
	cwd="$(pwd)"

	if [[ -d "${cwd}/${KNOWLEDGE_ROOT}" ]]; then
		printf '%s\n' "${cwd}/${KNOWLEDGE_ROOT}"
		return 0
	fi

	if [[ -d "${PERSONAL_PLANE_BASE}" ]]; then
		printf '%s\n' "${PERSONAL_PLANE_BASE}"
		return 0
	fi

	return 1
}

# ---------------------------------------------------------------------------
# _read_trust_config — read the .trust block from knowledge.json
# ---------------------------------------------------------------------------

_read_trust_config() {
	local root="$1"
	local config_file="${root}/_config/knowledge.json"

	if [[ ! -f "$config_file" ]]; then
		printf '{}\n'
		return 0
	fi

	local content
	content=$(jq -r '.trust // {}' "$config_file" 2>/dev/null) || content="{}"
	printf '%s\n' "$content"
	return 0
}

# ---------------------------------------------------------------------------
# _check_auto_promote_rules — check ingested_by and source_uri against config
# Returns 0 if matches an auto_promote rule, 1 otherwise
# ---------------------------------------------------------------------------

_check_auto_promote_rules() {
	local ingested_by="$1"
	local source_uri="$2"
	local trust_config="$3"

	local entry
	local auto_bots auto_emails auto_paths

	auto_bots=$(printf '%s' "$trust_config" \
		| jq -r '.auto_promote.from_bots // [] | .[]' 2>/dev/null) || auto_bots=""
	auto_emails=$(printf '%s' "$trust_config" \
		| jq -r '.auto_promote.from_emails // [] | .[]' 2>/dev/null) || auto_emails=""
	auto_paths=$(printf '%s' "$trust_config" \
		| jq -r '.auto_promote.from_paths // [] | .[]' 2>/dev/null) || auto_paths=""

	while IFS= read -r entry; do
		[[ -z "$entry" ]] && continue
		[[ "$ingested_by" == "$entry" ]] && return 0
	done <<< "$auto_bots"

	while IFS= read -r entry; do
		[[ -z "$entry" ]] && continue
		[[ "$ingested_by" == "$entry" ]] && return 0
	done <<< "$auto_emails"

	while IFS= read -r entry; do
		[[ -z "$entry" ]] && continue
		local expanded="${entry/#\~/$HOME}"
		[[ "$source_uri" == "${expanded}"* ]] && return 0
	done <<< "$auto_paths"

	return 1
}

# ---------------------------------------------------------------------------
# _resolve_trust_class — classify a source: auto_promote / review_gate / untrusted
# ---------------------------------------------------------------------------

_resolve_trust_class() {
	local meta_json="$1"
	local trust_config="$2"

	local trust ingested_by source_uri
	trust=$(printf '%s' "$meta_json" | jq -r '.trust // "unverified"' 2>/dev/null) \
		|| trust="unverified"
	ingested_by=$(printf '%s' "$meta_json" | jq -r '.ingested_by // ""' 2>/dev/null) \
		|| ingested_by=""
	source_uri=$(printf '%s' "$meta_json" | jq -r '.source_uri // ""' 2>/dev/null) \
		|| source_uri=""

	# Explicit trust fields override config rules
	if [[ "$trust" == "authoritative" || "$trust" == "trusted" ]]; then
		printf 'auto_promote\n'
		return 0
	fi

	# Check config auto_promote rules
	if _check_auto_promote_rules "$ingested_by" "$source_uri" "$trust_config"; then
		printf 'auto_promote\n'
		return 0
	fi

	# Check review_gate emails
	local rg_emails entry
	rg_emails=$(printf '%s' "$trust_config" \
		| jq -r '.review_gate.from_emails // [] | .[]' 2>/dev/null) || rg_emails=""
	while IFS= read -r entry; do
		[[ -z "$entry" ]] && continue
		[[ "$ingested_by" == "$entry" ]] && { printf 'review_gate\n'; return 0; }
	done <<< "$rg_emails"

	printf 'untrusted\n'
	return 0
}

# ---------------------------------------------------------------------------
# _append_audit_log — write JSONL record to _knowledge/index/audit.log
# ---------------------------------------------------------------------------

_append_audit_log() {
	local root="$1"
	local action="$2"
	local source_id="$3"
	local extra="${4:-}"

	local index_dir="${root}/index"
	mkdir -p "$index_dir" 2>/dev/null || true
	local audit_file="${index_dir}/${AUDIT_LOG_NAME}"

	local ts actor
	ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null) || ts=""
	actor="${AIDEVOPS_ACTOR:-$(whoami 2>/dev/null || echo "agent")}"

	local record
	record=$(jq -nc \
		--arg ts "$ts" \
		--arg action "$action" \
		--arg source_id "$source_id" \
		--arg actor "$actor" \
		--arg extra "$extra" \
		'{ts:$ts,action:$action,source_id:$source_id,actor:$actor,extra:$extra}' \
		2>/dev/null) \
		|| record="{\"ts\":\"${ts}\",\"action\":\"${action}\",\"source_id\":\"${source_id}\"}"

	printf '%s\n' "$record" >> "$audit_file"
	return 0
}

# ---------------------------------------------------------------------------
# _move_to_staging — move source directory from inbox/ to staging/
# ---------------------------------------------------------------------------

_move_to_staging() {
	local root="$1"
	local source_id="$2"
	local inbox_path="${root}/inbox/${source_id}"
	local staging_path="${root}/staging/${source_id}"

	[[ -e "$inbox_path" ]] || return 1
	mkdir -p "${root}/staging" 2>/dev/null || true
	mv "$inbox_path" "$staging_path" 2>/dev/null || return 1
	return 0
}

# ---------------------------------------------------------------------------
# _update_meta_state — patch .state (and optional timestamp) into meta.json
# ---------------------------------------------------------------------------

_update_meta_state() {
	local meta_file="$1"
	local new_state="$2"
	local ts_field="${3:-}"
	local extra_key="${4:-}"
	local extra_val="${5:-}"

	[[ -f "$meta_file" ]] || return 0

	local ts
	ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null) || ts=""
	local parent_dir
	parent_dir="$(dirname "$meta_file")"
	local tmp
	tmp=$(mktemp "${parent_dir}/.meta.XXXXXX" 2>/dev/null) || return 0

	# SC2016: single-quoted $state/$ts/$extra are jq arg references, not shell vars
	# shellcheck disable=SC2016
	local jq_filter='.state = $state'
	[[ -n "$ts_field" ]] && jq_filter="${jq_filter} | .${ts_field} = \$ts"
	[[ -n "$extra_key" ]] && jq_filter="${jq_filter} | .${extra_key} = \$extra"

	if jq --arg state "$new_state" --arg ts "$ts" --arg extra "$extra_val" \
		"$jq_filter" "$meta_file" > "$tmp" 2>/dev/null; then
		mv "$tmp" "$meta_file"
	else
		rm -f "$tmp"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# _move_to_sources — move source directory from staging/ to sources/
# ---------------------------------------------------------------------------

_move_to_sources() {
	local root="$1"
	local source_id="$2"
	local staging_path="${root}/staging/${source_id}"
	local sources_path="${root}/sources/${source_id}"

	[[ -e "$staging_path" ]] || return 1
	mkdir -p "${root}/sources" 2>/dev/null || true
	mv "$staging_path" "$sources_path" 2>/dev/null || return 1
	_update_meta_state "${sources_path}/meta.json" "promoted" "promoted_at"
	return 0
}

# ---------------------------------------------------------------------------
# _extract_preview — extract up to N chars from first text file in a dir
# ---------------------------------------------------------------------------

_extract_preview() {
	local source_dir="$1"
	local max_chars="${2:-500}"
	local preview=""

	local found_file
	found_file=$(find "$source_dir" -maxdepth 1 \
		\( -name "*.txt" -o -name "*.md" -o -name "*.json" \) \
		2>/dev/null | head -1)

	if [[ -n "$found_file" && -f "$found_file" ]]; then
		preview=$(dd if="$found_file" bs=1 count="$max_chars" 2>/dev/null \
			| tr -d '\0' | tr '\n' ' ')
	fi

	printf '%s' "${preview:-(no preview available)}"
	return 0
}

# ---------------------------------------------------------------------------
# _build_nmr_body_file — write NMR issue body to a temp file, return path
# ---------------------------------------------------------------------------

_build_nmr_body_file() {
	local root="$1"
	local source_id="$2"
	local meta_json="$3"
	local trust_class="$4"
	local repo_slug="$5"

	local kind sha256 size_bytes ingested_by sensitivity
	kind=$(printf '%s' "$meta_json" | jq -r '.kind // "unknown"' 2>/dev/null) \
		|| kind=""
	sha256=$(printf '%s' "$meta_json" | jq -r '.sha256 // ""' 2>/dev/null) \
		|| sha256=""
	size_bytes=$(printf '%s' "$meta_json" | jq -r '.size_bytes // 0' 2>/dev/null) \
		|| size_bytes=0
	ingested_by=$(printf '%s' "$meta_json" | jq -r '.ingested_by // "unknown"' 2>/dev/null) \
		|| ingested_by=""
	sensitivity=$(printf '%s' "$meta_json" | jq -r '.sensitivity // "internal"' 2>/dev/null) \
		|| sensitivity="internal"

	local staging_dir="${root}/staging/${source_id}"
	local preview
	preview=$(_extract_preview "$staging_dir" 500)

	local body_file
	# t2997: drop .md — XXXXXX must be at end for BSD mktemp; gh issue body-file
	# reads content regardless of extension.
	body_file=$(mktemp /tmp/knowledge-review-body-XXXXXX 2>/dev/null) || return 1

	local tmpl="${SCRIPT_TEMPLATES_DIR}/knowledge-review-nmr-body.md"
	if [[ -f "$tmpl" ]]; then
		sed -e "s|{{SOURCE_ID}}|${source_id}|g" \
			-e "s|{{REPO_SLUG}}|${repo_slug}|g" \
			-e "s|{{KIND}}|${kind}|g" \
			-e "s|{{SHA256}}|${sha256}|g" \
			-e "s|{{SIZE_BYTES}}|${size_bytes}|g" \
			-e "s|{{INGESTED_BY}}|${ingested_by}|g" \
			-e "s|{{SENSITIVITY}}|${sensitivity}|g" \
			-e "s|{{TRUST_CLASS}}|${trust_class}|g" \
			"$tmpl" > "$body_file" 2>/dev/null || true
		printf "\n\n**Preview (first 500 chars):**\n\n\`\`\`\n%s\n\`\`\`\n" "$preview" \
			>> "$body_file"
	else
		cat > "$body_file" <<BODY
<!-- aidevops:knowledge-review source_id:${source_id} -->

## Knowledge Source Review Request

A new knowledge source requires review before promotion to \`sources/\`.

| Field | Value |
|-------|-------|
| Source ID | \`${source_id}\` |
| Kind | ${kind} |
| SHA256 | \`${sha256}\` |
| Size | ${size_bytes} bytes |
| Ingested by | ${ingested_by} |
| Sensitivity | ${sensitivity} |
| Trust class | ${trust_class} |

**Preview (first 500 chars):**

\`\`\`
${preview}
\`\`\`

## Review Actions

- Approve: after reviewing the staged source, run
  \`knowledge-review-helper.sh promote ${source_id}\`, then close this issue.
- Reject: close the issue without approving (source stays in staging/)

Source staged at: \`_knowledge/staging/${source_id}/\`
BODY
	fi

	printf '%s\n' "$body_file"
	return 0
}

# ---------------------------------------------------------------------------
# _file_nmr_issue — create a GitHub issue for a review-required source
# The legacy function/state name is retained for on-disk compatibility.
# Returns the issue URL on success
# ---------------------------------------------------------------------------

_file_nmr_issue() {
	local root="$1"
	local source_id="$2"
	local meta_json="$3"
	local trust_class="$4"
	local repo_slug="$5"

	[[ -z "$repo_slug" ]] && return 1

	local body_file
	body_file=$(_build_nmr_body_file "$root" "$source_id" "$meta_json" "$trust_class" "$repo_slug") \
		|| return 1

	# Append signature footer (two-call pattern: write file, then post)
	if command -v gh-signature-helper.sh >/dev/null 2>&1; then
		gh-signature-helper.sh footer --model "${AIDEVOPS_MODEL:-unknown}" \
			>> "$body_file" 2>/dev/null || true
	fi

	local labels="kind:knowledge-review"
	if [[ "$trust_class" == "untrusted" ]]; then
		labels="${labels},hold-for-review"
	else
		labels="${labels},auto-dispatch"
	fi

	local kind
	kind=$(printf '%s' "$meta_json" | jq -r '.kind' 2>/dev/null) || kind=""
	local issue_title="Knowledge review: ${source_id} (${kind:-document})"

	local issue_url
	# gh_create_issue from shared-gh-wrappers.sh is required (sourced at script top)
	if ! declare -f gh_create_issue >/dev/null 2>&1; then
		echo "[knowledge-review] _file_nmr_issue: gh_create_issue not available, cannot file issue" >> "$LOGFILE"
		rm -f "$body_file"
		return 1
	fi
	issue_url=$(gh_create_issue \
		--repo "$repo_slug" \
		--title "$issue_title" \
		--label "$labels" \
		--body-file "$body_file" \
		2>/dev/null) || issue_url=""

	rm -f "$body_file"

	if [[ -n "$issue_url" ]]; then
		printf '%s\n' "$issue_url"
		_append_audit_log "$root" "nmr_filed" "$source_id" \
			"issue:${issue_url} trust_class:${trust_class}"
		return 0
	fi

	return 1
}

# ---------------------------------------------------------------------------
# _auto_promote — inbox → staging → sources for a trusted source
# ---------------------------------------------------------------------------

_auto_promote() {
	local root="$1"
	local source_id="$2"
	local actor="${3:-auto}"

	if ! _move_to_staging "$root" "$source_id"; then
		print_warning "knowledge-review: auto-promote: failed to move ${source_id} to staging"
		return 1
	fi

	if ! _move_to_sources "$root" "$source_id"; then
		print_warning "knowledge-review: auto-promote: failed to move ${source_id} to sources"
		return 1
	fi

	_append_audit_log "$root" "auto_promoted" "$source_id" "actor:${actor}"
	print_success "knowledge-review: auto-promoted ${source_id}"
	return 0
}

# ---------------------------------------------------------------------------
# _is_already_processed — idempotency guard
# Returns 0 if source was already processed, 1 if new/pending
# ---------------------------------------------------------------------------

_is_already_processed() {
	local root="$1"
	local source_id="$2"

	[[ -e "${root}/sources/${source_id}" ]] && return 0

	local meta_file="${root}/staging/${source_id}/meta.json"
	if [[ -f "$meta_file" ]]; then
		local state
		state=$(jq -r '.state // ""' "$meta_file" 2>/dev/null) || state=""
		case "$state" in
		nmr_filed | staged | promoted)
			return 0
			;;
		esac
	fi

	return 1
}

# ---------------------------------------------------------------------------
# _get_repo_slug — resolve owner/repo from repos.json or git remote
# ---------------------------------------------------------------------------

_get_repo_slug() {
	local cwd="${1:-$(pwd)}"
	local slug=""

	if [[ -f "$REPOS_FILE" ]] && command -v jq >/dev/null 2>&1; then
		slug=$(jq -r --arg p "$cwd" \
			'.initialized_repos[] | select(.path == $p) | .slug // ""' \
			"$REPOS_FILE" 2>/dev/null | head -1)
	fi

	if [[ -z "$slug" ]]; then
		local remote_url
		remote_url=$(git -C "$cwd" remote get-url origin 2>/dev/null) || remote_url=""
		if [[ -n "$remote_url" ]]; then
			slug=$(printf '%s' "$remote_url" \
				| sed 's|.*github\.com[:/]\(.*\)\.git$|\1|;s|.*github\.com[:/]\(.*\)$|\1|' \
				2>/dev/null)
		fi
	fi

	printf '%s\n' "$slug"
	return 0
}

# ---------------------------------------------------------------------------
# _process_inbox_item — handle a single inbox source during tick
# ---------------------------------------------------------------------------

_process_inbox_item() {
	local root="$1"
	local source_id="$2"
	local meta_json="$3"
	local trust_config="$4"
	local repo_slug="$5"

	local trust_class
	trust_class=$(_resolve_trust_class "$meta_json" "$trust_config")

	if [[ "$trust_class" == "auto_promote" ]]; then
		_auto_promote "$root" "$source_id" "tick"
		return $?
	fi

	# review_gate or untrusted: move to staging, then file issue
	if ! _move_to_staging "$root" "$source_id"; then
		print_warning "knowledge-review: failed to stage ${source_id}"
		return 1
	fi

	if [[ -z "$repo_slug" ]]; then
		print_warning "knowledge-review: no repo slug, staged ${source_id} without issue"
		_append_audit_log "$root" "staged_no_slug" "$source_id" "trust_class:${trust_class}"
		return 0
	fi

	local issue_url=""
	issue_url=$(_file_nmr_issue "$root" "$source_id" "$meta_json" "$trust_class" "$repo_slug") \
		|| issue_url=""

	if [[ -n "$issue_url" ]]; then
		_update_meta_state "${root}/staging/${source_id}/meta.json" \
			"nmr_filed" "staged_at" "nmr_issue_url" "$issue_url"
		return 0
	fi

	print_warning "knowledge-review: failed to file issue for ${source_id}"
	_append_audit_log "$root" "nmr_file_failed" "$source_id" "trust_class:${trust_class}"
	return 1
}

# ---------------------------------------------------------------------------
# cmd_tick — pulse-driven review gate scan (subcommand: tick)
# ---------------------------------------------------------------------------

cmd_tick() {
	local root
	root=$(_find_knowledge_root) || {
		print_info "knowledge-review tick: no knowledge plane found, skipping"
		return 0
	}

	local inbox_dir="${root}/inbox"
	if [[ ! -d "$inbox_dir" ]]; then
		print_info "knowledge-review tick: inbox not found, skipping"
		return 0
	fi

	local repo_slug trust_config
	repo_slug=$(_get_repo_slug) || repo_slug=""
	trust_config=$(_read_trust_config "$root")

	local processed=0 auto_promoted=0 nmr_filed_count=0 skipped=0

	local meta_file
	while IFS= read -r -d '' meta_file; do
		local source_dir source_id meta_json
		source_dir="$(dirname "$meta_file")"
		source_id="$(basename "$source_dir")"

		if _is_already_processed "$root" "$source_id"; then
			skipped=$((skipped + 1))
			continue
		fi

		meta_json=$(jq '.' "$meta_file" 2>/dev/null) || meta_json="{}"
		local trust_class
		trust_class=$(_resolve_trust_class "$meta_json" "$trust_config")

		if _process_inbox_item "$root" "$source_id" "$meta_json" "$trust_config" "$repo_slug"; then
			processed=$((processed + 1))
			if [[ "$trust_class" == "auto_promote" ]]; then
				auto_promoted=$((auto_promoted + 1))
			else
				nmr_filed_count=$((nmr_filed_count + 1))
			fi
		fi
	done < <(find "$inbox_dir" -mindepth 2 -maxdepth 2 -name "meta.json" -print0 2>/dev/null \
		| sort -z)

	echo "[knowledge-review] tick: processed=${processed} auto_promoted=${auto_promoted} nmr_filed=${nmr_filed_count} skipped=${skipped}" >> "$LOGFILE"

	if [[ "$processed" -gt 0 ]]; then
		print_info "knowledge-review tick: processed=${processed} (auto_promoted=${auto_promoted} nmr_filed=${nmr_filed_count} skipped=${skipped})"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# cmd_promote — explicit promotion from staging -> sources (approve hook)
# ---------------------------------------------------------------------------

cmd_promote() {
	local source_id="${1:-}"
	[[ -z "$source_id" ]] && { print_error "promote: source-id required"; return 1; }

	local root
	root=$(_find_knowledge_root) || {
		print_error "promote: no knowledge plane found"
		return 1
	}

	if [[ ! -e "${root}/staging/${source_id}" ]]; then
		print_error "promote: ${source_id} not found in staging/"
		return 1
	fi

	if ! _move_to_sources "$root" "$source_id"; then
		print_error "promote: failed to move ${source_id} to sources/"
		return 1
	fi

	local actor
	actor="${AIDEVOPS_ACTOR:-$(whoami 2>/dev/null || echo "maintainer")}"
	_append_audit_log "$root" "promoted" "$source_id" \
		"actor:${actor} path:approve_hook"
	print_success "knowledge-review: promoted ${source_id} to sources/"
	return 0
}

# ---------------------------------------------------------------------------
# cmd_audit_log — append a manual audit log entry
# ---------------------------------------------------------------------------

cmd_audit_log() {
	local action="${1:-}"
	local source_id="${2:-}"
	local extra="${3:-}"

	if [[ -z "$action" || -z "$source_id" ]]; then
		print_error "audit-log: action and source-id required"
		return 1
	fi

	local root
	root=$(_find_knowledge_root) || {
		print_error "audit-log: no knowledge plane found"
		return 1
	}

	_append_audit_log "$root" "$action" "$source_id" "$extra"
	return 0
}

# ---------------------------------------------------------------------------
# cmd_help
# ---------------------------------------------------------------------------

cmd_help() {
	cat <<'HELP'
knowledge-review-helper.sh — Knowledge plane review gate routine (t2845)

Subcommands:
  tick                       Scan inbox, classify trust, auto-promote or file review
  promote <source-id>        Promote a reviewed source from staging -> sources
  audit-log <action> <id>    Append JSONL entry to _knowledge/index/audit.log
  help                       Show this help

Trust classification (from _knowledge/_config/knowledge.json .trust):
  auto_promote  maintainer/trusted drops → promoted directly + audit-logged
  review_gate   trusted partner email   → kind:knowledge-review + auto-dispatch
  untrusted     default ("*")           → kind:knowledge-review + hold-for-review

Review flow (untrusted sources):
  inspect staged content → knowledge-review-helper.sh promote <source-id> → close issue

Audit log location: _knowledge/index/audit.log (JSONL)
HELP
	return 0
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

main() {
	local cmd="${1:-help}"
	shift || true

	case "$cmd" in
	tick)
		cmd_tick "$@"
		;;
	promote)
		cmd_promote "$@"
		;;
	audit-log)
		cmd_audit_log "$@"
		;;
	help | --help | -h)
		cmd_help
		;;
	*)
		print_error "Unknown subcommand: ${cmd}"
		cmd_help
		return 1
		;;
	esac
	return 0
}

if [[ "${BASH_SOURCE[0]:-$0}" == "$0" ]]; then
	main "$@"
fi

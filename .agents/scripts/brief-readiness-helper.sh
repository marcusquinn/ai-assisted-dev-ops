#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# brief-readiness-helper.sh — Detect worker-ready issue bodies and generate
# repo-native captures of worker-ready issues (t18404; legacy `stub` interface).
#
# Historical issue bodies retain heading-based readiness. Bodies carrying the
# brief schema-v2 marker must also contain substantive write-surface, hazard,
# verification, and positive/negative acceptance evidence.
#
# This helper provides:
#   1. A readiness detector (`check`) that scores an issue body against
#      known heading sets and returns a pass/fail verdict.
#   2. A capture writer (`stub`, retained for compatibility) that preserves
#      the complete observed issue body without overwriting local knowledge.
#   3. A similarity check (`similarity`) that compares an existing brief
#      file against an issue body and reports overlap percentage.
#
# Usage:
#   brief-readiness-helper.sh check   <issue-number> <slug>
#   brief-readiness-helper.sh check   --body <body-text>
#   brief-readiness-helper.sh stub    <task-id> <issue-number> <slug> [repo-path]
#   brief-readiness-helper.sh similarity <brief-path> --body <body-text>
#   brief-readiness-helper.sh help
#
# Exit codes:
#   0 — issue body IS worker-ready (check), or operation succeeded
#   1 — issue body is NOT worker-ready (check), or error
#   2 — usage error
#
# Environment:
#   BRIEF_READINESS_THRESHOLD — override the 4-of-7 heading threshold (default: 4)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)" || exit 1

# shellcheck source=/dev/null
if [[ -f "$SCRIPT_DIR/shared-constants.sh" ]]; then
	source "$SCRIPT_DIR/shared-constants.sh"
fi
# shellcheck source=./task-identity-lib.sh
source "$SCRIPT_DIR/task-identity-lib.sh"

# ---------------------------------------------------------------------------
# Logging (inline fallbacks if shared-constants not sourced)
# ---------------------------------------------------------------------------
if ! command -v log_info >/dev/null 2>&1; then
	log_info()  { printf '[INFO]  %s\n' "$*" >&2; return 0; }
	log_warn()  { printf '[WARN]  %s\n' "$*" >&2; return 0; }
	log_error() { printf '[ERROR] %s\n' "$*" >&2; return 0; }
fi

# ---------------------------------------------------------------------------
# Constants — the heading sets that signal worker-readiness.
#
# Two heading families exist in the wild:
#   Primary:   ## Task, ## Why, ## How, ## Acceptance
#   Alternate: ## What, ## Session Origin, ## Files to modify, ## Worker Guidance
#
# A body scoring >= THRESHOLD across both sets is worker-ready.
# ---------------------------------------------------------------------------
readonly DEFAULT_THRESHOLD=4
readonly BRIEF_SCHEMA_V2_MARKER='<!-- aidevops:brief-schema=v2 -->'
readonly BRIEF_BOOL_TRUE="true"
readonly BRIEF_PARSER_AWK="${SCRIPT_DIR}/brief-readiness-parser.awk"
readonly BRIEF_PARSE_UNFENCED_MODE="unfenced"
readonly BRIEF_PARSE_VISIBLE_MODE="visible"
readonly BRIEF_PARSE_SECTION_MODE="section"
readonly BRIEF_PARSE_PROSE_MODE="prose"

# Primary headings (the brief-template canonical set)
readonly -a PRIMARY_HEADINGS=(
	"## Task"
	"## Why"
	"## How"
	"## Acceptance"
)

# Alternate headings (common in enriched issue bodies)
readonly -a ALTERNATE_HEADINGS=(
	"## What"
	"## Session Origin"
	"## Files to modify"
)

# ---------------------------------------------------------------------------
# _score_body: count how many of the known headings appear in the body.
#
# Args: body_text
# Stdout: integer score (0-7)
# Returns: 0 always
# ---------------------------------------------------------------------------
_score_body() {
	local -a _sb_args=("$@")
	local body="${_sb_args[0]}"
	local score=0

	local heading
	for heading in "${PRIMARY_HEADINGS[@]}" "${ALTERNATE_HEADINGS[@]}"; do
		if printf '%s\n' "$body" | grep -qiF "$heading"; then
			score=$((score + 1))
		fi
	done

	printf '%d\n' "$score"
	return 0
}

_is_schema_v2_brief() {
	local -a _args=("$@")
	local body="${_args[0]}"
	local unfenced=""

	unfenced=$(_unfenced_brief_text "$body")
	if printf '%s\n' "$unfenced" | grep -qF "$BRIEF_SCHEMA_V2_MARKER"; then
		return 0
	fi
	return 1
}

_unfenced_brief_text() {
	local -a _args=("$@")
	local body="${_args[0]}"

	printf '%s\n' "$body" | awk -v mode="$BRIEF_PARSE_UNFENCED_MODE" -f "$BRIEF_PARSER_AWK"
	return 0
}

_visible_brief_text() {
	local -a _args=("$@")
	local body="${_args[0]}"

	printf '%s\n' "$body" | awk -v mode="$BRIEF_PARSE_VISIBLE_MODE" -f "$BRIEF_PARSER_AWK"
	return 0
}

_extract_markdown_section() {
	local -a _args=("$@")
	local body="${_args[0]}"
	local heading="${_args[1]}"
	local include_fenced="${_args[2]:-false}"

	printf '%s\n' "$body" | awk \
		-v mode="$BRIEF_PARSE_SECTION_MODE" \
		-v target="$heading" \
		-v include_fenced="$include_fenced" \
		-v true_value="$BRIEF_BOOL_TRUE" \
		-f "$BRIEF_PARSER_AWK"
	return 0
}

_brief_prose_text() {
	local -a _args=("$@")
	local body="${_args[0]}"

	printf '%s\n' "$body" | awk -v mode="$BRIEF_PARSE_PROSE_MODE" -f "$BRIEF_PARSER_AWK"
	return 0
}

_field_line() {
	local -a _args=("$@")
	local section="${_args[0]}"
	local field="${_args[1]}"

	printf '%s\n' "$section" | grep -iF -m 1 "**${field}:**" || true
	return 0
}

_field_is_substantive() {
	local -a _args=("$@")
	local section="${_args[0]}"
	local field="${_args[1]}"
	local line=""

	line=$(_field_line "$section" "$field")
	[[ -n "$line" ]] || return 1
	if printf '%s\n' "$line" | grep -qiE ':\*\*[[:space:]]*($|TBD$|TODO$|N/?A[[:space:]]*$|unknown[[:space:]]*$|\{|<)'; then
		return 1
	fi
	# The field wrapper contributes eight characters. Require at least four
	# content characters so concrete short paths such as `app.py` remain valid.
	[[ ${#line} -ge $((${#field} + 12)) ]] || return 1
	return 0
}

_write_surface_field_is_valid() {
	local -a _args=("$@")
	local section="${_args[0]}"
	local field="${_args[1]}"
	local line=""

	_field_is_substantive "$section" "$field" || return 1
	line=$(_field_line "$section" "$field")
	if printf '%s\n' "$line" | grep -qE "\`[^\`]+\`|(^|[[:space:]])(EDIT|NEW):"; then
		return 0
	fi
	if printf '%s\n' "$line" | grep -qiE '(N/?A|not applicable|not yet knowable|unknown).*(because|evidence|searched|documentation-only|new-file-only|until|no existing)'; then
		return 0
	fi
	return 1
}

_has_unfilled_placeholder() {
	local -a _args=("$@")
	local body="${_args[0]}"
	local prose=""

	prose=$(_brief_prose_text "$body")
	if printf '%s\n' "$prose" | grep -qiE '<[[:alpha:]][^>]*>|\{[^{}]*(command|path|purpose|criterion|rationale|summary|deliverable|problem|evidence|task|title)[^{}]*\}'; then
		return 0
	fi
	return 1
}

_has_file_target() {
	local -a _args=("$@")
	local section="${_args[0]}"

	if printf '%s\n' "$section" | grep -qE "^[[:space:]]*-[[:space:]]+[\`]?(EDIT|NEW):[[:space:]]+[\`]?[^ \`{<]+"; then
		return 0
	fi
	return 1
}

_has_implementation_step() {
	local -a _args=("$@")
	local section="${_args[0]}"

	if printf '%s\n' "$section" | grep -qE '^[[:space:]]*[0-9]+\.[[:space:]]+[^<{][^{}]{8,}'; then
		return 0
	fi
	return 1
}

_has_executable_verification() {
	local -a _args=("$@")
	local section="${_args[0]}"

	if printf '%s\n' "$section" | grep -qE '^[[:space:]]*(\$[[:space:]]*)?(bash |shellcheck |pytest( |$)|python[0-9]* |node |npm |pnpm |yarn |bun |go test( |$)|cargo test( |$)|make |bundle exec |composer |git diff( |$)|\./|[.][[:alnum:]_/-]+\.sh([[:space:]]|$))'; then
		return 0
	fi
	return 1
}

_validate_v2_body() {
	local -a _args=("$@")
	local body="${_args[0]}"
	local visible=""
	local files_to_modify=""
	local write_surface=""
	local implementation_steps=""
	local hazards=""
	local verification=""
	local acceptance=""
	local errors=""
	local field=""
	local checkbox_count=0
	local checkbox_pattern='^[[:space:]]*-[[:space:]]+\[[ xX]\]'
	local negative_pattern='regression|never|must not|does not|do not|without|rejects?|preserves?|no [[:alnum:]]'

	visible=$(_visible_brief_text "$body")
	files_to_modify=$(_extract_markdown_section "$visible" "### Files to Modify")
	write_surface=$(_extract_markdown_section "$visible" "### Complete Write Surface")
	implementation_steps=$(_extract_markdown_section "$visible" "### Implementation Steps")
	hazards=$(_extract_markdown_section "$visible" "### Hazards and Compatibility")
	verification=$(_extract_markdown_section "$visible" "### Verification Before Dispatch" "$BRIEF_BOOL_TRUE")
	acceptance=$(_extract_markdown_section "$visible" "## Acceptance Criteria")

	_has_file_target "$files_to_modify" || errors="${errors}files-to-modify:target;"
	_has_implementation_step "$implementation_steps" || errors="${errors}implementation-steps:substantive;"

	for field in "Callers/readers" "Writers/mutation paths" "Tests/fixtures" "Schemas/config" "Generated/deployed mirrors" "Migrations/backfills" "Cleanup/rollback paths"; do
		_write_surface_field_is_valid "$write_surface" "$field" || errors="${errors}write-surface:${field};"
	done

	for field in "Concurrency/atomicity" "Migration/rollback" "Mixed-version/backward compatibility" "Idempotency/retry" "Partial failure/recovery"; do
		_field_is_substantive "$hazards" "$field" || errors="${errors}hazard:${field};"
	done

	_field_is_substantive "$verification" "Surface mapping" || errors="${errors}verification:surface-mapping;"
	_has_executable_verification "$verification" || errors="${errors}verification:command;"

	checkbox_count=$(printf '%s\n' "$acceptance" | grep -cE "$checkbox_pattern" || true)
	[[ "$checkbox_count" -ge 2 ]] || errors="${errors}acceptance:multiple-observable-criteria;"
	printf '%s\n' "$acceptance" | grep -E "$checkbox_pattern" | grep -qiE "$negative_pattern" || errors="${errors}acceptance:negative-regression;"
	printf '%s\n' "$acceptance" | grep -E "$checkbox_pattern" | grep -viE "$negative_pattern" | grep -q . || errors="${errors}acceptance:positive;"
	_has_unfilled_placeholder "$visible" && errors="${errors}placeholder:unfilled;"

	if [[ -n "$errors" ]]; then
		printf 'VALIDATION_ERRORS=%s\n' "$errors"
		return 1
	fi
	printf 'VALIDATION_ERRORS=none\n'
	return 0
}

# ---------------------------------------------------------------------------
# _is_worker_ready: check whether a body meets the readiness threshold.
#
# Args: body_text [threshold]
# Returns: 0 if worker-ready, 1 if not
# ---------------------------------------------------------------------------
_is_worker_ready() {
	local -a _iwr_args=("$@")
	local body="${_iwr_args[0]}"
	local threshold="${_iwr_args[1]:-${BRIEF_READINESS_THRESHOLD:-$DEFAULT_THRESHOLD}}"
	local score_body="$body"
	local schema_v2=0
	local score=""

	if _is_schema_v2_brief "$body"; then
		schema_v2=1
		score_body=$(_unfenced_brief_text "$body")
	fi
	score=$(_score_body "$score_body")

	[[ "$score" -ge "$threshold" ]] || return 1
	if [[ "$schema_v2" -eq 1 ]]; then
		_validate_v2_body "$body" >/dev/null || return 1
	fi
	return 0
}

# ---------------------------------------------------------------------------
# _fetch_issue_body: retrieve the body text of a GitHub issue.
#
# Args: issue_number slug
# Stdout: body text
# Returns: 0 on success, 1 on failure
# ---------------------------------------------------------------------------
_fetch_issue_body() {
	local -a _fib_args=("$@")
	local issue_number="${_fib_args[0]}"
	local slug="${_fib_args[1]}"

	local body
	body=$(gh_issue_view "$issue_number" --repo "$slug" --json body --jq '.body' 2>/dev/null) || {
		log_error "Failed to fetch issue #${issue_number} from ${slug}"
		return 1
	}

	printf '%s\n' "$body"
	return 0
}

# ---------------------------------------------------------------------------
# cmd_check: score an issue body and report worker-readiness.
#
# Args: <issue-number> <slug>  OR  --body <body-text>
# Stdout: WORKER_READY=true/false, SCORE=N, THRESHOLD=N
# Exit: 0 if worker-ready, 1 if not
# ---------------------------------------------------------------------------
cmd_check() {
	local body=""
	local issue_number=""
	local slug=""
	local threshold="${BRIEF_READINESS_THRESHOLD:-$DEFAULT_THRESHOLD}"

	# Capture all args into a local array to avoid direct $1/$2 references
	local -a _args=("$@")
	local _i=0 _len="${#_args[@]}" _cur=""

	while [[ $_i -lt $_len ]]; do
		_cur="${_args[$_i]}"
		case "$_cur" in
		--body)
			_i=$((_i + 1)); body="${_args[$_i]}" ;;
		--threshold)
			_i=$((_i + 1)); threshold="${_args[$_i]}" ;;
		*)
			if [[ -z "$issue_number" ]]; then
				issue_number="$_cur"
			elif [[ -z "$slug" ]]; then
				slug="$_cur"
			else
				log_error "Unexpected argument: $_cur"
				return 2
			fi
			;;
		esac
		_i=$((_i + 1))
	done

	# Fetch body from GitHub if not provided inline
	if [[ -z "$body" ]]; then
		if [[ -z "$issue_number" || -z "$slug" ]]; then
			log_error "Usage: brief-readiness-helper.sh check <issue-number> <slug>"
			log_error "       brief-readiness-helper.sh check --body <body-text>"
			return 2
		fi
		body=$(_fetch_issue_body "$issue_number" "$slug") || return 1
	fi

	local score_body="$body"
	local schema_v2=0
	local score=""
	local ready="false"
	local exit_code=1
	local schema="legacy"
	local validation="VALIDATION_ERRORS=not-applicable"

	if _is_schema_v2_brief "$body"; then
		schema_v2=1
		score_body=$(_unfenced_brief_text "$body")
	fi
	score=$(_score_body "$score_body")

	if [[ "$schema_v2" -eq 1 ]]; then
		schema="v2"
		if [[ "$score" -ge "$threshold" ]] && validation=$(_validate_v2_body "$body"); then
			ready="$BRIEF_BOOL_TRUE"
			exit_code=0
		fi
	elif [[ "$score" -ge "$threshold" ]]; then
		ready="true"
		exit_code=0
	fi

	printf 'WORKER_READY=%s\n' "$ready"
	printf 'SCORE=%d\n' "$score"
	printf 'THRESHOLD=%d\n' "$threshold"
	printf 'SCHEMA=%s\n' "$schema"
	printf '%s\n' "$validation"

	return "$exit_code"
}

# ---------------------------------------------------------------------------
# cmd_stub: capture the observed issue body, retaining the legacy command name.
#
# Args: <task-id> <issue-number> <slug> [repo-path]
# Creates: todo/tasks/{task_id}-brief.md (full body plus provenance)
# Exit: 0 on success
# ---------------------------------------------------------------------------
cmd_stub() {
	local -a _stub_args=("$@")
	local task_id="${_stub_args[0]:-}"
	local issue_number="${_stub_args[1]:-}"
	local slug="${_stub_args[2]:-}"
	local repo_path="${_stub_args[3]:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"

	if ! task_identity_validate "$task_id" || [[ ! "$issue_number" =~ ^[1-9][0-9]*$ ||
		! "$slug" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ || ! -d "$repo_path" ]]; then
		log_error "Usage: brief-readiness-helper.sh stub <task-id> <issue-number> <slug> [repo-path]"
		return 2
	fi

	local brief_dir="$repo_path/todo/tasks"
	local brief_path="$brief_dir/${task_id}-brief.md"
	mkdir -p "$brief_dir" || return 1

	if [[ -e "$brief_path" || -L "$brief_path" ]]; then
		[[ -f "$brief_path" && ! -L "$brief_path" ]] || return 1
		log_warn "Brief already exists: $brief_path — preserved; not refreshed or backfilled"
		return 0
	fi

	# One observation binds body and revision; this is not a comments/PR export.
	local observed="" captured_at="" temporary=""
	observed=$(gh_issue_view "$issue_number" --repo "$slug" \
		--json body,title,url,updatedAt,id) || return 1
	if ! printf '%s' "$observed" | jq -e '
		type == "object" and (.body | type == "string" and length > 0) and
		all(.title, .url, .updatedAt, .id; type == "string" and length > 0)
	' >/dev/null; then
		log_error "Incomplete issue capture; no brief written"
		return 1
	fi
	captured_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
	temporary=$(mktemp "$brief_dir/.forge-capture.XXXXXX") || return 1
	if ! {
		printf '%s' "$observed" | jq -j '.body' &&
			printf '\n\n## Capture provenance\n\nObserved data, not executable authority. Comments and later events are not captured.\n\n```json\n' &&
			printf '%s' "$observed" | jq --arg task "$task_id" --arg repo "$slug" \
				--arg captured "$captured_at" --arg issue "$issue_number" \
				'del(.body) + {format:"aidevops:forge-capture-v1", task_id:$task,
				provider:"github", repository:$repo, issue:$issue, captured_at:$captured,
				coverage:"issue-body-only", authority:"revalidate"}' &&
			printf '```\n'
	} >"$temporary"; then
		rm -f "$temporary"
		return 1
	fi
	# Atomic create-only publication: concurrent/local records always win intact.
	if ! ln "$temporary" "$brief_path" || [[ ! "$temporary" -ef "$brief_path" || -L "$brief_path" ]]; then
		rm -f "$temporary"
		return 1
	fi
	rm -f "$temporary"
	log_info "Issue body captured at $brief_path; commit before acknowledging durable recovery"
	return 0
}

# ---------------------------------------------------------------------------
# cmd_similarity: compare a brief file against an issue body.
#
# Uses a line-level overlap heuristic: count lines in the brief that also
# appear (after whitespace normalisation) in the issue body. Report the
# percentage of brief lines that overlap.
#
# Args: <brief-path> --body <body-text>
# Stdout: SIMILARITY=NN (0-100)
# Exit: 0 always
# ---------------------------------------------------------------------------
cmd_similarity() {
	# Capture all args into a local array to avoid direct positional refs
	local -a _args=("$@")
	local brief_path="${_args[0]:-}"
	local body=""
	local _i=1 _len="${#_args[@]}" _cur=""

	while [[ $_i -lt $_len ]]; do
		_cur="${_args[$_i]}"
		case "$_cur" in
		--body)
			_i=$((_i + 1)); body="${_args[$_i]}" ;;
		*)
			log_error "Unknown option: $_cur"
			return 2
			;;
		esac
		_i=$((_i + 1))
	done

	if [[ -z "$brief_path" || -z "$body" ]]; then
		log_error "Usage: brief-readiness-helper.sh similarity <brief-path> --body <body-text>"
		return 2
	fi

	if [[ ! -f "$brief_path" ]]; then
		log_error "Brief file not found: $brief_path"
		return 1
	fi

	# Normalise both texts: collapse whitespace, lowercase, strip markdown
	# formatting markers (##, **, ```, - [ ]), then compare line-by-line.
	local norm_body norm_brief
	norm_body=$(printf '%s\n' "$body" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//; s/[[:space:]]+/ /g' | tr '[:upper:]' '[:lower:]' | grep -v '^$' || true)
	norm_brief=$(sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//; s/[[:space:]]+/ /g' "$brief_path" | tr '[:upper:]' '[:lower:]' | grep -v '^$' || true)

	local total_lines=0
	local matching_lines=0

	while IFS= read -r line; do
		# Skip very short lines (headers, blank, markers) — they match too easily
		if [[ ${#line} -lt 10 ]]; then
			continue
		fi
		total_lines=$((total_lines + 1))
		if printf '%s\n' "$norm_body" | grep -qF "$line"; then
			matching_lines=$((matching_lines + 1))
		fi
	done <<<"$norm_brief"

	local similarity=0
	if [[ "$total_lines" -gt 0 ]]; then
		similarity=$(( (matching_lines * 100) / total_lines ))
	fi

	printf 'SIMILARITY=%d\n' "$similarity"
	return 0
}

# ---------------------------------------------------------------------------
# cmd_help
# ---------------------------------------------------------------------------
cmd_help() {
	cat <<'USAGE'
brief-readiness-helper.sh — Detect worker-ready issue bodies (t2417)

Usage:
  check <issue-number> <slug>           Score an issue body for worker-readiness
  check --body <body-text>              Score inline body text
  stub  <task-id> <issue> <slug> [path] Capture full body/provenance, create-only
  similarity <brief-path> --body <text> Compare brief vs issue body overlap (%)
  help                                  Show this help

Exit codes:
  0 — worker-ready (check), or operation succeeded
  1 — not worker-ready (check), or error
  2 — usage error

Environment:
  BRIEF_READINESS_THRESHOLD  Override the 4-of-7 heading threshold (default: 4)
USAGE
	return 0
}

# ---------------------------------------------------------------------------
# Main dispatch
# ---------------------------------------------------------------------------
main() {
	local -a _main_args=("$@")
	local cmd="${_main_args[0]:-help}"

	# Remove first element to pass remaining args
	local -a _rest=("${_main_args[@]:1}")

	case "$cmd" in
	check)      cmd_check "${_rest[@]}" ;;
	stub)       cmd_stub "${_rest[@]}" ;;
	similarity) cmd_similarity "${_rest[@]}" ;;
	help|--help|-h) cmd_help ;;
	*)
		log_error "Unknown command: $cmd"
		cmd_help
		return 2
		;;
	esac
}

main "$@"

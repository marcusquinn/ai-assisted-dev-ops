#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# aidevops Issue Logger Helper
# =============================================================================
# Gathers diagnostic information for issue reporting
# Usage: log-issue-helper.sh [diagnostics|check-auth|search "query"]

set -euo pipefail

# Shared version-finding logic (avoids duplication with aidevops-update-check.sh)
# shellcheck source=lib/version.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/version.sh"

# Shared fingerprint algorithm (also used by issue-sync-reusable.yml server-side dedup)
# shellcheck source=lib/issue-fingerprint.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/issue-fingerprint.sh"

# -----------------------------------------------------------------------------
# Diagnostic Information Gathering
# -----------------------------------------------------------------------------

get_aidevops_version() {
	# Delegate to shared library function (lib/version.sh)
	aidevops_find_version
}

get_latest_version() {
	curl --proto '=https' -fsSL \
		"https://raw.githubusercontent.com/marcusquinn/aidevops/main/VERSION" \
		2>/dev/null || echo "unknown"
	return 0
}

detect_ai_assistant() {
	# Detect which AI coding assistant is running
	if [[ "${OPENCODE:-}" == "1" ]]; then
		echo "OpenCode"
	elif [[ -n "${CLAUDE_CODE:-}" ]] || [[ -n "${CLAUDE_SESSION_ID:-}" ]]; then
		echo "Claude Code"
	elif [[ -n "${CURSOR_SESSION:-}" ]] || [[ "${TERM_PROGRAM:-}" == "cursor" ]]; then
		echo "Cursor"
	elif [[ -n "${WINDSURF_SESSION:-}" ]]; then
		echo "Windsurf"
	elif [[ -n "${CONTINUE_SESSION:-}" ]]; then
		echo "Continue"
	elif [[ -n "${AIDER_SESSION:-}" ]]; then
		echo "Aider"
	elif [[ -n "${AUGMENT_SESSION:-}" ]]; then
		echo "Augment"
	elif [[ -n "${COPILOT_SESSION:-}" ]]; then
		echo "GitHub Copilot"
	elif [[ -n "${CODY_SESSION:-}" ]]; then
		echo "Cody"
	elif [[ -n "${KILO_SESSION:-}" ]]; then
		echo "Kilo Code"
	else
		# Check parent process
		local parent
		parent=$(ps -o comm= -p "${PPID:-0}" 2>/dev/null || echo "")
		case "$parent" in
		*opencode*) echo "OpenCode" ;;
		*claude*) echo "Claude Code" ;;
		*cursor*) echo "Cursor" ;;
		*aider*) echo "Aider" ;;
		*) echo "Unknown" ;;
		esac
	fi
	return 0
}

get_install_method() {
	# Detect how aidevops was installed
	local aidevops_path
	aidevops_path=$(command -v aidevops 2>/dev/null || echo "")

	if [[ -z "$aidevops_path" ]]; then
		echo "not in PATH"
	elif [[ "$aidevops_path" == *"homebrew"* ]] || [[ "$aidevops_path" == "/opt/homebrew"* ]]; then
		echo "Homebrew"
	elif [[ "$aidevops_path" == *"node_modules"* ]] || [[ "$aidevops_path" == *"npm"* ]]; then
		echo "npm"
	elif [[ "$aidevops_path" == "$HOME/Git/aidevops"* ]]; then
		echo "source (Git clone)"
	else
		echo "unknown ($aidevops_path)"
	fi
	return 0
}

get_git_context() {
	local repo branch toplevel
	toplevel=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
	if [[ -n "$toplevel" ]]; then
		repo=$(basename "$toplevel")
		branch=$(git branch --show-current 2>/dev/null || echo "detached")
	else
		repo="none"
		branch="n/a"
	fi
	echo "$repo ($branch)"
	return 0
}

gather_diagnostics() {
	local current_version latest_version ai_assistant install_method
	local os_info shell_info git_context ai_model_line=""

	current_version=$(get_aidevops_version)
	latest_version=$(get_latest_version)
	ai_assistant=$(detect_ai_assistant)
	install_method=$(get_install_method)
	git_context=$(get_git_context)
	if [[ -n "${AIDEVOPS_SIG_MODEL:-}" ]]; then
		ai_model_line=$'\n- **AI Model**: '"${AIDEVOPS_SIG_MODEL//$'\n'/}"
	fi

	# OS info
	if [[ "$(uname)" == "Darwin" ]]; then
		os_info="macOS $(sw_vers -productVersion 2>/dev/null || echo 'unknown')"
	elif [[ "$(uname)" == "Linux" ]]; then
		# Use || true to prevent pipefail from exiting on missing PRETTY_NAME
		os_info=$(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d'"' -f2 || true)
		# Fallback if PRETTY_NAME not found or empty
		: "${os_info:=Linux $(uname -r)}"
	else
		os_info="$(uname -s) $(uname -r)"
	fi

	# Shell info
	shell_info="${SHELL:-unknown}"
	if [[ -n "${ZSH_VERSION:-}" ]]; then
		shell_info="zsh $ZSH_VERSION"
	elif [[ -n "${BASH_VERSION:-}" ]]; then
		shell_info="bash $BASH_VERSION"
	fi

	# Output in markdown format
	cat <<EOF
- **aidevops version**: $current_version
- **Latest version**: $latest_version
- **Install method**: $install_method
- **AI Assistant**: $ai_assistant${ai_model_line}
- **OS**: $os_info
- **Shell**: $shell_info
- **Working repo**: $git_context
- **gh CLI**: $(gh --version 2>/dev/null | head -1 || echo "not installed")
EOF
	return 0
}

# -----------------------------------------------------------------------------
# GitHub CLI Helpers
# -----------------------------------------------------------------------------

check_gh_auth() {
	if ! command -v gh &>/dev/null; then
		echo "ERROR: GitHub CLI (gh) not installed" >&2
		echo "Install with: brew install gh (macOS) or apt install gh (Linux)" >&2
		return 1
	fi

	if ! gh auth status &>/dev/null; then
		echo "ERROR: GitHub CLI not authenticated" >&2
		echo "Run: gh auth login" >&2
		return 1
	fi

	echo "OK: GitHub CLI authenticated"
	return 0
}

search_issues() {
	local query="$1"

	# Verify gh CLI is available and authenticated before searching
	if ! check_gh_auth >/dev/null 2>&1; then
		check_gh_auth # Run again to show error message
		return 1
	fi

	gh issue list -R marcusquinn/aidevops \
		--state all \
		--search "$query" \
		--limit 10 \
		--json number,title,state,url \
		--jq '.[] | "#\(.number) [\(.state)] \(.title)\n   \(.url)"'
	return 0
}

is_valid_issue_number() {
	local issue_number="$1"

	[[ "$issue_number" =~ ^[1-9][0-9]*$ ]]
	return $?
}

# =============================================================================
# Issue Fingerprint Deduplication (GH#20322)
# =============================================================================
# Prevents duplicate filings from the same or subsequent sessions within a
# configurable time window.
#
# State file: ~/.aidevops/state/log-issue-fingerprints.jsonl
# Each line:  {"hash":"<sha256>","issue":<number>,"filed_at":"<ISO8601>","filed_epoch":<epoch>}
#
# Env var:    LOG_ISSUE_DEDUP_WINDOW_SECONDS  (default: 120)
# =============================================================================

_log_issue_fingerprint_file() {
	echo "${HOME}/.aidevops/state/log-issue-fingerprints.jsonl"
	return 0
}

_log_issue_dedup_window() {
	echo "${LOG_ISSUE_DEDUP_WINDOW_SECONDS:-120}"
	return 0
}

# _normalize_body_for_fingerprint and _compute_issue_fingerprint are now provided
# by lib/issue-fingerprint.sh (sourced above). This single source of truth is
# shared with the issue-sync-reusable.yml server-side dedup workflow (GH#21744).

# check_recent_filing <title> <body>
# Exits 0 and prints "OK" if no duplicate is found within the dedup window.
# Exits 1 and prints "DUPLICATE:<issue_number>:<seconds_ago>" if a match is found.
check_recent_filing() {
	local title="$1"
	local body="$2"
	local fp_file
	fp_file=$(_log_issue_fingerprint_file)
	local dedup_window
	dedup_window=$(_log_issue_dedup_window)

	if [[ ! -f "$fp_file" ]]; then
		echo "OK"
		return 0
	fi

	local fingerprint
	fingerprint=$(_compute_issue_fingerprint "$title" "$body")

	local now
	now=$(date +%s)
	local cutoff
	cutoff=$((now - dedup_window))

	local match filed_epoch issue_num age
	match=$(grep -F "\"hash\":\"$fingerprint\"" "$fp_file" | tail -n 1 || true)

	if [[ -n "$match" ]]; then
		read -r filed_epoch issue_num < <(sed -E 's/.*"issue":([0-9]+).*"filed_epoch":([0-9]+).*/\2 \1/' <<<"$match" || true)
		if [[ "$filed_epoch" =~ ^[0-9]+$ ]] && is_valid_issue_number "$issue_num" && [[ "$filed_epoch" -gt "$cutoff" ]]; then
			age=$((now - filed_epoch))
			echo "DUPLICATE:${issue_num}:${age}"
			return 1
		fi
	fi

	echo "OK"
	return 0
}

# record_filing <title> <body> <issue_number>
# Appends a fingerprint record to the state file.
record_filing() {
	local title="$1"
	local body="$2"
	local issue_number="$3"

	local fp_file
	fp_file=$(_log_issue_fingerprint_file)
	local state_dir
	state_dir=$(dirname "$fp_file")
	mkdir -p "$state_dir"

	local fingerprint
	fingerprint=$(_compute_issue_fingerprint "$title" "$body")

	local now
	now=$(date +%s)
	local iso_ts
	iso_ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "unknown")

	if ! is_valid_issue_number "$issue_number"; then
		echo "ERROR: invalid issue number for fingerprint: ${issue_number}" >&2
		return 1
	fi

	printf '{"hash":"%s","issue":%s,"filed_at":"%s","filed_epoch":%s}\n' \
		"$fingerprint" "$issue_number" "$iso_ts" "$now" >>"$fp_file"

	echo "[INFO] Fingerprint recorded for issue #${issue_number} in ${fp_file}"
	return 0
}

# -----------------------------------------------------------------------------
# Reproducer Prompt (t2410)
# Outputs the section template the agent uses to prompt the user for
# reproducer evidence before drafting a framework-bug report.
# -----------------------------------------------------------------------------

prompt_reproducer() {
	cat <<'EOF'
## Reproducer

Please provide the following evidence for the framework bug. The session context
that captured this failure will be gone after this conversation ends.

**Symptom command** (paste the exact command you ran that demonstrated the bug):

```
<paste command here>
```

**Actual output** (paste what happened — include any error messages or unexpected behaviour):

```
<paste terminal output here>
```

For hang, timeout, rate-limit, API-budget, or transport-cause claims, also include:

- **Blocked command**: the exact child command and arguments shown by the process tree or trace
- **Backend state**: direct rate-limit/API-budget/transport evidence captured during the failure

If those facts are unavailable, frame the report as an investigation and label the suspected
cause as unconfirmed rather than asserting that it caused the symptom.

**Expected output** (what should have happened instead):

```
<describe what you expected>
```

**Causal status**: unconfirmed investigation | confirmed

For a confirmed cause, provide all three owning-path facts. These prove that the
cited code owns the observed production behavior rather than merely resembling it.

**Owning-path proof**:

- **Production entry point**: <file:line and command/event that enters the owning path>
- **Call chain**: <end-to-end calls from the entry point to the observed failure>
- **Integrated verification**: <test or trace that exercises that same production path>

**Causal code** (optional — if you identified the file/line or commit that introduced this):

```bash
git blame <file> -L <line>,<line>
# or: paste the commit SHA suspected to be the regression
```

**Call-site sweep** (optional — to enumerate all affected locations):

```bash
rg "<function-or-pattern>" .agents/scripts/
```

EOF
	return 0
}

# -----------------------------------------------------------------------------
# Brief Validator (t2410)
# Checks if an issue body contains substantive reproducer evidence for a
# framework-bug brief. Returns 0 if valid, 1 if evidence is missing.
#
# Usage: validate_brief <body-text-or-file>
#   - Pass a filename if the body is in a file
#   - Pass body text directly via stdin when called as: validate_brief -
# -----------------------------------------------------------------------------

_brief_has_placeholder() {
	local body="$1"
	if grep -Eqi '<(paste|describe|command|output|provide)[^>]*>|(^|[[:space:]])(TODO|TBD)([[:space:]]|$)' <<<"$body"; then
		return 0
	fi
	return 1
}

_brief_is_causal_investigation() {
	local body="$1"
	if grep -Eqi '\*\*Causal status\*\*:[[:space:]]*confirmed' <<<"$body"; then
		return 1
	fi
	if grep -Eqi '\*\*Causal status\*\*:[[:space:]]*unconfirmed investigation|(^|[[:space:]])investigation:|candidate cause|suspected cause|cause (is )?unconfirmed|causality (is )?not established' <<<"$body"; then
		return 0
	fi
	return 1
}

_brief_asserts_transport_cause() {
	local body="$1"
	local failure='hang|hung|timeout|timed out|rate.?limit|API.?budget|transport'
	local causal='because|due to|root cause|cause(d|s)?|results? in|leads? to|triggers?'
	if grep -Eqi "(${causal}).{0,120}(${failure})|(${failure}).{0,120}(${causal})|rate.?limit.{0,120}(hang|hung|timeout)|[→]" <<<"$body"; then
		return 0
	fi
	return 1
}

_brief_has_transport_evidence() {
	local body="$1"
	if grep -Eqi '\*\*Blocked command\*\*[^[:alnum:]]*.{4,}' <<<"$body" &&
		grep -Eqi '\*\*Backend state\*\*[^[:alnum:]]*.{4,}' <<<"$body"; then
		return 0
	fi
	return 1
}

_brief_asserts_confirmed_cause() {
	local body="$1"
	local confirmed='\*\*Causal status\*\*:[[:space:]]*confirmed|root cause[[:space:]]*(is|:)|confirmed cause[[:space:]]*(is|:)|cause(s|d)? the observed|results? in the observed|leads? to the observed|triggers? the observed'
	if grep -Eqi "$confirmed" <<<"$body"; then
		return 0
	fi
	return 1
}

_brief_has_owning_path_proof() {
	local body="$1"
	if grep -Eqi '\*\*Production entry point\*\*:[[:space:]]*.{8,}' <<<"$body" &&
		grep -Eqi '\*\*Call chain\*\*:[[:space:]]*.{8,}' <<<"$body" &&
		grep -Eqi '\*\*Integrated verification\*\*:[[:space:]]*.{8,}' <<<"$body"; then
		return 0
	fi
	return 1
}

validate_brief_has_reproducer() {
	local body="$1"

	# Read from file if body is a file path
	if [[ -f "$body" ]]; then
		body=$(<"$body")
	fi

	if ! grep -Eqi '^## Reproducer[[:space:]]*$' <<<"$body"; then
		echo "ERROR: Brief is missing ## Reproducer" >&2
		return 1
	fi
	if ! grep -Eqi '\*\*Symptom command\*\*' <<<"$body" || ! grep -Eqi '\*\*Actual output\*\*' <<<"$body"; then
		echo "ERROR: Reproducer requires **Symptom command** and **Actual output**" >&2
		return 1
	fi
	if _brief_has_placeholder "$body"; then
		echo "ERROR: Reproducer still contains placeholder evidence" >&2
		return 1
	fi
	if _brief_asserts_transport_cause "$body" && ! _brief_is_causal_investigation "$body" && ! _brief_has_transport_evidence "$body"; then
		echo "ERROR: Confirmed hang/timeout/rate-limit/API-budget/transport claims require **Blocked command** and **Backend state** evidence; otherwise frame this as an investigation with an unconfirmed cause" >&2
		return 1
	fi
	if _brief_asserts_confirmed_cause "$body" && ! _brief_is_causal_investigation "$body" && ! _brief_has_owning_path_proof "$body"; then
		echo "ERROR: Confirmed root-cause claims require substantive **Production entry point**, **Call chain**, and **Integrated verification** owning-path proof; otherwise use **Causal status**: unconfirmed investigation" >&2
		return 1
	fi

	echo "OK: Brief contains substantive reproducer evidence"
	return 0
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------

main() {
	local command="${1:-diagnostics}"

	case "$command" in
	diagnostics)
		gather_diagnostics
		;;
	check-auth)
		check_gh_auth
		;;
	search)
		local query="${2:-}"
		if [[ -z "$query" ]]; then
			echo "Usage: log-issue-helper.sh search \"query\""
			return 1
		fi
		search_issues "$query"
		;;
	prompt-reproducer)
		# Output the reproducer section template for the agent to show the user
		prompt_reproducer
		;;
	validate-brief)
		# Validate that a brief body contains the required Reproducer section
		local body_or_file="${2:-}"
		if [[ -z "$body_or_file" ]]; then
			echo "Usage: log-issue-helper.sh validate-brief <file-path-or-body-text>" >&2
			echo "Example: log-issue-helper.sh validate-brief issue-body.md" >&2
			return 1
		fi
		validate_brief_has_reproducer "$body_or_file"
		;;
	check-fingerprint)
		# Check if an identical issue was filed within the dedup window.
		# Prints "OK" (exit 0) or "DUPLICATE:<number>:<seconds_ago>" (exit 1).
		local title="${2:-}"
		local body="${3:-}"
		if [[ -z "$title" ]]; then
			echo "Usage: log-issue-helper.sh check-fingerprint \"title\" \"body\"" >&2
			return 1
		fi
		check_recent_filing "$title" "$body"
		;;
	record-fingerprint)
		# Record a fingerprint after a successful issue creation.
		local title="${2:-}"
		local body="${3:-}"
		local issue_number="${4:-}"
		if [[ -z "$title" ]] || [[ -z "$issue_number" ]]; then
			echo "Usage: log-issue-helper.sh record-fingerprint \"title\" \"body\" \"issue_number\"" >&2
			return 1
		fi
		record_filing "$title" "$body" "$issue_number"
		;;
	help | --help | -h)
		cat <<EOF
aidevops Issue Logger Helper

Usage: log-issue-helper.sh [command]

Commands:
  diagnostics                          Gather system and aidevops diagnostic info (default)
  check-auth                           Verify GitHub CLI authentication
  search "query"                       Search existing issues for duplicates
  prompt-reproducer                    Output the reproducer section template for framework bugs
  validate-brief <file>                Validate that a brief body contains required sections
  check-fingerprint "title" "body"     Dedup check: prints OK or DUPLICATE:<num>:<secs_ago>
  record-fingerprint "title" "body" N  Record fingerprint after issue #N was created
  help                                 Show this help message

Examples:
  log-issue-helper.sh diagnostics
  log-issue-helper.sh check-auth
  log-issue-helper.sh search "update check"
  log-issue-helper.sh prompt-reproducer
  log-issue-helper.sh validate-brief /tmp/issue-body.md
  log-issue-helper.sh check-fingerprint "bug: foo" "\$body_text"
  log-issue-helper.sh record-fingerprint "bug: foo" "\$body_text" 20312
EOF
		;;
	*)
		echo "Unknown command: $command"
		echo "Run: log-issue-helper.sh help"
		return 1
		;;
	esac
	return 0
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	main "$@"
fi

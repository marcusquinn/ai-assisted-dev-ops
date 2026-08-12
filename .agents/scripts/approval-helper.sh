#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# -----------------------------------------------------------------------------
# approval-helper.sh — Cryptographic approval gate for external issues/PRs.
#
# Prevents automation (pulse/workers) from approving issues that require human
# review. Uses SSH-signed approval comments that workers cannot forge.
#
# Usage (must be run with sudo for issue/pr approval):
#   sudo aidevops approve setup          # One-time: generate approval key pair
#   sudo aidevops approve issue <number...> [owner/repo] # Approve issues for development
#   sudo aidevops approve pr <number...> [owner/repo]    # Approve PRs for merge
#   aidevops approve verify <number>     # Verify approval on an issue (no sudo)
#   aidevops approve status              # Show approval key setup status
#
# Security model:
#   - Private signing key stored root-only (~/.aidevops/approval-keys/private/)
#   - Requires sudo + interactive TTY (workers are headless, cannot enter password)
#   - SSH-signed approval comment posted to GitHub, verifiable by pulse
#   - Workers are prohibited from calling this command
# -----------------------------------------------------------------------------

set -euo pipefail

# Source shared-constants for gh_issue_comment / gh_pr_comment wrappers (t2393).
# PR #19953 replaced raw `gh issue comment` / `gh pr comment` calls with these
# wrappers to auto-append the t2393 signature footer, but this helper was
# missed in the sourcing sweep (t2408 / GH#19997). Under `sudo aidevops
# approve issue|pr`, the unbound wrappers produced `command not found` and
# blocked every approval. Conditional `[[ -f ]] && source` mirrors the
# circuit-breaker-helper.sh:29-32 pattern: fail-open if the shared file is
# missing on a partial install rather than hard-crashing the approval flow.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=shared-constants.sh
[[ -f "${SCRIPT_DIR}/shared-constants.sh" ]] && source "${SCRIPT_DIR}/shared-constants.sh"

# Resolve the real user's home directory, handling sudo env_reset.
# Under sudo, HOME may point at root's home while SUDO_USER holds the invoking
# username. getent passwd is canonical on Linux; dscl is canonical on macOS.
# Security: no escalation — root already has full filesystem access.
_resolve_real_home() {
	if [[ -n "${SUDO_USER:-}" && "$(id -u)" -eq 0 ]]; then
		local real_home=""
		if command -v getent &>/dev/null; then
			real_home=$(getent passwd "$SUDO_USER" | cut -d: -f6)
			if [[ -n "$real_home" ]]; then
				printf '%s' "$real_home"
				return 0
			fi
		fi
		if command -v dscl &>/dev/null; then
			real_home=$(dscl . -read "/Users/${SUDO_USER}" NFSHomeDirectory 2>/dev/null | awk '{print $2; exit}' || true)
			if [[ -n "$real_home" ]]; then
				printf '%s' "$real_home"
				return 0
			fi
		fi
		if [[ -d "/Users/${SUDO_USER}" ]]; then
			printf '/Users/%s' "$SUDO_USER"
			return 0
		fi
	fi
	printf '%s' "$HOME"
	return 0
}

# Compute real home once at script load; used for all path variables below.
_APPROVAL_HOME=$(_resolve_real_home)

readonly APPROVAL_DIR="$_APPROVAL_HOME/.aidevops/approval-keys"
readonly APPROVAL_PRIVATE_DIR="$APPROVAL_DIR/private"
readonly APPROVAL_KEY="$APPROVAL_PRIVATE_DIR/approval.key"
readonly APPROVAL_PUB="$APPROVAL_DIR/approval.pub"
readonly APPROVAL_NAMESPACE="aidevops-approve"
readonly APPROVAL_MARKER="<!-- aidevops-signed-approval -->"
readonly _APPROVAL_NMR_LABEL="needs-maintainer-review"
readonly _APPROVAL_AUTO_DISPATCH_LABEL="auto-dispatch"
readonly _APPROVAL_MISSING_FIELD="__missing__"
readonly _APPROVAL_GH_INVALID_TOKEN="invalid-token"
readonly _APPROVAL_BATCH_MODE="batch"

_APPROVAL_GH_RATE_LIMIT_RESET=""
_APPROVAL_GH_AUTH_FAILURE=""

# shellcheck source=approval-snapshot-v2.sh
source "${SCRIPT_DIR}/approval-snapshot-v2.sh"

# shellcheck source=./approval-helper-permissions.sh
# shellcheck disable=SC1091  # module resolved at runtime via SCRIPT_DIR
source "${SCRIPT_DIR}/approval-helper-permissions.sh"

_permission_comments_endpoint() {
	local slug="$1"
	local target_number="$2"
	printf 'repos/%s/issues/%s/comments?per_page=100' "$slug" "$target_number"
	return 0
}

# Detect repo slug from current directory or repos.json
_detect_slug() {
	local slug=""
	# Try git remote first
	if git rev-parse --is-inside-work-tree &>/dev/null; then
		local remote_url
		remote_url=$(git remote get-url origin 2>/dev/null || echo "")
		slug=$(printf '%s' "$remote_url" | sed 's|.*github\.com[:/]||;s|\.git$||')
	fi
	# Fall back to repos.json current directory match
	if [[ -z "$slug" || "$slug" != *"/"* ]]; then
		local repos_json="$_APPROVAL_HOME/.config/aidevops/repos.json"
		if [[ -f "$repos_json" ]]; then
			local cwd
			cwd=$(pwd)
			slug=$(jq -r --arg cwd "$cwd" \
				'.initialized_repos[] | select(.path == $cwd) | .slug // empty' \
				"$repos_json" 2>/dev/null || echo "")
		fi
	fi
	printf '%s' "$slug"
	return 0
}

_print_info() {
	local msg="$1"
	echo -e "\033[0;34m[INFO]\033[0m $msg"
	return 0
}

_print_ok() {
	local msg="$1"
	echo -e "\033[0;32m[OK]\033[0m $msg"
	return 0
}

_print_warn() {
	local msg="$1"
	echo -e "\033[1;33m[WARN]\033[0m $msg"
	return 0
}

_print_error() {
	local msg="$1"
	echo -e "\033[0;31m[ERROR]\033[0m $msg"
	return 0
}

_approval_probe_auth_failure() {
	local response=""
	# The diagnostic request must respect any active shared secondary cooldown.
	if command -v _gh_secondary_cooldown_preflight >/dev/null 2>&1; then
		_gh_secondary_cooldown_preflight read >/dev/null 2>&1 || return 1
	fi
	response=$(gh api user --include --silent 2>/dev/null) || true
	[[ -n "$response" ]] || return 1
	printf '%s\n' "$response" | awk '
		{ sub(/\r$/, "", $0) }
		$1 ~ /^HTTP\// {
			status = $2
			remaining = ""
			reset = ""
			resource = ""
		}
		tolower($1) == "x-ratelimit-remaining:" { remaining = $2 }
		tolower($1) == "x-ratelimit-reset:" { reset = $2 }
		tolower($1) == "x-ratelimit-resource:" { resource = tolower($2) }
		END {
			if (status ~ /^2[0-9][0-9]$/) {
				printf "authenticated"
				exit 0
			}
			if ((status == "403" || status == "429") && remaining == "0" && reset ~ /^[0-9]+$/ && resource == "core") {
				printf "core-rate-limit\t%s", reset
				exit 0
			}
			if (status == "401") {
				printf "invalid-token"
				exit 0
			}
			exit 1
		}'
	return $?
}

_approval_report_core_rate_limit() {
	local reset="$1"
	_print_error "GitHub core API rate limit is exhausted for the invoking user's credential (reset epoch: ${reset})"
	_print_info "Wait until reset epoch ${reset} before retrying. Re-authentication or forwarding GH_TOKEN will not help before reset."
	return 0
}

_approval_safe_gh_host() {
	local host="${GH_HOST:-github.com}"
	if [[ ! "$host" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]]; then
		host="github.com"
	fi
	printf '%s' "$host"
	return 0
}

_approval_report_invalid_token() {
	local host=""
	host="$(_approval_safe_gh_host)"
	_print_error "GitHub rejected the invoking user's stored gh credential (HTTP 401); this is not a sudo credential-forwarding failure"
	_print_info "Replace the rejected credential as your normal user: gh auth logout -h ${host}, then gh auth login -h ${host} -s workflow. Do not forward the rejected token through GH_TOKEN."
	return 0
}

_approval_use_gh_token() {
	local token="${1:-}"
	local previous_token="${GH_TOKEN:-}"
	local token_was_set="${GH_TOKEN+x}"
	local failure=""
	local failure_kind=""
	local reset=""
	_APPROVAL_GH_RATE_LIMIT_RESET=""
	_APPROVAL_GH_AUTH_FAILURE=""

	if [[ -z "$token" ]]; then
		return 1
	fi

	export GH_TOKEN="$token"
	if gh auth status >/dev/null 2>&1; then
		return 0
	fi
	if failure=$(_approval_probe_auth_failure); then
		IFS=$'\t' read -r failure_kind reset <<<"$failure"
		case "$failure_kind" in
		authenticated)
			return 0
			;;
		core-rate-limit)
			_APPROVAL_GH_RATE_LIMIT_RESET="$reset"
			;;
		"$_APPROVAL_GH_INVALID_TOKEN")
			_APPROVAL_GH_AUTH_FAILURE="$failure_kind"
			;;
		esac
	fi

	if [[ -n "$token_was_set" ]]; then
		export GH_TOKEN="$previous_token"
	else
		unset GH_TOKEN
	fi
	return 1
}

_approval_user_gh_token() {
	if [[ -z "${SUDO_USER:-}" || "$(id -u)" -ne 0 ]]; then
		return 1
	fi

	local real_uid=""
	real_uid=$(id -u "$SUDO_USER" 2>/dev/null || true)
	local real_home=""
	real_home=$(_resolve_real_home)
	local gh_home_env="HOME=${real_home}"
	local gh_bin=""
	gh_bin=$(type -P gh 2>/dev/null || command -v gh 2>/dev/null || true)
	local token=""

	if [[ -z "$gh_bin" ]]; then
		return 1
	fi

	# Linux: reconnect to the user's D-Bus session so gh can reach keyring-backed auth.
	if [[ -n "$real_uid" && -S "/run/user/${real_uid}/bus" ]] && command -v runuser &>/dev/null; then
		token=$(runuser -u "$SUDO_USER" -- env \
			"DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/${real_uid}/bus" \
			"XDG_RUNTIME_DIR=/run/user/${real_uid}" \
			"$gh_home_env" \
			"$gh_bin" auth token 2>/dev/null || true)
		if [[ -n "$token" ]]; then
			printf '%s' "$token"
			return 0
		fi
	fi

	# macOS: run in the invoking user's launchd session so gh can reach Keychain.
	if [[ -n "$real_uid" ]] && command -v launchctl &>/dev/null && command -v sudo &>/dev/null; then
		token=$(launchctl asuser "$real_uid" sudo -u "$SUDO_USER" -H env \
			"$gh_home_env" "$gh_bin" auth token 2>/dev/null || true)
		if [[ -n "$token" ]]; then
			printf '%s' "$token"
			return 0
		fi
	fi

	# Portable fallback for non-keyring gh storage and sudo configurations that
	# permit root to switch back to the invoking user without another password.
	if command -v sudo &>/dev/null; then
		token=$(sudo -u "$SUDO_USER" -H env "$gh_home_env" "$gh_bin" auth token 2>/dev/null || true)
		if [[ -n "$token" ]]; then
			printf '%s' "$token"
			return 0
		fi
	fi

	return 1
}

_require_gh_auth() {
	_APPROVAL_GH_RATE_LIMIT_RESET=""
	_APPROVAL_GH_AUTH_FAILURE=""
	if gh auth status >/dev/null 2>&1; then
		return 0
	fi
	# Under sudo, gh may be unable to access the invoking user's keyring/keychain.
	# Attempt automatic token recovery before falling back to a descriptive error.
	if [[ -n "${SUDO_USER:-}" && "$(id -u)" -eq 0 ]]; then
		local user_token=""
		user_token=$(_approval_user_gh_token || true)
		if _approval_use_gh_token "$user_token"; then
			return 0
		fi
		if [[ -n "$_APPROVAL_GH_RATE_LIMIT_RESET" ]]; then
			_approval_report_core_rate_limit "$_APPROVAL_GH_RATE_LIMIT_RESET"
			return 1
		fi
		if [[ "$_APPROVAL_GH_AUTH_FAILURE" == "$_APPROVAL_GH_INVALID_TOKEN" ]]; then
			_approval_report_invalid_token
			return 1
		fi

		# Read token directly from gh config file for non-keyring storage.
		local real_home
		real_home=$(_resolve_real_home)
		local gh_hosts="${real_home}/.config/gh/hosts.yml"
		if [[ -f "$gh_hosts" ]]; then
			local file_token=""
			file_token=$(awk '/oauth_token:/{print $2; exit}' "$gh_hosts" 2>/dev/null || true)
			if _approval_use_gh_token "$file_token"; then
				return 0
			fi
			if [[ -n "$_APPROVAL_GH_RATE_LIMIT_RESET" ]]; then
				_approval_report_core_rate_limit "$_APPROVAL_GH_RATE_LIMIT_RESET"
				return 1
			fi
			if [[ "$_APPROVAL_GH_AUTH_FAILURE" == "$_APPROVAL_GH_INVALID_TOKEN" ]]; then
				_approval_report_invalid_token
				return 1
			fi
		fi
	fi
	_print_error "gh authentication failed under sudo; automatic recovery from the invoking user's gh auth failed"
	_print_info "Check 'gh auth status' as your user, then retry sudo aidevops approve. If sudo strips auth, pass GH_TOKEN via sudo --preserve-env=GH_TOKEN."
	return 1
}

_require_number_arg() {
	local value="${1:-}"
	local noun="$2"
	local usage="$3"

	if [[ -z "$value" ]]; then
		_print_error "$usage"
		return 1
	fi

	if [[ ! "$value" =~ ^[0-9]+$ ]]; then
		_print_error "$noun number must be numeric: $value"
		return 1
	fi

	return 0
}

_require_interactive_root() {
	local usage="$1"

	if [[ ! -t 0 ]]; then
		_print_error "This command requires an interactive terminal (cannot run headless)"
		return 1
	fi

	if [[ "$(id -u)" -ne 0 ]]; then
		_print_error "This command must be run with sudo"
		echo "$usage"
		return 1
	fi

	return 0
}

_approval_real_user() {
	printf '%s' "${SUDO_USER:-$(whoami)}"
	return 0
}

_approval_real_home() {
	_resolve_real_home
	return 0
}

_approval_private_key_path() {
	local real_home
	real_home=$(_approval_real_home)
	printf '%s' "$real_home/.aidevops/approval-keys/private/approval.key"
	return 0
}

_require_approval_key() {
	local actual_key="$1"

	if [[ ! -f "$actual_key" ]]; then
		_print_error "No approval key found. Run: sudo aidevops approve setup"
		return 1
	fi

	return 0
}

_resolve_slug_or_fail() {
	local slug="${1:-}"
	local usage="$2"

	if [[ -z "$slug" ]]; then
		slug=$(_detect_slug)
	fi

	if [[ -z "$slug" || "$slug" != *"/"* ]]; then
		_print_error "$usage"
		return 1
	fi

	printf '%s' "$slug"
	return 0
}

_fetch_target_title() {
	local target_type="$1"
	local target_number="$2"
	local slug="$3"
	local title=""
	local rc=0

	if [[ "$target_type" == "issue" ]]; then
		title=$(gh issue view "$target_number" --repo "$slug" --json title --jq '.title' 2>/dev/null) || rc=$?
		if [[ $rc -ne 0 ]] && command -v _rest_should_fallback >/dev/null 2>&1 && _rest_should_fallback; then
			_print_info "gh-wrapper: GraphQL exhausted, falling back to REST for issue title" >&2
			title=$(_rest_issue_view "$target_number" --repo "$slug" --json title --jq '.title' 2>/dev/null) || title=""
		fi
		[[ -n "$title" ]] && printf '%s' "$title" || printf '%s' "(could not fetch title)"
		return 0
	fi

	title=$(gh pr view "$target_number" --repo "$slug" --json title --jq '.title' 2>/dev/null) || rc=$?
	if [[ $rc -ne 0 ]] && command -v _rest_should_fallback >/dev/null 2>&1 && _rest_should_fallback; then
		_print_info "gh-wrapper: GraphQL exhausted, falling back to REST for PR title" >&2
		title=$(_rest_pr_view "$target_number" --repo "$slug" --json title --jq '.title' 2>/dev/null) || title=""
	fi
	[[ -n "$title" ]] && printf '%s' "$title" || printf '%s' "(could not fetch title)"
	return 0
}

_validate_approval_target_kind() {
	local target_type="$1"
	local target_number="$2"
	local slug="$3"
	local issue_json=""

	issue_json=$(_approval_fetch_issue_json "$target_number" "$slug") || {
		_print_error "Could not resolve ${target_type} #${target_number} in ${slug}. Check the number, repo, and whether this is an issue or PR."
		if [[ "$target_type" == "pr" ]]; then
			_print_info "If this is an issue, use: sudo aidevops approve issue ${target_number} ${slug}"
		else
			_print_info "If this is a PR, use: sudo aidevops approve pr ${target_number} ${slug}"
		fi
		return 1
	}

	if [[ "$target_type" == "pr" ]]; then
		if ! printf '%s' "$issue_json" | jq -e 'has("pull_request")' >/dev/null 2>&1; then
			_print_error "#${target_number} in ${slug} is an issue, not a PR."
			_print_info "Use: sudo aidevops approve issue ${target_number} ${slug}"
			return 1
		fi
		return 0
	fi

	if printf '%s' "$issue_json" | jq -e 'has("pull_request")' >/dev/null 2>&1; then
		_print_error "#${target_number} in ${slug} is a PR, not an issue."
		_print_info "Use: sudo aidevops approve pr ${target_number} ${slug}"
		return 1
	fi

	return 0
}

_sign_approval_payload() {
	local payload="$1"
	local actual_key="$2"
	local sig_file="$3"

	printf '%s' "$payload" | ssh-keygen -Y sign \
		-f "$actual_key" \
		-n "$APPROVAL_NAMESPACE" \
		-q - >"$sig_file" 2>/dev/null

	if [[ ! -s "$sig_file" ]]; then
		_print_error "Signing failed"
		return 1
	fi

	return 0
}

_build_signed_comment() {
	local payload="$1"
	local sig_file="$2"
	local target_type="${3:-issue}"
	local signature lock_notice
	signature=$(<"$sig_file")

	# PRs use GitHub's "conversation locked" terminology; issues use "issue locked".
	if [[ "$target_type" == "pr" ]]; then
		lock_notice="> **This conversation is now locked.** To propose scope changes, open a new issue referencing this one."
	else
		lock_notice="> **This issue is now locked.** To propose scope changes, open a new issue referencing this one."
	fi

	cat <<EOF
${APPROVAL_MARKER}
## Maintainer Approval (cryptographically signed)

\`\`\`
${payload}
\`\`\`

\`\`\`
${signature}
\`\`\`

This approval was signed with a root-protected SSH key. It cannot be forged by automation.

${lock_notice}
EOF
	return 0
}

_approval_lock_issue() {
	local target_number="$1"
	local slug="$2"
	local rc=0
	local rest_rc=0

	gh issue lock "$target_number" --repo "$slug" --reason "resolved" >/dev/null 2>&1 || rc=$?
	if [[ $rc -eq 0 ]]; then
		return 0
	fi

	# `gh issue lock` rejects PR-backed issue numbers with "use gh pr lock",
	# while GitHub's REST issue lock endpoint works for both issues and PR
	# conversations. Always try REST after the CLI path fails so signed
	# approvals do not leave an unlocked prompt-injection window.
	if command -v _rest_should_fallback >/dev/null 2>&1 && _rest_should_fallback; then
		_print_info "gh-wrapper: GraphQL exhausted, falling back to REST for issue lock" >&2
	else
		_print_info "gh-wrapper: gh issue lock failed, falling back to REST for issue lock" >&2
	fi
	gh api -X PUT "/repos/${slug}/issues/${target_number}/lock" -f lock_reason=resolved >/dev/null 2>&1 || rest_rc=$?
	return "$rest_rc"
}

_approval_lock_pr() {
	local target_number="$1"
	local slug="$2"
	local rc=0
	local rest_rc=0

	gh pr lock "$target_number" --repo "$slug" --reason "resolved" >/dev/null 2>&1 || rc=$?
	if [[ $rc -eq 0 ]]; then
		return 0
	fi

	# Fall back to the REST issue lock endpoint because PR conversations are
	# issue-backed in GitHub's API and the endpoint is stable across gh versions.
	if command -v _rest_should_fallback >/dev/null 2>&1 && _rest_should_fallback; then
		_print_info "gh-wrapper: GraphQL exhausted, falling back to REST for PR lock" >&2
	else
		_print_info "gh-wrapper: gh pr lock failed, falling back to REST for PR lock" >&2
	fi
	gh api -X PUT "/repos/${slug}/issues/${target_number}/lock" -f lock_reason=resolved >/dev/null 2>&1 || rest_rc=$?
	return "$rest_rc"
}

_approval_verify_conversation_locked() {
	local target_type="$1"
	local target_number="$2"
	local slug="$3"
	local issue_json="${4:-}"
	local label="issue"

	if [[ "$target_type" == "pr" ]]; then
		label="PR conversation"
	fi

	if [[ -z "$issue_json" ]]; then
		issue_json=$(_approval_fetch_issue_json "$target_number" "$slug") || {
			_print_error "Approval state verification failed: could not read ${label} #$target_number via REST"
			return 1
		}
	fi

	if ! printf '%s' "$issue_json" | jq -e '.locked == true' >/dev/null 2>&1; then
		_print_error "Approval state verification failed: ${label} #$target_number is not locked"
		return 1
	fi

	return 0
}

_approval_fetch_issue_json() {
	local target_number="$1"
	local slug="$2"

	gh api "/repos/${slug}/issues/${target_number}" 2>/dev/null
	return $?
}

_approval_verify_issue_state() {
	local target_number="$1"
	local slug="$2"
	local gh_user="$3"
	local issue_json=""

	issue_json=$(_approval_fetch_issue_json "$target_number" "$slug") || {
		_print_error "Approval state verification failed: could not read issue #$target_number via REST"
		return 1
	}

	if ! printf '%s' "$issue_json" | jq -e --arg label "$_APPROVAL_NMR_LABEL" '(.labels // []) | any(.name == $label) | not' >/dev/null 2>&1; then
		_print_error "Approval state verification failed: needs-maintainer-review is still present on #$target_number"
		return 1
	fi
	if ! printf '%s' "$issue_json" | jq -e --arg label "$_APPROVAL_AUTO_DISPATCH_LABEL" '(.labels // []) | any(.name == $label)' >/dev/null 2>&1; then
		_print_error "Approval state verification failed: auto-dispatch is missing on #$target_number"
		return 1
	fi
	if ! printf '%s' "$issue_json" | jq -e --arg user "$gh_user" '(.assignees // []) | any(.login == $user)' >/dev/null 2>&1; then
		_print_error "Approval state verification failed: $gh_user is not assigned to #$target_number"
		return 1
	fi
	if ! printf '%s' "$issue_json" | jq -e '.locked == true' >/dev/null 2>&1; then
		_print_error "Approval state verification failed: issue #$target_number is not locked"
		return 1
	fi

	return 0
}

_approval_verify_pr_state() {
	local target_number="$1"
	local slug="$2"
	local issue_json=""

	issue_json=$(_approval_fetch_issue_json "$target_number" "$slug") || {
		_print_error "Approval state verification failed: could not read PR #$target_number via REST"
		return 1
	}
	if ! printf '%s' "$issue_json" | jq -e --arg label "$_APPROVAL_NMR_LABEL" '(.labels // []) | any(.name == $label) | not' >/dev/null 2>&1; then
		_print_error "Approval state verification failed: needs-maintainer-review is still present on PR #$target_number"
		return 1
	fi
	_approval_verify_conversation_locked pr "$target_number" "$slug" "$issue_json"
	return $?
}

_approval_apply_issue_lifecycle_updates() {
	local target_number="$1"
	local slug="$2"
	local gh_user=""
	local edit_err=""
	local lock_err=""

	gh_user=$(gh api user --jq '.login' 2>/dev/null || printf '')
	if [[ -z "$gh_user" || "$gh_user" == "null" ]]; then
		_print_error "Could not detect GitHub username — approval state was not changed"
		return 1
	fi

	edit_err=$(gh_issue_edit_safe "$target_number" --repo "$slug" \
		--remove-label "$_APPROVAL_NMR_LABEL" \
		--add-label "$_APPROVAL_AUTO_DISPATCH_LABEL" \
		--add-assignee "$gh_user" 2>&1 >/dev/null) || {
		_print_error "Failed to update approval labels/assignee on issue #$target_number"
		[[ -n "$edit_err" ]] && _print_error "$edit_err"
		return 1
	}
	_print_info "Labels updated: removed needs-maintainer-review, added auto-dispatch"
	_print_info "Assigned to $gh_user"

	lock_err=$(_approval_lock_issue "$target_number" "$slug" 2>&1 >/dev/null) || {
		_print_error "Approval advisory lock failure: issue #$target_number could not be locked after approval state updates"
		[[ -n "$lock_err" ]] && _print_error "$lock_err"
		return 1
	}
	_print_info "Issue #$target_number locked (scope finalized, unlocks after worker completion)"

	# t2057: idempotent release of status:in-review. Signing is the handoff to
	# automation, so the interactive hold must lift. Best-effort: verification
	# below checks the approval-critical state, not local stamp cleanup.
	local _ah_labels_json
	_ah_labels_json=$(gh_issue_view "$target_number" --repo "$slug" \
		--json labels --jq '[.labels[].name] | join(",")' 2>/dev/null || echo "")
	if [[ "$_ah_labels_json" == *"status:in-review"* ]]; then
		local _ah_helper=""
		if [[ -x "${HOME}/.aidevops/agents/scripts/interactive-session-helper.sh" ]]; then
			_ah_helper="${HOME}/.aidevops/agents/scripts/interactive-session-helper.sh"
		else
			local _ah_script_dir
			_ah_script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd) || _ah_script_dir=""
			if [[ -n "$_ah_script_dir" && -x "${_ah_script_dir}/interactive-session-helper.sh" ]]; then
				_ah_helper="${_ah_script_dir}/interactive-session-helper.sh"
			fi
		fi
		if [[ -n "$_ah_helper" ]]; then
			"$_ah_helper" release "$target_number" "$slug" >/dev/null 2>&1 || true
			_print_info "Released status:in-review (interactive review transitioned to available)"
		fi
	fi

	_approval_verify_issue_state "$target_number" "$slug" "$gh_user"
	return $?
}

_approval_apply_pr_lifecycle_updates() {
	local target_number="$1"
	local slug="$2"
	local lock_err=""
	local edit_err=""

	# Lock before clearing the live hold so no untrusted comment can land in the
	# approval-to-merge window. The final merge gate still re-verifies the V2
	# signature against current content and the exact PR head.
	lock_err=$(_approval_lock_pr "$target_number" "$slug" 2>&1 >/dev/null) || {
		_print_error "Approval advisory lock failure: PR #$target_number conversation could not be locked before clearing the NMR hold"
		[[ -n "$lock_err" ]] && _print_error "$lock_err"
		return 1
	}
	edit_err=$(gh_pr_edit_safe "$target_number" --repo "$slug" \
		--remove-label "$_APPROVAL_NMR_LABEL" 2>&1 >/dev/null) || {
		_print_error "Failed to clear needs-maintainer-review on PR #$target_number after approval"
		[[ -n "$edit_err" ]] && _print_error "$edit_err"
		return 1
	}
	_approval_verify_pr_state "$target_number" "$slug" || return 1
	_print_info "PR #$target_number NMR hold cleared and conversation locked"
	return 0
}

_post_issue_approval_updates() {
	local target_type="$1"
	local target_number="$2"
	local slug="$3"

	# Issues become dispatchable; PRs clear their live NMR hold only after the
	# signed comment has been posted and verified by _approve_target.
	if [[ "$target_type" == "issue" ]]; then
		_approval_apply_issue_lifecycle_updates "$target_number" "$slug"
		return $?
	fi
	_approval_apply_pr_lifecycle_updates "$target_number" "$slug"
	return $?
}

_approval_restore_nmr_hold() {
	local target_type="$1"
	local target_number="$2"
	local slug="$3"

	if [[ "$target_type" == "issue" ]]; then
		gh_issue_edit_safe "$target_number" --repo "$slug" --add-label "$_APPROVAL_NMR_LABEL"
		return $?
	fi
	gh_pr_edit_safe "$target_number" --repo "$slug" --add-label "$_APPROVAL_NMR_LABEL"
	return $?
}

#######################################
# t3068: Kick the pulse so it picks up this approval immediately.
#
# Eliminates the up-to-120s window between a verified signature post and the
# pulse-merge cycle acting on the linked PR. Two layers, both best-effort:
#
#   1. Marker file (~/.aidevops/cache/pulse-merge-trigger.txt) — append a
#      tab-separated line `slug<TAB>num<TAB>type<TAB>iso8601_ts`. The pulse
#      drains this file at cycle entry (see pulse-wrapper-bootstrap.sh
#      _drain_merge_trigger_file_if_present) and processes each PR via the
#      existing process_pr() entry point in pulse-merge.sh. Survives crashes
#      and approval/pulse races — if the immediate spawn (layer 2) is
#      unavailable, the next pulse-merge tick (60s) drains the marker.
#
#   2. Immediate background spawn — fire `pulse-wrapper.sh --merge-only` so
#      the merge pass runs within seconds. nohup + disown so the child
#      survives this script's exit. If pulse is already mid-merge the spawn
#      short-circuits via the merge-only lockdir collision in
#      _pulse_run_merge_only — the marker (layer 1) covers that case.
#
# Args:
#   $1 - target_type ("issue" or "pr")
#   $2 - target_number (numeric)
#   $3 - slug (owner/repo)
#
# Bypass: AIDEVOPS_SKIP_APPROVE_KICK_PULSE=1 disables both layers (used by
# tests and CI to keep approval flow purely local).
#
# Exit code: always 0 (failures must NEVER block the approval flow — the
# approval has already been signed and posted by the time we reach here).
#######################################
_kick_pulse_after_approval() {
	local target_type="${1:-}"
	local target_number="${2:-}"
	local slug="${3:-}"

	if [[ "${AIDEVOPS_SKIP_APPROVE_KICK_PULSE:-0}" == "1" ]]; then
		return 0
	fi

	# Defense-in-depth input validation. The caller already validated these,
	# but the marker file is consumed by another script that will exec on
	# them — keep the bar high.
	if ! [[ "$target_number" =~ ^[0-9]+$ ]]; then
		return 0
	fi
	if ! [[ "$slug" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
		return 0
	fi
	if [[ "$target_type" != "issue" && "$target_type" != "pr" ]]; then
		return 0
	fi

	# Layer 1: marker file. Always written; pulse drains on next merge cycle.
	# _APPROVAL_HOME (set near the top of this file) handles sudo HOME reset
	# on Linux so the marker lands in the real user's tree, not /root.
	local trigger_file="${_APPROVAL_HOME}/.aidevops/cache/pulse-merge-trigger.txt"
	mkdir -p "$(dirname "$trigger_file")" 2>/dev/null || true

	local ts
	ts=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || printf 'unknown')
	# Tab-separated; the drain parser splits on \t. Append-only — multiple
	# concurrent approvals each contribute one line.
	printf '%s\t%s\t%s\t%s\n' "$slug" "$target_number" "$target_type" "$ts" \
		>>"$trigger_file" 2>/dev/null || true

	# When sudo writes the marker file, ownership defaults to root. Hand it
	# back to the real user so the pulse (running as the user) can read +
	# rotate it without permission errors.
	if [[ -n "${SUDO_USER:-}" && "$(id -u)" -eq 0 ]]; then
		chown "$SUDO_USER" "$trigger_file" 2>/dev/null || true
	fi

	# Layer 2: immediate background spawn. Best-effort — if the binary is
	# missing or not executable, the marker (layer 1) still drives latency
	# down to the next pulse-merge tick (~60s).
	local pulse_wrapper="${_APPROVAL_HOME}/.aidevops/agents/scripts/pulse-wrapper.sh"
	if [[ ! -x "$pulse_wrapper" ]]; then
		return 0
	fi

	local kick_log="${_APPROVAL_HOME}/.aidevops/logs/pulse-approve-kick.log"
	mkdir -p "$(dirname "$kick_log")" 2>/dev/null || true

	# Detach completely so this exits even if the child blocks. The double
	# fork via subshell + disown matches the pattern in
	# pulse-lifecycle-helper.sh::_start. Drop sudo (run as the real user)
	# so the spawned pulse uses the same env/locks as the launchd-managed
	# pulse — root-owned locks would corrupt the lockdir tree.
	if [[ -n "${SUDO_USER:-}" && "$(id -u)" -eq 0 ]] && command -v sudo >/dev/null 2>&1; then
		(
			nohup sudo -u "$SUDO_USER" -H -- "$pulse_wrapper" --merge-only \
				>>"$kick_log" 2>&1 </dev/null &
			disown 2>/dev/null || true
		) 2>/dev/null
	else
		(
			nohup "$pulse_wrapper" --merge-only \
				>>"$kick_log" 2>&1 </dev/null &
			disown 2>/dev/null || true
		) 2>/dev/null
	fi

	return 0
}

_approve_target_after_confirmation() {
	local target_type="$1"
	local target_number="$2"
	local slug="$3"
	local actual_key="$4"

	local timestamp payload sig_file comment_body
	# #aidevops:trust-boundary — issue continuity can only begin from an
	# authoritative locked snapshot. PR approval semantics remain unchanged.
	if [[ "$target_type" == "$APPROVAL_TARGET_ISSUE" ]]; then
		_approval_lock_issue "$target_number" "$slug" >/dev/null 2>&1 || {
			_print_error "Could not lock issue before building its approval snapshot"
			return 1
		}
	fi
	timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
	payload=$(approval_snapshot_v2_payload "$target_type" "$target_number" "$slug" "$timestamp") || {
		_print_error "Could not build the immutable approval snapshot; approval was not posted"
		return 1
	}
	sig_file=$(mktemp)

	if ! _sign_approval_payload "$payload" "$actual_key" "$sig_file"; then
		rm -f "$sig_file"
		return 1
	fi

	comment_body=$(_build_signed_comment "$payload" "$sig_file" "$target_type")
	rm -f "$sig_file"

	if [[ "$target_type" == "issue" ]]; then
		if ! gh_issue_comment "$target_number" --repo "$slug" --body "$comment_body"; then
			_print_error "Failed to post approval comment on issue #$target_number"
			return 1
		fi
	else
		if ! gh_pr_comment "$target_number" --repo "$slug" --body "$comment_body"; then
			_print_error "Failed to post approval comment on PR #$target_number"
			return 1
		fi
	fi

	# #aidevops:trust-boundary — content can drift between the snapshot read and
	# comment write. Re-fetch and verify V2 before lifecycle writes or Pulse kick.
	local posted_verification=""
	posted_verification=$(cmd_verify "$target_type" "$target_number" "$slug" 2>/dev/null) || posted_verification="${posted_verification:-API_ERROR}"
	if [[ "$posted_verification" != "VERIFIED" ]]; then
		_print_error "Approval comment posted but current-state verification returned ${posted_verification}; lifecycle changes were not applied. Re-run approval after reviewing the latest state."
		return 1
	fi

	if ! _post_issue_approval_updates "$target_type" "$target_number" "$slug"; then
		# The signed comment already passed current-state verification. Queue the
		# bounded reconciliation path even when synchronous lifecycle writes race
		# label-protection automation or hit a transient API failure.
		_kick_pulse_after_approval "$target_type" "$target_number" "$slug"
		_print_error "Approval signed, but post-approval protection updates did not reach the required state"
		return 1
	fi

	# t3068: kick the pulse to act on this approval immediately. Always
	# returns 0 — never blocks the approval flow. See _kick_pulse_after_approval
	# above for the two-layer (marker file + background spawn) design.
	_kick_pulse_after_approval "$target_type" "$target_number" "$slug"

	# Bash 3.2 compat: ${var^} (uppercase first) requires Bash 4+. Use printf + tr.
	local target_type_cap
	target_type_cap="$(printf '%s' "${target_type:0:1}" | tr '[:lower:]' '[:upper:]')${target_type:1}"
	_print_ok "$target_type_cap #$target_number approved and signed"
	echo ""
	return 0
}

_approval_continuity_actor_authorized() {
	local slug="$1"
	local login="$2"
	local permission=""
	[[ "$login" =~ ^[A-Za-z0-9_.-]+$ ]] || return 1
	permission=$(gh api "repos/${slug}/collaborators/${login}/permission" --jq '.permission // "none"' 2>/dev/null) || return 2
	case "$permission" in
	admin | maintain | write) return 0 ;;
	esac
	return 1
}

_approval_verify_locked_issue_continuity() {
	local payload="$1"
	local current_snapshot="$2"
	local signed_digest="$3"
	local slug="$4"
	local target_number="$5"
	local issued_at="$6"
	local signed_lifecycle="" current_anchor="" signed_anchor="" candidate="" candidate_digest=""
	local timeline_pages="" mutation_rows="" event="" actor="" subject="" actor_rc=0

	# #aidevops:trust-boundary — no embedded lifecycle proof means this is a
	# legacy exact-snapshot approval, never continuity authority.
	signed_lifecycle=$(jq -c '.issue.lifecycle // empty' <<<"$payload" 2>/dev/null) || return 1
	[[ -n "$signed_lifecycle" ]] || return 1
	if ! jq -e --arg object "$APPROVAL_JSON_OBJECT" '.locked == true and (.lock_anchor | type == $object)' <<<"$signed_lifecycle" >/dev/null 2>&1; then
		return 1
	fi
	signed_anchor=$(jq -c '.lock_anchor' <<<"$signed_lifecycle") || return 1
	current_anchor=$(jq -c '.lifecycle.lock_anchor // empty' <<<"$current_snapshot") || return 1
	[[ -n "$current_anchor" && "$current_anchor" == "$signed_anchor" ]] || return 1
	if ! jq -e '.lifecycle.locked == true' <<<"$current_snapshot" >/dev/null 2>&1; then
		return 1
	fi

	# Replacing only lifecycle metadata must recreate the signed digest. This
	# proves title, body, comments, references, identity, and all scope-bearing
	# bytes remain exactly as reviewed.
	candidate=$(jq -cS --argjson lifecycle "$signed_lifecycle" '.lifecycle = $lifecycle' <<<"$current_snapshot") || return 1
	candidate_digest=$(approval_snapshot_v2_digest "$candidate") || return 2
	[[ "$candidate_digest" == "$signed_digest" ]] || return 1
	if ! jq -e --argjson signed "$signed_lifecycle" '
		def allowed_label: . == "needs-maintainer-review" or . == "auto-dispatch" or . == "status:available" or . == "status:queued" or . == "status:in-review" or . == "status:in-progress";
		.lifecycle as $current |
		$current.state == $signed.state
		and $current.state_reason == $signed.state_reason
		and $current.locked == $signed.locked
		and $current.active_lock_reason == $signed.active_lock_reason
		and $current.milestone == $signed.milestone
		and $current.lock_anchor == $signed.lock_anchor
		and ([(($current.labels + $signed.labels)[] | .name)] | unique | all(allowed_label))
		and ($current.assignees != $signed.assignees or $current.labels != $signed.labels)
	' <<<"$current_snapshot" >/dev/null 2>&1; then
		return 1
	fi

	timeline_pages=$(_approval_snapshot_v2_fetch_pages "repos/${slug}/issues/${target_number}/timeline?per_page=100") || return 2
	mutation_rows=$(jq -r --arg issued "$issued_at" '
		[.[][]? | select((.created_at // "") > $issued) | (.event // "") as $event |
		select(["assigned","unassigned","labeled","unlabeled","milestoned","demilestoned","closed","reopened","renamed","locked","unlocked","connected","disconnected","added_to_project","moved_columns_in_project","removed_from_project","transferred","converted_to_discussion","marked_as_duplicate","unmarked_as_duplicate","pinned","unpinned"] | index($event)) |
		[(.event // ""), (.actor.login // ""), (.label.name // .assignee.login // "")] | @tsv][]
	' <<<"$timeline_pages" 2>/dev/null) || return 2
	[[ -n "$mutation_rows" ]] || return 1

	while IFS=$'\t' read -r event actor subject; do
		[[ -n "$event" ]] || continue
		case "$event:$subject" in
		assigned:* | unassigned:* | labeled:needs-maintainer-review | unlabeled:needs-maintainer-review | labeled:auto-dispatch | unlabeled:auto-dispatch | labeled:status:available | unlabeled:status:available | labeled:status:queued | unlabeled:status:queued | labeled:status:in-review | unlabeled:status:in-review | labeled:status:in-progress | unlabeled:status:in-progress) ;;
		*) return 1 ;;
		esac
		actor_rc=0
		_approval_continuity_actor_authorized "$slug" "$actor" || actor_rc=$?
		[[ "$actor_rc" -eq 0 ]] || {
			[[ "$actor_rc" -eq 2 ]] && return 2
			return 1
		}
	done <<<"$mutation_rows"
	return 0
}

_approval_classify_digest_mismatch() {
	local target_type="$1"
	local target_number="$2"
	local slug="$3"
	local comment_id="$4"
	local issued_at="$5"
	local issue_lifecycle_profile="$6"
	local payload="$7"
	local snapshot_json="$8"
	local signed_digest="$9"
	local legacy_snapshot_json="" legacy_digest="" continuity_rc=0

	legacy_snapshot_json=$(approval_snapshot_v2_build "$target_type" "$target_number" "$slug" "$comment_id" "$issued_at" "$APPROVAL_SNAPSHOT_PROFILE_LEGACY" "$issue_lifecycle_profile") || {
		printf 'API_ERROR\n'
		return 0
	}
	legacy_digest=$(approval_snapshot_v2_digest "$legacy_snapshot_json") || {
		printf 'API_ERROR\n'
		return 0
	}
	if [[ "$legacy_digest" == "$signed_digest" ]]; then
		printf 'LEGACY_MATCH\n'
		return 0
	fi
	if [[ "$target_type" == "$APPROVAL_TARGET_ISSUE" ]]; then
		_approval_verify_locked_issue_continuity "$payload" "$snapshot_json" "$signed_digest" "$slug" "$target_number" "$issued_at" || continuity_rc=$?
		if [[ "$continuity_rc" -eq 0 ]]; then
			printf 'APPROVAL_REASON: proven-locked-continuity\n' >&2
			printf 'VERIFIED\n'
			return 0
		fi
		if [[ "$continuity_rc" -eq 2 ]]; then
			printf 'APPROVAL_REASON: continuity-api-uncertain\n' >&2
			printf 'API_ERROR\n'
			return 0
		fi
	fi
	printf 'APPROVAL_REASON: stale-or-unproven-continuity\n' >&2
	printf 'STALE_APPROVAL\n'
	return 0
}

_confirm_approval_batch() {
	local approval_mode="$1"
	local slug="$2"
	shift 2
	local target_count=$(($# / 3))
	local target_type=""
	local target_number=""
	local title=""
	local confirmation=""

	echo ""
	if [[ "$approval_mode" == "$_APPROVAL_BATCH_MODE" ]]; then
		echo "Approving ${target_count} issue/PR target(s):"
	elif [[ "$approval_mode" == "pr" ]]; then
		echo "Approving ${target_count} PR(s) to merge:"
	else
		echo "Approving ${target_count} issue(s) for development:"
	fi
	echo "  Repo: $slug"
	while [[ $# -gt 0 ]]; do
		target_type="$1"
		target_number="$2"
		title="$3"
		shift 3
		printf '  - %s #%s: %s\n' "$target_type" "$target_number" "$title"
	done
	echo ""
	printf 'Type APPROVE once to confirm all %s target(s): ' "$target_count"
	read -r confirmation
	if [[ "$confirmation" != "APPROVE" ]]; then
		_print_error "Approval cancelled"
		return 1
	fi
	return 0
}

_execute_approval_batch() {
	local slug="$1"
	local actual_key="$2"
	shift 2
	local target_spec=""
	local target_type=""
	local target_number=""
	local failed=0
	local target_count=$#

	for target_spec in "$@"; do
		target_type="${target_spec%%:*}"
		target_number="${target_spec#*:}"
		if ! _approve_target_after_confirmation "$target_type" "$target_number" "$slug" "$actual_key"; then
			failed=$((failed + 1))
		fi
	done
	if [[ "$failed" -gt 0 ]]; then
		_print_error "${failed} of ${target_count} approval(s) failed; successful targets remain signed"
		return 1
	fi
	_print_ok "All ${target_count} target(s) approved and signed"
	return 0
}

_approve_targets() {
	local approval_mode="$1"
	shift
	local usage="Usage: sudo aidevops approve ${approval_mode} <number> [number...] [owner/repo]"
	if [[ "$approval_mode" == "$_APPROVAL_BATCH_MODE" ]]; then
		usage="Usage: sudo aidevops approve batch issue:<number>|pr:<number> [...] [owner/repo]"
	fi
	local slug=""
	local arg=""
	local target_type=""
	local target_number=""
	local existing_target=""
	local title=""
	local actual_key=""
	local index=0
	local -a target_types=()
	local -a target_numbers=()
	local -a target_keys=()
	local -a display_rows=()

	for arg in "$@"; do
		if [[ "$arg" == */* ]]; then
			if [[ -n "$slug" ]]; then
				_print_error "Provide only one owner/repo slug"
				return 1
			fi
			slug="$arg"
			continue
		fi
		if [[ "$approval_mode" == "$_APPROVAL_BATCH_MODE" ]]; then
			if [[ ! "$arg" =~ ^(issue|pr):([0-9]+)$ ]]; then
				_print_error "$usage"
				return 1
			fi
			target_type="${arg%%:*}"
			target_number="${arg#*:}"
		else
			target_type="$approval_mode"
			target_number="$arg"
			_require_number_arg "$target_number" "$target_type" "$usage" || return 1
		fi
		for existing_target in "${target_keys[@]}"; do
			if [[ "$existing_target" == "${target_type}:${target_number}" ]]; then
				_print_error "Duplicate target in approval batch: ${target_type}:${target_number}"
				return 1
			fi
		done
		target_types+=("$target_type")
		target_numbers+=("$target_number")
		target_keys+=("${target_type}:${target_number}")
	done

	if [[ ${#target_numbers[@]} -eq 0 ]]; then
		_print_error "$usage"
		return 1
	fi

	_require_interactive_root "$usage" || return 1
	actual_key=$(_approval_private_key_path)
	_require_approval_key "$actual_key" || return 1
	_require_gh_auth || return 1

	slug=$(_resolve_slug_or_fail "$slug" "Could not detect repo slug. Provide it as the final owner/repo argument.") || return 1
	for ((index = 0; index < ${#target_numbers[@]}; index++)); do
		target_type="${target_types[$index]}"
		target_number="${target_numbers[$index]}"
		_validate_approval_target_kind "$target_type" "$target_number" "$slug" || return 1
		title=$(_fetch_target_title "$target_type" "$target_number" "$slug")
		display_rows+=("$target_type" "$target_number" "$title")
	done

	_confirm_approval_batch "$approval_mode" "$slug" "${display_rows[@]}" || return 1
	_execute_approval_batch "$slug" "$actual_key" "${target_keys[@]}"
	return $?
}

# Compatibility wrapper for callers that approve a single target directly.
_approve_target() {
	local target_type="$1"
	local target_number="${2:-}"
	local slug="${3:-}"
	if [[ -n "$slug" ]]; then
		_approve_targets "$target_type" "$target_number" "$slug"
	else
		_approve_targets "$target_type" "$target_number"
	fi
	return $?
}

_extract_fenced_block() {
	local body="$1"
	local target_block="$2"

	# Fenced code blocks have OPENING and CLOSING fence lines (``` pairs).
	# Count pairs (not individual fence lines) to identify block N.
	# Block 1 = content between fence pair 1, block 2 = content between pair 2, etc.
	printf '%s\n' "$body" | awk -v target="$target_block" '
		/^```/ {
			if (inside) {
				inside = 0
				if (capture) { exit }
			} else {
				pair++
				inside = 1
				if (pair == target) { capture = 1 }
				next
			}
			next
		}
		capture && inside { print }
	'
	return 0
}

_create_allowed_signers_file() {
	local pub_key="$1"
	local allowed_signers_file="$2"
	local key_content
	key_content=$(<"$pub_key")
	printf 'approval@aidevops.sh namespaces="%s" %s\n' "$APPROVAL_NAMESPACE" "$key_content" >"$allowed_signers_file"
	return 0
}

_verify_comment_signature() {
	local body="$1"
	local pub_key="$2"
	local payload signature payload_file sig_file allowed_signers_file

	payload=$(_extract_fenced_block "$body" 1)
	if [[ -z "$payload" ]]; then
		return 1
	fi

	signature=$(_extract_fenced_block "$body" 2)
	if [[ -z "$signature" ]]; then
		return 1
	fi

	payload_file=$(mktemp)
	sig_file=$(mktemp)
	allowed_signers_file=$(mktemp)
	printf '%s' "$payload" >"$payload_file"
	printf '%s\n' "$signature" >"$sig_file"
	_create_allowed_signers_file "$pub_key" "$allowed_signers_file"

	if ssh-keygen -Y verify \
		-f "$allowed_signers_file" \
		-I "approval@aidevops.sh" \
		-n "$APPROVAL_NAMESPACE" \
		-s "$sig_file" <"$payload_file" >/dev/null 2>&1; then
		rm -f "$payload_file" "$sig_file" "$allowed_signers_file"
		return 0
	fi

	rm -f "$payload_file" "$sig_file" "$allowed_signers_file"
	return 1
}

_approval_classify_signed_comment() {
	local target_type="$1"
	local target_number="$2"
	local slug="$3"
	local comment_id="$4"
	local body="$5"
	local pub_key="$6"
	local expected_head_sha="${7:-}"
	local payload="" snapshot_json="" current_digest="" signed_digest="" normalized_slug="" issued_at="" mismatch_classification=""
	normalized_slug=$(printf '%s' "$slug" | tr '[:upper:]' '[:lower:]')

	payload=$(_extract_fenced_block "$body" 1)
	if [[ -z "$payload" ]] || ! _verify_comment_signature "$body" "$pub_key"; then
		printf 'MALFORMED_APPROVAL\n'
		return 0
	fi

	if [[ "$payload" == APPROVE:* ]]; then
		local legacy_payload_prefix=""
		legacy_payload_prefix=$(printf 'APPROVE:%s:%s:%s:' "$target_type" "$slug" "$target_number" | tr '[:upper:]' '[:lower:]')
		if [[ "$(printf '%s' "$payload" | tr '[:upper:]' '[:lower:]')" == "${legacy_payload_prefix}"* ]]; then
			printf 'LEGACY_APPROVAL\n'
		else
			printf 'MALFORMED_APPROVAL\n'
		fi
		return 0
	fi

	if ! jq -e --arg type "$target_type" --arg repo "$normalized_slug" --arg number "$target_number" \
		--arg sha_pattern "$PERMISSION_SHA256_PATTERN" --arg string_type "$PERMISSION_JSON_STRING_TYPE" --arg object "$APPROVAL_JSON_OBJECT" '
		.schema == "aidevops-approval/v2"
		and .target.kind == $type
		and .target.repository == $repo
		and (.target.number | tostring) == $number
		and (.snapshot_sha256 | type == $string_type and test($sha_pattern))
		and (.issued_at | type == $string_type and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
		and (if $type == "pr" then (.authority == "merge" and (.pr | type == $object)) else (.authority == "development" and .pr == null and ((.issue // null) == null or (.issue.lifecycle | type == $object))) end)
	' <<<"$payload" >/dev/null 2>&1; then
		printf 'MALFORMED_APPROVAL\n'
		return 0
	fi

	if [[ "$target_type" == "pr" && -n "$expected_head_sha" ]] &&
		! jq -e --arg expected "$expected_head_sha" '.pr.head_sha == $expected' <<<"$payload" >/dev/null 2>&1; then
		printf 'STALE_APPROVAL\n'
		return 0
	fi

	issued_at=$(jq -r '.issued_at' <<<"$payload") || {
		printf 'MALFORMED_APPROVAL\n'
		return 0
	}
	local issue_lifecycle_profile="$APPROVAL_SNAPSHOT_PROFILE_CURRENT"
	if [[ "$target_type" == "$APPROVAL_TARGET_ISSUE" ]] && ! jq -e --arg object "$APPROVAL_JSON_OBJECT" '.issue.lifecycle | type == $object' <<<"$payload" >/dev/null 2>&1; then
		issue_lifecycle_profile="$APPROVAL_SNAPSHOT_PROFILE_LEGACY"
	fi
	snapshot_json=$(approval_snapshot_v2_build "$target_type" "$target_number" "$slug" "$comment_id" "$issued_at" "stable" "$issue_lifecycle_profile") || {
		printf 'API_ERROR\n'
		return 0
	}
	current_digest=$(approval_snapshot_v2_digest "$snapshot_json") || {
		printf 'API_ERROR\n'
		return 0
	}
	signed_digest=$(jq -r '.snapshot_sha256' <<<"$payload") || signed_digest=""
	if [[ "$current_digest" != "$signed_digest" ]]; then
		# #aidevops:trust-boundary — V2 approvals issued before GH#29009
		# included mutable linked-source updated_at metadata. Accept that profile
		# only when its complete current digest still matches the signed digest;
		# new approvals always use the stable profile above.
		mismatch_classification=$(_approval_classify_digest_mismatch "$target_type" "$target_number" "$slug" "$comment_id" "$issued_at" \
			"$issue_lifecycle_profile" "$payload" "$snapshot_json" "$signed_digest")
		if [[ "$mismatch_classification" != "LEGACY_MATCH" ]]; then
			printf '%s\n' "$mismatch_classification"
			return 0
		fi
		snapshot_json=$(approval_snapshot_v2_build "$target_type" "$target_number" "$slug" "$comment_id" "$issued_at" "$APPROVAL_SNAPSHOT_PROFILE_LEGACY" "$issue_lifecycle_profile") || {
			printf 'API_ERROR\n'
			return 0
		}
	fi

	if [[ "$target_type" == "pr" ]]; then
		if ! jq -e --argjson snapshot "$snapshot_json" '
			.pr.head_sha == $snapshot.head.sha
			and .pr.head_ref == $snapshot.head.ref
			and .pr.head_repository == $snapshot.head.repository
			and .pr.base_ref == $snapshot.base.ref
			and .pr.base_repository == $snapshot.base.repository
		' <<<"$payload" >/dev/null 2>&1; then
			printf 'STALE_APPROVAL\n'
			return 0
		fi
	fi

	printf 'APPROVAL_REASON: exact-snapshot\n' >&2
	printf 'VERIFIED\n'
	return 0
}

# ── Setup ────────────────────────────────────────────────────────────────────

cmd_setup() {
	echo ""
	echo "Setting up cryptographic approval key pair..."
	echo ""

	# Must be run as root (via sudo)
	if [[ "$(id -u)" -ne 0 ]]; then
		_print_error "This command must be run with sudo"
		echo "Usage: sudo aidevops approve setup"
		return 1
	fi

	# Detect the real user behind sudo
	local real_user="${SUDO_USER:-$(whoami)}"
	local real_home
	real_home=$(_resolve_real_home)
	local actual_approval_dir="$real_home/.aidevops/approval-keys"
	local actual_private_dir="$actual_approval_dir/private"
	local actual_key="$actual_private_dir/approval.key"
	local actual_pub="$actual_approval_dir/approval.pub"

	# Create directories
	mkdir -p "$actual_private_dir"

	# Generate key pair if it doesn't exist
	if [[ -f "$actual_key" ]]; then
		_print_info "Approval key already exists: $actual_key"
	else
		_print_info "Generating Ed25519 approval signing key..."
		ssh-keygen -t ed25519 -C "aidevops-approval-signing" \
			-f "$actual_key" -N "" -q
		_print_ok "Generated approval key pair"
	fi

	# Set ownership: private dir and key owned by root, not readable by user
	chown root:wheel "$actual_private_dir" 2>/dev/null || chown root:root "$actual_private_dir" 2>/dev/null || true
	chmod 700 "$actual_private_dir"
	chown root:wheel "$actual_key" 2>/dev/null || chown root:root "$actual_key" 2>/dev/null || true
	chmod 600 "$actual_key"
	# Also protect the private key's .pub companion that ssh-keygen creates
	if [[ -f "${actual_key}.pub" ]]; then
		chown root:wheel "${actual_key}.pub" 2>/dev/null || chown root:root "${actual_key}.pub" 2>/dev/null || true
		chmod 600 "${actual_key}.pub"
	fi

	# Copy public key to user-accessible location
	if [[ -f "${actual_key}.pub" ]]; then
		cp "${actual_key}.pub" "$actual_pub"
	elif [[ -f "$actual_key" ]]; then
		ssh-keygen -y -f "$actual_key" >"$actual_pub"
	fi
	chown "$real_user" "$actual_pub" 2>/dev/null || true
	chmod 644 "$actual_pub"

	# Set user-level dir ownership
	chown "$real_user" "$actual_approval_dir" 2>/dev/null || true

	_print_ok "Approval key pair configured"
	echo ""
	echo "  Private key (root-only): $actual_key"
	echo "  Public key (user-readable): $actual_pub"
	echo ""
	echo "The private key is owned by root and only accessible via sudo."
	echo "Workers cannot read it, even though they run as your user account."
	echo ""
	echo "You can now approve issues/PRs with:"
	echo "  sudo aidevops approve issue <number> <owner/repo>"
	echo "  sudo aidevops approve pr <number> <owner/repo>"
	echo "  sudo aidevops approve issue <number> [number...] <owner/repo>"
	echo "  sudo aidevops approve batch issue:<number> pr:<number> [...] <owner/repo>"
	return 0
}

# ── Approve Issue ────────────────────────────────────────────────────────────

cmd_issue_approved() {
	_approve_targets "issue" "$@"
	return $?
}

# ── Approve PR ───────────────────────────────────────────────────────────────

cmd_pr_approved() {
	_approve_targets "pr" "$@"
	return $?
}

cmd_batch_approved() {
	_approve_targets "$_APPROVAL_BATCH_MODE" "$@"
	return $?
}

# ── Verify Approval ──────────────────────────────────────────────────────────

#######################################
# Verify that a signed approval comment belongs to the currently authenticated
# actor and that GitHub reports maintainer-equivalent authority for that actor.
# OWNER/MEMBER associations are authoritative repository-scoped API fields;
# CONTRIBUTOR/COLLABORATOR associations require a current permission lookup.
# Bot, mismatched, malformed, and permission-uncertain identities fail closed.
#
# Args: repo slug, required actor, commenter, user type, author association
# Returns: 0 trusted, 1 untrusted, 2 authority lookup uncertainty
#######################################
_approval_comment_has_required_authority() {
	local slug="$1"
	local required_actor="$2"
	local commenter="$3"
	local user_type="$4"
	local association="$5"
	local normalized_required=""
	local normalized_commenter=""
	local permission=""

	[[ "$slug" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || return 1
	[[ "$required_actor" =~ ^[A-Za-z0-9_.-]+$ ]] || return 1
	[[ "$commenter" =~ ^[A-Za-z0-9_.-]+$ ]] || return 1
	[[ "$user_type" == "User" ]] || return 1
	normalized_required=$(printf '%s' "$required_actor" | tr '[:upper:]' '[:lower:]')
	normalized_commenter=$(printf '%s' "$commenter" | tr '[:upper:]' '[:lower:]')
	[[ "$normalized_required" == "$normalized_commenter" ]] || return 1

	case "$association" in
	OWNER | MEMBER)
		return 0
		;;
	CONTRIBUTOR | COLLABORATOR)
		permission=$(gh api "repos/${slug}/collaborators/${commenter}/permission" \
			--jq '.permission // "none"' 2>/dev/null) || return 2
		case "$permission" in
		admin | maintain | write) return 0 ;;
		esac
		return 1
		;;
	esac
	return 1
}

_approval_classify_marked_comments() {
	local target_type="$1"
	local target_number="$2"
	local slug="$3"
	local comments_json="$4"
	local pub_key="$5"
	local expected_head_sha="${6:-}"
	local comment_count="$7"
	local required_actor="${8:-}"
	local saw_api_error=0 saw_stale=0 saw_legacy=0 saw_untrusted=0 saw_malformed=0
	local comment_rows=""
	local base64_decode_flag="-d"
	[[ "$(uname -s)" == "Darwin" ]] && base64_decode_flag="-D"

	if [[ -z "$comments_json" || "$comment_count" -le 0 ]]; then
		printf 'MALFORMED_APPROVAL\n'
		return 5
	fi
	comment_rows=$(jq -r --arg missing "$_APPROVAL_MISSING_FIELD" '
		reverse[]
		| [
			((.id // "") | tostring),
			((.body // "") | @base64),
			(.user.login // $missing),
			(.user.type // $missing),
			(.author_association // $missing)
		]
		| @tsv
	' <<<"$comments_json") || {
		printf 'MALFORMED_APPROVAL\n'
		return 5
	}

	while IFS=$'\t' read -r comment_id encoded_body commenter user_type association; do
		local body="" classification="" authority_rc=0
		body=$(printf '%s' "$encoded_body" | base64 "$base64_decode_flag") || {
			saw_malformed=1
			continue
		}
		if [[ ! "$comment_id" =~ ^[0-9]+$ ]]; then
			saw_malformed=1
			continue
		fi
		if [[ -n "$required_actor" ]]; then
			_approval_comment_has_required_authority "$slug" "$required_actor" \
				"$commenter" "$user_type" "$association" || authority_rc=$?
			if [[ "$authority_rc" -eq 2 ]]; then
				saw_api_error=1
				continue
			fi
			if [[ "$authority_rc" -ne 0 ]]; then
				saw_untrusted=1
				continue
			fi
		fi
		classification=$(_approval_classify_signed_comment "$target_type" "$target_number" "$slug" "$comment_id" "$body" "$pub_key" "$expected_head_sha")
		case "$classification" in
		VERIFIED) printf 'VERIFIED\n'; return 0 ;;
		API_ERROR) saw_api_error=1 ;;
		STALE_APPROVAL) saw_stale=1 ;;
		LEGACY_APPROVAL) saw_legacy=1 ;;
		*) saw_malformed=1 ;;
		esac
	done <<<"$comment_rows"

	[[ "$saw_api_error" -eq 0 ]] || { printf 'API_ERROR\n'; return 6; }
	[[ "$saw_stale" -eq 0 ]] || { printf 'STALE_APPROVAL\n'; return 4; }
	[[ "$saw_legacy" -eq 0 ]] || { printf 'LEGACY_APPROVAL\n'; return 3; }
	[[ "$saw_untrusted" -eq 0 ]] || { printf 'UNTRUSTED_APPROVAL\n'; return 7; }
	[[ "$saw_malformed" -eq 1 ]] || saw_malformed=1
	printf 'MALFORMED_APPROVAL\n'
	return 5
}

# Verify a V2 approval against the current immutable issue/PR snapshot.
# Legacy syntax (`verify N slug`) remains an issue verification request, but V1
# signatures return LEGACY_APPROVAL and never authorize an external merge.
cmd_verify() {
	local target_type="issue"
	if [[ "${1:-}" == "issue" || "${1:-}" == "pr" ]]; then
		target_type="$1"
		shift
	fi
	local target_number="${1:-}"
	local slug=""
	local require_authority=0
	shift 2>/dev/null || true
	if [[ $# -gt 0 && "$1" != --* ]]; then
		slug="$1"
		shift
	fi
	local expected_head_sha=""
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--expect-head)
			expected_head_sha="${2:-}"
			shift 2
			;;
		--require-authority)
			require_authority=1
			shift
			;;
		*)
			printf 'MALFORMED_APPROVAL\n'
			return 5
			;;
		esac
	done
	if [[ -n "$expected_head_sha" && ! "$expected_head_sha" =~ ^[0-9A-Fa-f]{7,64}$ ]]; then
		printf 'MALFORMED_APPROVAL\n'
		return 5
	fi

	_require_number_arg "$target_number" "$target_type" "Usage: aidevops approve verify [issue|pr] <number> [owner/repo] [--expect-head SHA] [--require-authority]" || return 5
	slug=$(_resolve_slug_or_fail "$slug" "Could not detect repo slug") || return 1

	local required_actor=""
	if [[ "$require_authority" -eq 1 ]]; then
		required_actor=$(gh api user --jq '.login // empty' 2>/dev/null) || {
			printf 'API_ERROR\n'
			return 6
		}
		if ! [[ "$required_actor" =~ ^[A-Za-z0-9_.-]+$ ]]; then
			printf 'API_ERROR\n'
			return 6
		fi
	fi

	local comment_pages="" comments_json="" endpoint=""
	endpoint=$(_permission_comments_endpoint "$slug" "$target_number")
	comment_pages=$(gh api "$endpoint" --paginate --slurp 2>/dev/null) || {
		printf 'API_ERROR\n'
		return 6
	}
	comments_json=$(jq -c --arg marker "$APPROVAL_MARKER" --arg array_type "$PERMISSION_JSON_ARRAY_TYPE" '
		(if type == $array_type and all(.[]; type == $array_type) then [.[][]?] else [.[]?] end)
		| [ .[] | select((.body // "") | contains($marker)) ]
		| sort_by(.id)
	' <<<"$comment_pages" 2>/dev/null) || {
		printf 'API_ERROR\n'
		return 6
	}

	local comment_count
	comment_count=$(printf '%s' "$comments_json" | jq 'length' 2>/dev/null) || {
		printf 'API_ERROR\n'
		return 6
	}

	if [[ "$comment_count" -eq 0 ]]; then
		printf 'NO_APPROVAL\n'
		return 1
	fi

	# Load public key only after proving an approval marker exists. This keeps
	# callers able to distinguish "no approval" from "approval exists but this
	# worker cannot verify it" and avoids re-applying NMR over a signed approval.
	local pub_key="${AIDEVOPS_APPROVAL_PUB:-$APPROVAL_PUB}"
	if [[ ! -f "$pub_key" ]]; then
		printf 'NO_KEY\n'
		return 2
	fi

	_approval_classify_marked_comments "$target_type" "$target_number" "$slug" "$comments_json" "$pub_key" "$expected_head_sha" "$comment_count" "$required_actor"
	return $?
}

# Reconcile an approval that GitHub Actions conservatively re-blocked after the
# original local lifecycle transition. This command never signs or posts a new
# approval. It observes a live NMR hold, independently re-verifies the existing
# V2 signature against current target state and the authenticated actor's
# maintainer authority, then reuses the normal issue/PR lifecycle writers.
cmd_reconcile() {
	local target_type="${1:-}"
	local target_number="${2:-}"
	local slug="${3:-}"
	local usage="Usage: aidevops approve reconcile issue|pr <number> [owner/repo]"
	local issue_json=""
	local actual_type=""
	local target_state=""
	local nmr_rc=0
	local verification=""
	local verify_rc=0

	if [[ "$target_type" != "issue" && "$target_type" != "pr" ]]; then
		printf 'MALFORMED_APPROVAL\n'
		return 5
	fi
	_require_number_arg "$target_number" "$target_type" "$usage" >/dev/null 2>&1 || {
		printf 'MALFORMED_APPROVAL\n'
		return 5
	}
	slug=$(_resolve_slug_or_fail "$slug" "$usage") || {
		printf 'API_ERROR\n'
		return 6
	}

	issue_json=$(_approval_fetch_issue_json "$target_number" "$slug") || {
		printf 'API_ERROR\n'
		return 6
	}
	actual_type=$(printf '%s' "$issue_json" | jq -r 'if type != "object" then "invalid" elif .pull_request? != null then "pr" else "issue" end' 2>/dev/null) || actual_type="invalid"
	if [[ "$actual_type" != "$target_type" ]]; then
		printf 'TARGET_MISMATCH\n'
		return 5
	fi
	target_state=$(printf '%s' "$issue_json" | jq -r '.state // "" | ascii_downcase' 2>/dev/null) || target_state=""
	if [[ "$target_state" == "closed" ]]; then
		printf 'TARGET_CLOSED\n'
		return 0
	fi
	if [[ "$target_state" != "open" ]]; then
		printf 'API_ERROR\n'
		return 6
	fi
	printf '%s' "$issue_json" | jq -e --arg label "$_APPROVAL_NMR_LABEL" \
		'(.labels // []) | any(.name == $label)' >/dev/null 2>&1 || nmr_rc=$?
	if [[ "$nmr_rc" -eq 1 ]]; then
		printf 'NO_NMR\n'
		return 3
	fi
	if [[ "$nmr_rc" -ne 0 ]]; then
		printf 'API_ERROR\n'
		return 6
	fi

	# #aidevops:trust-boundary GH#28717 — current-state V2 verification and
	# authenticated actor authority are mandatory immediately before mutation.
	verification=$(cmd_verify "$target_type" "$target_number" "$slug" --require-authority 2>/dev/null) || verify_rc=$?
	if [[ "$verification" != "VERIFIED" || "$verify_rc" -ne 0 ]]; then
		printf '%s\n' "${verification:-API_ERROR}"
		if [[ "$verify_rc" -ne 0 ]]; then
			return "$verify_rc"
		fi
		return 6
	fi

	if ! _post_issue_approval_updates "$target_type" "$target_number" "$slug" >/dev/null 2>&1; then
		# A lifecycle writer may fail after partially clearing NMR (for example,
		# issue label mutation succeeds but its advisory lock fails). Reassert the
		# conservative hold before reporting uncertainty to the bounded caller.
		_approval_restore_nmr_hold "$target_type" "$target_number" "$slug" >/dev/null 2>&1 || true
		printf 'UPDATE_FAILED\n'
		return 8
	fi
	printf 'RECONCILED\n'
	return 0
}

# ── Status ───────────────────────────────────────────────────────────────────

cmd_status() {
	echo ""
	echo "Approval key status"
	echo "==================="
	echo ""

	if [[ -f "$APPROVAL_PUB" ]]; then
		_print_ok "Public key exists: $APPROVAL_PUB"
		echo "  Fingerprint: $(ssh-keygen -lf "$APPROVAL_PUB" 2>/dev/null || echo "unknown")"
	else
		_print_warn "No approval public key found"
		echo "  Run: sudo aidevops approve setup"
	fi

	echo ""
	if [[ -d "$APPROVAL_PRIVATE_DIR" ]]; then
		local owner perms
		owner=$(_file_owner "$APPROVAL_PRIVATE_DIR")
		perms=$(_file_perms "$APPROVAL_PRIVATE_DIR")
		if [[ "$owner" == "root" && "$perms" == "700" ]]; then
			_print_ok "Private key directory is root-protected (owner=$owner, mode=$perms)"
		else
			_print_warn "Private key directory permissions may be insecure (owner=$owner, mode=$perms)"
			echo "  Expected: owner=root, mode=700"
			echo "  Run: sudo aidevops approve setup"
		fi
	else
		_print_warn "No private key directory found"
		echo "  Run: sudo aidevops approve setup"
	fi

	echo ""
	return 0
}

# ── Help ─────────────────────────────────────────────────────────────────────

cmd_help() {
	echo "approval-helper.sh — Cryptographic approval gate covering external issues/PRs"
	echo ""
	echo "Commands (require sudo):"
	echo "  setup                      Generate root-protected approval key pair"
	echo "  issue <number...> [slug]   Approve one or more issues with one confirmation"
	echo "  pr <number...> [slug]      Approve one or more PRs with one confirmation"
	echo "  batch <kind:number...> [slug] Approve mixed issues/PRs with one confirmation"
	echo "  permissions issue|pr <number> [slug] --request perm-<id>"
	echo ""
	echo "Commands (no sudo needed):"
	echo "  verify [issue|pr] <number> [slug] [--expect-head SHA] [--require-authority]"
	echo "  verify-permissions issue|pr <number> [slug]"
	echo "  reconcile issue|pr <number> [slug]"
	echo "  status                     Show approval key setup status"
	echo "  help                       Show this help"
	echo ""
	echo "Examples:"
	echo "  sudo aidevops approve setup"
	echo "  sudo aidevops approve issue 17438 <owner/repo>"
	echo "  sudo aidevops approve issue 17438 17440 17442 <owner/repo>"
	echo "  sudo aidevops approve pr 17439 17441 <owner/repo>"
	echo "  sudo aidevops approve batch issue:17438 pr:17439 pr:17441 <owner/repo>"
	echo "  sudo aidevops approve permissions issue 17438 <owner/repo> --request perm-0123456789abcdef"
	echo "  aidevops approve verify 17438"
	echo "  aidevops approve verify pr 17439 <owner/repo> --expect-head <sha>"
	echo ""
	echo "Security: The approval signing key is stored root-only. Workers run as your"
	echo "user account and cannot access it, even with the same GitHub credentials."
	return 0
}

# ── Main ─────────────────────────────────────────────────────────────────────

main() {
	local command="${1:-help}"
	shift 2>/dev/null || true

	case "$command" in
	setup) cmd_setup "$@" ;;
	issue | issue-approved) cmd_issue_approved "$@" ;;
	pr | pr-approved) cmd_pr_approved "$@" ;;
	batch) cmd_batch_approved "$@" ;;
	permissions) cmd_permissions "$@" ;;
	verify-permissions) cmd_verify_permissions "$@" ;;
	verify) cmd_verify "$@" ;;
	reconcile) cmd_reconcile "$@" ;;
	status) cmd_status "$@" ;;
	help | --help | -h) cmd_help ;;
	*)
		_print_error "Unknown command: $command"
		cmd_help
		return 1
		;;
	esac
	return $?
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	main "$@"
fi

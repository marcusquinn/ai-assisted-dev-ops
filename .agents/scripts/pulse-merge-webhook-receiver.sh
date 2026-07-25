#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# pulse-merge-webhook-receiver.sh — GitHub webhook → process_pr (t3038)
#
# Listens for GitHub webhook deliveries, validates the HMAC SHA-256
# signature, decodes the event payload, and dispatches the affected
# PR(s) to pulse-merge.sh::process_pr immediately — replacing the
# 120s polling latency in pulse-merge-routine.sh with seconds.
#
# Architecture:
#   - Bash entry point parses CLI flags (run, --port, --check, help).
#   - Configuration loaded from .agents/configs/webhook-receiver.conf.
#   - Secret loaded from the env var named in WEBHOOK_SECRET_ENV
#     (e.g. GITHUB_WEBHOOK_SECRET, set via gopass or credentials.sh).
#   - Python HTTP server (stdlib only) handles the request loop, records
#     authenticated delivery IDs, and prints versioned invalidation records
#     before existing "PROCESS_PR <slug> <pr_number>" action lines.
#   - Unknown events return 204; bad signatures return 401; neither mutates state.
#
# This split (Python parses, bash dispatches) keeps the gh + process_pr
# call path identical to the polling routine — no duplicated merge logic.
#
# Backstop: pulse-merge-routine.sh's 120s polling loop continues to run
# regardless of receiver state. If the receiver is down, eligible PRs
# still merge on the next polling cycle.
#
# Usage:
#   pulse-merge-webhook-receiver.sh [run]   Start the receiver (default)
#   pulse-merge-webhook-receiver.sh --check Validate config + secret only
#   pulse-merge-webhook-receiver.sh help    Show usage
#
# Webhook configuration on the GitHub side:
#   - Payload URL: https://<your-tunnel>/webhook (Cloudflare Tunnel etc.)
#   - Content type: application/json
#   - Secret: the value stored in WEBHOOK_SECRET_ENV
#   - Events: Issues/comments, pull requests/reviews, checks/status/workflows
#
# Part of aidevops framework: https://aidevops.sh

set -euo pipefail

_aidevops_path_prefix="/opt/homebrew/bin:/usr/local/bin:/bin:/usr/bin"
if [[ "$(uname -s 2>/dev/null || true)" != "Darwin" && -d "/home/linuxbrew/.linuxbrew/bin" ]]; then
	_aidevops_path_prefix="/opt/homebrew/bin:/usr/local/bin:/home/linuxbrew/.linuxbrew/bin:/bin:/usr/bin"
fi
export PATH="${_aidevops_path_prefix}:${PATH}"
unset _aidevops_path_prefix

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
if [[ -r "${SCRIPT_DIR}/pulse-runtime-pin.sh" ]]; then
	# shellcheck source=./pulse-runtime-pin.sh
	source "${SCRIPT_DIR}/pulse-runtime-pin.sh"
	pulse_runtime_pin_reexec "${SCRIPT_DIR%/scripts}" "scripts/pulse-merge-webhook-receiver.sh" "$@" || exit $?
fi
AIDEVOPS_AGENTS_DIR="${SCRIPT_DIR%/scripts}"
AGENTS_DIR="$AIDEVOPS_AGENTS_DIR"
export AIDEVOPS_AGENTS_DIR AGENTS_DIR

# =============================================================================
# Config + secret loading
# =============================================================================

WEBHOOK_CONF="${WEBHOOK_CONF:-${SCRIPT_DIR}/../configs/webhook-receiver.conf}"
if [[ ! -f "$WEBHOOK_CONF" ]]; then
	# Fallback to deployed location.
	WEBHOOK_CONF="${HOME}/.aidevops/agents/configs/webhook-receiver.conf"
fi
if [[ ! -f "$WEBHOOK_CONF" ]]; then
	printf 'webhook-receiver: config not found (looked at %s)\n' "$WEBHOOK_CONF" >&2
	exit 2
fi

# Source config, but allow caller env to override conf file values.
# Pattern: capture pre-set vars, source the conf, then restore overrides.
_WEBHOOK_OVERRIDE_HOST="${WEBHOOK_LISTEN_HOST:-}"
_WEBHOOK_OVERRIDE_PORT="${WEBHOOK_LISTEN_PORT:-}"
_WEBHOOK_OVERRIDE_EVENTS="${WEBHOOK_HANDLED_EVENTS:-}"
_WEBHOOK_OVERRIDE_MAX="${WEBHOOK_MAX_BODY_BYTES:-}"
_WEBHOOK_OVERRIDE_SECRET_ENV="${WEBHOOK_SECRET_ENV:-}"
_WEBHOOK_OVERRIDE_LOG="${WEBHOOK_LOG_FILE:-}"
_WEBHOOK_OVERRIDE_LEDGER="${WEBHOOK_DELIVERY_LEDGER_FILE:-}"
_WEBHOOK_OVERRIDE_LEDGER_TTL="${WEBHOOK_DELIVERY_TTL_SECONDS:-}"
_WEBHOOK_OVERRIDE_LEDGER_MAX="${WEBHOOK_DELIVERY_MAX_ENTRIES:-}"
_WEBHOOK_OVERRIDE_CONCURRENCY="${WEBHOOK_DISPATCH_MAX_CONCURRENCY:-}"
_WEBHOOK_OVERRIDE_PROTOCOL="${WEBHOOK_ACTION_PROTOCOL_VERSION:-}"

# shellcheck source=/dev/null
source "$WEBHOOK_CONF"

[[ -n "$_WEBHOOK_OVERRIDE_HOST" ]] && WEBHOOK_LISTEN_HOST="$_WEBHOOK_OVERRIDE_HOST"
[[ -n "$_WEBHOOK_OVERRIDE_PORT" ]] && WEBHOOK_LISTEN_PORT="$_WEBHOOK_OVERRIDE_PORT"
[[ -n "$_WEBHOOK_OVERRIDE_EVENTS" ]] && WEBHOOK_HANDLED_EVENTS="$_WEBHOOK_OVERRIDE_EVENTS"
[[ -n "$_WEBHOOK_OVERRIDE_MAX" ]] && WEBHOOK_MAX_BODY_BYTES="$_WEBHOOK_OVERRIDE_MAX"
[[ -n "$_WEBHOOK_OVERRIDE_SECRET_ENV" ]] && WEBHOOK_SECRET_ENV="$_WEBHOOK_OVERRIDE_SECRET_ENV"
[[ -n "$_WEBHOOK_OVERRIDE_LOG" ]] && WEBHOOK_LOG_FILE="$_WEBHOOK_OVERRIDE_LOG"
[[ -n "$_WEBHOOK_OVERRIDE_LEDGER" ]] && WEBHOOK_DELIVERY_LEDGER_FILE="$_WEBHOOK_OVERRIDE_LEDGER"
[[ -n "$_WEBHOOK_OVERRIDE_LEDGER_TTL" ]] && WEBHOOK_DELIVERY_TTL_SECONDS="$_WEBHOOK_OVERRIDE_LEDGER_TTL"
[[ -n "$_WEBHOOK_OVERRIDE_LEDGER_MAX" ]] && WEBHOOK_DELIVERY_MAX_ENTRIES="$_WEBHOOK_OVERRIDE_LEDGER_MAX"
[[ -n "$_WEBHOOK_OVERRIDE_CONCURRENCY" ]] && WEBHOOK_DISPATCH_MAX_CONCURRENCY="$_WEBHOOK_OVERRIDE_CONCURRENCY"
[[ -n "$_WEBHOOK_OVERRIDE_PROTOCOL" ]] && WEBHOOK_ACTION_PROTOCOL_VERSION="$_WEBHOOK_OVERRIDE_PROTOCOL"

# Load credentials.sh (provides the webhook secret env var if not from gopass).
if [[ -f "${HOME}/.config/aidevops/credentials.sh" ]]; then
	# shellcheck source=/dev/null
	. "${HOME}/.config/aidevops/credentials.sh" 2>/dev/null || true
fi

WEBHOOK_LOG_FILE="${WEBHOOK_LOG_FILE:-${HOME}/.aidevops/logs/pulse-merge-webhook.log}"
WEBHOOK_HANDLED_EVENTS="${WEBHOOK_HANDLED_EVENTS:-check_run,check_suite,status,workflow_run,issues,issue_comment,pull_request,pull_request_review,pull_request_review_comment,pull_request_review_thread}"
WEBHOOK_DELIVERY_LEDGER_FILE="${WEBHOOK_DELIVERY_LEDGER_FILE:-${HOME}/.aidevops/state/pulse-merge-webhook-deliveries.json}"
WEBHOOK_DELIVERY_TTL_SECONDS="${WEBHOOK_DELIVERY_TTL_SECONDS:-604800}"
WEBHOOK_DELIVERY_MAX_ENTRIES="${WEBHOOK_DELIVERY_MAX_ENTRIES:-4096}"
WEBHOOK_DISPATCH_MAX_CONCURRENCY="${WEBHOOK_DISPATCH_MAX_CONCURRENCY:-4}"
WEBHOOK_ACTION_PROTOCOL_VERSION="${WEBHOOK_ACTION_PROTOCOL_VERSION:-v1}"
_WEBHOOK_INVALIDATION_FAILED=0
_WEBHOOK_DELIVERY_RECEIVED_MS=0
mkdir -p "$(dirname "$WEBHOOK_LOG_FILE")"

_whlog() {
	local level="$1"
	shift
	local ts
	ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
	printf '[%s] [%s] %s\n' "$ts" "$level" "$*" >>"$WEBHOOK_LOG_FILE"
	return 0
}

_webhook_now_ms() {
	local now_ms=""
	if declare -F _gh_now_ms >/dev/null 2>&1; then
		_gh_now_ms || return 1
		return 0
	fi
	now_ms=$(date +%s 2>/dev/null) || return 1
	[[ "$now_ms" =~ ^[0-9]+$ ]] || return 1
	printf '%s\n' "$((now_ms * 1000))"
	return 0
}

_webhook_record_invalidation_evidence() {
	local received_ms="${_WEBHOOK_DELIVERY_RECEIVED_MS:-0}"
	local now_ms=""
	local lag_ms=""
	declare -F gh_record_efficiency_evidence >/dev/null 2>&1 || return 0
	gh_record_efficiency_evidence webhook.invalidations 1 2>/dev/null || true
	[[ "$received_ms" =~ ^[0-9]+$ && "$received_ms" -gt 0 ]] || return 0
	now_ms=$(_webhook_now_ms) || return 0
	[[ "$now_ms" =~ ^[0-9]+$ && "$now_ms" -ge "$received_ms" ]] || return 0
	lag_ms=$((now_ms - received_ms))
	[[ "$lag_ms" -le 604800000 ]] || return 0
	gh_record_efficiency_evidence webhook.lag_ms "$lag_ms" 2>/dev/null || true
	return 0
}

_webhook_record_missed_recovery() {
	if declare -F gh_record_efficiency_evidence >/dev/null 2>&1; then
		gh_record_efficiency_evidence webhook.missed_recoveries 1 2>/dev/null || true
	fi
	return 0
}

# Resolve the secret value from the env var named in WEBHOOK_SECRET_ENV.
# We never log the secret itself — only whether it is set.
_resolve_secret() {
	local env_var_name="${WEBHOOK_SECRET_ENV:-GITHUB_WEBHOOK_SECRET}"
	[[ "$env_var_name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
	# shellcheck disable=SC2086
	local secret_val="${!env_var_name:-}"
	if [[ -z "$secret_val" ]]; then
		# Try gopass as a secondary source — best-effort, fail-quiet.
		if command -v gopass >/dev/null 2>&1; then
			secret_val=$(gopass show -o "aidevops/${env_var_name}" 2>/dev/null || true)
		fi
	fi
	printf '%s' "$secret_val"
	return 0
}

_clear_webhook_secret_env() {
	local env_var_name="${WEBHOOK_SECRET_ENV:-GITHUB_WEBHOOK_SECRET}"
	[[ "$env_var_name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
	unset "$env_var_name"
	return 0
}

_webhook_positive_integer() {
	local value="$1"
	[[ "$value" =~ ^[0-9]+$ && "$value" -gt 0 ]]
	return $?
}

_webhook_valid_slug() {
	local slug="$1"
	local owner="${slug%%/*}"
	local name="${slug#*/}"
	[[ "$slug" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || return 1
	[[ "$owner" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || return 1
	[[ "$name" != "." && "$name" != ".." ]]
	return $?
}

_webhook_invalidate_collection() {
	local kind="$1"
	local slug="$2"
	local helper="${SCRIPT_DIR}/pulse-batch-prefetch-helper.sh"
	case "$kind" in
	issues | prs) ;;
	*) return 1 ;;
	esac
	_webhook_valid_slug "$slug" || return 1
	[[ -x "$helper" ]] || return 1
	if ! "$helper" invalidate-collection --kind "$kind" --slug "$slug" >/dev/null 2>>"$WEBHOOK_LOG_FILE"; then
		return 1
	fi
	_whlog INFO "Invalidated canonical ${kind} snapshot for ${slug}"
	return 0
}

_webhook_invalidate_checks() {
	local slug="$1"
	local sha="$2"
	_webhook_valid_slug "$slug" || return 1
	[[ "$sha" =~ ^[A-Fa-f0-9]{40}$ ]] || return 1
	declare -F gh_pr_check_status_cache_invalidate >/dev/null 2>&1 || return 1
	gh_pr_check_status_cache_invalidate "$slug" "$sha" || return 1
	_whlog INFO "Invalidated exact-SHA check snapshot for ${slug}"
	return 0
}

_webhook_wait_for_dispatch_slot() {
	local max_concurrency="${WEBHOOK_DISPATCH_MAX_CONCURRENCY:-4}"
	_webhook_positive_integer "$max_concurrency" || max_concurrency=4
	while [[ "$(jobs -rp | wc -l)" -ge "$max_concurrency" ]]; do
		sleep 0.2
	done
	return 0
}

_dispatch_webhook_action_line() {
	local line="$1"
	local verb="" version="" scope="" first="" second="" extra=""
	case "$line" in
	'#'*)
		_whlog INFO "${line#'# '}"
		if [[ "$line" == '# accepted '* ]]; then
			_WEBHOOK_INVALIDATION_FAILED=0
			_WEBHOOK_DELIVERY_RECEIVED_MS=0
		fi
		return 0
		;;
	'') return 0 ;;
	esac
	IFS=' ' read -r verb version scope first second extra <<<"$line"
	case "${verb} ${version} ${scope}" in
	"DELIVERY v1 received-ms")
		if [[ "$first" =~ ^[0-9]+$ && "$first" -gt 0 \
			&& -z "$second" && -z "$extra" ]]; then
			_WEBHOOK_DELIVERY_RECEIVED_MS="$first"
			_WEBHOOK_INVALIDATION_FAILED=0
		else
			_WEBHOOK_DELIVERY_RECEIVED_MS=0
			_WEBHOOK_INVALIDATION_FAILED=1
			_whlog ERROR "Rejected malformed delivery timing record"
		fi
		return 0
		;;
	"INVALIDATE v1 collection")
		_WEBHOOK_INVALIDATION_FAILED=0
		if [[ -n "$extra" ]]; then
			_WEBHOOK_INVALIDATION_FAILED=1
			_whlog ERROR "Rejected malformed collection invalidation record"
		elif ! _webhook_invalidate_collection "$first" "$second"; then
			_WEBHOOK_INVALIDATION_FAILED=1
			_webhook_record_missed_recovery
			_whlog ERROR "Failed collection invalidation; polling recovery remains active"
		else
			_webhook_record_invalidation_evidence
		fi
		return 0
		;;
	"INVALIDATE v1 checks")
		_WEBHOOK_INVALIDATION_FAILED=0
		if [[ -n "$extra" ]]; then
			_WEBHOOK_INVALIDATION_FAILED=1
			_whlog ERROR "Rejected malformed check invalidation record"
		elif ! _webhook_invalidate_checks "$first" "$second"; then
			_WEBHOOK_INVALIDATION_FAILED=1
			_webhook_record_missed_recovery
			_whlog ERROR "Failed check invalidation; polling recovery remains active"
		else
			_webhook_record_invalidation_evidence
		fi
		return 0
		;;
	esac
	if [[ "$verb" == "PROCESS_PR" && -n "$version" && -n "$scope" \
		&& -z "$first" && -z "$second" && -z "$extra" ]]; then
		local slug="$version"
		local pr_number="$scope"
		if ! _webhook_valid_slug "$slug" \
			|| [[ ! "$pr_number" =~ ^[0-9]+$ || "$pr_number" -le 0 ]]; then
			_whlog WARN "Malformed PROCESS_PR action"
			return 0
		fi
		if [[ "$_WEBHOOK_INVALIDATION_FAILED" == "1" ]]; then
			_whlog WARN "Skipped process_pr because canonical invalidation failed; polling remains active"
			return 0
		fi
		_whlog INFO "Dispatching process_pr ${slug}#${pr_number}"
		(
			set +e
			process_pr "$slug" "$pr_number"
			_whlog INFO "process_pr ${slug}#${pr_number} returned ${?}"
		) &
		_webhook_wait_for_dispatch_slot
		return 0
	fi
	if [[ "$verb" == "INVALIDATE" || "$verb" == "DELIVERY" ]]; then
		_WEBHOOK_INVALIDATION_FAILED=1
	fi
	_whlog WARN "Unknown line from server"
	return 0
}

# =============================================================================
# Subcommand: --check (config + secret validation, no listener)
# =============================================================================

cmd_check() {
	local errors=0
	printf 'webhook-receiver config: %s\n' "$WEBHOOK_CONF"
	printf '  listen:  %s:%s\n' "${WEBHOOK_LISTEN_HOST:-127.0.0.1}" "${WEBHOOK_LISTEN_PORT:-9301}"
	printf '  events:  %s\n' "${WEBHOOK_HANDLED_EVENTS}"
	printf '  protocol: %s\n' "$WEBHOOK_ACTION_PROTOCOL_VERSION"
	printf '  log:     %s\n' "$WEBHOOK_LOG_FILE"
	printf '  ledger:  %s (ttl=%ss, max=%s)\n' \
		"$WEBHOOK_DELIVERY_LEDGER_FILE" "$WEBHOOK_DELIVERY_TTL_SECONDS" "$WEBHOOK_DELIVERY_MAX_ENTRIES"
	case "${WEBHOOK_LISTEN_HOST:-127.0.0.1}" in
	127.0.0.1 | ::1) ;;
	*)
		printf '  listen:  INVALID — loopback host required\n' >&2
		errors=$((errors + 1))
		;;
	esac
	if [[ "$WEBHOOK_ACTION_PROTOCOL_VERSION" != "v1" ]]; then
		printf '  protocol: INVALID — expected v1\n' >&2
		errors=$((errors + 1))
	fi
	local numeric_value=""
	for numeric_value in \
		"${WEBHOOK_LISTEN_PORT:-9301}" \
		"${WEBHOOK_MAX_BODY_BYTES:-1048576}" \
		"$WEBHOOK_DELIVERY_TTL_SECONDS" \
		"$WEBHOOK_DELIVERY_MAX_ENTRIES" \
		"$WEBHOOK_DISPATCH_MAX_CONCURRENCY"; do
		if ! _webhook_positive_integer "$numeric_value"; then
			printf '  numeric config: INVALID (%s)\n' "$numeric_value" >&2
			errors=$((errors + 1))
		fi
	done

	local secret
	secret=$(_resolve_secret)
	if [[ -n "$secret" ]]; then
		printf '  secret:  set (%s, %d chars)\n' "${WEBHOOK_SECRET_ENV}" "${#secret}"
	else
		printf '  secret:  MISSING — set with: aidevops secret set %s\n' "${WEBHOOK_SECRET_ENV}" >&2
		errors=$((errors + 1))
	fi

	if ! command -v python3 >/dev/null 2>&1; then
		printf '  python3: MISSING — required for HTTP server\n' >&2
		errors=$((errors + 1))
	else
		printf '  python3: %s\n' "$(command -v python3)"
	fi

	if [[ "$errors" -gt 0 ]]; then
		printf 'webhook-receiver: %d configuration error(s)\n' "$errors" >&2
		return 1
	fi
	printf 'webhook-receiver: OK\n'
	return 0
}

# =============================================================================
# Subcommand: run (start listener)
# =============================================================================

cmd_run() {
	local secret
	if [[ "$WEBHOOK_ACTION_PROTOCOL_VERSION" != "v1" ]]; then
		printf 'webhook-receiver: unsupported action protocol %s\n' "$WEBHOOK_ACTION_PROTOCOL_VERSION" >&2
		return 1
	fi
	secret=$(_resolve_secret)
	if [[ -z "$secret" ]]; then
		_whlog ERROR "Cannot start: webhook secret env var ${WEBHOOK_SECRET_ENV} not set"
		printf 'webhook-receiver: secret %s not set; refusing to start\n' "${WEBHOOK_SECRET_ENV}" >&2
		return 1
	fi
	_clear_webhook_secret_env || return 1

	# Make config available to the Python child via env vars (avoid arg leakage).
	export WEBHOOK_LISTEN_HOST="${WEBHOOK_LISTEN_HOST:-127.0.0.1}"
	export WEBHOOK_LISTEN_PORT="${WEBHOOK_LISTEN_PORT:-9301}"
	export WEBHOOK_HANDLED_EVENTS
	export WEBHOOK_MAX_BODY_BYTES="${WEBHOOK_MAX_BODY_BYTES:-1048576}"
	export WEBHOOK_LOG_FILE WEBHOOK_DELIVERY_LEDGER_FILE
	export WEBHOOK_DELIVERY_TTL_SECONDS WEBHOOK_DELIVERY_MAX_ENTRIES
	export WEBHOOK_ACTION_PROTOCOL_VERSION

	_whlog INFO "Starting receiver on ${WEBHOOK_LISTEN_HOST}:${WEBHOOK_LISTEN_PORT} (events=${WEBHOOK_HANDLED_EVENTS})"

	# Source pulse-merge.sh + dependencies inside this shell so process_pr is
	# callable from the dispatch loop below. We mirror pulse-merge-routine.sh.
	# shellcheck source=/dev/null
	source "${SCRIPT_DIR}/shared-constants.sh"
	# shellcheck source=/dev/null
	source "${SCRIPT_DIR}/gh-api-instrument.sh"
	# shellcheck source=/dev/null
	source "${SCRIPT_DIR}/shared-gh-wrappers-checks.sh"
	# shellcheck source=/dev/null
	source "${SCRIPT_DIR}/config-helper.sh" 2>/dev/null || true
	# shellcheck source=/dev/null
	source "${SCRIPT_DIR}/worker-lifecycle-common.sh"
	# shellcheck source=/dev/null
	source "${SCRIPT_DIR}/pulse-wrapper-config.sh"
	# shellcheck source=/dev/null
	source "${SCRIPT_DIR}/pulse-repo-meta.sh"
	# shellcheck source=/dev/null
	source "${SCRIPT_DIR}/pulse-merge.sh"
	# shellcheck source=/dev/null
	source "${SCRIPT_DIR}/pulse-merge-conflict.sh"
	# shellcheck source=/dev/null
	source "${SCRIPT_DIR}/pulse-merge-feedback.sh"

	# Invalidation records are emitted before PROCESS_PR lines for each delivery.
	# The secret is scoped only to the Python server process.
	while IFS= read -r line; do
		_dispatch_webhook_action_line "$line"
	done < <(_PULSE_WEBHOOK_SECRET="$secret" python3 -u "${SCRIPT_DIR}/pulse-merge-webhook-server.py")

	_whlog WARN "Server stdout loop exited"
	wait
	return 0
}

# =============================================================================
# Subcommand: --__server (internal, runs the python HTTP server)
# =============================================================================
# Logic lives in pulse-merge-webhook-server.py to keep this shell function
# under the function-complexity gate. Stdout = ACTION protocol.

cmd_server() {
	exec python3 -u "${SCRIPT_DIR}/pulse-merge-webhook-server.py"
}

# =============================================================================
# Help
# =============================================================================

cmd_help() {
	cat <<EOF
pulse-merge-webhook-receiver.sh — GitHub webhook → process_pr (t3038)

Usage:
  pulse-merge-webhook-receiver.sh [run]    Start the listener (default)
  pulse-merge-webhook-receiver.sh --check  Validate config + secret, no listener
  pulse-merge-webhook-receiver.sh help     Show this help

Configuration:
  ${WEBHOOK_CONF}

Secret:
  Stored in env var named by WEBHOOK_SECRET_ENV (currently: ${WEBHOOK_SECRET_ENV:-GITHUB_WEBHOOK_SECRET}).
  Set with: aidevops secret set ${WEBHOOK_SECRET_ENV:-GITHUB_WEBHOOK_SECRET}
  Or in ~/.config/aidevops/credentials.sh (mode 600).

Events handled:
  - Issue and issue-comment mutations invalidate the issue or PR collection.
  - Pull-request and review mutations invalidate the PR collection.
  - Check-run, check-suite, status, and workflow changes invalidate an exact SHA.
  - Eligible successful checks, approvals, and merge labels may also call process_pr.

Backstop:
  pulse-merge-routine.sh's 120s polling loop continues to run regardless
  of receiver state. If the receiver is offline, eligible PRs still
  merge on the next polling cycle — webhook-driven merges are an
  optimization, not a replacement.

GitHub-side setup:
  Expose this listener via Cloudflare Tunnel (HTTPS termination), then
  configure the repo webhook with:
    - Payload URL: https://<your-tunnel>/webhook
    - Content type: application/json
    - Secret: same value as the env var above
    - Events: ${WEBHOOK_HANDLED_EVENTS}

Logs:
  ${WEBHOOK_LOG_FILE}
EOF
	return 0
}

# =============================================================================
# Entry point
# =============================================================================

main() {
	local cmd="${1:-run}"
	case "$cmd" in
	run | --run | "")
		cmd_run
		;;
	--check | check)
		cmd_check
		;;
	--__server)
		# Internal diagnostic entry point for the Python server.
		cmd_server
		;;
	help | -h | --help)
		cmd_help
		;;
	*)
		printf 'Unknown command: %s\n' "$cmd" >&2
		cmd_help >&2
		return 2
		;;
	esac
	return 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	main "$@"
	exit $?
fi

#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# sandbox-exec-helper.sh — Lightweight execution sandbox for tool/command isolation
# Commands: run | audit | config | help
#
# Wraps command execution with environment clearing, timeout enforcement,
# temp directory isolation, optional network restriction, and network tiering.
# Inspired by OpenFang's WASM sandbox — adapted for shell-native use.
#
# Network tiering (t1412.3): recognized direct network clients have target
# domains classified into tiers (1-5). Tier 5 and direct DNS-exfiltration
# commands are blocked before execution. Tier 4 domains are allowed but flagged.
# Arbitrary interpreter scripts/custom binaries require a lower-layer egress
# backend; command classification is not whole-process network containment.
# See network-tier-helper.sh for the full tier model.
#
# Usage:
#   sandbox-exec-helper.sh run command [args...]
#   sandbox-exec-helper.sh run --timeout 60 --no-network curl example.com
#   sandbox-exec-helper.sh run --network-tiering --worker-id w123 curl example.com
#   sandbox-exec-helper.sh run --allow-secret-io gopass show path  # explicit override
#   sandbox-exec-helper.sh run --passthrough "GITHUB_TOKEN,NPM_TOKEN" npm publish
#   sandbox-exec-helper.sh audit [--last N]
#   sandbox-exec-helper.sh config --show
#   sandbox-exec-helper.sh help
#
# Note: command and its arguments are passed as separate shell words (not a
# single quoted string). This avoids bash -c eval and correctly handles
# arguments containing spaces.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
# shellcheck source=shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh"
set -euo pipefail

LOG_PREFIX="SANDBOX"

# =============================================================================
# Constants
# =============================================================================

readonly SANDBOX_DIR="${HOME}/.aidevops/.agent-workspace/sandbox"
readonly SANDBOX_LOG="${SANDBOX_DIR}/executions.jsonl"
readonly SANDBOX_TMP_BASE="${SANDBOX_DIR}/tmp"
readonly SANDBOX_DEFAULT_TIMEOUT=120
readonly SANDBOX_MAX_TIMEOUT=21600
readonly SANDBOX_MAX_OUTPUT_BYTES=10485760 # 10MB per stream
readonly SECRET_IO_GUARD_DEFAULT="true"
readonly SANDBOX_ERROR_LEVEL="ERROR"

# Minimal environment passthrough — only what's needed for basic operation
readonly DEFAULT_PASSTHROUGH="PATH HOME USER LANG TERM SHELL"

# Runtime-neutral shell-command policy helper
readonly COMMAND_POLICY_HELPER="${AIDEVOPS_COMMAND_POLICY_HELPER:-${SCRIPT_DIR}/command-policy-helper.py}"
readonly NETWORK_TIER_HELPER="${AIDEVOPS_NETWORK_TIER_HELPER:-${SCRIPT_DIR}/network-tier-helper.sh}"

# =============================================================================
# Helpers
# =============================================================================

log_sandbox() {
	local level="$1"
	local msg="$2"
	printf '[%s] [%s] [%s] %s\n' \
		"$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$LOG_PREFIX" "$level" "$msg" >&2
	return 0
}

# Log execution to JSONL audit trail
log_execution() {
	local command="$1"
	local exit_code="$2"
	local duration="$3"
	local timeout_used="$4"
	local network_blocked="${5:-false}"
	local passthrough_vars="${6:-}"
	local egress_state="${7:-not-evaluated}"
	local egress_backend="${8:-none}"
	local timestamp
	timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

	mkdir -p "$(dirname "$SANDBOX_LOG")"

	# Truncate command for logging (no secrets, max 500 chars)
	local logged_cmd="${command:0:500}"

	# Use jq to safely generate the JSON log entry — prevents JSON/log injection
	# via backslashes, newlines, or other special characters in the command string.
	local log_entry
	log_entry=$(jq -n \
		--arg ts "$timestamp" \
		--arg cmd "$logged_cmd" \
		--argjson exit "$exit_code" \
		--argjson duration "$duration" \
		--argjson timeout "$timeout_used" \
		--argjson network_blocked "$network_blocked" \
		--arg passthrough "$passthrough_vars" \
		--arg egress_state "$egress_state" \
		--arg egress_backend "$egress_backend" \
		'{ts: $ts, cmd: $cmd, exit: $exit, duration_s: $duration, timeout: $timeout, network_blocked: $network_blocked, passthrough: $passthrough, egress_state: $egress_state, egress_backend: $egress_backend}')

	printf '%s\n' "$log_entry" >>"$SANDBOX_LOG"
	return 0
}

# Detect high-risk commands that could expose secret values in transcript output.
# Returns 0 and prints a reason when command should be blocked.
# Returns 1 when command appears safe.
_sandbox_secret_block_reason() {
	local command="$1"
	local normalized
	normalized="$(printf '%s' "$command" | tr '[:upper:]' '[:lower:]')"

	if [[ "$normalized" =~ (^|[[:space:];|&])(gopass|pass)[[:space:]]+(show|cat)([[:space:]]|$) ]]; then
		echo "password manager value read command"
		return 0
	fi

	if [[ "$normalized" =~ (^|[[:space:];|&])op[[:space:]]+read([[:space:]]|$) ]]; then
		echo "1Password secret read command"
		return 0
	fi

	if [[ "$normalized" =~ (^|[[:space:];|&])(cat|less|more|tail|head|sed|awk)[[:space:]].*(^|[[:space:]/])((id_(rsa|dsa|ecdsa|ed25519))|\.env([^[:space:]]*)?|credentials\.(sh|json|ya?ml)|[^[:space:]]*secret[^[:space:]]*|[^[:space:]]*password[^[:space:]]*|[^[:space:]]*passwd[^[:space:]]*|[^[:space:]]*\.(pem|key|p12|pfx|kdbx|age|asc|gpg))($|[[:space:];|&]) ]]; then
		echo "file read command targeting likely secret material"
		return 0
	fi

	if [[ "$normalized" =~ (^|[[:space:];|&])(cat|less|more|tail|head|sed|awk)[[:space:]].*(^|[[:space:]/])(\.ssh|\.gnupg|\.aws|\.azure|\.kube|password-store|1password|op-vault)(/|[[:space:];|&]) ]] && [[ ! "$normalized" =~ \.pub($|[[:space:];|&]) ]]; then
		echo "file read command targeting credential-store path"
		return 0
	fi

	if [[ "$normalized" =~ (^|[[:space:];|&])(echo|printenv)[[:space:]]+\$?[a-z_][a-z0-9_]*(secret|token|key|password|passwd|pwd|credential|client_secret|access_token)([[:space:];|&]|$) ]]; then
		echo "environment variable value print command"
		return 0
	fi

	if [[ "$normalized" =~ (^|[[:space:];|&])env[[:space:]]*\|[[:space:]]*(grep|rg)([[:space:];|&]|$) ]]; then
		echo "environment dump piped to search command"
		return 0
	fi

	if [[ "$normalized" =~ (^|[[:space:];|&])kubectl[[:space:]]+get[[:space:]]+secret([[:space:]]|$) ]]; then
		echo "kubernetes secret read command"
		return 0
	fi

	if [[ "$normalized" =~ (^|[[:space:];|&])docker[[:space:]]+inspect([[:space:]]|$) ]] || [[ "$normalized" =~ (^|[[:space:];|&])docker[[:space:]]+exec[[:space:]].*[[:space:]]env([[:space:];|&]|$) ]]; then
		echo "docker environment inspection command"
		return 0
	fi

	if [[ "$normalized" =~ (^|[[:space:];|&])pm2[[:space:]]+env([[:space:]]|$) ]]; then
		echo "pm2 environment dump command"
		return 0
	fi

	return 1
}

# Determine whether command/output should be treated as secret-tainted.
# Tainted commands get stronger output handling (warning + redaction).
_sandbox_is_secret_tainted_command() {
	local command="$1"
	local normalized
	normalized="$(printf '%s' "$command" | tr '[:upper:]' '[:lower:]')"

	if _sandbox_secret_block_reason "$command" >/dev/null 2>&1; then
		return 0
	fi

	if [[ "$normalized" =~ oauth/access_token|client_secret|access_token|refresh_token|authorization:[[:space:]]*bearer ]]; then
		return 0
	fi

	return 1
}

# Apply Python-based secret redaction to a file, writing result to stdout.
# Arguments: $1=file path
# Caller is responsible for redirecting stdout to stderr if needed.
_sandbox_redact_with_python() {
	local input_file="$1"
	python3 - "$input_file" <<'PY'
import os
import re
import sys

path = sys.argv[1]
try:
    text = open(path, "r", encoding="utf-8", errors="replace").read()
except Exception:
    sys.exit(0)

candidate_values = []
for key, value in os.environ.items():
    upper = key.upper()
    if any(token in upper for token in ["SECRET", "TOKEN", "PASSWORD", "API_KEY", "ACCESS_KEY", "PRIVATE_KEY", "CLIENT_SECRET", "AUTH"]):
        if value and len(value) >= 8:
            candidate_values.append(value)

for value in sorted(set(candidate_values), key=len, reverse=True):
    text = text.replace(value, "[REDACTED_SECRET]")

patterns = [
    (re.compile(r'(?i)(authorization\s*:\s*bearer\s+)([A-Za-z0-9._~+/=-]+)'), r'\1[REDACTED_SECRET]'),
    (re.compile(r'(?i)(access_token|refresh_token|client_secret|api[_-]?key|password|token|secret)(\s*[:=]\s*)("?[^"\s,}]+"?)'), r'\1\2"[REDACTED_SECRET]"'),
]

for pattern, repl in patterns:
    text = pattern.sub(repl, text)

sys.stdout.write(text)
PY
	return 0
}

# Redact likely secret values from a captured output file.
# Arguments: $1=file path, $2=stream name (stdout|stderr), $3=tainted_flag
_sandbox_emit_redacted_output() {
	local output_file="$1"
	local stream_name="$2"
	local tainted_flag="$3"

	if [[ ! -f "$output_file" ]] || [[ ! -s "$output_file" ]]; then
		return 0
	fi

	local truncated_file
	truncated_file="$(mktemp)"
	head -c "$SANDBOX_MAX_OUTPUT_BYTES" "$output_file" >"$truncated_file"

	if [[ "$tainted_flag" == "true" ]]; then
		local warning_msg="[sandbox] WARNING: secret-tainted command detected — output is redacted"
		if [[ "$stream_name" == "stderr" ]]; then
			printf '%s\n' "$warning_msg" >&2
		else
			printf '%s\n' "$warning_msg"
		fi
	fi

	if command -v python3 >/dev/null 2>&1; then
		if [[ "$stream_name" == "stderr" ]]; then
			_sandbox_redact_with_python "$truncated_file" >&2
		else
			_sandbox_redact_with_python "$truncated_file"
		fi
	else
		if [[ "$stream_name" == "stderr" ]]; then
			cat "$truncated_file" >&2
		else
			cat "$truncated_file"
		fi
	fi

	rm -f "$truncated_file"
	return 0
}

# Enforce the shared runtime-neutral command safety floor.
# Arguments:
#   $1 - exact argv JSON array
#   $2 - worker ID
_sandbox_check_command_policy() {
	local argv_json="$1"
	local worker_id="$2"
	local result=""
	local status=0
	local decision=""
	local rule_id=""
	local reason=""

	if [[ ! -f "$COMMAND_POLICY_HELPER" ]]; then
		log_sandbox "$SANDBOX_ERROR_LEVEL" "Required command policy helper is unavailable: ${COMMAND_POLICY_HELPER}"
		return 1
	fi
	result="$(python3 "$COMMAND_POLICY_HELPER" check-command --worker --worker-id "$worker_id" --cwd "$PWD" --argv-json "$argv_json")" || status=$?
	decision="$(printf '%s' "$result" | jq -r '.decision // empty' 2>/dev/null)" || decision=""
	rule_id="$(printf '%s' "$result" | jq -r '.rule_id // "policy.invalid-response"' 2>/dev/null)" || rule_id="policy.invalid-response"
	reason="$(printf '%s' "$result" | jq -r '.reason // "command policy returned an invalid response"' 2>/dev/null)" || reason="command policy returned an invalid response"
	if [[ "$status" -eq 0 && "$decision" == "allow" ]]; then
		return 0
	fi
	log_sandbox "$SANDBOX_ERROR_LEVEL" "Command policy denied execution (${decision:-forbid}, ${rule_id}): ${reason}"
	return 1
}

# Serialize exact argv without shell joining or delimiter ambiguity.
_sandbox_argv_json() {
	python3 - "$@" <<'PY'
import json
import sys

print(json.dumps(sys.argv[1:]))
PY
	return 0
}

# Produce a display-only, shell-escaped command string for logs and legacy
# secret-output heuristics. It is never used for policy decisions or execution.
_sandbox_argv_display() {
	python3 - "$@" <<'PY'
import shlex
import sys

print(" ".join(shlex.quote(arg) for arg in sys.argv[1:]))
PY
	return 0
}

# Produce heuristic-only text for legacy secret-output pattern matching. This
# never feeds policy decisions or command execution; exact argv remains the
# authority for both.
_sandbox_argv_heuristic_text() {
	python3 - "$@" <<'PY'
import sys

print(" ".join(sys.argv[1:]))
PY
	return 0
}

# =============================================================================
# Sandbox Execution
# =============================================================================

# Record descendant identities while the original parent still owns them.
# Entries are append-only because a detached descendant may be reparented before
# the next sample. Cleanup revalidates every PID against its start token.
# Arguments: $1 - root PID, $2 - snapshot file
_sandbox_snapshot_descendants() {
	local snapshot_root_pid="${1:-}"
	local snapshot_file="${2:-}"
	local snapshot_rows=""
	local snapshot_wanted=" ${snapshot_root_pid} "
	local snapshot_changed=true
	local snapshot_pid=""
	local snapshot_ppid=""
	local snapshot_pgid=""
	local snapshot_token=""

	[[ "$snapshot_root_pid" =~ ^[0-9]+$ && -n "$snapshot_file" ]] || return 0
	snapshot_rows="$(ps -axo pid=,ppid=,pgid= 2>/dev/null)" || return 0
	while [[ "$snapshot_changed" == true ]]; do
		snapshot_changed=false
		while read -r snapshot_pid snapshot_ppid snapshot_pgid; do
			[[ "$snapshot_pid" =~ ^[0-9]+$ && "$snapshot_ppid" =~ ^[0-9]+$ ]] || continue
			case "$snapshot_wanted" in
			*" ${snapshot_ppid} "*)
				case "$snapshot_wanted" in
				*" ${snapshot_pid} "*) ;;
				*)
					snapshot_wanted="${snapshot_wanted}${snapshot_pid} "
					snapshot_changed=true
					;;
				esac
				;;
			esac
		done <<<"$snapshot_rows"
	done

	while read -r snapshot_pid snapshot_ppid snapshot_pgid; do
		[[ "$snapshot_pid" =~ ^[0-9]+$ && "$snapshot_pid" != "$snapshot_root_pid" ]] || continue
		case "$snapshot_wanted" in
		*" ${snapshot_pid} "*)
			snapshot_token="$(_sandbox_get_proc_starttime "$snapshot_pid")"
			[[ -n "$snapshot_token" ]] && printf '%s\t%s\t%s\n' "$snapshot_pid" "$snapshot_pgid" "$snapshot_token" >>"$snapshot_file"
			;;
		esac
	done <<<"$snapshot_rows"
	return 0
}

_sandbox_snapshot_identity_matches() {
	local identity_pid="${1:-}"
	local identity_pgid="${2:-}"
	local identity_token="${3:-}"
	local identity_current_pgid=""
	local identity_current_token=""
	local identity_stat_content=""
	local identity_after_comm=""
	local -a identity_fields=()

	[[ "$identity_pid" =~ ^[0-9]+$ && -n "$identity_token" ]] || return 1
	if [[ -f "/proc/${identity_pid}/stat" ]]; then
		IFS= read -r identity_stat_content <"/proc/${identity_pid}/stat" || return 1
		identity_after_comm="${identity_stat_content##*) }"
		read -r -a identity_fields <<<"$identity_after_comm"
		[[ "${identity_fields[2]:-}" == "$identity_pgid" && "${identity_fields[19]:-}" == "$identity_token" ]] || return 1
	else
		identity_current_token="$(_sandbox_get_proc_starttime "$identity_pid")"
		[[ -n "$identity_current_token" && "$identity_current_token" == "$identity_token" ]] || return 1
		identity_current_pgid="$(ps -o pgid= -p "$identity_pid" 2>/dev/null | tr -d '[:space:]')" || return 1
		[[ -n "$identity_current_pgid" && "$identity_current_pgid" == "$identity_pgid" ]] || return 1
	fi
	return 0
}

# Kill a child process group, verified detached descendants, and its watchdog.
# Standalone cleanup function — called explicitly on all exit paths and
# as an EXIT trap safety net. Takes explicit arguments instead of relying
# on closure variables (extracted from nested _pgkill_cleanup in GH#6429).
#
# Arguments:
#   $1 - watchdog_pid (may be empty)
#   $2 - child_pgid (may be empty)
#   $3 - child_pid (may be empty)
#   $4 - descendant identity snapshot file (may be empty)
_sandbox_pgkill_cleanup() {
	local cleanup_watchdog_pid="$1"
	local cleanup_child_pgid="$2"
	local cleanup_child_pid="$3"
	local cleanup_snapshot_file="${4:-}"

	# Kill the secondary watchdog first to prevent it from firing
	# after we've already cleaned up the child.
	if [[ -n "$cleanup_watchdog_pid" ]]; then
		kill "$cleanup_watchdog_pid" 2>/dev/null || true
		local cleanup_wait_start cleanup_wait_elapsed
		cleanup_wait_start=$(date +%s)
		while kill -0 "$cleanup_watchdog_pid" 2>/dev/null; do
			cleanup_wait_elapsed=$(( $(date +%s) - cleanup_wait_start ))
			if [[ "$cleanup_wait_elapsed" -ge 5 ]]; then
				kill -9 "$cleanup_watchdog_pid" 2>/dev/null || true
				break
			fi
			sleep 1
		done
		wait "$cleanup_watchdog_pid" 2>/dev/null || true
	fi

	local cleanup_self_pgid=""
	cleanup_self_pgid="$(ps -o pgid= -p "$$" 2>/dev/null | tr -d '[:space:]')" || true
	if [[ -n "$cleanup_child_pgid" && -n "$cleanup_self_pgid" && "$cleanup_child_pgid" == "$cleanup_self_pgid" ]]; then
		cleanup_child_pgid=""
	fi

	if [[ -n "$cleanup_child_pgid" ]]; then
		local cleanup_group_target="-${cleanup_child_pgid}"
		# SIGTERM first — allow graceful shutdown
		kill -- "$cleanup_group_target" 2>/dev/null || true
		# Brief grace period, then SIGKILL any survivors
		sleep 0.5
		kill -0 -- "$cleanup_group_target" 2>/dev/null &&
			kill -9 -- "$cleanup_group_target" 2>/dev/null || true
	elif [[ -n "$cleanup_child_pid" ]]; then
		# Fallback: setsid unavailable — kill direct child process only
		kill "$cleanup_child_pid" 2>/dev/null || true
		sleep 0.5
		kill -0 "$cleanup_child_pid" 2>/dev/null &&
			kill -9 "$cleanup_child_pid" 2>/dev/null || true
	fi

	# Descendants may have escaped the original PGID with setsid/setpgid. Only
	# signal entries whose PID, PGID, and start token still match the snapshot.
	if [[ -n "$cleanup_snapshot_file" && -f "$cleanup_snapshot_file" ]]; then
		local cleanup_pid=""
		local cleanup_pgid=""
		local cleanup_token=""
		local cleanup_index=0
		local -a cleanup_pids=()
		local -a cleanup_pgids=()
		local -a cleanup_tokens=()
		while IFS=$'\t' read -r cleanup_pid cleanup_pgid cleanup_token; do
			[[ -n "$cleanup_pid" ]] || continue
			cleanup_pids+=("$cleanup_pid")
			cleanup_pgids+=("$cleanup_pgid")
			cleanup_tokens+=("$cleanup_token")
			_sandbox_snapshot_identity_matches "$cleanup_pid" "$cleanup_pgid" "$cleanup_token" || continue
			# A group signal is safe only when its verified leader was descended
			# from the sandbox and our own PGID is known. Otherwise terminate the
			# verified PID individually to prevent a defensive self-kill.
			if [[ "$cleanup_pid" == "$cleanup_pgid" && -n "$cleanup_self_pgid" && "$cleanup_pgid" != "$cleanup_self_pgid" ]]; then
				kill -TERM -- "-${cleanup_pgid}" 2>/dev/null || true
			else
				kill -TERM "$cleanup_pid" 2>/dev/null || true
			fi
		done <"$cleanup_snapshot_file"
		# Consume the snapshot before the grace period. A concurrent/repeated
		# cleanup cannot act on stale identities while PIDs are being recycled.
		rm -f "$cleanup_snapshot_file" 2>/dev/null || true
		cleanup_snapshot_file=""
		sleep 0.5
		for ((cleanup_index = 0; cleanup_index < ${#cleanup_pids[@]}; cleanup_index++)); do
			cleanup_pid="${cleanup_pids[$cleanup_index]}"
			cleanup_pgid="${cleanup_pgids[$cleanup_index]}"
			cleanup_token="${cleanup_tokens[$cleanup_index]}"
			_sandbox_snapshot_identity_matches "$cleanup_pid" "$cleanup_pgid" "$cleanup_token" || continue
			if [[ "$cleanup_pid" == "$cleanup_pgid" && -n "$cleanup_self_pgid" && "$cleanup_pgid" != "$cleanup_self_pgid" ]]; then
				kill -KILL -- "-${cleanup_pgid}" 2>/dev/null || true
			else
				kill -KILL "$cleanup_pid" 2>/dev/null || true
			fi
		done
	fi
	return 0
}

# Start a command in a new process group via setsid.
# Sets caller-scoped variables: child_pid, child_pgid, child_start_token
# (uses bash dynamic scoping — caller must declare these as local).
#
# Arguments: stdout_file stderr_file cmd [args...]
# Fallback: if setsid is unavailable, runs directly and leaves child_pgid
# empty so _sandbox_pgkill_cleanup falls back to killing child_pid.
_sandbox_spawn_child() {
	local sc_stdout_file="$1"
	local sc_stderr_file="$2"
	shift 2

	# setsid creates a new session (and process group) so the child and all
	# its descendants share a PGID distinct from the wrapper's PGID.
	# stdout/stderr are redirected here so the redirection applies to the
	# backgrounded child process, not to the polling loop.
	#
	# --stream-stdout mode (GH#15180 bug #4): when stream_stdout=true (set
	# by sandbox_run via dynamic scoping), stdout is NOT redirected to the
	# capture file. Instead it flows to the caller's stdout (e.g., through
	# a pipe to tee in headless-runtime-helper.sh) so external watchdogs
	# can monitor activity in real-time. Stderr is still captured. The
	# capture file remains empty; _sandbox_emit_redacted_output handles
	# this gracefully (returns early on empty/missing files).
	if command -v setsid &>/dev/null; then
		if [[ "${stream_stdout:-false}" == "true" ]]; then
			if [[ "${private_output:-false}" == "true" ]]; then
				setsid "$@" 2>&1 &
			else
				setsid "$@" 2>"$sc_stderr_file" &
			fi
		else
			setsid "$@" >"$sc_stdout_file" 2>"$sc_stderr_file" &
		fi
		child_pid=$!
		# Retrieve the process group ID of the child.
		# On Linux: ps -o pgid= returns the PGID. On macOS: same flag works.
		# If ps fails (race: child already exited), clear pgid to fall back
		# to killing child_pid directly in _sandbox_pgkill_cleanup.
		child_pgid="$(ps -o pgid= -p "$child_pid" 2>/dev/null | tr -d ' ')" || true
		if [[ -z "$child_pgid" ]] || [[ "$child_pgid" == "0" ]]; then
			child_pgid=""
		fi
	else
		if [[ "${stream_stdout:-false}" == "true" ]]; then
			if [[ "${private_output:-false}" == "true" ]]; then
				"$@" 2>&1 &
			else
				"$@" 2>"$sc_stderr_file" &
			fi
		else
			"$@" >"$sc_stdout_file" 2>"$sc_stderr_file" &
		fi
		child_pid=$!
		# setsid not available — child shares the script's process group.
		# Do NOT read the PGID here: ps would return the script's own PGID,
		# causing _sandbox_pgkill_cleanup to kill the wrapper itself.
		child_pgid=""
	fi

	# PID recycling safety: capture a stable identity token at spawn time.
	# On Linux, use /proc/<pid>/stat field 22 (starttime in clock ticks since
	# boot). On macOS/other, use 'ps -o lstart=' for absolute start timestamp.
	# If the lookup fails (child already exited), token is empty — the watchdog
	# will skip signal delivery (safe: child already gone).
	child_start_token="$(_sandbox_get_proc_starttime "$child_pid")"
	return 0
}

# Poll until a child process exits or the timeout deadline is reached.
# Returns 0 if the child exited on its own, 124 if the timeout was reached.
#
# Arguments:
#   $1 - timeout in seconds
#   $2 - child_pid to monitor
#   $3 - descendant identity snapshot file
_sandbox_poll_child() {
	local poll_timeout="$1"
	local poll_child_pid="$2"
	local poll_snapshot_file="$3"
	local half_secs_remaining=$((poll_timeout * 2))
	local poll_state=""

	while kill -0 "$poll_child_pid" 2>/dev/null; do
		_sandbox_snapshot_descendants "$poll_child_pid" "$poll_snapshot_file"
		poll_state="$(ps -o stat= -p "$poll_child_pid" 2>/dev/null | tr -d '[:space:]')" || true
		if [[ "$poll_state" == *Z* ]]; then
			return 0
		fi
		if ((half_secs_remaining <= 0)); then
			return 124
		fi
		sleep 0.5
		((half_secs_remaining--)) || true
	done
	return 0
}

# Runs cmd in a new process group (via setsid) and kills the entire group
# when the timeout expires or the function exits. This ensures that worker
# child processes (MCP servers, node workers, etc.) are also terminated —
# a plain `timeout` only kills its direct child (GH#5530).
#
# Arguments: t_secs stdout_file stderr_file cmd [args...]
# stdout/stderr are passed as file paths (not via shell redirection on the
# function call) so the redirection applies to the backgrounded child, not
# to the polling loop in this function.
#
# Process group lifecycle (GH#5530):
# The worker process spawns its own child processes. A plain `timeout` only
# kills its direct child — grandchildren survive indefinitely. Fix: run the
# command in a new process group via `setsid`, then kill the entire group
# (kill -- -PGID) on timeout or exit. Cleanup is called explicitly on all
# exit paths — the EXIT trap is a safety net for unexpected exits only.
#
# Secondary watchdog (GH#6413):
# The primary polling loop uses sleep 0.5 + counter decrement. If the parent
# process crashes, gets OOM-killed, or the sleep drifts, the child (in its
# own session via setsid) survives indefinitely. Fix: spawn a background
# watchdog process that independently tracks wall-clock time via date(1) and
# kills the child process group if the deadline is exceeded. The watchdog is
# killed on normal exit to avoid orphaned watchers.
_sandbox_exec_with_pgkill() {
	local t_secs="$1"
	local t_stdout_file="$2"
	local t_stderr_file="$3"
	shift 3
	local child_pid=""
	local child_pgid=""
	local child_start_token=""
	local t_exit_code=0
	local watchdog_pid=""
	local descendant_snapshot_file="${t_stderr_file}.descendants"
	: >"$descendant_snapshot_file"

	# EXIT trap uses a closure-style wrapper to pass current variable values
	# to the standalone cleanup function.
	trap '_sandbox_pgkill_cleanup "$watchdog_pid" "$child_pgid" "$child_pid" "$descendant_snapshot_file"' EXIT

	# Spawn the child in a new process group (sets child_pid, child_pgid,
	# child_start_token via dynamic scoping).
	_sandbox_spawn_child "$t_stdout_file" "$t_stderr_file" "$@"
	_sandbox_snapshot_descendants "$child_pid" "$descendant_snapshot_file"

	# Marker file for watchdog-initiated kills (GH#6414, CodeRabbit review).
	# Derived from t_stderr_file path to avoid collisions across concurrent
	# sandbox invocations (unlike a global /tmp/ path with PID suffix).
	local t_watchdog_marker="${t_stderr_file}.watchdog_timeout"

	# Secondary watchdog (GH#6413): independent wall-clock timeout enforcement.
	# 10% grace period avoids racing with the primary loop's normal timeout.
	# GH#6538: use _sandbox_spawn_watchdog_bg so the watchdog process appears
	# as "bash -c ... sandbox-watchdog" in ps, not as "sandbox-exec-helper.sh
	# run ... opencode run ... /full-loop ..." — preventing it from being
	# counted as a duplicate active worker by list_active_worker_processes().
	_sandbox_spawn_watchdog_bg "$t_secs" "$child_pid" "$child_pgid" "$child_start_token" "$t_watchdog_marker"
	watchdog_pid=$!

	# Poll until the child exits or the deadline is reached.
	if ! _sandbox_poll_child "$t_secs" "$child_pid" "$descendant_snapshot_file"; then
		log_sandbox "WARN" "Command timed out after ${t_secs}s — killing process group ${child_pgid}"
		_sandbox_pgkill_cleanup "$watchdog_pid" "$child_pgid" "$child_pid" "$descendant_snapshot_file"
		watchdog_pid=""
		# Reap the child after killing it
		wait "$child_pid" 2>/dev/null || true
		trap - EXIT
		return 124
	fi

	wait "$child_pid" 2>/dev/null
	t_exit_code=$?

	# Watchdog exit status override (GH#6414, CodeRabbit review): if the
	# secondary watchdog killed the child, it will have touched the marker
	# file. Override the exit code to 124 (standard timeout) so callers can
	# distinguish a watchdog-killed process from a normal non-zero exit.
	if [[ -f "$t_watchdog_marker" ]]; then
		log_sandbox "WARN" "Secondary watchdog marker detected for PID ${child_pid} — overriding exit code to 124"
		t_exit_code=124
		rm -f "$t_watchdog_marker" 2>/dev/null || true
	fi

	# Emit captured stderr to our stderr so callers (headless-runtime-helper)
	# can see errors from the child process. Always emit for headless workers
	# (opencode exits 0 even on silent failures). Truncate to 8KB.
	if [[ -s "$t_stderr_file" ]]; then
		local _stderr_size
		_stderr_size=$(wc -c <"$t_stderr_file" | tr -d ' ')
		log_sandbox "INFO" "Child exited $t_exit_code — captured stderr (${_stderr_size}B):"
		head -c 8192 "$t_stderr_file" >&2
		echo >&2
	fi

	# Explicitly clean up any remaining descendants in the process group.
	# The EXIT trap is cleared below, so cleanup must be called explicitly
	# here — the trap does not fire on a normal function return.
	_sandbox_pgkill_cleanup "$watchdog_pid" "$child_pgid" "$child_pid" "$descendant_snapshot_file"
	watchdog_pid=""
	trap - EXIT
	return "$t_exit_code"
}

# Get the start time of a process for PID recycling detection (GH#6414).
# On Linux, reads /proc/<pid>/stat field 22 (starttime in clock ticks since
# boot) — this is the most reliable identity token: monotonic, kernel-sourced,
# and avoids forking ps. On macOS/other, uses ps -o lstart= which returns the
# process start date/time string. Returns empty string if the process doesn't
# exist or the start time can't be determined (non-fatal — the watchdog
# proceeds without the recycling guard in that case).
# Arguments: $1 - PID
_sandbox_get_proc_starttime() {
	local gps_pid="$1"
	local gps_starttime=""

	if [[ -f "/proc/${gps_pid}/stat" ]]; then
		# Linux: field 22 of /proc/<pid>/stat is starttime (clock ticks since boot).
		# Fields are space-separated but field 2 (comm) can contain spaces and
		# parentheses, so we strip it first: remove everything from the first
		# '(' to the last ')' to get clean space-separated fields, then pick
		# field 20 (which is original field 22 after removing the 2-field comm).
		local gps_stat_content=""
		gps_stat_content="$(cat "/proc/${gps_pid}/stat" 2>/dev/null)" || true
		if [[ -n "$gps_stat_content" ]]; then
			# Remove comm field: everything from first '(' to last ')'
			local gps_after_comm=""
			gps_after_comm="${gps_stat_content##*) }"
			# Field 20 in the remaining string = original field 22 (starttime)
			gps_starttime="$(printf '%s' "$gps_after_comm" | awk '{print $20}')" || true
		fi
	else
		# macOS / other: use ps -o lstart= for process start time string.
		# Example output: "Wed Mar 25 14:30:00 2026"
		gps_starttime="$(ps -o lstart= -p "$gps_pid" 2>/dev/null | tr -s ' ')" || true
		# Trim leading/trailing whitespace
		gps_starttime="${gps_starttime#"${gps_starttime%%[![:space:]]*}"}"
		gps_starttime="${gps_starttime%"${gps_starttime##*[![:space:]]}"}"
	fi

	printf '%s' "$gps_starttime"
	return 0
}

# Secondary watchdog for _sandbox_exec_with_pgkill (GH#6413).
# Runs as a background process. Sleeps for timeout + 10% grace, then verifies
# wall-clock elapsed time via date(1) and kills the child process group if
# the deadline has been exceeded. This is defense-in-depth: if the primary
# polling loop in _sandbox_exec_with_pgkill fails (parent crash, OOM, sleep
# drift), this watchdog independently enforces the timeout.
#
# Exit status override (GH#6414): before sending TERM/KILL, the watchdog
# touches the marker file passed as $5. The parent checks for this marker
# after 'wait "$child_pid"' returns and overrides the exit code to 124
# (standard timeout exit code) so callers can distinguish watchdog-killed
# from normal exit. The marker path is derived from t_stderr_file to avoid
# collisions across concurrent sandbox invocations.
#
# PID recycling safety (GH#6414): $4 (child_start_token) is the process
# start time captured at spawn via _sandbox_get_proc_starttime (Linux:
# /proc/<pid>/stat field 22, macOS: ps -o lstart=). Before sending any
# signal, the watchdog re-reads the start time and compares. If they differ,
# the PID has been recycled — the watchdog logs and exits without signalling.
#
# Process identity (GH#6538): the watchdog is spawned via
# _sandbox_spawn_watchdog_bg which uses "( exec bash -c '...' sandbox-watchdog )"
# so the resulting process appears as "bash -c ... sandbox-watchdog" in ps,
# NOT as "sandbox-exec-helper.sh run ... opencode run ... /full-loop ...".
# This prevents list_active_worker_processes() in pulse-wrapper.sh from
# counting the watchdog as a second active worker for the same issue.
#
# Arguments:
#   $1 - timeout_secs (original timeout)
#   $2 - child_pid (PID to monitor)
#   $3 - child_pgid (process group ID, may be empty)
#   $4 - child_start_token (process start time captured at spawn, may be empty)
#   $5 - marker_file (touched before kill to signal timeout to parent)
_sandbox_spawn_watchdog() {
	local wd_timeout="$1"
	local wd_pid="$2"
	local wd_pgid="$3"
	local wd_start_token="$4"
	local wd_marker="$5"
	local wd_start
	wd_start="$(date +%s)"

	# Grace period: 10% of timeout, minimum 5s, maximum 60s.
	# This avoids racing with the primary loop which fires at exactly t_secs.
	local wd_grace=$((wd_timeout / 10))
	if ((wd_grace < 5)); then
		wd_grace=5
	fi
	if ((wd_grace > 60)); then
		wd_grace=60
	fi
	local wd_deadline=$((wd_timeout + wd_grace))

	# Sleep in chunks (30s) so we can exit promptly if the child finishes
	# and our parent kills us. A single long sleep would delay cleanup.
	local wd_slept=0
	while ((wd_slept < wd_deadline)); do
		local wd_chunk=30
		if ((wd_slept + wd_chunk > wd_deadline)); then
			wd_chunk=$((wd_deadline - wd_slept))
		fi
		sleep "$wd_chunk" 2>/dev/null || return 0
		wd_slept=$((wd_slept + wd_chunk))

		# Check if child is still alive — if not, our job is done
		if ! kill -0 "$wd_pid" 2>/dev/null; then
			return 0
		fi
	done

	# Verify wall-clock elapsed time to guard against sleep drift
	local wd_now
	wd_now="$(date +%s)"
	local wd_elapsed=$((wd_now - wd_start))

	if ((wd_elapsed < wd_timeout)); then
		# Sleep returned early (spurious wakeup) — not actually timed out
		return 0
	fi

	# Child is still alive past the deadline — verify PID identity before killing.
	if kill -0 "$wd_pid" 2>/dev/null; then
		# PID recycling safety: re-read the process start time via the same
		# platform-aware helper used at spawn. If the PID has been recycled
		# (new process with the same PID), the start times will differ.
		if [[ -n "$wd_start_token" ]]; then
			local wd_current_token=""
			wd_current_token="$(_sandbox_get_proc_starttime "$wd_pid")"
			if [[ -z "$wd_current_token" ]]; then
				# Lookup returned nothing — process already exited between kill -0 and now
				return 0
			fi
			if [[ "$wd_current_token" != "$wd_start_token" ]]; then
				log_sandbox "WARN" "Secondary watchdog: PID ${wd_pid} start time changed (token mismatch) — PID recycled, skipping kill"
				return 0
			fi
		fi

		log_sandbox "WARN" "Secondary watchdog: child PID ${wd_pid} still alive after ${wd_elapsed}s (timeout=${wd_timeout}s) — killing"

		# Touch marker file before sending signals so the parent can detect
		# that this watchdog (not a normal exit) caused the child's termination.
		# The parent checks for this file after 'wait "$child_pid"' and overrides
		# the exit code to 124.
		touch "$wd_marker" 2>/dev/null || true

		if [[ -n "$wd_pgid" ]]; then
			local wd_group_target="-${wd_pgid}"
			kill -- "$wd_group_target" 2>/dev/null || true
			sleep 1
			kill -0 -- "$wd_group_target" 2>/dev/null &&
				kill -9 -- "$wd_group_target" 2>/dev/null || true
		else
			kill "$wd_pid" 2>/dev/null || true
			sleep 1
			kill -0 "$wd_pid" 2>/dev/null &&
				kill -9 "$wd_pid" 2>/dev/null || true
		fi
	fi

	return 0
}

# Spawn the secondary watchdog as a background process with a distinct process
# name (GH#6538). Using "( exec bash -c '...' sandbox-watchdog )" replaces the
# forked subshell's process image so ps shows "bash -c ... sandbox-watchdog"
# instead of inheriting the parent's execve() command line
# ("sandbox-exec-helper.sh run ... -- opencode run ... /full-loop ...").
#
# Without this, list_active_worker_processes() in pulse-wrapper.sh matches the
# watchdog on /full-loop + opencode and counts it as a second active worker for
# the same issue — causing duplicate dispatch, git conflicts, and inflated
# struggle ratios (GH#6538).
#
# The watchdog body is sourced from the parent script so all helper functions
# (_sandbox_get_proc_starttime, log_sandbox, etc.) are available in the child.
# BASH_SOURCE[0] is the canonical path to this script file.
#
# Arguments: same as _sandbox_spawn_watchdog ($1-$5)
# Returns: 0 always (background job; caller captures PID via $!)
_sandbox_spawn_watchdog_bg() {
	local bg_timeout="$1"
	local bg_pid="$2"
	local bg_pgid="$3"
	local bg_start_token="$4"
	local bg_marker="$5"
	local bg_script="${BASH_SOURCE[0]}"

	# exec replaces the subshell's process image. The resulting process shows
	# as "bash -c <body> sandbox-watchdog <args>" in ps — no sandbox-exec-helper.sh,
	# no opencode, no /full-loop — so worker-counting filters skip it.
	(
		exec bash --norc --noprofile -c '
			script="$1"; shift
			# shellcheck source=/dev/null
			source "$script" 2>/dev/null || true
			_sandbox_spawn_watchdog "$@"
		' sandbox-watchdog "$bg_script" "$bg_timeout" "$bg_pid" "$bg_pgid" "$bg_start_token" "$bg_marker"
	) &
	return 0
}

# Build the env -i argument list for sandboxed execution.
# Appends to the caller's env_args array (visible via bash dynamic scoping).
# Arguments:
#   $1 - exec_tmpdir path (used to set TMPDIR)
#   $2 - extra_passthrough (comma-separated list of additional env var names)
#   $3 - optional isolated HOME override
# Caller must declare: local -a env_args=() before calling this function.
_sandbox_build_env_args() {
	local exec_tmpdir="$1"
	local extra_passthrough="$2"
	local home_override="${3:-}"

	# Seed with env -i to clear the environment
	env_args=("env" "-i")

	# Add default passthrough vars (only if they exist in current env)
	local var
	for var in $DEFAULT_PASSTHROUGH; do
		if [[ "$var" == "HOME" && -n "$home_override" ]]; then
			env_args+=("HOME=${home_override}")
		elif [[ -n "${!var:-}" ]]; then
			env_args+=("${var}=${!var}")
		fi
	done

	# Override TMPDIR to isolated directory
	env_args+=("TMPDIR=${exec_tmpdir}")

	# Add extra passthrough vars (comma-separated list)
	if [[ -n "$extra_passthrough" ]]; then
		local extra_var
		while IFS= read -r extra_var; do
			# trim whitespace
			extra_var="${extra_var#"${extra_var%%[![:space:]]*}"}"
			extra_var="${extra_var%"${extra_var##*[![:space:]]}"}"
			if [[ -n "${!extra_var:-}" ]]; then
				env_args+=("${extra_var}=${!extra_var}")
			else
				log_sandbox "WARN" "Passthrough var '${extra_var}' not set in environment, skipping"
			fi
		done < <(printf '%s\n' "$extra_passthrough" | tr ',' '\n')
	fi
	return 0
}

# Resolve the trusted whole-process egress backend configured by the operator.
# The path must be absolute so a worker-controlled PATH cannot select a backend.
# Output: absolute executable path. Returns 1 when no usable backend is set.
_sandbox_resolve_egress_backend() {
	local configured_backend="${AIDEVOPS_WORKER_EGRESS_BACKEND:-}"
	[[ -n "$configured_backend" && "$configured_backend" == /* && -x "$configured_backend" ]] || return 1
	printf '%s' "$configured_backend"
	return 0
}

# Calculate a portable SHA-256 digest for backend policy binding.
# Arguments: $1=file path. Output: lowercase hex digest.
_sandbox_file_sha256() {
	local input_file="$1"
	python3 - "$input_file" <<'PY'
import hashlib
import sys

with open(sys.argv[1], "rb") as handle:
    print(hashlib.sha256(handle.read()).hexdigest())
PY
	return $?
}

# Prepare and verify process-tree egress containment.
# Backend contract:
#   probe --policy FILE
#     emits {"schema":"aidevops.worker-egress-backend.v1","ready":true,
#            "scope":"process-tree","enforcement":"kernel",
#            "policy_sha256":"...","backend_id":"safe-id",
#            "capabilities":["direct-socket-deny","hostname-policy",
#            "private-network-deny"],"cleanup":"automatic"}
#   run --policy FILE --worker-id ID -- COMMAND [ARG...]
#     binds COMMAND and all descendants to the policy before exec.
# Arguments: $1=mode (off|auto|required), $2=policy file, $3=worker ID,
#            $4=policy profile (default or provider:NAME).
# Sets caller-scoped: egress_state, egress_backend, egress_backend_id.
_sandbox_prepare_worker_egress() {
	local mode="$1"
	local policy_file="$2"
	local worker_id_value="$3"
	local policy_profile="${4:-default}"
	local candidate=""
	local probe_output=""
	local expected_policy_sha256=""

	egress_state="command-policy-only"
	egress_backend=""
	egress_backend_id="none"
	if [[ "$mode" == "off" ]]; then
		egress_state="off"
		return 0
	fi

	if ! candidate="$(_sandbox_resolve_egress_backend)"; then
		if [[ "$mode" == "required" ]]; then
			log_sandbox "$SANDBOX_ERROR_LEVEL" "Whole-process worker egress is required but AIDEVOPS_WORKER_EGRESS_BACKEND is not an executable absolute path"
			return 1
		fi
		log_sandbox "WARN" "Whole-process worker egress backend unavailable; state=command-policy-only"
		return 0
	fi

	if [[ ! -x "$NETWORK_TIER_HELPER" ]]; then
		if [[ "$mode" == "required" ]]; then
			log_sandbox "$SANDBOX_ERROR_LEVEL" "Required network policy authority is unavailable: ${NETWORK_TIER_HELPER}"
			return 1
		fi
		log_sandbox "WARN" "Network policy export unavailable; state=command-policy-only"
		return 0
	fi
	local policy_export_status=0
	case "$policy_profile" in
	default)
		"$NETWORK_TIER_HELPER" export-policy >"$policy_file" || policy_export_status=$?
		;;
	provider:*)
		local provider_name="${policy_profile#provider:}"
		"$NETWORK_TIER_HELPER" export-provider-policy "$provider_name" \
			>"$policy_file" || policy_export_status=$?
		;;
	*) policy_export_status=2 ;;
	esac
	if [[ "$policy_export_status" -ne 0 ]]; then
		if [[ "$mode" == "required" ]]; then
			log_sandbox "$SANDBOX_ERROR_LEVEL" "Required worker egress policy export failed (profile=${policy_profile})"
			return 1
		fi
		log_sandbox "WARN" "Worker egress policy export failed (profile=${policy_profile}); state=command-policy-only"
		return 0
	fi
	expected_policy_sha256="$(_sandbox_file_sha256 "$policy_file")" || {
		log_sandbox "$SANDBOX_ERROR_LEVEL" "Unable to digest normalized worker egress policy"
		return 1
	}

	if ! probe_output="$("$candidate" probe --policy "$policy_file" 2>/dev/null)"; then
		if [[ "$mode" == "required" ]]; then
			log_sandbox "$SANDBOX_ERROR_LEVEL" "Required worker egress backend probe failed"
			return 1
		fi
		log_sandbox "WARN" "Worker egress backend probe failed; state=command-policy-only"
		return 0
	fi
	if ! printf '%s' "$probe_output" | jq -e \
		--arg policy_sha256 "$expected_policy_sha256" \
		'.schema == "aidevops.worker-egress-backend.v1" and .ready == true and .scope == "process-tree" and (.enforcement == "kernel" or .enforcement == "equivalent") and .policy_sha256 == $policy_sha256 and (.backend_id | type == "string") and .cleanup == "automatic" and (["direct-socket-deny", "hostname-policy", "private-network-deny"] - .capabilities | length == 0)' \
		>/dev/null 2>&1; then
		if [[ "$mode" == "required" ]]; then
			log_sandbox "$SANDBOX_ERROR_LEVEL" "Required worker egress backend returned an invalid readiness contract"
			return 1
		fi
		log_sandbox "WARN" "Worker egress backend readiness contract invalid; state=command-policy-only"
		return 0
	fi

	egress_backend_id="$(printf '%s' "$probe_output" | jq -r '.backend_id')"
	if [[ ! "$egress_backend_id" =~ ^[A-Za-z0-9._-]+$ ]]; then
		log_sandbox "$SANDBOX_ERROR_LEVEL" "Worker egress backend_id contains unsupported characters"
		return 1
	fi
	egress_backend="$candidate"
	egress_state="enforced"
	log_sandbox "INFO" "Whole-process worker egress ready (backend=${egress_backend_id}, worker=${worker_id_value})"
	return 0
}

# Dispatch the sandboxed command via _sandbox_exec_with_pgkill.
# Handles optional macOS seatbelt network blocking.
# Arguments:
#   $1 - block_network (true|false)
#   $2 - timeout_secs
#   $3 - stdout_file
#   $4 - stderr_file
#   $5 - egress backend path (empty for none)
#   $6 - normalized egress policy file
#   $7 - worker ID
# Remaining args: env_args elements followed by "--" followed by cmd_args elements.
# Caller passes: "${env_args[@]}" "--" "${cmd_args[@]}"
_sandbox_run_dispatch() {
	local block_network="$1"
	local timeout_secs="$2"
	local stdout_file="$3"
	local stderr_file="$4"
	local egress_backend_path="$5"
	local egress_policy_file="$6"
	local dispatch_worker_id="$7"
	shift 7
	local dispatch_exit=0

	# Split remaining args into env_args and cmd_args at the "--" separator
	local -a d_env_args=()
	local -a d_cmd_args=()
	local past_sep=false
	local arg
	for arg in "$@"; do
		if [[ "$past_sep" == false ]] && [[ "$arg" == "--" ]]; then
			past_sep=true
		elif [[ "$past_sep" == false ]]; then
			d_env_args+=("$arg")
		else
			d_cmd_args+=("$arg")
		fi
	done

	local -a d_exec_args=()
	if [[ -n "$egress_backend_path" ]]; then
		d_exec_args=("$egress_backend_path" run --policy "$egress_policy_file" --worker-id "$dispatch_worker_id" -- "${d_env_args[@]}" "${d_cmd_args[@]}")
	else
		d_exec_args=("${d_env_args[@]}" "${d_cmd_args[@]}")
	fi

	if [[ "$block_network" == true ]] && command -v sandbox-exec &>/dev/null; then
		# macOS seatbelt: deny network access.
		# sandbox-exec accepts program + args directly (no shell wrapper needed).
		local seatbelt_profile="(version 1)(allow default)(deny network*)"
		_sandbox_exec_with_pgkill "$timeout_secs" "$stdout_file" "$stderr_file" \
			sandbox-exec -p "$seatbelt_profile" \
			"${d_exec_args[@]}" || dispatch_exit=$?
	else
		if [[ "$block_network" == true ]]; then
			log_sandbox "$SANDBOX_ERROR_LEVEL" "Network blocking requested but no enforcing deny-all backend is available"
			return 126
		fi
		_sandbox_exec_with_pgkill "$timeout_secs" "$stdout_file" "$stderr_file" \
			"${d_exec_args[@]}" || dispatch_exit=$?
	fi

	return "$dispatch_exit"
}

# Handle post-execution steps: timeout warning, output emission, audit log, cleanup.
# Arguments:
#   $1 - exit_code
#   $2 - timeout_secs
#   $3 - stdout_file
#   $4 - stderr_file
#   $5 - command_tainted (true|false)
#   $6 - cmd_str
#   $7 - duration (seconds)
#   $8 - block_network (true|false)
#   $9 - extra_passthrough
#   $10 - egress_state
#   $11 - egress_backend_id
_sandbox_run_post_exec() {
	local exit_code="$1"
	local timeout_secs="$2"
	local stdout_file="$3"
	local stderr_file="$4"
	local command_tainted="$5"
	local cmd_str="$6"
	local duration="$7"
	local block_network="$8"
	local extra_passthrough="$9"
	local egress_state_value="${10}"
	local egress_backend_value="${11}"

	# Handle timeout (exit code 124 from _sandbox_exec_with_pgkill)
	if [[ $exit_code -eq 124 ]]; then
		log_sandbox "WARN" "Command timed out after ${timeout_secs}s"
	fi

	# Output results with redaction and taint-aware handling.
	# In --stream-stdout mode, stdout was already sent to the caller in
	# real-time (not captured to file), so skip its emission here.
	if [[ "${stream_stdout:-false}" != "true" ]]; then
		_sandbox_emit_redacted_output "$stdout_file" "stdout" "$command_tainted"
	fi
	_sandbox_emit_redacted_output "$stderr_file" "stderr" "$command_tainted"

	# Audit log
	log_execution "$cmd_str" "$exit_code" "$duration" "$timeout_secs" "$block_network" "$extra_passthrough" "$egress_state_value" "$egress_backend_value"

	# Async cleanup of old temp dirs (older than 60 minutes).
	# stderr is not suppressed so permission errors or other persistent failures
	# remain visible for debugging rather than silently consuming disk space.
	find "$SANDBOX_TMP_BASE" -maxdepth 1 -type d -mmin +60 -exec rm -rf {} + &

	return 0
}

# Check the secret IO guard for a command string.
# Returns 0 (proceed) or 126 (blocked). Logs and records the blocked execution.
# Arguments:
#   $1 - secret_io_guard (true|false)
#   $2 - allow_secret_io (true|false)
#   $3 - cmd_str
#   $4 - timeout_secs
#   $5 - block_network (true|false)
#   $6 - extra_passthrough
#   $7 - audit-safe command text
_sandbox_run_check_secret_guard() {
	local secret_io_guard="$1"
	local allow_secret_io="$2"
	local cmd_str="$3"
	local timeout_secs="$4"
	local block_network="$5"
	local extra_passthrough="$6"
	local audit_cmd_str="${7:-$cmd_str}"

	if [[ "$secret_io_guard" == "true" ]] && [[ "$allow_secret_io" != "true" ]]; then
		local block_reason
		if block_reason="$(_sandbox_secret_block_reason "$cmd_str")"; then
			log_sandbox "$SANDBOX_ERROR_LEVEL" "Blocked command due to secret leak risk: ${block_reason}"
			log_sandbox "$SANDBOX_ERROR_LEVEL" "Use --allow-secret-io only for explicit user-approved local operations"
			log_execution "$audit_cmd_str" 126 0 "$timeout_secs" "$block_network" "$extra_passthrough"
			return 126
		fi
	fi
	return 0
}

# Log execution intent and detect secret-tainted output.
# Prints "true" or "false" to stdout to indicate whether the command is tainted.
# Arguments:
#   $1 - display command string
#   $2 - timeout_secs
#   $3 - block_network (true|false)
#   $4 - network_tiering (true|false)
#   $5 - heuristic-only command text
#   $6 - egress state
#   $7 - egress backend ID
_sandbox_run_pre_exec() {
	local cmd_str="$1"
	local timeout_secs="$2"
	local block_network="$3"
	local network_tiering="$4"
	local heuristic_text="$5"
	local egress_state_value="$6"
	local egress_backend_value="$7"

	log_sandbox "INFO" "Executing (timeout=${timeout_secs}s, network_blocked=${block_network}, tiering=${network_tiering}, egress=${egress_state_value}, backend=${egress_backend_value}): ${cmd_str:0:200}"

	local command_tainted=false
	if _sandbox_is_secret_tainted_command "$heuristic_text"; then
		command_tainted=true
	fi
	printf '%s' "$command_tainted"
	return 0
}

# Parse sandbox_run flags into caller-scoped variables (bash dynamic scoping).
# Caller must declare all target variables as local before calling this function:
#   timeout_secs, block_network, network_tiering, allow_secret_io,
#   worker_id, extra_passthrough, stream_stdout, egress_mode,
#   egress_policy_profile, home_override, cmd_args (array).
# Returns 0 on success, 1 if no command was provided after flag parsing.
_sandbox_run_parse_args() {
	while [[ $# -gt 0 ]]; do
		case $1 in
		--timeout)
			timeout_secs="$2"
			if ((timeout_secs > SANDBOX_MAX_TIMEOUT)); then
				log_sandbox "WARN" "Timeout capped at ${SANDBOX_MAX_TIMEOUT}s (requested ${timeout_secs}s)"
				timeout_secs=$SANDBOX_MAX_TIMEOUT
			fi
			shift 2
			;;
		--no-network)
			block_network=true
			shift
			;;
		--network-tiering)
			network_tiering=true
			shift
			;;
		--egress-mode)
			egress_mode="$2"
			shift 2
			;;
		--egress-policy-profile)
			egress_policy_profile="$2"
			shift 2
			;;
		--home-dir)
			home_override="$2"
			shift 2
			;;
		--allow-secret-io)
			allow_secret_io=true
			shift
			;;
		--worker-id)
			worker_id="$2"
			shift 2
			;;
		--passthrough)
			extra_passthrough="$2"
			shift 2
			;;
		--stream-stdout)
			stream_stdout=true
			shift
			;;
		--private-output)
			private_output=true
			stream_stdout=true
			shift
			;;
		--)
			shift
			cmd_args=("$@")
			return 0
			;;
		*)
			cmd_args=("$@")
			return 0
			;;
		esac
	done
	return 0
}

_sandbox_validate_private_output_mode() {
	local private_output_value="$1"
	if [[ "$private_output_value" == "true" && "${AIDEVOPS_PRIVATE_WORKLOAD:-0}" != "1" ]]; then
		log_sandbox "$SANDBOX_ERROR_LEVEL" "Private output requires an active private workload"
		return 2
	fi
	return 0
}

_sandbox_validate_run_options() {
	local private_output_value="$1"
	local egress_mode_value="$2"
	local policy_profile="$3"
	local home_override_value="$4"

	_sandbox_validate_private_output_mode "$private_output_value" || return $?
	case "$egress_mode_value" in
	off | auto | required) ;;
	*)
		log_sandbox "$SANDBOX_ERROR_LEVEL" "Invalid worker egress mode '${egress_mode_value}' (expected off, auto, or required)"
		return 2
		;;
	esac
	if [[ "$policy_profile" != "default" && \
		! "$policy_profile" =~ ^provider:[A-Za-z0-9._-]+$ ]]; then
		log_sandbox "$SANDBOX_ERROR_LEVEL" "Invalid worker egress policy profile '${policy_profile}'"
		return 2
	fi
	if [[ -n "$home_override_value" && \
		("$home_override_value" != /* || ! -d "$home_override_value" || -L "$home_override_value") ]]; then
		log_sandbox "$SANDBOX_ERROR_LEVEL" "Isolated HOME must be an existing absolute non-symlink directory"
		return 2
	fi
	return 0
}

sandbox_run() {
	local timeout_secs="$SANDBOX_DEFAULT_TIMEOUT"
	local block_network=false
	local network_tiering=true
	local allow_secret_io=false
	local worker_id="sandbox-$$"
	local extra_passthrough=""
	local egress_mode="${AIDEVOPS_WORKER_EGRESS_MODE:-auto}"
	local egress_state="command-policy-only"
	local egress_backend=""
	local egress_backend_id="none"
	local egress_policy_profile="default"
	local home_override=""
	local secret_io_guard="${AIDEVOPS_BLOCK_SECRET_IO:-$SECRET_IO_GUARD_DEFAULT}"
	# Stream stdout mode (GH#15180 bug #4): when true, child stdout flows to
	# the caller's stdout in real-time instead of being captured to a file and
	# replayed after exit. This allows external watchdogs (e.g., the headless
	# activity watchdog) to monitor output as it's produced. Stderr is still
	# captured. Post-exec stdout emission is skipped (already streamed).
	local stream_stdout=false
	# Private output mode streams both stdout and stderr to the caller without
	# writing either stream to the sandbox temp directory. The caller must apply
	# a non-content filter before persistence.
	local private_output=false
	# cmd_args is an array — preserves spaces, avoids bash -c eval risks
	local -a cmd_args=()

	_sandbox_run_parse_args "$@"

	if [[ ${#cmd_args[@]} -eq 0 ]]; then
		log_sandbox "$SANDBOX_ERROR_LEVEL" "No command provided"
		return 1
	fi
	_sandbox_validate_run_options \
		"$private_output" "$egress_mode" "$egress_policy_profile" "$home_override" || return $?

	local argv_json=""
	argv_json="$(_sandbox_argv_json "${cmd_args[@]}")" || return 126
	local cmd_str=""
	cmd_str="$(_sandbox_argv_display "${cmd_args[@]}")" || return 126
	local audit_cmd_str="$cmd_str"
	if [[ "$private_output" == "true" ]]; then
		audit_cmd_str="[private workload command suppressed]"
	fi
	local heuristic_text=""
	heuristic_text="$(_sandbox_argv_heuristic_text "${cmd_args[@]}")" || return 126

	_sandbox_run_check_secret_guard \
		"$secret_io_guard" "$allow_secret_io" "$heuristic_text" \
		"$timeout_secs" "$block_network" "$extra_passthrough" "$audit_cmd_str" || return $?
	if ! _sandbox_check_command_policy "$argv_json" "$worker_id"; then
		log_execution "$audit_cmd_str" 126 0 "$timeout_secs" "$block_network" "$extra_passthrough"
		return 126
	fi

	# Create isolated temp directory
	local exec_id
	exec_id="$(date +%s)-$$"
	local exec_tmpdir="${SANDBOX_TMP_BASE}/${exec_id}"
	mkdir -p "$exec_tmpdir"

	local -a env_args=()
	_sandbox_build_env_args "$exec_tmpdir" "$extra_passthrough" "$home_override"
	local egress_policy_file="${exec_tmpdir}/egress-policy.json"
	if ! _sandbox_prepare_worker_egress "$egress_mode" "$egress_policy_file" "$worker_id" "$egress_policy_profile"; then
		log_execution "$audit_cmd_str" 126 0 "$timeout_secs" "$block_network" "$extra_passthrough" "unavailable" "none"
		rm -rf "$exec_tmpdir"
		return 126
	fi

	local stdout_file="${exec_tmpdir}/stdout"
	local stderr_file="${exec_tmpdir}/stderr"
	local command_tainted
	command_tainted="$(_sandbox_run_pre_exec \
		"$audit_cmd_str" "$timeout_secs" "$block_network" "$network_tiering" "$heuristic_text" \
		"$egress_state" "$egress_backend_id")"

	local start_time exit_code=0
	start_time="$(date +%s)"

	_sandbox_run_dispatch \
		"$block_network" "$timeout_secs" "$stdout_file" "$stderr_file" \
		"$egress_backend" "$egress_policy_file" "$worker_id" \
		"${env_args[@]}" "--" "${cmd_args[@]}" || exit_code=$?
	rm -f "$egress_policy_file"

	local end_time duration
	end_time="$(date +%s)"
	duration=$((end_time - start_time))

	_sandbox_run_post_exec \
		"$exit_code" "$timeout_secs" "$stdout_file" "$stderr_file" \
		"$command_tainted" "$audit_cmd_str" "$duration" "$block_network" "$extra_passthrough" \
		"$egress_state" "$egress_backend_id"

	return "$exit_code"
}

# =============================================================================
# Audit
# =============================================================================

sandbox_audit() {
	local last_n=20

	while [[ $# -gt 0 ]]; do
		case $1 in
		--last)
			last_n="$2"
			shift 2
			;;
		*) shift ;;
		esac
	done

	if [[ ! -f "$SANDBOX_LOG" ]]; then
		echo "No sandbox executions logged yet."
		return 0
	fi

	echo "Last ${last_n} sandboxed executions:"
	echo "---"
	# Single jq call per line extracts all four fields at once via @tsv,
	# replacing four separate jq invocations and significantly reducing overhead
	# for large log files.
	tail -n "$last_n" "$SANDBOX_LOG" | while IFS= read -r line; do
		local ts cmd exit_code duration
		IFS=$'\t' read -r ts cmd exit_code duration < <(
			printf '%s' "$line" | jq -r '[.ts, .cmd, .exit, .duration_s] | map(. // "?") | @tsv'
		)
		# Truncate command display to 80 chars
		cmd="${cmd:0:80}"
		printf '%s  exit=%s  %ss  %s\n' "$ts" "$exit_code" "$duration" "$cmd"
	done
	return 0
}

# =============================================================================
# Config
# =============================================================================

sandbox_config() {
	echo "Sandbox configuration:"
	echo "  Log:          ${SANDBOX_LOG}"
	echo "  Tmp base:     ${SANDBOX_TMP_BASE}"
	echo "  Timeout:      ${SANDBOX_DEFAULT_TIMEOUT}s (max ${SANDBOX_MAX_TIMEOUT}s)"
	echo "  Max output:   $((SANDBOX_MAX_OUTPUT_BYTES / 1048576))MB per stream"
	echo "  Secret guard: ${AIDEVOPS_BLOCK_SECRET_IO:-$SECRET_IO_GUARD_DEFAULT}"
	echo "  Passthrough:  ${DEFAULT_PASSTHROUGH}"
	echo "  Net tiering:  enforced by shared worker command policy"
	echo "  Egress mode:  ${AIDEVOPS_WORKER_EGRESS_MODE:-auto}"
	echo "  Egress backend: $([[ -n "${AIDEVOPS_WORKER_EGRESS_BACKEND:-}" ]] && echo configured || echo none)"
	echo ""
	if [[ -f "$SANDBOX_LOG" ]]; then
		local count
		count="$(wc -l <"$SANDBOX_LOG" | xargs)"
		echo "  Executions logged: ${count}"
	else
		echo "  Executions logged: 0"
	fi
	return 0
}

# =============================================================================
# Help
# =============================================================================

sandbox_help() {
	cat <<'HELP'
sandbox-exec-helper.sh — Lightweight execution sandbox

Commands:
  run command [args...]      Execute command in sandboxed environment
  audit [--last N]           Show recent sandboxed executions
  config --show              Show sandbox configuration
  help                       Show this help

Run options:
HELP
	printf '  --timeout N                Timeout in seconds (default: %ss, max: %ss)\n' \
		"$SANDBOX_DEFAULT_TIMEOUT" "$SANDBOX_MAX_TIMEOUT"
	cat <<'HELP'
  --no-network               Block network access (macOS only, uses seatbelt)
  --network-tiering          Compatibility flag; enforcement is enabled by default
  --egress-mode MODE         Whole-process backend mode: off|auto|required
  --egress-policy-profile P  Policy profile: default|provider:NAME
  --home-dir PATH            Override HOME inside the clean environment
  --allow-secret-io          Bypass secret-output guard for this command only
  --worker-id ID             Worker identifier for network tier logs
  --passthrough "VAR1,VAR2"  Additional env vars to pass through

  Command and its arguments are passed as separate shell words — not a single
  quoted string. This correctly handles arguments containing spaces and avoids
  shell injection via bash -c evaluation.

Examples:
  sandbox-exec-helper.sh run ls -la /tmp
  sandbox-exec-helper.sh run --timeout 60 npm test
  sandbox-exec-helper.sh run --no-network python3 script.py
  sandbox-exec-helper.sh run --network-tiering --worker-id w123 curl https://api.github.com/repos
  sandbox-exec-helper.sh run --allow-secret-io gopass show aidevops/EXAMPLE
  sandbox-exec-helper.sh run --passthrough "GITHUB_TOKEN" gh pr list
  sandbox-exec-helper.sh audit --last 10

Security model:
  - Environment cleared (env -i) with minimal passthrough
  - Each execution gets isolated TMPDIR
  - Configurable timeout with hard kill
  - Secret-output command guard blocks likely credential leakage patterns
  - Optional network blocking (macOS seatbelt)
  - Recognized direct network clients block Tier 5 and DNS-exfiltration targets
  - Configured backends wrap the complete process tree before command execution
  - required mode fails closed when no verified process-tree backend is ready
  - auto mode reports command-policy-only when containment is unavailable
  - All executions logged to JSONL audit trail (jq-safe JSON, injection-proof)
  - Output capped at 10MB per stream

Backend contract:
  Set AIDEVOPS_WORKER_EGRESS_BACKEND to an absolute executable path. The backend
  must implement `probe --policy FILE` and `run --policy FILE --worker-id ID --
  COMMAND...` using the v1 JSON contracts documented in this script.
HELP
	return 0
}

# =============================================================================
# Main
# =============================================================================

main() {
	local cmd="${1:-help}"
	local status=0
	shift || true

	case "$cmd" in
	run) sandbox_run "$@" || status=$? ;;
	audit) sandbox_audit "$@" || status=$? ;;
	config) sandbox_config "$@" || status=$? ;;
	help) sandbox_help || status=$? ;;
	*)
		log_sandbox "$SANDBOX_ERROR_LEVEL" "Unknown command: ${cmd}"
		sandbox_help
		return 1
		;;
	esac
	return "$status"
}

# Source guard: only call main() when executed directly, not when sourced.
# This prevents the secondary watchdog (_sandbox_spawn_watchdog_bg) from
# triggering help output when it sources this script to load helper functions.
# Without this guard, sourcing the script would call main() with the watchdog's
# positional args (e.g., a numeric timeout), which falls through to the *)
# case in main() → sandbox_help() → help text printed to the sandbox's stdout
# pipe → contaminating the opencode output file → output_has_activity() returns
# "0" → headless-runtime-helper.sh records a backoff and never launches the
# worker. This was the root cause of GH#6617. (GH#6550)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	main "$@"
fi

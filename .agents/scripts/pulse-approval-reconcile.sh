#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# pulse-approval-reconcile.sh — bounded exact-target NMR approval recovery.

[[ -n "${_PULSE_APPROVAL_RECONCILE_LOADED:-}" ]] && return 0
_PULSE_APPROVAL_RECONCILE_LOADED=1

_pulse_approval_reconcile_log() {
	local message="$1"
	local log_file="${LOGFILE:-${HOME:-.}/.aidevops/logs/pulse.log}"
	local timestamp=""

	timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date)
	printf '[%s] approval-reconcile: %s\n' "$timestamp" "$message" >>"$log_file" 2>/dev/null || true
	return 0
}

_pulse_reconcile_bounded_integer() {
	local value="$1"
	local default_value="$2"
	local minimum="$3"
	local maximum="$4"

	case "$value" in
	'' | *[!0-9]*) value="$default_value" ;;
	*) value=$((10#$value)) ;;
	esac
	if [[ "$value" -lt "$minimum" || "$value" -gt "$maximum" ]]; then
		value="$default_value"
	fi
	printf '%s' "$value"
	return 0
}

#######################################
# Reconcile one issue or PR after GitHub Actions may have conservatively
# restored needs-maintainer-review. The approval helper owns current-state V2
# signature verification, authenticated actor authority, and the appropriate
# issue/PR lifecycle writer. This wrapper only owns a short bounded race window.
#
# Args: target type (issue|pr), target number, repo slug
# Returns: 0 reconciled/closed/no restored hold; 1 invalid or still blocked
#######################################
_pulse_reconcile_verified_approval_target() {
	local target_type="${1:-}"
	local target_number="${2:-}"
	local slug="${3:-}"
	local approval_helper="${AGENTS_DIR:-${HOME:-}/.aidevops/agents}/scripts/approval-helper.sh"
	local attempts="${AIDEVOPS_NMR_RECONCILE_ATTEMPTS:-6}"
	local delay_seconds="${AIDEVOPS_NMR_RECONCILE_DELAY_SECONDS:-1}"
	local attempt=1
	local result=""
	local reconcile_rc=0
	local reconciled=0
	local saw_mutation_uncertainty=0

	if [[ "$target_type" != "issue" && "$target_type" != "pr" ]]; then
		_pulse_approval_reconcile_log "rejected invalid target type '${target_type}'"
		return 1
	fi
	if ! [[ "$target_number" =~ ^[0-9]+$ ]]; then
		_pulse_approval_reconcile_log "rejected invalid ${target_type} number '${target_number}'"
		return 1
	fi
	if ! [[ "$slug" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
		_pulse_approval_reconcile_log "rejected invalid repository slug '${slug}'"
		return 1
	fi
	if [[ ! -f "$approval_helper" ]]; then
		_pulse_approval_reconcile_log "approval helper unavailable for ${slug} ${target_type} #${target_number}"
		return 1
	fi

	attempts=$(_pulse_reconcile_bounded_integer "$attempts" 6 1 8)
	delay_seconds=$(_pulse_reconcile_bounded_integer "$delay_seconds" 1 0 8)

	while [[ "$attempt" -le "$attempts" ]]; do
		reconcile_rc=0
		result=$(bash "$approval_helper" reconcile "$target_type" "$target_number" "$slug" 2>/dev/null) || reconcile_rc=$?
		case "$result" in
		RECONCILED)
			if [[ "$reconcile_rc" -eq 0 ]]; then
				_pulse_approval_reconcile_log "restored ${slug} ${target_type} #${target_number} on attempt ${attempt}/${attempts}"
				reconciled=1
			else
				saw_mutation_uncertainty=1
			fi
			;;
		TARGET_CLOSED)
			if [[ "$reconcile_rc" -eq 0 ]]; then
				_pulse_approval_reconcile_log "target already closed: ${slug} ${target_type} #${target_number}"
				return 0
			else
				saw_mutation_uncertainty=1
			fi
			;;
		NO_NMR)
			if [[ "$reconcile_rc" -ne 3 ]]; then
				_pulse_approval_reconcile_log "unexpected NO_NMR status for ${slug} ${target_type} #${target_number} on attempt ${attempt}: rc=${reconcile_rc}"
				saw_mutation_uncertainty=1
			elif [[ "$reconciled" -eq 1 ]]; then
				_pulse_approval_reconcile_log "restored state remained stable for ${slug} ${target_type} #${target_number}"
				return 0
			elif [[ "$attempt" -eq "$attempts" && "$saw_mutation_uncertainty" -eq 0 ]]; then
				_pulse_approval_reconcile_log "no restored NMR observed for ${slug} ${target_type} #${target_number} after ${attempts} bounded attempt(s)"
				return 0
			fi
			;;
		API_ERROR)
			# Transient read uncertainty may recover inside the bounded window.
			;;
		UPDATE_FAILED)
			# Do not treat a later absent hold as a clean no-op: the lifecycle writer
			# may have partially cleared NMR before reporting its failed mutation.
			saw_mutation_uncertainty=1
			;;
		NO_APPROVAL | NO_KEY | STALE_APPROVAL | LEGACY_APPROVAL | MALFORMED_APPROVAL | UNTRUSTED_APPROVAL | TARGET_MISMATCH)
			_pulse_approval_reconcile_log "blocked ${slug} ${target_type} #${target_number}: ${result}"
			return 1
			;;
		*)
			_pulse_approval_reconcile_log "unexpected result for ${slug} ${target_type} #${target_number} on attempt ${attempt}: ${result:-empty} (rc=${reconcile_rc})"
			;;
		esac

		if [[ "$attempt" -ge "$attempts" ]]; then
			break
		fi
		if [[ "$delay_seconds" -gt 0 ]]; then
			sleep "$delay_seconds"
			if [[ "$delay_seconds" -lt 8 ]]; then
				delay_seconds=$((delay_seconds * 2))
				[[ "$delay_seconds" -le 8 ]] || delay_seconds=8
			fi
		fi
		attempt=$((attempt + 1))
	done

	_pulse_approval_reconcile_log "bounded recovery exhausted for ${slug} ${target_type} #${target_number}: ${result:-empty} (rc=${reconcile_rc})"
	return 1
}

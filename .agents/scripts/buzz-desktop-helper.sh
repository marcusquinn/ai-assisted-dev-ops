#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Buzz Desktop compatibility helpers for aidevops-managed runtime integrations.

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh"

BUZZ_APP_PATH="${AIDEVOPS_BUZZ_APP_PATH:-/Applications/Buzz.app}"
BUZZ_STORE_PATH="${AIDEVOPS_BUZZ_STORE_PATH:-${HOME}/Library/Application Support/xyz.block.buzz.app/agents/managed-agents.json}"
BUZZ_STATE_DIR="${AIDEVOPS_BUZZ_STATE_DIR:-${HOME}/.aidevops/state}"
BUZZ_STATE_FILE="${AIDEVOPS_BUZZ_STATE_FILE:-${BUZZ_STATE_DIR}/buzz-opencode-acp-fix.json}"
BUZZ_BACKUP_DIR="${AIDEVOPS_BUZZ_BACKUP_DIR:-${HOME}/.aidevops/buzz-backups}"
BUZZ_LOCK_DIR="${AIDEVOPS_BUZZ_LOCK_DIR:-${HOME}/.aidevops/locks/buzz-opencode-acp-fix.lock}"
BUZZ_BACKUP_RETAIN="${AIDEVOPS_BUZZ_BACKUP_RETAIN:-3}"
BUZZ_ACP_ARG="acp"
BUZZ_PLATFORM_DARWIN="Darwin"
BUZZ_LOCK_HELD=0
BUZZ_QUIET=false
BUZZ_LAST_BACKUP=""

_buzz_cleanup() {
	if [[ "$BUZZ_LOCK_HELD" -eq 1 && -d "$BUZZ_LOCK_DIR" ]]; then
		rmdir "$BUZZ_LOCK_DIR" 2>/dev/null || true
	fi
	BUZZ_LOCK_HELD=0
	return 0
}
trap _buzz_cleanup EXIT

_buzz_info() {
	local message="$1"
	[[ "$BUZZ_QUIET" == "true" ]] || print_info "$message"
	return 0
}

_buzz_platform() {
	if [[ -n "${AIDEVOPS_BUZZ_PLATFORM_OVERRIDE:-}" ]]; then
		printf '%s\n' "$AIDEVOPS_BUZZ_PLATFORM_OVERRIDE"
		return 0
	fi
	uname -s
	return 0
}

_buzz_app_version() {
	if [[ -n "${AIDEVOPS_BUZZ_VERSION_OVERRIDE:-}" ]]; then
		printf '%s\n' "$AIDEVOPS_BUZZ_VERSION_OVERRIDE"
		return 0
	fi
	local plist="${BUZZ_APP_PATH}/Contents/Info.plist"
	[[ -f "$plist" && ! -L "$plist" ]] || return 1
	if command -v defaults >/dev/null 2>&1; then
		defaults read "$plist" CFBundleShortVersionString 2>/dev/null
		return $?
	fi
	if [[ -x /usr/libexec/PlistBuddy ]]; then
		/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist" 2>/dev/null
		return $?
	fi
	return 1
}

_buzz_is_running() {
	case "${AIDEVOPS_BUZZ_RUNNING_OVERRIDE:-}" in
	true | 1) return 0 ;;
	false | 0) return 1 ;;
	esac
	pgrep -x Buzz >/dev/null 2>&1 || pgrep -x buzz-desktop >/dev/null 2>&1
	return $?
}

_buzz_is_affected_version() {
	local version="$1"
	case "$version" in
	0.5.4 | 0.5.5) return 0 ;;
	*) return 1 ;;
	esac
}

_buzz_validate_private_file() {
	local path="$1"
	local label="$2"
	if [[ ! -f "$path" || -L "$path" ]]; then
		print_error "$label must be a regular non-symlink file"
		return 1
	fi
	local owner=""
	owner=$(_file_owner "$path")
	if [[ "$owner" != "$(id -un)" ]]; then
		print_error "$label is not owned by the current user"
		return 1
	fi
	local perms=""
	perms=$(_file_perms "$path")
	case "$perms" in
	600 | 400) ;;
	*)
		print_error "$label permissions must be private (600 or 400), found ${perms}"
		return 1
		;;
	esac
	return 0
}

_buzz_validate_store() {
	command -v jq >/dev/null 2>&1 || {
		print_error "jq is required for Buzz Desktop compatibility reconciliation"
		return 1
	}
	_buzz_validate_private_file "$BUZZ_STORE_PATH" "Buzz managed-agent store" || return 1
	jq -e '
		def is_array: type == "array";
		def is_string: type == "string";
		def command_basename:
			if is_string then (split("/") | last) else "" end;
		def needs_patch:
			([.agent_command, .agent_command_override]
				| map(command_basename)
				| any(. == "opencode")) and
			(((.agent_args // []) | length) == 0);
		is_array and
		all(.[];
			type == "object" and
			((.agent_args == null) or (.agent_args | is_array)) and
			((needs_patch | not) or
				((.pubkey | is_string) and (.pubkey | length) > 0))
		)
	' "$BUZZ_STORE_PATH" >/dev/null 2>&1 || {
		print_error "Buzz managed-agent store has an invalid record schema"
		return 1
	}
	return 0
}

_buzz_target_filter() {
	printf '%s\n' '
    def command_basename:
      if type == "string" then (split("/") | last) else "" end;
    ([.agent_command, .agent_command_override] | map(command_basename) | any(. == "opencode"))
  '
	return 0
}

_buzz_eligible_count() {
	local filter=""
	filter=$(_buzz_target_filter)
	jq "
		[
			.[]
			| select(${filter})
			| select(((.agent_args // []) | length) == 0)
		] | length
	" "$BUZZ_STORE_PATH"
	return $?
}

_buzz_fixed_count() {
	local filter=""
	filter=$(_buzz_target_filter)
	jq --arg acp "$BUZZ_ACP_ARG" "
		[
			.[]
			| select(${filter})
			| select((.agent_args // []) == [\$acp])
		] | length
	" "$BUZZ_STORE_PATH"
	return $?
}

_buzz_acquire_lock() {
	local parent="${BUZZ_LOCK_DIR%/*}"
	umask 077
	mkdir -p "$parent"
	chmod 700 "$parent"
	if ! mkdir "$BUZZ_LOCK_DIR" 2>/dev/null; then
		print_error "Another Buzz compatibility reconciliation is already running"
		return 1
	fi
	BUZZ_LOCK_HELD=1
	return 0
}

_buzz_release_lock() {
	_buzz_cleanup
	return 0
}

_buzz_create_backup() {
	local timestamp=""
	timestamp=$(date -u +%Y%m%dT%H%M%SZ)
	umask 077
	mkdir -p "$BUZZ_BACKUP_DIR"
	chmod 700 "$BUZZ_BACKUP_DIR"
	BUZZ_LAST_BACKUP="${BUZZ_BACKUP_DIR}/managed-agents.${timestamp}.$$.json"
	cp -p "$BUZZ_STORE_PATH" "$BUZZ_LAST_BACKUP"
	chmod 600 "$BUZZ_LAST_BACKUP"
	return 0
}

_buzz_prune_backups() {
	[[ "$BUZZ_BACKUP_RETAIN" =~ ^[0-9]+$ ]] || BUZZ_BACKUP_RETAIN=3
	local count=0
	local path=""
	while IFS= read -r path; do
		[[ -n "$path" && -f "$path" && ! -L "$path" ]] || continue
		((count += 1))
		if ((count > BUZZ_BACKUP_RETAIN)); then
			rm -f -- "$path"
		fi
	done < <(printf '%s\n' "$BUZZ_BACKUP_DIR"/managed-agents.*.json | sort -r)
	return 0
}

_buzz_write_apply_manifest() {
	local destination="$1"
	local version="$2"
	local backup="$3"
	local filter=""
	filter=$(_buzz_target_filter)
	jq \
		--arg version "$version" \
		--arg store "$BUZZ_STORE_PATH" \
		--arg backup "$backup" \
		--arg applied_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
		"
		{
			schema: \"aidevops-buzz-opencode-acp-fix/v1\",
			app_version: \$version,
			store_path: \$store,
			backup_path: \$backup,
			applied_at: \$applied_at,
			records: [
				.[]
				| select(${filter})
				| select(((.agent_args // []) | length) == 0)
				| {pubkey: .pubkey, original_args: (.agent_args // [])}
			]
		}
		" "$BUZZ_STORE_PATH" >"$destination"
	chmod 600 "$destination"
	return 0
}

_buzz_write_applied_store() {
	local destination="$1"
	local filter=""
	filter=$(_buzz_target_filter)
	jq --arg acp "$BUZZ_ACP_ARG" "
		map(
			if (${filter}) and (((.agent_args // []) | length) == 0)
			then .agent_args = [\$acp]
			else .
			end
		)
	" "$BUZZ_STORE_PATH" >"$destination"
	chmod 600 "$destination"
	return 0
}

_buzz_apply_locked() {
	local version="$1"
	local eligible=""
	eligible=$(_buzz_eligible_count) || return 1
	if [[ "$eligible" -eq 0 ]]; then
		_buzz_info "Buzz OpenCode ACP compatibility fix is already applied or not needed"
		return 0
	fi

	_buzz_is_running && {
		print_warning "Buzz Desktop is running; close it and run: aidevops buzz apply"
		return 2
	}

	_buzz_create_backup || return 1
	local store_tmp=""
	local state_tmp=""
	store_tmp=$(mktemp "${BUZZ_STORE_PATH}.aidevops.XXXXXX")
	umask 077
	mkdir -p "$BUZZ_STATE_DIR"
	chmod 700 "$BUZZ_STATE_DIR"
	state_tmp=$(mktemp "${BUZZ_STATE_DIR}/buzz-opencode-acp-fix.XXXXXX")

	if ! _buzz_write_apply_manifest "$state_tmp" "$version" "$BUZZ_LAST_BACKUP" ||
		! _buzz_write_applied_store "$store_tmp"; then
		rm -f "$store_tmp" "$state_tmp"
		return 1
	fi
	if _buzz_is_running; then
		rm -f "$store_tmp" "$state_tmp"
		print_warning "Buzz Desktop started during reconciliation; no changes were applied"
		return 2
	fi
	if ! mv "$store_tmp" "$BUZZ_STORE_PATH"; then
		rm -f "$store_tmp" "$state_tmp"
		return 1
	fi
	if ! mv "$state_tmp" "$BUZZ_STATE_FILE"; then
		cp -p "$BUZZ_LAST_BACKUP" "$BUZZ_STORE_PATH"
		chmod 600 "$BUZZ_STORE_PATH"
		rm -f "$state_tmp"
		print_error "Could not persist Buzz rollback state; restored the original store"
		return 1
	fi
	_buzz_prune_backups
	_buzz_info "Applied OpenCode ACP compatibility to ${eligible} Buzz agent record(s)"
	return 0
}

cmd_apply() {
	[[ "$(_buzz_platform)" == "$BUZZ_PLATFORM_DARWIN" ]] || {
		_buzz_info "Buzz Desktop compatibility is macOS-only; no changes needed"
		return 0
	}
	local version=""
	version=$(_buzz_app_version) || {
		_buzz_info "Buzz Desktop is not installed; no changes needed"
		return 0
	}
	if ! _buzz_is_affected_version "$version"; then
		_buzz_info "Buzz Desktop ${version} is not in the verified affected-version registry"
		return 0
	fi
	[[ -f "$BUZZ_STATE_FILE" ]] && {
		_buzz_info "Buzz OpenCode ACP compatibility fix is already managed by aidevops"
		return 0
	}
	[[ -f "$BUZZ_STORE_PATH" ]] || {
		_buzz_info "Buzz has no managed-agent store yet; no changes needed"
		return 0
	}
	_buzz_validate_store || return 1
	_buzz_acquire_lock || return 1
	_buzz_apply_locked "$version"
	local rc=$?
	_buzz_release_lock
	return "$rc"
}

_buzz_validate_state() {
	_buzz_validate_private_file "$BUZZ_STATE_FILE" "Buzz compatibility state" || return 1
	jq -e \
		--arg store "$BUZZ_STORE_PATH" \
		'.schema == "aidevops-buzz-opencode-acp-fix/v1" and .store_path == $store and (.records | type == "array")' \
		"$BUZZ_STATE_FILE" >/dev/null 2>&1 || {
		print_error "Buzz compatibility state is malformed or belongs to another store"
		return 1
	}
	return 0
}

_buzz_managed_drift_count() {
	local filter=""
	filter=$(_buzz_target_filter)
	jq --slurpfile state "$BUZZ_STATE_FILE" "
		[
			.[] as \$record
			| select(\$record | ${filter})
			| select(((\$record.agent_args // []) | length) == 0)
			| select(([\$state[0].records[] | select(.pubkey == \$record.pubkey)] | length) > 0)
		] | length
	" "$BUZZ_STORE_PATH"
	return $?
}

_buzz_write_reconciled_store() {
	local destination="$1"
	local filter=""
	filter=$(_buzz_target_filter)
	jq --arg acp "$BUZZ_ACP_ARG" --slurpfile state "$BUZZ_STATE_FILE" "
		map(
			. as \$record
			| ([\$state[0].records[] | select(.pubkey == \$record.pubkey)] | first) as \$owned
			| if (\$owned != null) and (\$record | ${filter}) and
				(((\$record.agent_args // []) | length) == 0)
			  then .agent_args = [\$acp]
			  else .
			  end
		)
	" "$BUZZ_STORE_PATH" >"$destination"
	chmod 600 "$destination"
	return 0
}

_buzz_reconcile_managed_locked() {
	local drifted=""
	drifted=$(_buzz_managed_drift_count) || return 1
	if [[ "$drifted" -eq 0 ]]; then
		_buzz_info "Buzz OpenCode ACP compatibility fix remains managed"
		return 0
	fi
	if _buzz_is_running; then
		print_warning "Buzz Desktop is running; close it and run: aidevops buzz reconcile"
		return 2
	fi

	_buzz_create_backup || return 1
	local store_tmp=""
	store_tmp=$(mktemp "${BUZZ_STORE_PATH}.aidevops.XXXXXX")
	if ! _buzz_write_reconciled_store "$store_tmp"; then
		rm -f "$store_tmp"
		return 1
	fi
	if _buzz_is_running; then
		rm -f "$store_tmp"
		print_warning "Buzz Desktop started during reconciliation; no changes were applied"
		return 2
	fi
	mv "$store_tmp" "$BUZZ_STORE_PATH"
	_buzz_prune_backups
	_buzz_info "Reapplied OpenCode ACP compatibility to ${drifted} managed Buzz agent record(s)"
	return 0
}

_buzz_write_rollback_store() {
	local destination="$1"
	jq --arg acp "$BUZZ_ACP_ARG" --slurpfile state "$BUZZ_STATE_FILE" '
		map(
			. as $record
			| ([$state[0].records[] | select(.pubkey == $record.pubkey)] | first) as $owned
			| if ($owned != null and ((.agent_args // []) == [$acp]))
			  then .agent_args = $owned.original_args
			  else .
			  end
		)
	' "$BUZZ_STORE_PATH" >"$destination"
	chmod 600 "$destination"
	return 0
}

cmd_rollback() {
	[[ -f "$BUZZ_STATE_FILE" ]] || {
		_buzz_info "No aidevops-managed Buzz compatibility fix is recorded"
		return 0
	}
	_buzz_validate_store || return 1
	_buzz_validate_state || return 1
	_buzz_acquire_lock || return 1
	if _buzz_is_running; then
		_buzz_release_lock
		print_warning "Buzz Desktop is running; close it and run: aidevops buzz rollback"
		return 2
	fi
	local store_tmp=""
	store_tmp=$(mktemp "${BUZZ_STORE_PATH}.aidevops.XXXXXX")
	if ! _buzz_write_rollback_store "$store_tmp"; then
		rm -f "$store_tmp"
		_buzz_release_lock
		return 1
	fi
	if _buzz_is_running; then
		rm -f "$store_tmp"
		_buzz_release_lock
		print_warning "Buzz Desktop started during rollback; no changes were applied"
		return 2
	fi
	mv "$store_tmp" "$BUZZ_STORE_PATH"
	rm -f "$BUZZ_STATE_FILE"
	_buzz_release_lock
	_buzz_info "Rolled back aidevops-managed Buzz OpenCode ACP compatibility fields"
	return 0
}

cmd_status() {
	if [[ "$(_buzz_platform)" != "$BUZZ_PLATFORM_DARWIN" ]]; then
		printf 'Buzz Desktop compatibility: not applicable\n'
		return 0
	fi
	local version=""
	version=$(_buzz_app_version) || {
		printf 'Buzz Desktop compatibility: Buzz not installed\n'
		return 0
	}
	if [[ -f "$BUZZ_STATE_FILE" ]]; then
		_buzz_validate_store || return 1
		_buzz_validate_state || return 1
		local fixed=""
		fixed=$(_buzz_fixed_count) || return 1
		printf 'Buzz Desktop %s compatibility: managed (%s OpenCode record(s))\n' "$version" "$fixed"
		return 0
	fi
	if ! _buzz_is_affected_version "$version"; then
		printf 'Buzz Desktop %s compatibility: version not in affected registry\n' "$version"
		return 0
	fi
	[[ -f "$BUZZ_STORE_PATH" ]] || {
		printf 'Buzz Desktop %s compatibility: no managed agents\n' "$version"
		return 0
	}
	_buzz_validate_store || return 1
	local eligible=""
	eligible=$(_buzz_eligible_count) || return 1
	printf 'Buzz Desktop %s compatibility: %s OpenCode record(s) need remediation\n' "$version" "$eligible"
	return 0
}

cmd_reconcile() {
	[[ -f "$BUZZ_STATE_FILE" ]] || {
		cmd_apply
		return $?
	}
	[[ "$(_buzz_platform)" == "$BUZZ_PLATFORM_DARWIN" ]] || {
		_buzz_info "Buzz Desktop compatibility is macOS-only; no changes needed"
		return 0
	}
	local version=""
	version=$(_buzz_app_version) || {
		_buzz_info "Buzz Desktop is not installed; no changes needed"
		return 0
	}
	if ! _buzz_is_affected_version "$version"; then
		_buzz_info "Buzz Desktop ${version} is not in the verified affected-version registry"
		return 0
	fi
	_buzz_validate_store || return 1
	_buzz_validate_state || return 1
	_buzz_acquire_lock || return 1
	_buzz_reconcile_managed_locked
	local rc=$?
	_buzz_release_lock
	return "$rc"
}

show_help() {
	cat <<'EOF'
Usage: aidevops buzz <status|apply|rollback|reconcile> [--quiet]

Manage the reversible Buzz Desktop 0.5.4-0.5.5 OpenCode ACP compatibility fix.

Commands:
  status      Report whether the installed Buzz version/agents need remediation
  apply       Add the missing `acp` argument to eligible OpenCode agent records
  rollback    Restore only unchanged fields previously managed by aidevops
  reconcile   Idempotently apply the verified version-specific remediation

Buzz must be closed for apply or rollback. The helper never prints agent-store
contents and keeps private rollback state and bounded backups with mode 600.
EOF
	return 0
}

main() {
	local command="${1:-status}"
	shift || true
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--quiet) BUZZ_QUIET=true ;;
		-h | --help | help) command=help ;;
		*)
			print_error "Unknown option: $1"
			return 1
			;;
		esac
		shift
	done
	case "$command" in
	status) cmd_status ;;
	apply) cmd_apply ;;
	rollback) cmd_rollback ;;
	reconcile) cmd_reconcile ;;
	help | -h | --help) show_help ;;
	*)
		print_error "Unknown Buzz command: $command"
		show_help
		return 1
		;;
	esac
	return $?
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	main "$@"
fi

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
BUZZ_WRAPPER_PATH="${AIDEVOPS_BUZZ_WRAPPER_PATH:-${HOME}/.aidevops/bin/opencode-acp}"
BUZZ_BACKUP_RETAIN="${AIDEVOPS_BUZZ_BACKUP_RETAIN:-3}"
BUZZ_ACP_ARG="acp"
BUZZ_OPENCODE_NAME="opencode"
BUZZ_JSON_TYPE_ARRAY="array"
BUZZ_JSON_TYPE_STRING="string"
BUZZ_STATE_SCHEMA_V1="aidevops-buzz-opencode-acp-fix/v1"
BUZZ_STATE_SCHEMA_V2="aidevops-buzz-opencode-acp-fix/v2"
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

_buzz_validate_wrapper() {
	if [[ ! -f "$BUZZ_WRAPPER_PATH" || ! -x "$BUZZ_WRAPPER_PATH" ]]; then
		print_error "Buzz OpenCode ACP wrapper is missing or not executable; run aidevops update"
		return 1
	fi
	local owner=""
	owner=$(_file_owner "$BUZZ_WRAPPER_PATH")
	if [[ "$owner" != "$(id -un)" ]]; then
		print_error "Buzz OpenCode ACP wrapper is not owned by the current user"
		return 1
	fi
	return 0
}

_buzz_validate_store() {
	command -v jq >/dev/null 2>&1 || {
		print_error "jq is required for Buzz Desktop compatibility reconciliation"
		return 1
	}
	_buzz_validate_private_file "$BUZZ_STORE_PATH" "Buzz managed-agent store" || return 1
	jq -e --arg wrapper "$BUZZ_WRAPPER_PATH" \
		--arg opencode "$BUZZ_OPENCODE_NAME" \
		--arg array_type "$BUZZ_JSON_TYPE_ARRAY" \
		--arg string_type "$BUZZ_JSON_TYPE_STRING" '
		def is_array: type == $array_type;
		def is_string: type == $string_type;
		def command_basename:
			if is_string then (split("/") | last) else empty end;
		def recognized_original:
			([.agent_command, .agent_command_override]
				| map(command_basename)
				| any(. == $opencode));
		def structurally_managed:
			(recognized_original or (.agent_command_override == $wrapper)) and
			(((.agent_args // []) == []) or ((.agent_args // []) == ["acp"]));
		is_array and
		all(.[];
			type == "object" and
			((.agent_command == null) or (.agent_command | is_string)) and
			((.agent_command_override == null) or (.agent_command_override | is_string)) and
			((.agent_args == null) or
				((.agent_args | is_array) and all(.agent_args[]; is_string))) and
			((structurally_managed | not) or
				((.pubkey | is_string) and (.pubkey | length) > 0))
		)
	' "$BUZZ_STORE_PATH" >/dev/null 2>&1 || {
		print_error "Buzz managed-agent store has an invalid record schema"
		return 1
	}
	return 0
}

_buzz_original_target_filter() {
	printf '%s\n' '
    def command_basename:
      if type == "string" then (split("/") | last) else "" end;
    ([.agent_command, .agent_command_override] | map(command_basename) | any(. == "opencode"))
  '
	return 0
}

_buzz_eligible_count() {
	local filter=""
	filter=$(_buzz_original_target_filter)
	jq --arg acp "$BUZZ_ACP_ARG" "
		[
			.[]
			| select(${filter})
			| select(((.agent_args // []) == []) or ((.agent_args // []) == [\$acp]))
		] | length
	" "$BUZZ_STORE_PATH"
	return $?
}

_buzz_fixed_count() {
	jq --arg acp "$BUZZ_ACP_ARG" --arg wrapper "$BUZZ_WRAPPER_PATH" '
		[
			.[]
			| select(.agent_command_override == $wrapper)
			| select((.agent_args // []) == [$acp])
		] | length
	' "$BUZZ_STORE_PATH"
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
	filter=$(_buzz_original_target_filter)
	jq \
		--arg version "$version" \
		--arg store "$BUZZ_STORE_PATH" \
		--arg backup "$backup" \
		--arg wrapper "$BUZZ_WRAPPER_PATH" \
		--arg acp "$BUZZ_ACP_ARG" \
		--arg applied_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
		"
		{
			schema: \"${BUZZ_STATE_SCHEMA_V2}\",
			app_version: \$version,
			store_path: \$store,
			wrapper_path: \$wrapper,
			backup_path: \$backup,
			applied_at: \$applied_at,
			records: [
				.[]
				| select(${filter})
				| select(((.agent_args // []) == []) or ((.agent_args // []) == [\$acp]))
				| {
					pubkey: .pubkey,
					original_command_override_present: has(\"agent_command_override\"),
					original_command_override: (.agent_command_override // null),
					original_args_present: has(\"agent_args\"),
					original_args: (.agent_args // []),
					managed_command_override: \$wrapper,
					managed_args: [\$acp]
				  }
			]
		}
		" "$BUZZ_STORE_PATH" >"$destination"
	chmod 600 "$destination"
	return 0
}

_buzz_write_applied_store() {
	local destination="$1"
	local filter=""
	filter=$(_buzz_original_target_filter)
	jq --arg acp "$BUZZ_ACP_ARG" --arg wrapper "$BUZZ_WRAPPER_PATH" "
		map(
			if (${filter}) and
				(((.agent_args // []) == []) or ((.agent_args // []) == [\$acp]))
			then .agent_command_override = \$wrapper | .agent_args = [\$acp]
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
	[[ -f "$BUZZ_STATE_FILE" ]] && {
		_buzz_info "Buzz OpenCode ACP compatibility fix is already managed by aidevops"
		return 0
	}
	[[ -f "$BUZZ_STORE_PATH" ]] || {
		_buzz_info "Buzz has no managed-agent store yet; no changes needed"
		return 0
	}
	_buzz_validate_store || return 1
	_buzz_validate_wrapper || return 1
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
		--arg wrapper "$BUZZ_WRAPPER_PATH" \
		--arg v1 "$BUZZ_STATE_SCHEMA_V1" \
		--arg v2 "$BUZZ_STATE_SCHEMA_V2" \
		--arg array_type "$BUZZ_JSON_TYPE_ARRAY" \
		--arg string_type "$BUZZ_JSON_TYPE_STRING" '
		.store_path == $store and
		(.records | type == $array_type) and
		((.records | length) == ([.records[].pubkey] | unique | length)) and
		if .schema == $v1 then
			all(.records[];
				(.pubkey | type == $string_type) and (.pubkey | length > 0) and
				(.original_args | type == $array_type))
		elif .schema == $v2 then
			.wrapper_path == $wrapper and
			all(.records[];
				(.pubkey | type == $string_type) and (.pubkey | length > 0) and
				(.original_command_override_present | type == "boolean") and
				((.original_command_override == null) or
					(.original_command_override | type == $string_type)) and
				(.original_args_present | type == "boolean") and
				(.original_args | type == $array_type) and
				(.managed_command_override == $wrapper) and
				(.managed_args == ["acp"]))
		else false
		end' \
		"$BUZZ_STATE_FILE" >/dev/null 2>&1 || {
		print_error "Buzz compatibility state is malformed or belongs to another store"
		return 1
	}
	return 0
}

_buzz_state_schema() {
	jq -r '.schema' "$BUZZ_STATE_FILE"
	return $?
}

_buzz_migrate_state_v1_locked() {
	local version="$1"
	local schema=""
	schema=$(_buzz_state_schema) || return 1
	[[ "$schema" == "$BUZZ_STATE_SCHEMA_V1" ]] || return 0
	if _buzz_is_running; then
		print_warning "Buzz Desktop is running; close it and run: aidevops buzz reconcile"
		return 2
	fi
	local state_tmp=""
	state_tmp=$(mktemp "${BUZZ_STATE_DIR}/buzz-opencode-acp-fix.XXXXXX")
	if ! jq -e \
		--arg version "$version" \
		--arg wrapper "$BUZZ_WRAPPER_PATH" \
		--arg schema "$BUZZ_STATE_SCHEMA_V2" \
		--arg opencode "$BUZZ_OPENCODE_NAME" \
		--arg string_type "$BUZZ_JSON_TYPE_STRING" \
		--arg migrated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
		--slurpfile store "$BUZZ_STORE_PATH" '
		def command_basename:
			if type == $string_type then (split("/") | last) else empty end;
		def recognized_original:
			([.agent_command, .agent_command_override]
				| map(command_basename) | any(. == $opencode));
		.records as $legacy_records
		| ($legacy_records | map(
			. as $legacy
			| ([$store[0][] | select(.pubkey == $legacy.pubkey)] | first) as $live
			| select($live != null and ($live | recognized_original))
			| {
				pubkey: $legacy.pubkey,
				original_command_override_present: ($live | has("agent_command_override")),
				original_command_override: ($live.agent_command_override // null),
				original_args_present: true,
				original_args: $legacy.original_args,
				managed_command_override: $wrapper,
				managed_args: ["acp"]
			  }
		  )) as $migrated
		| if ($migrated | length) != ($legacy_records | length) then
			error("legacy Buzz state does not match the live structural schema")
		  else {
			schema: $schema,
			app_version: $version,
			store_path: .store_path,
			wrapper_path: $wrapper,
			backup_path: .backup_path,
			applied_at: .applied_at,
			migrated_at: $migrated_at,
			records: $migrated
		  } end' "$BUZZ_STATE_FILE" >"$state_tmp"; then
		rm -f "$state_tmp"
		print_error "Buzz compatibility state cannot be safely migrated"
		return 1
	fi
	chmod 600 "$state_tmp"
	if _buzz_is_running; then
		rm -f "$state_tmp"
		print_warning "Buzz Desktop started during state migration; no changes were applied"
		return 2
	fi
	mv "$state_tmp" "$BUZZ_STATE_FILE"
	_buzz_info "Migrated legacy Buzz compatibility state to structural ownership"
	return 0
}

_buzz_managed_drift_count() {
	jq --arg acp "$BUZZ_ACP_ARG" --arg wrapper "$BUZZ_WRAPPER_PATH" \
		--arg opencode "$BUZZ_OPENCODE_NAME" --arg string_type "$BUZZ_JSON_TYPE_STRING" \
		--slurpfile state "$BUZZ_STATE_FILE" '
		def command_basename:
			if type == $string_type then (split("/") | last) else empty end;
		def recognized_original:
			([.agent_command, .agent_command_override]
				| map(command_basename) | any(. == $opencode));
		[
			.[] as $record
			| ([$state[0].records[] | select(.pubkey == $record.pubkey)] | first) as $owned
			| select($owned != null)
			| select(
				(($record | recognized_original) and
					((($record.agent_args // []) == []) or
					 (($record.agent_args // []) == [$acp]))) or
				($record.agent_command_override == $wrapper and
					(($record.agent_args // []) == []))
			  )
		] | length
	' "$BUZZ_STORE_PATH"
	return $?
}

_buzz_write_reconciled_store() {
	local destination="$1"
	jq --arg acp "$BUZZ_ACP_ARG" --arg wrapper "$BUZZ_WRAPPER_PATH" \
		--arg opencode "$BUZZ_OPENCODE_NAME" --arg string_type "$BUZZ_JSON_TYPE_STRING" \
		--slurpfile state "$BUZZ_STATE_FILE" '
		def command_basename:
			if type == $string_type then (split("/") | last) else empty end;
		def recognized_original:
			([.agent_command, .agent_command_override]
				| map(command_basename) | any(. == $opencode));
		map(
			. as $record
			| ([$state[0].records[] | select(.pubkey == $record.pubkey)] | first) as $owned
			| if ($owned != null) and (
				(($record | recognized_original) and
					((($record.agent_args // []) == []) or
					 (($record.agent_args // []) == [$acp]))) or
				($record.agent_command_override == $wrapper and
					(($record.agent_args // []) == []))
			  )
			  then .agent_command_override = $wrapper | .agent_args = [$acp]
			  else .
			  end
		)
	' "$BUZZ_STORE_PATH" >"$destination"
	chmod 600 "$destination"
	return 0
}

_buzz_reconcile_managed_locked() {
	local version="$1"
	_buzz_migrate_state_v1_locked "$version" || return $?
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
	jq --arg acp "$BUZZ_ACP_ARG" --arg v1 "$BUZZ_STATE_SCHEMA_V1" \
		--slurpfile state "$BUZZ_STATE_FILE" '
		map(
			. as $record
			| ([$state[0].records[] | select(.pubkey == $record.pubkey)] | first) as $owned
			| if $state[0].schema == $v1 then
				if ($owned != null and ((.agent_args // []) == [$acp]))
				then .agent_args = $owned.original_args else . end
			  else
				(if ($owned != null and
					 .agent_command_override == $owned.managed_command_override)
				 then if $owned.original_command_override_present
					then .agent_command_override = $owned.original_command_override
					else del(.agent_command_override) end
				 else . end)
				| (if ($owned != null and (.agent_args // []) == $owned.managed_args)
				   then if $owned.original_args_present
					then .agent_args = $owned.original_args
					else del(.agent_args) end
				   else . end)
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
		local drifted=""
		fixed=$(_buzz_fixed_count) || return 1
		drifted=$(_buzz_managed_drift_count) || return 1
		printf 'Buzz Desktop %s compatibility: managed (%s OpenCode record(s), %s need reconciliation)\n' \
			"$version" "$fixed" "$drifted"
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
	_buzz_validate_store || return 1
	_buzz_validate_wrapper || return 1
	_buzz_validate_state || return 1
	_buzz_acquire_lock || return 1
	_buzz_reconcile_managed_locked "$version"
	local rc=$?
	_buzz_release_lock
	return "$rc"
}

show_help() {
	cat <<'EOF'
Usage: aidevops buzz <status|apply|rollback|reconcile> [--quiet]

Manage a reversible, structurally validated Buzz Desktop OpenCode ACP compatibility fix.

Commands:
  status      Report whether the installed Buzz version/agents need remediation
  apply       Route eligible OpenCode records through the stable ACP wrapper
  rollback    Restore only unchanged fields previously managed by aidevops
  reconcile   Idempotently repair structurally recognized managed drift

Buzz must be closed for apply, reconcile, or rollback. The helper never prints agent-store
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

#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Explicit, audited rollback for retained immutable runtime bundles.

set -euo pipefail

_RUNTIME_BUNDLE_ROLLBACK_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly _RUNTIME_BUNDLE_VALUE_UNKNOWN="unknown"
readonly _RUNTIME_BUNDLE_STATE_ABSENT="absent"
_RUNTIME_BUNDLE_LAST_ERROR=""
_RUNTIME_BUNDLE_VALIDATED_ROOT=""
_RUNTIME_BUNDLE_VALIDATED_ID=""
_RUNTIME_BUNDLE_VALIDATED_VERSION=""
_RUNTIME_BUNDLE_VALIDATED_SHA=""
_RUNTIME_BUNDLE_META_ID="$_RUNTIME_BUNDLE_VALUE_UNKNOWN"
_RUNTIME_BUNDLE_META_VERSION="$_RUNTIME_BUNDLE_VALUE_UNKNOWN"
_RUNTIME_BUNDLE_META_SHA="$_RUNTIME_BUNDLE_VALUE_UNKNOWN"
_RUNTIME_BUNDLE_PREVIOUS_STATE="$_RUNTIME_BUNDLE_STATE_ABSENT"
_RUNTIME_BUNDLE_PREVIOUS_TARGET=""
_RUNTIME_BUNDLE_STAMP_STATE="$_RUNTIME_BUNDLE_STATE_ABSENT"
_RUNTIME_BUNDLE_STAMP_VALUE=""
_RUNTIME_BUNDLE_RESTORE_ACTIVE_ROOT=""
_RUNTIME_BUNDLE_RESTORE_PREVIOUS_LINK=""
_RUNTIME_BUNDLE_RESTORE_STAMP_FILE=""
_RUNTIME_BUNDLE_TRANSACTION_MUTATED=false

_runtime_bundle_rollback_error() {
	local message="$1"
	printf 'ERROR: %s\n' "$message" >&2
	return 0
}

_runtime_bundle_rollback_info() {
	local message="$1"
	printf '%s\n' "$message"
	return 0
}

_runtime_bundle_rollback_load_dependencies() {
	local runtime_helper="${_RUNTIME_BUNDLE_ROLLBACK_SCRIPT_DIR}/setup/modules/agent-runtime.sh"
	local verifier="${_RUNTIME_BUNDLE_ROLLBACK_SCRIPT_DIR}/runtime-bundle-verifier.sh"

	if ! declare -F aidevops_runtime_transition_lock_acquire >/dev/null 2>&1; then
		[[ -r "$runtime_helper" ]] || {
			_runtime_bundle_rollback_error "Runtime transition helper is unavailable"
			return 1
		}
		# shellcheck source=setup/modules/agent-runtime.sh
		# shellcheck disable=SC1090
		source "$runtime_helper"
	fi
	if ! declare -F _runtime_bundle_verify_manifest_value >/dev/null 2>&1; then
		[[ -r "$verifier" ]] || {
			_runtime_bundle_rollback_error "Runtime bundle verifier is unavailable"
			return 1
		}
		# shellcheck source=runtime-bundle-verifier.sh
		# shellcheck disable=SC1090
		source "$verifier"
	fi
	return 0
}

_runtime_bundle_managed_root() {
	local bundles_root="${HOME:?HOME must be set}/.aidevops/runtime-bundles"
	[[ -d "$bundles_root" ]] || return 1
	(cd "$bundles_root" && pwd -P) || return 1
	return 0
}

_runtime_bundle_active_link() {
	printf '%s\n' "${HOME:?HOME must be set}/.aidevops/agents"
	return 0
}

_runtime_bundle_previous_link() {
	printf '%s\n' "${HOME:?HOME must be set}/.aidevops/previous-runtime-bundle"
	return 0
}

_runtime_bundle_stamp_file() {
	printf '%s\n' "${HOME:?HOME must be set}/.aidevops/.deployed-sha"
	return 0
}

_runtime_bundle_repo_dir() {
	local repo_dir="${AIDEVOPS_INSTALL_DIR:-${HOME:?HOME must be set}/Git/aidevops}"
	[[ -d "$repo_dir/.git" ]] || return 1
	(cd "$repo_dir" && pwd -P) || return 1
	return 0
}

_runtime_bundle_validate_id() {
	local bundle_id="$1"
	case "$bundle_id" in
	'' | '.' | '..' | .* | *[!A-Za-z0-9._-]*) return 1 ;;
	esac
	return 0
}

_runtime_bundle_one_line() {
	local value="$1"
	local max_length="${2:-512}"
	value=${value//$'\n'/ }
	value=${value//$'\r'/ }
	value=${value//$'\t'/ }
	printf '%s' "${value:0:$max_length}"
	return 0
}

_runtime_bundle_reset_metadata() {
	_RUNTIME_BUNDLE_META_ID="$_RUNTIME_BUNDLE_VALUE_UNKNOWN"
	_RUNTIME_BUNDLE_META_VERSION="$_RUNTIME_BUNDLE_VALUE_UNKNOWN"
	_RUNTIME_BUNDLE_META_SHA="$_RUNTIME_BUNDLE_VALUE_UNKNOWN"
	return 0
}

_runtime_bundle_read_metadata() {
	local agents_root="$1"
	local manifest_file="$agents_root/.bundle-manifest"
	local bundle_dir="${agents_root%/agents}"
	local bundle_id="${bundle_dir##*/}"

	_runtime_bundle_reset_metadata
	_RUNTIME_BUNDLE_META_ID="$bundle_id"
	[[ -f "$manifest_file" && ! -L "$manifest_file" ]] || return 1
	_RUNTIME_BUNDLE_META_ID=$(_runtime_bundle_verify_manifest_value "$manifest_file" bundle_id 2>/dev/null || printf '%s' "$bundle_id")
	_RUNTIME_BUNDLE_META_VERSION=$(_runtime_bundle_verify_manifest_value "$manifest_file" framework_version 2>/dev/null || printf '%s' 'unknown')
	_RUNTIME_BUNDLE_META_SHA=$(_runtime_bundle_verify_manifest_value "$manifest_file" git_sha 2>/dev/null || printf '%s' 'unknown')
	return 0
}

_runtime_bundle_resolve_managed_link() {
	local link_path="$1"
	local bundles_root="$2"
	local resolved_root=""

	[[ -L "$link_path" && -d "$link_path" ]] || return 1
	resolved_root=$(cd "$link_path" 2>/dev/null && pwd -P) || return 1
	case "$resolved_root" in
	"$bundles_root"/*/agents) printf '%s\n' "$resolved_root" ;;
	*) return 1 ;;
	esac
	return 0
}

_runtime_bundle_inventory_metadata() {
	local bundle_dir="$1"
	local bundles_root="$2"
	local bundle_id="${bundle_dir##*/}"
	local agents_root="$bundle_dir/agents"
	local manifest_file="$bundle_dir/manifest"
	local inner_manifest="$agents_root/.bundle-manifest"
	local status=""
	local manifest_id=""

	_runtime_bundle_validate_id "$bundle_id" || return 1
	[[ "$bundle_dir" == "$bundles_root/$bundle_id" && -d "$bundle_dir" && ! -L "$bundle_dir" ]] || return 1
	[[ -d "$agents_root" && ! -L "$agents_root" ]] || return 1
	[[ -f "$manifest_file" && ! -L "$manifest_file" && -f "$inner_manifest" && ! -L "$inner_manifest" ]] || return 1
	cmp -s "$manifest_file" "$inner_manifest" || return 1
	status=$(_runtime_bundle_verify_manifest_value "$manifest_file" status 2>/dev/null || true)
	manifest_id=$(_runtime_bundle_verify_manifest_value "$manifest_file" bundle_id 2>/dev/null || true)
	[[ "$status" == "validated" && "$manifest_id" == "$bundle_id" ]] || return 1
	_runtime_bundle_read_metadata "$agents_root" || return 1
	return 0
}

_runtime_bundle_validate_plugin_integrity() {
	local agents_root="$1"
	local manifest_file="$2"
	local plugin_sha=""
	local actual_plugin_sha=""

	plugin_sha=$(_runtime_bundle_verify_manifest_value "$manifest_file" plugin_entry_sha256 2>/dev/null || printf '%s' 'missing')
	if [[ "$plugin_sha" == "missing" ]]; then
		if [[ -e "$agents_root/plugins/opencode-aidevops/index.mjs" ]]; then
			_RUNTIME_BUNDLE_LAST_ERROR="target plugin exists without manifest integrity evidence"
			return 1
		fi
		return 0
	fi
	actual_plugin_sha=$(_runtime_bundle_verify_sha256_file "$agents_root/plugins/opencode-aidevops/index.mjs" 2>/dev/null || true)
	if [[ -z "$actual_plugin_sha" || "$actual_plugin_sha" != "$plugin_sha" ]]; then
		_RUNTIME_BUNDLE_LAST_ERROR="target plugin integrity verification failed"
		return 1
	fi
	return 0
}

_runtime_bundle_validate_bundle() {
	local bundle_id="$1"
	local repo_dir="$2"
	local bundles_root=""
	local bundle_dir=""
	local agents_root=""
	local resolved_root=""
	local manifest_file=""
	local inner_manifest=""
	local status=""
	local manifest_id=""
	local version=""
	local git_sha=""
	local source_version=""
	local active_version=""

	_RUNTIME_BUNDLE_LAST_ERROR=""
	_RUNTIME_BUNDLE_VALIDATED_ROOT=""
	_RUNTIME_BUNDLE_VALIDATED_ID=""
	_RUNTIME_BUNDLE_VALIDATED_VERSION=""
	_RUNTIME_BUNDLE_VALIDATED_SHA=""
	if ! _runtime_bundle_validate_id "$bundle_id"; then
		_RUNTIME_BUNDLE_LAST_ERROR="target bundle ID is invalid"
		return 1
	fi
	bundles_root=$(_runtime_bundle_managed_root) || {
		_RUNTIME_BUNDLE_LAST_ERROR="managed runtime-bundles root is unavailable"
		return 1
	}
	bundle_dir="$bundles_root/$bundle_id"
	agents_root="$bundle_dir/agents"
	manifest_file="$bundle_dir/manifest"
	inner_manifest="$agents_root/.bundle-manifest"
	if [[ ! -d "$bundle_dir" || -L "$bundle_dir" || ! -d "$agents_root" || -L "$agents_root" ]]; then
		_RUNTIME_BUNDLE_LAST_ERROR="target is not a retained managed runtime bundle"
		return 1
	fi
	resolved_root=$(cd "$agents_root" 2>/dev/null && pwd -P) || {
		_RUNTIME_BUNDLE_LAST_ERROR="target agents root cannot be resolved"
		return 1
	}
	if [[ "$resolved_root" != "$agents_root" ]]; then
		_RUNTIME_BUNDLE_LAST_ERROR="target agents root escapes its managed bundle directory"
		return 1
	fi
	if [[ ! -f "$manifest_file" || -L "$manifest_file" || ! -f "$inner_manifest" || -L "$inner_manifest" ]] ||
		! cmp -s "$manifest_file" "$inner_manifest"; then
		_RUNTIME_BUNDLE_LAST_ERROR="target bundle manifests are missing or inconsistent"
		return 1
	fi
	status=$(_runtime_bundle_verify_manifest_value "$manifest_file" status 2>/dev/null || true)
	manifest_id=$(_runtime_bundle_verify_manifest_value "$manifest_file" bundle_id 2>/dev/null || true)
	version=$(_runtime_bundle_verify_manifest_value "$manifest_file" framework_version 2>/dev/null || true)
	git_sha=$(_runtime_bundle_verify_manifest_value "$manifest_file" git_sha 2>/dev/null || true)
	if [[ "$status" != "validated" || "$manifest_id" != "$bundle_id" || -z "$version" ]]; then
		_RUNTIME_BUNDLE_LAST_ERROR="target manifest is not validated for bundle ID $bundle_id"
		return 1
	fi
	if [[ ! "$git_sha" =~ ^[0-9a-f]{40,64}$ ]]; then
		_RUNTIME_BUNDLE_LAST_ERROR="target manifest Git SHA is invalid"
		return 1
	fi
	if [[ ! -x "$agents_root/aidevops.sh" || -L "$agents_root/aidevops.sh" ||
		! -f "$agents_root/VERSION" || -L "$agents_root/VERSION" ||
		! -d "$agents_root/scripts" || -L "$agents_root/scripts" ]]; then
		_RUNTIME_BUNDLE_LAST_ERROR="target runtime tree is incomplete or contains unsafe links"
		return 1
	fi
	git -C "$repo_dir" cat-file -e "${git_sha}^{commit}" 2>/dev/null || {
		_RUNTIME_BUNDLE_LAST_ERROR="target source commit is unavailable for integrity verification"
		return 1
	}
	if ! _runtime_bundle_verify_manifest "$agents_root" "$git_sha" >/dev/null 2>&1; then
		_RUNTIME_BUNDLE_LAST_ERROR="target manifest failed the runtime integrity verifier"
		return 1
	fi
	source_version=$(git -C "$repo_dir" show "${git_sha}:VERSION" 2>/dev/null || true)
	active_version=$(_runtime_bundle_verify_first_line "$agents_root/VERSION" 2>/dev/null || true)
	if [[ -z "$source_version" || "$source_version" != "$version" || "$active_version" != "$version" ]]; then
		_RUNTIME_BUNDLE_LAST_ERROR="target version does not match its manifest and source commit"
		return 1
	fi
	if ! _runtime_bundle_verify_sentinels "$repo_dir" "$git_sha" "$agents_root" >/dev/null 2>&1; then
		_RUNTIME_BUNDLE_LAST_ERROR="target runtime sentinel integrity verification failed"
		return 1
	fi
	_runtime_bundle_validate_plugin_integrity "$agents_root" "$manifest_file" || return 1
	_RUNTIME_BUNDLE_VALIDATED_ROOT="$agents_root"
	_RUNTIME_BUNDLE_VALIDATED_ID="$bundle_id"
	_RUNTIME_BUNDLE_VALIDATED_VERSION="$version"
	_RUNTIME_BUNDLE_VALIDATED_SHA="$git_sha"
	return 0
}

_runtime_bundle_audit_file() {
	printf '%s\n' "${HOME:?HOME must be set}/.aidevops/logs/runtime-bundle-rollback-audit.jsonl"
	return 0
}

_runtime_bundle_audit_preflight() {
	local audit_helper="${_RUNTIME_BUNDLE_ROLLBACK_SCRIPT_DIR}/audit-log-helper.sh"
	local audit_file=""
	[[ -f "$audit_helper" ]] || return 1
	audit_file=$(_runtime_bundle_audit_file)
	AUDIT_LOG_FILE="$audit_file" bash "$audit_helper" verify --quiet >/dev/null 2>&1
	return $?
}

_runtime_bundle_audit_event() {
	local outcome="$1"
	local reason="$2"
	local source_id="$3"
	local source_version="$4"
	local source_sha="$5"
	local target_id="$6"
	local target_version="$7"
	local target_sha="$8"
	local failure="$9"
	local mode="${10}"
	local audit_helper="${_RUNTIME_BUNDLE_ROLLBACK_SCRIPT_DIR}/audit-log-helper.sh"
	local audit_file=""
	local event_type="operation.block"
	local message="Runtime bundle rollback blocked"

	[[ -f "$audit_helper" ]] || return 1
	audit_file=$(_runtime_bundle_audit_file)
	if [[ "$outcome" == "allowed" ]]; then
		event_type="operation.verify"
		message="Runtime bundle rollback completed"
	fi
	reason=$(_runtime_bundle_one_line "$reason")
	failure=$(_runtime_bundle_one_line "$failure")
	source_id=$(_runtime_bundle_one_line "$source_id" 256)
	target_id=$(_runtime_bundle_one_line "$target_id" 256)
	AUDIT_LOG_FILE="$audit_file" bash "$audit_helper" verify --quiet >/dev/null 2>&1 || return 1
	AUDIT_LOG_FILE="$audit_file" AUDIT_QUIET=true bash "$audit_helper" log "$event_type" "$message" \
		--detail "operation=runtime-bundle-rollback" \
		--detail "outcome=$outcome" \
		--detail "mode=$mode" \
		--detail "reason=$reason" \
		--detail "source_bundle_id=$source_id" \
		--detail "source_version=$source_version" \
		--detail "source_git_sha=$source_sha" \
		--detail "target_bundle_id=$target_id" \
		--detail "target_version=$target_version" \
		--detail "target_git_sha=$target_sha" \
		--detail "failure=${failure:-none}" >/dev/null 2>&1 || return 1
	return 0
}

_runtime_bundle_current_metadata() {
	local bundles_root=""
	local active_link=""
	local active_root=""

	_runtime_bundle_reset_metadata
	bundles_root=$(_runtime_bundle_managed_root 2>/dev/null) || return 1
	active_link=$(_runtime_bundle_active_link)
	active_root=$(_runtime_bundle_resolve_managed_link "$active_link" "$bundles_root" 2>/dev/null) || return 1
	_runtime_bundle_read_metadata "$active_root" || return 1
	return 0
}

_runtime_bundle_capture_previous_link() {
	local previous_link="$1"
	_RUNTIME_BUNDLE_PREVIOUS_STATE="$_RUNTIME_BUNDLE_STATE_ABSENT"
	_RUNTIME_BUNDLE_PREVIOUS_TARGET=""
	if [[ -L "$previous_link" ]]; then
		_RUNTIME_BUNDLE_PREVIOUS_STATE="symlink"
		_RUNTIME_BUNDLE_PREVIOUS_TARGET=$(readlink "$previous_link") || return 1
	elif [[ -e "$previous_link" ]]; then
		_RUNTIME_BUNDLE_LAST_ERROR="previous-runtime-bundle is not a symlink"
		return 1
	fi
	return 0
}

_runtime_bundle_capture_stamp() {
	local stamp_file="$1"
	_RUNTIME_BUNDLE_STAMP_STATE="$_RUNTIME_BUNDLE_STATE_ABSENT"
	_RUNTIME_BUNDLE_STAMP_VALUE=""
	if [[ -L "$stamp_file" || -d "$stamp_file" ]]; then
		_RUNTIME_BUNDLE_LAST_ERROR="deployed SHA stamp is not a regular file"
		return 1
	fi
	if [[ -f "$stamp_file" ]]; then
		_RUNTIME_BUNDLE_STAMP_STATE="file"
		IFS= read -r _RUNTIME_BUNDLE_STAMP_VALUE <"$stamp_file" || _RUNTIME_BUNDLE_STAMP_VALUE=""
	fi
	return 0
}

_runtime_bundle_write_stamp() {
	local stamp_file="$1"
	local git_sha="$2"
	local stamp_tmp=""

	mkdir -p "${stamp_file%/*}" || return 1
	stamp_tmp=$(mktemp "${stamp_file}.tmp.XXXXXX") || return 1
	if ! printf '%s\n' "$git_sha" >"$stamp_tmp" || ! chmod 600 "$stamp_tmp" || ! mv -f "$stamp_tmp" "$stamp_file"; then
		rm -f "$stamp_tmp"
		return 1
	fi
	return 0
}

_runtime_bundle_restore_previous_link() {
	local previous_link="$1"
	case "$_RUNTIME_BUNDLE_PREVIOUS_STATE" in
	absent)
		rm -f "$previous_link"
		;;
	symlink)
		aidevops_runtime_switch_link "$previous_link" "$_RUNTIME_BUNDLE_PREVIOUS_TARGET" || return 1
		;;
	*) return 1 ;;
	esac
	return 0
}

_runtime_bundle_restore_stamp() {
	local stamp_file="$1"
	case "$_RUNTIME_BUNDLE_STAMP_STATE" in
	absent) rm -f "$stamp_file" ;;
	file) _runtime_bundle_write_stamp "$stamp_file" "$_RUNTIME_BUNDLE_STAMP_VALUE" || return 1 ;;
	*) return 1 ;;
	esac
	return 0
}

_runtime_bundle_restore_transaction() {
	local restore_failed=0

	aidevops_runtime_switch_link "$(_runtime_bundle_active_link)" "$_RUNTIME_BUNDLE_RESTORE_ACTIVE_ROOT" || restore_failed=1
	_runtime_bundle_restore_previous_link "$_RUNTIME_BUNDLE_RESTORE_PREVIOUS_LINK" || restore_failed=1
	_runtime_bundle_restore_stamp "$_RUNTIME_BUNDLE_RESTORE_STAMP_FILE" || restore_failed=1
	[[ "$restore_failed" -eq 0 ]] || return 1
	return 0
}

_runtime_bundle_exit_cleanup() {
	local exit_code=$?
	if [[ "$_RUNTIME_BUNDLE_TRANSACTION_MUTATED" == "true" ]]; then
		_runtime_bundle_restore_transaction >/dev/null 2>&1 || true
	fi
	aidevops_runtime_transition_lock_release >/dev/null 2>&1 || true
	return "$exit_code"
}

_runtime_bundle_post_switch_verify() {
	local target_id="$1"
	local target_root="$2"
	local source_root="$3"
	local target_sha="$4"
	local repo_dir="$5"
	local bundles_root=""
	local active_root=""
	local previous_root=""
	local deployed_sha=""

	if [[ "${AIDEVOPS_RUNTIME_BUNDLE_ROLLBACK_FAIL_AT:-}" == "post-switch-verification" ]]; then
		_RUNTIME_BUNDLE_LAST_ERROR="injected post-switch verification failure"
		return 1
	fi
	bundles_root=$(_runtime_bundle_managed_root) || return 1
	active_root=$(_runtime_bundle_resolve_managed_link "$(_runtime_bundle_active_link)" "$bundles_root" 2>/dev/null || true)
	previous_root=$(_runtime_bundle_resolve_managed_link "$(_runtime_bundle_previous_link)" "$bundles_root" 2>/dev/null || true)
	IFS= read -r deployed_sha <"$(_runtime_bundle_stamp_file)" || deployed_sha=""
	if [[ "$active_root" != "$target_root" || "$previous_root" != "$source_root" || "$deployed_sha" != "$target_sha" ]]; then
		_RUNTIME_BUNDLE_LAST_ERROR="post-switch link or deployed SHA verification failed"
		return 1
	fi
	_runtime_bundle_validate_bundle "$target_id" "$repo_dir" || return 1
	return 0
}

_runtime_bundle_rollback_blocked() {
	local reason="$1"
	local target_id="$2"
	local failure="$3"
	local mode="$4"
	local source_id="$_RUNTIME_BUNDLE_VALUE_UNKNOWN"
	local source_version="$_RUNTIME_BUNDLE_VALUE_UNKNOWN"
	local source_sha="$_RUNTIME_BUNDLE_VALUE_UNKNOWN"
	local target_version="$_RUNTIME_BUNDLE_VALUE_UNKNOWN"
	local target_sha="$_RUNTIME_BUNDLE_VALUE_UNKNOWN"
	local bundles_root=""
	local target_root=""

	if _runtime_bundle_current_metadata; then
		source_id="$_RUNTIME_BUNDLE_META_ID"
		source_version="$_RUNTIME_BUNDLE_META_VERSION"
		source_sha="$_RUNTIME_BUNDLE_META_SHA"
	fi
	if _runtime_bundle_validate_id "$target_id" && bundles_root=$(_runtime_bundle_managed_root 2>/dev/null); then
		target_root="$bundles_root/$target_id/agents"
		if _runtime_bundle_read_metadata "$target_root"; then
			target_version="$_RUNTIME_BUNDLE_META_VERSION"
			target_sha="$_RUNTIME_BUNDLE_META_SHA"
		fi
	fi
	if ! _runtime_bundle_audit_event blocked "${reason:-missing}" \
		"$source_id" "$source_version" "$source_sha" \
		"${target_id:-missing}" "$target_version" "$target_sha" "$failure" "$mode"; then
		_runtime_bundle_rollback_error "Rollback was blocked, but its audit event could not be written"
	fi
	_runtime_bundle_rollback_error "$failure"
	return 1
}

_runtime_bundle_apply_transition() {
	local active_link="$1"
	local previous_link="$2"
	local stamp_file="$3"
	local source_root="$4"
	local source_id="$5"
	local source_version="$6"
	local source_sha="$7"
	local target_root="$8"
	local target_id="$9"
	local target_version="${10}"
	local target_sha="${11}"
	local repo_dir="${12}"
	local reason="${13}"
	local mode="${14}"

	_RUNTIME_BUNDLE_RESTORE_ACTIVE_ROOT="$source_root"
	_RUNTIME_BUNDLE_RESTORE_PREVIOUS_LINK="$previous_link"
	_RUNTIME_BUNDLE_RESTORE_STAMP_FILE="$stamp_file"
	if ! aidevops_runtime_switch_link "$active_link" "$target_root"; then
		_RUNTIME_BUNDLE_LAST_ERROR="failed to atomically switch the active runtime link"
		return 1
	fi
	_RUNTIME_BUNDLE_TRANSACTION_MUTATED=true
	if [[ "${AIDEVOPS_RUNTIME_BUNDLE_ROLLBACK_FAIL_AT:-}" == "after-active-switch" ]]; then
		_RUNTIME_BUNDLE_LAST_ERROR="injected failure after active runtime switch"
		return 1
	fi
	if ! aidevops_runtime_switch_link "$previous_link" "$source_root"; then
		_RUNTIME_BUNDLE_LAST_ERROR="failed to atomically update the previous-runtime link"
		return 1
	fi
	if ! _runtime_bundle_write_stamp "$stamp_file" "$target_sha"; then
		_RUNTIME_BUNDLE_LAST_ERROR="failed to update the deployed SHA stamp"
		return 1
	fi
	_runtime_bundle_post_switch_verify \
		"$target_id" "$target_root" "$source_root" "$target_sha" "$repo_dir" || return 1
	if ! _runtime_bundle_audit_event allowed "$reason" \
		"$source_id" "$source_version" "$source_sha" \
		"$target_id" "$target_version" "$target_sha" "none" "$mode"; then
		_RUNTIME_BUNDLE_LAST_ERROR="successful transition could not be recorded in the tamper-evident audit log"
		return 1
	fi
	return 0
}

_runtime_bundle_report_transition_failure() {
	local transition_error="$1"
	local reason="$2"
	local source_id="$3"
	local source_version="$4"
	local source_sha="$5"
	local target_id="$6"
	local target_version="$7"
	local target_sha="$8"
	local mode="$9"
	local restore_note=""

	if [[ "$_RUNTIME_BUNDLE_TRANSACTION_MUTATED" == "true" ]]; then
		if _runtime_bundle_restore_transaction; then
			restore_note="; captured active runtime restored"
			_RUNTIME_BUNDLE_TRANSACTION_MUTATED=false
		else
			restore_note="; CRITICAL: automatic restoration failed"
		fi
	fi
	aidevops_runtime_transition_lock_release
	trap - EXIT
	_runtime_bundle_audit_event blocked "$reason" \
		"${source_id:-unknown}" "${source_version:-unknown}" "${source_sha:-unknown}" \
		"$target_id" "${target_version:-unknown}" "${target_sha:-unknown}" \
		"${transition_error}${restore_note}" "$mode" >/dev/null 2>&1 || true
	_runtime_bundle_rollback_error "Runtime bundle rollback failed: ${transition_error}${restore_note}"
	return 1
}

_runtime_bundle_rollback_execute() {
	local target_id="$1"
	local reason="$2"
	local mode="$3"
	local repo_dir=""
	local bundles_root=""
	local active_link=""
	local previous_link=""
	local stamp_file=""
	local source_root=""
	local source_id=""
	local source_version=""
	local source_sha=""
	local target_root=""
	local target_version=""
	local target_sha=""
	local transition_error=""

	if ! _runtime_bundle_validate_id "$target_id"; then
		_runtime_bundle_rollback_blocked "$reason" "$target_id" "A retained bundle ID is required; filesystem paths are not accepted" "$mode"
		return 1
	fi
	if [[ -z "$reason" || ! "$reason" =~ [^[:space:]] ]]; then
		_runtime_bundle_rollback_blocked "missing" "$target_id" "A non-empty rollback reason is required" "$mode"
		return 1
	fi
	repo_dir=$(_runtime_bundle_repo_dir 2>/dev/null) || {
		_runtime_bundle_rollback_blocked "$reason" "$target_id" "The aidevops source repository is unavailable for integrity verification" "$mode"
		return 1
	}
	if ! _runtime_bundle_audit_preflight; then
		_runtime_bundle_rollback_error "Tamper-evident rollback audit logging is unavailable"
		return 1
	fi
	if ! aidevops_runtime_transition_lock_acquire; then
		_runtime_bundle_rollback_blocked "$reason" "$target_id" "Unable to acquire the runtime activation lock" "$mode"
		return 1
	fi
	trap _runtime_bundle_exit_cleanup EXIT
	bundles_root=$(_runtime_bundle_managed_root) || transition_error="managed runtime-bundles root is unavailable"
	active_link=$(_runtime_bundle_active_link)
	previous_link=$(_runtime_bundle_previous_link)
	stamp_file=$(_runtime_bundle_stamp_file)
	if [[ -z "$transition_error" ]]; then
		source_root=$(_runtime_bundle_resolve_managed_link "$active_link" "$bundles_root" 2>/dev/null || true)
		[[ -n "$source_root" ]] || transition_error="active runtime is not a managed atomic bundle link"
	fi
	if [[ -z "$transition_error" ]]; then
		source_id="${source_root%/agents}"
		source_id="${source_id##*/}"
		if ! _runtime_bundle_validate_bundle "$source_id" "$repo_dir"; then
			transition_error="active runtime cannot be used as a verified restoration point: $_RUNTIME_BUNDLE_LAST_ERROR"
		else
			source_version="$_RUNTIME_BUNDLE_VALIDATED_VERSION"
			source_sha="$_RUNTIME_BUNDLE_VALIDATED_SHA"
		fi
	fi
	if [[ -z "$transition_error" ]]; then
		if ! _runtime_bundle_validate_bundle "$target_id" "$repo_dir"; then
			transition_error="$_RUNTIME_BUNDLE_LAST_ERROR"
		else
			target_root="$_RUNTIME_BUNDLE_VALIDATED_ROOT"
			target_version="$_RUNTIME_BUNDLE_VALIDATED_VERSION"
			target_sha="$_RUNTIME_BUNDLE_VALIDATED_SHA"
		fi
	fi
	if [[ -z "$transition_error" && "$target_root" == "$source_root" ]]; then
		transition_error="target bundle is already active"
	fi
	if [[ -z "$transition_error" ]] && ! _runtime_bundle_capture_previous_link "$previous_link"; then
		transition_error="$_RUNTIME_BUNDLE_LAST_ERROR"
	fi
	if [[ -z "$transition_error" ]] && ! _runtime_bundle_capture_stamp "$stamp_file"; then
		transition_error="$_RUNTIME_BUNDLE_LAST_ERROR"
	fi

	if [[ -z "$transition_error" ]] && ! _runtime_bundle_apply_transition \
		"$active_link" "$previous_link" "$stamp_file" \
		"$source_root" "$source_id" "$source_version" "$source_sha" \
		"$target_root" "$target_id" "$target_version" "$target_sha" \
		"$repo_dir" "$reason" "$mode"; then
		transition_error="${_RUNTIME_BUNDLE_LAST_ERROR:-runtime transition failed}"
	fi

	if [[ -n "$transition_error" ]]; then
		_runtime_bundle_report_transition_failure "$transition_error" "$reason" \
			"$source_id" "$source_version" "$source_sha" \
			"$target_id" "$target_version" "$target_sha" "$mode"
		return 1
	fi

	_RUNTIME_BUNDLE_TRANSACTION_MUTATED=false
	aidevops_runtime_transition_lock_release
	trap - EXIT
	_runtime_bundle_rollback_info "Rolled back the active runtime bundle from $source_id ($source_version) to $target_id ($target_version)."
	_runtime_bundle_rollback_info "Reason: $(_runtime_bundle_one_line "$reason")"
	return 0
}

_runtime_bundle_rollback_usage() {
	cat <<'EOF'
Usage:
  aidevops runtime-bundle status
  aidevops runtime-bundle list
  aidevops runtime-bundle rollback --bundle-id <id> --reason <text>

Commands:
  status     Show active, previous, and retained validated runtime bundles
  list       List retained validated bundle IDs and integrity metadata
  rollback   Atomically activate one retained bundle after validation and audit

Rollback accepts a managed bundle ID only, never a filesystem path. The target
must still exist under ~/.aidevops/runtime-bundles and pass manifest, source,
version, CLI, plugin, and runtime sentinel integrity checks. A successful
rollback leaves the former active bundle at previous-runtime-bundle. Existing
process leases and the Pulse runtime pin are not changed.
EOF
	return 0
}

_runtime_bundle_list() {
	local repo_dir="${AIDEVOPS_INSTALL_DIR:-${HOME:?HOME must be set}/Git/aidevops}"
	local bundles_root=""
	local active_root=""
	local previous_root=""
	local bundle_dir=""
	local state="retained"

	bundles_root=$(_runtime_bundle_managed_root) || {
		_runtime_bundle_rollback_error "No managed runtime bundles are installed"
		return 1
	}
	active_root=$(_runtime_bundle_resolve_managed_link "$(_runtime_bundle_active_link)" "$bundles_root" 2>/dev/null || true)
	previous_root=$(_runtime_bundle_resolve_managed_link "$(_runtime_bundle_previous_link)" "$bundles_root" 2>/dev/null || true)
	printf 'BUNDLE_ID\tVERSION\tGIT_SHA\tSTATE\tINTEGRITY\n'
	for bundle_dir in "$bundles_root"/*; do
		[[ -d "$bundle_dir" ]] || continue
		if ! _runtime_bundle_inventory_metadata "$bundle_dir" "$bundles_root"; then
			continue
		fi
		state="retained"
		[[ "$bundle_dir/agents" == "$active_root" ]] && state="active"
		[[ "$bundle_dir/agents" == "$previous_root" ]] && state="previous"
		if [[ -d "$repo_dir/.git" ]] && _runtime_bundle_validate_bundle "$_RUNTIME_BUNDLE_META_ID" "$repo_dir" >/dev/null 2>&1; then
			printf '%s\t%s\t%s\t%s\tverified\n' \
				"$_RUNTIME_BUNDLE_META_ID" "$_RUNTIME_BUNDLE_META_VERSION" "$_RUNTIME_BUNDLE_META_SHA" "$state"
		else
			printf '%s\t%s\t%s\t%s\tmanifest-only\n' \
				"$_RUNTIME_BUNDLE_META_ID" "$_RUNTIME_BUNDLE_META_VERSION" "$_RUNTIME_BUNDLE_META_SHA" "$state"
		fi
	done
	return 0
}

_runtime_bundle_status() {
	local bundles_root=""
	local active_root=""
	local previous_root=""
	local active_id="unavailable"
	local previous_id="none"

	bundles_root=$(_runtime_bundle_managed_root) || {
		_runtime_bundle_rollback_error "No managed runtime bundles are installed"
		return 1
	}
	active_root=$(_runtime_bundle_resolve_managed_link "$(_runtime_bundle_active_link)" "$bundles_root" 2>/dev/null || true)
	previous_root=$(_runtime_bundle_resolve_managed_link "$(_runtime_bundle_previous_link)" "$bundles_root" 2>/dev/null || true)
	if [[ -n "$active_root" ]]; then
		active_id="${active_root%/agents}"
		active_id="${active_id##*/}"
	fi
	if [[ -n "$previous_root" ]]; then
		previous_id="${previous_root%/agents}"
		previous_id="${previous_id##*/}"
	fi
	printf 'Active bundle: %s\n' "$active_id"
	printf 'Previous bundle: %s\n' "$previous_id"
	printf '\nRetained validated bundles:\n'
	_runtime_bundle_list
	return $?
}

_runtime_bundle_rollback_command() {
	local target_id=""
	local reason=""
	local mode="operator"
	local parse_error=""
	local arg=""
	local option_value=""
	local -a arguments=("$@")
	local argument_count="${#arguments[@]}"
	local argument_index=0

	while [[ "$argument_index" -lt "$argument_count" ]]; do
		arg="${arguments[$argument_index]}"
		argument_index=$((argument_index + 1))
		case "$arg" in
		--bundle-id)
			[[ "$argument_index" -lt "$argument_count" ]] || {
				parse_error="--bundle-id requires a value"
				break
			}
			option_value="${arguments[$argument_index]}"
			argument_index=$((argument_index + 1))
			target_id="$option_value"
			;;
		--reason)
			[[ "$argument_index" -lt "$argument_count" ]] || {
				parse_error="--reason requires a value"
				break
			}
			option_value="${arguments[$argument_index]}"
			argument_index=$((argument_index + 1))
			reason="$option_value"
			;;
		--automatic)
			mode="automatic-recovery"
			;;
		-h | --help | help)
			_runtime_bundle_rollback_usage
			return 0
			;;
		*)
			parse_error="Unknown rollback option: $arg"
			break
			;;
		esac
	done
	if [[ -n "$parse_error" ]]; then
		_runtime_bundle_rollback_blocked "$reason" "$target_id" "$parse_error" "$mode"
		return 1
	fi
	_runtime_bundle_rollback_execute "$target_id" "$reason" "$mode"
	return $?
}

main() {
	local command="${1:-status}"
	shift || true
	_runtime_bundle_rollback_load_dependencies || return 1
	case "$command" in
	status) _runtime_bundle_status "$@" ;;
	list) _runtime_bundle_list "$@" ;;
	rollback) _runtime_bundle_rollback_command "$@" ;;
	help | -h | --help) _runtime_bundle_rollback_usage ;;
	*)
		_runtime_bundle_rollback_error "Unknown runtime-bundle command: $command"
		_runtime_bundle_rollback_usage
		return 1
		;;
	esac
	return $?
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	main "$@"
fi

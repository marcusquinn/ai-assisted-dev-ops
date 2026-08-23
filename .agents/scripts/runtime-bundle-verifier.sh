#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

# Authoritative post-deployment verifier shared by setup, update, and release
# paths. The caller supplies the source checkout and expected commit; this
# helper proves that the stable activation link selects a validated immutable
# bundle produced from that exact revision.

_runtime_bundle_verifier_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=runtime-bundle-manifest.sh
source "$_runtime_bundle_verifier_dir/runtime-bundle-manifest.sh"
unset _runtime_bundle_verifier_dir

_runtime_bundle_verify_emit_error() {
	local message="$1"
	if declare -F print_error >/dev/null 2>&1; then
		print_error "$message"
	else
		printf 'ERROR: %s\n' "$message" >&2
	fi
	return 0
}

_runtime_bundle_verify_manifest_value() {
	local manifest_file="$1"
	local key="$2"
	runtime_bundle_manifest_value "$manifest_file" "$key" || return 1
	return 0
}

_runtime_bundle_verify_first_line() {
	local file="$1"
	local value=""

	[[ -r "$file" ]] || return 1
	if ! IFS= read -r value <"$file" && [[ -z "$value" ]]; then
		return 1
	fi
	printf '%s' "$value"
	return 0
}

_runtime_bundle_verify_sha256_file() {
	local file="$1"
	local digest=""

	[[ -r "$file" ]] || return 1
	if command -v sha256sum >/dev/null 2>&1; then
		digest=$(sha256sum "$file" 2>/dev/null | cut -d' ' -f1) || return 1
	elif command -v shasum >/dev/null 2>&1; then
		digest=$(shasum -a 256 "$file" 2>/dev/null | cut -d' ' -f1) || return 1
	elif command -v openssl >/dev/null 2>&1; then
		digest=$(openssl dgst -sha256 "$file" 2>/dev/null | sed 's/^.*= //') || return 1
	else
		return 1
	fi
	case "$digest" in
	'' | *[!0-9a-fA-F]*) return 1 ;;
	esac
	printf '%s' "$digest"
	return 0
}

_runtime_bundle_verify_git_blob_sha256() {
	local repo_dir="$1"
	local commit_sha="$2"
	local file_path="$3"
	local digest=""

	git -C "$repo_dir" cat-file -e "${commit_sha}:${file_path}" 2>/dev/null || return 1
	if command -v sha256sum >/dev/null 2>&1; then
		digest=$(git -C "$repo_dir" show "${commit_sha}:${file_path}" 2>/dev/null | sha256sum | cut -d' ' -f1) || return 1
	elif command -v shasum >/dev/null 2>&1; then
		digest=$(git -C "$repo_dir" show "${commit_sha}:${file_path}" 2>/dev/null | shasum -a 256 | cut -d' ' -f1) || return 1
	elif command -v openssl >/dev/null 2>&1; then
		digest=$(git -C "$repo_dir" show "${commit_sha}:${file_path}" 2>/dev/null | openssl dgst -sha256 | sed 's/^.*= //') || return 1
	else
		return 1
	fi
	case "$digest" in
	'' | *[!0-9a-fA-F]*) return 1 ;;
	esac
	printf '%s' "$digest"
	return 0
}

_AIDEVOPS_RUNTIME_VERIFY_SOURCE_SHA=""
_AIDEVOPS_RUNTIME_VERIFY_ACTIVE_ROOT=""
_AIDEVOPS_RUNTIME_VERIFY_MANIFEST_VERSION=""
_AIDEVOPS_RUNTIME_VERIFY_MANIFEST_CLI_SHA=""

_runtime_bundle_verify_source() {
	local repo_dir="$1"
	local expected_sha="$2"
	local source_sha=""
	local resolved_expected_sha=""

	if [[ -z "$repo_dir" || ! -d "$repo_dir" ]]; then
		_runtime_bundle_verify_emit_error "Runtime bundle convergence failed: source checkout is unavailable"
		return 1
	fi
	resolved_expected_sha=$(git -C "$repo_dir" rev-parse "${expected_sha}^{commit}" 2>/dev/null) || {
		_runtime_bundle_verify_emit_error "Runtime bundle convergence failed: expected source commit cannot be resolved"
		return 1
	}
	source_sha=$(git -C "$repo_dir" rev-parse HEAD 2>/dev/null) || {
		_runtime_bundle_verify_emit_error "Runtime bundle convergence failed: source checkout HEAD cannot be resolved"
		return 1
	}
	if [[ "$source_sha" != "$resolved_expected_sha" ]]; then
		_runtime_bundle_verify_emit_error "Runtime bundle convergence failed: source checkout HEAD ${source_sha:0:12} does not match release commit ${resolved_expected_sha:0:12}"
		return 1
	fi
	_AIDEVOPS_RUNTIME_VERIFY_SOURCE_SHA="$resolved_expected_sha"
	return 0
}

_runtime_bundle_verify_active_link() {
	local active_link="$1"
	local active_root=""
	local bundles_root=""

	if [[ ! -L "$active_link" ]]; then
		_runtime_bundle_verify_emit_error "Runtime bundle convergence failed: active agents path is not an atomic activation symlink"
		return 1
	fi
	active_root=$(cd "$active_link" 2>/dev/null && pwd -P) || {
		_runtime_bundle_verify_emit_error "Runtime bundle convergence failed: active agents symlink cannot be resolved"
		return 1
	}
	bundles_root=$(cd "${active_link%/*}/runtime-bundles" 2>/dev/null && pwd -P) || {
		_runtime_bundle_verify_emit_error "Runtime bundle convergence failed: immutable runtime-bundles directory is unavailable"
		return 1
	}
	case "$active_root" in
	"$bundles_root"/*/agents) ;;
	*)
		_runtime_bundle_verify_emit_error "Runtime bundle convergence failed: active agents realpath is outside the immutable runtime-bundles directory"
		return 1
		;;
	esac
	_AIDEVOPS_RUNTIME_VERIFY_ACTIVE_ROOT="$active_root"
	return 0
}

_runtime_bundle_verify_manifest() {
	local active_root="$1"
	local expected_sha="$2"
	local active_bundle_dir="${active_root%/agents}"
	local active_bundle_id=""
	local manifest_file="$active_root/.bundle-manifest"
	local manifest_schema=""
	local manifest_status=""
	local manifest_bundle_id=""
	local manifest_version=""
	local manifest_sha=""
	local manifest_cli_sha=""
	local expected_short="${expected_sha:0:12}"

	active_bundle_id="${active_bundle_dir##*/}"
	if [[ ! -r "$manifest_file" ]]; then
		_runtime_bundle_verify_emit_error "Runtime bundle convergence failed: active bundle manifest is missing"
		return 1
	fi
	manifest_schema=$(_runtime_bundle_verify_manifest_value "$manifest_file" schema 2>/dev/null) || manifest_schema=""
	manifest_status=$(_runtime_bundle_verify_manifest_value "$manifest_file" status 2>/dev/null) || manifest_status=""
	manifest_bundle_id=$(_runtime_bundle_verify_manifest_value "$manifest_file" bundle_id 2>/dev/null) || manifest_bundle_id=""
	manifest_version=$(_runtime_bundle_verify_manifest_value "$manifest_file" framework_version 2>/dev/null) || manifest_version=""
	manifest_sha=$(_runtime_bundle_verify_manifest_value "$manifest_file" git_sha 2>/dev/null) || manifest_sha=""
	manifest_cli_sha=$(_runtime_bundle_verify_manifest_value "$manifest_file" cli_sha256 2>/dev/null) || manifest_cli_sha=""
	if [[ "$manifest_schema" != "1" ]]; then
		_runtime_bundle_verify_emit_error "Runtime bundle convergence failed: active bundle manifest schema is ${manifest_schema:-missing}, expected 1"
		return 1
	fi
	if [[ "$manifest_status" != "validated" ]]; then
		_runtime_bundle_verify_emit_error "Runtime bundle convergence failed: active bundle manifest status is ${manifest_status:-missing}, expected validated"
		return 1
	fi
	if [[ -z "$manifest_bundle_id" || "$manifest_bundle_id" != "$active_bundle_id" ]]; then
		_runtime_bundle_verify_emit_error "Runtime bundle convergence failed: active realpath bundle ID ${active_bundle_id:-missing} does not match manifest bundle ID ${manifest_bundle_id:-missing}"
		return 1
	fi
	case "$active_bundle_id" in
	*-"$expected_short"-*) ;;
	*)
		_runtime_bundle_verify_emit_error "Runtime bundle convergence failed: active realpath bundle ID does not identify release commit $expected_short"
		return 1
		;;
	esac
	if [[ "$manifest_sha" != "$expected_sha" ]]; then
		_runtime_bundle_verify_emit_error "Runtime bundle convergence failed: manifest SHA ${manifest_sha:-missing} does not match release commit $expected_sha"
		return 1
	fi
	_AIDEVOPS_RUNTIME_VERIFY_MANIFEST_VERSION="$manifest_version"
	_AIDEVOPS_RUNTIME_VERIFY_MANIFEST_CLI_SHA="$manifest_cli_sha"
	return 0
}

_runtime_bundle_verify_version_and_stamp() {
	local repo_dir="$1"
	local expected_sha="$2"
	local active_root="$3"
	local stamp_file="$4"
	local repo_version=""
	local active_version=""
	local deployed_sha=""

	repo_version=$(git -C "$repo_dir" show "${expected_sha}:VERSION" 2>/dev/null) || repo_version=""
	active_version=$(_runtime_bundle_verify_first_line "$active_root/VERSION" 2>/dev/null) || active_version=""
	if [[ -z "$repo_version" || "$repo_version" != "$active_version" || "$repo_version" != "$_AIDEVOPS_RUNTIME_VERIFY_MANIFEST_VERSION" ]]; then
		_runtime_bundle_verify_emit_error "Runtime bundle convergence failed: source version=${repo_version:-missing}, active version=${active_version:-missing}, manifest version=${_AIDEVOPS_RUNTIME_VERIFY_MANIFEST_VERSION:-missing}"
		return 1
	fi
	if [[ -r "$stamp_file" ]]; then
		deployed_sha=$(tr -d '[:space:]' <"$stamp_file" 2>/dev/null) || deployed_sha=""
	fi
	if [[ "$deployed_sha" != "$expected_sha" ]]; then
		_runtime_bundle_verify_emit_error "Runtime bundle convergence failed: deployed SHA ${deployed_sha:-missing} does not match release commit $expected_sha"
		return 1
	fi
	return 0
}

_runtime_bundle_verify_sentinels() {
	local repo_dir="$1"
	local expected_sha="$2"
	local active_root="$3"
	local expected_short="${expected_sha:0:12}"
	local sentinel_pair=""
	local source_rel=""
	local active_rel=""
	local source_hash=""
	local active_hash=""
	local -a sentinel_pairs=(
		"aidevops.sh|aidevops.sh"
		".agents/scripts/version-manager-release.sh|scripts/version-manager-release.sh"
		".agents/scripts/deploy-agents-on-merge.sh|scripts/deploy-agents-on-merge.sh"
		".agents/scripts/runtime-bundle-manifest.sh|scripts/runtime-bundle-manifest.sh"
		".agents/scripts/runtime-bundle-verifier.sh|scripts/runtime-bundle-verifier.sh"
		".agents/scripts/setup/modules/agent-deploy.sh|scripts/setup/modules/agent-deploy.sh"
	)

	for sentinel_pair in "${sentinel_pairs[@]}"; do
		source_rel="${sentinel_pair%%|*}"
		active_rel="${sentinel_pair#*|}"
		source_hash=$(_runtime_bundle_verify_git_blob_sha256 "$repo_dir" "$expected_sha" "$source_rel" 2>/dev/null) || {
			_runtime_bundle_verify_emit_error "Runtime bundle convergence failed: release commit sentinel $source_rel cannot be hashed"
			return 1
		}
		active_hash=$(_runtime_bundle_verify_sha256_file "$active_root/$active_rel" 2>/dev/null) || {
			_runtime_bundle_verify_emit_error "Runtime bundle convergence failed: active sentinel $active_rel cannot be hashed"
			return 1
		}
		if [[ "$source_hash" != "$active_hash" ]]; then
			_runtime_bundle_verify_emit_error "Runtime bundle convergence failed: active sentinel $active_rel does not match release commit $expected_short"
			return 1
		fi
		if [[ "$source_rel" == "aidevops.sh" && "$_AIDEVOPS_RUNTIME_VERIFY_MANIFEST_CLI_SHA" != "$active_hash" ]]; then
			_runtime_bundle_verify_emit_error "Runtime bundle convergence failed: manifest CLI hash does not match the active release sentinel"
			return 1
		fi
	done

	return 0
}

verify_aidevops_runtime_bundle_convergence() {
	local repo_dir="$1"
	local expected_sha="$2"
	local active_link="${3:-${HOME}/.aidevops/agents}"
	local stamp_file="${4:-${HOME}/.aidevops/.deployed-sha}"

	_AIDEVOPS_RUNTIME_VERIFY_SOURCE_SHA=""
	_AIDEVOPS_RUNTIME_VERIFY_ACTIVE_ROOT=""
	_AIDEVOPS_RUNTIME_VERIFY_MANIFEST_VERSION=""
	_AIDEVOPS_RUNTIME_VERIFY_MANIFEST_CLI_SHA=""
	_runtime_bundle_verify_source "$repo_dir" "$expected_sha" || return 1
	_runtime_bundle_verify_active_link "$active_link" || return 1
	_runtime_bundle_verify_manifest \
		"$_AIDEVOPS_RUNTIME_VERIFY_ACTIVE_ROOT" \
		"$_AIDEVOPS_RUNTIME_VERIFY_SOURCE_SHA" || return 1
	_runtime_bundle_verify_version_and_stamp \
		"$repo_dir" \
		"$_AIDEVOPS_RUNTIME_VERIFY_SOURCE_SHA" \
		"$_AIDEVOPS_RUNTIME_VERIFY_ACTIVE_ROOT" \
		"$stamp_file" || return 1
	_runtime_bundle_verify_sentinels \
		"$repo_dir" \
		"$_AIDEVOPS_RUNTIME_VERIFY_SOURCE_SHA" \
		"$_AIDEVOPS_RUNTIME_VERIFY_ACTIVE_ROOT" || return 1
	return 0
}

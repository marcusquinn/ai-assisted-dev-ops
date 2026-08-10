#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Source-access broker provisioning from an immutable signed release.

set -Eeuo pipefail
IFS=$'\n\t'
# shellcheck disable=SC2154  # rc is assigned by $? in the trap string
trap 'rc=$?; echo "[ERROR] ${BASH_SOURCE[0]}:${LINENO} exit $rc" >&2' ERR
shopt -s inherit_errexit 2>/dev/null || true

_SOURCE_ACCESS_BROKER_DIR="/etc/aidevops/source-access"
_SOURCE_ACCESS_CORE_SOURCE=".agents/scripts/source_access_core.py"
_SOURCE_ACCESS_HELPER_SOURCE=".agents/scripts/source-access-helper.py"
_SOURCE_ACCESS_SETUP_SOURCE=".agents/scripts/setup/modules/source-access.sh"
_SOURCE_ACCESS_RAW_BASE="https://raw.githubusercontent.com/marcusquinn/aidevops"
_SOURCE_ACCESS_RELEASE_SIGNER_IDENTITY="6428977+marcusquinn@users.noreply.github.com"
_SOURCE_ACCESS_RELEASE_SIGNER_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMnXVft9/hT5P2dIICJMMmXeg6HUnKGCvR4VzkKpyJza"

_source_access_git() {
	GIT_NO_REPLACE_OBJECTS=1 /usr/bin/git "$@"
	return $?
}

_source_access_verify_release_tag() {
	local repo_root="$1"
	local tag_object="$2"
	local allowed_signers=""
	local verification_rc=0

	allowed_signers=$(/usr/bin/mktemp "${TMPDIR:-/tmp}/aidevops-source-access-signers.XXXXXX") || return 1
	if ! printf '%s %s\n' \
		"$_SOURCE_ACCESS_RELEASE_SIGNER_IDENTITY" \
		"$_SOURCE_ACCESS_RELEASE_SIGNER_KEY" >"$allowed_signers"; then
		/bin/rm -f "$allowed_signers"
		return 1
	fi
	/bin/chmod 0600 "$allowed_signers" || {
		/bin/rm -f "$allowed_signers"
		return 1
	}
	_source_access_git -C "$repo_root" \
		-c gpg.format=ssh \
		-c gpg.ssh.allowedSignersFile="$allowed_signers" \
		-c gpg.ssh.program=/usr/bin/ssh-keygen \
		verify-tag "$tag_object" >/dev/null 2>&1 || verification_rc=$?
	/bin/rm -f "$allowed_signers"
	[[ "$verification_rc" -eq 0 ]] || return 1
	return 0
}

_source_access_ensure_release_tag() {
	local repo_root="$1"
	local version=""
	local tag_ref=""
	local current_branch=""
	local recovery_helper="${repo_root}/.agents/scripts/canonical-recovery-helper.sh"

	[[ -r "$repo_root/VERSION" ]] || return 1
	IFS= read -r version <"$repo_root/VERSION" || return 1
	[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
	tag_ref="refs/tags/v${version}"
	if _source_access_git -C "$repo_root" show-ref --verify --quiet "$tag_ref"; then
		return 0
	fi
	[[ -f "$recovery_helper" ]] || return 1
	current_branch=$(_source_access_git -C "$repo_root" symbolic-ref --quiet --short HEAD 2>/dev/null) || return 1
	[[ -n "$current_branch" ]] || return 1
	AIDEVOPS_REAL_GIT_BIN=/usr/bin/git bash "$recovery_helper" fast-forward-current \
		--repo "$repo_root" --branch "$current_branch" --reason aidevops-update \
		--confirm FAST_FORWARD_CANONICAL_BRANCH >/dev/null || return 1
	_source_access_git -C "$repo_root" show-ref --verify --quiet "$tag_ref"
	return $?
}

_source_access_release_commit() {
	local repo_root="$1"
	local version=""
	local tag_name=""
	local tag_object=""
	local tag_type=""
	local tag_commit=""
	local tagged_version=""

	[[ -r "$repo_root/VERSION" ]] || return 1
	IFS= read -r version <"$repo_root/VERSION" || return 1
	[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
	tag_name="v${version}"
	tag_object=$(_source_access_git -C "$repo_root" rev-parse --verify "refs/tags/${tag_name}^{tag}" 2>/dev/null) || return 1
	[[ "$tag_object" =~ ^[0-9a-f]{40}$ ]] || return 1
	tag_type=$(_source_access_git -C "$repo_root" cat-file -t "$tag_object" 2>/dev/null) || return 1
	[[ "$tag_type" == "tag" ]] || return 1
	_source_access_verify_release_tag "$repo_root" "$tag_object" || return 1
	tag_commit=$(_source_access_git -C "$repo_root" rev-parse --verify "${tag_object}^{commit}" 2>/dev/null) || return 1
	[[ "$tag_commit" =~ ^[0-9a-f]{40}$ ]] || return 1
	_source_access_git -C "$repo_root" merge-base --is-ancestor "$tag_commit" HEAD 2>/dev/null || return 1
	tagged_version=$(_source_access_git -C "$repo_root" show "${tag_commit}:VERSION" 2>/dev/null) || return 1
	[[ "$tagged_version" == "$version" ]] || return 1
	_source_access_git -C "$repo_root" cat-file -e "${tag_commit}:${_SOURCE_ACCESS_CORE_SOURCE}" 2>/dev/null || return 1
	_source_access_git -C "$repo_root" cat-file -e "${tag_commit}:${_SOURCE_ACCESS_HELPER_SOURCE}" 2>/dev/null || return 1
	_source_access_git -C "$repo_root" cat-file -e "${tag_commit}:${_SOURCE_ACCESS_SETUP_SOURCE}" 2>/dev/null || return 1

	printf '%s\n' "$tag_commit"
	return 0
}

_source_access_file_matches() {
	local repo_root="$1"
	local tag_commit="$2"
	local source_path="$3"
	local installed_path="$4"

	[[ -f "$installed_path" && ! -L "$installed_path" ]] || return 1
	if _source_access_git -C "$repo_root" show "${tag_commit}:${source_path}" 2>/dev/null |
		/usr/bin/cmp -s - "$installed_path"; then
		return 0
	fi
	return 1
}

_source_access_setup_source_current() {
	local repo_root="$1"
	local tag_commit="$2"
	local setup_path="${repo_root}/${_SOURCE_ACCESS_SETUP_SOURCE}"

	_source_access_file_matches "$repo_root" "$tag_commit" "$_SOURCE_ACCESS_SETUP_SOURCE" "$setup_path"
	return $?
}

_source_access_path_identity() {
	local path="$1"
	local identity=""

	identity=$(/usr/bin/stat -f '%u:%Lp' "$path" 2>/dev/null) || identity=""
	if [[ -z "$identity" ]]; then
		identity=$(/usr/bin/stat -c '%u:%a' "$path" 2>/dev/null) || return 1
	fi
	printf '%s\n' "$identity"
	return 0
}

_source_access_root_owned_mode() {
	local path="$1"
	local expected_mode="$2"
	local expected_kind="$3"
	local identity=""

	[[ ! -L "$path" ]] || return 1
	case "$expected_kind" in
	file) [[ -f "$path" ]] || return 1 ;;
	directory) [[ -d "$path" ]] || return 1 ;;
	*) return 1 ;;
	esac
	identity=$(_source_access_path_identity "$path") || return 1
	[[ "$identity" == "0:${expected_mode}" ]]
	return $?
}

_source_access_root_owned_secure_directory() {
	local path="$1"
	local identity=""
	local owner=""
	local mode=""

	[[ -d "$path" && ! -L "$path" ]] || return 1
	identity=$(_source_access_path_identity "$path") || return 1
	owner="${identity%%:*}"
	mode="${identity#*:}"
	[[ "$owner" == "0" && "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
	(((8#$mode & 8#022) == 0)) || return 1
	return 0
}

_source_access_broker_metadata_current() {
	local core_path="${_SOURCE_ACCESS_BROKER_DIR}/source_access_core.py"
	local helper_path="${_SOURCE_ACCESS_BROKER_DIR}/source-access-helper.py"

	_source_access_root_owned_mode "$_SOURCE_ACCESS_BROKER_DIR" 755 directory || return 1
	_source_access_root_owned_mode "$core_path" 644 file || return 1
	_source_access_root_owned_mode "$helper_path" 644 file || return 1
	return 0
}

_source_access_broker_current() {
	local repo_root="$1"
	local tag_commit="$2"
	local core_path="${_SOURCE_ACCESS_BROKER_DIR}/source_access_core.py"
	local helper_path="${_SOURCE_ACCESS_BROKER_DIR}/source-access-helper.py"

	[[ -d "$_SOURCE_ACCESS_BROKER_DIR" && ! -L "$_SOURCE_ACCESS_BROKER_DIR" ]] || return 1
	_source_access_broker_metadata_current || return 1
	_source_access_file_matches "$repo_root" "$tag_commit" "$_SOURCE_ACCESS_CORE_SOURCE" "$core_path" || return 1
	_source_access_file_matches "$repo_root" "$tag_commit" "$_SOURCE_ACCESS_HELPER_SOURCE" "$helper_path" || return 1
	return 0
}

_source_access_trust_current() {
	local public_key="${_SOURCE_ACCESS_BROKER_DIR}/source-access.pub"
	local trust_marker="${_SOURCE_ACCESS_BROKER_DIR}/source-access.trust"
	local marker_schema=""
	local marker_key_source=""
	local marker_public_key=""
	local marker_extra=""
	local public_key_value=""
	local public_key_extra=""
	local public_key_type=""
	local public_key_data=""
	local public_key_comment=""

	# Unprivileged setup cannot traverse root-only private-key directories. The
	# root-owned marker attests the last configured binding; trust-check verifies
	# the live private key whenever setup already holds sudo.
	_source_access_root_owned_mode "$_SOURCE_ACCESS_BROKER_DIR" 755 directory || return 1
	_source_access_root_owned_mode "$public_key" 644 file || return 1
	_source_access_root_owned_mode "$trust_marker" 644 file || return 1
	{
		IFS= read -r marker_schema &&
			IFS= read -r marker_key_source &&
			IFS= read -r marker_public_key &&
			! IFS= read -r marker_extra
	} <"$trust_marker" || return 1
	{
		IFS= read -r public_key_value &&
			! IFS= read -r public_key_extra
	} <"$public_key" || return 1
	[[ "$marker_schema" == "schema=aidevops-source-access-trust/v1" ]] || return 1
	[[ "$marker_key_source" == "key_source=dedicated" ]] || return 1
	[[ "$marker_public_key" == public_key=* ]] || return 1
	marker_public_key="${marker_public_key#public_key=}"
	[[ "$marker_public_key" == "$public_key_value" ]] || return 1
	IFS=' ' read -r public_key_type public_key_data public_key_comment <<<"$public_key_value" || return 1
	[[ "$public_key_type" == "ssh-ed25519" && -n "$public_key_data" && -z "$public_key_comment" ]] || return 1
	return 0
}

_source_access_install_target_safe() {
	local broker_parent="${_SOURCE_ACCESS_BROKER_DIR%/*}"

	if [[ -e "$broker_parent" || -L "$broker_parent" ]]; then
		_source_access_root_owned_secure_directory "$broker_parent" || return 1
	fi
	if [[ -e "$_SOURCE_ACCESS_BROKER_DIR" || -L "$_SOURCE_ACCESS_BROKER_DIR" ]]; then
		_source_access_root_owned_secure_directory "$_SOURCE_ACCESS_BROKER_DIR" || return 1
	fi
	return 0
}

_source_access_acquire_privilege() {
	[[ -x /usr/bin/sudo ]] || return 1
	if _source_access_privilege_cached; then
		return 0
	fi
	[[ "${AIDEVOPS_SOURCE_ACCESS_INTERACTIVE:-false}" == "true" && -t 0 ]] || return 2
	print_info "Source-access broker provisioning requires one sudo confirmation"
	/usr/bin/sudo -v || return 1
	return 0
}

_source_access_privilege_cached() {
	[[ -x /usr/bin/sudo ]] || return 1
	/usr/bin/sudo -n /usr/bin/true >/dev/null 2>&1
	return $?
}

_source_access_privileged() {
	/usr/bin/sudo -n "$@"
	return $?
}

_source_access_cleanup_staging() {
	local core_stage="$1"
	local helper_stage="$2"

	if [[ -n "$core_stage" && -n "$helper_stage" ]]; then
		_source_access_privileged /bin/rm -f -- "$core_stage" "$helper_stage" >/dev/null 2>&1 || true
	elif [[ -n "$core_stage" ]]; then
		_source_access_privileged /bin/rm -f -- "$core_stage" >/dev/null 2>&1 || true
	elif [[ -n "$helper_stage" ]]; then
		_source_access_privileged /bin/rm -f -- "$helper_stage" >/dev/null 2>&1 || true
	fi
	return 0
}

_source_access_fetch_file() {
	local tag_commit="$1"
	local source_path="$2"
	local destination="$3"
	local source_url="${_SOURCE_ACCESS_RAW_BASE}/${tag_commit}/${source_path}"

	_source_access_privileged /usr/bin/curl --disable --fail --location --silent --show-error \
		--proto '=https' --proto-redir '=https' --tlsv1.2 \
		"$source_url" --output "$destination"
	return $?
}

_source_access_install_broker_files() {
	local repo_root="$1"
	local tag_commit="$2"
	local core_stage=""
	local helper_stage=""
	local core_path="${_SOURCE_ACCESS_BROKER_DIR}/source_access_core.py"
	local helper_path="${_SOURCE_ACCESS_BROKER_DIR}/source-access-helper.py"

	_source_access_install_target_safe || {
		print_warning "Source-access install target ownership or permissions are unsafe"
		return 1
	}
	_source_access_privileged /usr/bin/install -d -o 0 -g 0 -m 0755 "$_SOURCE_ACCESS_BROKER_DIR" || return 1
	_source_access_root_owned_mode "$_SOURCE_ACCESS_BROKER_DIR" 755 directory || return 1
	core_stage=$(_source_access_privileged /usr/bin/mktemp "${_SOURCE_ACCESS_BROKER_DIR}/.source_access_core.py.XXXXXX") || return 1
	helper_stage=$(_source_access_privileged /usr/bin/mktemp "${_SOURCE_ACCESS_BROKER_DIR}/.source-access-helper.py.XXXXXX") || {
		_source_access_cleanup_staging "$core_stage" ""
		return 1
	}
	if ! _source_access_fetch_file "$tag_commit" "$_SOURCE_ACCESS_CORE_SOURCE" "$core_stage" ||
		! _source_access_fetch_file "$tag_commit" "$_SOURCE_ACCESS_HELPER_SOURCE" "$helper_stage"; then
		_source_access_cleanup_staging "$core_stage" "$helper_stage"
		return 1
	fi
	_source_access_privileged /bin/chmod 0644 "$core_stage" "$helper_stage" || {
		_source_access_cleanup_staging "$core_stage" "$helper_stage"
		return 1
	}
	if ! _source_access_file_matches "$repo_root" "$tag_commit" "$_SOURCE_ACCESS_CORE_SOURCE" "$core_stage" ||
		! _source_access_file_matches "$repo_root" "$tag_commit" "$_SOURCE_ACCESS_HELPER_SOURCE" "$helper_stage"; then
		print_warning "Downloaded source-access broker bytes do not match the signed release"
		_source_access_cleanup_staging "$core_stage" "$helper_stage"
		return 1
	fi
	_source_access_privileged /bin/rm -f -- "$core_path" "$helper_path" || {
		_source_access_cleanup_staging "$core_stage" "$helper_stage"
		return 1
	}
	if ! _source_access_privileged /usr/bin/install -o 0 -g 0 -m 0644 "$core_stage" "$core_path" ||
		! _source_access_privileged /usr/bin/install -o 0 -g 0 -m 0644 "$helper_stage" "$helper_path"; then
		_source_access_cleanup_staging "$core_stage" "$helper_stage"
		return 1
	fi
	_source_access_cleanup_staging "$core_stage" "$helper_stage"
	_source_access_broker_current "$repo_root" "$tag_commit"
	return $?
}

_source_access_setup_trust() {
	local helper_path="${_SOURCE_ACCESS_BROKER_DIR}/source-access-helper.py"

	if _source_access_trust_current &&
		_source_access_privileged /usr/bin/python3 -I -B "$helper_path" trust-check >/dev/null; then
		return 0
	fi
	[[ "${AIDEVOPS_SOURCE_ACCESS_INTERACTIVE:-false}" == "true" && -t 0 ]] || return 2
	print_info "Configuring root-only source-access signing trust"
	_source_access_privileged /usr/bin/python3 -I -B "$helper_path" setup || return 1
	_source_access_trust_current || return 1
	_source_access_privileged /usr/bin/python3 -I -B "$helper_path" trust-check >/dev/null
	return $?
}

setup_source_access_broker() {
	local repo_root="${INSTALL_DIR:?INSTALL_DIR not set}"
	local tag_commit=""
	local helper_path="${_SOURCE_ACCESS_BROKER_DIR}/source-access-helper.py"
	local privilege_rc=0
	local trust_rc=0

	_source_access_ensure_release_tag "$repo_root" || {
		print_warning "Source-access broker deferred: the installed release tag is unavailable from the official remote"
		return 1
	}
	tag_commit=$(_source_access_release_commit "$repo_root") || {
		print_warning "Source-access broker deferred: the installed release tag could not be verified"
		return 1
	}
	_source_access_setup_source_current "$repo_root" "$tag_commit" || {
		print_warning "Source-access broker deferred: setup code does not match the signed release"
		return 1
	}
	_source_access_install_target_safe || {
		print_warning "Source-access broker deferred: install target ownership or permissions are unsafe"
		return 1
	}
	if _source_access_broker_current "$repo_root" "$tag_commit" && _source_access_trust_current; then
		if ! _source_access_privilege_cached; then
			print_success "Source-access broker matches signed release ${tag_commit:0:12}"
			return 0
		fi
		if _source_access_privileged /usr/bin/python3 -I -B "$helper_path" trust-check >/dev/null; then
			print_success "Source-access broker matches signed release ${tag_commit:0:12}"
			return 0
		fi
		print_warning "Source-access signing trust needs privileged reconciliation"
	fi

	_source_access_acquire_privilege || privilege_rc=$?
	if [[ "$privilege_rc" -ne 0 ]]; then
		print_warning "Source-access broker deferred; run aidevops update from an interactive terminal"
		return "$privilege_rc"
	fi
	if ! _source_access_broker_current "$repo_root" "$tag_commit"; then
		print_info "Installing source-access broker directly from signed release ${tag_commit:0:12}"
		_source_access_install_broker_files "$repo_root" "$tag_commit" || return 1
	fi

	_source_access_setup_trust || trust_rc=$?
	if [[ "$trust_rc" -eq 2 ]]; then
		print_warning "Source-access trust setup needs an interactive terminal; rerun aidevops update there"
		return 2
	fi
	[[ "$trust_rc" -eq 0 ]] || return 1
	_source_access_privileged /usr/bin/python3 -I -B "$helper_path" trust-check >/dev/null || return 1
	print_success "Source-access broker installed and verified from signed release ${tag_commit:0:12}"
	return 0
}

setup_source_access_broker_nonfatal() {
	local setup_rc=0

	setup_source_access_broker || setup_rc=$?
	if [[ "$setup_rc" -ne 0 ]]; then
		print_warning "Source-access remains fail-closed until broker provisioning completes"
	fi
	return 0
}

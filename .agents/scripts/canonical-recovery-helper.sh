#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail
# Supports: sync-mirror --repo PATH --reason aidevops-update
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
FAST_FORWARD_CMD="fast-forward-current"
SYNC_MIRROR_CMD="sync-mirror"
CLEAR_STALE_REBASE_CMD="clear-stale-rebase"
CLEAR_ABANDONED_REBASE_CMD="clear-abandoned-rebase"
AIDEVOPS_UPDATE_REASON="aidevops-update"
#aidevops:trust-boundary
# Framework maintenance pins its upstream identity here instead of trusting a
# downstream project registration or a caller-controlled remote name.
AIDEVOPS_FRAMEWORK_GITHUB_SLUG="marcusquinn/aidevops"
ABANDONED_REBASE_MIN_AGE_SECONDS=86400
ABANDONED_REBASE_KIND="abandoned"
HEAD_COMMIT_EXPR='HEAD^{commit}'
NULL_SHA1="0000000000000000000000000000000000000000"

github_slug_from_remote_url() {
	local url="$1"
	local slug=""
	local remainder=""
	local authority=""
	local port=""
	case "$url" in
	git@github.com:*) slug="${url#git@github.com:}" ;;
	ssh://* | https://* | http://* | git://*)
		remainder="${url#*://}"
		[[ "$remainder" == */* ]] || return 1
		authority="${remainder%%/*}"
		slug="${remainder#*/}"
		case "$url" in
		ssh://*)
			case "$authority" in
			git@github.com) ;;
			git@github.com:*) port="${authority#git@github.com:}" ;;
			*) return 1 ;;
			esac
			;;
		*)
			case "$authority" in
			github.com) ;;
			github.com:*) port="${authority#github.com:}" ;;
			*) return 1 ;;
			esac
			;;
		esac
		[[ -z "$port" || "$port" =~ ^[0-9]+$ ]] || return 1
		;;
	*) return 1 ;;
	esac
	slug="${slug%%\?*}"
	slug="${slug%%#*}"
	slug="${slug%/}"
	slug="${slug%.git}"
	[[ -n "$slug" && "$slug" == */* && "${slug#*/}" != */* ]] || return 1
	printf '%s\n' "$slug"
	return 0
}

is_github_remote_url() {
	local url="$1"
	case "$url" in
	git@github.com:* | ssh://git@github.com/* | ssh://git@github.com:*/* | \
		https://github.com/* | https://github.com:*/* | http://github.com/* | \
		http://github.com:*/* | git://github.com/* | git://github.com:*/*)
		return 0
		;;
	*) return 1 ;;
	esac
}

origin_is_local_mirror() {
	local repo="$1"
	local fetch_urls=""
	local push_urls=""
	local url=""
	local fetch_count=0
	local push_count=0
	fetch_urls=$("$REAL_GIT" -C "$repo" config --get-all remote.origin.url 2>/dev/null || true)
	push_urls=$("$REAL_GIT" -C "$repo" config --get-all remote.origin.pushurl 2>/dev/null || true)
	[[ -n "$push_urls" ]] || push_urls="$fetch_urls"
	while IFS= read -r url; do
		[[ -n "$url" ]] || continue
		fetch_count=$((fetch_count + 1))
		case "$url" in
		file://* | /* | ./* | ../*) ;;
		*) return 1 ;;
		esac
	done <<<"$fetch_urls"
	while IFS= read -r url; do
		[[ -n "$url" ]] || continue
		push_count=$((push_count + 1))
		case "$url" in
		file://* | /* | ./* | ../*) ;;
		*) return 1 ;;
		esac
	done <<<"$push_urls"
	[[ "$fetch_count" -gt 0 && "$push_count" -gt 0 ]] || return 1
	return 0
}

registered_repo_slug() {
	local repo="$1"
	local config_path="${AIDEVOPS_REPOS_CONFIG:-${HOME}/.config/aidevops/repos.json}"
	local rows=""
	local entry_path=""
	local entry_slug=""
	local entry_real=""
	local matched_slug=""
	[[ -f "$config_path" ]] || {
		printf '\n'
		return 0
	}
	rows=$(jq -r '.initialized_repos[]? | [(.path // .repo_path // ""), (.slug // "")] | @tsv' \
		"$config_path" 2>/dev/null) || return 1
	while IFS=$'\t' read -r entry_path entry_slug; do
		[[ -n "$entry_path" ]] || continue
		case "$entry_path" in
		~/*) entry_path="${HOME}/${entry_path#~/}" ;;
		esac
		entry_real=$(cd "$entry_path" 2>/dev/null && pwd -P) || continue
		[[ "$entry_real" == "$repo" ]] || continue
		[[ -n "$entry_slug" ]] || continue
		[[ "$entry_slug" == */* && "${entry_slug#*/}" != */* ]] || return 1
		if [[ -n "$matched_slug" && "$matched_slug" != "$entry_slug" ]]; then
			return 1
		fi
		matched_slug="$entry_slug"
	done <<<"$rows"
	printf '%s\n' "$matched_slug"
	return 0
}

GIT_CONFIG_CAPTURE_VALUES=""
GIT_CONFIG_CAPTURE_STATUS=0
GIT_CONFIG_CAPTURE_HAD_OUTPUT=false

# Capture one complete git-config enumeration without hiding its exit status.
# The suffix keeps command substitution from stripping record-separating newlines.
capture_git_config_values() {
	local repo="$1"
	local key="$2"
	local marker="__AIDEVOPS_GIT_CONFIG_CAPTURE_END_8F3D1A__"
	local suffix=$'\n'"$marker"
	local captured=""
	local capture_status=0
	captured=$(
		set +e
		"$REAL_GIT" -C "$repo" config --get-all "$key" 2>/dev/null
		command_status=$?
		printf '%s' "$marker"
		exit "$command_status"
	) || capture_status=$?
	GIT_CONFIG_CAPTURE_VALUES=""
	GIT_CONFIG_CAPTURE_STATUS="$capture_status"
	GIT_CONFIG_CAPTURE_HAD_OUTPUT=false
	case "$captured" in
	"$marker") ;;
	*"$suffix")
		GIT_CONFIG_CAPTURE_VALUES="${captured%"$suffix"}"
		GIT_CONFIG_CAPTURE_HAD_OUTPUT=true
		;;
	*) return 1 ;;
	esac
	return 0
}

GITHUB_REMOTE_URL_COUNT=0
GITHUB_REMOTE_URLS_MATCH=0
GITHUB_REMOTE_URL_SEEN=0

validate_github_remote_url_set() {
	local urls="$1"
	local expected_lower="$2"
	local remote_url=""
	local remote_slug=""
	local remote_lower=""
	GITHUB_REMOTE_URL_COUNT=0
	GITHUB_REMOTE_URLS_MATCH=1
	GITHUB_REMOTE_URL_SEEN=0
	while IFS= read -r remote_url; do
		GITHUB_REMOTE_URL_COUNT=$((GITHUB_REMOTE_URL_COUNT + 1))
		if [[ -z "$remote_url" ]]; then
			GITHUB_REMOTE_URLS_MATCH=0
			continue
		fi
		if is_github_remote_url "$remote_url"; then
			GITHUB_REMOTE_URL_SEEN=1
		fi
		remote_slug=$(github_slug_from_remote_url "$remote_url" 2>/dev/null || true)
		if [[ -z "$remote_slug" ]]; then
			GITHUB_REMOTE_URLS_MATCH=0
			continue
		fi
		GITHUB_REMOTE_URL_SEEN=1
		remote_lower=$(printf '%s' "$remote_slug" | tr '[:upper:]' '[:lower:]') || return 1
		[[ -n "$expected_lower" && "$remote_lower" == "$expected_lower" ]] || GITHUB_REMOTE_URLS_MATCH=0
	done <<<"$urls"
	return 0
}

# Resolve the remote that represents the registered GitHub repository. Exact
# fetch+push identity is required. Callers may allow the origin fallback for
# local mirrors where no configured remote can be parsed as GitHub at all. The
# pinned framework updater may also accept equivalent aliases after every URL
# independently resolves to its immutable expected repository identity.
resolve_github_remote() {
	local repo="$1"
	local expected_slug="$2"
	local allow_local_mirror="${3:-true}"
	local allow_equivalent_aliases="${4:-false}"
	local expected_lower=""
	local remote_names=""
	local remote=""
	local fetch_key=""
	local push_key=""
	local fetch_urls=""
	local push_urls=""
	local fetch_status=0
	local push_status=0
	local push_had_output=false
	local remote_matches=0
	local fetch_count=0
	local push_count=0
	local candidate=""
	local candidate_count=0
	local github_seen=0
	expected_lower=$(printf '%s' "$expected_slug" | tr '[:upper:]' '[:lower:]') || return 1
	remote_names=$(LC_ALL=C "$REAL_GIT" -C "$repo" remote 2>/dev/null | LC_ALL=C sort) || return 1
	while IFS= read -r remote; do
		[[ -n "$remote" ]] || continue
		fetch_key="remote.${remote}.url"
		push_key="remote.${remote}.pushurl"
		capture_git_config_values "$repo" "$fetch_key" || return 1
		fetch_status="$GIT_CONFIG_CAPTURE_STATUS"
		fetch_urls="$GIT_CONFIG_CAPTURE_VALUES"
		[[ "$fetch_status" -eq 0 ]] || return 1
		capture_git_config_values "$repo" "$push_key" || return 1
		push_status="$GIT_CONFIG_CAPTURE_STATUS"
		push_urls="$GIT_CONFIG_CAPTURE_VALUES"
		push_had_output="$GIT_CONFIG_CAPTURE_HAD_OUTPUT"
		case "$push_status" in
		0) ;;
		1)
			[[ "$push_had_output" == "false" ]] || return 1
			push_urls="$fetch_urls"
			;;
		*) return 1 ;;
		esac
		validate_github_remote_url_set "$fetch_urls" "$expected_lower" || return 1
		fetch_count="$GITHUB_REMOTE_URL_COUNT"
		remote_matches="$GITHUB_REMOTE_URLS_MATCH"
		[[ "$GITHUB_REMOTE_URL_SEEN" -eq 0 ]] || github_seen=1
		validate_github_remote_url_set "$push_urls" "$expected_lower" || return 1
		push_count="$GITHUB_REMOTE_URL_COUNT"
		[[ "$GITHUB_REMOTE_URLS_MATCH" -eq 1 ]] || remote_matches=0
		[[ "$GITHUB_REMOTE_URL_SEEN" -eq 0 ]] || github_seen=1
		[[ "$remote_matches" -eq 1 && "$fetch_count" -gt 0 && "$push_count" -gt 0 ]] || continue
		if [[ -z "$candidate" || "$remote" == "origin" ]]; then
			candidate="$remote"
		fi
		candidate_count=$((candidate_count + 1))
	done <<<"$remote_names"
	#aidevops:trust-boundary
	# Multiple names are accepted only after every candidate's complete fetch and
	# push URL sets independently matched the caller's immutable expected slug.
	if [[ "$candidate_count" -eq 1 ||
		("$allow_equivalent_aliases" == "true" && "$candidate_count" -gt 1) ]]; then
		printf '%s\n' "$candidate"
		return 0
	fi
	if [[ "$allow_local_mirror" == "true" && "$candidate_count" -eq 0 && "$github_seen" -eq 0 ]] &&
		origin_is_local_mirror "$repo"; then
		printf 'origin\n'
		return 0
	fi
	return 1
}

rebase_state_fingerprint() {
	local state_dir="$1"
	local fingerprint=""
	fingerprint=$(
		python3 - "$state_dir" <<'PY'
import hashlib
import os
import stat
import sys

state_dir = sys.argv[1]
root_stat = os.lstat(state_dir)
if not stat.S_ISDIR(root_stat.st_mode) or stat.S_ISLNK(root_stat.st_mode):
    raise RuntimeError("rebase state root is not a plain directory")

digest = hashlib.sha256()


def add_field(value):
    data = value.encode("utf-8", "surrogateescape")
    digest.update(len(data).to_bytes(8, "big"))
    digest.update(data)


def walk(path, relative):
    for entry in sorted(os.scandir(path), key=lambda item: item.name):
        entry_relative = os.path.join(relative, entry.name) if relative else entry.name
        entry_stat = entry.stat(follow_symlinks=False)
        if stat.S_ISDIR(entry_stat.st_mode) and not stat.S_ISLNK(entry_stat.st_mode):
            digest.update(b"D")
            add_field(entry_relative)
            walk(entry.path, entry_relative)
        elif stat.S_ISREG(entry_stat.st_mode):
            digest.update(b"F")
            add_field(entry_relative)
            digest.update(entry_stat.st_size.to_bytes(8, "big"))
            with open(entry.path, "rb") as handle:
                for chunk in iter(lambda: handle.read(65536), b""):
                    digest.update(chunk)
        else:
            raise RuntimeError("rebase state contains a non-regular entry")


walk(state_dir, "")
print(digest.hexdigest())
PY
	) || return 1
	printf '%s\n' "$fingerprint"
	return 0
}

rebase_marker_fingerprint() {
	local state_dir="$1"
	local rebase_head_path="$2"
	local state_hash=""
	local rebase_head_hash="absent"
	state_hash=$(rebase_state_fingerprint "$state_dir") || return 1
	if [[ -f "$rebase_head_path" ]]; then
		rebase_head_hash=$("$REAL_GIT" hash-object "$rebase_head_path") || return 1
	elif [[ -e "$rebase_head_path" ]]; then
		return 1
	fi
	printf '%s\n%s\n' "$state_hash" "$rebase_head_hash" | "$REAL_GIT" hash-object --stdin
	return 0
}

rebase_state_latest_mtime() {
	local state_dir="$1"
	local rebase_head_path="$2"
	local latest_mtime=""
	latest_mtime=$(
		python3 - "$state_dir" "$rebase_head_path" <<'PY'
import os
import sys

state_dir, rebase_head_path = sys.argv[1:]
paths = [state_dir]
for root, dirs, files in os.walk(state_dir):
    paths.extend(os.path.join(root, name) for name in dirs)
    paths.extend(os.path.join(root, name) for name in files)
if os.path.exists(rebase_head_path):
    paths.append(rebase_head_path)
print(int(max(os.lstat(path).st_mtime for path in paths)))
PY
	) || return 1
	printf '%s\n' "$latest_mtime"
	return 0
}

preserve_rebase_commit_ref() {
	local repo="$1"
	local issue="$2"
	local namespace="$3"
	local commitish="$4"
	local commit=""
	local existing_commit=""
	local preservation_ref=""
	[[ "$commitish" =~ ^[0-9a-fA-F]{4,40}$ ]] || return 1
	commit=$("$REAL_GIT" -C "$repo" rev-parse --verify "${commitish}^{commit}" 2>/dev/null) || return 1
	[[ "$commit" =~ ^[0-9a-fA-F]{40}$ ]] || return 1
	preservation_ref="refs/aidevops/canonical-recovery/issue-${issue}/${namespace}/${commit}"
	existing_commit=$("$REAL_GIT" -C "$repo" rev-parse --verify "${preservation_ref}^{commit}" 2>/dev/null || true)
	[[ -z "$existing_commit" || "$existing_commit" == "$commit" ]] || return 1
	if [[ -z "$existing_commit" ]]; then
		"$REAL_GIT" -C "$repo" update-ref "$preservation_ref" "$commit" \
			"0000000000000000000000000000000000000000" || return 1
	fi
	[[ "$("$REAL_GIT" -C "$repo" rev-parse --verify "${preservation_ref}^{commit}")" == "$commit" ]] || return 1
	return 0
}

preserve_rebase_sequence_refs() {
	local repo="$1"
	local issue="$2"
	local namespace="$3"
	local sequence_file="$4"
	local sequence_action=""
	local sequence_commit=""
	local sequence_rest=""
	[[ -f "$sequence_file" ]] || return 1
	while read -r sequence_action sequence_commit sequence_rest ||
		[[ -n "$sequence_action" || -n "$sequence_commit" || -n "$sequence_rest" ]]; do
		case "$sequence_action" in
		"" | \#* | exec | x | break | b | label | l | reset | t | update-ref | u | noop)
			continue
			;;
		pick | p | reword | r | edit | e | squash | s | drop | d)
			preserve_rebase_commit_ref "$repo" "$issue" "$namespace" "$sequence_commit" || return 1
			;;
		fixup | f)
			if [[ "$sequence_commit" == "-C" || "$sequence_commit" == "-c" ]]; then
				read -r sequence_commit _ <<<"$sequence_rest"
			fi
			preserve_rebase_commit_ref "$repo" "$issue" "$namespace" "$sequence_commit" || return 1
			;;
		merge | m)
			if [[ "$sequence_commit" == "-C" || "$sequence_commit" == "-c" ]]; then
				read -r sequence_commit _ <<<"$sequence_rest"
				preserve_rebase_commit_ref "$repo" "$issue" "$namespace" "$sequence_commit" || return 1
			fi
			;;
		*)
			return 1
			;;
		esac
	done <"$sequence_file"
	return 0
}

preserve_rewritten_rebase_refs() {
	local repo="$1"
	local issue="$2"
	local namespace="$3"
	local state_dir="$4"
	local extra=""
	local new_commit=""
	local old_commit=""
	local pending_commit=""
	if [[ -f "${state_dir}/rewritten-list" ]]; then
		while read -r old_commit new_commit extra ||
			[[ -n "$old_commit" || -n "$new_commit" || -n "$extra" ]]; do
			[[ -n "$old_commit" && -n "$new_commit" && -z "$extra" ]] || return 1
			preserve_rebase_commit_ref "$repo" "$issue" "$namespace" "$old_commit" || return 1
			preserve_rebase_commit_ref "$repo" "$issue" "$namespace" "$new_commit" || return 1
		done <"${state_dir}/rewritten-list"
	fi
	if [[ -f "${state_dir}/rewritten-pending" ]]; then
		while read -r pending_commit extra || [[ -n "$pending_commit" || -n "$extra" ]]; do
			[[ -n "$pending_commit" && -z "$extra" ]] || return 1
			preserve_rebase_commit_ref "$repo" "$issue" "$namespace" "$pending_commit" || return 1
		done <"${state_dir}/rewritten-pending"
	fi
	return 0
}

preserve_rebase_object_file_refs() {
	local repo="$1"
	local issue="$2"
	local namespace="$3"
	local object_file="$4"
	local object_line=""
	local object_token=""
	local -a object_tokens=()
	[[ -f "$object_file" ]] || return 0
	while IFS= read -r object_line || [[ -n "$object_line" ]]; do
		object_tokens=()
		read -r -a object_tokens <<<"$object_line"
		for object_token in "${object_tokens[@]}"; do
			[[ "$object_token" =~ ^[0-9a-fA-F]{4,40}$ ]] || continue
			[[ "$object_token" =~ ^0+$ ]] && continue
			preserve_rebase_commit_ref "$repo" "$issue" "$namespace" "$object_token" || return 1
		done
	done <"$object_file"
	return 0
}

restore_deleted_rebase_head() {
	local repo="$1"
	local rebase_head_path="$2"
	local stopped_sha="$3"
	local current_rebase_head=""
	if [[ -e "$rebase_head_path" ]]; then
		[[ -f "$rebase_head_path" ]] || return 1
		current_rebase_head=$("$REAL_GIT" -C "$repo" rev-parse --verify 'REBASE_HEAD^{commit}' 2>/dev/null || true)
		[[ -n "$current_rebase_head" ]] || return 1
		return 0
	fi
	"$REAL_GIT" -C "$repo" update-ref REBASE_HEAD "$stopped_sha" "$NULL_SHA1" || return 1
	[[ "$("$REAL_GIT" -C "$repo" rev-parse --verify 'REBASE_HEAD^{commit}')" == "$stopped_sha" ]] || return 1
	return 0
}

restore_deleted_rebase_head_copy() {
	local repo="$1"
	local rebase_head_path="$2"
	local stopped_sha="$3"
	local quarantine_head_path="$4"
	restore_deleted_rebase_head "$repo" "$rebase_head_path" "$stopped_sha" || return 1
	rm -f "$quarantine_head_path" || return 1
	return 0
}

restore_quarantined_rebase_state() {
	local repo="$1"
	local state_dir="$2"
	local rebase_head_path="$3"
	local quarantine_dir="$4"
	local quarantine_head_path="$5"
	local cleanup_kind="$6"
	local stopped_sha="$7"
	[[ -d "$quarantine_dir" && ! -e "$state_dir" ]] || return 1
	if [[ "$cleanup_kind" == "$ABANDONED_REBASE_KIND" ]]; then
		[[ -f "$quarantine_head_path" ]] || return 1
	fi
	mv "$quarantine_dir" "$state_dir" || return 1
	if [[ "$cleanup_kind" == "$ABANDONED_REBASE_KIND" ]]; then
		if ! restore_deleted_rebase_head "$repo" "$rebase_head_path" "$stopped_sha"; then
			mv "$state_dir" "$quarantine_dir" >/dev/null 2>&1 || true
			return 1
		fi
		rm -f "$quarantine_head_path" || return 1
	fi
	return 0
}

# Fetch only the release tag required by the post-update source-access stage.
# The caller has already pinned and validated the canonical remote. Existing
# refs are never rewritten; source-access owns signature and ancestry checks.
fetch_aidevops_release_tag() {
	local repo="$1"
	local remote="$2"
	local version=""
	local tag_ref=""

	[[ -r "$repo/VERSION" ]] || return 1
	IFS= read -r version <"$repo/VERSION" || return 1
	[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
	tag_ref="refs/tags/v${version}"
	if "$REAL_GIT" -C "$repo" show-ref --verify --quiet "$tag_ref"; then
		return 0
	fi
	if ! "$REAL_GIT" -C "$repo" fetch --no-tags "$remote" \
		"${tag_ref}:${tag_ref}" >/dev/null 2>&1; then
		return 1
	fi
	"$REAL_GIT" -C "$repo" show-ref --verify --quiet "$tag_ref"
	return $?
}

usage() {
	printf '%s\n' \
		'Usage:' \
		'  canonical-recovery-helper.sh restore-default --repo PATH --issue N --confirm RESTORE_CANONICAL_DEFAULT' \
		"  canonical-recovery-helper.sh ${CLEAR_STALE_REBASE_CMD} --repo PATH --issue N --confirm CLEAR_CONVERGED_STALE_REBASE" \
		"  canonical-recovery-helper.sh ${CLEAR_ABANDONED_REBASE_CMD} --repo PATH --issue N --confirm CLEAR_ABANDONED_STALE_REBASE" \
		"  canonical-recovery-helper.sh ${FAST_FORWARD_CMD} --repo PATH --branch BRANCH --issue N --confirm FAST_FORWARD_CANONICAL_BRANCH" \
		"  canonical-recovery-helper.sh ${FAST_FORWARD_CMD} --repo PATH --branch BRANCH --reason ${AIDEVOPS_UPDATE_REASON} --confirm FAST_FORWARD_CANONICAL_BRANCH" \
		"  canonical-recovery-helper.sh ${SYNC_MIRROR_CMD} --repo PATH --issue N --confirm SYNCHRONIZE_CANONICAL_MIRROR" \
		"  canonical-recovery-helper.sh ${SYNC_MIRROR_CMD} --repo PATH --reason ${AIDEVOPS_UPDATE_REASON} --confirm SYNCHRONIZE_CANONICAL_MIRROR"
	return 0
}

cmd="${1:-}"
shift || true
repo_path=""
issue_number=""
maintenance_reason=""
confirmation=""
expected_branch=""
while [[ $# -gt 0 ]]; do
	case "$1" in
	--repo)
		repo_path="${2:-}"
		shift 2
		;;
	--issue)
		issue_number="${2:-}"
		shift 2
		;;
	--reason)
		maintenance_reason="${2:-}"
		shift 2
		;;
	--confirm)
		confirmation="${2:-}"
		shift 2
		;;
	--branch)
		expected_branch="${2:-}"
		shift 2
		;;
	*)
		usage
		exit 2
		;;
	esac
done

case "$cmd" in
restore-default)
	expected_confirmation="RESTORE_CANONICAL_DEFAULT"
	[[ -z "$expected_branch" ]] || {
		usage
		exit 2
	}
	;;
"$CLEAR_STALE_REBASE_CMD")
	expected_confirmation="CLEAR_CONVERGED_STALE_REBASE"
	[[ -z "$expected_branch" ]] || {
		usage
		exit 2
	}
	;;
"$CLEAR_ABANDONED_REBASE_CMD")
	expected_confirmation="CLEAR_ABANDONED_STALE_REBASE"
	[[ -z "$expected_branch" ]] || {
		usage
		exit 2
	}
	;;
"$FAST_FORWARD_CMD")
	expected_confirmation="FAST_FORWARD_CANONICAL_BRANCH"
	[[ -n "$expected_branch" ]] || {
		usage
		exit 2
	}
	;;
"$SYNC_MIRROR_CMD")
	expected_confirmation="SYNCHRONIZE_CANONICAL_MIRROR"
	[[ -z "$expected_branch" ]] || {
		usage
		exit 2
	}
	;;
*)
	usage
	exit 2
	;;
esac
[[ -d "$repo_path" ]] || {
	usage
	exit 2
}
if [[ "$issue_number" =~ ^[0-9]+$ && -z "$maintenance_reason" ]]; then
	audit_reference="issue ${issue_number}"
elif [[ -z "$issue_number" && ("$cmd" == "$FAST_FORWARD_CMD" || "$cmd" == "$SYNC_MIRROR_CMD") &&
	"$maintenance_reason" == "$AIDEVOPS_UPDATE_REASON" ]]; then
	audit_reference="reason ${maintenance_reason}"
else
	usage
	exit 2
fi
repo_path=$(cd "$repo_path" && pwd -P) || exit 2
[[ "$confirmation" == "$expected_confirmation" ]] || {
	printf 'BLOCKED: exact recovery confirmation is required\n' >&2
	exit 1
}

REAL_GIT="${AIDEVOPS_REAL_GIT_BIN:-/usr/bin/git}"
git_dir=$("$REAL_GIT" -C "$repo_path" rev-parse --path-format=absolute --git-dir 2>/dev/null)
common_dir=$("$REAL_GIT" -C "$repo_path" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
[[ -n "$git_dir" && "$git_dir" == "$common_dir" ]] || {
	printf 'BLOCKED: recovery target is not the canonical worktree\n' >&2
	exit 1
}
if [[ "$cmd" != "$SYNC_MIRROR_CMD" ]] && [[ -n "$("$REAL_GIT" -C "$repo_path" status --porcelain)" ]]; then
	printf 'BLOCKED: canonical worktree is not clean\n' >&2
	exit 1
fi

policy_helper="${SCRIPT_DIR}/canonical-write-policy-helper.py"
[[ -f "$policy_helper" ]] || {
	printf 'BLOCKED: canonical branch policy helper is unavailable\n' >&2
	exit 1
}
registered_slug=""
expected_slug=""
allow_local_mirror=true
allow_equivalent_aliases=false
#aidevops:trust-boundary
# Only framework self-update has an identity pinned independently of repository
# registration, so ordinary canonical recovery keeps rejecting multiple aliases.
if [[ "$maintenance_reason" == "$AIDEVOPS_UPDATE_REASON" ]]; then
	expected_slug="$AIDEVOPS_FRAMEWORK_GITHUB_SLUG"
	allow_local_mirror=false
	allow_equivalent_aliases=true
else
	registered_slug=$(registered_repo_slug "$repo_path") || {
		printf 'BLOCKED: registered canonical repository identity is invalid or ambiguous\n' >&2
		exit 1
	}
	expected_slug="$registered_slug"
fi
if ! canonical_remote=$(resolve_github_remote \
	"$repo_path" "$expected_slug" "$allow_local_mirror" "$allow_equivalent_aliases"); then
	if [[ "$maintenance_reason" == "$AIDEVOPS_UPDATE_REASON" ]]; then
		printf 'BLOCKED: official aidevops GitHub remote is missing, mismatched, or ambiguous\n' >&2
	else
		printf 'BLOCKED: registered GitHub remote is missing, mismatched, or ambiguous\n' >&2
	fi
	exit 1
fi
target_branch=$(AIDEVOPS_CANONICAL_REMOTE="$canonical_remote" \
	python3 "$policy_helper" resolve-branch --cwd "$repo_path" --field branch) || exit 1
target_branch_source=$(AIDEVOPS_CANONICAL_REMOTE="$canonical_remote" \
	python3 "$policy_helper" resolve-branch --cwd "$repo_path" --field source) || exit 1
"$REAL_GIT" check-ref-format --branch "$target_branch" >/dev/null 2>&1 || {
	printf 'BLOCKED: resolved canonical branch is invalid\n' >&2
	exit 1
}

if [[ "$cmd" != "restore-default" && "$cmd" != "$CLEAR_STALE_REBASE_CMD" &&
	"$cmd" != "$CLEAR_ABANDONED_REBASE_CMD" ]]; then
	current_branch=$("$REAL_GIT" -C "$repo_path" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
	[[ -n "$current_branch" ]] || {
		printf 'BLOCKED: canonical worktree is detached\n' >&2
		exit 1
	}
	if [[ "$cmd" == "$FAST_FORWARD_CMD" && "$expected_branch" != "$target_branch" ]]; then
		printf 'BLOCKED: requested branch %s is not the resolved canonical branch %s\n' \
			"$expected_branch" "$target_branch" >&2
		exit 1
	fi
	[[ "$current_branch" == "$target_branch" ]] || {
		printf 'BLOCKED: canonical worktree is on %s, expected %s\n' "$current_branch" "$target_branch" >&2
		exit 1
	}
fi

occupied_path=""
while IFS= read -r line; do
	case "$line" in
	worktree\ *) occupied_path="${line#worktree }" ;;
	branch\ refs/heads/"$target_branch")
		if [[ "$occupied_path" != "$repo_path" ]]; then
			printf 'BLOCKED: target branch is active in another worktree: %s\n' "$occupied_path" >&2
			exit 1
		fi
		;;
	esac
done < <("$REAL_GIT" -C "$repo_path" worktree list --porcelain)

lock_dir="${common_dir}/aidevops-canonical-recovery.lock"
mkdir "$lock_dir" 2>/dev/null || {
	printf 'BLOCKED: canonical recovery lock is already held\n' >&2
	exit 1
}
trap 'rmdir "$lock_dir" 2>/dev/null || true' EXIT

local_ref="refs/heads/${target_branch}"
remote_ref="refs/remotes/${canonical_remote}/${target_branch}"
"$REAL_GIT" -C "$repo_path" fetch --no-tags "$canonical_remote" \
	"+refs/heads/${target_branch}:${remote_ref}" >/dev/null 2>&1 || {
	printf 'BLOCKED: %s/%s tip could not be fetched\n' "$canonical_remote" "$target_branch" >&2
	exit 1
}
target_sha=$("$REAL_GIT" -C "$repo_path" rev-parse --verify "${remote_ref}^{commit}" 2>/dev/null || true)
[[ -n "$target_sha" ]] || {
	printf 'BLOCKED: %s/%s tip cannot be resolved\n' "$canonical_remote" "$target_branch" >&2
	exit 1
}
local_sha=$("$REAL_GIT" -C "$repo_path" rev-parse --verify "${local_ref}^{commit}" 2>/dev/null || true)
[[ -n "$local_sha" ]] || {
	printf 'BLOCKED: local %s tip cannot be resolved\n' "$target_branch" >&2
	exit 1
}
if [[ "$cmd" == "$SYNC_MIRROR_CMD" && "$maintenance_reason" == "$AIDEVOPS_UPDATE_REASON" ]]; then
	tracked_status=$("$REAL_GIT" -C "$repo_path" status --porcelain=v1 --untracked-files=no) || {
		printf 'BLOCKED: canonical tracked/index state cannot be read safely\n' >&2
		exit 1
	}
	[[ -z "$tracked_status" ]] || {
		printf 'BLOCKED: routine update synchronization accepts untracked-only state\n' >&2
		exit 1
	}
	"$REAL_GIT" -C "$repo_path" merge-base --is-ancestor "$local_ref" "$target_sha" || {
		printf 'BLOCKED: routine update synchronization will not replace local commits\n' >&2
		exit 1
	}
fi

stale_rebase_dir=""
stale_rebase_fingerprint=""
stale_rebase_preservation_dir=""
stale_head_sha=""
stale_index_tree=""
stale_rebase_cleanup_kind=""
stale_rebase_ref_namespace=""
stale_rebase_stopped_sha=""
if [[ "$cmd" == "$CLEAR_STALE_REBASE_CMD" || "$cmd" == "$CLEAR_ABANDONED_REBASE_CMD" ]]; then
	rebase_merge_dir=$("$REAL_GIT" -C "$repo_path" rev-parse --path-format=absolute --git-path rebase-merge)
	rebase_apply_dir=$("$REAL_GIT" -C "$repo_path" rev-parse --path-format=absolute --git-path rebase-apply)
	rebase_head_path=$("$REAL_GIT" -C "$repo_path" rev-parse --path-format=absolute --git-path REBASE_HEAD)
	[[ -d "$rebase_merge_dir" && ! -e "$rebase_apply_dir" ]] || {
		printf 'BLOCKED: exactly one supported interactive rebase state is required\n' >&2
		exit 1
	}
	for required_file in "head-name" "onto" "orig-head" "git-rebase-todo" "done" "msgnum" "end"; do
		[[ -f "${rebase_merge_dir}/${required_file}" ]] || {
			printf 'BLOCKED: stale rebase metadata is malformed or incomplete\n' >&2
			exit 1
		}
	done
	rebase_head_name=$(<"${rebase_merge_dir}/head-name")
	rebase_onto=$(<"${rebase_merge_dir}/onto")
	rebase_orig_head=$(<"${rebase_merge_dir}/orig-head")
	rebase_msgnum=$(<"${rebase_merge_dir}/msgnum")
	rebase_end=$(<"${rebase_merge_dir}/end")
	[[ "$rebase_head_name" == "$local_ref" ]] || {
		printf 'BLOCKED: stale rebase belongs to a different branch\n' >&2
		exit 1
	}
	[[ "$rebase_msgnum" =~ ^[0-9]+$ && "$rebase_end" =~ ^[0-9]+$ ]] || {
		printf 'BLOCKED: rebase sequence counters are malformed\n' >&2
		exit 1
	}
	"$REAL_GIT" -C "$repo_path" rev-parse --verify "${rebase_onto}^{commit}" >/dev/null 2>&1 &&
		"$REAL_GIT" -C "$repo_path" rev-parse --verify "${rebase_orig_head}^{commit}" >/dev/null 2>&1 || {
		printf 'BLOCKED: stale rebase commit metadata is invalid\n' >&2
		exit 1
	}
	[[ -z "$("$REAL_GIT" -C "$repo_path" diff --name-only --diff-filter=U)" ]] || {
		printf 'BLOCKED: rebase has unresolved index entries\n' >&2
		exit 1
	}
	stale_head_sha=$("$REAL_GIT" -C "$repo_path" rev-parse --verify "$HEAD_COMMIT_EXPR")
	stale_index_tree=$("$REAL_GIT" -C "$repo_path" write-tree)
	stale_rebase_dir="$rebase_merge_dir"
	if [[ "$cmd" == "$CLEAR_STALE_REBASE_CMD" ]]; then
		[[ "$rebase_msgnum" == "$rebase_end" ]] || {
			printf 'BLOCKED: rebase sequence is active or malformed\n' >&2
			exit 1
		}
		[[ ! -s "${rebase_merge_dir}/git-rebase-todo" && -s "${rebase_merge_dir}/done" ]] || {
			printf 'BLOCKED: rebase sequence still has active work\n' >&2
			exit 1
		}
		[[ ! -e "$rebase_head_path" && ! -e "${rebase_merge_dir}/stopped-sha" ]] || {
			printf 'BLOCKED: rebase is stopped on an active commit\n' >&2
			exit 1
		}
		[[ "$stale_head_sha" == "$local_sha" && "$local_sha" == "$target_sha" ]] || {
			printf 'BLOCKED: HEAD, local default, and pinned %s default have not converged\n' "$canonical_remote" >&2
			exit 1
		}
		stale_rebase_cleanup_kind="converged"
		stale_rebase_ref_namespace="stale-rebase"
		stale_rebase_fingerprint=$(rebase_state_fingerprint "$stale_rebase_dir")
		stale_rebase_preservation_dir="${AIDEVOPS_CANONICAL_RECOVERY_ROOT:-${HOME}/.aidevops/.agent-workspace/recovery/canonical}/${issue_number}/stale-rebase-${stale_head_sha}"
	else
		[[ "$rebase_msgnum" -ge 1 && "$rebase_msgnum" -lt "$rebase_end" ]] || {
			printf 'BLOCKED: abandoned rebase must retain an incomplete active sequence\n' >&2
			exit 1
		}
		[[ -s "${rebase_merge_dir}/git-rebase-todo" && -s "${rebase_merge_dir}/done" &&
			-f "${rebase_merge_dir}/stopped-sha" && -f "$rebase_head_path" ]] || {
			printf 'BLOCKED: abandoned rebase metadata is not a complete stopped sequence\n' >&2
			exit 1
		}
		stale_rebase_stopped_sha=$(<"${rebase_merge_dir}/stopped-sha")
		rebase_head_sha=$(<"$rebase_head_path")
		stale_rebase_stopped_sha=$("$REAL_GIT" -C "$repo_path" rev-parse --verify "${stale_rebase_stopped_sha}^{commit}" 2>/dev/null || true)
		rebase_head_sha=$("$REAL_GIT" -C "$repo_path" rev-parse --verify "${rebase_head_sha}^{commit}" 2>/dev/null || true)
		[[ -n "$stale_rebase_stopped_sha" && "$stale_rebase_stopped_sha" == "$rebase_head_sha" ]] || {
			printf 'BLOCKED: stopped rebase commit metadata is invalid or inconsistent\n' >&2
			exit 1
		}
		abandoned_current_branch=$("$REAL_GIT" -C "$repo_path" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
		[[ -z "$abandoned_current_branch" ]] || {
			printf 'BLOCKED: abandoned rebase recovery requires a detached canonical HEAD\n' >&2
			exit 1
		}
		[[ "$stale_head_sha" == "$target_sha" && "$stale_head_sha" != "$stale_rebase_stopped_sha" ]] || {
			printf 'BLOCKED: HEAD has not independently converged beyond the stopped rebase commit\n' >&2
			exit 1
		}
		"$REAL_GIT" -C "$repo_path" merge-base --is-ancestor "$local_sha" "$target_sha" || {
			printf 'BLOCKED: local default branch has diverged from the pinned %s default\n' "$canonical_remote" >&2
			exit 1
		}
		rebase_latest_mtime=$(rebase_state_latest_mtime "$stale_rebase_dir" "$rebase_head_path") || {
			printf 'BLOCKED: abandoned rebase age cannot be established\n' >&2
			exit 1
		}
		current_epoch=$(date +%s)
		[[ "$rebase_latest_mtime" =~ ^[0-9]+$ && "$current_epoch" =~ ^[0-9]+$ &&
			"$current_epoch" -ge "$rebase_latest_mtime" &&
			$((current_epoch - rebase_latest_mtime)) -ge "$ABANDONED_REBASE_MIN_AGE_SECONDS" ]] || {
			printf 'BLOCKED: active rebase metadata is too recent to prove abandonment\n' >&2
			exit 1
		}
		stale_rebase_cleanup_kind="$ABANDONED_REBASE_KIND"
		stale_rebase_ref_namespace="abandoned-rebase"
		stale_rebase_fingerprint=$(rebase_marker_fingerprint "$stale_rebase_dir" "$rebase_head_path")
		stale_rebase_preservation_dir="${AIDEVOPS_CANONICAL_RECOVERY_ROOT:-${HOME}/.aidevops/.agent-workspace/recovery/canonical}/${issue_number}/abandoned-rebase-${stale_head_sha}"
	fi
fi

sync_backup_id=""
sync_backup_dir=""
if [[ "$cmd" == "$SYNC_MIRROR_CMD" ]]; then
	canonical_status=$("$REAL_GIT" -C "$repo_path" status --porcelain=v1) || {
		printf 'BLOCKED: canonical worktree status cannot be read safely\n' >&2
		exit 1
	}
	if [[ -n "$canonical_status" ]]; then
		backup_helper="${SCRIPT_DIR}/dirty-worktree-backup-helper.sh"
		[[ -f "$backup_helper" ]] || {
			printf 'BLOCKED: dirty-worktree backup helper is unavailable\n' >&2
			exit 1
		}
		backup_operation_key="${issue_number:-$maintenance_reason}"
		backup_output=$(AIDEVOPS_REAL_GIT_BIN="$REAL_GIT" bash "$backup_helper" backup \
			--repo "$repo_path" --reason "canonical mirror synchronization" \
			--issue "$issue_number" \
			--operation-id "canonical-sync-${backup_operation_key}-${target_sha}" --machine) || {
			printf 'BLOCKED: canonical dirty state could not be preserved\n' >&2
			exit 1
		}
		backup_record="${backup_output##*$'\n'}"
		IFS='|' read -r sync_backup_id sync_backup_dir <<<"$backup_record"
		[[ -n "$sync_backup_id" && -d "$sync_backup_dir" ]] || {
			printf 'BLOCKED: canonical backup evidence is incomplete\n' >&2
			exit 1
		}
		AIDEVOPS_REAL_GIT_BIN="$REAL_GIT" bash "$backup_helper" verify \
			--repo "$repo_path" --backup "$sync_backup_id" >/dev/null || {
			printf 'BLOCKED: canonical backup verification failed\n' >&2
			exit 1
		}
		AIDEVOPS_REAL_GIT_BIN="$REAL_GIT" bash "$backup_helper" matches \
			--repo "$repo_path" --backup "$sync_backup_id" >/dev/null || {
			printf 'BLOCKED: canonical state changed after backup\n' >&2
			exit 1
		}
		printf 'PRESERVED_BACKUP_ID=%s\n' "$sync_backup_id"
		printf 'PRESERVED_BACKUP_DIR=%s\n' "$sync_backup_dir"
		printf 'RESTORE_COMMAND=%q restore --repo %q --backup %q --confirm RESTORE_DIRTY_WORKTREE_BACKUP\n' \
			"$backup_helper" "$repo_path" "$sync_backup_id"
		printf 'RECOVER_CLEAN_COMMAND=%q recover-clean --repo %q --backup %q --confirm RECOVER_DIRTY_WORKTREE_CLEAN\n' \
			"$backup_helper" "$repo_path" "$sync_backup_id"
		AIDEVOPS_REAL_GIT_BIN="$REAL_GIT" bash "$backup_helper" clean \
			--repo "$repo_path" --backup "$sync_backup_id" \
			--confirm CLEAN_VERIFIED_DIRTY_WORKTREE_BACKUP >/dev/null || {
			if AIDEVOPS_REAL_GIT_BIN="$REAL_GIT" bash "$backup_helper" matches \
				--repo "$repo_path" --backup "$sync_backup_id" >/dev/null 2>&1; then
				printf 'BLOCKED: canonical clean failed and pre-clean state was restored (backup %s)\n' \
					"$sync_backup_id" >&2
			else
				printf 'BLOCKED: canonical clean recovery is required (backup %s)\n' \
					"$sync_backup_id" >&2
			fi
			exit 1
		}
	fi

	# shellcheck source=shared-constants.sh
	source "${SCRIPT_DIR}/shared-constants.sh"
	if ! declare -F remove_canonical_worktree_owner >/dev/null 2>&1 ||
		! remove_canonical_worktree_owner "$repo_path"; then
		printf 'BLOCKED: invalid canonical ownership could not be cleared safely\n' >&2
		exit 1
	fi
	current_branch=$("$REAL_GIT" -C "$repo_path" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
	current_local_sha=$("$REAL_GIT" -C "$repo_path" rev-parse --verify "${local_ref}^{commit}" 2>/dev/null || true)
	[[ "$target_branch" == "$current_branch" ]] || {
		printf 'BLOCKED: canonical branch changed during preservation\n' >&2
		exit 1
	}
	[[ "$local_sha" == "$current_local_sha" ]] || {
		printf 'BLOCKED: canonical local ref changed during preservation\n' >&2
		exit 1
	}
	[[ -z "$("$REAL_GIT" -C "$repo_path" status --porcelain)" ]] || {
		printf 'BLOCKED: canonical worktree remains dirty after preservation\n' >&2
		exit 1
	}
fi

preservation_ref=""
if [[ "$cmd" == "$FAST_FORWARD_CMD" ]] && ! "$REAL_GIT" -C "$repo_path" merge-base --is-ancestor "$local_ref" "$target_sha"; then
	printf 'BLOCKED: local %s has diverged from %s/%s\n' \
		"$target_branch" "$canonical_remote" "$target_branch" >&2
	exit 1
fi
if [[ "$cmd" != "$FAST_FORWARD_CMD" ]] && ! "$REAL_GIT" -C "$repo_path" merge-base --is-ancestor "$local_ref" "$target_sha"; then
	preservation_ref="refs/aidevops/canonical-recovery/issue-${issue_number}/${local_sha}"
	"$REAL_GIT" check-ref-format "$preservation_ref" >/dev/null || {
		printf 'BLOCKED: canonical preservation ref is invalid\n' >&2
		exit 1
	}
fi

audit_helper="${SCRIPT_DIR}/audit-log-helper.sh"
recovery_audit_file="${HOME}/.aidevops/logs/canonical-recovery-audit.jsonl"
[[ -x "$audit_helper" ]] || {
	printf 'BLOCKED: tamper-evident audit helper is unavailable\n' >&2
	exit 1
}
AUDIT_LOG_FILE="$recovery_audit_file" "$audit_helper" verify --quiet || {
	printf 'BLOCKED: audit chain verification failed\n' >&2
	exit 1
}
audit_message="Canonical default-branch recovery authorized"
[[ "$cmd" == "$FAST_FORWARD_CMD" ]] && audit_message="Canonical current-branch fast-forward authorized"
[[ "$cmd" == "$SYNC_MIRROR_CMD" ]] && audit_message="Canonical mirror synchronization authorized"
[[ "$cmd" == "$CLEAR_STALE_REBASE_CMD" ]] && audit_message="Converged stale rebase cleanup authorized"
[[ "$cmd" == "$CLEAR_ABANDONED_REBASE_CMD" ]] && audit_message="Abandoned stale rebase cleanup authorized"
AUDIT_LOG_FILE="$recovery_audit_file" AUDIT_QUIET=true "$audit_helper" log operation.verify "$audit_message" \
	--detail "issue=${issue_number:-none}" --detail "reason=${maintenance_reason:-none}" --detail "repo=${repo_path}" \
	--detail "operation=${cmd}" --detail "target=${target_branch}" --detail "target_source=${target_branch_source}" \
	--detail "remote=${canonical_remote}" --detail "registered_slug=${registered_slug:-none}" \
	--detail "expected_slug=${expected_slug}" \
	--detail "target_sha=${target_sha}" --detail "local_sha=${local_sha}" \
	--detail "preservation_ref=${preservation_ref:-none}" --detail "backup_id=${sync_backup_id:-none}" \
	--detail "stale_rebase_fingerprint=${stale_rebase_fingerprint:-none}" \
	--detail "stale_rebase_preservation=${stale_rebase_preservation_dir:-none}" >/dev/null || {
	printf 'BLOCKED: recovery audit record could not be written\n' >&2
	exit 1
}

[[ "$("$REAL_GIT" -C "$repo_path" rev-parse --verify "${remote_ref}^{commit}")" == "$target_sha" ]] || {
	printf 'BLOCKED: %s/%s tip changed during recovery\n' "$canonical_remote" "$target_branch" >&2
	exit 1
}
[[ "$("$REAL_GIT" -C "$repo_path" rev-parse --verify "${local_ref}^{commit}")" == "$local_sha" ]] || {
	printf 'BLOCKED: local %s tip changed during recovery\n' "$target_branch" >&2
	exit 1
}
if [[ "$cmd" == "$CLEAR_STALE_REBASE_CMD" || "$cmd" == "$CLEAR_ABANDONED_REBASE_CMD" ]]; then
	preservation_parent=${stale_rebase_preservation_dir%/*}
	mkdir -p "$preservation_parent"
	if [[ -d "$stale_rebase_preservation_dir" ]]; then
		preserved_rebase_fingerprint=""
		if [[ "$stale_rebase_cleanup_kind" == "$ABANDONED_REBASE_KIND" ]]; then
			preserved_rebase_fingerprint=$(rebase_marker_fingerprint \
				"${stale_rebase_preservation_dir}/rebase-merge" \
				"${stale_rebase_preservation_dir}/REBASE_HEAD") || true
		else
			preserved_rebase_fingerprint=$(rebase_state_fingerprint "$stale_rebase_preservation_dir") || true
		fi
		[[ "$preserved_rebase_fingerprint" == "$stale_rebase_fingerprint" ]] || {
			printf 'BLOCKED: existing stale rebase preservation evidence differs\n' >&2
			exit 1
		}
	else
		preservation_temp="${stale_rebase_preservation_dir}.tmp.$$"
		mkdir "$preservation_temp"
		if [[ "$stale_rebase_cleanup_kind" == "$ABANDONED_REBASE_KIND" ]]; then
			mkdir "${preservation_temp}/rebase-merge"
			cp -R "${stale_rebase_dir}/." "${preservation_temp}/rebase-merge/"
			cp "$rebase_head_path" "${preservation_temp}/REBASE_HEAD"
			preserved_rebase_fingerprint=$(rebase_marker_fingerprint \
				"${preservation_temp}/rebase-merge" "${preservation_temp}/REBASE_HEAD") || true
		else
			cp -R "${stale_rebase_dir}/." "$preservation_temp/"
			preserved_rebase_fingerprint=$(rebase_state_fingerprint "$preservation_temp") || true
		fi
		[[ "$preserved_rebase_fingerprint" == "$stale_rebase_fingerprint" ]] || {
			printf 'BLOCKED: stale rebase metadata copy could not be verified\n' >&2
			rm -rf "$preservation_temp"
			exit 1
		}
		mv "$preservation_temp" "$stale_rebase_preservation_dir"
	fi
	for metadata_commit in "$stale_head_sha" "$local_sha" "$target_sha" "$rebase_onto" \
		"$rebase_orig_head" "$stale_rebase_stopped_sha"; do
		[[ -n "$metadata_commit" ]] || continue
		preserve_rebase_commit_ref "$repo_path" "$issue_number" \
			"$stale_rebase_ref_namespace" "$metadata_commit" || {
			printf 'BLOCKED: stale rebase commit reference could not be preserved\n' >&2
			exit 1
		}
	done
	for sequence_file in "${stale_rebase_dir}/git-rebase-todo" "${stale_rebase_dir}/done"; do
		preserve_rebase_sequence_refs "$repo_path" "$issue_number" \
			"$stale_rebase_ref_namespace" "$sequence_file" || {
			printf 'BLOCKED: stale rebase sequence references are malformed or could not be preserved\n' >&2
			exit 1
		}
	done
	if [[ -f "${stale_rebase_dir}/git-rebase-todo.backup" ]]; then
		preserve_rebase_sequence_refs "$repo_path" "$issue_number" \
			"$stale_rebase_ref_namespace" "${stale_rebase_dir}/git-rebase-todo.backup" || {
			printf 'BLOCKED: stale rebase backup references are malformed or could not be preserved\n' >&2
			exit 1
		}
	fi
	preserve_rewritten_rebase_refs "$repo_path" "$issue_number" \
		"$stale_rebase_ref_namespace" "$stale_rebase_dir" || {
		printf 'BLOCKED: rewritten rebase references are malformed or could not be preserved\n' >&2
		exit 1
	}
	for object_metadata_file in "amend" "squash-onto" "update-refs"; do
		preserve_rebase_object_file_refs "$repo_path" "$issue_number" \
			"$stale_rebase_ref_namespace" "${stale_rebase_dir}/${object_metadata_file}" || {
			printf 'BLOCKED: auxiliary rebase object references could not be preserved\n' >&2
			exit 1
		}
	done
	if [[ -f "${stale_rebase_dir}/current-fixups" ]]; then
		preserve_rebase_sequence_refs "$repo_path" "$issue_number" \
			"$stale_rebase_ref_namespace" "${stale_rebase_dir}/current-fixups" || {
			printf 'BLOCKED: current rebase fixup references are malformed or could not be preserved\n' >&2
			exit 1
		}
	fi
	if [[ -n "${AIDEVOPS_CANONICAL_BEFORE_REBASE_CLEANUP_HOOK:-}" ]]; then
		"$AIDEVOPS_CANONICAL_BEFORE_REBASE_CLEANUP_HOOK" "$repo_path" "$stale_rebase_dir" || {
			printf 'BLOCKED: canonical pre-rebase-cleanup hook failed\n' >&2
			exit 1
		}
	fi
	current_rebase_fingerprint=""
	if [[ "$stale_rebase_cleanup_kind" == "$ABANDONED_REBASE_KIND" ]]; then
		current_rebase_fingerprint=$(rebase_marker_fingerprint "$stale_rebase_dir" "$rebase_head_path") || true
	else
		current_rebase_fingerprint=$(rebase_state_fingerprint "$stale_rebase_dir") || true
	fi
	[[ "$current_rebase_fingerprint" == "$stale_rebase_fingerprint" ]] &&
		[[ "$("$REAL_GIT" -C "$repo_path" rev-parse --verify "$HEAD_COMMIT_EXPR")" == "$stale_head_sha" ]] &&
		[[ "$("$REAL_GIT" -C "$repo_path" rev-parse --verify "${local_ref}^{commit}")" == "$local_sha" ]] &&
		[[ "$("$REAL_GIT" -C "$repo_path" rev-parse --verify "${remote_ref}^{commit}")" == "$target_sha" ]] &&
		[[ "$("$REAL_GIT" -C "$repo_path" write-tree)" == "$stale_index_tree" ]] &&
		[[ -z "$("$REAL_GIT" -C "$repo_path" status --porcelain)" ]] || {
		printf 'BLOCKED: canonical or rebase state changed before cleanup\n' >&2
		exit 1
	}
	stale_rebase_quarantine_dir="${stale_rebase_dir}.aidevops-quarantine.${issue_number}.$$"
	stale_rebase_quarantine_head="${rebase_head_path}.aidevops-quarantine.${issue_number}.$$"
	[[ ! -e "$stale_rebase_quarantine_dir" && ! -e "$stale_rebase_quarantine_head" ]] || {
		printf 'BLOCKED: stale rebase quarantine path already exists\n' >&2
		exit 1
	}
	if [[ -n "${AIDEVOPS_CANONICAL_BEFORE_REBASE_QUARANTINE_HOOK:-}" ]]; then
		"$AIDEVOPS_CANONICAL_BEFORE_REBASE_QUARANTINE_HOOK" "$repo_path" "$stale_rebase_dir" || {
			printf 'BLOCKED: canonical pre-rebase-quarantine hook failed\n' >&2
			exit 1
		}
	fi
	if [[ "$stale_rebase_cleanup_kind" == "$ABANDONED_REBASE_KIND" ]]; then
		cp "$rebase_head_path" "$stale_rebase_quarantine_head" || {
			printf 'BLOCKED: REBASE_HEAD could not be copied for quarantine\n' >&2
			exit 1
		}
		[[ "$("$REAL_GIT" hash-object "$stale_rebase_quarantine_head")" == "$("$REAL_GIT" hash-object "$rebase_head_path")" ]] || {
			printf 'BLOCKED: REBASE_HEAD quarantine copy could not be verified\n' >&2
			rm -f "$stale_rebase_quarantine_head"
			exit 1
		}
		if ! "$REAL_GIT" -C "$repo_path" update-ref -d REBASE_HEAD "$stale_rebase_stopped_sha"; then
			printf 'BLOCKED: REBASE_HEAD changed before compare-and-delete\n' >&2
			rm -f "$stale_rebase_quarantine_head"
			exit 1
		fi
		[[ ! -e "$rebase_head_path" ]] || {
			printf 'BLOCKED: REBASE_HEAD remained after compare-and-delete\n' >&2
			rm -f "$stale_rebase_quarantine_head"
			exit 1
		}
		if [[ -n "${AIDEVOPS_CANONICAL_BEFORE_REBASE_DIRECTORY_QUARANTINE_HOOK:-}" ]]; then
			if ! "$AIDEVOPS_CANONICAL_BEFORE_REBASE_DIRECTORY_QUARANTINE_HOOK" \
				"$repo_path" "$stale_rebase_dir" "$rebase_head_path" "$target_sha"; then
				if restore_deleted_rebase_head_copy "$repo_path" "$rebase_head_path" \
					"$stale_rebase_stopped_sha" "$stale_rebase_quarantine_head"; then
					printf 'BLOCKED: canonical pre-directory-quarantine hook failed\n' >&2
				else
					printf 'CRITICAL: pre-directory-quarantine hook failed and REBASE_HEAD recovery evidence was retained\n' >&2
				fi
				exit 1
			fi
		fi
	fi
	mv "$stale_rebase_dir" "$stale_rebase_quarantine_dir" || {
		if [[ "$stale_rebase_cleanup_kind" == "$ABANDONED_REBASE_KIND" ]]; then
			if ! restore_deleted_rebase_head_copy "$repo_path" "$rebase_head_path" \
				"$stale_rebase_stopped_sha" "$stale_rebase_quarantine_head"; then
				printf 'CRITICAL: directory quarantine failed and REBASE_HEAD recovery evidence was retained\n' >&2
				exit 1
			fi
		fi
		printf 'BLOCKED: stale rebase metadata could not be quarantined\n' >&2
		exit 1
	}
	quarantined_rebase_fingerprint=""
	if [[ "$stale_rebase_cleanup_kind" == "$ABANDONED_REBASE_KIND" ]]; then
		quarantined_rebase_fingerprint=$(rebase_marker_fingerprint \
			"$stale_rebase_quarantine_dir" "$stale_rebase_quarantine_head") || true
	else
		quarantined_rebase_fingerprint=$(rebase_state_fingerprint "$stale_rebase_quarantine_dir") || true
	fi
	quarantine_valid=1
	[[ "$quarantined_rebase_fingerprint" == "$stale_rebase_fingerprint" ]] || quarantine_valid=0
	[[ ! -e "$stale_rebase_dir" && ! -e "$rebase_apply_dir" && ! -e "$rebase_head_path" ]] || quarantine_valid=0
	[[ "$("$REAL_GIT" -C "$repo_path" rev-parse --verify "$HEAD_COMMIT_EXPR")" == "$stale_head_sha" ]] || quarantine_valid=0
	[[ "$("$REAL_GIT" -C "$repo_path" rev-parse --verify "${local_ref}^{commit}")" == "$local_sha" ]] || quarantine_valid=0
	[[ "$("$REAL_GIT" -C "$repo_path" rev-parse --verify "${remote_ref}^{commit}")" == "$target_sha" ]] || quarantine_valid=0
	[[ "$("$REAL_GIT" -C "$repo_path" write-tree)" == "$stale_index_tree" ]] || quarantine_valid=0
	[[ -z "$("$REAL_GIT" -C "$repo_path" status --porcelain)" ]] || quarantine_valid=0
	if [[ "$quarantine_valid" -ne 1 ]]; then
		if restore_quarantined_rebase_state "$repo_path" "$stale_rebase_dir" "$rebase_head_path" \
			"$stale_rebase_quarantine_dir" "$stale_rebase_quarantine_head" \
			"$stale_rebase_cleanup_kind" "$stale_rebase_stopped_sha"; then
			printf 'BLOCKED: canonical or rebase state changed during quarantine; metadata restored\n' >&2
		else
			printf 'CRITICAL: quarantined stale rebase metadata requires manual recovery\n' >&2
		fi
		exit 1
	fi
	rm -rf "$stale_rebase_quarantine_dir"
	[[ "$stale_rebase_cleanup_kind" != "$ABANDONED_REBASE_KIND" ]] || rm -f "$stale_rebase_quarantine_head"
	[[ ! -e "$stale_rebase_dir" && ! -e "$rebase_apply_dir" && ! -e "$rebase_head_path" ]] &&
		[[ ! -e "$stale_rebase_quarantine_dir" && ! -e "$stale_rebase_quarantine_head" ]] &&
		[[ "$("$REAL_GIT" -C "$repo_path" rev-parse --verify "$HEAD_COMMIT_EXPR")" == "$stale_head_sha" ]] &&
		[[ "$("$REAL_GIT" -C "$repo_path" rev-parse --verify "${local_ref}^{commit}")" == "$local_sha" ]] &&
		[[ "$("$REAL_GIT" -C "$repo_path" rev-parse --verify "${remote_ref}^{commit}")" == "$target_sha" ]] &&
		[[ "$("$REAL_GIT" -C "$repo_path" write-tree)" == "$stale_index_tree" ]] &&
		[[ -z "$("$REAL_GIT" -C "$repo_path" status --porcelain)" ]] || {
		printf 'CRITICAL: stale rebase cleanup changed canonical repository state\n' >&2
		exit 1
	}
	if [[ "$stale_rebase_cleanup_kind" == "$ABANDONED_REBASE_KIND" ]]; then
		printf 'CLEARED_ABANDONED_STALE_REBASE=true\n'
	else
		printf 'CLEARED_CONVERGED_STALE_REBASE=true\n'
	fi
	printf 'PRESERVED_REBASE_DIR=%s\n' "$stale_rebase_preservation_dir"
	exit 0
fi
if [[ "$cmd" == "$SYNC_MIRROR_CMD" && -n "$preservation_ref" ]]; then
	existing_preservation_sha=$("$REAL_GIT" -C "$repo_path" rev-parse --verify "${preservation_ref}^{commit}" 2>/dev/null || true)
	if [[ -n "$existing_preservation_sha" && "$existing_preservation_sha" != "$local_sha" ]]; then
		printf 'BLOCKED: canonical preservation ref already points elsewhere\n' >&2
		exit 1
	fi
	if [[ -z "$existing_preservation_sha" ]]; then
		"$REAL_GIT" -C "$repo_path" update-ref "$preservation_ref" "$local_sha" \
			"0000000000000000000000000000000000000000" || {
			printf 'BLOCKED: canonical preservation ref could not be created\n' >&2
			exit 1
		}
	fi
	[[ "$("$REAL_GIT" -C "$repo_path" rev-parse --verify "${preservation_ref}^{commit}")" == "$local_sha" ]] || {
		printf 'BLOCKED: divergent canonical commit was not preserved\n' >&2
		exit 1
	}
fi
if [[ "$cmd" == "$FAST_FORWARD_CMD" || "$cmd" == "$SYNC_MIRROR_CMD" ]]; then
	fast_forward_reflog="aidevops canonical fast-forward"
	[[ "$cmd" == "$SYNC_MIRROR_CMD" ]] && fast_forward_reflog="aidevops canonical mirror synchronization"
	current_branch=$("$REAL_GIT" -C "$repo_path" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
	[[ "$current_branch" == "$target_branch" ]] || {
		printf 'BLOCKED: canonical branch changed during fast-forward\n' >&2
		exit 1
	}
	[[ -z "$("$REAL_GIT" -C "$repo_path" status --porcelain)" ]] || {
		printf 'BLOCKED: canonical worktree changed during fast-forward\n' >&2
		exit 1
	}
	"$REAL_GIT" -C "$repo_path" read-tree --dry-run -u -m "$local_sha" "$target_sha" || {
		printf 'BLOCKED: canonical worktree cannot be updated without overwriting local changes\n' >&2
		exit 1
	}
	if [[ -n "${AIDEVOPS_CANONICAL_BEFORE_REF_UPDATE_HOOK:-}" ]]; then
		"$AIDEVOPS_CANONICAL_BEFORE_REF_UPDATE_HOOK" "$repo_path" "$target_branch" "$local_sha" "$target_sha" || {
			printf 'BLOCKED: canonical pre-update hook failed\n' >&2
			exit 1
		}
	fi
	if ! printf '%s\n' \
		'start' \
		"verify ${remote_ref} ${target_sha}" \
		"update ${local_ref} ${target_sha} ${local_sha}" \
		'prepare' \
		'commit' | "$REAL_GIT" -C "$repo_path" update-ref \
		-m "${fast_forward_reflog} for ${audit_reference}" --stdin >/dev/null; then
		printf 'BLOCKED: canonical local or %s ref changed during fast-forward\n' "$canonical_remote" >&2
		exit 1
	fi
	current_branch=$("$REAL_GIT" -C "$repo_path" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
	current_remote_sha=$("$REAL_GIT" -C "$repo_path" rev-parse --verify "${remote_ref}^{commit}" 2>/dev/null || true)
	if [[ "$current_branch" != "$target_branch" || "$current_remote_sha" != "$target_sha" ]]; then
		if ! "$REAL_GIT" -C "$repo_path" update-ref \
			-m "${fast_forward_reflog} rollback for issue ${issue_number}" \
			"$local_ref" "$local_sha" "$target_sha"; then
			printf 'CRITICAL: canonical branch changed after compare-and-swap and the local ref rollback failed\n' >&2
			exit 1
		fi
		printf 'BLOCKED: canonical branch or %s ref changed during fast-forward; local ref rolled back\n' \
			"$canonical_remote" >&2
		exit 1
	fi
	if [[ -n "${AIDEVOPS_CANONICAL_BEFORE_WORKTREE_UPDATE_HOOK:-}" ]]; then
		if ! "$AIDEVOPS_CANONICAL_BEFORE_WORKTREE_UPDATE_HOOK" "$repo_path" "$target_branch" "$local_sha" "$target_sha"; then
			if ! "$REAL_GIT" -C "$repo_path" update-ref \
				-m "${fast_forward_reflog} rollback for issue ${issue_number}" \
				"$local_ref" "$local_sha" "$target_sha"; then
				printf 'CRITICAL: canonical pre-worktree-update hook failed and the local ref rollback also failed\n' >&2
				exit 1
			fi
			printf 'BLOCKED: canonical pre-worktree-update hook failed\n' >&2
			exit 1
		fi
	fi
	if ! "$REAL_GIT" -C "$repo_path" read-tree -u -m "$local_sha" "$target_sha"; then
		if ! "$REAL_GIT" -C "$repo_path" update-ref \
			-m "${fast_forward_reflog} rollback for issue ${issue_number}" \
			"$local_ref" "$local_sha" "$target_sha"; then
			printf 'CRITICAL: canonical worktree update failed and the local ref rollback also failed\n' >&2
			exit 1
		fi
		printf 'BLOCKED: canonical worktree update failed; local ref rolled back\n' >&2
		exit 1
	fi
	post_update_branch=$("$REAL_GIT" -C "$repo_path" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
	post_update_remote_sha=$("$REAL_GIT" -C "$repo_path" rev-parse --verify "${remote_ref}^{commit}" 2>/dev/null || true)
	if [[ "$post_update_branch" != "$target_branch" || "$post_update_remote_sha" != "$target_sha" ]]; then
		if [[ "$post_update_branch" == "$target_branch" ]]; then
			restore_worktree_sha="$local_sha"
		else
			restore_worktree_sha=$("$REAL_GIT" -C "$repo_path" rev-parse --verify "$HEAD_COMMIT_EXPR" 2>/dev/null || true)
		fi
		if ! "$REAL_GIT" -C "$repo_path" update-ref \
			-m "${fast_forward_reflog} rollback for issue ${issue_number}" \
			"$local_ref" "$local_sha" "$target_sha"; then
			printf 'CRITICAL: canonical state changed after the worktree update and the local ref rollback failed\n' >&2
			exit 1
		fi
		[[ -n "$restore_worktree_sha" ]] || restore_worktree_sha="$local_sha"
		if ! "$REAL_GIT" -C "$repo_path" read-tree --dry-run -u -m "$target_sha" "$restore_worktree_sha" ||
			! "$REAL_GIT" -C "$repo_path" read-tree -u -m "$target_sha" "$restore_worktree_sha"; then
			printf 'CRITICAL: canonical ref was rolled back but the concurrent branch worktree could not be restored\n' >&2
			exit 1
		fi
		current_head_sha=$("$REAL_GIT" -C "$repo_path" rev-parse --verify "$HEAD_COMMIT_EXPR" 2>/dev/null || true)
		if [[ "$current_head_sha" != "$restore_worktree_sha" ]] ||
			[[ -n "$("$REAL_GIT" -C "$repo_path" status --porcelain)" ]]; then
			printf 'CRITICAL: canonical ref was rolled back but the concurrent branch remains inconsistent\n' >&2
			exit 1
		fi
		printf 'BLOCKED: canonical branch or %s ref changed during worktree update; ref and worktree restored\n' \
			"$canonical_remote" >&2
		exit 1
	fi
	[[ "$("$REAL_GIT" -C "$repo_path" rev-parse HEAD)" == "$target_sha" ]] || exit 1
	[[ "$("$REAL_GIT" -C "$repo_path" rev-parse --verify "${local_ref}^{commit}")" == "$target_sha" ]] || exit 1
	[[ "$("$REAL_GIT" -C "$repo_path" rev-parse --verify "${remote_ref}^{commit}")" == "$target_sha" ]] || exit 1
	[[ -z "$("$REAL_GIT" -C "$repo_path" status --porcelain)" ]] || exit 1
	if [[ "$maintenance_reason" == "$AIDEVOPS_UPDATE_REASON" ]] &&
		! fetch_aidevops_release_tag "$repo_path" "$canonical_remote"; then
		printf 'WARNING: exact release tag for the updated VERSION is not available from %s\n' \
			"$canonical_remote" >&2
	fi
	if [[ "$cmd" == "$SYNC_MIRROR_CMD" ]]; then
		if [[ "$maintenance_reason" == "$AIDEVOPS_UPDATE_REASON" && -n "$sync_backup_id" ]]; then
			retention_days="${AIDEVOPS_DIRTY_BACKUP_RETENTION_DAYS:-30}"
			[[ "$retention_days" =~ ^[0-9]+$ ]] || retention_days=30
			if ! AIDEVOPS_REAL_GIT_BIN="$REAL_GIT" bash "$backup_helper" acknowledge \
				--backup "$sync_backup_id" --confirm ACKNOWLEDGE_DIRTY_WORKTREE_BACKUP >/dev/null; then
				printf 'WARNING: synchronized backup remains open and requires manual acknowledgement: %s\n' \
					"$sync_backup_id" >&2
			elif ! AIDEVOPS_REAL_GIT_BIN="$REAL_GIT" bash "$backup_helper" prune \
				--force --retention-days "$retention_days" >/dev/null; then
				printf 'WARNING: synchronized mirror succeeded but expired backup pruning failed\n' >&2
			fi
		fi
		printf 'SYNCHRONIZED_CANONICAL_MIRROR=true\n'
		printf 'OLD_SHA=%s\n' "$local_sha"
		printf 'NEW_SHA=%s\n' "$target_sha"
		printf 'CANONICAL_BRANCH=%s\n' "$target_branch"
		printf 'BRANCH_SOURCE=%s\n' "$target_branch_source"
		printf 'PRESERVATION_REF=%s\n' "${preservation_ref:-none}"
	else
		printf 'Fast-forwarded canonical %s to %s/%s\n' \
			"$target_branch" "$canonical_remote" "$target_branch"
	fi
	exit 0
fi
if [[ -n "$preservation_ref" ]]; then
	existing_preservation_sha=$("$REAL_GIT" -C "$repo_path" rev-parse --verify "${preservation_ref}^{commit}" 2>/dev/null || true)
	if [[ -n "$existing_preservation_sha" && "$existing_preservation_sha" != "$local_sha" ]]; then
		printf 'BLOCKED: canonical preservation ref already points elsewhere\n' >&2
		exit 1
	fi
	if [[ -z "$existing_preservation_sha" ]]; then
		"$REAL_GIT" -C "$repo_path" update-ref "$preservation_ref" "$local_sha" "0000000000000000000000000000000000000000"
	fi
	[[ "$("$REAL_GIT" -C "$repo_path" rev-parse --verify "${preservation_ref}^{commit}")" == "$local_sha" ]] || {
		printf 'BLOCKED: divergent canonical commit was not preserved\n' >&2
		exit 1
	}
	"$REAL_GIT" -C "$repo_path" update-ref "$local_ref" "$target_sha" "$local_sha"
fi
"$REAL_GIT" -C "$repo_path" switch "$target_branch"
[[ "$("$REAL_GIT" -C "$repo_path" branch --show-current)" == "$target_branch" ]] || exit 1
"$REAL_GIT" -C "$repo_path" merge --ff-only "$target_sha"
[[ "$("$REAL_GIT" -C "$repo_path" rev-parse HEAD)" == "$target_sha" ]] || exit 1
[[ "$("$REAL_GIT" -C "$repo_path" rev-parse --verify "${remote_ref}^{commit}")" == "$target_sha" ]] || exit 1
if [[ -n "$preservation_ref" ]]; then
	printf 'Preserved divergent canonical tip %s at %s\n' "$local_sha" "$preservation_ref"
fi
printf 'Restored canonical repository to %s\n' "$target_branch"

#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
# shellcheck source=shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh"
if [[ -f "${SCRIPT_DIR}/portable-stat.sh" ]]; then
	# shellcheck source=portable-stat.sh
	source "${SCRIPT_DIR}/portable-stat.sh"
fi

BACKUP_ROOT="${AIDEVOPS_DIRTY_BACKUP_ROOT:-${HOME}/.aidevops/.agent-workspace/tmp/dirty-main-backups}"
DEFAULT_RETENTION_DAYS="${AIDEVOPS_DIRTY_BACKUP_RETENTION_DAYS:-30}"
REAL_GIT="${AIDEVOPS_REAL_GIT_BIN:-/usr/bin/git}"
BACKUP_SCHEMA="dirty-worktree-backup-v2"
UNTRACKED_LIST_NAME="untracked-files.nul"

CAPTURE_HEAD=""
CAPTURE_BRANCH=""
CAPTURE_INDEX_TREE=""
CAPTURE_WORKTREE_TREE=""
CAPTURE_STATUS_HASH=""
CAPTURE_FINGERPRINT=""

usage() {
	cat <<'USAGE'
Usage: dirty-worktree-backup-helper.sh <command> [options]

Commands:
  backup [--repo PATH] [--reason TEXT] [--pr N] [--issue N] [--session KEY]
         [--task ID] [--operation-id ID] [--machine]
      Preserve tracked, staged, and untracked state without changing the worktree.
  verify --repo PATH --backup ID
      Verify hashes, Git objects, and the stable backup ref.
  matches --repo PATH --backup ID
      Verify that the current worktree still byte-matches a backup.
  clean --repo PATH --backup ID --confirm CLEAN_VERIFIED_DIRTY_WORKTREE_BACKUP
      Remove only state that still exactly matches the verified backup.
  restore --repo PATH --backup ID --confirm RESTORE_DIRTY_WORKTREE_BACKUP
      Restore the original HEAD, index, worktree, and untracked state.
  acknowledge --backup ID --confirm ACKNOWLEDGE_DIRTY_WORKTREE_BACKUP
      Mark an open backup eligible for retention pruning.
  list
      List recorded dirty-worktree backups.
  prune [--dry-run] [--force] [--retention-days N]
      Remove only acknowledged/restored backups that are terminal or stale.

Environment:
  AIDEVOPS_DIRTY_BACKUP_ROOT            Override backup directory.
  AIDEVOPS_DIRTY_BACKUP_RETENTION_DAYS Override stale-backup retention (default: 30).
USAGE
	return 0
}

timestamp_utc() {
	date -u '+%Y%m%dT%H%M%SZ'
	return 0
}

iso_utc() {
	date -u '+%Y-%m-%dT%H:%M:%SZ'
	return 0
}

safe_slug() {
	local raw="$1"
	printf '%s' "$raw" | LC_ALL=C tr -c 'A-Za-z0-9._-' '-' | cut -c 1-80
	return 0
}

hash_file() {
	local file_path="$1"
	python3 - "$file_path" <<'PY'
import hashlib
import pathlib
import sys

digest = hashlib.sha256()
with pathlib.Path(sys.argv[1]).open("rb") as handle:
    for block in iter(lambda: handle.read(1024 * 1024), b""):
        digest.update(block)
print(digest.hexdigest())
PY
	return $?
}

fingerprint_values() {
	local head_sha="$1"
	local index_tree="$2"
	local worktree_tree="$3"
	local status_hash="$4"
	python3 - "$head_sha" "$index_tree" "$worktree_tree" "$status_hash" <<'PY'
import hashlib
import sys

payload = "".join(f"{value}\n" for value in sys.argv[1:]).encode()
print(hashlib.sha256(payload).hexdigest())
PY
	return $?
}

manifest_write() {
	local manifest_path="$1"
	local key="$2"
	local value="$3"
	value="${value//$'\t'/ }"
	value="${value//$'\n'/ }"
	value="${value//$'\r'/ }"
	printf '%s\t%s\n' "$key" "$value" >>"$manifest_path"
	return 0
}

manifest_value() {
	local manifest_path="$1"
	local key="$2"
	awk -F '\t' -v wanted="$key" '$1 == wanted { print substr($0, length($1) + 2); exit }' "$manifest_path" 2>/dev/null || true
	return 0
}

manifest_set() {
	local manifest_path="$1"
	local key="$2"
	local value="$3"
	local temp_path="${manifest_path}.tmp.$$"
	awk -F '\t' -v wanted="$key" -v replacement="$value" '
		BEGIN { found = 0 }
		$1 == wanted { print wanted "\t" replacement; found = 1; next }
		{ print }
		END { if (!found) print wanted "\t" replacement }
	' "$manifest_path" >"$temp_path" || return 1
	mv "$temp_path" "$manifest_path" || return 1
	return 0
}

repo_slug_from_remote() {
	local repo_path="$1"
	local remote_url=""
	remote_url=$("$REAL_GIT" -C "$repo_path" remote get-url origin 2>/dev/null || true)
	remote_url=${remote_url%.git}
	case "$remote_url" in
	https://github.com/*/*)
		printf '%s\n' "${remote_url#https://github.com/}"
		return 0
		;;
	git@github.com:*/*)
		printf '%s\n' "${remote_url#git@github.com:}"
		return 0
		;;
	esac
	return 1
}

repo_status() {
	local repo_path="$1"
	"$REAL_GIT" -C "$repo_path" status --porcelain=v1 2>/dev/null
	return $?
}

resolve_repo_path() {
	local repo_path="$1"
	[[ -n "$repo_path" && -d "$repo_path" ]] || return 1
	(cd "$repo_path" && pwd -P) || return 1
	return 0
}

resolve_backup_dir() {
	local backup_id="$1"
	[[ -n "$backup_id" ]] || return 1
	[[ "$backup_id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || return 1
	local backup_dir="${BACKUP_ROOT}/${backup_id}"
	[[ -d "$backup_dir" && -f "$backup_dir/manifest.tsv" ]] || return 1
	printf '%s\n' "$backup_dir"
	return 0
}

copy_untracked_files() {
	local repo_path="$1"
	local backup_dir="$2"
	local nul_path="$backup_dir"/"$UNTRACKED_LIST_NAME"
	local rel_path=""
	local target_path=""

	: >"$backup_dir/untracked-files.txt"
	while IFS= read -r -d '' rel_path; do
		[[ -n "$rel_path" ]] || continue
		printf '%s\n' "$rel_path" >>"$backup_dir/untracked-files.txt"
		target_path="$backup_dir/untracked/$rel_path"
		mkdir -p "$(dirname "$target_path")"
		cp -Pp "$repo_path/$rel_path" "$target_path"
	done <"$nul_path"
	return 0
}

capture_state() {
	local repo_path="$1"
	local capture_dir="$2"
	local index_path=""
	local temp_index="$capture_dir/worktree.index"

	mkdir -p "$capture_dir/untracked"
	CAPTURE_HEAD=$("$REAL_GIT" -C "$repo_path" rev-parse --verify 'HEAD^{commit}') || return 1
	CAPTURE_BRANCH=$("$REAL_GIT" -C "$repo_path" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
	[[ -n "$CAPTURE_BRANCH" ]] || CAPTURE_BRANCH="detached"
	CAPTURE_INDEX_TREE=$("$REAL_GIT" -C "$repo_path" write-tree) || return 1
	index_path=$("$REAL_GIT" -C "$repo_path" rev-parse --git-path index) || return 1
	[[ "$index_path" == /* ]] || index_path="$repo_path/$index_path"
	cp -p "$index_path" "$temp_index" || return 1
	GIT_INDEX_FILE="$temp_index" "$REAL_GIT" -C "$repo_path" add -A -- . || return 1
	CAPTURE_WORKTREE_TREE=$(GIT_INDEX_FILE="$temp_index" "$REAL_GIT" -C "$repo_path" write-tree) || return 1
	rm -f "$temp_index"

	"$REAL_GIT" -C "$repo_path" status --short --branch >"$capture_dir/git-status.txt"
	"$REAL_GIT" -C "$repo_path" status --porcelain=v1 -z >"$capture_dir/git-status.nul"
	"$REAL_GIT" -C "$repo_path" diff --binary >"$capture_dir/tracked.patch"
	"$REAL_GIT" -C "$repo_path" diff --cached --binary >"$capture_dir/staged.patch"
	"$REAL_GIT" -C "$repo_path" ls-files --others --exclude-standard -z >"$capture_dir"/"$UNTRACKED_LIST_NAME"
	copy_untracked_files "$repo_path" "$capture_dir" || return 1
	CAPTURE_STATUS_HASH=$(hash_file "$capture_dir/git-status.nul") || return 1
	CAPTURE_FINGERPRINT=$(fingerprint_values "$CAPTURE_HEAD" "$CAPTURE_INDEX_TREE" \
		"$CAPTURE_WORKTREE_TREE" "$CAPTURE_STATUS_HASH") || return 1
	return 0
}

create_snapshot_commits() {
	local repo_path="$1"
	local backup_ref="$2"
	local index_commit=""
	local worktree_commit=""
	local zero_sha="0000000000000000000000000000000000000000"
	local identity_name="aidevops recovery"
	local identity_email="recovery@localhost"

	index_commit=$(printf 'aidevops dirty backup index\n' |
		GIT_AUTHOR_NAME="$identity_name" GIT_AUTHOR_EMAIL="$identity_email" \
			GIT_COMMITTER_NAME="$identity_name" GIT_COMMITTER_EMAIL="$identity_email" \
			"$REAL_GIT" -C "$repo_path" commit-tree "$CAPTURE_INDEX_TREE" -p "$CAPTURE_HEAD") || return 1
	worktree_commit=$(printf 'aidevops dirty backup worktree\n' |
		GIT_AUTHOR_NAME="$identity_name" GIT_AUTHOR_EMAIL="$identity_email" \
			GIT_COMMITTER_NAME="$identity_name" GIT_COMMITTER_EMAIL="$identity_email" \
			"$REAL_GIT" -C "$repo_path" commit-tree "$CAPTURE_WORKTREE_TREE" -p "$index_commit") || return 1
	"$REAL_GIT" -C "$repo_path" update-ref "$backup_ref" "$worktree_commit" "$zero_sha" || return 1
	printf '%s\t%s\n' "$index_commit" "$worktree_commit"
	return 0
}

delete_backup_ref() {
	local repo_path="$1"
	local backup_ref="$2"
	local expected_commit="$3"
	"$REAL_GIT" -C "$repo_path" update-ref -d "$backup_ref" "$expected_commit" 2>/dev/null || true
	return 0
}

write_backup_manifest() {
	local manifest_path="$1"
	local repo_path="$2"
	local reason="$3"
	local pr_number="$4"
	local issue_number="$5"
	local session_key="$6"
	local task_id="$7"
	local backup_id="$8"
	local backup_ref="$9"
	local index_commit="${10}"
	local worktree_commit="${11}"
	local repo_slug=""
	local manifest_dir=""
	local created_at=""
	local tracked_patch_hash=""
	local staged_patch_hash=""
	local untracked_list_hash=""
	repo_slug=$(repo_slug_from_remote "$repo_path" || true)
	manifest_dir=$(dirname "$manifest_path") || return 1
	created_at=$(iso_utc) || return 1
	tracked_patch_hash=$(hash_file "$manifest_dir/tracked.patch") || return 1
	staged_patch_hash=$(hash_file "$manifest_dir/staged.patch") || return 1
	untracked_list_hash=$(hash_file "$manifest_dir"/"$UNTRACKED_LIST_NAME") || return 1

	: >"$manifest_path"
	manifest_write "$manifest_path" schema "$BACKUP_SCHEMA"
	manifest_write "$manifest_path" created_at "$created_at"
	manifest_write "$manifest_path" state open
	manifest_write "$manifest_path" backup_id "$backup_id"
	manifest_write "$manifest_path" repo_path "$repo_path"
	manifest_write "$manifest_path" repo_slug "$repo_slug"
	manifest_write "$manifest_path" branch "$CAPTURE_BRANCH"
	manifest_write "$manifest_path" head "$CAPTURE_HEAD"
	manifest_write "$manifest_path" index_tree "$CAPTURE_INDEX_TREE"
	manifest_write "$manifest_path" worktree_tree "$CAPTURE_WORKTREE_TREE"
	manifest_write "$manifest_path" index_commit "$index_commit"
	manifest_write "$manifest_path" worktree_commit "$worktree_commit"
	manifest_write "$manifest_path" backup_ref "$backup_ref"
	manifest_write "$manifest_path" status_sha256 "$CAPTURE_STATUS_HASH"
	manifest_write "$manifest_path" fingerprint "$CAPTURE_FINGERPRINT"
	manifest_write "$manifest_path" tracked_patch_sha256 "$tracked_patch_hash"
	manifest_write "$manifest_path" staged_patch_sha256 "$staged_patch_hash"
	manifest_write "$manifest_path" untracked_list_sha256 "$untracked_list_hash"
	manifest_write "$manifest_path" session "$session_key"
	manifest_write "$manifest_path" task "$task_id"
	manifest_write "$manifest_path" pr "$pr_number"
	manifest_write "$manifest_path" issue "$issue_number"
	manifest_write "$manifest_path" reason "$reason"
	manifest_write "$manifest_path" restore_confirm RESTORE_DIRTY_WORKTREE_BACKUP
	return 0
}

verify_backup_dir() {
	local repo_path="$1"
	local backup_dir="$2"
	local manifest_path="$backup_dir/manifest.tsv"
	local backup_id=""
	local backup_ref=""
	local head_sha=""
	local index_commit=""
	local worktree_commit=""
	local index_tree=""
	local worktree_tree=""
	local status_hash=""
	local expected_fingerprint=""
	local actual=""
	local expected_hash=""

	[[ "$(manifest_value "$manifest_path" schema)" == "$BACKUP_SCHEMA" ]] || return 1
	[[ "$(manifest_value "$manifest_path" repo_path)" == "$repo_path" ]] || return 1
	backup_id=$(manifest_value "$manifest_path" backup_id)
	backup_ref=$(manifest_value "$manifest_path" backup_ref)
	head_sha=$(manifest_value "$manifest_path" head)
	index_commit=$(manifest_value "$manifest_path" index_commit)
	worktree_commit=$(manifest_value "$manifest_path" worktree_commit)
	index_tree=$(manifest_value "$manifest_path" index_tree)
	worktree_tree=$(manifest_value "$manifest_path" worktree_tree)
	status_hash=$(manifest_value "$manifest_path" status_sha256)
	[[ "$backup_id" == "$(basename "$backup_dir")" ]] || return 1
	[[ "$backup_ref" == "refs/aidevops/dirty-worktree-backups/${backup_id}" ]] || return 1
	for actual in "$head_sha" "$index_commit" "$worktree_commit" "$index_tree" "$worktree_tree"; do
		[[ "$actual" =~ ^[0-9a-f]{40}$ || "$actual" =~ ^[0-9a-f]{64}$ ]] || return 1
	done
	[[ "$status_hash" =~ ^[0-9a-f]{64}$ ]] || return 1
	actual=$("$REAL_GIT" -C "$repo_path" rev-parse --verify "${backup_ref}^{commit}" 2>/dev/null || true)
	[[ "$actual" == "$worktree_commit" ]] || return 1
	actual=$("$REAL_GIT" -C "$repo_path" rev-parse "${worktree_commit}^{tree}") || return 1
	[[ "$actual" == "$worktree_tree" ]] || return 1
	actual=$("$REAL_GIT" -C "$repo_path" rev-parse "${worktree_commit}^1") || return 1
	[[ "$actual" == "$index_commit" ]] || return 1
	actual=$("$REAL_GIT" -C "$repo_path" rev-parse "${index_commit}^{tree}") || return 1
	[[ "$actual" == "$index_tree" ]] || return 1
	actual=$("$REAL_GIT" -C "$repo_path" rev-parse "${index_commit}^1") || return 1
	[[ "$actual" == "$head_sha" ]] || return 1
	actual=$(hash_file "$backup_dir/git-status.nul") || return 1
	[[ "$actual" == "$status_hash" ]] || return 1
	actual=$(hash_file "$backup_dir/tracked.patch") || return 1
	expected_hash=$(manifest_value "$manifest_path" tracked_patch_sha256)
	[[ "$actual" == "$expected_hash" ]] || return 1
	actual=$(hash_file "$backup_dir/staged.patch") || return 1
	expected_hash=$(manifest_value "$manifest_path" staged_patch_sha256)
	[[ "$actual" == "$expected_hash" ]] || return 1
	actual=$(hash_file "$backup_dir"/"$UNTRACKED_LIST_NAME") || return 1
	expected_hash=$(manifest_value "$manifest_path" untracked_list_sha256)
	[[ "$actual" == "$expected_hash" ]] || return 1
	expected_fingerprint=$(fingerprint_values "$head_sha" "$index_tree" "$worktree_tree" "$status_hash") || return 1
	[[ "$expected_fingerprint" == "$(manifest_value "$manifest_path" fingerprint)" ]] || return 1
	return 0
}

current_state_matches_backup() {
	local repo_path="$1"
	local backup_dir="$2"
	local manifest_path="$backup_dir/manifest.tsv"
	local capture_dir=""
	local expected_fingerprint=""
	expected_fingerprint=$(manifest_value "$manifest_path" fingerprint)
	capture_dir=$(mktemp -d "${BACKUP_ROOT}/.verify.XXXXXXXX") || return 1
	if ! capture_state "$repo_path" "$capture_dir"; then
		rm -rf "$capture_dir"
		return 1
	fi
	rm -rf "$capture_dir"
	[[ "$CAPTURE_FINGERPRINT" == "$expected_fingerprint" ]]
	return $?
}

parse_repo_backup_args() {
	PARSED_REPO_PATH=""
	PARSED_BACKUP_ID=""
	PARSED_CONFIRMATION=""
	while [[ $# -gt 0 ]]; do
		local arg="$1"
		case "$arg" in
		--repo)
			PARSED_REPO_PATH="${2:-}"
			shift 2
			;;
		--backup)
			PARSED_BACKUP_ID="${2:-}"
			shift 2
			;;
		--confirm)
			PARSED_CONFIRMATION="${2:-}"
			shift 2
			;;
		*) return 1 ;;
		esac
	done
	return 0
}

parse_backup_args() {
	PARSED_BACKUP_REPO="$PWD"
	PARSED_BACKUP_REASON="dirty worktree preservation"
	PARSED_BACKUP_PR=""
	PARSED_BACKUP_ISSUE=""
	PARSED_BACKUP_SESSION="${AIDEVOPS_SESSION_KEY:-${WORKER_SESSION_KEY:-}}"
	PARSED_BACKUP_TASK="${AIDEVOPS_TASK_ID:-${WORKER_TASK_NUMBER:-}}"
	PARSED_BACKUP_OPERATION=""
	PARSED_BACKUP_MACHINE=false
	PARSED_BACKUP_HELP=false
	while [[ $# -gt 0 ]]; do
		local arg="$1"
		case "$arg" in
		--repo)
			PARSED_BACKUP_REPO="${2:-}"
			shift 2
			;;
		--reason)
			PARSED_BACKUP_REASON="${2:-}"
			shift 2
			;;
		--pr)
			PARSED_BACKUP_PR="${2:-}"
			shift 2
			;;
		--issue)
			PARSED_BACKUP_ISSUE="${2:-}"
			shift 2
			;;
		--session)
			PARSED_BACKUP_SESSION="${2:-}"
			shift 2
			;;
		--task)
			PARSED_BACKUP_TASK="${2:-}"
			shift 2
			;;
		--operation-id)
			PARSED_BACKUP_OPERATION="${2:-}"
			shift 2
			;;
		--machine)
			PARSED_BACKUP_MACHINE=true
			shift
			;;
		--help | -h)
			usage
			PARSED_BACKUP_HELP=true
			shift
			;;
		*)
			print_error "Unknown backup option: $arg"
			return 1
			;;
		esac
	done
	return 0
}

cmd_backup() {
	parse_backup_args "$@" || return 1
	[[ "$PARSED_BACKUP_HELP" == true ]] && return 0
	local repo_path="$PARSED_BACKUP_REPO"
	local reason="$PARSED_BACKUP_REASON"
	local pr_number="$PARSED_BACKUP_PR"
	local issue_number="$PARSED_BACKUP_ISSUE"
	local session_key="$PARSED_BACKUP_SESSION"
	local task_id="$PARSED_BACKUP_TASK"
	local operation_id="$PARSED_BACKUP_OPERATION"
	local machine="$PARSED_BACKUP_MACHINE"
	repo_path=$(resolve_repo_path "$repo_path") || return 1
	local status_output=""
	status_output=$(repo_status "$repo_path") || {
		print_error "Cannot read worktree status safely: $repo_path"
		return 1
	}
	if [[ -z "$status_output" ]]; then
		print_info "No dirty worktree changes to back up: $repo_path"
		return 0
	fi

	(umask 0077 && mkdir -p "$BACKUP_ROOT") || return 1
	local capture_dir=""
	capture_dir=$(mktemp -d "${BACKUP_ROOT}/.capture.XXXXXXXX") || return 1
	trap 'rm -rf "${capture_dir:-}"' RETURN
	capture_state "$repo_path" "$capture_dir" || return 1
	local repo_name=""
	repo_name=$(basename "$repo_path")
	local id_component="${operation_id:-$(timestamp_utc)-$$}"
	local backup_id=""
	backup_id="$(safe_slug "$repo_name")-$(safe_slug "$CAPTURE_BRANCH")-$(safe_slug "$id_component")-${CAPTURE_FINGERPRINT:0:16}"
	local backup_dir="${BACKUP_ROOT}/${backup_id}"
	if [[ -d "$backup_dir" ]]; then
		verify_backup_dir "$repo_path" "$backup_dir" || return 1
		current_state_matches_backup "$repo_path" "$backup_dir" || return 1
		rm -rf "$capture_dir"
		capture_dir=""
		[[ "$machine" == true ]] && printf '%s|%s\n' "$backup_id" "$backup_dir" || printf '%s\n' "$backup_dir"
		return 0
	fi
	local backup_ref="refs/aidevops/dirty-worktree-backups/${backup_id}"
	"$REAL_GIT" check-ref-format "$backup_ref" >/dev/null 2>&1 || return 1
	local commit_pair=""
	commit_pair=$(create_snapshot_commits "$repo_path" "$backup_ref") || return 1
	local index_commit="${commit_pair%%$'\t'*}"
	local worktree_commit="${commit_pair#*$'\t'}"
	write_backup_manifest "$capture_dir/manifest.tsv" "$repo_path" "$reason" "$pr_number" \
		"$issue_number" "$session_key" "$task_id" "$backup_id" "$backup_ref" \
		"$index_commit" "$worktree_commit" || {
		delete_backup_ref "$repo_path" "$backup_ref" "$worktree_commit"
		return 1
	}
	if ! chmod 700 "$capture_dir" || ! chmod 600 "$capture_dir/manifest.tsv" ||
		! mv "$capture_dir" "$backup_dir"; then
		delete_backup_ref "$repo_path" "$backup_ref" "$worktree_commit"
		return 1
	fi
	capture_dir=""
	verify_backup_dir "$repo_path" "$backup_dir" || return 1
	if [[ "$machine" == true ]]; then
		printf '%s|%s\n' "$backup_id" "$backup_dir"
	else
		print_success "Backed up dirty worktree state: $backup_id"
		printf 'RESTORE_COMMAND=%q restore --repo %q --backup %q --confirm RESTORE_DIRTY_WORKTREE_BACKUP\n' "$0" "$repo_path" "$backup_id"
		printf '%s\n' "$backup_dir"
	fi
	return 0
}

cmd_verify() {
	parse_repo_backup_args "$@" || return 1
	local repo_path=""
	repo_path=$(resolve_repo_path "$PARSED_REPO_PATH") || return 1
	local backup_dir=""
	backup_dir=$(resolve_backup_dir "$PARSED_BACKUP_ID") || return 1
	verify_backup_dir "$repo_path" "$backup_dir" || return 1
	printf 'VERIFIED_BACKUP_ID=%s\n' "$PARSED_BACKUP_ID"
	return 0
}

cmd_matches() {
	parse_repo_backup_args "$@" || return 1
	local repo_path=""
	repo_path=$(resolve_repo_path "$PARSED_REPO_PATH") || return 1
	local backup_dir=""
	backup_dir=$(resolve_backup_dir "$PARSED_BACKUP_ID") || return 1
	verify_backup_dir "$repo_path" "$backup_dir" || return 1
	current_state_matches_backup "$repo_path" "$backup_dir" || return 1
	printf 'BACKUP_MATCH=true\n'
	return 0
}

remove_preserved_untracked() {
	local repo_path="$1"
	local nul_path="$2"
	python3 - "$repo_path" "$nul_path" <<'PY'
import os
import pathlib
import sys

root = pathlib.Path(sys.argv[1]).resolve()
paths = pathlib.Path(sys.argv[2]).read_bytes().split(b"\0")
for raw in paths:
    if not raw:
        continue
    relative = pathlib.Path(os.fsdecode(raw))
    if relative.is_absolute() or ".." in relative.parts:
        raise SystemExit("untracked path escaped repository")
    target_parent = (root / relative.parent).resolve(strict=False)
    if os.path.commonpath((str(root), str(target_parent))) != str(root):
        raise SystemExit("untracked path parent escaped repository")
    target = target_parent / relative.name
    if target.is_symlink() or target.is_file():
        target.unlink()
    elif target.exists():
        raise SystemExit(f"refusing unexpected untracked directory: {relative}")
    parent = target.parent
    while parent != root:
        try:
            parent.rmdir()
        except OSError:
            break
        parent = parent.parent
PY
	return $?
}

cmd_clean() {
	parse_repo_backup_args "$@" || return 1
	[[ "$PARSED_CONFIRMATION" == "CLEAN_VERIFIED_DIRTY_WORKTREE_BACKUP" ]] || return 1
	local repo_path=""
	repo_path=$(resolve_repo_path "$PARSED_REPO_PATH") || return 1
	local backup_dir=""
	backup_dir=$(resolve_backup_dir "$PARSED_BACKUP_ID") || return 1
	verify_backup_dir "$repo_path" "$backup_dir" || return 1
	current_state_matches_backup "$repo_path" "$backup_dir" || return 1
	local original_head=""
	local cleaned_at=""
	original_head=$(manifest_value "$backup_dir/manifest.tsv" head)
	"$REAL_GIT" -C "$repo_path" read-tree --reset -u "$original_head" || return 1
	remove_preserved_untracked "$repo_path" "$backup_dir"/"$UNTRACKED_LIST_NAME" || return 1
	[[ -z "$("$REAL_GIT" -C "$repo_path" status --porcelain=v1)" ]] || return 1
	cleaned_at=$(iso_utc) || return 1
	manifest_set "$backup_dir/manifest.tsv" cleaned_at "$cleaned_at" || return 1
	printf 'CLEANED_BACKUP_ID=%s\n' "$PARSED_BACKUP_ID"
	return 0
}

rollback_restore() {
	local repo_path="$1"
	local branch_ref="$2"
	local original_head="$3"
	local rollback_head="$4"
	local untracked_nul="$5"
	"$REAL_GIT" -C "$repo_path" update-ref "$branch_ref" "$rollback_head" "$original_head" || return 1
	"$REAL_GIT" -C "$repo_path" read-tree --reset -u "$rollback_head" || return 1
	remove_preserved_untracked "$repo_path" "$untracked_nul" || return 1
	return 0
}

cmd_restore() {
	parse_repo_backup_args "$@" || return 1
	[[ "$PARSED_CONFIRMATION" == "RESTORE_DIRTY_WORKTREE_BACKUP" ]] || return 1
	local repo_path=""
	repo_path=$(resolve_repo_path "$PARSED_REPO_PATH") || return 1
	local backup_dir=""
	backup_dir=$(resolve_backup_dir "$PARSED_BACKUP_ID") || return 1
	verify_backup_dir "$repo_path" "$backup_dir" || return 1
	[[ -z "$("$REAL_GIT" -C "$repo_path" status --porcelain=v1)" ]] || return 1
	local branch=""
	branch=$("$REAL_GIT" -C "$repo_path" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
	[[ "$branch" == "$(manifest_value "$backup_dir/manifest.tsv" branch)" ]] || return 1
	local rollback_head=""
	local original_head=""
	local index_tree=""
	local worktree_tree=""
	local restored_at=""
	rollback_head=$("$REAL_GIT" -C "$repo_path" rev-parse --verify 'HEAD^{commit}') || return 1
	original_head=$(manifest_value "$backup_dir/manifest.tsv" head)
	index_tree=$(manifest_value "$backup_dir/manifest.tsv" index_tree)
	worktree_tree=$(manifest_value "$backup_dir/manifest.tsv" worktree_tree)
	local branch_ref="refs/heads/${branch}"
	"$REAL_GIT" -C "$repo_path" update-ref "$branch_ref" "$original_head" "$rollback_head" || return 1
	if ! "$REAL_GIT" -C "$repo_path" read-tree --reset -u "$worktree_tree" ||
		! "$REAL_GIT" -C "$repo_path" read-tree "$index_tree"; then
		rollback_restore "$repo_path" "$branch_ref" "$original_head" "$rollback_head" \
			"$backup_dir"/"$UNTRACKED_LIST_NAME" || return 1
		return 1
	fi
	if ! current_state_matches_backup "$repo_path" "$backup_dir"; then
		rollback_restore "$repo_path" "$branch_ref" "$original_head" "$rollback_head" \
			"$backup_dir"/"$UNTRACKED_LIST_NAME" || return 1
		return 1
	fi
	manifest_set "$backup_dir/manifest.tsv" state restored || return 1
	restored_at=$(iso_utc) || return 1
	manifest_set "$backup_dir/manifest.tsv" restored_at "$restored_at" || return 1
	printf 'RESTORED_BACKUP_ID=%s\n' "$PARSED_BACKUP_ID"
	return 0
}

cmd_acknowledge() {
	parse_repo_backup_args "$@" || return 1
	[[ -z "$PARSED_REPO_PATH" ]] || return 1
	[[ "$PARSED_CONFIRMATION" == "ACKNOWLEDGE_DIRTY_WORKTREE_BACKUP" ]] || return 1
	local backup_dir=""
	local acknowledged_at=""
	backup_dir=$(resolve_backup_dir "$PARSED_BACKUP_ID") || return 1
	manifest_set "$backup_dir/manifest.tsv" state acknowledged || return 1
	acknowledged_at=$(iso_utc) || return 1
	manifest_set "$backup_dir/manifest.tsv" acknowledged_at "$acknowledged_at" || return 1
	printf 'ACKNOWLEDGED_BACKUP_ID=%s\n' "$PARSED_BACKUP_ID"
	return 0
}

cmd_list() {
	local backup_dir=""
	local manifest_path=""
	[[ -d "$BACKUP_ROOT" ]] || {
		print_info "No dirty-worktree backups found."
		return 0
	}
	for backup_dir in "$BACKUP_ROOT"/*; do
		[[ -d "$backup_dir" ]] || continue
		manifest_path="$backup_dir/manifest.tsv"
		[[ -f "$manifest_path" ]] || continue
		printf '%s\tstate=%s\tpr=%s\ttask=%s\treason=%s\n' \
			"$(manifest_value "$manifest_path" backup_id)" \
			"$(manifest_value "$manifest_path" state)" \
			"$(manifest_value "$manifest_path" pr)" \
			"$(manifest_value "$manifest_path" task)" \
			"$(manifest_value "$manifest_path" reason)"
	done
	return 0
}

backup_age_days() {
	local backup_dir="$1"
	local now_epoch=""
	local backup_epoch=""
	now_epoch=$(date +%s)
	if command -v _file_mtime_epoch >/dev/null 2>&1; then
		backup_epoch=$(_file_mtime_epoch "$backup_dir" 2>/dev/null || printf '%s' "$now_epoch")
	else
		backup_epoch="$now_epoch"
	fi
	[[ "$backup_epoch" =~ ^[0-9]+$ ]] || backup_epoch="$now_epoch"
	printf '%s\n' $(((now_epoch - backup_epoch) / 86400))
	return 0
}

pr_is_terminal() {
	local repo_slug="$1"
	local pr_number="$2"
	local pr_state=""
	[[ -n "$repo_slug" && "$pr_number" =~ ^[0-9]+$ ]] || return 1
	command -v gh >/dev/null 2>&1 || return 1
	pr_state=$(gh pr view "$pr_number" --repo "$repo_slug" --json state --jq '.state // ""' 2>/dev/null || true)
	case "$pr_state" in
	CLOSED | MERGED) return 0 ;;
	esac
	return 1
}

remove_backup_dir() {
	local backup_dir="$1"
	local force="$2"
	local reason="$3"
	local manifest_path="$backup_dir/manifest.tsv"
	if [[ "$force" != true ]]; then
		print_info "[dry-run] Would remove backup ($reason): $(basename "$backup_dir")"
		return 0
	fi
	local repo_path=""
	local backup_ref=""
	local worktree_commit=""
	repo_path=$(manifest_value "$manifest_path" repo_path)
	backup_ref=$(manifest_value "$manifest_path" backup_ref)
	worktree_commit=$(manifest_value "$manifest_path" worktree_commit)
	if [[ -n "$backup_ref" && -d "$repo_path" ]]; then
		repo_path=$(resolve_repo_path "$repo_path") || return 1
		verify_backup_dir "$repo_path" "$backup_dir" || return 1
		"$REAL_GIT" -C "$repo_path" update-ref -d "$backup_ref" "$worktree_commit" || return 1
	fi
	rm -rf "$backup_dir"
	print_info "Removed backup ($reason): $(basename "$backup_dir")"
	return 0
}

cmd_prune() {
	local force=false
	local retention_days="$DEFAULT_RETENTION_DAYS"
	while [[ $# -gt 0 ]]; do
		local arg="$1"
		case "$arg" in
		--force)
			force=true
			shift
			;;
		--dry-run)
			force=false
			shift
			;;
		--retention-days)
			retention_days="${2:-}"
			shift 2
			;;
		*) return 1 ;;
		esac
	done
	[[ "$retention_days" =~ ^[0-9]+$ ]] || return 1
	[[ -d "$BACKUP_ROOT" ]] || return 0
	local backup_dir=""
	for backup_dir in "$BACKUP_ROOT"/*; do
		[[ -d "$backup_dir" && -f "$backup_dir/manifest.tsv" ]] || continue
		[[ -f "$backup_dir/.keep" ]] && continue
		local state=""
		state=$(manifest_value "$backup_dir/manifest.tsv" state)
		case "$state" in
		acknowledged | restored) ;;
		*) continue ;;
		esac
		local repo_slug=""
		local pr_number=""
		repo_slug=$(manifest_value "$backup_dir/manifest.tsv" repo_slug)
		pr_number=$(manifest_value "$backup_dir/manifest.tsv" pr)
		if pr_is_terminal "$repo_slug" "$pr_number"; then
			remove_backup_dir "$backup_dir" "$force" "linked PR terminal" || return 1
			continue
		fi
		local age_days=""
		age_days=$(backup_age_days "$backup_dir")
		if [[ "$age_days" -ge "$retention_days" ]]; then
			remove_backup_dir "$backup_dir" "$force" "age ${age_days}d >= ${retention_days}d" || return 1
		fi
	done
	return 0
}

main() {
	local command_name="${1:-help}"
	[[ $# -eq 0 ]] || shift
	case "$command_name" in
	backup)
		cmd_backup "$@"
		return $?
		;;
	verify)
		cmd_verify "$@"
		return $?
		;;
	matches)
		cmd_matches "$@"
		return $?
		;;
	clean)
		cmd_clean "$@"
		return $?
		;;
	restore)
		cmd_restore "$@"
		return $?
		;;
	acknowledge)
		cmd_acknowledge "$@"
		return $?
		;;
	list)
		cmd_list "$@"
		return $?
		;;
	prune)
		cmd_prune "$@"
		return $?
		;;
	help | --help | -h)
		usage
		return 0
		;;
	*)
		print_error "Unknown command: $command_name"
		usage
		return 1
		;;
	esac
}

main "$@"

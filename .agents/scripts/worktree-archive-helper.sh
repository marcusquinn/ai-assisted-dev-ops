#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
# shellcheck source=shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh"

ARCHIVE_ROOT="${AIDEVOPS_WORKTREE_ARCHIVE_ROOT:-${HOME}/.aidevops/recovery/archives}"
MAX_UNTRACKED_FILES="${AIDEVOPS_WORKTREE_ARCHIVE_MAX_UNTRACKED_FILES:-10000}"
MAX_UNTRACKED_BYTES="${AIDEVOPS_WORKTREE_ARCHIVE_MAX_UNTRACKED_BYTES:-1073741824}"
ARCHIVE_SCHEMA="aidevops-worktree-archive-v1"

usage() {
	cat <<'USAGE'
Usage: worktree-archive-helper.sh <command> [options]

Commands:
  archive WORKTREE --repo OWNER/REPO --issue N
      --reason failed-worker|post-pr-cleanup --base-branch BRANCH
      [--base-sha SHA] [--output-root DIR] [--failure-log FILE]
  restore ARCHIVE_DIR --target NEW_WORKTREE_PATH
  list [--repo OWNER/REPO] [--issue N] [--output-root DIR]
  verify ARCHIVE_DIR
  prune --older-than 14d --max-total-size 20G [--dry-run|--apply]
      [--output-root DIR]

Environment:
  AIDEVOPS_WORKTREE_ARCHIVE_ROOT                Override the archive root.
  AIDEVOPS_WORKTREE_ARCHIVE_MAX_UNTRACKED_FILES Maximum untracked paths (10000).
  AIDEVOPS_WORKTREE_ARCHIVE_MAX_UNTRACKED_BYTES Maximum untracked bytes (1 GiB).
USAGE
	return 0
}

die() {
	local message="$1"
	printf 'Error: %s\n' "$message" >&2
	return 1
}

require_value() {
	local option="$1"
	local value="${2:-}"
	if [[ -z "$value" ]]; then
		die "$option requires a value"
		return 1
	fi
	return 0
}

validate_repo() {
	local repo="$1"
	if [[ ! "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
		die "invalid repository slug: $repo"
		return 1
	fi
	return 0
}

validate_issue() {
	local issue="$1"
	if [[ ! "$issue" =~ ^[1-9][0-9]*$ ]]; then
		die "issue must be a positive integer"
		return 1
	fi
	return 0
}

validate_branch() {
	local branch="$1"
	if ! git check-ref-format --branch "$branch" >/dev/null 2>&1; then
		die "invalid base branch: $branch"
		return 1
	fi
	return 0
}

validate_archive_dir() {
	local archive_dir="$1"
	if [[ ! -d "$archive_dir" || ! -f "$archive_dir/manifest.json" ]]; then
		die "archive manifest not found: $archive_dir"
		return 1
	fi
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

resolve_base_sha() {
	local worktree="$1"
	local base_branch="$2"
	local requested_sha="$3"
	local resolved=""
	if [[ -n "$requested_sha" ]]; then
		resolved=$(git -C "$worktree" rev-parse --verify "${requested_sha}^{commit}" 2>/dev/null) || return 1
	else
		resolved=$(git -C "$worktree" rev-parse --verify "refs/remotes/origin/${base_branch}^{commit}" 2>/dev/null || true)
		if [[ -z "$resolved" ]]; then
			resolved=$(git -C "$worktree" rev-parse --verify "refs/heads/${base_branch}^{commit}" 2>/dev/null) || return 1
		fi
	fi
	printf '%s\n' "$resolved"
	return 0
}

capture_untracked() {
	local worktree="$1"
	local archive_dir="$2"
	local inventory="$archive_dir/untracked-files.nul"
	git -C "$worktree" ls-files --others --exclude-standard -z >"$inventory" || return 1
	python3 - "$worktree" "$inventory" "$archive_dir" "$MAX_UNTRACKED_FILES" "$MAX_UNTRACKED_BYTES" <<'PY'
import os
import pathlib
import sys
import tarfile

root = pathlib.Path(sys.argv[1]).resolve()
inventory = pathlib.Path(sys.argv[2])
archive = pathlib.Path(sys.argv[3])
limit_files = int(sys.argv[4])
limit_bytes = int(sys.argv[5])
raw_paths = [p for p in inventory.read_bytes().split(b"\0") if p]
display = []
total = 0
paths = []
for raw in raw_paths:
    rel = pathlib.PurePosixPath(os.fsdecode(raw))
    if rel.is_absolute() or ".." in rel.parts:
        raise SystemExit("unsafe untracked path")
    target = root.joinpath(*rel.parts)
    if not target.is_file() and not target.is_symlink():
        raise SystemExit("unsupported untracked path type")
    total += target.lstat().st_size
    paths.append((raw, rel, target))
    display.append(os.fsdecode(raw).replace("\\", "\\\\").replace("\n", "\\n"))
if len(paths) > limit_files or total > limit_bytes:
    raise SystemExit("untracked payload exceeds configured limit")
(archive / "untracked-files.txt").write_text("".join(path + "\n" for path in display), encoding='utf-8')
inventory.unlink()
if paths:
    with tarfile.open(archive / "untracked.tar.gz", "w:gz") as output:
        for _, rel, target in paths:
            output.add(target, arcname=str(rel), recursive=False)
PY
	return $?
}

write_manifest() {
	local archive_dir="$1"
	local repo="$2"
	local issue="$3"
	local reason="$4"
	local created_at="$5"
	local worktree="$6"
	local branch="$7"
	local head_sha="$8"
	local base_branch="$9"
	local base_sha="${10}"
	local default_branch="${11}"
	local remote_state="${12}"
	local dirty_state="${13}"
	local git_common_dir="${14}"
	python3 - "$archive_dir" "$repo" "$issue" "$reason" "$created_at" "$worktree" "$branch" "$head_sha" "$base_branch" "$base_sha" "$default_branch" "$remote_state" "$dirty_state" "$git_common_dir" "$ARCHIVE_SCHEMA" <<'PY'
import hashlib
import json
import pathlib
import sys

archive = pathlib.Path(sys.argv[1])
names = sorted(path.name for path in archive.iterdir() if path.name != 'manifest.json')
artifacts = []
for name in names:
    path = archive / name
    if not path.is_file():
        continue
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    artifacts.append({'name': name, "size": path.stat().st_size, "sha256": digest})
manifest = {
    'schema': sys.argv[15],
    'repo': sys.argv[2],
    'issue': int(sys.argv[3]),
    "reason": sys.argv[4],
    "created_at": sys.argv[5],
    "source_worktree": sys.argv[6],
    'source_git_common_dir': sys.argv[14],
    "branch": sys.argv[7],
    "head_sha": sys.argv[8],
    "base_branch": sys.argv[9],
    "base_sha": sys.argv[10],
    "default_branch": sys.argv[11],
    "remote_branch_state": sys.argv[12],
    "dirty_state": sys.argv[13],
    "artifacts": artifacts,
    "restore_instructions": f"worktree-archive-helper.sh restore {archive} --target <new-worktree-path>",
}
(archive / 'manifest.json').write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding='utf-8')
PY
	return $?
}

archive_worktree() {
	local worktree="${1:-}"
	shift || true
	local repo="" issue="" reason="" base_branch="" base_sha="" output_root="$ARCHIVE_ROOT" failure_log=""
	local created_at timestamp repo_path archive_dir branch head_sha default_branch remote_state dirty_state git_common_dir commit_count
	[[ -n "$worktree" ]] || { usage >&2; return 1; }
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--repo) require_value "$1" "${2:-}" || return 1; repo="$2"; shift 2 ;;
		--issue) require_value "$1" "${2:-}" || return 1; issue="$2"; shift 2 ;;
		--reason) require_value "$1" "${2:-}" || return 1; reason="$2"; shift 2 ;;
		--base-branch) require_value "$1" "${2:-}" || return 1; base_branch="$2"; shift 2 ;;
		--base-sha) require_value "$1" "${2:-}" || return 1; base_sha="$2"; shift 2 ;;
		--output-root) require_value "$1" "${2:-}" || return 1; output_root="$2"; shift 2 ;;
		--failure-log) require_value "$1" "${2:-}" || return 1; failure_log="$2"; shift 2 ;;
		*) die "unknown archive option: $1"; return 1 ;;
		esac
	done
	validate_repo "$repo" || return 1
	validate_issue "$issue" || return 1
	[[ "$reason" == "failed-worker" || "$reason" == "post-pr-cleanup" ]] || { die "invalid archive reason"; return 1; }
	validate_branch "$base_branch" || return 1
	[[ -d "$worktree" ]] || { die "worktree does not exist: $worktree"; return 1; }
	git -C "$worktree" rev-parse --is-inside-work-tree >/dev/null 2>&1 || { die "not a Git worktree: $worktree"; return 1; }
	worktree=$(cd "$worktree" && pwd -P) || return 1
	base_sha=$(resolve_base_sha "$worktree" "$base_branch" "$base_sha") || { die "cannot resolve base SHA"; return 1; }
	head_sha=$(git -C "$worktree" rev-parse HEAD) || return 1
	branch=$(git -C "$worktree" symbolic-ref --short -q HEAD 2>/dev/null || printf 'detached')
	default_branch=$(git -C "$worktree" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null || true)
	default_branch=${default_branch#origin/}
	[[ -n "$default_branch" ]] || default_branch="$base_branch"
	remote_state="unknown"
	if [[ "$branch" != "detached" ]]; then
		local remote_rc=0
		git -C "$worktree" ls-remote --exit-code --heads origin "$branch" >/dev/null 2>&1 || remote_rc=$?
		if [[ "$remote_rc" -eq 0 ]]; then
			remote_state="present"
		elif [[ "$remote_rc" -eq 2 ]]; then
			remote_state="missing"
		fi
	fi
	dirty_state=$(git -C "$worktree" status --porcelain=v1)
	if [[ -n "$dirty_state" ]]; then dirty_state="dirty"; else dirty_state="clean"; fi
	git_common_dir=$(git -C "$worktree" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || git -C "$worktree" rev-parse --git-common-dir) || return 1
	timestamp=$(timestamp_utc)
	created_at=$(iso_utc)
	repo_path="${repo//\//__}"
	archive_dir="${output_root%/}/${repo_path}/${issue}/${timestamp}"
	if [[ -e "$archive_dir" ]]; then archive_dir="${archive_dir}-$$"; fi
	mkdir -p "$archive_dir" || return 1
	git -C "$worktree" diff --binary >"$archive_dir/diff.patch" || return 1
	git -C "$worktree" diff --cached --binary >"$archive_dir/staged.patch" || return 1
	commit_count=$(git -C "$worktree" rev-list --count "${base_sha}..${head_sha}") || return 1
	if [[ "$commit_count" -gt 0 ]]; then
		git -C "$worktree" bundle create "$archive_dir/commits.bundle" HEAD "^${base_sha}" || return 1
	fi
	capture_untracked "$worktree" "$archive_dir" || return 1
	if [[ -n "$failure_log" ]]; then
		[[ -f "$failure_log" ]] || { die "failure log does not exist"; return 1; }
		python3 - "$failure_log" "$archive_dir/failure.log" <<'PY'
import pathlib
import sys
source = pathlib.Path(sys.argv[1])
target = pathlib.Path(sys.argv[2])
with source.open("rb") as handle:
    handle.seek(max(0, source.stat().st_size - 262144))
    target.write_bytes(handle.read())
PY
	fi
	write_manifest "$archive_dir" "$repo" "$issue" "$reason" "$created_at" "$worktree" "$branch" "$head_sha" "$base_branch" "$base_sha" "$default_branch" "$remote_state" "$dirty_state" "$git_common_dir" || return 1
	printf '%s\n' "$archive_dir"
	return 0
}

verify_archive() {
	local archive_dir="$1"
	validate_archive_dir "$archive_dir" || return 1
	python3 - "$archive_dir" "$ARCHIVE_SCHEMA" <<'PY'
import hashlib
import json
import pathlib
import posixpath
import subprocess
import sys
import tarfile

archive = pathlib.Path(sys.argv[1]).resolve()
manifest = json.loads((archive / 'manifest.json').read_text(encoding='utf-8'))
required = ('repo', 'issue', "reason", 'created_at', "source_worktree", "branch", "head_sha", "base_branch", "base_sha", "default_branch", "remote_branch_state", "dirty_state", 'artifacts', "restore_instructions")
missing = [key for key in required if key not in manifest]
if manifest.get('schema') != sys.argv[2] or missing:
    raise SystemExit("invalid manifest schema or missing fields: " + ", ".join(missing))
for artifact in manifest['artifacts']:
    path = archive / artifact['name']
    if path.parent != archive or not path.is_file():
        raise SystemExit("missing or unsafe artifact: " + artifact['name'])
    if path.stat().st_size != artifact["size"] or hashlib.sha256(path.read_bytes()).hexdigest() != artifact["sha256"]:
        raise SystemExit("artifact integrity mismatch: " + artifact['name'])
bundle = archive / "commits.bundle"
if bundle.exists():
    common_dir = manifest.get('source_git_common_dir', "")
    command = ["git"]
    if common_dir and pathlib.Path(common_dir).is_dir():
        command.append(f"--git-dir={common_dir}")
    command.extend(["bundle", "verify", str(bundle)])
    subprocess.run(command, check=True, stdout=subprocess.DEVNULL)
payload = archive / "untracked.tar.gz"
if payload.exists():
    with tarfile.open(payload, "r:gz") as source:
        for member in source.getmembers():
            path = pathlib.PurePosixPath(member.name)
            link = pathlib.PurePosixPath(member.linkname) if member.issym() else None
            resolved_link = pathlib.PurePosixPath(posixpath.normpath(str(path.parent / link))) if link else None
            if (path.is_absolute() or ".." in path.parts or member.isdev() or
                    member.islnk() or (link and link.is_absolute()) or
                    (resolved_link and ".." in resolved_link.parts)):
                raise SystemExit("unsafe untracked archive member")
print(f"verified {archive}")
PY
	return $?
}

restore_archive() {
	local archive_dir="${1:-}"
	shift || true
	local target="" common_dir head_sha branch restore_branch
	validate_archive_dir "$archive_dir" || return 1
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--target) require_value "$1" "${2:-}" || return 1; target="$2"; shift 2 ;;
		*) die "unknown restore option: $1"; return 1 ;;
		esac
	done
	[[ -n "$target" && ! -e "$target" ]] || { die "restore target must not exist"; return 1; }
	verify_archive "$archive_dir" >/dev/null || return 1
	IFS=$'\t' read -r common_dir head_sha branch < <(python3 - "$archive_dir/manifest.json" <<'PY'
import json, sys
m = json.load(open(sys.argv[1], encoding='utf-8'))
print(m.get('source_git_common_dir', ""), m["head_sha"], m["branch"], sep=chr(9))
PY
	)
	[[ -d "$common_dir" ]] || { die "source Git repository is unavailable: $common_dir"; return 1; }
	if [[ -f "$archive_dir/commits.bundle" ]]; then
		git --git-dir="$common_dir" fetch "$archive_dir/commits.bundle" HEAD >/dev/null || return 1
	fi
	restore_branch="archive-restore-$(date -u '+%Y%m%d%H%M%S')-$$"
	git --git-dir="$common_dir" worktree add -b "$restore_branch" "$target" "$head_sha" >/dev/null || return 1
	if [[ -s "$archive_dir/staged.patch" ]]; then git -C "$target" apply --index "$archive_dir/staged.patch" || return 1; fi
	if [[ -s "$archive_dir/diff.patch" ]]; then git -C "$target" apply "$archive_dir/diff.patch" || return 1; fi
	if [[ -f "$archive_dir/untracked.tar.gz" ]]; then
		python3 - "$archive_dir/untracked.tar.gz" "$target" <<'PY'
import pathlib
import os
import posixpath
import shutil
import sys
import tarfile
source = pathlib.Path(sys.argv[1])
target = pathlib.Path(sys.argv[2]).resolve()
with tarfile.open(source, "r:gz") as payload:
    for member in payload.getmembers():
        path = pathlib.PurePosixPath(member.name)
        link = pathlib.PurePosixPath(member.linkname) if member.issym() else None
        resolved_link = pathlib.PurePosixPath(posixpath.normpath(str(path.parent / link))) if link else None
        if (path.is_absolute() or ".." in path.parts or member.isdev() or
                member.islnk() or (link and link.is_absolute()) or
                (resolved_link and ".." in resolved_link.parts)):
            raise SystemExit("unsafe untracked archive member")
        destination = target.joinpath(*path.parts)
        destination.parent.mkdir(parents=True, exist_ok=True)
        if os.path.commonpath((str(target), str(destination.parent.resolve()))) != str(target):
            raise SystemExit("untracked archive escaped restore target")
        if member.isdir():
            destination.mkdir(exist_ok=True)
        elif member.issym():
            destination.symlink_to(member.linkname)
        elif member.isfile():
            source_file = payload.extractfile(member)
            if source_file is None:
                raise SystemExit("missing untracked file payload")
            with destination.open("wb") as output:
                shutil.copyfileobj(source_file, output)
            destination.chmod(member.mode & 0o777)
        else:
            raise SystemExit("unsupported untracked archive member")
PY
	fi
	printf '%s\n' "$target"
	return 0
}

list_archives() {
	local repo="" issue="" output_root="$ARCHIVE_ROOT"
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--repo) require_value "$1" "${2:-}" || return 1; repo="$2"; shift 2 ;;
		--issue) require_value "$1" "${2:-}" || return 1; issue="$2"; shift 2 ;;
		--output-root) require_value "$1" "${2:-}" || return 1; output_root="$2"; shift 2 ;;
		*) die "unknown list option: $1"; return 1 ;;
		esac
	done
	[[ -z "$repo" ]] || validate_repo "$repo" || return 1
	[[ -z "$issue" ]] || validate_issue "$issue" || return 1
	python3 - "$output_root" "$repo" "$issue" <<'PY'
import json
import pathlib
import sys
root = pathlib.Path(sys.argv[1])
repo_filter, issue_filter = sys.argv[2:]
if root.is_dir():
    for manifest_path in sorted(root.glob("*/*/*/manifest.json")):
        try:
            manifest = json.loads(manifest_path.read_text(encoding='utf-8'))
        except (OSError, ValueError):
            continue
        if repo_filter and manifest.get('repo') != repo_filter:
            continue
        if issue_filter and str(manifest.get('issue')) != issue_filter:
            continue
        print(f"{manifest.get('created_at', '-')}\t{manifest.get('repo', '-')}#{manifest.get('issue', '-')}\t{manifest.get('reason', '-')}\t{manifest_path.parent}")
PY
	return $?
}

prune_archives() {
	local older_than="" max_total="" mode="" output_root="$ARCHIVE_ROOT"
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--older-than) require_value "$1" "${2:-}" || return 1; older_than="$2"; shift 2 ;;
		--max-total-size) require_value "$1" "${2:-}" || return 1; max_total="$2"; shift 2 ;;
		--dry-run) [[ -z "$mode" ]] || { die "choose only one prune mode"; return 1; }; mode="dry-run"; shift ;;
		--apply) [[ -z "$mode" ]] || { die "choose only one prune mode"; return 1; }; mode="apply"; shift ;;
		--output-root) require_value "$1" "${2:-}" || return 1; output_root="$2"; shift 2 ;;
		*) die "unknown prune option: $1"; return 1 ;;
		esac
	done
	[[ "$older_than" =~ ^[1-9][0-9]*d$ ]] || { die "--older-than must use positive day syntax such as 14d"; return 1; }
	[[ "$max_total" =~ ^[1-9][0-9]*([KMGTP])?$ ]] || { die "invalid --max-total-size"; return 1; }
	[[ -n "$mode" ]] || { die "prune requires --dry-run or --apply"; return 1; }
	python3 - "$output_root" "${older_than%d}" "$max_total" "$mode" "$ARCHIVE_SCHEMA" <<'PY'
import datetime
import json
import pathlib
import shutil
import sys

root = pathlib.Path(sys.argv[1]).resolve()
days = int(sys.argv[2])
raw_limit = sys.argv[3]
mode = sys.argv[4]
units = {"K": 1024, "M": 1024**2, "G": 1024**3, "T": 1024**4, "P": 1024**5}
limit = int(raw_limit[:-1]) * units[raw_limit[-1]] if raw_limit[-1] in units else int(raw_limit)
now = datetime.datetime.now(datetime.timezone.utc)
entries = []
if root.is_dir():
    for manifest_path in root.glob("*/*/*/manifest.json"):
        directory = manifest_path.parent
        try:
            manifest = json.loads(manifest_path.read_text(encoding='utf-8'))
            if manifest.get('schema') != sys.argv[5]:
                continue
            created = datetime.datetime.fromisoformat(manifest['created_at'].replace("Z", "+00:00"))
        except (OSError, ValueError, KeyError):
            continue
        size = sum(path.stat().st_size for path in directory.rglob("*") if path.is_file())
        entries.append([created, size, directory, (now - created).days >= days])
total = sum(entry[1] for entry in entries)
selected = {entry[2] for entry in entries if entry[3]}
remaining = sorted((entry for entry in entries if entry[2] not in selected), key=lambda item: item[0])
remaining_total = total - sum(entry[1] for entry in entries if entry[2] in selected)
for entry in remaining:
    if remaining_total <= limit:
        break
    selected.add(entry[2])
    remaining_total -= entry[1]
for directory in sorted(selected):
    print(f"{mode}\t{directory}")
    if mode == "apply":
        shutil.rmtree(directory)
PY
	return $?
}

main() {
	local command="${1:-help}"
	shift || true
	case "$command" in
	archive) archive_worktree "$@" ;;
	restore) restore_archive "$@" ;;
	list) list_archives "$@" ;;
	verify) [[ $# -eq 1 ]] || { usage >&2; return 1; }; verify_archive "$1" ;;
	prune) prune_archives "$@" ;;
	help|-h|--help) usage ;;
	*) usage >&2; return 1 ;;
	esac
	return $?
}

main "$@"

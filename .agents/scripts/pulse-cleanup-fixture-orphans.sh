#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Sourced by pulse-cleanup.sh; legacy test fixtures go to recoverable trash only.

# Require the exact pre-edit fixture shape and a missing temporary canonical repo.
# Never infer disposability from a tmp.* name or an unreadable Git pointer alone.
_pc_central_fixture_bytes() {
	local candidate="$1"
	local base="$2"
	local now_epoch="$3"
	local grace_secs="${ORPHAN_WORKTREE_GRACE_SECS:-1800}"
	python3 - "$candidate" "$base" "$now_epoch" "$grace_secs" <<'PY'
import os
from pathlib import Path
import re
import stat
import sys

candidate, base = map(Path, sys.argv[1:3])
now, grace = map(int, sys.argv[3:5])

def require(condition):
    if not condition:
        raise ValueError('fixture safety check failed')

try:
    require(grace >= 1800)
    require(candidate.parent == base and not candidate.is_symlink())
    require(base.resolve() == base and candidate.is_dir())
    match = re.fullmatch(r'(tmp\.[A-Za-z0-9]+)-feature-auto-[0-9]{8}-[0-9]{6}', candidate.name)
    require(match and now - candidate.stat().st_mtime >= grace)
    entries = list(candidate.iterdir())
    require({p.name for p in entries} <= {'.git', '.metadata_never_index', 'README.md', 'TODO.md'})
    for entry in entries:
        info = entry.lstat()
        require(stat.S_ISREG(info.st_mode) and info.st_size <= 4096)
        require(now - info.st_mtime >= grace)
    require((candidate / 'README.md').read_bytes() == b'test\n')
    pointer = (candidate / '.git').read_text().strip()
    suffix = '/.git/worktrees/' + candidate.name
    require(pointer.startswith('gitdir: /') and pointer.endswith(suffix))
    root = Path(pointer[len('gitdir: '):-len(suffix)])
    require(root.name == match[1] and '..' not in root.parts)
    require(re.fullmatch(r'/(?:private/)?(?:tmp|var/folders/[^/]+/[^/]+/T)/tmp\.[A-Za-z0-9]+', str(root)))
    require(root.parent.is_dir() and os.access(root.parent, os.R_OK | os.X_OK))
    try:
        root.lstat()
    except FileNotFoundError:
        pass
    else:
        raise ValueError('fixture canonical root still exists')
    print(sum(p.lstat().st_blocks * 512 for p in entries))
except (OSError, ValueError, UnicodeError):
    sys.exit(1)
PY
	return $?
}

_pc_fixture_process_clear() {
	local candidate="$1"
	local process_output="" process_rc=0
	process_output=$(lsof -t +D "$candidate" 2>&1) || process_rc=$?
	[[ "$process_rc" -eq 1 && -z "$process_output" ]] || return 1
	return 0
}

# API-free and independent of repos.json: deleted fixture repos are unregistered.
# Optional audit mode reports candidates without moving anything.
_pc_cleanup_central_fixture_orphans() {
	local now_epoch="$1"
	local mode="${2:-apply}"
	local base="" candidate="" bytes=0 moved=0 eligible=0 skipped=0 total_bytes=0
	[[ "$mode" == "apply" || "$mode" == "audit" ]] || return 1
	command -v python3 >/dev/null 2>&1 && command -v lsof >/dev/null 2>&1 || { printf '0\n'; return 0; }
	declare -F is_worktree_owned_by_others >/dev/null 2>&1 || { printf '0\n'; return 0; }
	declare -F is_registered_canonical >/dev/null 2>&1 || { printf '0\n'; return 0; }
	base=$(aidevops_worktree_base_dir_configured) || { printf '0\n'; return 0; }
	for candidate in "$base"/tmp.*-feature-auto-*; do
		[[ -d "$candidate" ]] || continue
		if ! bytes=$(_pc_central_fixture_bytes "$candidate" "$base" "$now_epoch"); then
			skipped=$((skipped + 1))
			continue
		fi
		if _worktree_owner_alive "$candidate" "" || is_registered_canonical "$candidate"; then
			skipped=$((skipped + 1))
			continue
		fi
		# Include cwd and open files; diagnostics or an unavailable process scan veto.
		if ! _pc_fixture_process_clear "$candidate"; then
			skipped=$((skipped + 1))
			continue
		fi
		eligible=$((eligible + 1))
		total_bytes=$((total_bytes + bytes))
		if [[ "$mode" == "audit" ]]; then
			printf '[pulse-cleanup] fixture-candidate path=%s bytes=%s\n' "$candidate" "$bytes" >>"$LOGFILE"
			continue
		fi
		# Revalidate the filesystem after the ownership/process checks.
		if _pc_central_fixture_bytes "$candidate" "$base" "$now_epoch" >/dev/null &&
			! _worktree_owner_alive "$candidate" "" && _pc_fixture_process_clear "$candidate" &&
			_pc_trash_orphan_dir "$candidate"; then
			log_worktree_removal_event "$_WTAR_REMOVED" "$_WTAR_PC_CALLER" "$candidate" "abandoned-central-test-fixture" "trash"
			moved=$((moved + 1))
		else
			log_worktree_removal_event "$_WTAR_SKIPPED" "$_WTAR_PC_CALLER" "$candidate" "fixture-recheck-or-trash-failed" "skipped"
		fi
	done
	printf '[pulse-cleanup] central-fixtures mode=%s eligible=%s candidate_bytes=%s moved=%s skipped=%s\n' "$mode" "$eligible" "$total_bytes" "$moved" "$skipped" >>"$LOGFILE"
	printf '%s\n' "$moved"
	return 0
}

#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="${SCRIPT_DIR}/../worktree-archive-helper.sh"
TEST_ROOT="$(mktemp -d)"
TESTS_RUN=0
TESTS_FAILED=0

cleanup() {
	rm -rf "$TEST_ROOT"
	return 0
}
trap cleanup EXIT

result() {
	local name="$1"
	local rc="$2"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$rc" -eq 0 ]]; then
		printf 'PASS %s\n' "$name"
	else
		printf 'FAIL %s\n' "$name"
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	return 0
}

setup_repo() {
	local name="$1"
	local bare="$TEST_ROOT/${name}.git"
	local canonical="$TEST_ROOT/${name}-canonical"
	local worktree="$TEST_ROOT/${name}-worktree"
	git init -q --bare "$bare" || return 1
	git clone -q "$bare" "$canonical" || return 1
	git -C "$canonical" config user.email test@example.invalid || return 1
	git -C "$canonical" config user.name Test || return 1
	git -C "$canonical" config commit.gpgsign false || return 1
	git -C "$canonical" checkout -q -b main || return 1
	printf 'base\n' >"$canonical/file.txt"
	git -C "$canonical" add file.txt || return 1
	git -C "$canonical" commit -q -m base || return 1
	git -C "$canonical" push -q -u origin main || return 1
	git -C "$bare" symbolic-ref HEAD refs/heads/main || return 1
	git -C "$canonical" remote set-head origin main || return 1
	git -C "$canonical" worktree add -q -b feature/archive "$worktree" main || return 1
	git -C "$worktree" config user.email test@example.invalid || return 1
	git -C "$worktree" config user.name Test || return 1
	printf '%s\t%s\n' "$canonical" "$worktree"
	return 0
}

test_clean_archive() {
	local paths canonical worktree archive_root archive rc=0
	paths=$(setup_repo clean) || return 1
	IFS=$'\t' read -r canonical worktree <<<"$paths"
	archive_root="$TEST_ROOT/clean-archives"
	archive=$(bash "$HELPER" archive "$worktree" --repo owner/repo --issue 10 \
		--reason post-pr-cleanup --base-branch main --output-root "$archive_root") || return 1
	[[ -f "$archive/manifest.json" && ! -f "$archive/commits.bundle" ]] || rc=1
	python3 - "$archive/manifest.json" <<'PY' || rc=1
import json, sys
m = json.load(open(sys.argv[1], encoding="utf-8"))
assert m["dirty_state"] == "clean"
assert m["base_branch"] == "main"
assert m["base_sha"] == m["head_sha"]
assert m["default_branch"] == "main"
PY
	bash "$HELPER" verify "$archive" >/dev/null || rc=1
	[[ "$(bash "$HELPER" list --repo owner/repo --issue 10 --output-root "$archive_root" | wc -l | tr -d ' ')" == "1" ]] || rc=1
	result "clean archive records exact base metadata and verifies" "$rc"
	return 0
}

test_restore_commits_dirty_and_untracked() {
	local paths canonical worktree archive_root archive target rc=0
	paths=$(setup_repo restore) || return 1
	IFS=$'\t' read -r canonical worktree <<<"$paths"
	archive_root="$TEST_ROOT/restore-archives"
	printf 'commit\n' >>"$worktree/file.txt"
	git -C "$worktree" commit -qam local || return 1
	printf 'staged\n' >"$worktree/staged.txt"
	git -C "$worktree" add staged.txt || return 1
	printf 'dirty\n' >>"$worktree/file.txt"
	mkdir -p "$worktree/local"
	printf 'untracked\n' >"$worktree/local/note.txt"
	ln -s ../file.txt "$worktree/local/file-link"
	archive=$(bash "$HELPER" archive "$worktree" --repo owner/repo --issue 11 \
		--reason failed-worker --base-branch main --output-root "$archive_root") || return 1
	[[ -s "$archive/commits.bundle" && -s "$archive/diff.patch" && -s "$archive/staged.patch" ]] || rc=1
	[[ -s "$archive/untracked.tar.gz" && -s "$archive/untracked-files.txt" ]] || rc=1
	target="$TEST_ROOT/restored-worktree"
	bash "$HELPER" restore "$archive" --target "$target" >/dev/null || rc=1
	grep -q '^commit$' "$target/file.txt" || rc=1
	grep -q '^dirty$' "$target/file.txt" || rc=1
	[[ "$(git -C "$target" show :staged.txt)" == "staged" ]] || rc=1
	[[ "$(cat "$target/local/note.txt")" == "untracked" ]] || rc=1
	[[ -L "$target/local/file-link" && "$(readlink "$target/local/file-link")" == "../file.txt" ]] || rc=1
	[[ "$(git -C "$target" log -1 --format=%s)" == "local" ]] || rc=1
	result "restore recovers bundle commits, staged and unstaged patches, and untracked files" "$rc"
	return 0
}

test_verify_detects_tamper() {
	local paths canonical worktree archive rc=0
	paths=$(setup_repo verify) || return 1
	IFS=$'\t' read -r canonical worktree <<<"$paths"
	printf 'dirty\n' >>"$worktree/file.txt"
	archive=$(bash "$HELPER" archive "$worktree" --repo owner/repo --issue 12 \
		--reason failed-worker --base-branch main --output-root "$TEST_ROOT/verify-archives") || return 1
	printf 'tamper\n' >>"$archive/diff.patch"
	if bash "$HELPER" verify "$archive" >/dev/null 2>&1; then rc=1; fi
	result "verify rejects artifact tampering" "$rc"
	return 0
}

test_prune_modes() {
	local paths canonical worktree root archive old_archive rc=0
	paths=$(setup_repo prune) || return 1
	IFS=$'\t' read -r canonical worktree <<<"$paths"
	root="$TEST_ROOT/prune-archives"
	archive=$(bash "$HELPER" archive "$worktree" --repo owner/repo --issue 13 \
		--reason post-pr-cleanup --base-branch main --output-root "$root") || return 1
	old_archive="$archive"
	python3 - "$old_archive/manifest.json" <<'PY'
import json, pathlib, sys
p = pathlib.Path(sys.argv[1])
m = json.loads(p.read_text(encoding="utf-8"))
m["created_at"] = "2000-01-01T00:00:00Z"
p.write_text(json.dumps(m, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
	bash "$HELPER" prune --older-than 14d --max-total-size 20G --dry-run --output-root "$root" | grep -q "$old_archive" || rc=1
	[[ -d "$old_archive" ]] || rc=1
	bash "$HELPER" prune --older-than 14d --max-total-size 20G --apply --output-root "$root" >/dev/null || rc=1
	[[ ! -e "$old_archive" ]] || rc=1
	result "prune dry-run reports and apply removes expired archives" "$rc"
	return 0
}

test_invalid_arguments() {
	local paths canonical worktree rc=0
	paths=$(setup_repo invalid) || return 1
	IFS=$'\t' read -r canonical worktree <<<"$paths"
	if bash "$HELPER" archive "$worktree" --repo bad --issue 1 --reason failed-worker --base-branch main >/dev/null 2>&1; then rc=1; fi
	if bash "$HELPER" archive "$worktree" --repo owner/repo --issue 0 --reason failed-worker --base-branch main >/dev/null 2>&1; then rc=1; fi
	if bash "$HELPER" prune --older-than fourteen --max-total-size 20G --dry-run >/dev/null 2>&1; then rc=1; fi
	if bash "$HELPER" prune --older-than 14d --max-total-size 20G >/dev/null 2>&1; then rc=1; fi
	if bash "$HELPER" restore "$TEST_ROOT/missing" --target "$TEST_ROOT/target" >/dev/null 2>&1; then rc=1; fi
	result "invalid arguments fail safely" "$rc"
	return 0
}

test_clean_archive
test_restore_commits_dirty_and_untracked
test_verify_detects_tamper
test_prune_modes
test_invalid_arguments

printf '%s tests, %s failures\n' "$TESTS_RUN" "$TESTS_FAILED"
[[ "$TESTS_FAILED" -eq 0 ]]

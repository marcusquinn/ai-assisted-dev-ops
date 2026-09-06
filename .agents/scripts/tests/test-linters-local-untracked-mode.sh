#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-linters-local-untracked-mode.sh — changed inventory coverage and deduplication.

set -euo pipefail

TEST_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
DISCOVERY_HELPER="${TEST_SCRIPT_DIR}/../lint-file-discovery.sh"
TEST_ROOT=""
TESTS_RUN=0
TESTS_FAILED=0

# shellcheck source=../lint-file-discovery.sh
source "$DISCOVERY_HELPER"

# shellcheck source=../linters-local-validators.sh
source "${TEST_SCRIPT_DIR}/../linters-local-validators.sh"
print_warning() {
	printf '%s\n' "$*"
	return 0
}
print_success() {
	printf '%s\n' "$*"
	return 0
}
print_error() {
	printf '%s\n' "$*"
	return 0
}
_linters_local_base_ref() {
	git rev-parse HEAD
	return $?
}

print_result() {
	local test_name="$1"
	local passed="$2"
	local detail="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$passed" -eq 0 ]]; then
		printf 'PASS %s\n' "$test_name"
		return 0
	fi
	printf 'FAIL %s\n' "$test_name"
	[[ -n "$detail" ]] && printf '       %s\n' "$detail"
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

setup_fixture() {
	TEST_ROOT=$(mktemp -d)
	git -C "$TEST_ROOT" init -q
	git -C "$TEST_ROOT" config user.email "test@example.invalid"
	git -C "$TEST_ROOT" config user.name "Test"
	printf 'ignored/\n' >"${TEST_ROOT}/.gitignore"
	printf '#!/usr/bin/env bash\ntrue\n' >"${TEST_ROOT}/tracked.sh"
	git -C "$TEST_ROOT" add .gitignore tracked.sh
	git -C "$TEST_ROOT" commit -qm "fixture"
	git -C "$TEST_ROOT" update-ref refs/remotes/origin/main HEAD
	printf '# changed\n' >>"${TEST_ROOT}/tracked.sh"
	printf '#!/usr/bin/env bash\ntrue\n' >"${TEST_ROOT}/staged.sh"
	git -C "$TEST_ROOT" add staged.sh
	printf '#!/usr/bin/env bash\ntrue\n' >"${TEST_ROOT}/untracked.sh"
	mkdir -p "${TEST_ROOT}/ignored" "${TEST_ROOT}/.agents/scripts/_archive"
	printf '#!/usr/bin/env bash\ntrue\n' >"${TEST_ROOT}/ignored/generated.sh"
	printf '#!/usr/bin/env bash\ntrue\n' >"${TEST_ROOT}/.agents/scripts/_archive/archived.sh"
	return 0
}

teardown_fixture() {
	[[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]] && rm -rf "$TEST_ROOT"
	return 0
}

test_changed_inventory_coverage() {
	local original_dir="$PWD"
	cd "$TEST_ROOT" || return 1
	LINT_CHANGED_FILES_READY=false
	lint_changed_files "$(git rev-parse HEAD)"
	local inventory="$LINT_CHANGED_FILES"
	cd "$original_dir" || return 1
	local missing=0
	local expected=""
	for expected in tracked.sh staged.sh untracked.sh; do
		if ! printf '%s\n' "$inventory" | grep -qxF "$expected"; then
			missing=$((missing + 1))
		fi
	done
	if [[ "$missing" -eq 0 ]] &&
		! printf '%s\n' "$inventory" | grep -qE 'ignored/|_archive/' &&
		[[ "$(printf '%s\n' "$inventory" | sort | uniq -d | wc -l | tr -d '[:space:]')" -eq 0 ]]; then
		print_result "changed inventory covers tracked, staged, and untracked files once" 0
		return 0
	fi
	print_result "changed inventory covers tracked, staged, and untracked files once" 1 "$inventory"
	return 0
}

test_untracked_content_changes_fingerprint() {
	local original_dir="$PWD"
	cd "$TEST_ROOT" || return 1
	LINT_CHANGED_FILES_READY=false
	lint_changed_files "$(git rev-parse HEAD)"
	local before="$LINT_CHANGED_FILES_FINGERPRINT"
	printf '# fingerprint change\n' >>untracked.sh
	LINT_CHANGED_FILES_READY=false
	lint_changed_files "$(git rev-parse HEAD)"
	local after="$LINT_CHANGED_FILES_FINGERPRINT"
	cd "$original_dir" || return 1
	if [[ -n "$before" && "$before" != "$after" ]]; then
		print_result "changed inventory fingerprint includes untracked content" 0
		return 0
	fi
	print_result "changed inventory fingerprint includes untracked content" 1 "before=${before} after=${after}"
	return 0
}

test_full_shell_inventory_has_no_setup_module_duplicates() {
	mkdir -p "${TEST_ROOT}/.agents/scripts/setup/modules"
	printf '#!/usr/bin/env bash\ntrue\n' >"${TEST_ROOT}/.agents/scripts/setup/modules/module.sh"
	printf '#!/usr/bin/env bash\ntrue\n' >"${TEST_ROOT}/.agents/scripts/root.sh"
	printf '#!/usr/bin/env bash\ntrue\n' >"${TEST_ROOT}/setup.sh"
	local original_dir="$PWD"
	cd "$TEST_ROOT" || return 1
	lint_shell_files_local
	cd "$original_dir" || return 1
	local count=0
	local file=""
	for file in "${LINT_SH_FILES_LOCAL[@]}"; do
		[[ "$file" == ".agents/scripts/setup/modules/module.sh" ]] && count=$((count + 1))
	done
	if [[ "$count" -eq 1 ]]; then
		print_result "full shell inventory traverses setup modules once" 0
		return 0
	fi
	print_result "full shell inventory traverses setup modules once" 1 "count=${count}"
	return 0
}

test_untracked_whitespace() {
	local original_dir="$PWD" output="" rc=0
	local unusual_name=$'space and\nnewline.md'
	cd "$TEST_ROOT" || return 1
	printf 'bad   \n' >"$unusual_name"
	output=$(BLUE='' NC='' check_git_diff_whitespace 2>&1) || rc=$?
	if [[ "$rc" -ne 0 && "$output" == *"trailing whitespace"* ]]; then
		print_result "production whitespace gate rejects untracked text with unusual filename" 0
	else
		print_result "production whitespace gate rejects untracked text with unusual filename" 1 "$output"
	fi
	printf 'clean\n' >"$unusual_name"
	printf 'ignored   \n' >ignored/whitespace.md
	printf '\000binary   \n' >binary.dat
	ln -s ignored/whitespace.md linked.md
	output=$(BLUE='' NC='' check_git_diff_whitespace 2>&1) && rc=0 || rc=$?
	print_result "clean text, binary, ignored files and symlinks pass" "$rc" "$output"
	# Git config remains authoritative (intentional Markdown-style trailing spaces).
	printf 'allowed   \n' >"$unusual_name"
	git config core.whitespace -blank-at-eol
	output=$(BLUE='' NC='' check_git_diff_whitespace 2>&1) && rc=0 || rc=$?
	print_result "untracked check honors repository whitespace configuration" "$rc" "$output"
	git config --unset core.whitespace
	printf 'clean\n' >"$unusual_name"
	# Sparse fixture avoids generating large content merely to exercise the bound.
	python3 -c 'with open("large.md", "wb") as f: f.truncate(1048577)'
	output=$(BLUE='' NC='' check_git_diff_whitespace 2>&1) && rc=0 || rc=$?
	if [[ "$rc" -eq 0 && "$output" == *"skipped large.md"* ]]; then
		print_result "oversized untracked file is explicitly reported as skipped" 0
	else
		print_result "oversized untracked file is explicitly reported as skipped" 1 "$output"
	fi
	cd "$original_dir" || return 1
	return 0
}

main() {
	setup_fixture
	trap teardown_fixture EXIT
	test_changed_inventory_coverage
	test_untracked_content_changes_fingerprint
	test_full_shell_inventory_has_no_setup_module_duplicates
	test_untracked_whitespace
	printf '\nRan %s tests, %s failed.\n' "$TESTS_RUN" "$TESTS_FAILED"
	[[ "$TESTS_FAILED" -eq 0 ]]
}

main "$@"

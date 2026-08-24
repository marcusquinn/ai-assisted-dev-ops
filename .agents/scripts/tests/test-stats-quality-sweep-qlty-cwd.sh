#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression test for GH#24842: `_sweep_qlty` must execute Qlty from the
# target repository path, not from the stats wrapper's current directory.
#
# Run:
#   bash .agents/scripts/tests/test-stats-quality-sweep-qlty-cwd.sh
#
# shellcheck disable=SC1090,SC1091

set -euo pipefail

TEST_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
SCRIPTS_DIR="$(cd "${TEST_SCRIPT_DIR}/.." && pwd)" || exit 1

TMP_HOME=$(mktemp -d)
TMP_REPO=$(mktemp -d)
TMP_REL_PARENT=$(mktemp -d)
TMP_CDPATH_PARENT=$(mktemp -d)
FAKE_BIN=$(mktemp -d)
QLTY_PWD_FILE="${TMP_HOME}/qlty-pwd.txt"
QLTY_CREATE_CALLS="${TMP_HOME}/qlty-create-calls.txt"
QLTY_MODE="stable"
LOCAL_HEAD="1111111111111111111111111111111111111111"
REMOTE_HEAD="$LOCAL_HEAD"
WORKTREE_STATE=""
export HOME="$TMP_HOME"
export LOGFILE="${TMP_HOME}/test.log"
export QUALITY_SWEEP_STATE_DIR="${TMP_HOME}/state"
export QLTY_PWD_FILE QLTY_CREATE_CALLS QLTY_MODE LOCAL_HEAD REMOTE_HEAD WORKTREE_STATE
PATH="${FAKE_BIN}:${PATH}"
export PATH

cleanup() {
	rm -rf "$TMP_HOME" "$TMP_REPO" "$TMP_REL_PARENT" "$TMP_CDPATH_PARENT" "$FAKE_BIN"
	return 0
}
trap cleanup EXIT

mkdir -p "${HOME}/.qlty/bin" "${TMP_REPO}/.qlty" "$QUALITY_SWEEP_STATE_DIR"
printf '%s\n' '[plugins]' >"${TMP_REPO}/.qlty/qlty.toml"

cat >"${HOME}/.qlty/bin/qlty" <<'QLTY'
#!/usr/bin/env bash
set -euo pipefail
pwd >"${QLTY_PWD_FILE:?}"
if [[ "${1:-}" == "--version" ]]; then
	printf '%s\n' "qlty test-stub"
	exit 0
fi
if [[ "${QLTY_MODE:-stable}" == "unstable" ]]; then
	run_count=0
	if [[ -f "${XDG_CACHE_HOME:?}/run-count" ]]; then
		run_count=$(<"${XDG_CACHE_HOME}/run-count")
	fi
	run_count=$((run_count + 1))
	printf '%s\n' "$run_count" >"${XDG_CACHE_HOME}/run-count"
	printf '{"runs":[{"results":[{"ruleId":"function-complexity","locations":[{"physicalLocation":{"artifactLocation":{"uri":"scripts/attempt-%s.sh"}}}]}]}]}\n' "$run_count"
	exit 0
fi
printf '%s\n' '{"runs":[{"results":[{"ruleId":"function-complexity","locations":[{"physicalLocation":{"artifactLocation":{"uri":"scripts/example.sh"}}}]}]}]}'
QLTY
chmod +x "${HOME}/.qlty/bin/qlty"

cat >"${FAKE_BIN}/curl" <<'CURL'
#!/usr/bin/env bash
exit 22
CURL
chmod +x "${FAKE_BIN}/curl"

cat >"${FAKE_BIN}/git" <<'GIT'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$*" == *"rev-parse --verify HEAD"* ]]; then
	printf '%s\n' "${LOCAL_HEAD:?}"
	exit 0
fi
if [[ "$*" == *"status --porcelain --untracked-files=normal"* ]]; then
	printf '%s' "${WORKTREE_STATE:-}"
	exit 0
fi
exit 1
GIT
chmod +x "${FAKE_BIN}/git"

# Source dependencies. stats-functions.sh expects shared-constants and
# worker-lifecycle-common to be sourced first.
source "${SCRIPTS_DIR}/shared-constants.sh"
source "${SCRIPTS_DIR}/worker-lifecycle-common.sh"
source "${SCRIPTS_DIR}/stats-functions.sh"

gh() {
	printf '%s\n' "$REMOTE_HEAD"
	return 0
}

_create_simplification_issues() {
	printf '%s\n' "called" >>"$QLTY_CREATE_CALLS"
	printf '%s' "1"
	return 0
}

result=$(_sweep_qlty "owner/repo" "$TMP_REPO")
qlty_section="${result%%|*}"
qlty_remainder="${result#*|}"
qlty_smell_count="${qlty_remainder%%|*}"

if [[ ! -f "$QLTY_PWD_FILE" ]]; then
	printf '%s\n' "FAIL qlty was not executed"
	exit 1
fi

actual_pwd=$(<"$QLTY_PWD_FILE")
if [[ "$actual_pwd" != "$TMP_REPO" ]]; then
	printf '%s\n' "FAIL qlty ran from wrong cwd: expected ${TMP_REPO}, got ${actual_pwd}"
	exit 1
fi

if [[ "$qlty_smell_count" != "1" ]]; then
	printf '%s\n' "FAIL qlty smell count: expected 1, got ${qlty_smell_count}"
	exit 1
fi

if [[ "$qlty_section" != *"scripts/example.sh"* ]]; then
	printf '%s\n' "FAIL qlty section omitted SARIF file path"
	exit 1
fi

if [[ "$(<"$QLTY_CREATE_CALLS")" != "called" ]]; then
	printf '%s\n' "FAIL current default scan did not create remediation issues"
	exit 1
fi

REMOTE_HEAD="2222222222222222222222222222222222222222"
export REMOTE_HEAD
_sweep_qlty "owner/repo" "$TMP_REPO" >/dev/null
if [[ "$(<"$QLTY_CREATE_CALLS")" != "called" ]]; then
	printf '%s\n' "FAIL stale default scan created remediation issues"
	exit 1
fi
if ! grep -q 'skipping stale scan' "$LOGFILE"; then
	printf '%s\n' "FAIL stale default scan did not record its skip reason"
	exit 1
fi

REMOTE_HEAD="$LOCAL_HEAD"
WORKTREE_STATE=" M scripts/example.sh"
export REMOTE_HEAD WORKTREE_STATE
_sweep_qlty "owner/repo" "$TMP_REPO" >/dev/null
if [[ "$(<"$QLTY_CREATE_CALLS")" != "called" ]]; then
	printf '%s\n' "FAIL dirty default scan created remediation issues"
	exit 1
fi
if ! grep -q 'skipping uncommitted scan' "$LOGFILE"; then
	printf '%s\n' "FAIL dirty default scan did not record its skip reason"
	exit 1
fi
WORKTREE_STATE=""
export WORKTREE_STATE

QLTY_MODE="unstable"
export QLTY_MODE
unstable_result=$(_sweep_qlty "owner/repo" "$TMP_REPO")
unstable_remainder="${unstable_result#*|}"
unstable_count="${unstable_remainder%%|*}"
if [[ "$unstable_count" != "inconclusive" ]]; then
	printf '%s\n' "FAIL unstable qlty scan became numeric telemetry: ${unstable_count}"
	exit 1
fi
if [[ "$(<"$QLTY_CREATE_CALLS")" != "called" ]]; then
	printf '%s\n' "FAIL unstable qlty scan created remediation evidence"
	exit 1
fi
if ! grep -q 'Qlty telemetry INCONCLUSIVE: unstable normalized identities' "$LOGFILE"; then
	printf '%s\n' "FAIL unstable qlty scan omitted inconclusive diagnostics"
	exit 1
fi
QLTY_MODE="stable"
export QLTY_MODE

mkdir -p "${TMP_REL_PARENT}/target-repo/.qlty" "${TMP_CDPATH_PARENT}/target-repo/.qlty"
printf '%s\n' '[plugins]' >"${TMP_REL_PARENT}/target-repo/.qlty/qlty.toml"
printf '%s\n' '[plugins]' >"${TMP_CDPATH_PARENT}/target-repo/.qlty/qlty.toml"

rm -f "$QLTY_PWD_FILE"
(
	cd "$TMP_REL_PARENT"
	CDPATH="$TMP_CDPATH_PARENT" _sweep_qlty "owner/repo" "target-repo" >/dev/null
)

actual_pwd=$(<"$QLTY_PWD_FILE")
if [[ "$actual_pwd" != "${TMP_REL_PARENT}/target-repo" ]]; then
	printf '%s\n' "FAIL qlty relative path was hijacked by CDPATH: expected ${TMP_REL_PARENT}/target-repo, got ${actual_pwd}"
	exit 1
fi

printf '%s\n' "PASS _sweep_qlty runs from repo_path"

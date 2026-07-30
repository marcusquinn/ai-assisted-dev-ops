#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Regression guard for GH#28872: refresh and publication use an isolated state snapshot.

set -euo pipefail
# Fixture repositories are disposable; bypass interactive canonical-repo guards.
PATH="/usr/bin:/bin:/usr/sbin:/sbin"
export PATH

SCRIPT_DIR_TEST="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
SCRIPT_DIR="${SCRIPT_DIR_TEST}/.."
STATE_SCRIPT="${SCRIPT_DIR}/pulse-simplification-state.sh"
ORCHESTRATION_SCRIPT="${SCRIPT_DIR}/pulse-simplification-orchestration.sh"
TEST_ROOT="$(mktemp -d)"
REMOTE="${TEST_ROOT}/remote.git"
REPO="${TEST_ROOT}/canonical"
OBSERVED="${TEST_ROOT}/observed-state"
LOGFILE="${TEST_ROOT}/pulse.log"
AIDEVOPS_TEMP_DIR="${TEST_ROOT}/managed-temp"
export AIDEVOPS_TEMP_DIR LOGFILE OBSERVED

cleanup() {
	rm -rf "$TEST_ROOT"
	return 0
}
trap cleanup EXIT

state_digest() {
	local repo_path="$1"
	{
		git -C "$repo_path" rev-parse HEAD
		git -C "$repo_path" ls-files -s
		git -C "$repo_path" diff --binary
		git -C "$repo_path" diff --cached --binary
		git -C "$repo_path" status --porcelain=v1 --untracked-files=all
	} | git hash-object --stdin
	return 0
}

git init --bare --initial-branch=main "$REMOTE" >/dev/null
git clone -q "$REMOTE" "$REPO"
git -C "$REPO" config user.name Test
git -C "$REPO" config user.email test@example.invalid
git -C "$REPO" config commit.gpgsign false
mkdir -p "${REPO}/.agents/configs"
printf '%s\n' '#!/usr/bin/env bash' 'printf refreshed' >"${REPO}/tracked.sh"
printf '%s\n' '{"files":{"tracked.sh":{"hash":"0000000000000000000000000000000000000000","passes":1}}}' \
	>"${REPO}/.agents/configs/simplification-state.json"
git -C "$REPO" add .
git -C "$REPO" commit -qm seed
git -C "$REPO" push -q origin main
git -C "$REPO" remote set-head origin main

SCAN_HELPER="${TEST_ROOT}/scan-helper.sh"
cat >"$SCAN_HELPER" <<'SCAN'
#!/usr/bin/env bash
set -euo pipefail
scan_type=""
state_file=""
shift 2
while [[ $# -gt 0 ]]; do
	case "$1" in
	--type) scan_type="$2"; shift 2 ;;
	--state-file) state_file="$2"; shift 2 ;;
	*) shift ;;
	esac
done
hash=$(jq -r '.files["tracked.sh"].hash' "$state_file")
printf '%s|%s|%s\n' "$scan_type" "$state_file" "$hash" >>"$OBSERVED"
exit 0
SCAN
chmod +x "$SCAN_HELPER"

# shellcheck source=../pulse-simplification-state.sh
source "$STATE_SCRIPT"
# shellcheck source=../pulse-simplification-orchestration.sh
source "$ORCHESTRATION_SCRIPT"

_simplification_state_backfill_closed() {
	local _repo_path="$1"
	local _state_file="$2"
	local _repo_slug="$3"
	printf '0\n'
	return 0
}

_simplification_close_spurious_requeue_issues() {
	local _repo_path="$1"
	local _repo_slug="$2"
	printf '0\n'
	return 0
}

_complexity_scan_create_issues() {
	local _results="$1"
	local _repos_json="$2"
	local _repo_slug="$3"
	return 0
}

_complexity_scan_create_md_issues() {
	local _results="$1"
	local _repos_json="$2"
	local _repo_slug="$3"
	return 0
}

before=$(state_digest "$REPO")
expected_hash=$(git -C "$REPO" hash-object tracked.sh)
AIDEVOPS_PLANNING_VALIDATOR=/usr/bin/true \
	_complexity_scan_run_isolated_state_cycle "$SCAN_HELPER" "$REPO" "${TEST_ROOT}/repos.json" test/aidevops
after=$(state_digest "$REPO")
first_remote=$(git --git-dir="$REMOTE" rev-parse main)

[[ "$before" == "$after" ]]
[[ "$(git --git-dir="$REMOTE" show main:.agents/configs/simplification-state.json | jq -r '.files["tracked.sh"].hash')" == "$expected_hash" ]]
[[ "$(wc -l <"$OBSERVED" | tr -d ' ')" == "2" ]]
[[ "$(cut -d'|' -f3 "$OBSERVED" | sort -u)" == "$expected_hash" ]]
observed_state=$(cut -d'|' -f2 "$OBSERVED" | sort -u)
[[ "$observed_state" != "${REPO}/.agents/configs/simplification-state.json" ]]
[[ ! -e "$observed_state" ]]

: >"$OBSERVED"
AIDEVOPS_PLANNING_VALIDATOR=/usr/bin/true \
	_complexity_scan_run_isolated_state_cycle "$SCAN_HELPER" "$REPO" "${TEST_ROOT}/repos.json" test/aidevops
[[ "$before" == "$(state_digest "$REPO")" ]]
[[ "$first_remote" == "$(git --git-dir="$REMOTE" rev-parse main)" ]]
[[ "$(wc -l <"$OBSERVED" | tr -d ' ')" == "2" ]]

printf 'PASS simplification-state refresh publication remains checkout-isolated\n'
exit 0

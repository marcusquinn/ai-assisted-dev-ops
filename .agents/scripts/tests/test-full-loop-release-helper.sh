#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit
ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT
mkdir -p "$ROOT/bin" "$ROOT/repo/linked-branch" "$ROOT/repo/.agents/scripts" \
	"$ROOT/repo/.git" "$ROOT/worktrees" "$ROOT/cleanup" "$ROOT/state"
export AIDEVOPS_STATE_DIR="$ROOT/state"
export LANE_HEAD_FILE="$ROOT/lane-head"
export LANE_STATE_FILE="$ROOT/lane-state.json"
: >"$ROOT/repo/aidevops.sh"
: >"$ROOT/repo/.agents/scripts/version-manager.sh"

cat >"$ROOT/bin/git" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${GIT_CALL_LOG:?}"
case "$*" in
*rev-parse\ --show-toplevel*) printf '%s\n' "${FAKE_REPO_ROOT:?}" ;;
*show\ *:VERSION*) printf '2.9.9\n' ;;
*rev-parse\ refs/tags/v3.0.0*) printf '%040d\n' 0 ;;
*rev-parse\ HEAD*) printf '%040d\n' 0 ;;
*worktree\ add*)
	for arg in "$@"; do
		case "$arg" in
		*/aidevops-release-*)
			mkdir -p "$arg"
			: >"$arg/.git"
			;;
		esac
	done
	;;
*worktree\ remove*)
	for arg in "$@"; do
		case "$arg" in */aidevops-release-*) rm -rf "$arg" ;; esac
	done
	;;
esac
exit 0
STUB
chmod +x "$ROOT/bin/git"

cat >"$ROOT/bin/gh" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "api" ]]; then
	endpoint=""
	for api_arg in "$@"; do
		case "$api_arg" in repos/*) endpoint="$api_arg" ;; esac
	done
	case "$endpoint" in
	"repos/marcusquinn/aidevops/git/ref/heads/aidevops/release-lane")
		if [[ -f "${LANE_HEAD_FILE:?}" ]]; then
			IFS= read -r lane_head <"$LANE_HEAD_FILE"
			printf '%s\n' "$lane_head"
			exit 0
		fi
		[[ "$*" == *"--include"* ]] && printf 'HTTP/2 404\n'
		exit 1
		;;
	"repos/marcusquinn/aidevops/git/ref/heads/main")
		printf '%040d\n' 0
		exit 0
		;;
	"repos/marcusquinn/aidevops/git/commits/"*)
		printf '%040d\n' 1
		exit 0
		;;
	"repos/marcusquinn/aidevops/git/blobs")
		payload=$(</dev/stdin)
		jq -r '.content' <<<"$payload" >"${LANE_STATE_FILE:?}"
		printf '%040d\n' 2
		exit 0
		;;
	"repos/marcusquinn/aidevops/git/trees")
		printf '%040d\n' 3
		exit 0
		;;
	"repos/marcusquinn/aidevops/git/commits")
		printf '%040d\n' 4
		exit 0
		;;
	"repos/marcusquinn/aidevops/git/refs" | "repos/marcusquinn/aidevops/git/refs/heads/aidevops/release-lane")
		printf '%040d\n' 4 >"${LANE_HEAD_FILE:?}"
		exit 0
		;;
	"repos/marcusquinn/aidevops/contents/.aidevops-release-lane.json?ref="*)
		[[ -f "${LANE_STATE_FILE:?}" ]] || exit 1
		IFS= read -r lane_state <"$LANE_STATE_FILE"
		printf '%s\n' "$lane_state"
		exit 0
		;;
	esac
	exit 1
fi
if [[ "${1:-}" == "repo" && "${2:-}" == "view" ]]; then
	printf 'repo-view-cwd=%s\n' "$PWD" >>"${GH_CALL_LOG:?}"
	case "$PWD" in
	"${FAKE_CONTROL_PARENT:?}"/aidevops-release-control-*) printf 'marcusquinn/aidevops\n' ;;
	*) printf 'wrong/caller-repo\n' ;;
	esac
	exit 0
fi
if [[ "${1:-}" == "pr" && "${2:-}" == "view" ]]; then
	printf '{"state":"MERGED","mergedAt":"2026-07-27T00:00:00Z","baseRefName":"main","mergeCommit":{"oid":"%040d"}}\n' 1
	exit 0
fi
exit 1
STUB
chmod +x "$ROOT/bin/gh"

cat >"$ROOT/version-manager.sh" <<'STUB'
#!/usr/bin/env bash
printf 'args=%s\n' "$*" >"${VM_CALL_LOG:?}"
printf 'cwd=%s\n' "$PWD" >>"$VM_CALL_LOG"
printf 'intent=%s\n' "${AIDEVOPS_RELEASE_INTENT_TRUSTED:-}" >>"$VM_CALL_LOG"
printf 'priority=%s\n' "${AIDEVOPS_TRUSTED_ISSUE_PRIORITY:-}" >>"$VM_CALL_LOG"
printf 'deploy=%s\n' "${AIDEVOPS_RELEASE_DEPLOY_SCOPE:-}" >>"$VM_CALL_LOG"
if [[ "${VM_EXIT:-0}" -eq 0 ]]; then
	printf '3.0.0\n' >VERSION
fi
exit "${VM_EXIT:-0}"
STUB
chmod +x "$ROOT/version-manager.sh"

cat >"$ROOT/source-resolver.sh" <<'STUB'
#!/usr/bin/env bash
command="${1:-}"
shift || true
source_pr=""
expected_sources=""
while [[ $# -gt 0 ]]; do
	case "$1" in
	--source-pr) source_pr="$2"; shift 2 ;;
	--expected-sources) expected_sources="$2"; shift 2 ;;
	*) shift ;;
	esac
done
if [[ -n "${RESOLVER_CALL_LOG:-}" ]]; then
	printf 'expected=%s\n' "$expected_sources" >>"$RESOLVER_CALL_LOG"
fi
if [[ "${RESOLVER_MODE:-direct}" == "blocked" && "$command" == "resolve-source" ]]; then
	exit 1
elif [[ "${RESOLVER_MODE:-direct}" == "aggregate" ]]; then
	printf '{"mode":"aggregate","requested_pr":%s,"source_pr":99,"source_merge":"%040d","aggregated_sources":[{"pr":%s,"merge":"%040d"}],"expected_sources":[{"pr":%s,"merge":"%040d"}]}\n' \
		"$source_pr" 0 "$source_pr" 1 "$source_pr" 1
else
	printf '{"mode":"direct","requested_pr":%s,"source_pr":%s,"source_merge":"%040d","aggregated_sources":[],"expected_sources":[{"pr":%s,"merge":"%040d"}]}\n' \
		"$source_pr" "$source_pr" 0 "$source_pr" 0
fi
exit 0
STUB
chmod +x "$ROOT/source-resolver.sh"

(
	cd "$ROOT/repo/linked-branch"
	PATH="$ROOT/bin:/usr/bin:/bin" \
		GIT_CALL_LOG="$ROOT/git.log" \
		GH_CALL_LOG="$ROOT/gh.log" \
		RESOLVER_CALL_LOG="$ROOT/resolver.log" \
		VM_CALL_LOG="$ROOT/vm.log" \
		FAKE_REPO_ROOT="$ROOT/repo" \
		FAKE_CONTROL_PARENT="$ROOT/worktrees" \
		AIDEVOPS_WORKTREE_BASE_DIR="$ROOT/worktrees" \
		AIDEVOPS_FULL_LOOP_VERSION_MANAGER="../../version-manager.sh" \
		AIDEVOPS_FULL_LOOP_SOURCE_RESOLVER="$ROOT/source-resolver.sh" \
		AIDEVOPS_FULL_LOOP_RECEIPT_DIR="$ROOT/receipts" \
		AIDEVOPS_TRUSTED_ISSUE_PRIORITY=critical \
		bash "$SCRIPT_DIR/full-loop-release-helper.sh" minor 42 full --expected-sources 42
)

grep -q 'worktree add --detach' "$ROOT/git.log"
grep -q 'worktree remove' "$ROOT/git.log"
grep -qx 'args=release minor --source-pr 42 --expected-sources 42@0000000000000000000000000000000000000000' "$ROOT/vm.log"
grep -qx 'expected=42' "$ROOT/resolver.log"
grep -Eq "^cwd=${ROOT}/worktrees/aidevops-release-42-[0-9]+$" "$ROOT/vm.log"
grep -qx 'intent=1' "$ROOT/vm.log"
grep -qx 'priority=critical' "$ROOT/vm.log"
grep -qx 'deploy=full' "$ROOT/vm.log"
grep -qx 'published' "$ROOT/receipts/marcusquinn_aidevops-42.status"
jq -e '.expected_sources == [{"pr":42,"merge":"0000000000000000000000000000000000000000"}]' \
	"$ROOT/receipts/marcusquinn_aidevops-42.authorization.json" >/dev/null
grep -Eq "^repo-view-cwd=${ROOT}/worktrees/aidevops-release-control-[0-9]+$" "$ROOT/gh.log"
if grep -Fq -- "-C $ROOT/repo fetch " "$ROOT/git.log" ||
	! grep -Eq -- "-C ${ROOT}/worktrees/aidevops-release-control-[0-9]+ fetch origin (main|--tags)" \
		"$ROOT/git.log"; then
	printf 'FAIL canonical release Git mutations did not move into a linked control worktree\n'
	exit 1
fi
if compgen -G "$ROOT/worktrees/aidevops-release-control-*" >/dev/null; then
	printf 'FAIL linked release control worktree was not removed\n'
	exit 1
fi
printf 'PASS canonical release Git mutations use a temporary linked control worktree\n'
if compgen -G "$ROOT/worktrees/aidevops-release-42-*" >/dev/null; then
	printf 'FAIL detached release worktree was not removed\n'
	exit 1
fi
printf 'PASS detached release runner persists publication receipt after successful gates\n'

cp "$ROOT/vm.log" "$ROOT/vm-after-publication.log"
printf '%s\n' '{"schema_version":1,"repository":"marcusquinn/aidevops","pr_number":42,"release_status":"not-requested"}' \
	>"$ROOT/cleanup/marcusquinn_aidevops-42.json"
worktree_adds_before=$(grep -c 'worktree add --detach .*/aidevops-release-42-' "$ROOT/git.log")
(
	cd "$ROOT/repo/linked-branch"
	PATH="$ROOT/bin:/usr/bin:/bin" \
		GIT_CALL_LOG="$ROOT/git.log" \
		VM_CALL_LOG="$ROOT/vm.log" \
		FAKE_REPO_ROOT="$ROOT/repo" \
		AIDEVOPS_WORKTREE_BASE_DIR="$ROOT/worktrees" \
		AIDEVOPS_FULL_LOOP_VERSION_MANAGER="../../version-manager.sh" \
		AIDEVOPS_FULL_LOOP_SOURCE_RESOLVER="$ROOT/source-resolver.sh" \
		AIDEVOPS_FULL_LOOP_RECEIPT_DIR="$ROOT/receipts" \
		AIDEVOPS_FULL_LOOP_CLEANUP_DIR="$ROOT/cleanup" \
		AIDEVOPS_FULL_LOOP_REPO=marcusquinn/aidevops \
		bash "$SCRIPT_DIR/full-loop-release-helper.sh" minor 42 full
)
cmp -s "$ROOT/vm.log" "$ROOT/vm-after-publication.log"
worktree_adds_after=$(grep -c 'worktree add --detach .*/aidevops-release-42-' "$ROOT/git.log")
[[ "$worktree_adds_after" -eq "$worktree_adds_before" ]]
jq -e '.release_status == "published"' "$ROOT/cleanup/marcusquinn_aidevops-42.json" >/dev/null
printf 'PASS repeated detached release reconciliation skips duplicate publication\n'

pending_rc=0
(
	cd "$ROOT/repo/linked-branch"
	PATH="$ROOT/bin:/usr/bin:/bin" \
		GIT_CALL_LOG="$ROOT/git.log" \
		VM_CALL_LOG="$ROOT/pending-vm.log" \
		VM_EXIT=8 \
		FAKE_REPO_ROOT="$ROOT/repo" \
		AIDEVOPS_WORKTREE_BASE_DIR="$ROOT/worktrees" \
		AIDEVOPS_FULL_LOOP_VERSION_MANAGER="../../version-manager.sh" \
		AIDEVOPS_FULL_LOOP_SOURCE_RESOLVER="$ROOT/source-resolver.sh" \
		AIDEVOPS_FULL_LOOP_RECEIPT_DIR="$ROOT/receipts" \
		AIDEVOPS_FULL_LOOP_REPO=marcusquinn/aidevops \
		bash "$SCRIPT_DIR/full-loop-release-helper.sh" patch 46 incremental
) >/dev/null 2>&1 || pending_rc=$?
if [[ "$pending_rc" -ne 8 ||
	-e "$ROOT/receipts/marcusquinn_aidevops-46.status" ||
	-e "$ROOT/receipts/marcusquinn_aidevops-46.failure.json" ]]; then
	printf 'FAIL durable queued release was recorded as terminal evidence\n'
	exit 1
fi
printf 'PASS durable queued release returns pending without false terminal evidence\n'
rm -f "$LANE_HEAD_FILE" "$LANE_STATE_FILE"

if (
	cd "$ROOT/repo/linked-branch"
	PATH="$ROOT/bin:/usr/bin:/bin" \
		GIT_CALL_LOG="$ROOT/git.log" \
		VM_CALL_LOG="$ROOT/vm.log" \
		VM_EXIT=1 \
		FAKE_REPO_ROOT="$ROOT/repo" \
		AIDEVOPS_WORKTREE_BASE_DIR="$ROOT/worktrees" \
		AIDEVOPS_FULL_LOOP_VERSION_MANAGER="../../version-manager.sh" \
		AIDEVOPS_FULL_LOOP_SOURCE_RESOLVER="$ROOT/source-resolver.sh" \
		AIDEVOPS_FULL_LOOP_RECEIPT_DIR="$ROOT/receipts" \
		AIDEVOPS_FULL_LOOP_REPO=marcusquinn/aidevops \
		bash "$SCRIPT_DIR/full-loop-release-helper.sh" patch 43 incremental
); then
	printf 'FAIL partial release returned success\n'
	exit 1
fi
grep -qx 'failed' "$ROOT/receipts/marcusquinn_aidevops-43.status"
jq -e '.status == "failed" and .requested_pr == 43 and .requested_merge == .current_head
	and .attempted_tag == "v2.9.10" and .release_type == "patch"' \
	"$ROOT/receipts/marcusquinn_aidevops-43.failure.json" >/dev/null
printf 'PASS failed release persists actionable provenance without publication evidence\n'
rm -f "$LANE_HEAD_FILE" "$LANE_STATE_FILE"

if (
	cd "$ROOT/repo/linked-branch"
	PATH="$ROOT/bin:/usr/bin:/bin" GIT_CALL_LOG="$ROOT/git.log" VM_CALL_LOG="$ROOT/vm.log" \
		FAKE_REPO_ROOT="$ROOT/repo" RESOLVER_MODE=blocked AIDEVOPS_WORKTREE_BASE_DIR="$ROOT/worktrees" \
		AIDEVOPS_FULL_LOOP_VERSION_MANAGER="../../version-manager.sh" \
		AIDEVOPS_FULL_LOOP_SOURCE_RESOLVER="$ROOT/source-resolver.sh" \
		AIDEVOPS_FULL_LOOP_RECEIPT_DIR="$ROOT/receipts" AIDEVOPS_FULL_LOOP_REPO=marcusquinn/aidevops \
		bash "$SCRIPT_DIR/full-loop-release-helper.sh" patch 47 incremental
); then
	printf 'FAIL intervening main commit returned release success\n'
	exit 1
fi
grep -qx 'failed' "$ROOT/receipts/marcusquinn_aidevops-47.status"
jq -e '.requested_pr == 47 and .requested_merge == "0000000000000000000000000000000000000001"
	and .current_head == "0000000000000000000000000000000000000000" and .release_source_pr == null' \
	"$ROOT/receipts/marcusquinn_aidevops-47.failure.json" >/dev/null
printf 'PASS intervening main commit records both SHAs without publication\n'
rm -f "$LANE_HEAD_FILE" "$LANE_STATE_FILE"

printf '%s\n' not-requested >"$ROOT/receipts/marcusquinn_aidevops-44.status"
cp "$ROOT/vm.log" "$ROOT/vm-before-skipped-release.log"
(
	cd "$ROOT/repo/linked-branch"
	PATH="$ROOT/bin:/usr/bin:/bin" \
		GIT_CALL_LOG="$ROOT/git.log" \
		VM_CALL_LOG="$ROOT/vm.log" \
		FAKE_REPO_ROOT="$ROOT/repo" \
		AIDEVOPS_WORKTREE_BASE_DIR="$ROOT/worktrees" \
		AIDEVOPS_FULL_LOOP_VERSION_MANAGER="../../version-manager.sh" \
		AIDEVOPS_FULL_LOOP_SOURCE_RESOLVER="$ROOT/source-resolver.sh" \
		AIDEVOPS_FULL_LOOP_RECEIPT_DIR="$ROOT/receipts" \
		AIDEVOPS_FULL_LOOP_REPO=marcusquinn/aidevops \
		bash "$SCRIPT_DIR/full-loop-release-helper.sh" patch 44 incremental
)
grep -qx 'published' "$ROOT/receipts/marcusquinn_aidevops-44.status"
if cmp -s "$ROOT/vm.log" "$ROOT/vm-before-skipped-release.log"; then
	printf 'FAIL later release authorization did not invoke publication\n'
	exit 1
fi
printf 'PASS no-release evidence permits a later explicitly authorized publication\n'

(
	cd "$ROOT/repo/linked-branch"
	PATH="$ROOT/bin:/usr/bin:/bin" \
		GIT_CALL_LOG="$ROOT/git.log" \
		VM_CALL_LOG="$ROOT/aggregate-vm.log" \
		FAKE_REPO_ROOT="$ROOT/repo" \
		RESOLVER_MODE=aggregate \
		AIDEVOPS_WORKTREE_BASE_DIR="$ROOT/worktrees" \
		AIDEVOPS_FULL_LOOP_VERSION_MANAGER="../../version-manager.sh" \
		AIDEVOPS_FULL_LOOP_SOURCE_RESOLVER="$ROOT/source-resolver.sh" \
		AIDEVOPS_FULL_LOOP_RECEIPT_DIR="$ROOT/receipts" \
		AIDEVOPS_FULL_LOOP_REPO=marcusquinn/aidevops \
		bash "$SCRIPT_DIR/full-loop-release-helper.sh" patch 45 incremental
)
grep -qx 'published' "$ROOT/receipts/marcusquinn_aidevops-99.status"
grep -qx 'superseded' "$ROOT/receipts/marcusquinn_aidevops-45.status"
jq -e '.status == "superseded" and .pr_number == 45 and .aggregate_pr == 99 and .release_tag == "v3.0.0"' \
	"$ROOT/receipts/marcusquinn_aidevops-45.aggregate.json" >/dev/null
cp "$ROOT/aggregate-vm.log" "$ROOT/aggregate-vm-before-retry.log"
printf '%s\n' '{"schema_version":1,"repository":"marcusquinn/aidevops","pr_number":45,"release_status":"not-requested"}' \
	>"$ROOT/cleanup/marcusquinn_aidevops-45.json"
(
	cd "$ROOT/repo/linked-branch"
	PATH="$ROOT/bin:/usr/bin:/bin" \
		GIT_CALL_LOG="$ROOT/git.log" VM_CALL_LOG="$ROOT/aggregate-vm.log" FAKE_REPO_ROOT="$ROOT/repo" \
		AIDEVOPS_WORKTREE_BASE_DIR="$ROOT/worktrees" AIDEVOPS_FULL_LOOP_RECEIPT_DIR="$ROOT/receipts" \
		AIDEVOPS_FULL_LOOP_CLEANUP_DIR="$ROOT/cleanup" \
		AIDEVOPS_FULL_LOOP_REPO=marcusquinn/aidevops \
		bash "$SCRIPT_DIR/full-loop-release-helper.sh" patch 45 incremental
)
cmp -s "$ROOT/aggregate-vm.log" "$ROOT/aggregate-vm-before-retry.log"
jq -e '.release_status == "superseded"' "$ROOT/cleanup/marcusquinn_aidevops-45.json" >/dev/null

printf '%s\n' '{"schema_version":1,"repository":"wrong/repo","pr_number":45,"release_status":"not-requested"}' \
	>"$ROOT/cleanup/marcusquinn_aidevops-45.json"
if (
	cd "$ROOT/repo/linked-branch"
	PATH="$ROOT/bin:/usr/bin:/bin" GIT_CALL_LOG="$ROOT/git.log" VM_CALL_LOG="$ROOT/aggregate-vm.log" \
		FAKE_REPO_ROOT="$ROOT/repo" AIDEVOPS_WORKTREE_BASE_DIR="$ROOT/worktrees" \
		AIDEVOPS_FULL_LOOP_RECEIPT_DIR="$ROOT/receipts" AIDEVOPS_FULL_LOOP_CLEANUP_DIR="$ROOT/cleanup" \
		AIDEVOPS_FULL_LOOP_REPO=marcusquinn/aidevops \
		bash "$SCRIPT_DIR/full-loop-release-helper.sh" patch 45 incremental
); then
	printf 'FAIL mismatched cleanup receipt accepted terminal release replay\n'
	exit 1
fi
jq -e '.repository == "wrong/repo" and .release_status == "not-requested"' \
	"$ROOT/cleanup/marcusquinn_aidevops-45.json" >/dev/null
printf 'PASS reviewed aggregate source publishes once and truthfully supersedes included receipts\n'

(
	cd "$ROOT/repo/linked-branch"
	export PATH="$ROOT/bin:/usr/bin:/bin"
	export GIT_CALL_LOG="$ROOT/git.log"
	export FAKE_REPO_ROOT="$ROOT/repo"
	export AIDEVOPS_WORKTREE_BASE_DIR="$ROOT/worktrees"
	export AIDEVOPS_FULL_LOOP_RECEIPT_DIR="$ROOT/receipts"
	export AIDEVOPS_FULL_LOOP_REPO=marcusquinn/aidevops
	source "$SCRIPT_DIR/full-loop-release-helper.sh" help >/dev/null
	persisted_sources=48@0000000000000000000000000000000000000000
	lane_checks=0
	expansion_calls=0
	_full_loop_recovery_lane_requires_prepublication_transaction() {
		local repo="$1"
		local source_pr="$2"
		local observed_sources="$3"
		[[ "$repo" == "marcusquinn/aidevops" && "$source_pr" == "48" &&
			"$observed_sources" == "$persisted_sources" ]] || return 1
		lane_checks=$((lane_checks + 1))
		return 0
	}
	_full_loop_recovery_expand_reserved_authorization() {
		local repo="$1"
		local source_pr="$2"
		local requested_sources="$3"
		local release_type="$4"
		[[ "$repo" == "marcusquinn/aidevops" && "$source_pr" == "48" &&
			"$requested_sources" == "$persisted_sources" && "$release_type" == "patch" ]] || return 1
		expansion_calls=$((expansion_calls + 1))
		_FULL_LOOP_AGGREGATE_RECOVERY_EXPECTED="$requested_sources"
		return 0
	}
	_full_loop_release_resolve_persisted_intent marcusquinn/aidevops 48 "" "$persisted_sources" patch
	[[ "$lane_checks" -eq 1 && "$expansion_calls" -eq 1 &&
		"$_FULL_LOOP_RESERVED_RECOVERY_EXPECTED" == "$persisted_sources" &&
		"$_FULL_LOOP_RESERVED_RECOVERY_COMPLETED" == "true" &&
		"$_FULL_LOOP_RESERVED_RECOVERY_FAILED_PREPUBLICATION" == "false" ]]
)
printf 'PASS omitted expected sources still resume a persisted failed pre-publication transaction\n'

(
	cd "$ROOT/repo/linked-branch"
	export PATH="$ROOT/bin:/usr/bin:/bin"
	export GIT_CALL_LOG="$ROOT/git.log"
	export FAKE_REPO_ROOT="$ROOT/repo"
	export AIDEVOPS_WORKTREE_BASE_DIR="$ROOT/worktrees"
	export AIDEVOPS_FULL_LOOP_REPO=marcusquinn/aidevops
	export RESOLVER_MODE=blocked
	source "$SCRIPT_DIR/full-loop-release-helper.sh" help >/dev/null
	evidence_writes=0
	persisted_sources=48@0000000000000000000000000000000000000000
	fixture_blocked_merge=0000000000000000000000000000000000000001
	fixture_blocked_head=0000000000000000000000000000000000000000
	_full_loop_write_release_failure_evidence() {
		local repo="$1"
		local source_pr="$2"
		local requested_merge="$3"
		local current_head="$4"
		[[ "$repo" == "marcusquinn/aidevops" && "$source_pr" == "48" &&
			"$requested_merge" == "$fixture_blocked_merge" && "$current_head" == "$fixture_blocked_head" ]] || return 1
		evidence_writes=$((evidence_writes + 1))
		return 0
	}
	gh() {
		local command_name="$1"
		local object_name="$2"
		[[ "$command_name" == "pr" && "$object_name" == "view" ]] || return 1
		jq -cn --arg merge "$fixture_blocked_merge" \
			'{state:"MERGED",mergedAt:"2026-08-24T02:00:00Z",baseRefName:"main",mergeCommit:{oid:$merge}}'
		return 0
	}
	git() {
		local option="$1"
		local repo_path="$2"
		local operation="$3"
		[[ "$option" == "-C" && "$repo_path" == "$ROOT/repo/linked-branch" ]] || return 1
		case "$operation" in
		rev-parse) printf '%s\n' "$fixture_blocked_head" ;;
		merge-base) return 0 ;;
		*) return 1 ;;
		esac
		return 0
	}
	_FULL_LOOP_RESERVED_RECOVERY_COMPLETED=true
	_FULL_LOOP_RESERVED_RECOVERY_FAILED_PREPUBLICATION=true
	_FULL_LOOP_PRESERVE_PREPUBLICATION_FAILURE_EVIDENCE=false
	resolve_rc=0
	_full_loop_resolve_requested_release_source marcusquinn/aidevops 48 \
		"$ROOT/repo/linked-branch" "$ROOT/source-resolver.sh" "$persisted_sources" || resolve_rc=$?
	[[ "$resolve_rc" -ne 0 && "$evidence_writes" -eq 0 ]]
	_FULL_LOOP_RESERVED_RECOVERY_FAILED_PREPUBLICATION=false
	_FULL_LOOP_PRESERVE_PREPUBLICATION_FAILURE_EVIDENCE=true
	resolve_rc=0
	_full_loop_resolve_requested_release_source marcusquinn/aidevops 48 \
		"$ROOT/repo/linked-branch" "$ROOT/source-resolver.sh" "$persisted_sources" || resolve_rc=$?
	[[ "$resolve_rc" -ne 0 && "$evidence_writes" -eq 0 ]]
	_FULL_LOOP_PRESERVE_PREPUBLICATION_FAILURE_EVIDENCE=false
	resolve_rc=0
	_full_loop_resolve_requested_release_source marcusquinn/aidevops 48 \
		"$ROOT/repo/linked-branch" "$ROOT/source-resolver.sh" "$persisted_sources" || resolve_rc=$?
	[[ "$resolve_rc" -ne 0 && "$evidence_writes" -eq 1 ]]
)
printf 'PASS recovered retries preserve their original failure evidence until preparing\n'

exit 0

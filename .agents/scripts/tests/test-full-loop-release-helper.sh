#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit
ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT
mkdir -p "$ROOT/bin" "$ROOT/repo/linked-branch" "$ROOT/repo/.agents/scripts" \
	"$ROOT/repo/.git" "$ROOT/worktrees" "$ROOT/cleanup"
: >"$ROOT/repo/aidevops.sh"
: >"$ROOT/repo/.agents/scripts/version-manager.sh"

cat >"$ROOT/bin/git" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${GIT_CALL_LOG:?}"
case "$*" in
*rev-parse\ --show-toplevel*) printf '%s\n' "${FAKE_REPO_ROOT:?}" ;;
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
jq -e '.status == "failed" and .requested_pr == 43 and .requested_merge == .current_head' \
	"$ROOT/receipts/marcusquinn_aidevops-43.failure.json" >/dev/null
printf 'PASS failed release persists actionable provenance without publication evidence\n'

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

exit 0

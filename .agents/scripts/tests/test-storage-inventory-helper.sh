#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="$SCRIPT_DIR/../storage-inventory-helper.sh"
AUDIT_HELPER="$SCRIPT_DIR/../audit-worktree-removal-helper.sh"
GIT_BIN="${AIDEVOPS_TEST_GIT_BIN:-/usr/bin/git}"
TEST_ROOT="$(mktemp -d -t aidevops-storage-inventory.XXXXXX)"
HOME="$TEST_ROOT/home"
export HOME
AIDEVOPS_WORKTREE_TRASH_ROOT="$HOME/.aidevops/recovery/worktrees"
export AIDEVOPS_WORKTREE_TRASH_ROOT
# shellcheck source=../audit-worktree-removal-helper.sh
source "$AUDIT_HELPER"

cleanup() {
	rm -rf "$TEST_ROOT"
	return 0
}
trap cleanup EXIT

fail() {
	local message="$1"
	printf 'FAIL: %s\n' "$message" >&2
	exit 1
}

make_fixture() {
	mkdir -p \
		"$HOME/.aidevops/runtime-bundles/bundle-a" \
		"$HOME/.aidevops/.agent-workspace/observability" \
		"$HOME/.aidevops/agents-backups/20260101_000001" \
		"$HOME/.aidevops/agents-backups/20260102_000001" \
		"$HOME/.aidevops/logs/worker-failure-excerpts" \
		"$HOME/.aidevops/logs/pulse-archive" \
		"$HOME/.local/share/opencode" \
		"$HOME/.npm"
	printf 'bundle-data\n' >"$HOME/.aidevops/runtime-bundles/bundle-a/data"
	printf 'audit-data\n' >"$HOME/.aidevops/.agent-workspace/observability/events"
	printf 'backup-data-a\n' >"$HOME/.aidevops/agents-backups/20260101_000001/data"
	printf 'backup-data-b\n' >"$HOME/.aidevops/agents-backups/20260102_000001/data"
	printf 'log-data\n' >"$HOME/.aidevops/logs/pulse.log"
	printf 'failure-a\n' >"$HOME/.aidevops/logs/worker-failure-excerpts/issue-1-20260101T000001Z-1.log"
	printf 'failure-b\n' >"$HOME/.aidevops/logs/worker-failure-excerpts/issue-1-20260101T000002Z-2.log"
	printf 'runtime-data\n' >"$HOME/.local/share/opencode/opencode.db"
	printf 'cache-data\n' >"$HOME/.npm/cache"
	return 0
}

make_recovery_fixture() {
	local repo_path="$TEST_ROOT/recovery-repo"
	local worktree_path="$TEST_ROOT/recovery-worktree"

	"$GIT_BIN" init -q -b main "$repo_path" || return 1
	"$GIT_BIN" -C "$repo_path" config user.email test@example.invalid || return 1
	"$GIT_BIN" -C "$repo_path" config user.name 'Aidevops Test' || return 1
	"$GIT_BIN" -C "$repo_path" config commit.gpgsign false || return 1
	printf 'base\n' >"$repo_path/README.md" || return 1
	"$GIT_BIN" -C "$repo_path" add README.md || return 1
	"$GIT_BIN" -C "$repo_path" commit -q -m init || return 1
	"$GIT_BIN" -C "$repo_path" worktree add -q -b feature/recovery-inventory \
		"$worktree_path" main || return 1
	AIDEVOPS_REAL_GIT_BIN="$GIT_BIN" archive_worktree_path_recoverably \
		"$worktree_path" "test-storage-inventory-helper.sh" "storage-inventory" || return 1
	return 0
}

fixture_checksum() {
	cksum \
		"$HOME/.aidevops/runtime-bundles/bundle-a/data" \
		"$HOME/.aidevops/.agent-workspace/observability/events" \
		"$HOME/.aidevops/agents-backups/20260101_000001/data" \
		"$HOME/.aidevops/agents-backups/20260102_000001/data" \
		"$HOME/.aidevops/logs/pulse.log" \
		"$HOME/.aidevops/logs/worker-failure-excerpts/issue-1-20260101T000001Z-1.log" \
		"$HOME/.aidevops/logs/worker-failure-excerpts/issue-1-20260101T000002Z-2.log" \
		"$HOME/.local/share/opencode/opencode.db" \
		"$HOME/.npm/cache"
	return 0
}

make_fixture
make_recovery_fixture
before_checksum=$(fixture_checksum)
report=$(bash "$HELPER" json)
after_checksum=$(fixture_checksum)
[[ "$before_checksum" == "$after_checksum" ]] || fail "inventory changed fixture byte identity"

[[ "$(printf '%s' "$report" | jq -r '.schema_version')" == "2" ]] || fail "schema version missing"
[[ "$(printf '%s' "$report" | jq -r '.read_only')" == "true" ]] || fail "read-only marker missing"
[[ "$(printf '%s' "$report" | jq '.stores | length')" == "16" ]] || fail "expected explicit producer and split OpenCode stores"
[[ "$(printf '%s' "$report" | jq '[.stores[].reclaimable_bytes] | add')" == "0" ]] || fail "foundation report suggested reclaimable bytes"
[[ "$(printf '%s' "$report" | jq '[.stores[] | select(.total_bytes != null) | (.total_bytes == (.protected_bytes + .reclaimable_bytes + .unknown_bytes))] | all')" == "true" ]] || fail "storage categories did not reconcile with totals"
[[ "$(printf '%s' "$report" | jq -r '.stores[] | select(.store_id == "runtime-bundles") | .unknown_bytes > 0')" == "true" ]] || fail "runtime bundles were not fail-closed unknown"
[[ "$(printf '%s' "$report" | jq -r '.stores[] | select(.store_id == "observability") | .total_bytes > 0')" == "true" ]] || fail "observability bytes were not measured"
[[ "$(printf '%s' "$report" | jq -r '.stores[] | select(.store_id == "observability") | .unknown_bytes > 0')" == "true" ]] || fail "unattributed observability bytes did not fail closed"
[[ "$(printf '%s' "$report" | jq -r '.stores[] | select(.store_id == "observability") | has("active_bytes") and has("archive_bytes") and has("candidate_bytes")')" == "true" ]] || fail "observability lifecycle byte classes missing"
[[ "$(printf '%s' "$report" | jq -r '.stores[] | select(.store_id == "npm-cache") | .owner')" == "external" ]] || fail "npm ownership was claimed by aidevops"
[[ "$(printf '%s' "$report" | jq -r '.stores[] | select(.store_id == "opencode-active-db") | .owner')" == "joint" ]] || fail "OpenCode active DB ownership was not bounded"
[[ "$(printf '%s' "$report" | jq -r '.stores[] | select(.store_id == "opencode-active-db") | .safety_class')" == "unknown" ]] || fail "unavailable OpenCode schema did not fail closed"
[[ "$(printf '%s' "$report" | jq '[.stores[] | select(.store_id | startswith("opencode-")) | .reclaimable_bytes] | add')" == "0" ]] || fail "OpenCode report exposed cleanup candidates"
[[ "$(printf '%s' "$report" | jq -r '.stores[] | select(.store_id == "worktree-recovery") | .bucket_count')" == "1" ]] || fail "worktree recovery archive was not inventoried"
[[ "$(printf '%s' "$report" | jq -r '.stores[] | select(.store_id == "worktree-recovery") | .total_bytes > 0')" == "true" ]] || fail "worktree recovery bytes were not measured"
[[ "$(printf '%s' "$report" | jq -r '.stores[] | select(.store_id == "worktree-recovery") | .protected_bytes == .total_bytes')" == "true" ]] || fail "attributed worktree recovery bytes were not protected"
[[ "$(printf '%s' "$report" | jq -r '.stores[] | select(.store_id == "worktree-recovery") | .reclaimable_bytes')" == "0" ]] || fail "worktree recovery inventory granted deletion authority"

home_unset_report=$(env -u HOME -u SUDO_USER -u AIDEVOPS_OPENCODE_DATA_DIR -u AIDEVOPS_OPENCODE_DB_PATH -u OPENCODE_DB_PATH -u OPENCODE_DB -u AIDEVOPS_NPM_CACHE_DIR bash "$HELPER" json)
[[ "$(printf '%s' "$home_unset_report" | jq '.stores | length')" == "16" ]] || fail "HOME-unset inventory did not return every store"
[[ "$(printf '%s' "$home_unset_report" | jq -r '[.stores[] | .error == "home-unavailable"] | all')" == "true" ]] || fail "HOME-unset stores did not fail closed"

report=$(BACKUP_KEEP_COUNT=1 AIDEVOPS_WORKER_EXCERPT_KEEP_COUNT=1 bash "$HELPER" json)
[[ "$(printf '%s' "$report" | jq -r '.stores[] | select(.store_id == "agent-backups") | .reclaimable_bytes > 0')" == "true" ]] || fail "backup dry-run candidates were not reported"
[[ "$(printf '%s' "$report" | jq -r '.stores[] | select(.store_id == "worker-failure-excerpts") | .reclaimable_bytes > 0')" == "true" ]] || fail "worker excerpt dry-run candidates were not reported"
[[ "$(printf '%s' "$report" | jq -r '.stores[] | select(.store_id == "worker-failure-excerpts") | .protected_bytes > 0')" == "true" ]] || fail "newest worker recovery evidence was not protected"

human=$(bash "$HELPER" status)
[[ "$human" == *"Storage Inventory (read-only)"* ]] || fail "human report heading missing"
[[ "$human" == *"No cleanup was performed"* ]] || fail "human report omitted non-destructive guarantee"
[[ "$human" == *"next: Use aidevops opencode-db report"* ]] || fail "human report omitted OpenCode guidance"

mv "$HOME/.aidevops/runtime-bundles" "$HOME/.aidevops/runtime-bundles-real"
ln -s "$HOME/.aidevops/runtime-bundles-real" "$HOME/.aidevops/runtime-bundles"
report=$(bash "$HELPER" json)
[[ "$(printf '%s' "$report" | jq -r '.stores[] | select(.store_id == "runtime-bundles") | .error')" == "root-is-symlink" ]] || fail "symlink root did not fail closed"
[[ "$(printf '%s' "$report" | jq -r '.stores[] | select(.store_id == "runtime-bundles") | .reclaimable_bytes')" == "0" ]] || fail "symlink root became reclaimable"
rm "$HOME/.aidevops/runtime-bundles"
mv "$HOME/.aidevops/runtime-bundles-real" "$HOME/.aidevops/runtime-bundles"

rm -rf "$HOME/.aidevops/runtime-bundles"
mkdir -p \
	"$HOME/.aidevops/runtime-bundles/active/agents" \
	"$HOME/.aidevops/runtime-bundles/cross-user/agents" \
	"$HOME/.aidevops/runtime-bundles/candidate/agents" \
	"$HOME/.aidevops/runtime-bundles/.leases/cross-user"
printf 'active\n' >"$HOME/.aidevops/runtime-bundles/active/agents/data"
dd if=/dev/zero of="$HOME/.aidevops/runtime-bundles/cross-user/agents/data" bs=1024 count=64 2>/dev/null
printf 'candidate\n' >"$HOME/.aidevops/runtime-bundles/candidate/agents/data"
printf 'lease\n' >"$HOME/.aidevops/runtime-bundles/.leases/cross-user/$$"
ln -s "$HOME/.aidevops/runtime-bundles/active/agents" "$HOME/.aidevops/agents"
KILL_EPERM_ENV="$TEST_ROOT/kill-eperm-env"
printf '%s\n' 'kill() { return 1; }' >"$KILL_EPERM_ENV"
report=$(BASH_ENV="$KILL_EPERM_ENV" bash "$HELPER" json)
[[ -n "$report" ]] || fail "ps fallback returned an empty storage report"
printf '%s' "$report" | jq -e '.stores[] | select(.store_id == "runtime-bundles") | .protected_bytes > .reclaimable_bytes' >/dev/null || fail "ps fallback did not protect a cross-user runtime bundle lease"

FAILING_DU="$TEST_ROOT/failing-du"
printf '%s\n' '#!/usr/bin/env bash' 'exit 1' >"$FAILING_DU"
chmod +x "$FAILING_DU"
report=$(AIDEVOPS_STORAGE_DU_COMMAND="$FAILING_DU" bash "$HELPER" json)
[[ "$(printf '%s' "$report" | jq -r '.stores[] | select(.store_id == "runtime-bundles") | .error')" == "sizing-failed" ]] || fail "sizing failure was not visible"
[[ "$(printf '%s' "$report" | jq -r '.stores[] | select(.store_id == "worktree-recovery") | .error')" == "sizing-failed" ]] || fail "worktree recovery sizing failure was not visible"

SLOW_DU="$TEST_ROOT/slow-du"
printf '%s\n' '#!/usr/bin/env bash' 'sleep 5' >"$SLOW_DU"
chmod +x "$SLOW_DU"
report=$(AIDEVOPS_STORAGE_DU_COMMAND="$SLOW_DU" AIDEVOPS_STORAGE_SIZE_TIMEOUT_TENTHS=1 bash "$HELPER" json)
[[ "$(printf '%s' "$report" | jq -r '.stores[] | select(.store_id == "runtime-bundles") | .error')" == "sizing-timeout" ]] || fail "sizing timeout was not fail-closed"

print_warning() {
	local message="$1"
	printf 'WARNING: %s\n' "$message"
	return 0
}
AGENTS_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
export AGENTS_DIR
# shellcheck source=../aidevops-cli/aidevops-status-lib.sh
source "$SCRIPT_DIR/../aidevops-cli/aidevops-status-lib.sh"
status_output=$(AIDEVOPS_STATUS_STORAGE_TIMEOUT_TENTHS=1 _status_storage_inventory)
[[ "$status_output" == *"Storage Inventory (read-only)"* ]] || fail "aidevops status integration omitted storage inventory"

printf 'PASS: storage inventory is read-only, portable, explicit, and fail-closed\n'
exit 0

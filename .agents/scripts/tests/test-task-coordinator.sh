#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
COORDINATOR="${SCRIPT_DIR}/../task-coordinator.mjs"
CLAIM="${SCRIPT_DIR}/../claim-task-id.sh"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT
export AIDEVOPS_TASK_COORDINATOR_DB="${TEST_ROOT}/coordinator.db"

# Multiprocess WAL allocation and offline uniqueness.
for i in $(seq 1 24); do
	node "$COORDINATOR" allocate --operation-id "parallel-${i}" --payload "{\"worker\":${i}}" >"${TEST_ROOT}/parallel-${i}.json" &
done
wait
[[ "$(sqlite3 "$AIDEVOPS_TASK_COORDINATOR_DB" 'SELECT COUNT(DISTINCT task_id) FROM tasks;')" == "24" ]]
[[ "$(sqlite3 "$AIDEVOPS_TASK_COORDINATOR_DB" 'SELECT MAX(sequence) FROM tasks;')" == "24" ]]
[[ "$(sqlite3 "$AIDEVOPS_TASK_COORDINATOR_DB" 'PRAGMA journal_mode;')" == "wal" ]]
[[ "$(stat -f '%Lp' "$AIDEVOPS_TASK_COORDINATOR_DB" 2>/dev/null || stat -c '%a' "$AIDEVOPS_TASK_COORDINATOR_DB")" == "600" ]]

# Concurrent delivery of one operation returns one complete, identical result.
for i in $(seq 1 12); do
	node "$COORDINATOR" allocate --operation-id same-operation --payload '{"same":true}' >"${TEST_ROOT}/same-${i}.json" 2>"${TEST_ROOT}/same-${i}.err" &
done
wait
[[ "$(sqlite3 "$AIDEVOPS_TASK_COORDINATOR_DB" "SELECT COUNT(*) FROM tasks WHERE created_operation_id='same-operation';")" == "1" ]]
same_expected=$(jq -cS . "${TEST_ROOT}/same-1.json")
[[ "$same_expected" != "{}" ]]
for i in $(seq 2 12); do
	[[ "$(jq -cS . "${TEST_ROOT}/same-${i}.json")" == "$same_expected" ]]
done
[[ "$(sqlite3 "$AIDEVOPS_TASK_COORDINATOR_DB" "SELECT status FROM operations WHERE operation_id='same-operation';")" == "terminal" ]]
[[ "$(sqlite3 "$AIDEVOPS_TASK_COORDINATOR_DB" "SELECT result_json FROM operations WHERE operation_id='same-operation';")" != "{}" ]]

# Idempotency and conflict preserve the original immutable task.
first=$(node "$COORDINATOR" allocate --operation-id idem --payload '{"value":1}')
again=$(node "$COORDINATOR" allocate --operation-id idem --payload '{"value":1}')
[[ "$first" == "$again" ]]
if node "$COORDINATOR" allocate --operation-id idem --payload '{"value":2}' >/dev/null 2>&1; then
	printf 'FAIL changed payload reused an operation ID\n' >&2
	exit 1
fi

# Crash before commit leaves no allocation; crash after commit replays the durable result.
before=$(printf '%s' "$first" | jq -r '.tasks[0].sequence')
if AIDEVOPS_TASK_COORDINATOR_TEST_CRASH=before-commit node "$COORDINATOR" allocate --operation-id crash-before >/dev/null 2>&1; then
	printf 'FAIL crash-before hook returned success\n' >&2
	exit 1
fi
[[ "$(sqlite3 "$AIDEVOPS_TASK_COORDINATOR_DB" "SELECT COUNT(*) FROM operations WHERE operation_id='crash-before';")" == "0" ]]
if AIDEVOPS_TASK_COORDINATOR_TEST_CRASH=after-commit node "$COORDINATOR" allocate --operation-id crash-after >/dev/null 2>&1; then
	printf 'FAIL crash-after hook returned success\n' >&2
	exit 1
fi
crash_after=$(node "$COORDINATOR" allocate --operation-id crash-after)
[[ "$(printf '%s' "$crash_after" | jq '.tasks | length')" == "1" ]]
[[ "$(sqlite3 "$AIDEVOPS_TASK_COORDINATOR_DB" "SELECT COUNT(*) FROM tasks WHERE created_operation_id='crash-after';")" == "1" ]]
after=$(node "$COORDINATOR" allocate --operation-id restart --payload '{}' | jq -r '.tasks[0].sequence')
[[ "$after" -gt "$before" ]]
node "$COORDINATOR" verify | jq -e '.ok == true' >/dev/null
node "$COORDINATOR" checkpoint | jq -e '.checkpointed == true and .ok == true' >/dev/null
if AIDEVOPS_TASK_COORDINATOR_TEST_CHECKPOINT_RESULT='1|2|3' node "$COORDINATOR" checkpoint >"${TEST_ROOT}/busy-checkpoint.json"; then
	printf 'FAIL busy WAL checkpoint returned success\n' >&2
	exit 1
fi
jq -e '.checkpointed == false and .ok == false' "${TEST_ROOT}/busy-checkpoint.json" >/dev/null

# Strict identifiers, canonical legacy IDs, JSON object shape, and payload limits.
for invalid_args in \
	"--operation-id ../escape" \
	"--operation-id valid --legacy-id t001" \
	"--operation-id valid-array --payload []"; do
	# shellcheck disable=SC2086
	if node "$COORDINATOR" allocate $invalid_args >/dev/null 2>&1; then
		printf 'FAIL invalid allocation input accepted: %s\n' "$invalid_args" >&2
		exit 1
	fi
done
large_payload=$(printf 'x%.0s' $(seq 1 65536))
if node "$COORDINATOR" allocate --operation-id too-large --payload "{\"value\":\"${large_payload}\"}" >/dev/null 2>&1; then
	printf 'FAIL oversized payload accepted\n' >&2
	exit 1
fi

# Existing legacy TODO identities are adopted atomically and remain bound to
# one immutable repository identity across duplicate and conflicting intake.
legacy_adoption=$(node "$COORDINATOR" adopt-legacy-task --operation-id adopt-28465 --task-id t28465 \
	--repository-id R_adopt --repository-slug owner/adopt --issue-id I_adopt --display-number 28465)
[[ "$(jq -r '.taskId' <<<"$legacy_adoption")" == "t28465" ]]
[[ "$(jq -r '.status' <<<"$legacy_adoption")" == "accepted" ]]
[[ "$(node "$COORDINATOR" adopt-legacy-task --operation-id adopt-28465 --task-id t28465 --repository-id R_adopt --repository-slug owner/adopt --issue-id I_adopt --display-number 28465)" == "$legacy_adoption" ]]
if node "$COORDINATOR" adopt-legacy-task --operation-id adopt-28465 --task-id t28465 --repository-id R_other \
	--repository-slug owner/other --issue-id I_adopt --display-number 28465 >/dev/null 2>&1; then
	printf 'FAIL changed legacy adoption reused an operation ID\n' >&2
	exit 1
fi
if node "$COORDINATOR" adopt-legacy-task --operation-id adopt-cross-repo --task-id t28465 --repository-id R_other \
	--repository-slug owner/other --issue-id I_other --display-number 28465 >/dev/null 2>&1; then
	printf 'FAIL legacy task adoption crossed repository identities\n' >&2
	exit 1
fi
if node "$COORDINATOR" adopt-legacy-task --operation-id adopt-issue-conflict --task-id t28465 --repository-id R_adopt \
	--repository-slug owner/adopt --issue-id I_other --display-number 28466 >/dev/null 2>&1; then
	printf 'FAIL legacy task adoption replaced immutable issue identity\n' >&2
	exit 1
fi
[[ "$(sqlite3 "$AIDEVOPS_TASK_COORDINATOR_DB" "SELECT COUNT(*) FROM tasks WHERE task_id='t28465';")" == "1" ]]
[[ "$(sqlite3 "$AIDEVOPS_TASK_COORDINATOR_DB" "SELECT status FROM operations WHERE operation_id='adopt-cross-repo';")" == "conflict" ]]
[[ "$(sqlite3 "$AIDEVOPS_TASK_COORDINATOR_DB" "SELECT status FROM operations WHERE operation_id='adopt-issue-conflict';")" == "conflict" ]]

# Independent reinstall/clone state creates a new CSPRNG origin at the same sequence.
origin_one=$(node "$COORDINATOR" status | jq -r '.origin_id')
AIDEVOPS_TASK_COORDINATOR_DB="${TEST_ROOT}/clone.db" node "$COORDINATOR" allocate --operation-id clone >/dev/null
origin_two=$(AIDEVOPS_TASK_COORDINATOR_DB="${TEST_ROOT}/clone.db" node "$COORDINATOR" status | jq -r '.origin_id')
[[ "$origin_one" != "$origin_two" ]]

# Publication intent/attempt evidence reaches a durable terminal result.
task_id=$(printf '%s' "$first" | jq -r '.tasks[0].taskId')
intent=$(node "$COORDINATOR" publication-intent --operation-id publish-1 --task-id "$task_id" --payload '{"projection":"issue"}' | jq -r '.intentId')
node "$COORDINATOR" attempt --intent-id "$intent" --status retryable --evidence '{"timeout":true}' >/dev/null
node "$COORDINATOR" attempt --intent-id "$intent" --status published --evidence '{"marker":"verified"}' >/dev/null
[[ "$(sqlite3 "$AIDEVOPS_TASK_COORDINATOR_DB" "SELECT COUNT(*) FROM terminal_evidence WHERE operation_id='publish-1';")" == "1" ]]
[[ "$(node "$COORDINATOR" publication-intent --operation-id publish-1 --task-id "$task_id" --payload '{"projection":"issue"}' | jq -r '.status')" == "published" ]]
[[ "$(sqlite3 "$AIDEVOPS_TASK_COORDINATOR_DB" "SELECT json_extract(result_json,'$.status') FROM operations WHERE operation_id='publish-1';")" == "published" ]]

# Backups are integrity-checked; restore requires a newer fenced ownership epoch.
backup="${TEST_ROOT}/verified-backup.db"
sqlite3 "$AIDEVOPS_TASK_COORDINATOR_DB" ".backup '$backup'"
inode_before=$(stat -f '%i' "$AIDEVOPS_TASK_COORDINATOR_DB" 2>/dev/null || stat -c '%i' "$AIDEVOPS_TASK_COORDINATOR_DB")
fence=$(node "$COORDINATOR" status | jq -r '.fencing_token')
node "$COORDINATOR" transition --state read-only --fencing-token "$fence" --evidence '{"reason":"restore-test"}' >/dev/null
if node "$COORDINATOR" restore --backup "$backup" --registry-evidence '{}' --prior-epoch 1 --new-epoch 1 --fencing-token stale >/dev/null 2>&1; then
	printf 'FAIL stale restore epoch accepted\n' >&2
	exit 1
fi
if node "$COORDINATOR" restore --backup "$backup" --registry-evidence '{"cas":"winner","prior_revoked":true}' --prior-epoch 1 --new-epoch 2 --fencing-token restore-fence >/dev/null 2>&1; then
	printf 'FAIL incomplete registry evidence accepted\n' >&2
	exit 1
fi
node "$COORDINATOR" restore --backup "$backup" --registry-evidence '{"cas":"winner","prior_revoked":true,"fencing_token":"restore-fence","transfer_record_id":"transfer-1"}' --prior-epoch 1 --new-epoch 2 --fencing-token restore-fence --published-high-water 100 >/dev/null
[[ "$(node "$COORDINATOR" status | jq -r '.sequence')" == "100" ]]
inode_after=$(stat -f '%i' "$AIDEVOPS_TASK_COORDINATOR_DB" 2>/dev/null || stat -c '%i' "$AIDEVOPS_TASK_COORDINATOR_DB")
[[ "$inode_after" == "$inode_before" ]]
[[ -n "$(ls "${TEST_ROOT}"/coordinator.db-backup-*-pre-restore.db)" ]]

# A real v1 schema migrates through every version only after verified backups.
migration_db="${TEST_ROOT}/migration.db"
AIDEVOPS_TASK_COORDINATOR_DB="$migration_db" node "$COORDINATOR" status >/dev/null
sqlite3 "$migration_db" "DROP TABLE legacy_task_adoptions; DROP TABLE issue_mappings; DROP TABLE forge_event_cursors; ALTER TABLE restore_controls DROP COLUMN backup_high_water; UPDATE coordinator_meta SET value='1' WHERE key='schema_version'; DELETE FROM migration_history; INSERT INTO migration_history VALUES(1,'2026-01-01T00:00:00Z',NULL,'ok');"
AIDEVOPS_TASK_COORDINATOR_DB="$migration_db" node "$COORDINATOR" status >/dev/null
[[ "$(sqlite3 "$migration_db" "SELECT value FROM coordinator_meta WHERE key='schema_version';")" == "7" ]]
[[ "$(sqlite3 "$migration_db" "SELECT COUNT(*) FROM pragma_table_info('operations') WHERE name='result_hash';")" == "0" ]]
[[ -n "$(ls "${TEST_ROOT}"/migration.db-backup-*-pre-migrate-v2.db)" ]]
[[ -n "$(ls "${TEST_ROOT}"/migration.db-backup-*-pre-migrate-v3.db)" ]]

# An untouched v2 database is backed up before any v3 table is applied.
v2_db="${TEST_ROOT}/v2.db"
AIDEVOPS_TASK_COORDINATOR_DB="$v2_db" node "$COORDINATOR" status >/dev/null
sqlite3 "$v2_db" "DROP TABLE legacy_task_adoptions; DROP TABLE issue_mappings; DROP TABLE forge_event_cursors; ALTER TABLE operations ADD COLUMN result_hash TEXT NOT NULL DEFAULT 'unchecked'; UPDATE coordinator_meta SET value='2' WHERE key='schema_version'; DELETE FROM migration_history WHERE version>2; INSERT OR IGNORE INTO migration_history VALUES(2,'2026-01-01T00:00:00Z',NULL,'ok');"
AIDEVOPS_TASK_COORDINATOR_DB="$v2_db" node "$COORDINATOR" status >/dev/null
v2_backup=$(ls "${TEST_ROOT}"/v2.db-backup-*-pre-migrate-v3.db)
[[ "$(sqlite3 "$v2_backup" "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='issue_mappings';")" == "0" ]]
[[ "$(sqlite3 "$v2_db" "SELECT value FROM coordinator_meta WHERE key='schema_version';")" == "7" ]]

# Immutable task/repository identities isolate equal display numbers and allow
# one task to retain home, implementation, and upstream issue projections.
mapping_task=$(node "$COORDINATOR" allocate --operation-id mapping-task --payload '{}' | jq -r '.tasks[0].taskId')
node "$COORDINATOR" bind-issue --task-id "$mapping_task" --repository-id R_home --repository-slug owner/home \
	--role home --issue-id I_home --project-id P_home --display-number 42 --state-cursor 2026-07-12T06:00:00-04:00 \
	--sync-metadata '{"state":"OPEN","source":"backfill"}' >/dev/null
node "$COORDINATOR" bind-issue --task-id "$mapping_task" --repository-id R_impl --repository-slug owner/implementation \
	--role implementation --issue-id I_impl --display-number 42 --sync-metadata '{"state":"OPEN"}' >/dev/null
node "$COORDINATOR" bind-issue --task-id "$mapping_task" --repository-id R_upstream --repository-slug upstream/project \
	--role upstream --issue-id I_upstream --display-number 42 >/dev/null
[[ "$(node "$COORDINATOR" resolve-issue --task-id "$mapping_task" --repository-id R_home | jq -r '.issueId')" == "I_home" ]]
[[ "$(node "$COORDINATOR" resolve-issue --task-id "$mapping_task" --repository-id R_impl | jq -r '.issueId')" == "I_impl" ]]
[[ "$(sqlite3 "$AIDEVOPS_TASK_COORDINATOR_DB" "SELECT COUNT(*) FROM issue_mappings WHERE task_id='${mapping_task}';")" == "3" ]]
[[ "$(node "$COORDINATOR" resolve-issue --task-id "$mapping_task" --repository-id R_home | jq -r '.stateCursor')" == "2026-07-12T10:00:00.000Z" ]]

# A renamed slug updates display metadata without changing repository identity;
# conflicting issue identity or an unvalidated repository fails closed.
node "$COORDINATOR" bind-issue --task-id "$mapping_task" --repository-id R_home --repository-slug renamed/home \
	--role home --issue-id I_home --display-number 42 --state-cursor 2026-07-12T10:00:00Z \
	--sync-metadata '{"state":"OPEN","source":"backfill"}' >/dev/null
[[ "$(node "$COORDINATOR" resolve-issue --task-id "$mapping_task" --repository-id R_home | jq -r '.repositorySlug')" == "renamed/home" ]]
if node "$COORDINATOR" bind-issue --task-id "$mapping_task" --repository-id R_home --repository-slug renamed/home \
	--role home --issue-id I_conflict --display-number 42 >/dev/null 2>&1; then
	printf 'FAIL conflicting issue mapping was accepted\n' >&2
	exit 1
fi

# Dotted legacy task identities bind and resolve through the same codec.
node "$COORDINATOR" bind-issue --task-id t1873.1 --repository-id R_dotted --repository-slug owner/dotted \
	--role home --issue-id I_dotted --display-number 73 --state-cursor 2026-07-12T10:00:00Z >/dev/null
[[ "$(node "$COORDINATOR" resolve-issue --task-id t1873.1 --repository-id R_dotted | jq -r '.displayNumber')" == "73" ]]

# State cursors are monotonic. Newer state advances, equal state is idempotent,
# and stale or cursor-dropping updates cannot regress synchronization metadata.
node "$COORDINATOR" bind-issue --task-id "$mapping_task" --repository-id R_home --repository-slug renamed/home \
	--role home --issue-id I_home --display-number 42 --state-cursor 2026-07-12T11:00:00Z \
	--sync-metadata '{"state":"CLOSED","source":"webhook"}' >/dev/null
node "$COORDINATOR" bind-issue --task-id "$mapping_task" --repository-id R_home --repository-slug renamed/home \
	--role home --issue-id I_home --display-number 42 --state-cursor 2026-07-12T11:00:00Z \
	--sync-metadata '{"state":"CLOSED","source":"webhook"}' >/dev/null
if node "$COORDINATOR" bind-issue --task-id "$mapping_task" --repository-id R_home --repository-slug renamed/home \
	--role home --issue-id I_home --display-number 42 --state-cursor 2026-07-12T10:30:00Z \
	--sync-metadata '{"state":"OPEN"}' >/dev/null 2>&1; then
	printf 'FAIL stale synchronization metadata was accepted\n' >&2
	exit 1
fi
if node "$COORDINATOR" bind-issue --task-id "$mapping_task" --repository-id R_home --repository-slug renamed/home \
	--role home --issue-id I_home --display-number 42 --sync-metadata '{"state":"OPEN"}' >/dev/null 2>&1; then
	printf 'FAIL synchronization cursor regression was accepted\n' >&2
	exit 1
fi
[[ "$(node "$COORDINATOR" resolve-issue --task-id "$mapping_task" --repository-id R_home | jq -r '.syncMetadata.state')" == "CLOSED" ]]

# Forge deliveries resolve by immutable repository and subject identities only,
# advance one mapped task, and route its projection through the durable outbox.
forge_first=$(node "$COORDINATOR" forge-event --operation-id delivery-1 --repository-id R_home \
	--delivery-id delivery-1 --cursor-tiebreaker run-10 --repository-slug renamed/home --repository-path "$TEST_ROOT" \
	--event-kind issue --action reopened --subject-id I_home --cursor 2026-07-12T12:00:00Z)
[[ "$(printf '%s' "$forge_first" | jq -r '.taskId')" == "$mapping_task" ]]
[[ "$(printf '%s' "$forge_first" | jq -r '.status')" == "accepted" ]]
[[ "$(printf '%s' "$forge_first" | jq -r '.transitionKind')" == "task.available" ]]
[[ "$(sqlite3 "$AIDEVOPS_TASK_COORDINATOR_DB" "SELECT COUNT(*) FROM publication_intents WHERE operation_id='delivery-1';")" == "1" ]]
[[ "$(sqlite3 "$AIDEVOPS_TASK_COORDINATOR_DB" "SELECT COUNT(*) FROM publication_queue q JOIN publication_intents i USING(intent_id) WHERE i.operation_id='delivery-1';")" == "1" ]]
[[ "$(node "$COORDINATOR" forge-event --operation-id delivery-1 --delivery-id delivery-1 --cursor-tiebreaker run-10 --repository-id R_home --repository-slug renamed/home --repository-path "$TEST_ROOT" --event-kind issue --action reopened --subject-id I_home --cursor 2026-07-12T12:00:00Z)" == "$forge_first" ]]
stale_forge=$(node "$COORDINATOR" forge-event --operation-id delivery-stale --repository-id R_home \
	--delivery-id delivery-stale --cursor-tiebreaker run-11 --repository-slug attacker/ignored --event-kind issue --action closed --subject-id I_home --cursor 2026-07-12T11:30:00Z)
[[ "$(printf '%s' "$stale_forge" | jq -r '.status')" == "stale" ]]
[[ "$(node "$COORDINATOR" resolve-issue --task-id "$mapping_task" --repository-id R_home | jq -r '.repositorySlug')" == "renamed/home" ]]
unmapped_forge=$(node "$COORDINATOR" forge-event --operation-id delivery-unmapped --repository-id R_home \
	--delivery-id delivery-unmapped --cursor-tiebreaker run-12 --repository-slug attacker/ignored --event-kind pull_request --action merged --subject-id I_unmapped --cursor 2026-07-12T13:00:00Z)
[[ "$(printf '%s' "$unmapped_forge" | jq -r '.status')" == "unmapped" ]]
[[ "$(sqlite3 "$AIDEVOPS_TASK_COORDINATOR_DB" "SELECT COUNT(*) FROM publication_intents WHERE operation_id IN ('delivery-stale','delivery-unmapped');")" == "0" ]]

# Legacy/restored state can contain an issue mapping whose task projection is
# absent. Such mappings are deterministically unmapped, never published, and
# excluded from reconciliation without aborting the forge-event transaction.
sqlite3 "$AIDEVOPS_TASK_COORDINATOR_DB" "INSERT INTO issue_mappings(task_id,forge,repository_id,repository_slug,role,issue_id,display_number,created_at,updated_at) VALUES ('t27856','github','R_home','renamed/home','home','I_orphan',56,'2026-07-12T12:30:00.000Z','2026-07-12T12:30:00.000Z');"
orphan_targets=$(node "$COORDINATOR" reconciliation-targets --repository-id R_home)
[[ "$(printf '%s' "$orphan_targets" | jq '[.targets[] | select(.taskId == "t27856")] | length')" == "0" ]]
orphan_forge=$(node "$COORDINATOR" forge-event --operation-id delivery-orphan --repository-id R_home \
	--delivery-id delivery-orphan --cursor-tiebreaker run-13 --repository-slug renamed/home --repository-path "$TEST_ROOT" \
	--event-kind issue --action closed --subject-id I_orphan --cursor 2026-07-12T13:30:00Z)
[[ "$(printf '%s' "$orphan_forge" | jq -r '.status')" == "unmapped" ]]
[[ "$(printf '%s' "$orphan_forge" | jq -r '.taskId')" == "null" ]]
[[ "$(sqlite3 "$AIDEVOPS_TASK_COORDINATOR_DB" "SELECT COUNT(*) FROM publication_intents WHERE operation_id='delivery-orphan';")" == "0" ]]
[[ "$(sqlite3 "$AIDEVOPS_TASK_COORDINATOR_DB" "SELECT COUNT(*) FROM forge_event_cursors WHERE subject_id='I_orphan';")" == "0" ]]
[[ "$(sqlite3 "$AIDEVOPS_TASK_COORDINATOR_DB" "SELECT COUNT(*) FROM terminal_evidence WHERE operation_id='delivery-orphan' AND result_state='terminal';")" == "1" ]]
[[ "$(node "$COORDINATOR" forge-event --operation-id delivery-orphan --repository-id R_home --delivery-id delivery-orphan --cursor-tiebreaker run-13 --repository-slug renamed/home --repository-path "$TEST_ROOT" --event-kind issue --action closed --subject-id I_orphan --cursor 2026-07-12T13:30:00Z)" == "$orphan_forge" ]]
[[ "$(sqlite3 "$AIDEVOPS_TASK_COORDINATOR_DB" "SELECT COUNT(*) FROM operations WHERE operation_id='delivery-orphan'; SELECT COUNT(*) FROM terminal_evidence WHERE operation_id='delivery-orphan';")" == $'1\n1' ]]

# Equal timestamps are ordered by delivery/run identity rather than silently lost.
equal_forge=$(node "$COORDINATOR" forge-event --operation-id delivery-equal --delivery-id delivery-equal \
	--cursor-tiebreaker run-20 --repository-id R_home --repository-slug renamed/home --repository-path "$TEST_ROOT" \
	--event-kind issue --action closed --subject-id I_home --cursor 2026-07-12T12:00:00Z)
[[ "$(printf '%s' "$equal_forge" | jq -r '.status')" == "accepted" ]]
[[ "$(printf '%s' "$equal_forge" | jq -r '.transitionKind')" == "task.completed" ]]
conflict_forge=$(node "$COORDINATOR" forge-event --operation-id delivery-conflict --delivery-id delivery-conflict \
	--cursor-tiebreaker run-20 --repository-id R_home --repository-slug renamed/home \
	--event-kind issue --action edited --subject-id I_home --cursor 2026-07-12T12:00:00Z)
[[ "$(printf '%s' "$conflict_forge" | jq -r '.status')" == "conflict" ]]

# Pushes use trusted repository semantics and never attempt SHA-to-issue mapping.
push_forge=$(node "$COORDINATOR" forge-event --operation-id delivery-push --delivery-id delivery-push \
	--cursor-tiebreaker run-30 --repository-id R_home --repository-slug renamed/home \
	--event-kind push --action pushed --subject-id aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa --cursor 2026-07-12T10:00:00-04:00)
[[ "$(printf '%s' "$push_forge" | jq -r '.mappingMode')" == "trusted-repository" ]]
[[ "$(printf '%s' "$push_forge" | jq -r '.taskId')" == "null" ]]
[[ "$(sqlite3 "$AIDEVOPS_TASK_COORDINATOR_DB" "SELECT cursor_timestamp FROM forge_event_cursors WHERE repository_id='R_home' AND subject_kind='push';")" == "2026-07-12T14:00:00.000Z" ]]
[[ "$(node "$COORDINATOR" forge-event --operation-id delivery-push --delivery-id delivery-push --cursor-tiebreaker run-30 --repository-id R_home --repository-slug renamed/home --event-kind push --action pushed --subject-id aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa --cursor 2026-07-12T14:00:00Z)" == "$push_forge" ]]

# Manual events share the same canonical cursor boundary, while malformed dates
# fail before an operation or cursor can be persisted.
manual_forge=$(node "$COORDINATOR" forge-event --operation-id delivery-manual --delivery-id delivery-manual \
	--cursor-tiebreaker run-31 --repository-id R_home --repository-slug renamed/home --task-id "$mapping_task" \
	--event-kind manual --action requested --subject-id I_home --cursor 2026-07-12T15:00:00+01:00)
[[ "$(printf '%s' "$manual_forge" | jq -r '.mappingMode')" == "explicit-task" ]]
[[ "$(sqlite3 "$AIDEVOPS_TASK_COORDINATOR_DB" "SELECT cursor_timestamp FROM forge_event_cursors WHERE repository_id='R_home' AND subject_kind='manual';")" == "2026-07-12T14:00:00.000Z" ]]
invalid_cursor_error="${TEST_ROOT}/invalid-cursor-error"
if node "$COORDINATOR" forge-event --operation-id delivery-invalid --delivery-id delivery-invalid \
	--cursor-tiebreaker run-32 --repository-id R_home --repository-slug renamed/home \
	--event-kind push --action pushed --subject-id bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
	--cursor 2026-02-30T12:00:00Z >/dev/null 2>"$invalid_cursor_error"; then
	printf 'FAIL invalid RFC3339 cursor was accepted\n' >&2
	exit 1
fi
grep -q 'cursor must be a valid RFC3339 timestamp' "$invalid_cursor_error"
[[ "$(sqlite3 "$AIDEVOPS_TASK_COORDINATOR_DB" "SELECT COUNT(*) FROM operations WHERE operation_id='delivery-invalid';")" == "0" ]]

# Repository identity isolates otherwise identical subjects and cursors.
other_repo=$(node "$COORDINATOR" forge-event --operation-id delivery-other-repo --delivery-id delivery-other-repo \
	--cursor-tiebreaker run-10 --repository-id R_other --repository-slug owner/other \
	--event-kind issue --action opened --subject-id I_home --cursor 2026-07-12T12:00:00Z)
[[ "$(printf '%s' "$other_repo" | jq -r '.status')" == "unmapped" ]]

# A fresh process observes the same durable cursor and outbox after restart.
node "$COORDINATOR" status >/dev/null
[[ "$(sqlite3 "$AIDEVOPS_TASK_COORDINATOR_DB" "SELECT transition_kind FROM forge_event_cursors WHERE repository_id='R_home' AND subject_kind='issue' AND subject_id='I_home';")" == "task.completed" ]]

# Concurrent conflicting first binds are serialized in SQLite: exactly one
# identity wins and every competing identity fails without overwriting it.
for i in $(seq 1 12); do
	(
		if node "$COORDINATOR" bind-issue --task-id t1999.1 --repository-id R_race --repository-slug owner/race \
			--role home --issue-id "I_race_${i}" --display-number "$i" --state-cursor 2026-07-12T12:00:00Z >/dev/null 2>&1; then
			printf '0\n' >"${TEST_ROOT}/race-${i}.rc"
		else
			printf '1\n' >"${TEST_ROOT}/race-${i}.rc"
		fi
	) &
done
wait
[[ "$(grep -hxc '0' "${TEST_ROOT}"/race-*.rc | awk '{s+=$1} END {print s}')" == "1" ]]
[[ "$(sqlite3 "$AIDEVOPS_TASK_COORDINATOR_DB" "SELECT COUNT(*) FROM issue_mappings WHERE task_id='t1999.1' AND repository_id='R_race';")" == "1" ]]
if node "$COORDINATOR" resolve-issue --task-id "$mapping_task" --repository-id R_missing >/dev/null 2>&1; then
	printf 'FAIL missing repository mapping resolved\n' >&2
	exit 1
fi

# Integration defaults to legacy, shadow is additive, and emission needs two gates.
if AIDEVOPS_TASK_COORDINATOR_MODE=namespaced bash "$CLAIM" --no-issue --title test >/dev/null 2>&1; then
	printf 'FAIL namespaced emission worked without explicit emission gate\n' >&2
	exit 1
fi
repo_fixture="${TEST_ROOT}/repo-fixture"
mkdir "$repo_fixture"
printf 'unchanged\n' >"${repo_fixture}/sentinel"
before_fixture=$(cksum "${repo_fixture}/sentinel")
dry_count=$(sqlite3 "$AIDEVOPS_TASK_COORDINATOR_DB" 'SELECT COUNT(*) FROM tasks;')
AIDEVOPS_TASK_COORDINATOR_MODE=namespaced AIDEVOPS_TASK_COORDINATOR_NAMESPACED_EMISSION_ENABLED=1 \
	bash "$CLAIM" --no-issue --dry-run --title test --repo-path "$repo_fixture" | grep -q '^task_id=tDRY_RUN$'
[[ "$(sqlite3 "$AIDEVOPS_TASK_COORDINATOR_DB" 'SELECT COUNT(*) FROM tasks;')" == "$dry_count" ]]
namespaced=$(AIDEVOPS_TASK_COORDINATOR_MODE=namespaced AIDEVOPS_TASK_COORDINATOR_NAMESPACED_EMISSION_ENABLED=1 \
	bash "$CLAIM" --no-issue --count 3 --title test --repo-path "$repo_fixture")
printf '%s' "$namespaced" | grep -Eq '^task_id=to[0-7][0-9a-hjkmnp-tv-z]{25}-[1-9][0-9]*$'
printf '%s' "$namespaced" | grep -Eq '^task_id_last=to[0-7][0-9a-hjkmnp-tv-z]{25}-[1-9][0-9]*$'
printf '%s' "$namespaced" | grep -q '^task_count=3$'
[[ "$(cksum "${repo_fixture}/sentinel")" == "$before_fixture" ]]
[[ "$(sqlite3 "$AIDEVOPS_TASK_COORDINATOR_DB" "SELECT value FROM coordinator_meta WHERE key='namespaced_emitted';")" == "1" ]]

# Shadow mode records the legacy identity but never replaces CAS output.
(
	SCRIPT_DIR="${SCRIPT_DIR}/.."
	log_info() {
		:
		return 0
	}
	log_warn() {
		:
		return 0
	}
	log_error() {
		:
		return 0
	}
	# shellcheck source=../claim-task-id-counter.sh
	source "${SCRIPT_DIR}/claim-task-id-counter.sh"
	AIDEVOPS_TASK_COORDINATOR_MODE=shadow AIDEVOPS_TASK_COORDINATOR_SHADOW_ENABLED=1 _task_coordinator_shadow_legacy 321 1
)
[[ "$(sqlite3 "$AIDEVOPS_TASK_COORDINATOR_DB" "SELECT COUNT(*) FROM tasks WHERE task_id='t321';")" == "1" ]]

printf 'PASS task coordinator allocation, replay, recovery, restore, and integration gates\n'

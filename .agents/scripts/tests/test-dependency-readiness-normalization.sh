#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Regression coverage for t18100 dependency readiness normalization.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TMP_ROOT"' EXIT
LOGFILE="${TMP_ROOT}/test.log"
: >"$LOGFILE"

pass=0
fail=0

assert_eq() {
	local label="$1"
	local expected="$2"
	local actual="$3"
	if [[ "$expected" == "$actual" ]]; then
		printf 'PASS: %s\n' "$label"
		pass=$((pass + 1))
	else
		printf 'FAIL: %s (expected=%q actual=%q)\n' "$label" "$expected" "$actual" >&2
		fail=$((fail + 1))
	fi
	return 0
}

assert_true() {
	local label="$1"
	shift
	if "$@"; then
		printf 'PASS: %s\n' "$label"
		pass=$((pass + 1))
	else
		printf 'FAIL: %s\n' "$label" >&2
		fail=$((fail + 1))
	fi
	return 0
}

# shellcheck disable=SC1090
source "${SCRIPTS_DIR}/pulse-dep-graph.sh"

_test_dep_identity_api() {
	local endpoint="$1"
	case "$endpoint" in
	repos/owner/repo) printf 'R_owner_repo\n' ;;
	repos/owner/repo/issues/20) printf '20\tI_20\n' ;;
	*) return 1 ;;
	esac
	return 0
}

_test_render_args() {
	local rendered=""
	local arg=""
	for arg in "$@"; do
		[[ -z "$rendered" ]] || rendered="${rendered} "
		rendered="${rendered}${arg}"
	done
	printf '%s' "$rendered"
	return 0
}

acc='{"open_nums":[],"closed_nums":[],"known_nums":[],"task_to_issue":{},"blocked_by_map":{},"defer_flags_map":{}}'
# shellcheck disable=SC2016  # Markdown backticks are literal fixture content.
issue='{"number":20,"title":"t20: roadmap child","state":"OPEN","body":"**Blocked by:** `t20`, #20, #10","labels":[]}'
parsed=$(_dep_graph_process_issue_json "$issue" "$acc")
assert_eq "self task reference ignored" '[]' "$(printf '%s' "$parsed" | jq -c '.blocked_by_map["20"].task_ids')"
assert_eq "self issue reference ignored" '["10"]' "$(printf '%s' "$parsed" | jq -c '.blocked_by_map["20"].issue_nums')"

entry='{"task_ids":["t10"],"issue_nums":["11"]}'
assert_true "closed roadmap predecessors resolve" \
	_refresh_all_blockers_resolved "$entry" '{"t10":10}' '[10,11]' '[10,11,20]'
if _refresh_all_blockers_resolved "$entry" '{"t10":10}' '[10]' '[10,20]'; then
	assert_eq "missing issue fails closed" "blocked" "resolved"
else
	assert_eq "missing issue fails closed" "blocked" "blocked"
fi
if _refresh_all_blockers_resolved '{"task_ids":["t404"],"issue_nums":[]}' '{}' '[]' '[20]'; then
	assert_eq "missing task fails closed" "blocked" "resolved"
else
	assert_eq "missing task fails closed" "blocked" "blocked"
fi

ISSUE_STATUS_LABEL_PRECEDENCE=("done" "in-review" "in-progress" "queued" "claimed" "available" "blocked")
ISSUE_TIER_LABEL_RANK=(reasoning standard simple)
# shellcheck disable=SC1090
source "${SCRIPTS_DIR}/pulse-issue-reconcile-normalize.sh"
assert_eq "blocked wins inconsistent available pair" "blocked" "$(_pick_status_survivor available blocked)"
assert_eq "active lifecycle wins blocked available conflict" "in-review" "$(_pick_status_survivor available blocked in-review)"

status_write=""
current_status="status:available"
gh() {
	local command="$1"
	local target="${2:-}"
	if [[ "$command" == "api" ]]; then
		_test_dep_identity_api "$target"
		return $?
	elif [[ "$command $target" == "issue view" ]]; then
		printf '%s\n' "$current_status"
	elif [[ "$command $target" == "issue edit" ]]; then
		status_write=$(_test_render_args "$@")
		current_status="status:blocked"
	fi
	return 0
}
export -f gh
_refresh_ensure_unresolved_is_blocked "owner/repo" "20"
assert_eq "available issue normalized blocked" "issue edit 20 --repo owner/repo --remove-label status:available --add-label status:blocked" "$status_write"

status_write=""
current_status="status:available,status:queued"
gh() {
	local command="$1"
	local target="${2:-}"
	if [[ "$command" == "api" ]]; then
		_test_dep_identity_api "$target"
		return $?
	elif [[ "$command $target" == "issue view" ]]; then
		printf '%s\n' "$current_status"
	fi
	return 0
}
export -f gh
_refresh_ensure_unresolved_is_blocked "owner/repo" "20" || true
assert_eq "concurrent queued transition is preserved" "" "$status_write"

status_write=""
view_counter_file="${TMP_ROOT}/view-count"
printf '0\n' >"$view_counter_file"
gh() {
	local command="$1"
	local target="${2:-}"
	if [[ "$command" == "api" ]]; then
		_test_dep_identity_api "$target"
		return $?
	elif [[ "$command $target" == "issue view" ]]; then
		local view_count=""
		view_count=$(<"$view_counter_file")
		view_count=$((view_count + 1))
		printf '%s\n' "$view_count" >"$view_counter_file"
		if [[ "$view_count" -eq 1 ]]; then
			printf 'status:available\n'
		else
			printf 'status:queued,status:blocked\n'
		fi
	elif [[ "$command $target" == "issue edit" ]]; then
		status_write="${status_write}$(_test_render_args "$@")"$'\n'
	fi
	return 0
}
export -f gh
_refresh_ensure_unresolved_is_blocked "owner/repo" "20" || true
assert_true "post-read removes blocked after concurrent queue transition" \
	grep -Fq -- "--remove-label status:blocked" <<<"$status_write"

log_verbose() {
	return 0
}
_gh_with_timeout() {
	local mode="$1"
	shift
	[[ "$mode" == "read" || "$mode" == "write" ]] || return 1
	if "$@"; then
		return 0
	fi
	return 1
}
gh() {
	[[ "${AIDEVOPS_GH_GRAPHQL_COST_FROM_RESPONSE:-}" == "1" && "$*" == *"rateLimit"* ]] || return 1
	printf '%s\n' '{"data":{"node":{"blockedBy":{"nodes":[{"id":"I_blocker"}],"pageInfo":{"hasNextPage":false}}},"rateLimit":{"cost":1}}}'
	return 0
}
export -f gh log_verbose _gh_with_timeout
# shellcheck disable=SC1090
source "${SCRIPTS_DIR}/issue-sync-lib-parse.sh"
# shellcheck disable=SC1090
source "${SCRIPTS_DIR}/issue-sync-lib-ref.sh"
# shellcheck disable=SC1090
source "${SCRIPTS_DIR}/issue-sync-relationships.sh"
assert_true "existing native relationship pre-read is idempotent" _gh_add_blocked_by "I_blocked" "I_blocker"

dependency_status="status:available,auto-dispatch"
dependency_status_writes=""
gh() {
	local command="$1"
	local target="${2:-}"
	if [[ "$command $target" == "issue view" ]]; then
		printf '%s\n' "$dependency_status"
	elif [[ "$command $target" == "issue edit" ]]; then
		dependency_status_writes="${dependency_status_writes}$(_test_render_args "$@")"$'\n'
		dependency_status="status:blocked,auto-dispatch"
	fi
	return 0
}
export -f gh
assert_true "linked dependency moves available issue to blocked" \
	_ensure_dependency_status_blocked "20" "owner/repo" "native_relationship_linked"
assert_true "dependency status edit preserves auto-dispatch" \
	grep -Fq -- "issue edit 20 --repo owner/repo --remove-label status:available --add-label status:blocked" \
	<<<"$dependency_status_writes"
assert_eq "auto-dispatch remains attached after dependency status edit" \
	"status:blocked,auto-dispatch" "$dependency_status"

dependency_status="status:available,status:in-progress,auto-dispatch"
dependency_status_writes=""
assert_true "active dependency lifecycle is left unchanged" \
	_ensure_dependency_status_blocked "20" "owner/repo" "native_relationship_linked"
assert_eq "active dependency lifecycle receives no status write" "" "$dependency_status_writes"

_run_relationship_status_sync_cases() (
	local dependency_status="status:available,auto-dispatch"
	local dependency_status_writes=""
	local cross_phase_rc=0

	_relationship_deadline_expired() {
		return 1
	}
	resolve_task_gh_number() {
		local task_id="$1"
		case "$task_id" in
		t10) printf '10\n' ;;
		t20) printf '20\n' ;;
		*) return 1 ;;
		esac
		return 0
	}
	_relationship_edge_should_attempt() {
		return 0
	}
	_cached_node_id() {
		local issue_num="$1"
		printf 'I_%s\n' "$issue_num"
		return 0
	}
	_dependency_cycle_should_skip_edge() {
		return 1
	}
	_gh_add_blocked_by() {
		return 0
	}
	_relationship_record_outcome() {
		return 0
	}
	gh() {
		local command="$1"
		local target="${2:-}"
		if [[ "$command $target" == "issue view" ]]; then
			printf '%s\n' "$dependency_status"
		elif [[ "$command $target" == "issue edit" ]]; then
			dependency_status_writes="${dependency_status_writes}$(_test_render_args "$@")"$'\n'
			dependency_status="status:blocked,auto-dispatch"
		fi
		return 0
	}
	DRY_RUN="false"

	_sync_declared_blocked_by_edges "t20" "/dev/null" "owner/repo" "20" "I_20" "t10" \
		>"${TMP_ROOT}/direct-blocked-by.out"
	printf '%s' "$dependency_status_writes" >"${TMP_ROOT}/direct-blocked-by-writes.out"

	dependency_status="status:available,auto-dispatch"
	dependency_status_writes=""
	_sync_declared_blocks_edges "t10" "/dev/null" "owner/repo" "10" "I_10" "t20" \
		>"${TMP_ROOT}/inverse-blocks.out"
	printf '%s' "$dependency_status_writes" >"${TMP_ROOT}/inverse-blocks-writes.out"

	dependency_status="status:available,auto-dispatch"
	dependency_status_writes=""
	_backfill_cross_phase_pair "20" "10" "I_20" "I_10" "owner/repo" || cross_phase_rc=$?
	printf '%s' "$dependency_status_writes" >"${TMP_ROOT}/cross-phase-writes.out"
	return "$cross_phase_rc"
)

relationship_sync_rc=0
_run_relationship_status_sync_cases || relationship_sync_rc=$?
assert_true "direct blocked-by sync normalizes the dependent issue" \
	grep -Fq -- "issue edit 20 --repo owner/repo --remove-label status:available --add-label status:blocked" \
	"${TMP_ROOT}/direct-blocked-by-writes.out"
assert_true "inverse blocks sync normalizes the dependent issue" \
	grep -Fq -- "issue edit 20 --repo owner/repo --remove-label status:available --add-label status:blocked" \
	"${TMP_ROOT}/inverse-blocks-writes.out"
assert_eq "cross-phase sync succeeds" "0" "$relationship_sync_rc"
assert_true "cross-phase sync normalizes the dependent issue" \
	grep -Fq -- "issue edit 20 --repo owner/repo --remove-label status:available --add-label status:blocked" \
	"${TMP_ROOT}/cross-phase-writes.out"

gh() {
	if [[ "$*" == *"query("* ]]; then
		printf '%s\n' '{"data":{"node":{"blockedBy":{"nodes":[{"id":"I_blocker"}],"pageInfo":{"hasNextPage":false}}},"rateLimit":{"cost":1}}}'
	else
		printf '%s\n' '{"data":{"removeBlockedBy":{"issue":{"number":10}},"rateLimit":{"cost":1}}}'
	fi
	return 0
}
export -f gh
assert_true "existing circular native edge is removed" _gh_remove_blocked_by "I_blocked" "I_blocker"

cycle_todo="${TMP_ROOT}/cycle-todo.md"
printf '%s\n' '- [ ] t10 first blocked-by:t20 ref:GH#10' '- [ ] t20 second blocked-by:t10 ref:GH#20' >"$cycle_todo"
assert_true "ascending circular native edge is skipped" \
	_dependency_cycle_should_skip_edge "t10" "t20" "10" "20" "$cycle_todo"

gh() {
	return 1
}
export -f gh
if _hold_dependency_sync_retry "20" "owner/repo" "test"; then
	assert_eq "failed status read propagates retry" "failure" "success"
else
	assert_eq "failed status read propagates retry" "failure" "failure"
fi

cycle_graph='{"open_issues":[10,20],"closed_issues":[],"known_issues":[10,20],"task_to_issue":{"10":10,"20":20},"blocked_by":{"10":{"task_ids":[],"issue_nums":["20"]},"20":{"task_ids":[],"issue_nums":["10"]}}}'
pruned_graph=$(_dep_graph_prune_circular_edges "$cycle_graph")
assert_eq "cycle pruning keeps one dependency direction" '[]' \
	"$(printf '%s' "$pruned_graph" | jq -c '.blocked_by["10"].issue_nums')"

gh_issue_list() {
	printf '%s\n' '[{"number":10,"title":"t10: first","state":"OPEN","body":"Blocked by #20","labels":[]},{"number":20,"title":"t20: second","state":"OPEN","body":"Blocked by #10","labels":[]}]'
	return 0
}
export -f gh_issue_list
built_graph=$(_dep_graph_build_repo_data "owner/repo")
assert_eq "repo graph build prunes circular dependency" '[]' \
	"$(printf '%s' "$built_graph" | jq -c '.blocked_by["10"].issue_nums')"

if (
	unset DEP_GRAPH_CACHE_FILE
	_dep_graph_build_repo_data() {
		printf '%s\n' '{"open_issues":[],"task_to_issue":{},"blocked_by":{},"defer_flags":{}}'
		return 0
	}
	refresh_blocked_status_from_graph() {
		return 0
	}
	normalize_repo_dependency_readiness "owner/repo"
); then
	assert_eq "repo normalization tolerates unset cache path" "safe" "safe"
else
	assert_eq "repo normalization tolerates unset cache path" "safe" "failed"
fi

home_result=$(
	unset HOME
	if normalize_repo_dependency_readiness_if_due "owner/repo"; then
		printf '0'
	else
		printf '%s' "$?"
	fi
)
assert_eq "repo normalization fails safely without HOME" "1" "$home_result"

# The shared candidate selector must recover an all-blocked roadmap even when
# called directly by a workers sweep without the full pulse preflight.
# shellcheck disable=SC1090
source "${SCRIPTS_DIR}/pulse-repo-meta.sh"
candidate_fetch_file="${TMP_ROOT}/candidate-fetch-count"
normalization_file="${TMP_ROOT}/normalization-count"
printf '0\n' >"$candidate_fetch_file"
printf '0\n' >"$normalization_file"
export candidate_fetch_file normalization_file
gh_issue_list() {
	local candidate_fetch_count=""
	candidate_fetch_count=$(<"$candidate_fetch_file")
	candidate_fetch_count=$((candidate_fetch_count + 1))
	printf '%s\n' "$candidate_fetch_count" >"$candidate_fetch_file"
	if [[ "$candidate_fetch_count" -eq 1 ]]; then
		printf '%s\n' '[{"number":20,"title":"next child","url":"","updatedAt":"2026-07-11T00:00:00Z","assignees":[],"labels":[{"name":"auto-dispatch"},{"name":"status:blocked"}]},{"number":30,"title":"unrelated work","url":"","updatedAt":"2026-07-11T00:00:00Z","assignees":[],"labels":[{"name":"auto-dispatch"},{"name":"status:available"}]}]'
	else
		printf '%s\n' '[{"number":20,"title":"next child","url":"","updatedAt":"2026-07-11T00:00:00Z","assignees":[],"labels":[{"name":"auto-dispatch"},{"name":"status:available"}]},{"number":30,"title":"unrelated work","url":"","updatedAt":"2026-07-11T00:00:00Z","assignees":[],"labels":[{"name":"auto-dispatch"},{"name":"status:available"}]}]'
	fi
	return 0
}
normalize_repo_dependency_readiness_if_due() {
	local normalization_count=""
	normalization_count=$(<"$normalization_file")
	normalization_count=$((normalization_count + 1))
	printf '%s\n' "$normalization_count" >"$normalization_file"
	return 0
}
export -f gh_issue_list normalize_repo_dependency_readiness_if_due
recovered_candidates=$(list_dispatchable_issue_candidates_json "owner/repo" 100)
assert_eq "all-blocked roadmap triggers dependency normalization" "1" "$(<"$normalization_file")"
assert_eq "next dependency-ready child reaches shared candidate stream" "20" \
	"$(printf '%s' "$recovered_candidates" | jq -r 'map(select(.number == 20))[0].number')"

# A successful command that returns null after dependency normalization is not
# a complete empty snapshot. Preserve failure provenance so campaign renewal
# cannot infer that every previously open issue completed.
printf '0\n' >"$candidate_fetch_file"
null_refresh_raw="${TMP_ROOT}/null-refresh-raw.json"
null_refresh_status="${TMP_ROOT}/null-refresh-status.txt"
gh_issue_list() {
	local candidate_fetch_count=""
	candidate_fetch_count=$(<"$candidate_fetch_file")
	candidate_fetch_count=$((candidate_fetch_count + 1))
	printf '%s\n' "$candidate_fetch_count" >"$candidate_fetch_file"
	if [[ "$candidate_fetch_count" -eq 1 ]]; then
		printf '%s\n' '[{"number":20,"title":"next child","url":"","updatedAt":"2026-07-11T00:00:00Z","assignees":[],"labels":[{"name":"status:blocked"}]}]'
	else
		printf 'null\n'
	fi
	return 0
}
null_refresh_candidates=$(list_dispatchable_issue_candidates_json \
	"owner/repo" 100 "$null_refresh_raw" "$null_refresh_status")
assert_eq "null refresh records failed snapshot provenance" "0" "$(<"$null_refresh_status")"
assert_eq "null refresh persists a safe empty raw snapshot" "[]" "$(<"$null_refresh_raw")"
assert_eq "null refresh returns no dispatch candidates" "[]" "$null_refresh_candidates"

malformed_raw="${TMP_ROOT}/malformed-raw.json"
malformed_status="${TMP_ROOT}/malformed-status.txt"
gh_issue_list() {
	printf '%s\n' '[{"number":"invalid","labels":[],"assignees":[]}]'
	return 0
}
malformed_candidates=$(list_dispatchable_issue_candidates_json \
	"owner/repo" 100 "$malformed_raw" "$malformed_status")
assert_eq "malformed snapshot records failed provenance" "0" "$(<"$malformed_status")"
assert_eq "malformed snapshot persists a safe empty raw snapshot" "[]" "$(<"$malformed_raw")"
assert_eq "malformed snapshot returns no dispatch candidates" "[]" "$malformed_candidates"

gh_issue_list() {
	printf '%s\n' '[{"number":20,"labels":"status:available","assignees":[]}]'
	return 0
}
malformed_candidates=$(list_dispatchable_issue_candidates_json \
	"owner/repo" 100 "$malformed_raw" "$malformed_status")
assert_eq "malformed labels record failed provenance" "0" "$(<"$malformed_status")"
assert_eq "malformed labels return no dispatch candidates" "[]" "$malformed_candidates"

gh_issue_list() {
	printf '%s\n' '[{"number":20,"title":"normalized fields","url":"","createdAt":"2026-07-11T00:00:00Z","updatedAt":"2026-07-11T00:00:00Z","labels":["status:available"],"assignees":["example-runner"]}]'
	return 0
}
normalized_candidates=$(list_dispatchable_issue_candidates_json \
	"owner/repo" 100 "$malformed_raw" "$malformed_status")
assert_eq "normalized string fields retain successful provenance" "1" "$(<"$malformed_status")"
assert_eq "normalized string fields remain dispatchable" "20" \
	"$(printf '%s' "$normalized_candidates" | jq -r '.[0].number')"

status_write=""
view_counter_file="${TMP_ROOT}/unblock-view-count"
printf '0\n' >"$view_counter_file"
gh() {
	local command="$1"
	local target="${2:-}"
	if [[ "$command" == "api" ]]; then
		_test_dep_identity_api "$target"
		return $?
	elif [[ "$command $target" == "issue view" ]]; then
		local view_count=""
		view_count=$(<"$view_counter_file")
		view_count=$((view_count + 1))
		printf '%s\n' "$view_count" >"$view_counter_file"
		case "$view_count" in
			1 | 2) printf 'status:blocked\n' ;;
			*) printf 'status:queued,status:available\n' ;;
		esac
	elif [[ "$command $target" == "issue edit" ]]; then
		status_write="${status_write}$(_test_render_args "$@")"$'\n'
	fi
	return 0
}
_should_defer_auto_unblock() {
	return 1
}
_refresh_cleanup_resolved_blocker_labels() {
	return 1
}
export -f gh _should_defer_auto_unblock _refresh_cleanup_resolved_blocker_labels
_refresh_try_unblock_issue "owner/repo" "20" '{"task_ids":[],"issue_nums":[]}' '{}' || true
assert_true "concurrent queued transition wins resolved unblock" \
	grep -Fq -- "--remove-label status:available" <<<"$status_write"

_blocked_by_check_native_relationships() {
	return 2
}
_blocked_by_check_issue_num() {
	return 0
}
export -f _blocked_by_check_native_relationships _blocked_by_check_issue_num
if _refresh_dependency_is_resolved "owner/repo" "20" '{"task_ids":[],"issue_nums":["10"]}' '{}' '[]' '[10,20]'; then
	assert_eq "partial native repair still checks declared edge" "blocked" "resolved"
else
	assert_eq "partial native repair still checks declared edge" "blocked" "blocked"
fi

python3 - "$SCRIPTS_DIR/pulse-check-queue-scan.py" <<'PY'
import datetime as dt
import importlib.util
import sys

path = sys.argv[1]
spec = importlib.util.spec_from_file_location("queue_scan", path)
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)

def issue(number, body, labels=None):
    return {
        "number": number,
        "title": f"t{number}: child",
        "body": body,
        "labels": [{"name": name} for name in (labels or ["status:available", "auto-dispatch"])],
        "assignees": [],
        "updatedAt": "2026-07-11T00:00:00Z",
    }

# Native clear relationships still require every explicit declared edge closed.
module._native_dependency_state = lambda slug, number: module.NATIVE_CLEAR
module._run_gh_json = lambda cmd: {"state": "CLOSED"}
assert module._dependency_inconsistent("owner/repo", issue(102, "Blocked by #101")) is False

# Native open relationships are always inconsistent with available.
module._native_dependency_state = lambda slug, number: module.NATIVE_UNRESOLVED
assert module._dependency_inconsistent("owner/repo", issue(102, "")) is True

# Text fallback holds ordered roadmap children when native links are absent.
module._native_dependency_state = lambda slug, number: module.NATIVE_ABSENT
module._run_gh_json = lambda cmd: {"state": "OPEN"} if cmd[1:3] == ["issue", "view"] else None
roadmap_child = issue(102, "Blocked by #101")
assert module._dependency_inconsistent("owner/repo", roadmap_child) is True

# Missing textual references fail closed rather than becoming available.
module._run_gh_json = lambda cmd: None
assert module._dependency_inconsistent("owner/repo", issue(103, "Blocked by #999999")) is True

# Native API uncertainty and pagination truncation fail closed and report an error.
module._native_dependency_state = lambda slug, number: module.NATIVE_UNKNOWN
assert module._dependency_diagnostic("owner/repo", issue(104, "")) == (True, True)

# Parent tasks remain unavailable through their independent blocking label.
aggregate = module._empty_aggregate()
parent = issue(200, "", ["status:available", "auto-dispatch", "parent-task"])
parent["dependency_inconsistent"] = False
available = module._count_issue(aggregate, parent, dt.datetime.now(dt.timezone.utc), 30)
assert available is False

# Dependency-inconsistent availability is reported separately and excluded.
aggregate = module._empty_aggregate()
roadmap_child["dependency_inconsistent"] = True
available = module._count_issue(aggregate, roadmap_child, dt.datetime.now(dt.timezone.utc), 30)
assert available is False
assert aggregate["dependency_inconsistent_available"] == 1
assert aggregate["available_unassigned"] == 0
print("PASS: queue scanner native/text/missing/parent diagnostics")
PY
python_rc=$?
if [[ "$python_rc" -eq 0 ]]; then
	pass=$((pass + 1))
else
	fail=$((fail + 1))
fi

printf '\nResults: %d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]] || exit 1
exit 0

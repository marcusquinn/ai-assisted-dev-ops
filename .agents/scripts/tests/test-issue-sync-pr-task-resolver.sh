#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESOLVER="${SCRIPT_DIR}/../issue-sync-pr-task-resolver.sh"
WORKFLOW="${SCRIPT_DIR}/../../../.github/workflows/issue-sync-reusable.yml"
PROTECTED_PUBLISH_CALL='issue-sync-git-push-helper\.sh" publish-todo main 3'
MULTI_TASK_PUBLICATION="chore: mark \\\$UPDATED_TASK_IDS complete (\\\$PROOF) \[skip ci\]"
PAIR_MATCH="if [[ \"\${ISSUE_TASK_PAIR%%:*}\" == \"\$ISSUE_NUM\" ]]"
MAPPED_TASK_REF="TASK_REF=\" Task \$MAPPED_TASK_ID\""
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT
PASS=0
FAIL=0

check_success() {
	local name="$1"
	local title_id="$2"
	local issues="$3"
	local expected="$4"
	local vetoed="${5:-}"
	local actual=""
	if actual=$(bash "$RESOLVER" "${TMP_DIR}/TODO.md" "$issues" "$title_id" "$vetoed") && [[ "$actual" == "$expected" ]]; then
		printf 'PASS: %s\n' "$name"
		PASS=$((PASS + 1))
	else
		printf 'FAIL: %s (expected %s, got %s)\n' "$name" "$expected" "$actual"
		FAIL=$((FAIL + 1))
	fi
	return 0
}

check_failure() {
	local name="$1"
	local title_id="$2"
	local issues="$3"
	local vetoed="${4:-}"
	if bash "$RESOLVER" "${TMP_DIR}/TODO.md" "$issues" "$title_id" "$vetoed" >/dev/null 2>&1; then
		printf 'FAIL: %s (unexpected success)\n' "$name"
		FAIL=$((FAIL + 1))
	else
		printf 'PASS: %s\n' "$name"
		PASS=$((PASS + 1))
	fi
	return 0
}

cat >"${TMP_DIR}/TODO.md" <<'EOF'
- [ ] t100 canonical title ref:GH#700
- [ ] t101 issue-title identity ref:GH#701
- [ ] t102 renamed task text ref:GH#702
- [ ] t103 first close ref:GH#703
- [ ] t104 second close ref:GH#704
EOF

check_success "canonical tNNN title agrees" "t100" "700" "t100|700|true|700:t100"
check_success "GH# title has no task identity and uses ref" "" "701" "t101|701|true|701:t101"
check_success "recovery or renamed title uses ref" "" "702" "t102|702|true|702:t102"
check_success "multiple closing issues preserve associations" "t103" "703 704" "t103 t104|703 704|true|703:t103 704:t104"
check_success "ordinary non-task closing issue is preserved" "" "999" "|999|false|"
check_success "For/Ref overlap is vetoed before resolution" "" "700 999" "|999|false|" "700"

printf '%s\n' '- [ ] t105 duplicate ref ref:GH#700' >>"${TMP_DIR}/TODO.md"
check_failure "duplicate ref is ambiguous" "t100" "700"
check_failure "task-backed mixed flow rejects zero ref match" "t101" "701 999"
check_failure "title and ref conflict fails" "t999" "701"

if grep -q 'id: resolve-tasks' "$WORKFLOW" &&
	grep -q 'steps.resolve-tasks.outputs.effective_issues' "$WORKFLOW"; then
	printf 'PASS: reusable workflow resolves proof-log identity from closing issues\n'
	PASS=$((PASS + 1))
else
	printf 'FAIL: reusable workflow does not use closing-issue resolver\n'
	FAIL=$((FAIL + 1))
fi

resolve_line=$(grep -n 'id: resolve-tasks' "$WORKFLOW" | cut -d: -f1 || true)
hygiene_line=$(grep -n 'name: Apply closing hygiene' "$WORKFLOW" | cut -d: -f1 || true)
if [[ -n "$resolve_line" && -n "$hygiene_line" && "$resolve_line" -lt "$hygiene_line" ]]; then
	printf 'PASS: task mapping validates before closing hygiene\n'
	PASS=$((PASS + 1))
else
	printf 'FAIL: task mapping does not validate before closing hygiene\n'
	FAIL=$((FAIL + 1))
fi

if grep -q "name: Sync PLANS.md status" "$WORKFLOW" &&
	grep -q "if: steps.resolve-tasks.outputs.task_backed == 'true' && steps.extract.outputs.range_syntax != 'true'" "$WORKFLOW"; then
	printf 'PASS: range syntax guards TODO and PLAN completion\n'
	PASS=$((PASS + 1))
else
	printf 'FAIL: range syntax does not guard downstream completion\n'
	FAIL=$((FAIL + 1))
fi

if grep -q "$PROTECTED_PUBLISH_CALL" "$WORKFLOW" &&
	grep -q "$MULTI_TASK_PUBLICATION" "$WORKFLOW" &&
	! grep -q 'WORKAROUND_COMMANDS' "$WORKFLOW"; then
	printf 'PASS: multi-task proof publication uses the cumulative PR-safe helper\n'
	PASS=$((PASS + 1))
else
	printf 'FAIL: multi-task proof publication bypasses the cumulative PR-safe helper\n'
	FAIL=$((FAIL + 1))
fi

if grep -q 'ISSUE_TASK_PAIRS:.*issue_task_pairs' "$WORKFLOW" &&
	grep -Fq "$PAIR_MATCH" "$WORKFLOW" &&
	grep -Fq "$MAPPED_TASK_REF" "$WORKFLOW"; then
	printf 'PASS: multi-issue hygiene uses per-issue blocked and comment task mapping\n'
	PASS=$((PASS + 1))
else
	printf 'FAIL: multi-issue hygiene does not preserve issue-task association\n'
	FAIL=$((FAIL + 1))
fi

printf '\nResults: %s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]

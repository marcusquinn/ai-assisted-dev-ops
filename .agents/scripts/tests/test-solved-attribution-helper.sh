#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Integration coverage for solved-attribution report and guarded dry-run backfill.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
HELPER="${TEST_DIR}/../solved-attribution-helper.sh"
TMP_ROOT=$(mktemp -d -t solved-attribution.XXXXXX) || exit 1
trap 'rm -rf "$TMP_ROOT"' EXIT
STUB_DIR="${TMP_ROOT}/bin"
mkdir -p "$STUB_DIR"

cat >"${STUB_DIR}/gh" <<'STUB'
#!/usr/bin/env bash
set -u
if [[ "$1" == "issue" && "$2" == "list" ]]; then
	case " $* " in
	*" --json number,stateReason,closedByPullRequestsReferences "*)
		printf '%s\n' '[{"number":101,"stateReason":"COMPLETED","closedByPullRequestsReferences":[{"number":11}]},{"number":102,"stateReason":"COMPLETED","closedByPullRequestsReferences":[{"number":12},{"number":13}]}]'
		;;
	*" label:solved:worker label:solved:interactive "*) printf '%s\n' '[{"number":5}]' ;;
	*" label:solved:worker -label:solved:interactive "*) printf '%s\n' '[{"number":1},{"number":2}]' ;;
	*" label:solved:interactive -label:solved:worker "*) printf '%s\n' '[{"number":3}]' ;;
	*" -label:solved:worker -label:solved:interactive "*) printf '%s\n' '[{"number":4}]' ;;
	*) printf '%s\n' '[]' ;;
	esac
	exit 0
fi
if [[ "$1" == "pr" && "$2" == "view" && "$3" == "11" ]]; then
	printf '2026-08-01T00:00:00Z\torigin:worker,bug\n'
	exit 0
fi
printf '%s\n' '[]'
exit 0
STUB
chmod +x "${STUB_DIR}/gh"

PASS=0
FAIL=0

assert_contains() {
	local name="$1"
	local needle="$2"
	local haystack="$3"
	if [[ "$haystack" == *"$needle"* ]]; then
		PASS=$((PASS + 1))
		printf 'PASS: %s\n' "$name"
	else
		FAIL=$((FAIL + 1))
		printf 'FAIL: %s (missing %s)\n' "$name" "$needle" >&2
	fi
	return 0
}

REPORT=$(PATH="${STUB_DIR}:$PATH" "$HELPER" report --repo owner/repo --since 2026-08-01 --json)
assert_contains "report counts worker attribution" '"solved_worker": 2' "$REPORT"
assert_contains "report counts interactive attribution" '"solved_interactive": 1' "$REPORT"
assert_contains "report isolates conflicting attribution" '"conflicting": 1' "$REPORT"
assert_contains "report counts missing attribution" '"unattributed": 1' "$REPORT"
assert_contains "report calculates coverage" '"coverage_percent": 60' "$REPORT"

BACKFILL=$(PATH="${STUB_DIR}:$PATH" "$HELPER" backfill --repo owner/repo --since 2026-08-01 --limit 10)
assert_contains "dry-run attributes unambiguous merged worker PR" '[DRY-RUN] issue #101 <- solved:worker from merged PR #11' "$BACKFILL"
assert_contains "dry-run skips ambiguous multiple-PR evidence" 'skipped_or_ambiguous=1' "$BACKFILL"

if PATH="${STUB_DIR}:$PATH" "$HELPER" report --repo owner/repo --since 2026-08-01 --min-coverage 80 >/dev/null 2>&1; then
	FAIL=$((FAIL + 1))
	printf 'FAIL: minimum coverage gate should fail below threshold\n' >&2
else
	PASS=$((PASS + 1))
	printf 'PASS: minimum coverage gate fails below threshold\n'
fi

printf 'Results: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]

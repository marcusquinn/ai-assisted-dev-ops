#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
SCRIPTS_DIR="${SCRIPT_DIR}/.."
ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT
mkdir -p "${ROOT}/bin" "${ROOT}/helpers"

cat >"${ROOT}/helpers/review-bot-gate-helper.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "${REVIEW_GATE_TEST_RESULT:-PASS}"
exit 0
STUB
chmod +x "${ROOT}/helpers/review-bot-gate-helper.sh"

cat >"${ROOT}/bin/gh" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "api" && "${2:-}" == "repos/testorg/testrepo" ]]; then
	if [[ "${GH_TEST_MODE:-pass}" == "api-error" ]]; then
		printf '%s\n' 'HTTP 503: service unavailable' >&2
		exit 1
	fi
	printf '%s\n' 'main'
	exit 0
fi
if [[ "${1:-}" == "api" && "${2:-}" == *"/protection/required_status_checks" ]]; then
	if [[ "${GH_TEST_MODE:-pass}" == "cli-no-required" ]]; then
		printf '%s\n' 'gh: HTTP 403: branch protection unavailable' >&2
		exit 1
	fi
	if [[ "${GH_TEST_MODE:-pass}" == "no-required" ]]; then
		printf '%s\n' 'gh: HTTP 404: Not Found' >&2
		exit 1
	fi
	printf '%s\n' '{"contexts":["required-ci"]}'
	exit 0
fi
if [[ "${1:-}" == "api" && "${2:-}" == "repos/testorg/testrepo/rulesets" ]]; then
	printf '%s\n' '[]'
	exit 0
fi
if [[ "${1:-}" == "pr" && "${2:-}" == "checks" ]]; then
	case "${GH_TEST_MODE:-pass}" in
		pending)
			printf '%s\n' '[{"name":"required-ci","state":"IN_PROGRESS","bucket":"pending"}]'
			exit 8
			;;
		no-required)
			printf '%s\n' 'required-check CLI must not run when configuration has no contexts' >&2
			exit 99
			;;
		cli-no-required)
			printf "%s\n" "no required checks reported on the 'remote-branch' branch" >&2
			exit 1
			;;
		api-error)
			printf '%s\n' 'HTTP 503: service unavailable' >&2
			exit 1
			;;
		changed-wording)
			printf "%s\n" "no required checks configured for the 'remote-branch' branch" >&2
			exit 1
			;;
		malformed)
			printf '%s\n' 'not-json'
			exit 0
			;;
		empty-array)
			printf '%s\n' '[]'
			exit 0
			;;
		*)
			printf '%s\n' '[{"name":"required-ci","state":"SUCCESS","bucket":"pass"}]'
			exit 0
			;;
	esac
fi
if [[ "${1:-}" == "pr" && "${2:-}" == "view" && " $* " == *" --jq "* ]]; then
	printf '%s\n' 'abc123'
	exit 0
fi
case "${GH_TEST_MODE:-pass}" in
	draft) printf '%s\n' '{"state":"OPEN","isDraft":true,"reviewDecision":"","headRefOid":"abc123","headRefName":"remote-branch","statusCheckRollup":[]}' ;;
	optional-cancelled) printf '%s\n' '{"state":"OPEN","isDraft":false,"reviewDecision":"APPROVED","headRefOid":"abc123","headRefName":"remote-branch","statusCheckRollup":[{"name":"old-optional","status":"COMPLETED","conclusion":"CANCELLED"}]}' ;;
	changes) printf '%s\n' '{"state":"OPEN","isDraft":false,"reviewDecision":"CHANGES_REQUESTED","headRefOid":"abc123","headRefName":"remote-branch","statusCheckRollup":[]}' ;;
	closed) printf '%s\n' '{"state":"CLOSED","isDraft":false,"reviewDecision":"","headRefOid":"abc123","headRefName":"remote-branch","statusCheckRollup":[]}' ;;
	*) printf '%s\n' '{"state":"OPEN","isDraft":false,"reviewDecision":"APPROVED","headRefOid":"abc123","headRefName":"remote-branch","statusCheckRollup":[{"status":"COMPLETED","conclusion":"SUCCESS"}]}' ;;
esac
exit 0
STUB
chmod +x "${ROOT}/bin/gh"

run_gate() {
	local mode="$1"
	local runner="${ROOT}/runner-${mode}.sh"
	cat >"$runner" <<RUNNER
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR='${ROOT}/helpers'
print_error() { printf 'ERROR %s\n' "\$*"; return 0; }
print_info() { return 0; }
print_warning() { return 0; }
print_success() { return 0; }
source '${SCRIPTS_DIR}/full-loop-helper-commit.sh'
gh_pr_checks_exact_json() {
	local repo_slug="\$1"
	local pr_number="\$2"
	local selection_mode="\$3"
	: "\$repo_slug" "\$pr_number" "\$selection_mode"
	case "\${GH_TEST_MODE:-pass}" in
		pending)
			printf '%s\n' '[{"name":"required-ci","state":"IN_PROGRESS","bucket":"pending"}]'
			return 8
			;;
		no-required)
			printf '%s\n' 'exact check helper must not run when configuration has no contexts' >&2
			return 99
			;;
		cli-no-required)
			printf "%s\n" "no required checks reported on the 'remote-branch' branch" >&2
			return 1
			;;
		api-error)
			printf '%s\n' 'exact check read unavailable' >&2
			return 2
			;;
		changed-wording)
			printf "%s\n" "no required checks configured for the 'remote-branch' branch" >&2
			return 1
			;;
		malformed)
			printf '%s\n' 'not-json'
			return 0
			;;
		empty-array)
			printf '%s\n' '[]'
			return 0
			;;
		*)
			printf '%s\n' '[{"name":"required-ci","state":"SUCCESS","bucket":"pass"}]'
			return 0
			;;
	esac
}
cmd_pre_merge_gate 42 testorg/testrepo
RUNNER
	chmod +x "$runner"
	GH_TEST_MODE="$mode" REVIEW_GATE_TEST_RESULT="${REVIEW_GATE_TEST_RESULT:-PASS}" \
		PATH="${ROOT}/bin:/opt/homebrew/bin:/usr/bin:/bin" bash "$runner" >/dev/null 2>&1
	return $?
}

run_gate pass || {
	printf 'FAIL terminal remote evidence was rejected\n'
	exit 1
}
printf 'PASS terminal remote evidence is accepted\n'

REVIEW_GATE_TEST_RESULT=PASS_ADVISORY run_gate pass || {
	printf 'FAIL advisory-default review result was rejected\n'
	exit 1
}
printf 'PASS advisory-default review result is accepted\n'

run_gate optional-cancelled || {
	printf 'FAIL cancelled optional history blocked passing required checks\n'
	exit 1
}
printf 'PASS cancelled optional history does not override passing required checks\n'

run_gate no-required || {
	printf 'FAIL explicit no-required-checks evidence was rejected\n'
	exit 1
}
printf 'PASS explicit no-required-checks evidence reaches the review-bot gate\n'

run_gate cli-no-required || {
	printf 'FAIL canonical CLI no-required-checks evidence was rejected after API failure\n'
	exit 1
}
printf 'PASS canonical CLI no-required-checks evidence survives unavailable branch protection\n'

for mode in draft pending changes closed api-error changed-wording malformed empty-array; do
	if run_gate "$mode"; then
		printf 'FAIL unsafe remote state was accepted: %s\n' "$mode"
		exit 1
	fi
	printf 'PASS unsafe remote state is blocked: %s\n' "$mode"
done

exit 0

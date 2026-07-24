#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Regression coverage for GH#28466 runtime-risk PR body classification.

set -uo pipefail

SCRIPT_DIR_TEST="$(cd "$(dirname "$0")/.." && pwd)" || exit 1
TESTS_RUN=0
TESTS_FAILED=0
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT

print_error() {
	local message="$1"
	printf 'ERROR %s\n' "$message" >&2
	return 0
}

assert_contains() {
	local name="$1"
	local actual="$2"
	local expected="$3"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$actual" == *"$expected"* ]]; then
		printf 'PASS %s\n' "$name"
	else
		printf 'FAIL %s: missing %s\n' "$name" "$expected"
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	return 0
}

assert_rejected() {
	local name="$1"
	shift
	TESTS_RUN=$((TESTS_RUN + 1))
	if "$@" >/dev/null 2>&1; then
		printf 'FAIL %s\n' "$name"
		TESTS_FAILED=$((TESTS_FAILED + 1))
	else
		printf 'PASS %s\n' "$name"
	fi
	return 0
}

# shellcheck source=../full-loop-helper-risk.sh
source "${SCRIPT_DIR_TEST}/full-loop-helper-risk.sh"
# shellcheck source=../full-loop-helper-commit.sh
source "${SCRIPT_DIR_TEST}/full-loop-helper-commit.sh"

high_body=$(_build_pr_body \
	"28466" \
	"Fix polling-loop state-machine behavior" \
	"runtime-verified with a polling fixture" \
	"src/poller.sh, tests/test-poller.sh" \
	"<!-- aidevops:sig -->" \
	"Resolves")
assert_contains "polling fixture derives High" "$high_body" "**Risk level:** High"
assert_contains "High fixture records runtime evidence" "$high_body" "**Verification:** runtime-verified"
assert_contains "closing keyword remains compatible" "$high_body" "Resolves #28466"
assert_contains "signature remains compatible" "$high_body" "<!-- aidevops:sig -->"

assert_rejected "High without runtime evidence is rejected" \
	_build_pr_body "1" "API endpoint" "unit tests pass" "src/api.sh" ""
assert_rejected "Critical without runtime evidence is rejected" \
	_build_pr_body "2" "Credential rotation" "self-assessed" "src/auth.sh" "" "Resolves" "Critical" "self-assessed"
assert_rejected "explicit Low cannot bypass Critical runtime evidence" \
	_build_pr_body "2" "Delete data" "self-assessed" "src/storage.sh" "" "Resolves" "Low" "self-assessed"
assert_rejected "bare runtime marker is not evidence" \
	_build_pr_body "2" "Credential rotation" "runtime-verified" "src/auth.sh" ""
assert_rejected "explicit runtime level still requires evidence" \
	_build_pr_body "2" "Credential rotation" "" "src/auth.sh" "" "Resolves" "Critical" "runtime-verified"

low_body=$(_build_pr_body \
	"3" \
	"Document credential and polling-loop behavior" \
	"focused tests pass" \
	"docs/runtime.md, .agents/scripts/tests/test-docs.sh, .qlty/qlty.toml, stubs/client.pyi" \
	"" \
	"Resolves")
assert_contains "non-runtime files remain Low despite policy terms" "$low_body" "**Risk level:** Low"
assert_contains "Low fixture is self-assessed" "$low_body" "**Verification:** self-assessed"

author_body=$(_build_pr_body \
	"4" \
	"Update author metadata" \
	"focused tests pass" \
	"src/metadata.sh" \
	"" \
	"Resolves")
assert_contains "author does not false-match auth" "$author_body" "**Risk level:** Medium"

critical_body=$(_build_pr_body \
	"5" \
	"Change credential rotation" \
	"runtime-verified with a credential rotation fixture" \
	"src/auth.sh" \
	"" \
	"Resolves" \
	"Low")
assert_contains "explicit Low cannot downgrade Critical" "$critical_body" "**Risk level:** Critical"

raised_body=$(_build_pr_body \
	"6" \
	"Change ambiguous runtime behavior" \
	"runtime-verified with an integration fixture" \
	"src/worker.sh" \
	"" \
	"Resolves" \
	"High")
assert_contains "explicit risk can raise an ambiguous change" "$raised_body" "**Risk level:** High"

COMMENT_REPO="${TEST_ROOT}/comment-repo"
mkdir -p "${COMMENT_REPO}/src"
/usr/bin/git -C "$COMMENT_REPO" init -q
/usr/bin/git -C "$COMMENT_REPO" config user.name "Runtime Risk Test"
/usr/bin/git -C "$COMMENT_REPO" config user.email "runtime-risk@example.invalid"
printf '#!/usr/bin/env bash\nprintf "ok\\n"\n# Old credential comment.\n' >"${COMMENT_REPO}/src/app.sh"
/usr/bin/git -C "$COMMENT_REPO" add src/app.sh
/usr/bin/git -C "$COMMENT_REPO" -c commit.gpgSign=false commit -qm "fixture: add runtime file"
comment_base=$(/usr/bin/git -C "$COMMENT_REPO" rev-parse HEAD)
printf '#!/usr/bin/env bash\nprintf "ok\\n"\n# New credential comment.\n' >"${COMMENT_REPO}/src/app.sh"
/usr/bin/git -C "$COMMENT_REPO" add src/app.sh
/usr/bin/git -C "$COMMENT_REPO" -c commit.gpgSign=false commit -qm "docs: update source comment"
comment_body=$(cd "$COMMENT_REPO" && _build_pr_body \
	"7" \
	"Update a source comment" \
	"diff reviewed" \
	"src/app.sh" \
	"" \
	"Resolves" \
	"" \
	"" \
	"$comment_base")
assert_contains "comment-only source change remains Low" "$comment_body" "**Risk level:** Low"

runtime_risk=""
testing_level=""
issue_number=""
commit_message=""
pr_title=""
summary_what=""
summary_testing=""
summary_decisions=""
allow_parent_close=0
skip_hooks=0
skip_rebase=0
extra_labels=()
_parse_commit_and_pr_args --issue 4 --message "test" --risk-level High --testing-level runtime-verified
assert_contains "risk level flag is accepted" "$runtime_risk" "High"
assert_contains "testing level flag is accepted" "$testing_level" "runtime-verified"

ORDERING_BIN="${TEST_ROOT}/ordering-bin"
ORDERING_TRACE="${TEST_ROOT}/ordering-trace"
mkdir -p "$ORDERING_BIN"
cat >"${ORDERING_BIN}/git" <<'EOF'
#!/usr/bin/env bash
printf 'git %s\n' "$*" >>"$ORDERING_TRACE"
if [[ "$1" == "branch" && "$2" == "--show-current" ]]; then
	printf 'feature/metadata-ordering\n'
fi
exit 0
EOF
cat >"${ORDERING_BIN}/gh" <<'EOF'
#!/usr/bin/env bash
printf 'gh %s\n' "$*" >>"$ORDERING_TRACE"
if [[ "$1" == "repo" && "$2" == "view" ]]; then
	printf 'example/ordering\n'
fi
exit 0
EOF
chmod +x "${ORDERING_BIN}/git" "${ORDERING_BIN}/gh"

for invalid_flag in "--testing-level invalid" "--risk-level invalid"; do
	invalid_option="${invalid_flag%% *}"
	invalid_value="${invalid_flag#* }"
	: >"$ORDERING_TRACE"
	if PATH="${ORDERING_BIN}:$PATH" ORDERING_TRACE="$ORDERING_TRACE" \
		"${SCRIPT_DIR_TEST}/full-loop-helper.sh" commit-and-pr --issue 4 --message "fix: validate metadata" "$invalid_option" "$invalid_value" >/dev/null 2>&1; then
		printf 'FAIL invalid metadata is rejected before mutation: %s\n' "$invalid_flag"
		TESTS_FAILED=$((TESTS_FAILED + 1))
	else
		if grep -Eq '^git (add|commit|rebase|push)|^gh (pr|api .*POST)' "$ORDERING_TRACE"; then
			printf 'FAIL invalid metadata avoids Git and GitHub mutations: %s\n' "$invalid_flag"
			TESTS_FAILED=$((TESTS_FAILED + 1))
		else
			printf 'PASS invalid metadata avoids Git and GitHub mutations: %s\n' "$invalid_flag"
		fi
	fi
	TESTS_RUN=$((TESTS_RUN + 1))
done

printf '\n%d tests run, %d failed\n' "$TESTS_RUN" "$TESTS_FAILED"
[[ "$TESTS_FAILED" -eq 0 ]] || exit 1
exit 0

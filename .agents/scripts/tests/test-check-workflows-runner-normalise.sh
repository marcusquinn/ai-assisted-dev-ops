#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-check-workflows-runner-normalise.sh — regression test for GH#21877
#
# Verifies that _normalize_wf_for_compare in check-workflows-helper.sh
# correctly handles the injected `with: runner:` block so repos that carry
# a repos.json `runner` field are not falsely flagged as DRIFTED/CALLER.
#
# Scenarios covered:
#   A.  Canonical template (no runner override) → CURRENT/CALLER
#   B.  Caller with injected `with: runner: ubicloud-standard-2` inside an
#       existing `with:` block (issue-sync pattern) → CURRENT/CALLER
#   C.  Caller with a standalone `with: runner: ubicloud-standard-2` block
#       injected after `uses:` (maintainer-gate / review-bot-gate pattern)
#       → CURRENT/CALLER
#   D.  Caller with a genuinely drifted line (unrelated to runner) → DRIFTED/CALLER
#       (true-positive preserved — runner normalisation must not mask real drift)
#   E.  Caller with runner AND a develop-branch variant → CURRENT/CALLER
#       (runner + branch normalisations compose correctly)
#   F.  Caller with a `with: runner: <label>` block appended at EOF
#       → CURRENT/CALLER (GH#21899 regression — earlier awk END block
#       re-emitted the buffered `with:` when it was the last line of the
#       file, falsely classifying these callers as DRIFTED/CALLER).
#
# Strategy: each scenario builds a temporary repo tree, copies the canonical
# caller template (optionally mutated), runs the helper in --json mode, and
# asserts the classification string.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
HELPER="${SCRIPT_DIR}/../check-workflows-helper.sh"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)" || exit 1

if [[ ! -f "$HELPER" ]]; then
	echo "SKIP: helper not found at $HELPER" >&2
	exit 0
fi

readonly _T_GREEN='\033[0;32m'
readonly _T_RED='\033[0;31m'
readonly _T_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0

_pass() {
	local name="$1"
	TESTS_RUN=$((TESTS_RUN + 1))
	printf '%bPASS%b %s\n' "$_T_GREEN" "$_T_RESET" "$name"
	return 0
}

_fail() {
	local name="$1"
	local msg="${2:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	TESTS_FAILED=$((TESTS_FAILED + 1))
	printf '%bFAIL%b %s\n' "$_T_RED" "$_T_RESET" "$name"
	[[ -n "$msg" ]] && printf '       %s\n' "$msg"
	return 0
}

# ─── Fixture helpers ──────────────────────────────────────────────────────────

_setup_fake_home() {
	local _root="$1"
	mkdir -p "$_root/.config/aidevops"
	mkdir -p "$_root/.aidevops/agents/templates/workflows"
	# Copy all canonical templates so the helper resolves any workflow type.
	local _tpl
	for _tpl in issue-sync-caller.yml review-bot-gate-caller.yml \
	            maintainer-gate-caller.yml loc-badge-caller.yml \
	            linked-issue-check-caller.yml; do
		local _src="$REPO_ROOT/.agents/templates/workflows/${_tpl}"
		[[ -f "$_src" ]] && cp "$_src" "$_root/.aidevops/agents/templates/workflows/${_tpl}"
	done
	return 0
}

_write_repos_json() {
	local _root="$1"
	local _json="$2"
	printf '%s\n' "$_json" > "$_root/.config/aidevops/repos.json"
	return 0
}

# _classify_for_workflow <fake-home-root> <slug> <workflow-name-without-.yml>
_classify_for_workflow() {
	local _root="$1"
	local _slug="$2"
	local _wf_name="$3"
	HOME="$_root" bash "$HELPER" --json --repo "$_slug" --workflow "$_wf_name" 2>/dev/null \
		| jq -r 'select(.slug != "") | .classification' \
		| head -n 1
	return 0
}

# ─── Scenario helpers ─────────────────────────────────────────────────────────

# _add_runner_to_with_block <src_template> <dest_file> <runner_label>
# Mirrors _inject_runner_in_content for templates that already have a `with:` block.
_add_runner_to_with_block() {
	local _src="$1"
	local _dest="$2"
	local _runner="$3"
	sed -E "s|^(    with:)$|\\1\n      runner: ${_runner}|" "$_src" > "$_dest"
	return 0
}

# _add_standalone_runner_block <src_template> <dest_file> <runner_label>
# Mirrors _inject_runner_in_content for templates with no existing `with:` block.
_add_standalone_runner_block() {
	local _src="$1"
	local _dest="$2"
	local _runner="$3"
	sed -E "s|^(    uses:[[:space:]]*marcusquinn/aidevops/.+)$|\\1\n    with:\n      runner: ${_runner}|" \
		"$_src" > "$_dest"
	return 0
}

# ─── Tests ────────────────────────────────────────────────────────────────────

readonly _RUNNER_LABEL="ubicloud-standard-2"

# Workflow tuples to test: workflow_file:template_file
# We test issue-sync (has existing with: block) and maintainer-gate (no with: block).
readonly -a _WF_TUPLES=(
	"issue-sync.yml:issue-sync-caller.yml"
	"maintainer-gate.yml:maintainer-gate-caller.yml"
	"review-bot-gate.yml:review-bot-gate-caller.yml"
	"loc-badge.yml:loc-badge-caller.yml"
	"linked-issue-check.yml:linked-issue-check-caller.yml"
)

for _wf_tuple in "${_WF_TUPLES[@]}"; do
	_wf_file="${_wf_tuple%%:*}"
	_tpl_file="${_wf_tuple##*:}"
	_wf_name="${_wf_file%.yml}"

	_src_template="$REPO_ROOT/.agents/templates/workflows/${_tpl_file}"
	if [[ ! -f "$_src_template" ]]; then
		printf 'SKIP: template not found: %s\n' "$_src_template" >&2
		continue
	fi

	# ── Scenario A: byte-identical canonical caller (no runner) → CURRENT/CALLER ─
	_TD="$(mktemp -d)"
	_setup_fake_home "$_TD"
	mkdir -p "$_TD/repos/repo-a/.github/workflows"
	cp "$_src_template" "$_TD/repos/repo-a/.github/workflows/${_wf_file}"
	_write_repos_json "$_TD" \
		"$(jq -n --arg p "$_TD/repos/repo-a" \
			'{initialized_repos: [{slug: "x/a", path: $p, local_only: false}]}')"
	_result=$(_classify_for_workflow "$_TD" "x/a" "$_wf_name")
	if [[ "$_result" == "CURRENT/CALLER" ]]; then
		_pass "${_wf_name}: canonical caller (no runner) → CURRENT/CALLER"
	else
		_fail "${_wf_name}: canonical caller (no runner) → CURRENT/CALLER" \
			"got: ${_result:-<empty>}"
	fi
	rm -rf "$_TD"

	# ── Scenario B/C: caller with injected runner block → CURRENT/CALLER ─────
	# For templates with `with:` already (e.g. issue-sync), use _add_runner_to_with_block.
	# For templates without `with:` (e.g. maintainer-gate), use _add_standalone_runner_block.
	_TD="$(mktemp -d)"
	_setup_fake_home "$_TD"
	mkdir -p "$_TD/repos/repo-b/.github/workflows"
	_dest_wf="$_TD/repos/repo-b/.github/workflows/${_wf_file}"
	if grep -qE '^    with:$' "$_src_template" 2>/dev/null; then
		_add_runner_to_with_block "$_src_template" "$_dest_wf" "$_RUNNER_LABEL"
	else
		_add_standalone_runner_block "$_src_template" "$_dest_wf" "$_RUNNER_LABEL"
	fi
	_write_repos_json "$_TD" \
		"$(jq -n --arg p "$_TD/repos/repo-b" \
			'{initialized_repos: [{slug: "x/b", path: $p, local_only: false}]}')"
	_result=$(_classify_for_workflow "$_TD" "x/b" "$_wf_name")
	if [[ "$_result" == "CURRENT/CALLER" ]]; then
		_pass "${_wf_name}: runner-injected caller → CURRENT/CALLER (normalisation)"
	else
		_fail "${_wf_name}: runner-injected caller → CURRENT/CALLER (normalisation)" \
			"got: ${_result:-<empty>} — runner block was not stripped from comparison"
	fi
	rm -rf "$_TD"

	# ── Scenario D: actually-drifted caller → DRIFTED/CALLER (true positive) ──
	_TD="$(mktemp -d)"
	_setup_fake_home "$_TD"
	mkdir -p "$_TD/repos/repo-d/.github/workflows"
	{
		cat "$_src_template"
		printf '\n# Local drift — should NOT be masked by runner normalisation\n'
	} > "$_TD/repos/repo-d/.github/workflows/${_wf_file}"
	_write_repos_json "$_TD" \
		"$(jq -n --arg p "$_TD/repos/repo-d" \
			'{initialized_repos: [{slug: "x/d", path: $p, local_only: false}]}')"
	_result=$(_classify_for_workflow "$_TD" "x/d" "$_wf_name")
	if [[ "$_result" == "DRIFTED/CALLER" ]]; then
		_pass "${_wf_name}: drifted caller → DRIFTED/CALLER (true positive preserved)"
	else
		_fail "${_wf_name}: drifted caller → DRIFTED/CALLER (true positive preserved)" \
			"got: ${_result:-<empty>} — runner normalisation may have swallowed real drift"
	fi
	rm -rf "$_TD"

	# ── Scenario E: runner + develop-branch compose → CURRENT/CALLER ──────────
	# Only issue-sync has a `branches:` filter in the template.
	if grep -qE '^    branches:' "$_src_template" 2>/dev/null; then
		_TD="$(mktemp -d)"
		_setup_fake_home "$_TD"
		mkdir -p "$_TD/repos/repo-e/.github/workflows"
		_dest_e="$_TD/repos/repo-e/.github/workflows/${_wf_file}"
		# First inject runner, then rewrite branch to develop.
		if grep -qE '^    with:$' "$_src_template" 2>/dev/null; then
			_add_runner_to_with_block "$_src_template" "$_dest_e" "$_RUNNER_LABEL"
		else
			_add_standalone_runner_block "$_src_template" "$_dest_e" "$_RUNNER_LABEL"
		fi
		sed -i '' 's/branches: \[main\]/branches: [develop]/' "$_dest_e"
		_write_repos_json "$_TD" \
			"$(jq -n --arg p "$_TD/repos/repo-e" \
				'{initialized_repos: [{slug: "x/e", path: $p, local_only: false}]}')"
		_result=$(_classify_for_workflow "$_TD" "x/e" "$_wf_name")
		if [[ "$_result" == "CURRENT/CALLER" ]]; then
			_pass "${_wf_name}: runner + develop-branch → CURRENT/CALLER (composed normalisation)"
		else
			_fail "${_wf_name}: runner + develop-branch → CURRENT/CALLER (composed normalisation)" \
				"got: ${_result:-<empty>}"
		fi
		rm -rf "$_TD"
	fi

	# ── Scenario F: `with: runner: <label>` block at EOF → CURRENT/CALLER ─────
	# GH#21899: when a caller's runner block ends up as the last content lines
	# of the file (e.g. the caller is missing `secrets: inherit` after `uses:`,
	# or some other path leaves runner as the trailing key), the earlier awk
	# `END { print pending }` resurrected the buffered `with:` and tipped the
	# byte-comparison into DRIFTED/CALLER. The caller below appends the
	# runner-block AFTER all canonical content, so after sed deletes the
	# runner key the `with:` line is genuinely at EOF.
	_TD="$(mktemp -d)"
	_setup_fake_home "$_TD"
	mkdir -p "$_TD/repos/repo-f/.github/workflows"
	_dest_f="$_TD/repos/repo-f/.github/workflows/${_wf_file}"
	{
		cat "$_src_template"
		printf '    with:\n      runner: %s\n' "$_RUNNER_LABEL"
	} > "$_dest_f"
	_write_repos_json "$_TD" \
		"$(jq -n --arg p "$_TD/repos/repo-f" \
			'{initialized_repos: [{slug: "x/f", path: $p, local_only: false}]}')"
	_result=$(_classify_for_workflow "$_TD" "x/f" "$_wf_name")
	if [[ "$_result" == "CURRENT/CALLER" ]]; then
		_pass "${_wf_name}: runner block at EOF → CURRENT/CALLER (GH#21899 regression)"
	else
		_fail "${_wf_name}: runner block at EOF → CURRENT/CALLER (GH#21899 regression)" \
			"got: ${_result:-<empty>} — empty \`with:\` survived normalisation at EOF"
	fi
	rm -rf "$_TD"

done

# ─── Summary ─────────────────────────────────────────────────────────────────

echo
if (( TESTS_FAILED == 0 )); then
	printf '%bAll %d test(s) passed%b\n' "$_T_GREEN" "$TESTS_RUN" "$_T_RESET"
	exit 0
else
	printf '%b%d of %d test(s) failed%b\n' "$_T_RED" "$TESTS_FAILED" "$TESTS_RUN" "$_T_RESET"
	exit 1
fi

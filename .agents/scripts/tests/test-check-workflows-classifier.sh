#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-check-workflows-classifier.sh — regression test for GH#21477
#
# Bug: _resolve_wf_canonical emitted a TSV of "canonical_path\tcanon_norm"
# but `IFS=$'\t' read -r` reads exactly one line, so _canon_norm was silently
# truncated to the first line of the multi-line YAML (~50 bytes vs ~2 KB).
# _classify_workflow's equality check always failed → every caller-pattern
# workflow reported DRIFTED/CALLER for byte-identical inputs.
# Introduced in PR #20809 (GH#20794). Fixed in GH#21477.
#
# Scenarios covered:
# Covers byte-identical, coherently pinned, non-default-branch, and genuinely
# drifted callers for every managed workflow tuple.
#
# Strategy: each scenario copies the canonical caller template byte-for-byte
# (or with a single normalisation-allowed variant) into a temporary repo tree,
# runs the helper in --json mode, and asserts the classification.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
HELPER="${SCRIPT_DIR}/../check-workflows-helper.sh"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)" || exit 1

if [[ ! -f "$HELPER" ]]; then
	echo "SKIP: helper not found at $HELPER" >&2
	exit 0
fi

# Workflow tuple: "workflow_file:reusable_file:template_file"
# Must match _KNOWN_WORKFLOWS in check-workflows-helper.sh.
readonly -a _WORKFLOWS=(
	"issue-sync.yml:issue-sync-reusable.yml:issue-sync-caller.yml"
	"review-bot-gate.yml:review-bot-gate-reusable.yml:review-bot-gate-caller.yml"
	"maintainer-gate.yml:maintainer-gate-reusable.yml:maintainer-gate-caller.yml"
	"loc-badge.yml:loc-badge-reusable.yml:loc-badge-caller.yml"
	"linked-issue-check.yml:linked-issue-check-reusable.yml:linked-issue-check-caller.yml"
)

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
	# Copy all managed templates so the helper can resolve any workflow type.
	local _wf_tuple
	for _wf_tuple in "${_WORKFLOWS[@]}"; do
		local _template_file="${_wf_tuple##*:}"
		local _src="$REPO_ROOT/.agents/templates/workflows/${_template_file}"
		if [[ -f "$_src" ]]; then
			cp "$_src" "$_root/.aidevops/agents/templates/workflows/${_template_file}"
		fi
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
# Returns the classification string for the specified workflow in the single
# repo registered in repos.json.
_classify_for_workflow() {
	local _root="$1"
	local _slug="$2"
	local _wf_name="$3"
	HOME="$_root" bash "$HELPER" --json --repo "$_slug" --workflow "$_wf_name" 2>/dev/null \
		| jq -r 'select(.slug != "") | .classification' \
		| head -n 1
	return 0
}

# ─── Tests ────────────────────────────────────────────────────────────────────

for _wf_tuple in "${_WORKFLOWS[@]}"; do
	_workflow_file="${_wf_tuple%%:*}"
	_reusable_file="${_wf_tuple#*:}"; _reusable_file="${_reusable_file%%:*}"
	_template_file="${_wf_tuple##*:}"
	_wf_name="${_workflow_file%.yml}"

	_src_template="$REPO_ROOT/.agents/templates/workflows/${_template_file}"
	if [[ ! -f "$_src_template" ]]; then
		printf 'SKIP: template not found: %s\n' "$_src_template" >&2
		continue
	fi

	# ── Scenario A: byte-identical to canonical → CURRENT/CALLER ─────────────
	_TD="$(mktemp -d)"
	_setup_fake_home "$_TD"
	mkdir -p "$_TD/repos/repo-a/.github/workflows"
	cp "$_src_template" "$_TD/repos/repo-a/.github/workflows/${_workflow_file}"
	_write_repos_json "$_TD" \
		"$(jq -n --arg p "$_TD/repos/repo-a" \
			'{initialized_repos: [{slug: "x/a", path: $p, local_only: false}]}')"
	_result=$(_classify_for_workflow "$_TD" "x/a" "$_wf_name")
	if [[ "$_result" == "CURRENT/CALLER" ]]; then
		_pass "${_wf_name}: byte-identical caller → CURRENT/CALLER"
	else
		_fail "${_wf_name}: byte-identical caller → CURRENT/CALLER" \
			"got: $_result (GH#21477 regression — read -r truncation bug)"
	fi
	rm -rf "$_TD"

	# ── Scenario B: pinned @v3.9.0 variant → CURRENT/CALLER (normalised ref) ─
	_TD="$(mktemp -d)"
	_setup_fake_home "$_TD"
	mkdir -p "$_TD/repos/repo-b/.github/workflows"
	sed -e "s|${_reusable_file}@main|${_reusable_file}@v3.9.0|g" \
		-e 's|aidevops_ref: main|aidevops_ref: v3.9.0|g' \
		"$_src_template" > "$_TD/repos/repo-b/.github/workflows/${_workflow_file}"
	_write_repos_json "$_TD" \
		"$(jq -n --arg p "$_TD/repos/repo-b" \
			'{initialized_repos: [{slug: "x/b", path: $p, local_only: false}]}')"
	_result=$(_classify_for_workflow "$_TD" "x/b" "$_wf_name")
	if [[ "$_result" == "CURRENT/CALLER" ]]; then
		_pass "${_wf_name}: @v3.9.0-pinned caller → CURRENT/CALLER (normalised @ref)"
	else
		_fail "${_wf_name}: @v3.9.0-pinned caller → CURRENT/CALLER (normalised @ref)" \
			"got: $_result"
	fi
	rm -rf "$_TD"

	# ── Scenario C: branches:[develop] variant → CURRENT/CALLER (normalised branch) ─
	_TD="$(mktemp -d)"
	_setup_fake_home "$_TD"
	mkdir -p "$_TD/repos/repo-c/.github/workflows"
	sed 's/branches: \[main\]/branches: [develop]/' \
		"$_src_template" > "$_TD/repos/repo-c/.github/workflows/${_workflow_file}"
	_write_repos_json "$_TD" \
		"$(jq -n --arg p "$_TD/repos/repo-c" \
			'{initialized_repos: [{slug: "x/c", path: $p, local_only: false}]}')"
	_result=$(_classify_for_workflow "$_TD" "x/c" "$_wf_name")
	if [[ "$_result" == "CURRENT/CALLER" ]]; then
		_pass "${_wf_name}: branches:[develop] caller → CURRENT/CALLER (normalised branch)"
	else
		_fail "${_wf_name}: branches:[develop] caller → CURRENT/CALLER (normalised branch)" \
			"got: $_result"
	fi
	rm -rf "$_TD"

	# ── Scenario D: actually-drifted caller → DRIFTED/CALLER (true positive) ─
	_TD="$(mktemp -d)"
	_setup_fake_home "$_TD"
	mkdir -p "$_TD/repos/repo-d/.github/workflows"
	{
		cat "$_src_template"
		printf '\n# Local customisation — should trigger DRIFTED detection\n'
	} > "$_TD/repos/repo-d/.github/workflows/${_workflow_file}"
	_write_repos_json "$_TD" \
		"$(jq -n --arg p "$_TD/repos/repo-d" \
			'{initialized_repos: [{slug: "x/d", path: $p, local_only: false}]}')"
	_result=$(_classify_for_workflow "$_TD" "x/d" "$_wf_name")
	if [[ "$_result" == "DRIFTED/CALLER" ]]; then
		_pass "${_wf_name}: locally-modified caller → DRIFTED/CALLER (true positive)"
	else
		_fail "${_wf_name}: locally-modified caller → DRIFTED/CALLER (true positive)" \
			"got: $_result"
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

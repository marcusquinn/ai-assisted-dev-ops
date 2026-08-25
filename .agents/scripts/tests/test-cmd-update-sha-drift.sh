#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-cmd-update-sha-drift.sh — t2706 regression guard.
#
# Tests the stamp-drift detection wired into two headless update paths:
#
#   1. aidevops.sh::cmd_update — when local_hash == remote_hash (git already
#      up-to-date), the VERSION match branch now ALSO compares .deployed-sha.
#      Before t2706 it only checked VERSION, missing post-release script fixes.
#
#   2. .agents/scripts/auto-update-helper.sh::_cmd_check_stale_agent_redeploy
#      — was: SHA-256 of single sentinel file (gh-failure-miner-helper.sh).
#      After: .deployed-sha stamp compared to canonical HEAD + filtered diff.
#
# Production failure that motivated t2706 (GH#20323 blast radius):
#   PR #20323 (t2695) fixed gh search prs --headRefName in
#   pulse-batch-prefetch-helper.sh at 17:47 UTC. The fix lived in git for ~14h
#   while VERSION stayed at 3.8.91 (no release bump). Auto-update runs every
#   10 min but its sentinel check only watched gh-failure-miner-helper.sh, so
#   it never fired. The pulse kept hitting the bug ~every 4 minutes.
#
# Fix (t2706): both update paths now use the .deployed-sha stamp (written by
# .agents/scripts/setup/modules/agent-deploy.sh:612) and a git diff between deployed and HEAD,
# filtered to framework code paths. Catches ANY file drift, not just one.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKTREE_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

TEST_RED=$'\033[0;31m'
TEST_GREEN=$'\033[0;32m'
TEST_RESET=$'\033[0m'

TESTS_RUN=0
TESTS_FAILED=0

print_result() {
	local name="$1" rc="$2" extra="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$rc" -eq 0 ]]; then
		printf '%sPASS%s %s\n' "$TEST_GREEN" "$TEST_RESET" "$name"
	else
		printf '%sFAIL%s %s %s\n' "$TEST_RED" "$TEST_RESET" "$name" "$extra"
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Structural tests: verify the fix landed in both files.
# These catch regression from someone reverting the change or moving it to
# the wrong branch of the conditional (the kind of edit that would ship
# without functional test coverage because the integration test below
# requires a full sandbox git setup).
# ---------------------------------------------------------------------------

AIDEVOPS_SH="$WORKTREE_ROOT/aidevops.sh"
AUTO_UPDATE_SH="$WORKTREE_ROOT/.agents/scripts/auto-update-helper.sh"
AUTO_UPDATE_CHECK_SH="$WORKTREE_ROOT/.agents/scripts/auto-update-helper-check.sh"
UPDATE_CHECK_SH="$WORKTREE_ROOT/.agents/scripts/aidevops-update-check.sh"
UPDATE_LIB="$WORKTREE_ROOT/.agents/scripts/aidevops-cli/aidevops-update-lib.sh"

# Test 1: aidevops.sh cmd_update references .deployed-sha in the VERSION-match branch
if grep -q '\.deployed-sha' "$AIDEVOPS_SH" &&
	grep -q 't2706' "$AIDEVOPS_SH"; then
	print_result "aidevops.sh cmd_update has stamp-drift check (t2706 marker)" 0
else
	print_result "aidevops.sh cmd_update has stamp-drift check (t2706 marker)" 1 \
		"(expected .deployed-sha reference and t2706 marker)"
fi

if grep -q '_update_repo_verify_files_changed' "$UPDATE_LIB" &&
	grep -q 'skip_project_sync.*reconcile_repo_verify' "$AIDEVOPS_SH"; then
	print_result "lint reconciliation is changed-file gated and honours project-sync skip" 0
else
	print_result "lint reconciliation is changed-file gated and honours project-sync skip" 1 \
		"(expected changed-file helper and skip_project_sync gate)"
fi

# Test 2: aidevops.sh filters for framework code paths (skips docs-only drift)
if grep -q '\.agents/scripts/' "$AIDEVOPS_SH" &&
	grep -q 'has_code_drift' "$AIDEVOPS_SH"; then
	print_result "aidevops.sh filters for framework code paths" 0
else
	print_result "aidevops.sh filters for framework code paths" 1 \
		"(expected .agents/scripts/ case and has_code_drift variable)"
fi

# Test 2b: aidevops.sh uses the AI-session setup scope for update redeploys.
if grep -q -- '--stage ai-session' "$AIDEVOPS_SH" &&
	grep -q '_run_update_setup' "$AIDEVOPS_SH"; then
	print_result "aidevops.sh update uses incremental setup scope" 0
else
	print_result "aidevops.sh update uses incremental setup scope" 1 \
		"(expected _run_update_setup and --stage ai-session)"
fi

# Test 3: auto-update-helper.sh no longer uses single-sentinel SHA-256 check
# (The replacement was a functional upgrade: stamp-based diff catches any file.)
if grep -q 'gh-failure-miner-helper.sh' "$AUTO_UPDATE_SH" &&
	grep -q 'sentinel_repo' "$AUTO_UPDATE_SH"; then
	print_result "auto-update-helper.sh sentinel SHA-256 check replaced" 1 \
		"(found surviving sentinel references — fix was reverted?)"
else
	print_result "auto-update-helper.sh sentinel SHA-256 check replaced" 0
fi

# Test 4: auto-update-helper.sh uses .deployed-sha stamp
if grep -q '\.deployed-sha' "$AUTO_UPDATE_SH" &&
	grep -q 't2706' "$AUTO_UPDATE_SH"; then
	print_result "auto-update-helper.sh has stamp-drift check (t2706 marker)" 0
else
	print_result "auto-update-helper.sh has stamp-drift check (t2706 marker)" 1 \
		"(expected .deployed-sha reference and t2706 marker)"
fi

if grep -q 'merge-base --is-ancestor.*head_sha.*deployed_sha' "$AUTO_UPDATE_SH" &&
	grep -q 'merge-base --is-ancestor.*head_sha.*deployed_sha' "$AUTO_UPDATE_CHECK_SH"; then
	print_result "auto-update preserves deployed runtimes ahead of canonical HEAD" 0
else
	print_result "auto-update preserves deployed runtimes ahead of canonical HEAD" 1 \
		"(expected ancestry guard in orchestrator and check sub-library)"
fi

# Test 5: auto-update-helper.sh filters for framework code paths
if grep -q '\.agents/scripts/' "$AUTO_UPDATE_SH" &&
	grep -qE 'has_code_drift|filepath\)' "$AUTO_UPDATE_SH"; then
	print_result "auto-update-helper.sh filters for framework code paths" 0
else
	print_result "auto-update-helper.sh filters for framework code paths" 1 \
		"(expected .agents/scripts/ case and drift filter)"
fi

# Test 5b: session-start update checks use the AI-session incremental setup scope.
if grep -q -- '--stage ai-session' "$UPDATE_CHECK_SH" &&
	grep -q -- '--non-interactive' "$UPDATE_CHECK_SH"; then
	print_result "update-check script drift uses incremental setup with full fallback" 0
else
	print_result "update-check script drift uses incremental setup with full fallback" 1 \
		"(expected --stage ai-session and --non-interactive fallback)"
fi

# Test 5c: auto-update helper uses the AI-session incremental setup helper.
if grep -q '_run_setup_ai_session_with_fallback' "$AUTO_UPDATE_SH" &&
	grep -q -- '--stage ai-session' "$AUTO_UPDATE_SH"; then
	print_result "auto-update helper uses incremental setup helper" 0
else
	print_result "auto-update helper uses incremental setup helper" 1 \
		"(expected _run_setup_ai_session_with_fallback and --stage ai-session)"
fi

# ---------------------------------------------------------------------------
# Integration test: fake framework repo, stale stamp, verify setup.sh fires
# ---------------------------------------------------------------------------

TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT

SANDBOX_HOME="${TEST_ROOT}/home"
SANDBOX_REPO="${TEST_ROOT}/aidevops"
SANDBOX_AIDEVOPS="${SANDBOX_HOME}/.aidevops"
SETUP_CALLS_LOG="${TEST_ROOT}/setup_calls.log"

mkdir -p "$SANDBOX_HOME" "$SANDBOX_AIDEVOPS/agents"

# Build sandbox framework repo with a script change + docs-only commit
/usr/bin/git init -q "$SANDBOX_REPO" 2>/dev/null
/usr/bin/git -C "$SANDBOX_REPO" config user.email "test@test.local"
/usr/bin/git -C "$SANDBOX_REPO" config user.name "Test"
/usr/bin/git -C "$SANDBOX_REPO" config commit.gpgsign false

# Baseline — deployed state
mkdir -p "$SANDBOX_REPO/.agents/scripts"
printf '#!/usr/bin/env bash\necho v1\n' >"$SANDBOX_REPO/.agents/scripts/foo.sh"
printf 'v1\n' >"$SANDBOX_REPO/VERSION"
/usr/bin/git -C "$SANDBOX_REPO" add -A
/usr/bin/git -C "$SANDBOX_REPO" commit -qm "initial" 2>/dev/null
DEPLOYED_SHA=$(/usr/bin/git -C "$SANDBOX_REPO" rev-parse HEAD)

# Add a framework-code drift commit
printf '#!/usr/bin/env bash\necho v2\n' >"$SANDBOX_REPO/.agents/scripts/foo.sh"
/usr/bin/git -C "$SANDBOX_REPO" add -A
/usr/bin/git -C "$SANDBOX_REPO" commit -qm "update script" 2>/dev/null
HEAD_SHA=$(/usr/bin/git -C "$SANDBOX_REPO" rev-parse HEAD)

# Add a docs-only commit on top
mkdir -p "$SANDBOX_REPO/.agents/reference"
printf '# doc\n' >"$SANDBOX_REPO/.agents/reference/readme.md"
/usr/bin/git -C "$SANDBOX_REPO" add -A
/usr/bin/git -C "$SANDBOX_REPO" commit -qm "update docs" 2>/dev/null
HEAD_WITH_DOCS_SHA=$(/usr/bin/git -C "$SANDBOX_REPO" rev-parse HEAD)

# Add a setup.sh-only drift commit (per Gemini feedback on PR #20342:
# setup.sh drift must trigger redeploy because it controls what gets deployed).
printf '#!/usr/bin/env bash\necho setup v2\n' >"$SANDBOX_REPO/setup.sh"
/usr/bin/git -C "$SANDBOX_REPO" add -A
/usr/bin/git -C "$SANDBOX_REPO" commit -qm "update setup.sh" 2>/dev/null
HEAD_WITH_SETUP_DRIFT_SHA=$(/usr/bin/git -C "$SANDBOX_REPO" rev-parse HEAD)

# Add an aidevops.sh-only drift commit (per Gemini feedback on PR #20342:
# aidevops.sh is the deployed CLI entry point, drift must trigger redeploy).
printf '#!/usr/bin/env bash\necho aidevops v2\n' >"$SANDBOX_REPO/aidevops.sh"
/usr/bin/git -C "$SANDBOX_REPO" add -A
/usr/bin/git -C "$SANDBOX_REPO" commit -qm "update aidevops.sh" 2>/dev/null
HEAD_WITH_AIDEVOPS_DRIFT_SHA=$(/usr/bin/git -C "$SANDBOX_REPO" rev-parse HEAD)

# Add an intentional linked-worktree-style hotfix deployment ahead of the
# canonical HEAD, then return the sandbox checkout to the canonical commit.
printf '#!/usr/bin/env bash\necho hotfix\n' >"$SANDBOX_REPO/.agents/scripts/foo.sh"
/usr/bin/git -C "$SANDBOX_REPO" add -A
/usr/bin/git -C "$SANDBOX_REPO" commit -qm "active hotfix" 2>/dev/null
DEPLOYED_AHEAD_SHA=$(/usr/bin/git -C "$SANDBOX_REPO" rev-parse HEAD)
/usr/bin/git -C "$SANDBOX_REPO" checkout -q --detach "$HEAD_WITH_AIDEVOPS_DRIFT_SHA"

if [[ -z "$DEPLOYED_SHA" || -z "$HEAD_SHA" || -z "$HEAD_WITH_DOCS_SHA" ||
	-z "$HEAD_WITH_SETUP_DRIFT_SHA" || -z "$HEAD_WITH_AIDEVOPS_DRIFT_SHA" ||
	-z "$DEPLOYED_AHEAD_SHA" ]]; then
	printf '%sSETUP FAILED%s sandbox repo SHAs empty\n' "$TEST_RED" "$TEST_RESET"
	exit 1
fi

# Fake setup.sh records each invocation
FAKE_SETUP="${SANDBOX_REPO}/setup.sh"
printf '#!/usr/bin/env bash\nprintf "called %%s\n" "$$" >> "%s"\n' "$SETUP_CALLS_LOG" >"$FAKE_SETUP"
chmod +x "$FAKE_SETUP"

# Sync VERSION file to "current" so only the stamp/SHA triggers the redeploy
printf 'v1\n' >"$SANDBOX_AIDEVOPS/agents/VERSION"

# ---------------------------------------------------------------------------
# run_cmd_update_stamp_branch: extract just the stamp-check block from
# aidevops.sh cmd_update and execute it against the sandbox state.
#
# This tests the behaviour of the t2706 addition in isolation, without
# needing the full cmd_update flow (which depends on network calls and a
# full framework environment).
# ---------------------------------------------------------------------------
run_cmd_update_stamp_branch() {
	local stamp_content="${1:-}" head_sha="${2:-$HEAD_SHA}"

	if [[ -n "$stamp_content" ]]; then
		printf '%s\n' "$stamp_content" >"$SANDBOX_AIDEVOPS/.deployed-sha"
	else
		rm -f "$SANDBOX_AIDEVOPS/.deployed-sha"
	fi

	# Inline stamp check mirroring the t2706 addition in aidevops.sh cmd_update.
	# This is a structural copy, not a source reference, because the logic lives
	# inside a much larger function that is not safely sourceable.
	# Pattern updated per Gemini code-review on PR #20342 to match aidevops.sh
	# and auto-update-helper.sh (path filter + grep -q . + expanded path list).
	HOME="$SANDBOX_HOME" bash -c '
		set +e
		INSTALL_DIR="'"$SANDBOX_REPO"'"
		local_hash="'"$head_sha"'"
		stamp_file="$HOME/.aidevops/.deployed-sha"
		if [[ -f "$stamp_file" ]]; then
			deployed_sha=$(tr -d "[:space:]" <"$stamp_file" 2>/dev/null) || deployed_sha=""
			if [[ -n "$deployed_sha" && "$deployed_sha" != "$local_hash" ]]; then
				has_code_drift=0
				if /usr/bin/git -C "$INSTALL_DIR" diff --name-only "$deployed_sha" "$local_hash" -- \
					.agents/scripts/ .agents/agents/ .agents/workflows/ .agents/prompts/ .agents/hooks/ \
					setup.sh .agents/scripts/setup/modules/ aidevops.sh 2>/dev/null | grep -q .; then
					has_code_drift=1
				fi
				if [[ "$has_code_drift" -eq 1 ]]; then
					bash "$INSTALL_DIR/setup.sh" --stage ai-session >/dev/null 2>&1
				fi
			fi
		fi
	' 2>/dev/null
	return 0
}

count_setup_calls() {
	[[ -f "$SETUP_CALLS_LOG" ]] || { echo 0; return 0; }
	wc -l <"$SETUP_CALLS_LOG" | tr -d ' '
	return 0
}

run_auto_update_stale_check() {
	local stamp_content="$1"
	printf '%s\n' "$stamp_content" >"$SANDBOX_AIDEVOPS/.deployed-sha"
	HOME="$SANDBOX_HOME" bash -c '
		INSTALL_DIR="$1"
		LOG_FILE="$2"
		SCRIPT_DIR="${3%/*}"
		setup_calls_log="$4"
		source "$3"
		log_info() { return 0; }
		log_warn() { return 0; }
		log_error() { return 0; }
		_run_setup_ai_session_with_fallback() {
			printf "called\n" >>"$setup_calls_log"
			return 0
		}
		_cmd_check_stale_agent_redeploy v1
	' _ "$SANDBOX_REPO" "${TEST_ROOT}/auto-update-test.log" "$AUTO_UPDATE_CHECK_SH" "$SETUP_CALLS_LOG"
	return 0
}

# Test 6: no stamp file → no-op
rm -f "$SETUP_CALLS_LOG"
run_cmd_update_stamp_branch ""
if [[ "$(count_setup_calls)" -eq 0 ]]; then
	print_result "no-op when stamp file missing" 0
else
	print_result "no-op when stamp file missing" 1 "(setup.sh was called)"
fi

# Test 7: stamp == HEAD → no-op
rm -f "$SETUP_CALLS_LOG"
run_cmd_update_stamp_branch "$HEAD_SHA"
if [[ "$(count_setup_calls)" -eq 0 ]]; then
	print_result "no-op when stamp == HEAD" 0
else
	print_result "no-op when stamp == HEAD" 1 "(setup.sh was called)"
fi

# Test 8: stamp lags HEAD with code drift → setup.sh fires once
rm -f "$SETUP_CALLS_LOG"
run_cmd_update_stamp_branch "$DEPLOYED_SHA" "$HEAD_SHA"
if [[ "$(count_setup_calls)" -eq 1 ]]; then
	print_result "setup.sh fires when code drifts" 0
else
	print_result "setup.sh fires when code drifts" 1 \
		"(expected 1 call, got $(count_setup_calls))"
fi

# Test 9: stamp lags HEAD but only docs drifted → no-op
rm -f "$SETUP_CALLS_LOG"
run_cmd_update_stamp_branch "$HEAD_SHA" "$HEAD_WITH_DOCS_SHA"
if [[ "$(count_setup_calls)" -eq 0 ]]; then
	print_result "no-op when drift is docs-only" 0
else
	print_result "no-op when drift is docs-only" 1 \
		"(setup.sh was called — docs-only drift should skip)"
fi

# Test 10: stamp lags HEAD with setup.sh drift → setup.sh fires
# (Gemini PR #20342 feedback: setup.sh changes must trigger redeploy.)
rm -f "$SETUP_CALLS_LOG"
run_cmd_update_stamp_branch "$HEAD_WITH_DOCS_SHA" "$HEAD_WITH_SETUP_DRIFT_SHA"
if [[ "$(count_setup_calls)" -eq 1 ]]; then
	print_result "setup.sh fires when setup.sh itself drifts" 0
else
	print_result "setup.sh fires when setup.sh itself drifts" 1 \
		"(expected 1 call, got $(count_setup_calls))"
fi

# Test 11: stamp lags HEAD with aidevops.sh drift → setup.sh fires
# (Gemini PR #20342 feedback: aidevops.sh is deployed, drift must trigger redeploy.)
rm -f "$SETUP_CALLS_LOG"
run_cmd_update_stamp_branch "$HEAD_WITH_SETUP_DRIFT_SHA" "$HEAD_WITH_AIDEVOPS_DRIFT_SHA"
if [[ "$(count_setup_calls)" -eq 1 ]]; then
	print_result "setup.sh fires when aidevops.sh drifts" 0
else
	print_result "setup.sh fires when aidevops.sh drifts" 1 \
		"(expected 1 call, got $(count_setup_calls))"
fi

# Test 12: an intentionally deployed hotfix ahead of canonical HEAD must not be
# replaced by the unattended same-version drift reconciler.
rm -f "$SETUP_CALLS_LOG"
run_auto_update_stale_check "$DEPLOYED_AHEAD_SHA"
if [[ "$(count_setup_calls)" -eq 0 ]]; then
	print_result "auto-update preserves an ahead deployed runtime" 0
else
	print_result "auto-update preserves an ahead deployed runtime" 1 \
		"(setup.sh was called for an intentional hotfix deployment)"
fi

# Test 13: the ancestry guard must retain the original stale-runtime repair.
rm -f "$SETUP_CALLS_LOG"
run_auto_update_stale_check "$DEPLOYED_SHA"
if [[ "$(count_setup_calls)" -eq 1 ]]; then
	print_result "auto-update still repairs a deployed runtime behind HEAD" 0
else
	print_result "auto-update still repairs a deployed runtime behind HEAD" 1 \
		"(expected 1 call, got $(count_setup_calls))"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
if [[ "$TESTS_FAILED" -eq 0 ]]; then
	printf '%sAll %d tests passed.%s\n' "$TEST_GREEN" "$TESTS_RUN" "$TEST_RESET"
	exit 0
else
	printf '%s%d of %d tests FAILED.%s\n' "$TEST_RED" "$TESTS_FAILED" "$TESTS_RUN" "$TEST_RESET"
	exit 1
fi

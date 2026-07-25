#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

repo_root=$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)
runner="$repo_root/.agents/tools/autoagent/autoagent.md"
safety="$repo_root/.agents/tools/autoagent/autoagent/safety.md"
hypothesis_types="$repo_root/.agents/tools/autoagent/autoagent/hypothesis-types.md"
template="$repo_root/.agents/templates/autoagent-program-template.md"
research_template="$repo_root/.agents/templates/research-program-template.md"
command_doc="$repo_root/.agents/scripts/commands/autoagent.md"
workflow_doc="$repo_root/.agents/workflows/autoagent.md"
autoresearch_workflow="$repo_root/.agents/workflows/autoresearch.md"
program="$repo_root/todo/research/autoagent-awards-session-reliability.md"
agent_optimization_program="$repo_root/todo/research/agent-optimization.md"
metric_helper="$repo_root/.agents/scripts/autoagent-metric-helper.sh"
evaluation="$repo_root/.agents/tools/autoagent/autoagent/evaluation.md"
signal_mining="$repo_root/.agents/tools/autoagent/autoagent/signal-mining.md"
autoresearch_runner="$repo_root/.agents/tools/autoresearch/autoresearch.md"
autoresearch_optimization="$repo_root/.agents/tools/autoresearch/autoresearch/agent-optimization.md"
autoresearch_loop="$repo_root/.agents/tools/autoresearch/autoresearch/loop.md"
shipped_suite="$repo_root/.agents/tests/agents-md-knowledge.json"

assert_contains() {
	local needle="$1"
	local file="$2"

	if ! grep -Fq -- "$needle" "$file"; then
		printf 'Missing contract text %q in %s\n' "$needle" "$file" >&2
		return 1
	fi

	return 0
}

assert_not_contains() {
	local needle="$1"
	local file="$2"

	if grep -Fq -- "$needle" "$file"; then
		printf 'Forbidden contract text %q found in %s\n' "$needle" "$file" >&2
		return 1
	fi

	return 0
}

assert_constraint_section() {
	local file="$1"
	local bullets
	local bullet

	bullets=$(awk '
		/^## Constraints$/ { in_constraints=1; next }
		in_constraints && /^## / { exit }
		in_constraints && /^- / { print }
	' "$file")

	if [[ -z "$bullets" ]]; then
		printf 'No constraint bullets found in %s\n' "$file" >&2
		return 1
	fi

	while IFS= read -r bullet; do
		if ! grep -Eq "^- [^\`]*\`[^\`]+\`[^\`]*$" <<<"$bullet"; then
			printf 'Invalid constraint bullet in %s: %s\n' "$file" "$bullet" >&2
			return 1
		fi
	done <<<"$bullets"

	return 0
}

for section in "Signal Sources" "Hypothesis Types" "Safety" "Evaluation"; do
	assert_contains "## $section" "$runner"
	assert_contains "## $section" "$template"
done

assert_contains "Fail closed before setup or command execution" "$runner"
assert_contains "accept only literal \`true\` or \`false\`" "$runner"
assert_contains "Require each signal key exactly once" "$runner"
assert_contains "Require each hypothesis key exactly once" "$runner"
assert_contains "only \`in-repo\`, \`cross-repo\`, or \`standalone\`" "$runner"
assert_contains "only the provider-agnostic workload tiers \`simple\`, \`standard\`, or" "$runner"
assert_contains "Each bullet must contain exactly" "$runner"
assert_contains "one non-empty inline-code span" "$runner"
assert_contains "Never execute the whole Markdown bullet" "$runner"
assert_contains "Broad target patterns may overlap" "$runner"
assert_contains "Reject an empty resulting set" "$runner"
assert_contains "every target-matched elevated-only file" "$runner"
assert_contains "required_improvements:" "$runner"
assert_contains "AIDEVOPS_WORKTREE_BASE_DIR" "$runner"
assert_contains "SOURCE_PROGRAM" "$runner"
assert_contains "SOURCE_PROGRAM_SHA256" "$runner"
assert_contains "PROGRAM_FILE" "$runner"
assert_contains "copy the already" "$runner"
assert_contains "show-ref --verify --quiet \"refs/heads/\$BRANCH\"" "$runner"
assert_contains "git -C \"\$REPO_ROOT\" worktree add \"\$WORKTREE_PATH\" \"\$BRANCH\"" "$runner"
assert_contains "validate its committed \`PROGRAM_REL\` and \`RESULTS_REL\`" "$runner"
assert_contains "Never use \`-b\` for an existing branch" "$runner"
assert_contains "safe slug pattern" "$runner"
assert_contains "git check-ref-format --branch" "$runner"
assert_contains "Reject protected branch names" "$runner"
assert_contains "immutable configuration" "$runner"
assert_contains "differing source baseline is allowed" "$runner"
assert_contains "RESULTS_FILE = \"\$WORKTREE_PATH/" "$runner"
assert_contains "checkpoint_candidate_diff" "$runner"
assert_contains "remove_owned_candidate_worktree" "$runner"
assert_contains 'commit_runner_state("constraint_fail")' "$runner"
assert_contains 'commit_runner_state("crash")' "$runner"
assert_contains 'commit_runner_state("keep")' "$runner"
assert_contains 'commit_runner_state("discard")' "$runner"
assert_contains 'commit_runner_state("baseline")' "$runner"
assert_contains 'commit_runner_state("baseline_error")' "$runner"
assert_contains "exact runner-owned state paths" "$runner"
assert_contains "verify the worktree is clean" "$runner"
assert_contains "If any path is outside the" "$runner"
assert_contains "Never reset, stash, or clean" "$runner"
assert_contains "cross-file iteration consistency" "$runner"
assert_contains "candidate code commit and experiment-worktree fast-forward happen" "$runner"
assert_contains "worktree add --detach" "$runner"
assert_contains "create_owned_detached_candidate_worktree" "$runner"
assert_contains "Never create a" "$runner"
assert_contains "per-iteration branch or ref" "$runner"
assert_contains "next iteration starts clean" "$runner"
assert_contains "--body-file" "$runner"
assert_not_contains "git reset --hard" "$runner"
assert_not_contains "git reset --hard" "$safety"
assert_not_contains "--body \"\$(" "$runner"
assert_contains "workflow-optimization" "$command_doc"
assert_contains "autoagent-programs" "$command_doc"
assert_contains "AIDEVOPS_TEMP_DIR:-\$HOME/.aidevops/.agent-workspace/tmp}/autoagent-programs" "$command_doc"
assert_contains "SOURCE_PROGRAM=\"\$AUTOAGENT_PROGRAM_DIR/autoagent-\${PROGRAM_NAME}.md\"" "$command_doc"
assert_contains "Existing \`--program <path>\` inputs remain supported" "$command_doc"
assert_contains "--program \"\$SOURCE_PROGRAM\"" "$command_doc"
assert_contains "QUEUED_PROGRAM=\"todo/research/autoagent-\${PROGRAM_NAME}.md\"" "$command_doc"
assert_contains "normal pre-edit linked-worktree" "$command_doc"
assert_contains "program: todo/research/autoagent-{name}.md" "$command_doc"
assert_not_contains "program: {SOURCE_PROGRAM}" "$command_doc"
assert_not_contains "Write to \`todo/research/autoagent-{name}.md\`" "$command_doc"
assert_not_contains "workflow-alignment" "$command_doc"
assert_contains '.agents/AGENTS.md' "$safety"
assert_contains "| \`prompts/build.txt\` | Near-empty compatibility placeholder" "$safety"
assert_contains "is canonical; \`prompts/build.txt\` remains never-modify" "$safety"
assert_contains ".agents/AGENTS.md\` is canonical" "$template"
assert_not_contains "prompts/build.txt\` (non-security sections)" "$safety"
assert_not_contains "non-security \`prompts/build.txt\`" "$template"
assert_contains "listed in \`require_review\`" "$safety"
assert_contains "## Instruction-Semantic Preservation Gate" "$safety"
assert_contains ".agents/tools/build-agent/agent-review.md" "$safety"
assert_contains "defaults to preservation" "$safety"
assert_contains "record \`provenance_fail\`" "$safety"
assert_contains "prepare_instruction_review" "$runner"
assert_contains "verify_instruction_semantic_preservation" "$runner"
assert_contains '"provenance_fail"' "$runner"
assert_contains "\`provenance_fail\`" "$evaluation"
assert_contains "## Instruction-Semantic Preservation Gate" "$autoresearch_optimization"
assert_contains ".agents/tools/build-agent/agent-review.md" "$autoresearch_optimization"
assert_contains "defaults to preservation" "$autoresearch_optimization"
assert_contains "prepare_instruction_review" "$autoresearch_loop"
assert_contains "verify_instruction_semantic_preservation" "$autoresearch_loop"
assert_contains '"provenance_fail"' "$autoresearch_loop"
assert_contains ".agents/tools/build-agent/agent-review.md" "$autoresearch_runner"
assert_not_contains "Simplification is always valid" "$hypothesis_types"
assert_not_contains "Equal-or-better with less is always a win" "$hypothesis_types"
assert_not_contains "Delete rules that don't affect any test outcome" "$autoresearch_optimization"
assert_not_contains "Remove anything that doesn't affect the metric" "$autoresearch_optimization"
assert_not_contains "equal-or-better with less code is a win" "$autoresearch_loop"
assert_contains "exactly one" "$template"
assert_not_contains "- Tests must pass: autoagent-metric-helper.sh" "$template"
assert_contains ".agents/tests/agents-md-knowledge.json" "$template"
assert_contains ".agents/tests/agents-md-knowledge.json" "$safety"
assert_contains ".agents/tests/agents-md-knowledge.json" "$signal_mining"
assert_contains ".agents/tests/agents-md-knowledge.json" "$evaluation"
assert_contains "DEFAULT_SUITE=\".agents/tests/agents-md-knowledge.json\"" "$metric_helper"
assert_not_contains "agent-test-helper.sh run --suite" "$safety"
assert_not_contains "agent-test-helper.sh run --suite" "$signal_mining"
assert_not_contains "autoagent-metric-helper.sh run" "$evaluation"
assert_not_contains "--suite agent-optimization" "$safety"
assert_not_contains "--suite agent-optimization" "$signal_mining"
assert_not_contains "build.txt" "$evaluation"
assert_not_contains "build.txt" "$signal_mining"
assert_not_contains "build.txt" "$command_doc"
assert_not_contains "build.txt" "$workflow_doc"
assert_not_contains "--baseline-file /tmp/my-baseline.json" "$metric_helper"
assert_contains "AIDEVOPS_TEMP_DIR:-\$HOME/.aidevops/.agent-workspace/tmp" "$metric_helper"
assert_contains "return \"\$status\"" "$metric_helper"
assert_contains 'if(s<0)s=0; if(s>1)s=1; s\n' "$metric_helper"
assert_contains "autoagent-pr-bodies" "$runner"
assert_not_contains "PR_BODY_FILE=\"\$WORKTREE_PATH/" "$runner"
assert_contains "verify WORKTREE_PATH is clean" "$runner"
assert_contains "No owned-state file may be written" "$runner"
assert_contains "run_pre_edit_check(CANDIDATE_PATH)" "$runner"
assert_contains "validate_candidate_paths(CANDIDATE_PATH, ALLOWED_FILES)" "$runner"
assert_contains 'commit_runner_state("review_required")' "$runner"
assert_contains "Headless runs must never" "$runner"
assert_contains "auto-approve" "$runner"
assert_contains "goal_met(BEST_METRIC, GOAL, METRIC_DIR)" "$evaluation"
assert_contains "| \`session_miner\` | Session miner data, error-feedback patterns, instruction candidates |" "$signal_mining"
assert_contains "| \`comprehension\` | Comprehension test results |" "$signal_mining"
assert_contains "| \`linters\` | Linter violations |" "$signal_mining"
assert_not_contains "| \`session-miner\` | Session miner data |" "$signal_mining"
assert_not_contains "| \`all\` | All sources (default) |" "$signal_mining"
assert_contains "researcher: standard" "$template"
assert_contains "researcher: standard" "$research_template"
assert_contains "evaluator: simple" "$research_template"
assert_contains "target: standard" "$research_template"
assert_contains "Researcher workload tier" "$workflow_doc"
assert_contains "researcher=standard" "$autoresearch_workflow"
assert_contains "researcher: standard" "$program"
assert_contains "researcher: standard" "$agent_optimization_program"
assert_not_contains "researcher: sonnet" "$template"
assert_not_contains "researcher: sonnet" "$research_template"
assert_not_contains "researcher=sonnet" "$autoresearch_workflow"

if [[ ! -f "$shipped_suite" ]]; then
	printf 'Shipped Autoagent suite is missing: %s\n' "$shipped_suite" >&2
	exit 1
fi

if grep -Eq '^(files|require_review):.*prompts/build\.txt' "$template"; then
	printf 'Template suggests targeting the prompts/build.txt placeholder\n' >&2
	exit 1
fi

assert_constraint_section "$template"
assert_constraint_section "$program"

if ! cmp -s "$command_doc" "$workflow_doc"; then
	printf 'Autoagent command and workflow documents differ\n' >&2
	exit 1
fi

printf 'Autoagent contract checks passed\n'

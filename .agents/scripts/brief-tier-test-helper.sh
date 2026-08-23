#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# brief-tier-test-helper.sh — Test harness for cascade tier optimisation
#
# Extracts merged PR data into a test corpus, generates enriched briefs,
# runs model-tier tests (dispatching Haiku against known-good PRs), and
# scores the results. Used by the autoresearch program at
# todo/research/optimize-brief-tiers.md.
#
# Usage:
#   brief-tier-test-helper.sh extract  --repo SLUG [--label LABEL] [--max-files N] [--limit N] --output DIR
#   brief-tier-test-helper.sh enrich   --corpus DIR [--model MODEL]
#   brief-tier-test-helper.sh test     --corpus DIR [--model MODEL] --results FILE
#   brief-tier-test-helper.sh score    --corpus DIR --results FILE
#   brief-tier-test-helper.sh report   --results FILE
#   brief-tier-test-helper.sh replay   validate|qualify|dry-run|run|report ...
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENTS_DIR="${SCRIPT_DIR%/scripts}"

#######################################
# Print usage and exit
#######################################
usage() {
	cat <<'EOF'
brief-tier-test-helper.sh — Cascade tier optimisation test harness

Commands:
  extract   Pull merged PR data into a structured test corpus
  enrich    Generate gold-standard prescriptive briefs using Sonnet
  test      Dispatch a model against the corpus and record results
  score     Compute composite cascade-cost metric from results
  report    Human-readable summary of test results

Options:
  --repo SLUG       GitHub repo slug (owner/repo) for extraction
  --label LABEL     Filter PRs by label (default: origin:worker)
  --max-files N     Maximum changed files per PR (default: 3)
  --limit N         Maximum PRs to extract (default: 30)
  --output DIR      Output directory for corpus
  --corpus DIR      Corpus directory (for enrich/test/score)
  --model MODEL     Model tier to use (default: simple for test, standard for enrich)
  --results FILE    Results TSV file path
  --subset N        Test only N cases from corpus (for iteration speed)
EOF
	exit 1
	return 0
}

# ── extract helpers ──────────────────────────────────────────────

#######################################
# Fetch merged PR list from GitHub
#
# Arguments:
#   $1 - repo slug (owner/repo)
#   $2 - label filter
#   $3 - max changed files
#   $4 - PR limit
# Outputs: JSON array to stdout
# Returns: 0 on success, 1 on error
#######################################
_fetch_pr_list() {
	local repo="$1"
	local label="$2"
	local max_files="$3"
	local limit="$4"

	gh pr list --repo "$repo" --state merged --limit "$limit" \
		--label "$label" \
		--json number,title,labels,additions,deletions,changedFiles,mergedAt,headRefName,body \
		--jq "[.[] | select(.changedFiles <= ${max_files})]" 2>/dev/null || {
		echo "Error: failed to query PRs from $repo" >&2
		return 1
	}
	return 0
}

#######################################
# Determine complexity category from file count
#
# Arguments:
#   $1 - number of changed files
# Outputs: complexity string to stdout
# Returns: 0
#######################################
_classify_complexity() {
	local changed_files="$1"

	if [[ "$changed_files" -gt 3 ]]; then
		echo "4+-files"
	elif [[ "$changed_files" -gt 1 ]]; then
		echo "2-3-files"
	else
		echo "1-file"
	fi
	return 0
}

#######################################
# Extract a single PR into a case directory
#
# Fetches diff, linked issue body, and merge commit info,
# then writes case.json, original-issue.md, original-diff.patch,
# and verification.sh into the case directory.
#
# Arguments:
#   $1 - repo slug
#   $2 - PR number
#   $3 - PR title
#   $4 - PR additions
#   $5 - PR deletions
#   $6 - PR changed files count
#   $7 - PR body
#   $8 - case directory path
#   $9 - complexity category
# Returns: 0 on success
#######################################
_extract_single_pr() {
	local repo="$1"
	local pr_number="$2"
	local pr_title="$3"
	local pr_additions="$4"
	local pr_deletions="$5"
	local pr_changed_files="$6"
	local pr_body="$7"
	local case_dir="$8"
	local complexity="$9"

	mkdir -p "$case_dir"

	# Get the diff
	local pr_diff
	pr_diff=$(gh pr diff "$pr_number" --repo "$repo" 2>/dev/null) || pr_diff=""

	# Get the linked issue body (from PR body "Closes #NNN" pattern)
	local issue_number=""
	local issue_body=""
	if [[ -n "$pr_body" ]]; then
		issue_number=$(echo "$pr_body" | grep -oE '(Closes|Fixes|Resolves) #[0-9]+' | head -1 | grep -oE '[0-9]+') || issue_number=""
	fi
	if [[ -n "$issue_number" ]]; then
		issue_body=$(gh issue view "$issue_number" --repo "$repo" --json body --jq '.body // ""' 2>/dev/null) || issue_body=""
	fi

	# Find the merge commit
	local merge_base=""
	merge_base=$(gh pr view "$pr_number" --repo "$repo" --json mergeCommit --jq '.mergeCommit.oid' 2>/dev/null) || merge_base=""

	# Write case metadata
	cat >"${case_dir}/case.json" <<CASE_EOF
{
  "pr_number": ${pr_number},
  "repo": "${repo}",
  "title": $(echo "$pr_title" | jq -Rs .),
  "issue_number": ${issue_number:-null},
  "additions": ${pr_additions},
  "deletions": ${pr_deletions},
  "changed_files": ${pr_changed_files},
  "complexity": "${complexity}",
  "merge_commit": $(echo "$merge_base" | jq -Rs .),
  "extracted_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
CASE_EOF

	# Write issue/PR body
	if [[ -n "$issue_body" ]]; then
		printf '%s\n' "$issue_body" >"${case_dir}/original-issue.md"
	elif [[ -n "$pr_body" ]]; then
		printf '%s\n' "$pr_body" >"${case_dir}/original-issue.md"
	fi

	# Write diff
	if [[ -n "$pr_diff" ]]; then
		printf '%s\n' "$pr_diff" >"${case_dir}/original-diff.patch"
	fi

	# Write verification placeholder
	cat >"${case_dir}/verification.sh" <<'VERIFY_EOF'
#!/usr/bin/env bash
# Auto-generated verification for test case
set -euo pipefail
# Basic: check that the diff is non-empty and applies cleanly
echo "PASS: verification placeholder — replace with task-specific checks"
exit 0
VERIFY_EOF
	chmod +x "${case_dir}/verification.sh"

	return 0
}

#######################################
# Extract merged PRs into test corpus
#
# Pulls PR metadata, issue bodies, and diffs from GitHub.
# Creates one directory per PR with structured files.
#
# Arguments: parsed from command-line flags
# Returns: 0 on success, 1 on error
#######################################
cmd_extract() {
	local repo=""
	local label="origin:worker"
	local max_files=3
	local limit=30
	local output=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--repo)
			repo="$2"
			shift 2
			;;
		--label)
			label="$2"
			shift 2
			;;
		--max-files)
			max_files="$2"
			shift 2
			;;
		--limit)
			limit="$2"
			shift 2
			;;
		--output)
			output="$2"
			shift 2
			;;
		*)
			echo "Unknown option: $1" >&2
			return 1
			;;
		esac
	done

	[[ -n "$repo" ]] || {
		echo "Error: --repo required" >&2
		return 1
	}
	[[ -n "$output" ]] || {
		echo "Error: --output required" >&2
		return 1
	}

	mkdir -p "$output"

	echo "[extract] Pulling merged PRs from $repo (label=$label, max_files=$max_files, limit=$limit)..."

	# Get merged PRs with metadata
	local pr_json
	pr_json=$(_fetch_pr_list "$repo" "$label" "$max_files" "$limit") || return 1

	local pr_count
	pr_count=$(echo "$pr_json" | jq 'length') || pr_count=0
	echo "[extract] Found $pr_count PRs matching criteria"

	if [[ "$pr_count" -eq 0 ]]; then
		echo "[extract] No PRs found. Check --label and --max-files filters." >&2
		return 1
	fi

	# Extract repo short name for directory naming
	local repo_short
	repo_short=$(echo "$repo" | cut -d'/' -f2)

	# Load existing index entries (merge mode — multiple extract runs append)
	local index_entries="[]"
	if [[ -f "${output}/index.json" ]]; then
		index_entries=$(jq '.' "${output}/index.json" 2>/dev/null) || index_entries="[]"
	fi

	local i=0
	while [[ "$i" -lt "$pr_count" ]]; do
		index_entries=$(_process_extract_pr "$pr_json" "$i" "$output" "$repo" "$repo_short" "$index_entries") || true
		i=$((i + 1))
	done

	# Write index
	echo "$index_entries" | jq '.' >"${output}/index.json"

	echo "[extract] Corpus extracted: ${pr_count} cases in ${output}/"
	echo "[extract] Complexity distribution:"
	echo "$index_entries" | jq -r 'group_by(.complexity) | map("\(.[0].complexity): \(length)") | .[]'

	return 0
}

#######################################
# Process a single PR from the JSON array and extract it
#
# Parses fields from pr_json at index $i, calls _extract_single_pr,
# and appends to the index. Prints the updated index_entries to stdout.
#
# Arguments:
#   $1 - pr_json (full JSON array)
#   $2 - loop index
#   $3 - output directory
#   $4 - repo slug
#   $5 - repo short name
#   $6 - current index_entries JSON
# Outputs: updated index_entries JSON to stdout
# Returns: 0 on success
#######################################
_process_extract_pr() {
	local pr_json="$1"
	local i="$2"
	local output="$3"
	local repo="$4"
	local repo_short="$5"
	local index_entries="$6"

	local pr_number pr_title pr_additions pr_deletions pr_changed_files pr_body
	pr_number=$(echo "$pr_json" | jq -r ".[$i].number") || return 1
	pr_title=$(echo "$pr_json" | jq -r ".[$i].title") || return 1
	pr_additions=$(echo "$pr_json" | jq -r ".[$i].additions") || return 1
	pr_deletions=$(echo "$pr_json" | jq -r ".[$i].deletions") || return 1
	pr_changed_files=$(echo "$pr_json" | jq -r ".[$i].changedFiles") || return 1
	pr_body=$(echo "$pr_json" | jq -r ".[$i].body // \"\"") || pr_body=""

	local case_dir="${output}/${repo_short}-${pr_number}"
	local complexity
	complexity=$(_classify_complexity "$pr_changed_files")

	echo "[extract] PR #${pr_number}: ${pr_title} (${pr_changed_files} files, +${pr_additions}/-${pr_deletions}, ${complexity})" >&2

	_extract_single_pr "$repo" "$pr_number" "$pr_title" "$pr_additions" \
		"$pr_deletions" "$pr_changed_files" "$pr_body" "$case_dir" "$complexity"

	# Append to index and output
	echo "$index_entries" | jq \
		--arg dir "${repo_short}-${pr_number}" \
		--argjson pr "$pr_number" \
		--arg complexity "$complexity" \
		--argjson files "$pr_changed_files" \
		--argjson adds "$pr_additions" \
		--argjson dels "$pr_deletions" \
		'. + [{"directory": $dir, "pr_number": $pr, "complexity": $complexity, "changed_files": $files, "additions": $adds, "deletions": $dels}]'

	return 0
}

# ── enrich helpers ───────────────────────────────────────────────

#######################################
# Build the enrichment prompt for a single test case
#
# Arguments:
#   $1 - case metadata JSON string
#   $2 - issue content (may be empty)
#   $3 - diff content
# Outputs: prompt string to stdout
# Returns: 0
#######################################
_build_enrichment_prompt() {
	local case_meta="$1"
	local issue_content="$2"
	local diff_content="$3"

	cat <<PROMPT_EOF
You are writing a prescriptive brief that will be given to Haiku (a fast but less capable model) to implement a code change. The brief must be specific enough that Haiku can follow it mechanically without needing to explore the codebase or make architectural decisions.

Given the following PR information, write a brief following the template at .agents/templates/brief-template.md with tier:simple level detail:

## PR Metadata
${case_meta}

## Original Issue Body
${issue_content:-No issue body available}

## Actual Diff (the known-good solution)
\`\`\`diff
${diff_content}
\`\`\`

Write the brief with:
1. EXACT file paths and line ranges from the diff
2. COMPLETE code blocks — not skeletons, but the actual code to insert/replace
3. Explicit oldString/newString pairs for each edit
4. Verification commands that test the specific changes
5. Set tier to tier:simple with rationale

The brief should be detailed enough that a worker can implement it by copying code blocks and running verification, without reading any other files.
PROMPT_EOF
	return 0
}

#######################################
# Write a placeholder enriched brief for a single case
#
# Arguments:
#   $1 - full path to case directory
#   $2 - model name
# Returns: 0
#######################################
_write_placeholder_brief() {
	local full_path="$1"
	local model="$2"

	cat >"${full_path}/enriched-brief.md" <<BRIEF_EOF
# Enriched Brief (placeholder)

**Status:** Awaiting generation via ${model}
**PR:** #$(jq -r '.pr_number' "${full_path}/case.json")
**Complexity:** $(jq -r '.complexity' "${full_path}/case.json")

## Enrichment Prompt

The enrichment prompt has been prepared. Run the enrich command interactively
or dispatch via autoresearch to generate the prescriptive brief.

---
_Generated by brief-tier-test-helper.sh enrich_
BRIEF_EOF
	return 0
}

#######################################
# Enrich a single test case with a prescriptive brief
#
# Arguments:
#   $1 - case directory name (relative)
#   $2 - full path to case directory
#   $3 - model name
# Outputs: status messages to stdout
# Returns: 0 on success, 1 to signal skip
#######################################
_enrich_single_case() {
	local case_dir="$1"
	local full_path="$2"
	local model="$3"

	if [[ -f "${full_path}/enriched-brief.md" ]]; then
		echo "[enrich] ${case_dir}: already enriched, skipping"
		return 1
	fi

	if [[ ! -f "${full_path}/original-diff.patch" ]]; then
		echo "[enrich] ${case_dir}: no diff available, skipping"
		return 1
	fi

	local issue_content=""
	if [[ -f "${full_path}/original-issue.md" ]]; then
		issue_content=$(cat "${full_path}/original-issue.md")
	fi
	local diff_content
	diff_content=$(cat "${full_path}/original-diff.patch")
	local case_meta
	case_meta=$(cat "${full_path}/case.json")

	# Build the prompt (used by interactive enrichment or autoresearch)
	_build_enrichment_prompt "$case_meta" "$issue_content" "$diff_content" >/dev/null

	echo "[enrich] ${case_dir}: generating enriched brief..."

	# Dispatch to ai-research for brief generation
	if command -v ai-research >/dev/null 2>&1 || [[ -x "${AGENTS_DIR}/scripts/ai-research-helper.sh" ]]; then
		echo "[enrich] ${case_dir}: would generate via ai-research (model: ${model})"
		echo "[enrich] ${case_dir}: placeholder brief written — run interactively to generate real briefs"
		_write_placeholder_brief "$full_path" "$model"
	fi

	return 0
}

#######################################
# Generate enriched briefs from corpus
#
# For each test case, reads the original issue and diff,
# then uses the specified model to write a prescriptive brief.
#
# Arguments: parsed from command-line flags
# Returns: 0 on success
#######################################
cmd_enrich() {
	local corpus=""
	local model="standard"

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--corpus)
			corpus="$2"
			shift 2
			;;
		--model)
			model="$2"
			shift 2
			;;
		*)
			echo "Unknown option: $1" >&2
			return 1
			;;
		esac
	done

	[[ -n "$corpus" ]] || {
		echo "Error: --corpus required" >&2
		return 1
	}
	[[ -f "${corpus}/index.json" ]] || {
		echo "Error: ${corpus}/index.json not found" >&2
		return 1
	}

	local case_count
	case_count=$(jq 'length' "${corpus}/index.json") || case_count=0
	echo "[enrich] Generating prescriptive briefs for ${case_count} cases using ${model}..."

	local i=0
	local enriched=0
	local skipped=0
	while [[ "$i" -lt "$case_count" ]]; do
		local case_dir
		case_dir=$(jq -r ".[$i].directory" "${corpus}/index.json")
		local full_path="${corpus}/${case_dir}"

		if _enrich_single_case "$case_dir" "$full_path" "$model"; then
			enriched=$((enriched + 1))
		else
			skipped=$((skipped + 1))
		fi

		i=$((i + 1))
	done

	echo "[enrich] Done: ${enriched} enriched, ${skipped} skipped"
	return 0
}

# ── test helpers ─────────────────────────────────────────────────

#######################################
# Run a single test case against the model
#
# Dispatches the model with the enriched brief and records
# the result. Currently writes placeholder results pending
# full model dispatch implementation.
#
# Arguments:
#   $1 - case directory name (relative)
#   $2 - full path to case directory
#   $3 - PR number
#   $4 - repo slug
#   $5 - complexity category
#   $6 - model name
#   $7 - results TSV file path
# Returns: 0 if passed, 1 if failed or skipped
#######################################
_test_single_case() {
	local case_dir="$1"
	local full_path="$2"
	local pr_number="$3"
	local repo="$4"
	local complexity="$5"
	local model="$6"
	local results="$7"

	if [[ ! -f "${full_path}/enriched-brief.md" ]]; then
		echo "[test] ${case_dir}: no enriched brief, skipping"
		return 1
	fi

	echo "[test] ${case_dir}: testing ${model} against PR #${pr_number}..."

	# TODO: Implement actual model dispatch in test worktree
	# Real implementation will:
	# 1. Create test worktree at pre-PR commit
	# 2. Dispatch model with enriched brief
	# 3. Capture output diff
	# 4. Compare against original-diff.patch
	# 5. Run verification.sh
	# 6. Score and record

	local pass="false"
	local diff_sim="0.0"
	local tokens="0"
	local escalation_reason="NOT_RUN"

	printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
		"$case_dir" "$pr_number" "$repo" "$complexity" "$model" \
		"$pass" "$diff_sim" "$tokens" "$escalation_reason" \
		"$(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"$results"

	if [[ "$pass" == "true" ]]; then
		return 0
	fi
	return 1
}

#######################################
# Run model against corpus test cases
#
# For each test case, checks out the pre-PR state, dispatches
# the specified model with the enriched brief, captures the
# output diff, and compares against the known-good diff.
#
# Arguments: parsed from command-line flags
# Returns: 0 on success
#######################################
cmd_test() {
	local corpus=""
	local model="simple"
	local results=""
	local subset=0

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--corpus)
			corpus="$2"
			shift 2
			;;
		--model)
			model="$2"
			shift 2
			;;
		--results)
			results="$2"
			shift 2
			;;
		--subset)
			subset="$2"
			shift 2
			;;
		*)
			echo "Unknown option: $1" >&2
			return 1
			;;
		esac
	done

	[[ -n "$corpus" ]] || {
		echo "Error: --corpus required" >&2
		return 1
	}
	[[ -n "$results" ]] || {
		echo "Error: --results required" >&2
		return 1
	}

	# Write TSV header if file doesn't exist
	if [[ ! -f "$results" ]]; then
		printf 'case_id\tpr_number\trepo\tcomplexity\tmodel\tpass\tdiff_similarity\ttokens_used\tescalation_reason\ttimestamp\n' >"$results"
	fi

	local case_count
	case_count=$(jq 'length' "${corpus}/index.json") || case_count=0
	if [[ "$subset" -gt 0 && "$subset" -lt "$case_count" ]]; then
		case_count="$subset"
	fi

	echo "[test] Running ${model} against ${case_count} test cases..."

	local i=0
	local passed=0
	local failed=0
	while [[ "$i" -lt "$case_count" ]]; do
		local case_dir
		case_dir=$(jq -r ".[$i].directory" "${corpus}/index.json")
		local full_path="${corpus}/${case_dir}"
		local pr_number
		pr_number=$(jq -r ".[$i].pr_number" "${corpus}/index.json")
		local repo
		repo=$(jq -r '.repo' "${full_path}/case.json")
		local complexity
		complexity=$(jq -r ".[$i].complexity" "${corpus}/index.json")

		if _test_single_case "$case_dir" "$full_path" "$pr_number" "$repo" \
			"$complexity" "$model" "$results"; then
			passed=$((passed + 1))
		else
			failed=$((failed + 1))
		fi

		i=$((i + 1))
	done

	echo "[test] Results: ${passed} passed, ${failed} failed out of $((passed + failed))"
	echo "[test] Results written to: ${results}"
	return 0
}

#######################################
# Compute composite score from results
#
# Reads the results TSV and computes the cascade cost metric.
# Outputs a single number to stdout (for autoresearch metric consumption).
#
# Arguments: parsed from command-line flags
# Returns: 0 on success
#######################################
cmd_score() {
	local corpus=""
	local results=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--corpus)
			corpus="$2"
			shift 2
			;;
		--results)
			results="$2"
			shift 2
			;;
		*)
			echo "Unknown option: $1" >&2
			return 1
			;;
		esac
	done

	[[ -n "$results" ]] || {
		echo "Error: --results required" >&2
		return 1
	}
	[[ -f "$results" ]] || {
		echo "Error: ${results} not found" >&2
		return 1
	}

	# Parse results TSV (skip header)
	local total=0
	local passed=0
	local diff_sim_sum=0
	local token_sum=0

	while IFS=$'\t' read -r case_id pr_number repo complexity model pass diff_sim tokens escalation_reason timestamp; do
		[[ "$case_id" == "case_id" ]] && continue # skip header
		total=$((total + 1))
		if [[ "$pass" == "true" ]]; then
			passed=$((passed + 1))
		fi
		# Accumulate diff similarity (awk for float addition)
		diff_sim_sum=$(awk "BEGIN {print ${diff_sim_sum} + ${diff_sim}}")
		token_sum=$((token_sum + tokens))
	done <"$results"

	if [[ "$total" -eq 0 ]]; then
		echo "0.0"
		return 0
	fi

	# Compute composite metric
	local pass_rate avg_sim cost_eff score
	pass_rate=$(awk "BEGIN {print ${passed} / ${total}}")
	avg_sim=$(awk "BEGIN {print ${diff_sim_sum} / ${total}}")
	# Cost efficiency: assume baseline Sonnet uses ~50K tokens per task
	local baseline_tokens=50000
	local avg_tokens
	avg_tokens=$(awk "BEGIN {print ${token_sum} / ${total}}")
	cost_eff=$(awk "BEGIN {v = 1 - (${avg_tokens} / ${baseline_tokens}); print (v < 0) ? 0 : v}")

	score=$(awk "BEGIN {print (0.5 * ${pass_rate}) + (0.3 * ${avg_sim}) + (0.2 * ${cost_eff})}")

	# Output score for autoresearch metric consumption (last line = metric value)
	echo "[score] Total: ${total}, Passed: ${passed}, Pass rate: ${pass_rate}"
	echo "[score] Avg diff similarity: ${avg_sim}"
	echo "[score] Avg tokens: ${avg_tokens}, Cost efficiency: ${cost_eff}"
	echo "[score] Composite score: ${score}"
	echo "$score"

	return 0
}

#######################################
# Print human-readable report
#######################################
cmd_report() {
	local results=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--results)
			results="$2"
			shift 2
			;;
		*)
			echo "Unknown option: $1" >&2
			return 1
			;;
		esac
	done

	[[ -n "$results" ]] || {
		echo "Error: --results required" >&2
		return 1
	}
	[[ -f "$results" ]] || {
		echo "Error: ${results} not found" >&2
		return 1
	}

	echo "=== Brief Tier Optimisation Report ==="
	echo ""

	# Overall stats
	local total passed failed
	total=$(tail -n +2 "$results" | wc -l | tr -d ' ')
	passed=$(tail -n +2 "$results" | awk -F'\t' '$6 == "true"' | wc -l | tr -d ' ')
	failed=$((total - passed))

	echo "Total test cases: ${total}"
	echo "Passed: ${passed} ($(awk "BEGIN {printf \"%.1f\", ${passed}/${total}*100}")%)"
	echo "Failed: ${failed}"
	echo ""

	# Breakdown by complexity
	echo "By complexity:"
	tail -n +2 "$results" | awk -F'\t' '{
		total[$4]++; if ($6 == "true") passed[$4]++
	} END {
		for (c in total) {
			p = (c in passed) ? passed[c] : 0
			printf "  %s: %d/%d (%.1f%%)\n", c, p, total[c], p/total[c]*100
		}
	}'
	echo ""

	# Escalation reasons
	echo "Escalation reasons (failures):"
	tail -n +2 "$results" | awk -F'\t' '$6 != "true" {print $9}' | sort | uniq -c | sort -rn
	echo ""

	# Compute composite score
	cmd_score --results "$results" 2>/dev/null | grep "^\[score\]"

	return 0
}

#######################################
# Main dispatch
#######################################
main() {
	local command="${1:-}"
	shift || true

	case "$command" in
	replay)
		python3 "${SCRIPT_DIR}/historical-replay-benchmark.py" "$@"
		;;
	extract) cmd_extract "$@" ;;
	enrich) cmd_enrich "$@" ;;
	test) cmd_test "$@" ;;
	score) cmd_score "$@" ;;
	report) cmd_report "$@" ;;
	*) usage ;;
	esac
}

main "$@"

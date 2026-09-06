#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# verify-agent-discoverability.sh — t1680.5
# Verify agent discoverability is not degraded after AGENTS.md progressive-load refactor.
#
# What was refactored (t1679/t1680 series):
#   build.txt: Conversational Memory Lookup, Screenshot Size Limits,
#              External Repo Submission, Bash 3.2 Compat, Secret Handling
#   AGENTS.md: Domain Index (t1680.1), Self-Improvement (t1680.2),
#              Agent Routing (t1680.3), Capabilities (t1680.4)
#   Inline content moved to reference files (on-demand reads):
#              self-improvement.md, agent-routing.md, domain-index.md
#   Supplement reference files (inline content retained in source):
#              audit-logging.md, model-verification.md, review-bot-gate.md,
#              memory-lookup.md, screenshot-limits.md, external-repo-submissions.md,
#              bash-compat.md, secret-handling.md
#
# Discoverability checks:
#   1. All extracted reference files exist and are non-empty
#   2. AGENTS.md has pointers to extracted reference files
#   3. AGENTS.md Domain Index section has pointer to reference/domain-index.md
#   4. reference/domain-index.md exists and has >=30 domain rows with trigger words
#  4b. Node server admin agent is routed and indexed
#   5. All 12 primary agent files exist and are non-empty
#   6. Capabilities section retains key capability entries
#   7. Self-Improvement section has pointer to reference/self-improvement.md
#   8. Agent Routing section has pointer to reference/agent-routing.md
#   9. subagent-index.toon TOON block counts are valid (>=12 agents, >=60 subagents)
#  10. Prompt-to-hook migration registry is discoverable
#  11. Critical scripts for self-improvement workflow are executable
#
# Usage: bash verify-agent-discoverability.sh [--agents-dir <path>]
# Exit: 0 = all checks pass, 1 = one or more failures

set -euo pipefail

AGENTS_DIR="${AIDEVOPS_AGENTS_DIR:-${HOME}/.aidevops/agents}"
PROMPT_HOOK_REGISTRY="configs/prompt-hook-candidates.conf"
readonly FRAMEWORK_RULES_FILE="AGENTS.md"
readonly AGENT_ROUTING_FILE="reference/agent-routing.md"
readonly BUILD_PLUS_FILE="build-plus.md"
PASS=0
FAIL=0
WARNINGS=0

# Parse args
while [[ $# -gt 0 ]]; do
	case "$1" in
	--agents-dir)
		AGENTS_DIR="$2"
		shift 2
		;;
	*)
		shift
		;;
	esac
done

log_ok() {
	local msg="$1"
	echo "  [PASS] ${msg}"
	PASS=$((PASS + 1))
	return 0
}

log_fail() {
	local msg="$1"
	echo "  [FAIL] ${msg}" >&2
	FAIL=$((FAIL + 1))
	return 0
}

log_warn() {
	local msg="$1"
	echo "  [WARN] ${msg}"
	WARNINGS=$((WARNINGS + 1))
	return 0
}

check_file_nonempty() {
	local path="$1"
	local min_bytes="${2:-100}"
	local label="$3"
	local full="${AGENTS_DIR}/${path}"
	if [[ ! -f "$full" ]]; then
		log_fail "${label}: ${path} — NOT FOUND"
		return 0
	fi
	local size
	size=$(wc -c <"$full" | tr -d ' ')
	if [[ "$size" -ge "$min_bytes" ]]; then
		log_ok "${label}: ${path} (${size} bytes)"
	else
		log_fail "${label}: ${path} — too small (${size} bytes, expected >=${min_bytes})"
	fi
	return 0
}

# check_string_in_file: grep -F with -- separator to handle strings starting with -
check_string_in_file() {
	local file="$1"
	local needle="$2"
	local label="$3"
	if grep -qF -- "$needle" "${AGENTS_DIR}/${file}" 2>/dev/null; then
		log_ok "${label}"
	else
		log_fail "${label} — '${needle}' not found in ${file}"
	fi
	return 0
}

check_regex_in_file() {
	local file="$1"
	local pattern="$2"
	local label="$3"
	if grep -qE -- "$pattern" "${AGENTS_DIR}/${file}" 2>/dev/null; then
		log_ok "${label}"
	else
		log_fail "${label} — pattern not found in ${file}"
	fi
	return 0
}

check_frontmatter_description_quoting() {
	local file="$1"
	local label="$2"
	local path="${AGENTS_DIR}/${file}"
	local description_line=""
	local description_value=""
	if [[ ! -f "$path" ]]; then
		log_fail "${label}: ${file} — NOT FOUND"
		return 0
	fi
	description_line=$(awk '
		/^---$/ { fm++; next }
		fm == 1 && /^description:/ { print; exit }
		fm == 2 { exit }
	' "$path" 2>/dev/null || true)
	description_value="${description_line#description:}"
	description_value="${description_value# }"
	if [[ "$description_value" != "\""* && "$description_value" != "'"* && "$description_value" == *": "* ]]; then
		log_fail "${label}: ${file} has unquoted description containing ':'"
	else
		log_ok "${label}: ${file} frontmatter description is safely quoted"
	fi
	return 0
}

check_domain_index_view() {
	local domain_index="${AGENTS_DIR}/reference/domain-index.md"
	local duplicates
	local path
	local checked_paths=0

	duplicates=$(awk -F'|' -v domain_column=2 '
		/^\|/ && $domain_column !~ /^[[:space:]]*(Domain|-+)/ {
			gsub(/^[[:space:]]+|[[:space:]]+$/, "", $domain_column)
			if (++seen[$domain_column] == 2) print $domain_column
		}' "$domain_index")
	if [[ -n "$duplicates" ]]; then
		log_fail "Domain index: duplicate domain rows: ${duplicates//$'\n'/, }"
	else
		log_ok "Domain index: domain rows are unique"
	fi

	while IFS= read -r path; do
		[[ "$path" == *"*"* ]] && continue
		[[ "$path" != */* && "$path" != *.* ]] && continue
		checked_paths=$((checked_paths + 1))
		if [[ -f "${AGENTS_DIR}/${path}" ]]; then
			log_ok "Domain index: entry point exists: ${path}"
		else
			log_fail "Domain index: stale entry point: ${path}"
		fi
	done < <(awk -F'`' '/^\|/ { for (field = 2; field <= NF; field += 2) print $field }' "$domain_index")
	if [[ "$checked_paths" -eq 0 ]]; then
		log_fail "Domain index: no declared entry points found"
	fi
	return 0
}

check_declared_view_contract() {
	if python3 "${AGENTS_DIR}/scripts/capability-readiness-helper.py" check >/dev/null; then
		log_ok "Capability registry: declared views have unique existing paths"
	else
		log_fail "Capability registry: stale or duplicate declared view"
	fi
	return 0
}

# ─── Test 1: Extracted reference files exist and are non-empty ───────────────
echo ""
echo "=== 1. Extracted Reference Files ==="
EXTRACTED_REFS=(
	"reference/memory-lookup.md"
	"reference/screenshot-limits.md"
	"reference/external-repo-submissions.md"
	"reference/audit-logging.md"
	"reference/model-verification.md"
	"reference/review-bot-gate.md"
	"reference/self-improvement.md"
	"$AGENT_ROUTING_FILE"
	"reference/domain-index.md"
)
for ref in "${EXTRACTED_REFS[@]}"; do
	check_file_nonempty "$ref" 100 "Extracted reference"
done

# ─── Test 1b: Prompt-to-hook migration registry exists and is discoverable ────
echo ""
echo "=== 1b. Prompt-to-Hook Migration Registry ==="
check_file_nonempty "$PROMPT_HOOK_REGISTRY" 1000 "Prompt-hook registry"
check_string_in_file "$FRAMEWORK_RULES_FILE" "$PROMPT_HOOK_REGISTRY" "${FRAMEWORK_RULES_FILE}: pointer to prompt-hook registry"
check_string_in_file "reference/progressive-disclosure.md" "Prompt-to-Hook Migration" "progressive-disclosure: prompt-to-hook migration rubric"
check_string_in_file "$PROMPT_HOOK_REGISTRY" "deterministic" "Prompt-hook registry: deterministic rule class present"

# ─── Test 2: AGENTS.md Framework Rules has pointers to extracted reference files ─
# Post-t2878: build.txt was consolidated into AGENTS.md "Framework Rules", so
# the pointers that used to live in prompts/build.txt now live in AGENTS.md.
echo ""
echo "=== 2. AGENTS.md Framework Rules Pointers to Extracted References ==="
FRAMEWORK_REFS=(
	"reference/memory-lookup.md"
	"reference/screenshot-limits.md"
)
for ref in "${FRAMEWORK_REFS[@]}"; do
	check_string_in_file "$FRAMEWORK_RULES_FILE" "$ref" "${FRAMEWORK_RULES_FILE} pointer: ${ref}"
done

# ─── Test 3: AGENTS.md Domain Index section has pointer to reference file ─────
echo ""
echo "=== 3. AGENTS.md Domain Index Pointer ==="
check_string_in_file "$FRAMEWORK_RULES_FILE" "reference/domain-index.md" "${FRAMEWORK_RULES_FILE}: Domain Index pointer to reference/domain-index.md"

# ─── Test 4: reference/domain-index.md has >=30 domain rows ──────────────────
echo ""
echo "=== 4. Domain Index Reference File Integrity ==="
DOMAIN_INDEX="${AGENTS_DIR}/reference/domain-index.md"
if [[ ! -f "$DOMAIN_INDEX" ]]; then
	log_fail "reference/domain-index.md not found"
else
	# Count table rows (lines starting with | that aren't header/separator).
	# Avoid `grep -c ... || echo 0` counter stacking on zero-match paths.
	ROW_COUNT=$(grep -c "^|" "$DOMAIN_INDEX" 2>/dev/null || true)
	[[ "$ROW_COUNT" =~ ^[0-9]+$ ]] || ROW_COUNT=0
	# Subtract header and separator rows (2 per table)
	DATA_ROWS=$((ROW_COUNT - 2))
	if [[ "$DATA_ROWS" -ge 30 ]]; then
		log_ok "reference/domain-index.md has ${DATA_ROWS} domain rows (expected >=30)"
	else
		log_fail "reference/domain-index.md has only ${DATA_ROWS} domain rows (expected >=30)"
	fi
	check_file_nonempty "reference/domain-index.md" 2000 "Domain index: substantial content"
	check_string_in_file "reference/domain-index.md" "Trigger words" "Domain index: trigger-word column present"
	check_domain_index_view
	check_declared_view_contract
fi

# ─── Test 4b: Node server admin specialist is routed and indexed ─────────────
echo ""
echo "=== 4b. Node Server Admin Discoverability ==="
check_file_nonempty "tools/runtime/node-server-admin.md" 2000 "Node server admin agent"
check_string_in_file "tools/runtime/node-server-admin.md" "mode: subagent" "Node server admin: subagent mode"
check_regex_in_file "$BUILD_PLUS_FILE" '^[[:space:]]*-[[:space:]]*node-server-admin[[:space:]]*$' "Build+: node-server-admin allowlist"
check_string_in_file "$BUILD_PLUS_FILE" "tools/runtime/node-server-admin.md" "Build+: Node runtime domain route"
check_string_in_file "reference/domain-index.md" "tools/runtime/node-server-admin.md" "Domain index: Node server admin route"
check_string_in_file "subagent-index.toon" "node-server-admin" "Subagent index: node-server-admin entry"

# ─── Test 5: Primary agent @mention files ─────────────────────────────────────
echo ""
echo "=== 5. Primary Agent @Mention Files ==="
# 12 primary agents: marketing-sales consolidates marketing+sales; content covers video/social; business covers accounts; PR covers earned media.
AGENT_FILES=(
	"aidevops.md"
	"$BUILD_PLUS_FILE"
	"automate.md"
	"business.md"
	"content.md"
	"health.md"
	"legal.md"
	"marketing-sales.md"
	"pr.md"
	"product.md"
	"research.md"
	"seo.md"
)
for af in "${AGENT_FILES[@]}"; do
	check_file_nonempty "$af" 100 "Primary agent file"
done
check_string_in_file "subagent-index.toon" "PR,pr.md" "subagent-index: PR display name is uppercase"
check_frontmatter_description_quoting "services/communications/privacy-comparison.md" "OpenCode subagent YAML safety"

# ─── Test 6: Capabilities section retains key entries ─────────────────────────
echo ""
echo "=== 6. Capabilities Section Key Entries ==="
KEY_CAPS=(
	"reference/domain-index.md"
	"reference/orchestration.md"
	"reference/services.md"
	"reference/skills.md"
	"reference/memory.md"
	"reference/self-improvement.md"
	"/routine"
)
for cap in "${KEY_CAPS[@]}"; do
	check_string_in_file "$FRAMEWORK_RULES_FILE" "$cap" "Capabilities: ${cap}"
done

# ─── Test 7: Self-Improvement section has pointer to reference file ───────────
# After t1680.2 refactor: inline content moved to reference/self-improvement.md;
# AGENTS.md retains only the section header + 1-line pointer.
echo ""
echo "=== 7. Self-Improvement Section Key References ==="
check_string_in_file "$FRAMEWORK_RULES_FILE" "reference/self-improvement.md" "${FRAMEWORK_RULES_FILE} Self-Improvement: pointer to reference/self-improvement.md"
# Verify the reference file has the full content (canonical source after refactor)
check_string_in_file "reference/self-improvement.md" "framework-issue-helper.sh" "reference/self-improvement.md: framework-issue-helper.sh reference"
check_string_in_file "reference/self-improvement.md" "PULSE_SCOPE_REPOS" "reference/self-improvement.md: PULSE_SCOPE_REPOS scope boundary"
check_file_nonempty "reference/self-improvement.md" 2000 "reference/self-improvement.md: substantial content"

# ─── Test 8: Agent Routing section — content accessible (inline or via pointer) ─
# After t1680.3 refactor: inline content moved to reference/agent-routing.md;
# AGENTS.md retains only the section header + 1-line pointer.
# This check passes if either the pointer OR inline content is present in AGENTS.md
# (supports both pre- and post-refactor states during the PR merge window).
echo ""
echo "=== 8. Agent Routing Section Key References ==="
check_string_in_file "$FRAMEWORK_RULES_FILE" "## Agent Routing" "${FRAMEWORK_RULES_FILE}: Agent Routing section present"
# Check that routing content is accessible: either via pointer or inline
AGENTS_MD="${AGENTS_DIR}/${FRAMEWORK_RULES_FILE}"
if grep -qF "$AGENT_ROUTING_FILE" "$AGENTS_MD" 2>/dev/null; then
	log_ok "${FRAMEWORK_RULES_FILE} Agent Routing: pointer to ${AGENT_ROUTING_FILE}"
elif grep -qF "headless-runtime-helper.sh" "$AGENTS_MD" 2>/dev/null; then
	log_ok "${FRAMEWORK_RULES_FILE} Agent Routing: inline headless dispatch reference (pre-refactor state)"
else
	log_fail "${FRAMEWORK_RULES_FILE} Agent Routing: neither pointer nor inline content found"
fi
# Verify the reference file has the full content (canonical source after refactor)
check_string_in_file "$AGENT_ROUTING_FILE" "headless-runtime-helper.sh" "${AGENT_ROUTING_FILE}: headless dispatch reference"
check_string_in_file "$AGENT_ROUTING_FILE" "--agent" "${AGENT_ROUTING_FILE}: --agent flag documented"
check_file_nonempty "$AGENT_ROUTING_FILE" 1000 "${AGENT_ROUTING_FILE}: substantial content"

# ─── Test 9: subagent-index.toon TOON block counts ────────────────────────────
echo ""
echo "=== 9. subagent-index.toon TOON Block Counts ==="
TOON_FILE="${AGENTS_DIR}/subagent-index.toon"
if [[ ! -f "$TOON_FILE" ]]; then
	log_fail "subagent-index.toon not found"
else
	# Extract declared count from TOON block header using sed (macOS-compatible)
	# Format: <!--TOON:agents[12]{...}:
	# 12 primary agents: marketing-sales consolidates marketing+sales; content covers video/social; business covers accounts; PR covers earned media.
	AGENTS_COUNT=$(sed -n 's/.*<!--TOON:agents\[\([0-9]*\)\].*/\1/p' "$TOON_FILE" | head -1)
	if [[ -n "$AGENTS_COUNT" && "$AGENTS_COUNT" -ge 12 ]]; then
		log_ok "subagent-index.toon: agents block declares ${AGENTS_COUNT} agents (expected >=12)"
	elif [[ -n "$AGENTS_COUNT" ]]; then
		log_fail "subagent-index.toon: agents block declares only ${AGENTS_COUNT} agents (expected >=12)"
	else
		log_fail "subagent-index.toon: could not parse agents block count"
	fi

	SUBAGENTS_COUNT=$(sed -n 's/.*<!--TOON:subagents\[\([0-9]*\)\].*/\1/p' "$TOON_FILE" | head -1)
	if [[ -n "$SUBAGENTS_COUNT" && "$SUBAGENTS_COUNT" -ge 60 ]]; then
		log_ok "subagent-index.toon: subagents block declares ${SUBAGENTS_COUNT} subagents"
	elif [[ -n "$SUBAGENTS_COUNT" ]]; then
		log_fail "subagent-index.toon: subagents block declares only ${SUBAGENTS_COUNT} subagents (expected >=60)"
	else
		log_fail "subagent-index.toon: could not parse subagents block count"
	fi

	check_string_in_file "subagent-index.toon" "triggers" "subagent-index.toon: primary agent triggers documented"
fi

# ─── Test 10: Critical scripts for self-improvement workflow ──────────────────
echo ""
echo "=== 11. Critical Scripts for Self-Improvement Workflow ==="
CRITICAL_SCRIPTS=(
	"scripts/framework-issue-helper.sh"
	"scripts/framework-routing-helper.sh"
	"scripts/headless-runtime-helper.sh"
	"scripts/worktree-helper.sh"
	"scripts/pre-edit-check.sh"
	"scripts/claim-task-id.sh"
)
for script in "${CRITICAL_SCRIPTS[@]}"; do
	full="${AGENTS_DIR}/${script}"
	if [[ -f "$full" && -x "$full" ]]; then
		log_ok "Script executable: ${script}"
	elif [[ -f "$full" ]]; then
		log_fail "Script exists but not executable: ${script}"
	else
		log_fail "Script missing: ${script}"
	fi
done

# ─── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "=== SUMMARY ==="
echo "  PASS: ${PASS}"
echo "  FAIL: ${FAIL}"
echo "  WARN: ${WARNINGS}"
echo ""

if [[ "$FAIL" -gt 0 ]]; then
	echo "RESULT: FAIL — ${FAIL} check(s) failed. Agent discoverability may be degraded."
	exit 1
else
	echo "RESULT: PASS — All discoverability checks passed. Refactor did not degrade agent discoverability."
	exit 0
fi

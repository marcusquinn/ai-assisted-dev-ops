#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Guard intentional safety reinforcement against count-driven consolidation.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)" || exit 1
AGENT_REVIEW="$REPO_ROOT/.agents/tools/build-agent/agent-review.md"
BUILD_AGENT="$REPO_ROOT/.agents/tools/build-agent/build-agent.md"
CODE_SIMPLIFIER="$REPO_ROOT/.agents/tools/code-review/code-simplifier.md"
CLAUDE_GENERATOR="$REPO_ROOT/.agents/scripts/generate-claude-commands.sh"
OPENCODE_GENERATOR="$REPO_ROOT/.agents/scripts/generate-opencode-commands-quality.sh"
RUNTIME_GENERATOR="$REPO_ROOT/.agents/scripts/generate-runtime-config-commands.sh"

python3 - "$AGENT_REVIEW" "$BUILD_AGENT" "$CODE_SIMPLIFIER" \
	"$CLAUDE_GENERATOR" "$OPENCODE_GENERATOR" "$RUNTIME_GENERATOR" <<'PY'
import sys
from pathlib import Path

content = Path(sys.argv[1]).read_text()
build_agent = Path(sys.argv[2]).read_text()
code_simplifier = Path(sys.argv[3]).read_text()
generators = [Path(path) for path in sys.argv[4:]]

# The invariant is intentionally repeated because each copy protects a distinct
# decision point. A review must not classify this fixture by text similarity alone.
fixture = [
    ("before-write", "Never expose credentials in generated files."),
    ("before-push", "Never expose credentials in public changes."),
]
assert len({text.split(" in ")[0] for _, text in fixture}) == 1
assert len({boundary for boundary, _ in fixture}) == 2

required = [
    "counts are heuristics, never standalone removal evidence",
    "recent file history",
    "exact duplication from reinforcement at another decision boundary",
    "runtime-specific variants",
    "similar-but-different hazards",
    "reliable trigger that delivers the lesson at its decision point",
    "obsolete or fully superseded",
    "**Provenance**",
    "**Context Stack**",
    "**Classification**",
    "**Activation/Exclusion**",
    "**Boundary Analysis**",
    "**Verification**",
    "Invariant",
    "Judgment rule",
    "Interface",
    "Triggered pointer",
    "Rationale",
    "Deterministic enforcement candidate",
    "assembled context stack",
    "Incomplete provenance, delivery, or behavioural evidence defaults to preservation",
]
missing = [phrase for phrase in required if phrase not in content]
assert not missing, f"Agent Review lost provenance safeguards: {missing}"

assert "Frontmatter uses `model: simple|standard|thinking`" in build_agent
assert "provider/model mapping" in build_agent
assert "size reduction is not the success criterion" in build_agent
assert "Agent Review owns semantic tightening" in code_simplifier
assert "Incomplete provenance, delivery, or coverage evidence means no deletion" in code_simplifier

for generator in generators:
    wrapper = generator.read_text()
    assert "follow it as the canonical review rubric" in wrapper, \
        f"{generator.name} does not defer to canonical Agent Review"
    assert "Instruction count (target <50" not in wrapper, \
        f"{generator.name} reintroduced a hard count quota"
    assert "Duplicate detection across agents" not in wrapper, \
        f"{generator.name} forks the canonical review checklist"
PY

printf 'PASS Agent Review directive provenance contract\n'

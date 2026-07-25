#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Guard /define's sufficiency-driven interview and tier-aware brief contracts.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)" || exit 1

python3 - "$REPO_ROOT" <<'PY'
import re
import sys
from pathlib import Path

root = Path(sys.argv[1])
define = (root / ".agents/workflows/define.md").read_text()
command = root / ".agents/scripts/commands/define.md"

required = [
    "scope, architecture, trust/security boundaries, user-visible behaviour, or acceptance criteria",
    "Use zero or more probes",
    "Do not enforce a minimum or maximum question count",
    "compact blind-spot pass",
    "`tier:simple`: provide every exact file",
    "`tier:standard`: provide verified files",
    "`tier:thinking`: keep the brief problem-first",
]
missing = [phrase for phrase in required if phrase not in define]
assert not missing, f"Define lost sufficiency/tier contracts: {missing}"

forbidden = [
    "Structured Interview (3–5 questions)",
    "exactly **2 probes**",
    "Maximum total: 7 questions",
    "MANDATORY for code tasks): For each file",
]
present = [phrase for phrase in forbidden if phrase in define]
assert not present, f"Define reintroduced fixed interview/scaffold quotas: {present}"

assert command.is_symlink(), "The /define command must remain a canonical workflow symlink"
assert command.resolve() == root / ".agents/workflows/define.md"

probe_dir = root / ".agents/reference/define-probes"
for path in sorted(probe_dir.glob("*.md")):
    content = path.read_text()
    assert "candidate" in content.lower(), f"{path.name} is not framed as a candidate pool"
    assert not re.search(r"\b(?:use|ask|select|pick)\s+(?:the\s+)?2\b", content, re.IGNORECASE), \
        f"{path.name} retains a fixed two-question quota"
    assert "ask both" not in content.lower(), f"{path.name} retains a mandatory question pair"

simple = (root / ".agents/workflows/brief/tier-simple.md").read_text()
standard = (root / ".agents/workflows/brief/tier-standard.md").read_text()
thinking = (root / ".agents/workflows/brief/tier-thinking.md").read_text()
template = (root / ".agents/templates/brief-template.md").read_text()
plans = (root / ".agents/workflows/plans.md").read_text()
new_task = (root / ".agents/workflows/new-task.md").read_text()
assert "no unresolved design" in simple
assert "implementation-ready" in standard and "false precision" in standard
assert "Decisions to Make" in thinking and "No speculative scaffolding" in thinking
assert "tier:standard (sonnet)" not in template
assert "No speculative file-by-file skeletons" in template
assert "{Concrete step with code skeleton:}" not in template
assert "Delete it for unresolved" in template
assert "Tier-aware implementation context (t1901)" in plans
assert "complete exact edits for `tier:simple`" in new_task
assert "For each file, draft a code skeleton" not in plans + new_task
PY

printf 'PASS Define sufficiency and tier-aware briefing contracts\n'
exit 0

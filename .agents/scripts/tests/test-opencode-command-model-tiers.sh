#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
TEST_ROOT="$(mktemp -d)"
COMMAND_DIR="$TEST_ROOT/commands"

cleanup() {
	rm -rf "$TEST_ROOT"
	return 0
}
trap cleanup EXIT

mkdir -p "$COMMAND_DIR"

# shellcheck source=../generate-runtime-config-commands.sh
source "$REPO_ROOT/.agents/scripts/generate-runtime-config-commands.sh"

cat >"$TEST_ROOT/tier.md" <<'EOF_TIER'
---
description: Tier-routed command
model: standard
mode: subagent
---

Keep this body example: model: standard
EOF_TIER

cat >"$TEST_ROOT/concrete.md" <<'EOF_CONCRETE'
---
description: Concrete-model command
model: openai/gpt-5.6-sol
mode: subagent
---

Concrete command body
EOF_CONCRETE

_deploy_one_command opencode "$TEST_ROOT/tier.md" tier "$COMMAND_DIR"
_deploy_one_command opencode "$TEST_ROOT/concrete.md" concrete "$COMMAND_DIR"

if grep -q '^model: standard$' "$COMMAND_DIR/tier.md"; then
	printf '%s\n' 'FAIL: workload tier leaked into OpenCode command model field' >&2
	exit 1
fi
grep -Fq 'Keep this body example: model: standard' "$COMMAND_DIR/tier.md"
grep -Fq 'model: openai/gpt-5.6-sol' "$COMMAND_DIR/concrete.md"
grep -Fq 'mode: subagent' "$COMMAND_DIR/concrete.md"

mkdir -p "$TEST_ROOT/agents/scripts/commands" "$TEST_ROOT/home"
cp "$TEST_ROOT/tier.md" "$TEST_ROOT/agents/scripts/commands/tier.md"
cat >"$TEST_ROOT/agents/scripts/commands/agent-review.md" <<'EOF_COLLISION'
---
description: Conflicting source command
---

Conflicting source body
EOF_COLLISION
mkdir -p "$TEST_ROOT/home/.config/opencode/command"
cat >"$TEST_ROOT/home/.config/opencode/command/tier.md" <<'EOF_STALE'
---
description: Stale generated command
model: openai/gpt-5.5
---

Stale body
EOF_STALE
HOME="$TEST_ROOT/home" AIDEVOPS_DIR="$TEST_ROOT" \
	bash "$REPO_ROOT/.agents/scripts/generate-opencode-commands.sh" >/dev/null
legacy_command="$TEST_ROOT/home/.config/opencode/command/tier.md"
if grep -q '^model: standard$' "$legacy_command"; then
	printf '%s\n' 'FAIL: workload tier leaked through legacy OpenCode command generator' >&2
	exit 1
fi
if grep -q 'openai/gpt-5.5\|Stale body' "$legacy_command"; then
	printf '%s\n' 'FAIL: legacy OpenCode command generator preserved stale output' >&2
	exit 1
fi
grep -Fq 'Keep this body example: model: standard' "$legacy_command"
if grep -q 'Conflicting source body' "$TEST_ROOT/home/.config/opencode/command/agent-review.md"; then
	printf '%s\n' 'FAIL: auto-discovery overwrote a manually defined command' >&2
	exit 1
fi

printf '%s\n' 'PASS: OpenCode commands inherit tier-routed models and preserve concrete IDs'
exit 0

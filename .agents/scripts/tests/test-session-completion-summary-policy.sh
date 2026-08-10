#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)" || exit 1
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)" || exit 1
AGENTS_DOC="${REPO_ROOT}/.agents/AGENTS.md"
SESSION_DOC="${REPO_ROOT}/.agents/reference/session.md"
FULL_LOOP_DOC="${REPO_ROOT}/.agents/workflows/full-loop.md"

require_literal() {
	local needle="$1"
	local file="$2"
	local description="$3"

	if ! grep -Fq -- "$needle" "$file"; then
		printf 'FAIL: %s\n' "$description" >&2
		return 1
	fi
	return 0
}

main() {
	require_literal 'state aim and solved outcome' \
		"$AGENTS_DOC" 'always-loaded completion guidance omits the session aim and solved outcome' || return 1
	require_literal 'reconnects the delivered work to the session aim or problem' \
		"$SESSION_DOC" 'session completion detail omits reader reorientation context' || return 1
	require_literal 'omit routine-owned cleanup unless user action is required or work is at risk' \
		"$AGENTS_DOC" 'always-loaded completion guidance does not suppress routine cleanup noise' || return 1
	require_literal 'Do not attempt or report normal deferred cleanup' \
		"$SESSION_DOC" 'session lifecycle still asks the owning session to narrate cleanup' || return 1
	require_literal "A valid routine-owned \`CLEANUP_DEFERRED\` handoff is silent operational bookkeeping" \
		"$FULL_LOOP_DOC" 'full-loop guidance does not classify routine cleanup as silent' || return 1
	require_literal 'Do not copy lifecycle promise tokens' \
		"$FULL_LOOP_DOC" 'machine lifecycle tokens may leak into the user-facing summary' || return 1

	if grep -Fq -- "Cleanup: commit or stash changes, then run \`wt merge\`" "$SESSION_DOC"; then
		printf 'FAIL: session lifecycle still directs the owning session to clean its worktree\n' >&2
		return 1
	fi

	printf 'PASS: completion summaries prioritize delivered outcomes over routine cleanup\n'
	return 0
}

main "$@"

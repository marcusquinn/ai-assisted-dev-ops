#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)" || exit 1
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)" || exit 1
AGENTS_DOC="${REPO_ROOT}/.agents/AGENTS.md"
SESSION_DOC="${REPO_ROOT}/.agents/reference/session.md"
FULL_LOOP_COMMAND="${REPO_ROOT}/.agents/scripts/commands/full-loop.md"
SAFETY_STOP_DOC="${REPO_ROOT}/.agents/reference/safety-stop-recovery.md"

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
		"$FULL_LOOP_COMMAND" 'full-loop guidance does not classify routine cleanup as silent' || return 1
	require_literal 'Do not copy lifecycle promise tokens' \
		"$FULL_LOOP_COMMAND" 'machine lifecycle tokens may leak into the user-facing summary' || return 1
	require_literal '**Delivered:** every promised acceptance criterion has verified evidence.' \
		"$SESSION_DOC" 'session guidance does not define delivered evidence' || return 1
	require_literal '**Externally blocked:** name the dependency, its durable action, its owner' \
		"$SESSION_DOC" 'session guidance does not define an actionable external handoff' || return 1
	require_literal '**Active:** identify an actually live executor or a verified durable checkpoint' \
		"$SESSION_DOC" 'session guidance permits imaginary background continuation' || return 1
	require_literal 'A plan, suggested next step, draft, or expired command is not an active executor.' \
		"$SESSION_DOC" 'session guidance does not reject plans as execution' || return 1
	require_literal 'While authorized safe work remains, perform the next safe action' \
		"$SESSION_DOC" 'session guidance allows premature stops in authorized work' || return 1
	require_literal '### Behavioral Examples' \
		"$SESSION_DOC" 'session guidance lacks behavioral contract examples' || return 1
	for behavior in \
		'Authorized work remains and a safe edit or check is available' \
		'A permission must be granted by a human' \
		'A recoverable API call fails' \
		'A human may not return soon' \
		'Every accepted criterion has evidence' \
		'The user explicitly stops work'; do
		require_literal "$behavior" "$SESSION_DOC" \
			"session guidance omits behavioral case: $behavior" || return 1
	done
	require_literal 'not prove a future model run complies with the contract.' \
		"$SESSION_DOC" 'session guidance overstates literal policy coverage' || return 1
	require_literal 'Handoff action and verification' \
		"$SAFETY_STOP_DOC" 'safety-stop checkpoints omit human-only handoff evidence' || return 1
	require_literal 'Do not claim that work continues in the background unless a named, live executor' \
		"$SAFETY_STOP_DOC" 'safety-stop guidance allows unsupported background-progress claims' || return 1
	require_literal '**Truthful execution state (MANDATORY):**' \
		"$FULL_LOOP_COMMAND" 'full-loop command omits truthful execution states' || return 1
	require_literal 'continuation; it never completes unfinished delivery.' \
		"$FULL_LOOP_COMMAND" 'full-loop command treats checkpointing as completion' || return 1

	if grep -Fq -- "Cleanup: commit or stash changes, then run \`wt merge\`" "$SESSION_DOC"; then
		printf 'FAIL: session lifecycle still directs the owning session to clean its worktree\n' >&2
		return 1
	fi

	printf 'PASS: completion summaries prioritize delivered outcomes over routine cleanup\n'
	return 0
}

main "$@"

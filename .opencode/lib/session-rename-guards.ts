// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
//
// Pure guard logic for session-rename.ts (t2252).
//
// This file has no runtime-injected dependencies (@opencode-ai/plugin) so it
// can be imported and unit-tested directly via bun. session-rename.ts imports
// these symbols; the tests in .agents/scripts/tests/test-session-rename-ts.mjs
// verify behaviour without needing the OpenCode plugin runtime.
//
// The semantics mirror session-rename-helper.sh's `_is_meaningful_branch_title`
// and `_is_title_overwritable` verbatim so the two code paths cannot drift.

import type { Database } from "bun:sqlite"

const AIDEVOPS_TITLE_SUFFIX_RE = /\s+· AIDevOps \d+\.\d+\.\d+$/
const CURRENT_CONTEXT_SEPARATOR = " — Current: "

/**
 * Check whether a branch name is a default (non-feature) branch.
 *
 * Default branches (main/master/HEAD) are NOT meaningful session titles —
 * they represent the absence of a feature branch and should never clobber
 * a session title. This matters because sync_branch is called on worktree
 * creation AND repeatedly during a session; interactive sessions in
 * canonical repo directories stay on main per t1990. Without this guard,
 * auto-compaction or routine syncs end up titling sessions "main" forever
 * (t2252).
 *
 * Mirrors `_is_meaningful_branch_title` in session-rename-helper.sh
 * (inverted return: this returns TRUE when branch is default).
 */
export function isDefaultBranchTitle(branch: string): boolean {
  switch (branch) {
    case "":
    case "HEAD":
    case "main":
    case "master":
      return true
    default:
      return false
  }
}

/**
 * Check whether the current session title is safe to overwrite.
 *
 * A title is overwritable when it is empty, the default "New Session", or
 * itself one of the default branch names (main/master/HEAD — recovery path
 * for sessions stuck by the pre-t2252 code). A meaningful custom title —
 * anything else, including feature branch names or LLM-generated summaries —
 * is preserved.
 *
 * Mirrors `_is_title_overwritable` in session-rename-helper.sh.
 */
export function isTitleOverwritable(db: Database, sessionID: string): boolean {
  const row = db
    .query("SELECT COALESCE(title, '') AS title FROM session WHERE id = ?")
    .get(sessionID) as { title: string } | null

  if (row === null) {
    // No row yet — effectively empty, safe to set.
    return true
  }

  switch (row.title) {
    case "":
    case "New Session":
    case "HEAD":
    case "main":
    case "master":
      return true
    default:
      return false
  }
}

/**
 * Preserve the first meaningful session purpose while allowing the current
 * phase to evolve. Explicit replacement is reserved for a user-directed
 * repurpose of the whole session.
 */
export function purposePreservingTitle(
  currentTitle: string,
  requestedTitle: string,
  replacePurpose = false,
): string {
  const currentBase = currentTitle.replace(AIDEVOPS_TITLE_SUFFIX_RE, "").trim()
  const requestedBase = requestedTitle.replace(AIDEVOPS_TITLE_SUFFIX_RE, "").trim()

  if (!currentBase || isDefaultBranchTitle(currentBase) || currentBase === "New Session") {
    return requestedBase
  }
  if (replacePurpose) return requestedBase

  const purpose = currentBase.split(CURRENT_CONTEXT_SEPARATOR, 1)[0].trim()
  if (!purpose || requestedBase.includes(purpose)) return requestedBase
  return `${purpose}${CURRENT_CONTEXT_SEPARATOR}${requestedBase}`
}

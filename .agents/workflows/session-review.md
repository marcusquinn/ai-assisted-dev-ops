---
description: Review session for completeness, best practices, and knowledge capture
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: true
  grep: true
  task: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Session Review - Completeness and Best Practices Audit

<!-- AI-CONTEXT-START -->

**Purpose**: Review current session for completeness, workflow adherence, and knowledge capture.
**Trigger**: `/session-review [focus]` — focus: `objectives | workflow | knowledge | all` (default). Run at end of significant work, before ending session, or after Ralph loop completion.
**Output**: Completion score (0-100%), outstanding items, value extraction report, evidence-based friction/efficiency retrospective, knowledge capture recommendations, session continuation advice.

<!-- AI-CONTEXT-END -->

## Review Process

### Step 1: Gather Session Context

```bash
git branch --show-current && git log --oneline -10
grep -A 20 "## In Progress" TODO.md 2>/dev/null || echo "No TODO.md"
git status --short
test -f .agents/loop-state/ralph-loop.local.md && head -10 .agents/loop-state/ralph-loop.local.md || \
  test -f .claude/ralph-loop.local.md && head -10 .claude/ralph-loop.local.md
gh pr list --state open --limit 5 2>/dev/null || echo "No open PRs"
```

### Step 2: Objective Completion Assessment

| Check | Method | Weight |
|-------|--------|--------|
| Initial request fulfilled | Compare first message to current state | 40% |
| TODO items completed | Count `[x]` vs `[ ]` in session scope | 20% |
| Branch purpose achieved | Compare branch name to commits | 20% |
| Functional evidence and required checks | Inspect production-facing verification; run applicable existing checks | 10% |
| No blocking errors | Check for unresolved issues | 10% |

Output: score, completed `[x]` / outstanding `[ ]` items with blockers, scope changes.

### Step 3: Workflow Adherence Check

| Practice | Check | Required? |
|----------|-------|-----------|
| Pre-edit git check | In a safe linked worktree, not canonical main | Required |
| TODO tracking | Tasks logged in TODO.md | Recommended |
| Commit hygiene | Atomic commits, clear messages | Required |
| Quality checks | Linters run before commit | Recommended |
| Issue-sync | `issue-sync-helper.sh status` after PR merge | Recommended |
| Documentation | Changes documented where needed | Situational |

Output: practices followed, practices missed with recommendations.

### Step 4: Auto-Distill Session Learnings

**MANDATORY**: Run resumable session finalization. It checkpoints operational state independently, privacy-redacts observations before proposal persistence, and only auto-finalizes low-risk preferences explicitly stated by the user:

```bash
~/.aidevops/agents/scripts/session-distill-helper.sh auto
```

### Step 5: Conversation Value Extraction + Knowledge Capture

**MANDATORY**: Re-read the entire conversation. Submit uncaptured observations as proposals with stable session/source boundaries. Mark only directly stated, non-consequential preferences as `explicit: true, risk: low`; inferred or consequential observations remain `pending_review`.

**Signals to capture:**

| Signal | Example | Capture To |
|--------|---------|------------|
| User direction/philosophy | "always solve root causes" | Agent docs, memory |
| Design decisions with rationale | "POC mode is a flag, not a separate system" | PLANS.md, brief, memory |
| System behaviour observations | "pulse completed 8 tasks in 40 min" | Memory |
| Root cause analyses | "workers search by keyword instead of using authoritative ID" | Code fix + memory |
| Recurring patterns | "three-layer defense: prevent, detect, correct" | Agent docs, memory |
| User preferences/constraints | "skip ceremony for prototypes" | Memory |
| Unfinished threads | "we should also check X" — never did | TODO.md or issue |
| Side discoveries | "GitHub parses Closes #NNN in prose text" | Docs, memory |
| Implicit standards | user corrects an approach — that correction is a standard | Agent docs |
| Bug patterns discovered | Error patterns, tool failures | Code comments, docs |
| Tool discoveries | Unexpected tool behaviour | Relevant subagent |
| Temporary workarounds | Hacks that need proper fixes | TODO.md, code comments |

**Process**: Scan chronologically; write candidate JSON and run `session-distill-helper.sh propose <file>`, then `finalize`. Retries process only unfinished items by idempotency key. Never delete proposal inputs or pending ledger items after partial failure. Finalization failure is non-blocking for authorized implementation; report it and leave the ledger resumable. User corrections reveal framework gaps, but consequential or inferred claims require review.

Output: newly captured items with locations, already-captured items, unfinished threads with created TODOs/issues.

### Step 6: Session Health Assessment

Gather deterministic output-noise evidence for the exact current session when
transcript history is available:

```bash
session-review-helper.sh output-efficiency --session <session-id> --json
```

Use unchanged-snapshot, duplicate-output, repeated-fragment, success-verbosity,
and fallback findings as candidates to correlate with the conversation timeline.
Keep raw transcript content private, and do not treat aggregate counts alone as
proof that a required safeguard was wasteful.

Before assessing whether to end, read and run
`workflows/session-analysis.md` with focus `all`. Include its outcome baseline,
shortest safe replay, model/reasoning fit, material harness and repository
findings, and retained safeguards in the session review. Keep the analysis
evidence-backed and route any deduplicated systemic candidate through
`reference/self-improvement.md`.

| Signal | Recommendation |
|--------|----------------|
| All objectives complete | End session |
| PR merged | End or new session |
| Context becoming stale | End session |
| Topic shift requested | New session |
| Blocked on external | End session |
| More work in scope | Continue |

Output: status (Continue/End Recommended/End Required), reason, final actions if ending, next focus if continuing, suggested branches for new sessions.

## Integration Points

- **Before PR creation**: Ensure all changes committed, no outstanding items, docs complete.
- **Before ending session**: Capture learnings, update TODO.md, check issue-sync drift (`issue-sync-helper.sh status`, t179.4), ensure clean handoff.
- **After Ralph loop completion**: Verify completion promise met, identify cleanup, suggest next steps.

### Security Summary (t1428.5)

```bash
session-review-helper.sh security              # Full summary (/session-review security)
session-review-helper.sh security --json       # JSON output
session-review-helper.sh security --session ID # Filter by session
session-review-helper.sh gather --security     # Include in standard gather
```

**Data sources:**

| Source | Data | Script |
|--------|------|--------|
| Cost breakdown | LLM requests by model, token counts, costs | `observability-helper.sh` |
| Audit events | Security event type breakdown, chain integrity | `audit-log-helper.sh` |
| Network access | Logged/flagged/denied domain counts, top flagged | `network-tier-helper.sh` |
| Prompt guard | Blocked/warned/sanitized injection attempts | `prompt-guard-helper.sh` |
| Session context | Composite security score (when t1428.3 available) | `session-security-helper.sh` |
| Quarantine | Pending review items (when t1428.4 available) | `quarantine-helper.sh` |

**Security posture levels:** CLEAN → LOW (flagged domains/warned injections) → MEDIUM (blocked injections) → HIGH (denied Tier 5 domains) → CRITICAL (audit chain integrity broken).

## Related

- `workflows/session-manager.md` - Session lifecycle management
- `workflows/session-analysis.md` - Harness, model-routing, and observed-repository analysis
- `tools/build-agent/agent-review.md` - Agent improvement process
- `workflows/preflight.md` - Pre-commit quality checks
- `workflows/postflight.md` - Post-release verification
- `tools/security/tamper-evident-audit.md` - Audit log documentation
- `tools/security/prompt-injection-defender.md` - Prompt guard documentation

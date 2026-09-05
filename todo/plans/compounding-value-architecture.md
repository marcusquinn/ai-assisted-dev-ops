<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->

# Compounding-value architecture roadmap

Parent task: t18402. This repo-native plan is the durable record; linked forge
issues are execution conversations, not the only copy of the requirements.

## Maintainer direction: preserve this purpose

1. Aidevops is a value-layering and automation system for information flows, not
   a Q&A entertainment product. All covered domains can be codified, systemised
   and improved through DevOps principles and tool leverage.
2. The aim is compounding user value without compounding user time, supervision
   or attention requirements. Time and money are the ultimate value measures;
   tokens, calls, checks and task counts are supporting diagnostics.
3. A user becoming 100x more capable at value generation is an ambition to work
   towards and substantiate, not an established benchmark result or guarantee.
4. Tasks, TODOs/Beads, plans, material decisions, evidence and progress belong to
   durable repository knowledge. GitHub, GitLab, Gitea and Forgejo are portable
   execution-conversation surfaces. Loss of a forge must not lose plans/progress.
5. Build+ remains the default for development, systems and apps. Other primary
   domains provide focus. Delegated work may use a relevant main-domain profile
   or a lighter profile, with narrower scope rather than weaker safeguards.
6. Preserve hard-won lessons, provenance and intentional boundary reinforcement.
   Optimise delivery and activation, not knowledge volume or instruction counts
   for their own sake. Do not classify non-coding domains as outside DevOps.
7. Organisational single sources of truth and dependent updates must be
   structural: generated views, explicit ownership, consistency checks and
   verified migration/fallback behavior rather than reminders to update copies.
8. Model judgment owns prioritisation, economics, semantic decisions and
   trade-offs; deterministic tooling owns reproducible mechanics and invariants.

## Authority and scope

The user requested repo-native briefs/TODOs and linked implementation issues.
This planning change does not implement the downstream architecture, alter
production prompts, publish a release, buy services or authorize paid API use.
Worker-ready children should become auto-dispatch eligible only after their
complete repo snapshot is published and dependency edges are verified. The parent
is coordination-only and must remain `parent-task`, without auto-dispatch.

## Evidence and deduplication

Discovery was refreshed at source commit
`5393632ee048f17385f94032189fa71825285a72` on 2026-09-05. Memory searches returned
no matching entry; the maintainer's direction above is preserved directly from
the conversation rather than inferred from those searches.

- PR #31249 delivered the local OAuth-backed FrontierHarness pilot. Its guide
  and six recorded cells are at
  `.agents/tools/ai-assistants/frontier-harness-eval.md` and the adjacent JSON.
  Normal stock/plugin arms both passed; the plugin arm used more input/time on
  the one short task. At calibrated 18,432 context, custom/native compaction both
  passed after two compactions, with mixed resource results. The 16,384 setting
  was infeasible after OpenCode's reserve and caused repeated compaction/timeouts.
  This is not the full suite, installed Build+ experience, or K3 leaderboard.
- PR #31228 / issue #31225 already preserves instruction provenance and adds
  `context-catalogue.mjs` for exact instruction-body deduplication and compact
  generated skill advertising. Do not reimplement it or reintroduce size quotas.
- PR #31207 already adds interactive runtime launch commands/main-agent selection;
  PR #31201 installs native Codex workflows. Inspect and extend their delivery
  routes rather than adding another launcher or skill installer.
- `todo/plans/context-engineering-refinement.md` already records canonical tier
  semantics and provenance safeguards. Do not reopen completed tier migration.
- Current README already states maximum value for time/money. The missing delta
  is the fuller operating purpose, repo/forge ownership, 100x ambition, structural
  drift prevention, and reliable inheritance during architecture/self-improvement.
- `get_agent_config()` puts the selected source in `description`, while `prompt`
  uses shared `build.txt`. This is a delivery risk to verify, not proof that every
  runtime loses the primary agent's knowledge.
- `buildClaudeArgs()` appends framework, selected agent and incoming system text
  without a source-identity check. Reproduce overlap before deduplicating; never
  strip similar-but-different rules or content across trust boundaries.
- Domain index has a stale `tools/task/beads.md` target, duplicate Networking/VPN
  rows, and overlapping Business/Accounting routes. Its readiness distinction is
  valuable and must survive direct-domain entry.
- Existing `progressive-load-check.sh` passed 24 checks in the review; it covers
  selected pointers, not complete delivered-context behavior or all graph edges.
- Session output-efficiency evidence reported 870,911 model-visible tool-output
  bytes, 26 oversized results and 25 successful oversized results. Categories
  overlap; this is review pressure, not proof all output was avoidable.
- Open PRs #31269 and #31252 concern checkpoint/worker recovery. Do not edit their
  moving implementation paths as incidental cleanup in these tasks.
- During briefing, the relationship helper exhausted its deadline with one backend
  mapping call and substantial unaccounted wait; the cause is not established.
  Durable created refs were preserved. Direct native relationship mutations and
  read-back verified all 10 parent links and 15 dependency edges. Reuse this
  evidence in t18404's sync/recovery audit rather than duplicating created issues.

## Work packages

The ten child briefs cover the following non-overlapping deliverables. `TODO.md`
owns their current forge-ref mapping; the stable repo IDs below remain useful
offline. No automatic phase auto-filing is requested because children are filed
explicitly in this planning batch.

| Unit | Deliverable | Depends on |
| --- | --- | --- |
| t18403 Purpose | Canonical purpose and prominent README/architecture/self-improvement inheritance | None |
| t18404 Portability | Repo/forge authority contract and an offline plans/progress recovery proof | t18403 |
| t18405 Startup | Verified primary-knowledge delivery and safe fallback across runtime launch routes | t18403 |
| t18406 Deduplication | Exact/provenance-aware Claude proxy context assembly | t18405 |
| t18407 Discovery | Owned discovery views, corrected routes and structural drift validation | t18403 |
| t18408 Delegation | Domain-primary and lighter child profiles with inherited safety/context bounds | t18405, t18407 |
| t18409 Activation | Action-scoped detailed guidance without weakening universal DevOps principles | t18405, t18407 |
| t18410 Operations | Existing operation receipts and helper interface discovery applied to observed costly paths | t18403 |
| t18411 Compaction | Usable-context calibration, bounded infeasible-run handling and faithful working-state handoff | t18405 |
| t18412 Value evaluation | Representative repeated outcomes/time/money/attention evaluation using existing tooling | t18404, t18408, t18409, t18410, t18411 |

## Delivery and preservation gates

- A parent link never substitutes for a substantive child brief. Every child
  retains its decisive constraints, files, hazards, verification and acceptance.
- Each rule moved has an identified owner, provenance, trigger and verified
  delivery before the protected decision. Unknown delivery defaults to keeping it.
- Registered, installed, authenticated and authorized are distinct states.
  Service readiness is checked before external actions, not as a ritual before
  every conceptual discussion. Availability never grants user authority.
- Each forge adapter preserves repo task identity. Foreign IDs are references.
  Rehydration must work without the original forge/account/session database and
  must not replay obsolete permissions or side effects.
- Reuse existing registries, receipt/state stores and test runners. New fixtures
  are justified only by a named material uncertainty or acceptance requirement.
- Do not default to deleting context, adding bureaucratic checklists, opening
  every tool, shrinking all windows, or inventing a new deterministic supervisor.
- Keep subscription OAuth separate from paid API spend. Existing authorization
  covers no paid provider/cloud purchases. Public examples use placeholders;
  private identifiers, raw conversations, solutions and credentials stay private.
- For multi-file/framework children, exercise the narrow production-facing path
  and preserve a WIP checkpoint before broad gates. A safety fuse leaves remaining
  acceptance open; resume through a safer bounded route rather than repeating the
  same failed shape or mistaking a checkpoint for completion.

## Completion evidence

The parent closes only when every explicitly linked child has delivered its
acceptance evidence, or the user has explicitly changed its scope. A planning
publication or one child's merge is not completion of this program. Subsequent
issues/PRs must link back to repo-native briefs; material execution decisions and
progress must be retained locally rather than left only in a forge thread.

---
description: Mission skill learning — auto-capture reusable patterns from missions, suggest promotion of temporary agents/scripts, track recurring patterns across missions
mode: subagent
model: standard  # pattern evaluation, not architecture-level reasoning
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: false
  grep: true
  webfetch: false
  task: false
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Mission Skill Learning

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Capture reusable patterns from missions, promote useful artifacts, feed learnings into cross-session memory
- **Script**: `scripts/mission-skill-learner.sh` — CLI for scanning, scoring, promoting, and tracking
- **Called by**: Mission orchestrator (Phase 5), pulse supervisor (mission completion), manual invocation
- **Stores to**: `memory.db` (mission_learnings table + memory entries via memory-helper.sh)

```bash
mission-skill-learner.sh scan <mission-dir>          # Scan a completed mission
mission-skill-learner.sh scan-all [--repo <path>]    # Scan all missions; paths: {repo}/todo/missions/*/mission.md + ~/.aidevops/missions/*/mission.md
mission-skill-learner.sh promote <path> [draft|custom]  # Copy artifact to target tier and record promotion
mission-skill-learner.sh patterns [--mission <id>]   # Identify artifacts recurring across missions
mission-skill-learner.sh suggest <mission-dir>       # Re-scan with detailed promotion suggestions
mission-skill-learner.sh stats                       # Artifact totals, promotion counts, missions scanned, memory pattern counts
```

**Related**:

| File | Purpose |
|------|---------|
| `workflows/mission-orchestrator.md` | Orchestrator that invokes skill learning at completion |
| `reference/memory.md` | Cross-session memory system |
| `tools/build-agent/build-agent.md` | Agent lifecycle tiers (draft/custom/shared) |
| `templates/mission-template.md` | Mission state file with "Mission Agents" table |

<!-- AI-CONTEXT-END -->

## When It Runs

| Stage | Action |
|-------|--------|
| During execution | Orchestrator records raw observations in the mission decision log; no scoring yet |
| Mission completion | `scan <mission-dir>` after `status: completed` — inspects `agents/` and `scripts/`, extracts decisions/lessons, scores artifacts (0-100), stores to `memory.db`, suggests promotions |
| Pulse follow-up | Detect completed-but-unscanned missions, run scan, report promotion candidates |

## Artifact Scoring

| Factor | Weight | Measures |
|--------|--------|----------|
| Generality | +30 | Not project-specific (no hardcoded paths, URLs, repo names) |
| Documentation | +20 | Has description, usage comments, structured sections |
| Size | +15 | Appropriate length (not trivial, not bloated) |
| Standard format | +15 | Follows aidevops conventions (frontmatter, set -euo, local vars) |
| Multi-feature usage | +20 | Referenced by multiple features within the mission |

## Promotion Lifecycle

| Tier | Score | Location | Notes |
|------|-------|----------|-------|
| Mission-only | < 40 | Mission directory | Too specific/trivial; learning still captured in memory |
| Draft | >= 40 | `~/.aidevops/agents/draft/` | Experimental, survives updates. `promote <path> draft` |
| Custom | >= 70 | `~/.aidevops/agents/custom/` | Proven useful across missions. `promote <path> custom` |
| Shared | >= 85 | Requires PR to aidevops repo | Flagged as candidate; user/supervisor creates PR |

`patterns` highlights artifacts recurring across missions; treat them as strong promotion candidates.

## Integration Points

### Cross-Session Memory

Store mission decisions, lessons, and failure modes as `MISSION_PATTERN` entries — surfaces via `/recall` during future mission planning, worker recovery, and pulse runs.

| Entry type | Memory type | Tags |
|------------|-------------|------|
| Decisions | `MISSION_PATTERN` | `mission,decision,{mission_id}` |
| Lessons | `MISSION_PATTERN` | `mission,lesson,{mission_id}` |
| Promotions | `MISSION_AGENT` | `mission,promotion,{tier},{name}` |

### Mission Orchestrator (Phase 5)

1. Run `mission-skill-learner.sh scan <mission-dir>`
2. For each suggestion with score >= 40, promote based on tier:
   - **Score 40-69**: `mission-skill-learner.sh promote <path> draft`
   - **Score 70-84**: `mission-skill-learner.sh promote <path> custom`
   - **Score >= 85**: do not use CLI promote; create an aidevops PR and follow shared-tier review
   - Leave project-specific artifacts in place even if their score qualifies for promotion
3. Record decisions in the mission's "Mission Agents" table
4. File GitHub issues for framework improvements; record in "Framework Improvements" section

### Pulse Supervisor

Detects missions with `status: completed` and no `mission_learnings` entries for that mission ID, runs the scan, and logs promotion candidates in the pulse report.

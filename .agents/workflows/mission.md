---
description: Interactive mission scoping — decompose a high-level goal into milestones, features, and a mission state file for autonomous multi-day execution
agent: Build+
mode: subagent
tools:
  read: true
  write: true
  edit: true
  bash: true
  task: true
  webfetch: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

Scope, plan, and launch a mission — autonomous multi-day project from idea to delivery. Reuses `/define` probe techniques at project scope.

Topic: $ARGUMENTS

## Step 0: Parse Arguments

```bash
HEADLESS=false; MISSION_DESC=""
if echo "$ARGUMENTS" | grep -q -- '--headless'; then
  HEADLESS=true; MISSION_DESC=$(echo "$ARGUMENTS" | sed 's/--headless//' | xargs)
elif echo "$ARGUMENTS" | grep -q ' -- '; then
  HEADLESS=true; MISSION_DESC=$(echo "$ARGUMENTS" | sed 's/ -- .*//' | xargs)
else
  MISSION_DESC=$(echo "$ARGUMENTS" | xargs)
fi
```

If `$MISSION_DESC` empty and not headless: ask "What's the mission? Describe the end goal in one sentence."

**Headless defaults** (`--headless` or ` -- ` in args):

| Setting | Default |
|---------|---------|
| Classification | auto-detect |
| Mode | Full (unless "poc"/"prototype"/"spike"/"research" in desc) |
| Time | 1 week |
| Cost | moderate |
| Infra | existing/local |
| Deps | none |

Run decomposition with opus. Output: `MISSION_ID={id} MISSION_DIR={path} MISSION_MODE={poc|full} MISSION_MILESTONES={n} MISSION_FEATURES={n} MISSION_STATUS=planning`

## Step 1: Mission Classification

| Type | Signal Words | Default Assumptions |
|------|-------------|---------------------|
| **greenfield** | build, create, launch, new, start | New repo, full stack, needs infrastructure |
| **migration** | migrate, port, convert, upgrade, move | Existing codebase, incremental, needs rollback plan |
| **research** | research, evaluate, compare, spike, prototype | Time-boxed, deliverable is recommendation + POC |
| **enhancement** | add, extend, improve, integrate, scale | Existing repo, linked worktrees, existing CI |
| **infrastructure** | deploy, configure, setup, provision, automate | DevOps focus, needs credentials, cloud accounts |

If ambiguous, present numbered options and ask.

## Step 2: Mode Selection

| Mode | Behaviour |
|------|-----------|
| **POC** | Commits to main/branch, no task briefs, no PR reviews, single worker per milestone |
| **Full** | Worktree + PR workflow, task briefs per feature, parallel worker dispatch, preflight/postflight (recommended for greenfield/enhancement) |

## Step 3: Budget and Constraints Interview

| Q | Options |
|---|---------|
| **Time budget** | 1 day / 2-3 days / 1 week *(rec. greenfield)* / 2+ weeks / No constraint |
| **Token/cost budget** | Minimal ($5-20) / Moderate ($20-100) / Generous ($100-500, rec. production) / Uncapped / Specify |
| **Infrastructure** | Local only / Existing / New needed / Specify |
| **External deps** | None / I'll provide credentials / Agent should research / List them |

## Step 4: Scope Probing (3 probes by type)

| Type | Probes |
|------|--------|
| **Greenfield** | (1) Pre-mortem: "Imagine this fails in {time_budget}. Most likely cause?" (2) User journey: "Who is the primary user and their first interaction?" (3) Non-negotiables: "What MUST work perfectly?" |
| **Migration** | (1) Rollback plan (2) Data integrity requirements (3) Incremental vs big-bang |
| **Research** | (1) Decision criteria (2) Deliverable format (3) Time-box for decision |
| **Enhancement/Infra** | Select 3 from greenfield + migration sets based on relevance |

## Step 5: Milestone Decomposition

Sequential milestones; features within a milestone are parallelisable. Each has a validation criterion. First = smallest viable increment. Last = "polish, docs, and deploy". Each feature = one `/full-loop` dispatch.

Present: `Mission: "{mission_desc}" | Mode: {poc|full} | Budget: {time_budget}/{cost_budget} | Type: {classification}`. Annotate features `[parallel-group:a]` or `[depends:N]`. Options: `1. Approve (rec) 2. Adjust milestones 3. Adjust features 4. Change mode 5. Start over`.

Run budget feasibility before presenting:

```bash
~/.aidevops/agents/scripts/budget-analysis-helper.sh recommend --goal "{mission_desc}" --json
~/.aidevops/agents/scripts/budget-analysis-helper.sh analyse --budget {cost_budget} --hours {time_budget} --json
```

If budget insufficient: present Tier 1 (guaranteed) / Tier 2 (likely) / Tier 3 (stretch).

## Step 6: Mission File Creation

```bash
if top_level=$(git rev-parse --show-toplevel 2>/dev/null); then
  MISSION_HOME="$top_level/todo/missions"
else
  MISSION_HOME="$HOME/.aidevops/missions"
fi
HASH=$(printf '%s' "$MISSION_DESC" | { md5 -q 2>/dev/null || md5sum | cut -d' ' -f1; } | cut -c1-6)
MISSION_ID="m-$(date +%Y%m%d)-${HASH}"
MISSION_DIR="$MISSION_HOME/$MISSION_ID"
mkdir -p "$MISSION_DIR"/{research,agents,scripts,assets}
```

State file structure: `templates/mission-template.md` (t1357.1). Sections: State, Goal, Constraints, Milestones (feature checklists with `[parallel-group:a]`/`[depends:F1]`), Budget Tracking, Decisions Log, Notes.

**Optional repo creation** (homeless + greenfield): `1. Create + init (rec) — git init + aidevops init  2. Use existing repo  3. Keep homeless`. If option 1:

```bash
REPO_DIR="$HOME/Git/$REPO_NAME"; mkdir -p "$REPO_DIR"; git -C "$REPO_DIR" init -q
mkdir -p "$REPO_DIR/todo/missions" || { echo "ERROR: mkdir failed" >&2; exit 1; }
mv "$MISSION_DIR" "$REPO_DIR/todo/missions/$MISSION_ID" || { echo "ERROR: mv failed" >&2; exit 1; }
```

## Step 7: Feature-to-Task Mapping (Full Mode Only)

```bash
repo_path=$(git rev-parse --show-toplevel)
while IFS= read -r feature_title; do
  output=$(~/.aidevops/agents/scripts/claim-task-id.sh --title "$feature_title" --repo-path "$repo_path")
  task_id=$(echo "$output" | grep '^TASK_ID=' | cut -d= -f2)
  # Create brief from mission context; add to TODO.md
  # Format: - [ ] {task_id} {feature_title} #mission:{mission_id} ~{est} ref:{ref}
done < <(awk '/^- \[ \] F[0-9]+:/{sub(/^- \[ \] F[0-9]+: /,""); print}' "$MISSION_DIR/mission.md")
```

POC mode: skip task creation — orchestrator dispatches features directly from mission state file.

## Step 8: Launch Confirmation

Print: `Mission created: {mission_id} | {mission_dir}/mission.md | Mode: {poc|full} | Milestones: {n} | Features: {n}`

Options: `1. Start now (rec) 2. Review file first 3. Queue for pulse 4. Edit before starting`. Option 1: POC → single `/full-loop` sequentially; Full → parallel features via pulse supervisor.

## Model Routing

| Phase | Model |
|-------|-------|
| Interview + classification | sonnet |
| Milestone decomposition | **opus** (complex reasoning, architecture decisions) |
| Feature brief generation | sonnet |
| Feature implementation | per mission budget (haiku for POC, sonnet/opus for Full) |

## Mission Lifecycle

`planning → active → paused → active → completed` / `active → recovering → active` / `active → blocked → active` / `→ cancelled`

A mission fuse transitions the affected feature to `recovering`, not `skipped`
or `done`. Append a durable recovery checkpoint and schedule the next safe route
before ending the invocation. A mission cannot complete while recovery criteria
remain open. Full invariant and recovery ladder:
`reference/safety-stop-recovery.md`.

Mission dirs: `research/` (comparisons, API evals), `agents/` (temp agents, draft tier), `scripts/` (automation), `assets/` (screenshots, PDFs). Promote generally-useful agents/scripts to `~/.aidevops/agents/draft/` and log in decisions log.

## Related

- `scripts/commands/goals.md` — Goal-oriented alias and dashboard entrypoint for missions
- `scripts/commands/define.md` — Interview technique (reused for scoping)
- `scripts/commands/full-loop.md` — Worker execution (dispatched per feature)
- `scripts/commands/pulse.md` — Supervisor dispatch (mission-aware)
- `workflows/plans.md` — Planning patterns for decomposition
- `~/.aidevops/agents/templates/brief-template.md` — Brief format (Full mode features)
- `templates/mission-template.md` — Mission state file template (t1357.1)
- `tools/build-agent/build-agent.md` — Agent lifecycle (draft tier for mission agents)
- `reference/orchestration.md` — Model routing for mission workers
- `scripts/budget-analysis-helper.sh` — Budget analysis engine (t1357.7)
- `scripts/budget-tracker-helper.sh` — Append-only cost log for historical spend data
- `scripts/commands/budget-analysis.md` — `/budget-analysis` command for interactive use

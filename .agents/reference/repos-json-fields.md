# repos.json Field Reference

Config file: `~/.config/aidevops/repos.json`. Structure: `{"initialized_repos": [...], "git_parent_dirs": [...]}`.

**CRITICAL:** New entries MUST go inside the `initialized_repos` array — never as top-level keys. After any write, validate: `jq . ~/.config/aidevops/repos.json > /dev/null`. A malformed file silently breaks the pulse for ALL repos.

## Core Fields

| Field | Type | Description |
|-------|------|-------------|
| `slug` | string | `owner/repo` — ALWAYS use this for `gh` commands, never guess org names |
| `pulse` | bool | `true` = active development, tasks, issues. `false` = no task management |
| `maintenance` | bool | Missing/`true` = include in recurring cross-repo maintenance. `false` = keep registered but omit from routine API scans, workflow/badge rollout, and Pulse. |
| `local_only` | bool | No remote; skip all `gh` operations |
| `priority` | string | `"tooling"` (infrastructure), `"product"` (user-facing), `"profile"` (docs-only) |
| `maintainer` | string | GitHub username. Auto-detected from `gh api user`; falls back to slug owner |
| `role` | string | `"maintainer"` or `"contributor"`. Controls which pulse scanners run |
| `init_scope` | string | `"minimal"`, `"standard"` (default), or `"public"`. Controls `aidevops init` scaffolding |
| `has_interface` | bool | Explicit GUI/interface flag. `true` forces DESIGN.md scaffolding/backfill; `false` suppresses heuristic interface detection. |
| `agent_source` | bool | `true` = repo is a managed private agent source pack; `aidevops init` seeds core-style agent structure and `aidevops update` refreshes framework-owned organization templates |
| `features` | array | Enabled registration capabilities. `"code-quality"` activates lint policy migration and repo-verify hook rollout unless `.aidevops.json` explicitly opts out. |

### `role` detail

- **`maintainer`** (default for repos you own): all scanners run
- **`contributor`** (default for repos owned by others): session-miner insights only — files sanitized `contributor-insight` issues upstream from instruction candidates and error patterns in the contributor's own sessions. Privacy: strips private repo slugs, local file paths, credentials, email addresses.

Registration persists `maintainer` when GitHub reports `ADMIN`, `MAINTAIN`, or
`WRITE`, including organization-owned repositories, and persists `contributor`
for confirmed lower permissions. If permission evidence is unavailable, it does
not persist a downgrade; runtime resolution remains fail-closed until a later
registration can record authoritative permission. Existing explicit roles are
always preserved.

### `init_scope` detail

- `minimal`: project-specific files only (TODO.md, AGENTS.md, .aidevops.json, .gitignore, .gitattributes)
- `standard`: adds DESIGN.md, MODELS.md, collaborator pointers, README.md
- `public`: adds LICENCE, CHANGELOG.md, CONTRIBUTING.md, SECURITY.md, CODE_OF_CONDUCT.md

Auto-inferred when absent: `local_only`/no-remote → `minimal`; others → `standard`. Stored in `.aidevops.json` per project. Preserved on re-registration.

Repository-native verification policy lives in `.aidevops.json.features.code_quality`
and `.aidevops.json.verify`. `aidevops lint audit` reports registration/config
drift. Update migrations preserve explicit `false`, unknown keys, and tracked
configuration on canonical `main`/`master`; tracked changes require a linked-worktree PR.

### `has_interface` detail

`aidevops init` records this field in `.aidevops.json` and mirrors it into `repos.json` during registration. When absent, design helpers infer it from UI markers such as Next/Vite/Nuxt/Astro/Svelte config, React/Vue/Svelte entry files, view templates, frontend/client/web directories, or UI dependencies. Minimal-scope repos with `has_interface: true` still receive a root `DESIGN.md`; standard/public scopes continue to seed it by default.

### `agent_source` detail

Set `"agent_source": true` on private repos that store aidevops agent packs. `"role": "agent-source"` is also accepted for compatibility, but the boolean field is preferred because it does not overload maintainer/contributor scanner role semantics.

Agent-source repos receive non-destructive template management:

- `aidevops init` creates root `AGENTS.md`, `.agents/AGENTS.md`, and the core-style `.agents/` skeleton when absent.
- `aidevops update` revisits every managed repo marked as an agent source and refreshes only framework-owned managed blocks marked with `<!-- aidevops:agent-source-template:* -->`.
- User-authored files without the managed markers are never overwritten.
- Public TODO entries, issue text, logs, and comments must not include private repo slugs; use generic wording such as "a managed private agent source repo".

## Scheduling and Lifecycle Fields

Registration, maintenance, and Pulse are separate scopes:

- Registration retains canonical path resolution, history, privacy guards, and
  explicit one-repository commands.
- `maintenance: false` marks a repository dormant. Recurring all-repository
  scans omit it, while an explicit `--repo owner/repo` check or repair may still
  target it without bypassing `local_only`, contributor, or permission gates.
- `pulse: true` additionally enables active task/issue automation. Dormant
  repositories are never Pulse-eligible; the CLI disables Pulse when pausing
  maintenance and does not silently re-enable it on resume.
- Safety hygiene remains registration-scoped: privacy inventory, stale claim and
  dispatch-label cleanup, dirty-PR recovery, and local worktree cleanup continue
  to see dormant repositories but never use dormancy to authorize new work.
- Missing `maintenance` defaults to `true` for backward compatibility.

Manage the state without hand-editing JSON:

```bash
aidevops repos maintenance off owner/repo
aidevops repos maintenance on owner/repo
```

| Field | Type | Example | Description |
|-------|------|---------|-------------|
| `pulse_hours` | object or array | `{"start": 17, "end": 5}` or `[17, 5]` | Limits dispatch to window (24h local time). Overnight supported. Omit for 24/7. Array form is accepted for compatibility; object form is preferred for readability. |
| `pulse_interval` | integer | `600` | Minimum seconds between dispatch polls for this repo. Default: omit (poll every cycle). Min: 60. Useful for contributor-role repos with low activity — e.g. 600 polls every 5 cycles instead of every cycle, reducing GraphQL budget consumption ~5×. State: `~/.aidevops/logs/pulse-last-per-repo.json`. |
| `pulse_expires` | string | `"2026-05-01"` | Past this date, pulse auto-sets `pulse: false`. Useful for temporary windows. |
| `dependabot_alert_monitor` | bool | `true` | For `pulse: true` maintainer repos, pulse checks open GitHub Dependabot alerts and creates grouped, neutral, worker-ready remediation issues. Set `false` to opt out for repos that handle dependency alerts elsewhere. |

## PR Throughput Preferences

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `pr_base_branch` | string | GitHub default branch | Branch workers should target when creating or recovering PRs. Use for repos whose integration branch differs from the GitHub default branch, e.g. `"develop"`. Aliases accepted by orphan recovery: `pr_target_branch`, `base_branch`, `default_branch`. |
| `interactive_pr_auto_merge` | bool | unset → global config/default | Per-repo preference for `origin:interactive` PR merge throughput. `true` allows pulse to merge maintainer-authored interactive PRs after normal gates pass and the PR is ready/non-draft. `false` keeps this repo manual even if global config is true. PR-specific `allow-auto-merge` still opts in one PR; `hold-for-review` or draft state still blocks. |

Global equivalent: `orchestration.interactive_pr_auto_merge` in `~/.config/aidevops/config.jsonc`. Env override for the current pulse/session: `AIDEVOPS_INTERACTIVE_PR_AUTO_MERGE`.

## Workflow Runner Configuration

| Field | Type | Example | Description |
|-------|------|---------|-------------|
| `runner` | string | `"ubicloud-standard-2"` | Runner label for managed reusable workflows (`issue-sync`, `maintainer-gate`, `review-bot-gate`, `loc-badge`). Omit to inherit the reusable workflow default (`ubuntu-latest`). Consumed by `aidevops sync-workflows --apply` — injected as `with: runner: <label>` in the caller YAML and preserved across future syncs. Self-hosted label groups must be YAML-encoded as a string: `"[self-hosted, linux, x64]"`. See `reference/reusable-workflows.md` "Runner override". |

## Contribution and FOSS Fields

| Field | Type | Description |
|-------|------|-------------|
| `contributed` | bool | External repos authored/commented on. Read-only monitoring; no merge/dispatch/TODO powers. Managed by `contribution-watch-helper.sh`. |
| `foss` | bool | FOSS contribution target. Enables `foss-contribution-helper.sh` budget enforcement. Combine with `app_type` and `foss_config`. See `reference/foss-contributions.md`. |
| `app_type` | string | FOSS repo type: `wordpress-plugin`, `php-composer`, `node`, `python`, `go`, `macos-app`, `browser-extension`, `cli-tool`, `electron`, `cloudron-package`, `generic` |
| `foss_config` | object | Per-repo FOSS controls (see below) |

### `cloudron_package` object fields

When `CloudronManifest.json` exists, `aidevops init` safely defaults
`app_type` to `cloudron-package` and adds lifecycle metadata without replacing
explicit values. Package slugs and paths remain local to `repos.json`.

| Key | Default | Description |
|-----|---------|-------------|
| `manifest` | `CloudronManifest.json` | Manifest path relative to the registered repository root. Absolute paths and `..` are rejected by monitors. |
| `release_workflow` | `.github/workflows/cloudron-package-release.yml` | Thin tag-triggered caller scaffolded by `aidevops init`; existing files are never overwritten. |
| `upstream_slug` | unset | Upstream GitHub `owner/repo` used for stable-release comparison. Monitoring stays disabled until this is explicitly configured. |
| `upstream_tag_prefixes` | `["v", ""]` | Non-empty array of tag-stream prefixes. Each value must be a string; ASCII control characters are rejected, while the empty string allows bare semantic tags. Only tags whose configured prefix leaves a semantic version are candidates. |
| `monitor_upstream` | `true` when `upstream_slug` is set; otherwise `false` | Include the package in the daily upstream-release routine. |
| `monitor_compatibility` | `true` | Include the package in the weekly manifest and pinned-base audit. |

```json
{
  "app_type": "cloudron-package",
  "cloudron_package": {
    "manifest": "CloudronManifest.json",
    "upstream_slug": "exampleorg/example-upstream",
    "upstream_tag_prefixes": ["v", ""],
    "monitor_upstream": true,
    "monitor_compatibility": true
  }
}
```

Use a package-specific stream when one upstream repository publishes releases
for multiple products. For example, this accepts `desktop-v0.5.3` while
rejecting unrelated `v...` tags:

```json
{
  "cloudron_package": {
    "upstream_slug": "exampleorg/multi-product-upstream",
    "upstream_tag_prefixes": ["desktop-v"],
    "monitor_upstream": true
  }
}
```

The upstream monitor paginates all GitHub releases, excludes drafts and
prereleases, and chooses the numerically highest stable semantic version from
the configured streams. Invalid prefix configuration or no matching stable tag
fails closed with a diagnostic rather than falling back to another stream.

The monitors file deduplicated findings only in the package repository and only
with `ADMIN` or `MAINTAIN` authority. They never build, tag, publish, deploy, or
mutate package source. See `tools/deployment/cloudron-app-packaging.md`.

### `foss_config` object fields

| Key | Default | Description |
|-----|---------|-------------|
| `max_prs_per_week` | 2 | Weekly PR budget |
| `token_budget_per_issue` | 10000 | Enforced by `foss-contribution-helper.sh check` |
| `blocklist` | false | Maintainer opt-out flag |
| `disclosure` | true | AI note in PRs |
| `labels_filter` | `["help wanted", "good first issue", "bug"]` | Issue labels to target |

## Review Gate Configuration

`review_gate` — per-repo review add-on configuration (t2123, GH#19173; extended in t2139, GH#19251). Required project CI controls merge readiness by default; add-on completion becomes blocking only through explicit strict configuration.

```json
{
  "rate_limit_behavior": "pass",
  "completion_behavior": "fast",
  "min_edit_lag_seconds": 30,
  "advisory_check_contexts": ["CodeRabbit"],
  "tools": {
    "coderabbitai": {
      "rate_limit_behavior": "wait",
      "min_edit_lag_seconds": 90
    }
  }
}
```

| Field | Default | Description |
|-------|---------|-------------|
| `rate_limit_behavior` | `"pass"` | `"pass"` exits 0 for bot rate limits and trusted internal API exhaustion, delegating late feedback to the post-merge scanner; `"wait"` blocks when evidence cannot be evaluated. External/unknown authors always block. |
| `completion_behavior` | `"fast"` | `"fast"` is the permanent advisory default: absent, pending, unavailable, or late add-on review does not delay a merge after required CI passes. `"strict"` explicitly opts into review-before-merge and terminal completion evidence. |
| `min_edit_lag_seconds` | 30 | Seconds a bot comment must be "settled" before it counts. Defeats CodeRabbit's two-phase placeholder (stub at ~14s, final edit at ~90-120s). |
| `advisory_check_contexts` | `[]` | Exact non-required review-provider check names that may be advisory only when typed live evidence permits the outcome for the current PR head and review threads are resolved. Required, maintainer-gate, unknown, malformed-evidence, and external rate-limit failures always block. |
| `tools` | — | Per-tool overrides keyed by active bot login (`coderabbitai`, `augment-code`, `augmentcode`, `copilot`). The retired `gemini-code-assist` key is ignored by gate policy and accepted by the CLI only with `unset` for cleanup. |

Resolution order (per field independently): per-tool > per-repo > env var (`REVIEW_GATE_RATE_LIMIT_BEHAVIOR`, `REVIEW_GATE_COMPLETION_BEHAVIOR`, or `REVIEW_BOT_MIN_EDIT_LAG_SECONDS`) > hard default.

The reusable workflow exposes matching `rate_limit_behavior` and `completion_behavior` inputs for CI callers. Their defaults are `pass` and `fast`. The canonical caller maps the repository Actions variable `AIDEVOPS_REVIEW_GATE_COMPLETION_BEHAVIOR` to the completion input and falls back to `fast` when unset. `fast` never waits for add-on completion on trusted maintainer-controlled PRs; late findings are swept into follow-up issues. Set both the local `review_gate.completion_behavior` and the CI variable to `strict` only when a repository explicitly accepts the added delay of review-before-merge. External/unknown authors retain the GH#17671 defence-in-depth boundary, and per-tool `wait`/`strict` overrides remain fail-closed when provider identity cannot be evaluated.

CLI: `aidevops review-gate --help` — configure rate-limit/completion policy and add or remove exact advisory check contexts without hand-editing JSON.

## Knowledge Plane

| Field | Type | Values | Description |
|-------|------|--------|-------------|
| `knowledge` | string | `"off"` (default), `"repo"`, `"personal"` | Controls knowledge plane provisioning. `"off"`: no plane (backwards-compatible default). `"repo"`: provisions `_knowledge/` inside the repo. `"personal"`: provisions at `~/.aidevops/.agent-workspace/knowledge/`. |

CLI: `aidevops knowledge init [repo|personal|off]` — sets field and provisions directories.
See `.agents/aidevops/knowledge-plane.md` for the full directory contract, meta.json schema, and 30MB threshold rationale.

## Cases Plane

| Field | Type | Values | Description |
|-------|------|--------|-------------|
| `cases` | string | `"off"` (default), `"repo"`, `"personal"` | Controls cases plane provisioning. `"off"`: no plane (backwards-compatible default). `"repo"`: provisions `_cases/` inside the repo. `"personal"`: provisions at `~/.aidevops/.agent-workspace/cases/`. |

CLI: `aidevops case init [<repo-path>]` — sets `cases: "repo"` and provisions directories.
See `.agents/aidevops/cases-plane.md` for the full directory contract, dossier.toon schema, and timeline format.

## Platform Integration

| Field | Values | Description |
|-------|--------|-------------|
| `platform` | `"shopify"` | Platform-specific MCP server integration. `"shopify"` enables `shopify-dev-mcp` (schema-aware GraphQL, Liquid validation, Admin API). Requires Shopify CLI 3.93.0+. Config: `configs/mcp-templates/shopify-dev-mcp-config.json.txt`. |

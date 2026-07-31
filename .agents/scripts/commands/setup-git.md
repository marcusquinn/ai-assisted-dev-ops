<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# /setup-git — Guided Per-Repo Platform Secret Setup

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Command**: `/setup-git`
- **Aggregator**: `~/.aidevops/agents/scripts/setup-debt-helper.sh`
- **Detector**: `~/.aidevops/agents/scripts/security-posture-helper.sh` (Phase 7)
- **Platform matrix**: `reference/sync-pat-platforms.md`
- **Sister command**: `/onboarding` — per-account auth (different scope)

## Scope

`/setup-git` is **per-repo platform secret setup** — most importantly `SYNC_PAT`, the
fine-grained PAT that allows the `issue-sync` workflow to author issues as the
maintainer instead of as `github-actions[bot]`. Without `SYNC_PAT`, every synced
issue carries `author_association: NONE` and the t2449 worker-briefed auto-merge
gate refuses to merge worker PRs.

**Use `/setup-git` when**:

- The toast shows `[WARN] N repos need SYNC_PAT setup`
- The toast shows `[WARN] N repos need workflow re-sync` (cross-account secrets:inherit)
- A worker PR sits BLOCKED with all-green CI
- You just registered a new repo via `aidevops init` or hand-edited `repos.json`
- You're onboarding a new operator and want every active repo's secrets right

**Use `/onboarding` instead when**:

- You need per-account auth (`gh auth login`, `glab auth login`, `tea login`)
- You need API keys for AI services (`OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, etc.) in `~/.config/aidevops/credentials.sh`
- You're setting up a new machine and don't yet have any repos cloned

## Security Posture (NON-NEGOTIABLE)

This command **never** accepts secret values in conversation. The fix path is
always `gh secret set NAME --repo SLUG` run **interactively in a separate
terminal** so the value never lands in the AI session transcript or shell
history (the `gh secret set` interactive prompt also avoids `--body "$VALUE"`,
which would leave the token in process listings).

The agent's job is: read the debt summary → tell the operator which URL to open →
confirm with `setup-debt-helper.sh verify-secret` once they're done. **No tool call ever has
a secret value as an argument.**

If the operator pastes a token into the conversation, refuse it explicitly,
discard the message context, and ask them to reset the conversation if any AI
in the loop has training-data risk. (For Claude Code / OpenCode this risk is
minimal but the discipline still applies.)

<!-- AI-CONTEXT-END -->

## Agent Workflow

When invoked, walk the operator through these phases. Skip phases that are
already clean (no debt → fast path to "all set").

### Phase 1 — Inventory

Run the aggregator and present the result:

```bash
~/.aidevops/agents/scripts/setup-debt-helper.sh summary --format=human
```

Then list both debt classes:

```bash
~/.aidevops/agents/scripts/setup-debt-helper.sh list-sync-pat-missing
~/.aidevops/agents/scripts/setup-debt-helper.sh list-cross-account-inherit
```

For each slug, also fetch the platform from `~/.config/aidevops/repos.json`
so you can route to the correct PAT URL template:

```bash
jq -r --arg slug "$SLUG" '.initialized_repos[] | select(.slug == $slug) | .platform // "github"' ~/.config/aidevops/repos.json
```

If `setup-debt-helper.sh summary` returns empty, congratulate the operator
and exit — there is nothing to do.

### Phase 1.5 — Cross-Account secrets:inherit Remediation (t2880)

For each repo returned by `list-cross-account-inherit`, present this template:

```text
=== Repo: <SLUG> — workflow re-sync needed ===

Why this matters: your .github/workflows/issue-sync.yml was installed before
#20976 fixed the canonical caller template. It uses `secrets: inherit` instead
of an explicit SYNC_PAT mapping. GitHub only propagates secrets:inherit within
the same org/enterprise — callers from a different account receive no secrets,
so issue-sync silently fails.

Fix (one command — run in a separate terminal):

  aidevops sync-workflows --apply --repo <SLUG>

This replaces the secrets:inherit line in issue-sync.yml with the explicit
mapping from the updated template and opens a PR in <SLUG> to apply the change.

After the PR merges, verify:

  aidevops check-workflows --repo <SLUG>

The workflow should be classified as CURRENT/CALLER with no drift.

Dismiss without re-syncing (e.g., intentional fork with own secrets):
  aidevops security dismiss cross-account-inherit-<SLUG_SAFE>
```

After the operator confirms the re-sync PR is merged, move on.

### Phase 1.6 — Public Repo PR-Gating Remediation (GH#22195)

For public repos where the current GitHub token has admin access,
`aidevops security check` treats missing effective PR merge gating as an
actionable failure. This setup command may guide the operator, but it must not
silently change branch protection during unrelated secret setup.

Use this template for each affected public ADMIN repo:

```text
=== Repo: <SLUG> — branch protection / ruleset setup needed ===

Why this matters: public repos need GitHub-enforced pull requests and required
status checks on the default branch. Independent review should also be required
when at least two review-eligible humans have write access. Pulse-side merge
logic is defense in depth, not a substitute for repository protection.

Fix (maintainer/admin action — run explicitly in GitHub settings or a separate
terminal):

  1. Ensure review-bot-gate.yml and maintainer-gate.yml are installed/current:
       aidevops check-workflows --repo <SLUG>
       aidevops sync-workflows --apply --repo <SLUG>   # only if drift/missing

  2. In GitHub Settings → Rules → Rulesets (preferred) or Branches → Branch
     protection, target the default branch and require:
       - Pull request before merging
       - At least 1 approving review when two or more review-eligible humans
         have push, write, maintain, or admin access
       - Zero required approvals is the default for a verified solo-maintainer
         repo, unless the maintainer explicitly requests review
       - Required status checks, including review-bot-gate and maintainer-gate
       - No admin bypass for public ADMIN repos unless consciously documented

  3. Verify:
       aidevops security check --repo <SLUG>

Do not ask the AI session to apply protection implicitly; this changes repo
security posture and should be a deliberate maintainer/admin action.
```

### Phase 1.7 — Linked-Issue PR Check Audit (GH#23906)

For GitHub-hosted repos in `~/.config/aidevops/repos.json` that are not marked
`local_only`, audit whether `.github/workflows/linked-issue-check.yml` is
installed and whether `linked-issue-check` is required by branch protection or
an active ruleset. This is report-only: do not mutate branch protection or
rulesets during `/setup-git`.

Use this template for each affected repo:

```text
=== Repo: <SLUG> — linked-issue PR check setup needed ===

Why this matters: human-authored PRs must reference an existing issue with one
of the accepted keywords: Closes/Fixes/Resolves/For/Ref #NNN. The
linked-issue-check status enforces that contract before merge.

Audit:

  aidevops security posture check <PATH_TO_REPO>

Fix (maintainer/admin action — run explicitly in GitHub settings or a separate
terminal):

  1. Ensure .github/workflows/linked-issue-check.yml exists in <SLUG>.
  2. In GitHub Settings → Rules → Rulesets (preferred) or Branches → Branch
     protection, require the status check named linked-issue-check on the
     default branch.
  3. Verify:
       aidevops security posture check <PATH_TO_REPO>

Skip repos with platform != github or local_only=true.
```

### Phase 2 — Per-Repo Walkthrough

For each repo with missing `SYNC_PAT`, present this template (substitute slug
and platform). Read the platform-specific section from
`reference/sync-pat-platforms.md` and emit the URL with required scopes
pre-encoded.

#### GitHub example

```text
=== Repo: <SLUG> (platform: github) ===

Why this matters: without SYNC_PAT on this repo, issues created by
issue-sync.yml are authored by github-actions[bot] (author_association NONE),
which causes the t2449 worker-briefed auto-merge gate to refuse to merge
worker PRs. Setting SYNC_PAT once unblocks every future worker PR on this
repo.

Step 1 — Create a fine-grained PAT
   Open this URL in your browser. Scopes are pre-filled:

     https://github.com/settings/personal-access-tokens/new?name=aidevops-sync-<SLUG_SAFE>&description=aidevops%20issue-sync%20PAT%20for%20<SLUG_URLENC>&expiration=90&target_name=<OWNER>&permissions=contents:write,issues:write,pull_requests:write,metadata:read

   Set repository access to "Only select repositories → <SLUG>".
   Click Generate. Save the generated token.

Step 2 — Save to your password manager NOW
   GitHub will not show this token again. Add an entry like:

     Title:    aidevops SYNC_PAT — <SLUG>
     URL:      https://github.com/settings/personal-access-tokens
     Expiry:   <90 days from today>
     Notes:    Fine-grained PAT, scoped to <SLUG> only.
               Used by .github/workflows/issue-sync.yml.

Step 3 — Set the repo secret (SEPARATE TERMINAL)
   In a new terminal window — NOT this AI session — run:

     gh secret set SYNC_PAT --repo <SLUG>

   The CLI will prompt for the value. Paste the token there. This keeps the
   token out of this conversation transcript and out of shell history.

Step 4 — Confirm setup landed
   Type: verify <SLUG>

   I will run setup-debt-helper.sh verify-secret which checks `gh secret list`
   for SYNC_PAT presence — it never reads the value.
```

#### Other platforms

GitLab, Gitea, Bitbucket: read the appropriate section of
`reference/sync-pat-platforms.md`. If a platform is listed as "stub" in the
matrix, emit a clear "manual setup required, see `<docs URL>`" message and move
to the next repo.

### Phase 3 — Verification

When the operator types `verify <SLUG>` (or `verify all`):

```bash
# Per-repo
~/.aidevops/agents/scripts/setup-debt-helper.sh verify-secret <SLUG> SYNC_PAT

# All known
~/.aidevops/agents/scripts/setup-debt-helper.sh list-sync-pat-missing | \
    while IFS= read -r slug; do
        ~/.aidevops/agents/scripts/setup-debt-helper.sh verify-secret "$slug" SYNC_PAT
    done
```

Report each result. On confirmed-set repos, the next pulse cycle's
`security-posture-helper.sh` run will detect SYNC_PAT and remove the advisory
file automatically — no manual dismiss step needed.

If the operator wants to dismiss without setting (e.g., they've decided this
repo doesn't need worker auto-merge):

```bash
aidevops security dismiss sync-pat-<SLUG_SAFE>
```

### Phase 4 — Wrap

After all advisories are addressed, summarise:

- Number of repos walked
- Number now set vs dismissed vs deferred
- Reminder to verify expiry calendar entries are saved in their password manager
- Pointer to the next pulse cycle re-running `aidevops security check` (no manual rerun needed)

## Out of scope (Phase 1)

These belong in follow-up tasks; do not attempt them in `/setup-git`:

- Repo discovery / auto-registration of unregistered `~/Git/*` directories — Phase 2
- Multi-platform full implementation (GitLab/Gitea/Bitbucket guided flow) — Phase 2
- AI review keys (`OPENAI_API_KEY`, `CODERABBIT_API_KEY` per-repo) — Phase 3
- `gh auth` scope checks, default-branch drift, workflow-file drift — separate `aidevops security check` covers these
- Writing a manifest of confirmed-set secrets — Phase 2

If the operator asks for any of the above, point them at the relevant
follow-up issue (filed off this PR) and continue with the in-scope SYNC_PAT
walkthrough.

## Cross-references

- `aidevops/onboarding.md` — per-account auth (the `/onboarding` command)
- `reference/sync-pat-platforms.md` — PAT URL templates and scopes per platform
- `reference/reusable-workflows.md` — cross-account secrets architecture and caller template
- `AGENTS.md` "Security Rules" — secret handling principles
- `tools/credentials/gopass.md` — preferred secret store for AIDEVOPS env vars
- t2449 (auto-merge.md) — why SYNC_PAT matters for worker auto-merge
- t2374 (auto-dispatch.md) — original SYNC_PAT advisory infrastructure
- t2806 / GH#20745 — rulesets-protected repo detection (sibling fix)
- t2880 / GH#20981 — cross-account secrets:inherit detection (this command's Phase 1.5)

## Related issues

- GH#20812 — t2816 — this command's parent task
- GH#20743 — t2805 — `pulse-merge.sh` rebase-before-fix-worker (sibling)
- GH#20745 — t2806 — `security-posture-helper.sh` rulesets detection (dependency)

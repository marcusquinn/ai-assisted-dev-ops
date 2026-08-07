<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# SYNC_PAT — Platform Matrix

Canonical reference for the `SYNC_PAT` secret used by the `issue-sync`
workflow across supported git platforms. Consumed by `/setup-git` to
generate platform-specific PAT-creation URLs and secret-set instructions.

## What `SYNC_PAT` is

A platform personal access token configured as a **per-repo** secret named
`SYNC_PAT`. The `issue-sync` reusable workflow uses it to authenticate as the
maintainer (instead of the platform's bot identity) when:

- Creating issues from `TODO.md` entries that lack `ref:GH#NNN`
- Pushing back the auto-injected `chore: sync ref:GH#NNN to TODO.md [skip ci]`
  commit after the issue is created

When unset, the workflow falls back to the platform's default token (`GITHUB_TOKEN`
on GitHub Actions). Issues are then authored by the bot, which:

1. Reports `author_association: NONE` (or platform equivalent), tripping the
   t2449 worker-briefed auto-merge gate.
2. Cannot push to a branch-protected default branch on most platforms. The
   workflow routes terminal GH006 rejection through one deterministic PR; if
   Actions PR creation is disabled, the job token cannot open that PR either.

`SYNC_PAT` does not weaken or bypass default-branch protection. Direct GH006
rejection still routes through review and required checks. The PAT is used as
the bounded PR API fallback only after the job token fails and concurrent-PR
recovery finds nothing.

## Security posture (cross-platform)

Three rules apply on every platform:

1. **Per-repo PAT**, never an org-wide / account-wide token. Blast radius of a
   leaked token is limited to one repo's contents+issues+PRs.
2. **Fine-grained / scoped to specific repos**, never "all repos" or
   "classic / personal scope". Most platforms now have a fine-grained option;
   use it.
3. **Save to password manager at creation time**. Most platforms only show
   the token once. Rotation reminders (90 days default) belong in the
   password manager entry, not in shell scripts.

## Platform Matrix

| Platform | Status | Native CLI | Secret Storage | Notes |
|----------|--------|------------|----------------|-------|
| GitHub | **Primary** (Phase 1) | `gh` | `gh secret set` | Fine-grained PAT, query-string scope encoding |
| GitLab | Stub (Phase 2) | `glab` | `glab variable set` | Project-scoped PAT, manual scope selection |
| Gitea | Stub (Phase 2) | `tea` | Manual repo secret UI | Token + repo-secret; no native query-string encoding |
| Bitbucket | Stub (Phase 2) | (none) | Repository variables UI | App passwords; no native CLI; setup is fully manual |

---

## GitHub (Primary, Phase 1 implemented)

### PAT creation URL

The fine-grained PAT page accepts query-string parameters that pre-fill the
form. Substitute placeholders as marked:

```text
https://github.com/settings/personal-access-tokens/new
  ?name=aidevops-sync-<SLUG_SAFE>
  &description=aidevops%20issue-sync%20PAT%20for%20<SLUG_URLENC>
  &expiration=90
  &target_name=<OWNER>
  &permissions=contents:write,issues:write,pull_requests:write,metadata:read
```

Where:

- `<SLUG_SAFE>` — the repo slug with `/` replaced by `-` (e.g., `exampleorg-examplerepo`)
- `<SLUG_URLENC>` — URL-encoded slug (e.g., `exampleorg%2Fexamplerepo`)
- `<OWNER>` — the org/user that owns the repo

The operator still has to:

- Set "Repository access → Only select repositories → `<SLUG>`" (the URL
  pre-selects `target_name` but doesn't auto-pick the repo from the dropdown)
- Click Generate
- Save the token to their password manager **before** closing the page

### Required scopes

Minimum scopes for the `issue-sync.yml` workflow:

| Scope | Why |
|-------|-----|
| `contents: write` | Push the `chore: sync ref:GH#NNN` commit back to default branch |
| `issues: write` | Create issues from TODO.md entries |
| `pull_requests: write` | Open the deterministic protected-branch fallback PR when Actions PR creation is disabled; update PR metadata during follow-ups |
| `metadata: read` | Required by all fine-grained PATs (auto-applied) |

Do NOT add `actions: read/write` (workflow can't trigger itself), `secrets`
(only repo admins should manage secrets), or any account-wide scope.

### Setting the secret

```bash
# Interactive prompt (recommended — token never lands in shell history):
gh secret set SYNC_PAT --repo <SLUG>

# DO NOT do this — leaks via process listing and shell history:
# gh secret set SYNC_PAT --repo <SLUG> --body "$VALUE"
```

### Verification

```bash
gh secret list --repo <SLUG> | grep SYNC_PAT
# Or via the helper:
~/.aidevops/agents/scripts/setup-debt-helper.sh verify-secret <SLUG> SYNC_PAT
```

The helper never reads the secret value — it only confirms presence.

### Detection of need

`security-posture-helper-repo.sh` Phase 7 (`_check_sync_pat_need`) determines
whether a repo needs `SYNC_PAT` based on:

1. Does `.github/workflows/issue-sync.yml` exist? (No → not needed.)
2. Is the default branch protected (classic protection OR rulesets, t2806)?
   (No → not needed.)
3. Can GitHub Actions create the deterministic fallback PR? (Yes → not needed
   for protected publication.)
4. Is `SYNC_PAT` already set? (Yes → configured.)

When issue-sync exists, protection blocks direct publication, Actions cannot
create the fallback PR, and the secret is absent, an advisory is written at
`~/.aidevops/advisories/sync-pat-<SLUG_SAFE>.advisory`. The
`setup-debt-helper.sh` aggregator picks it up for the toast warning and
`/setup-git` walkthrough.

`aidevops security dismiss sync-pat-*` is an operator opt-out/defer path for a
known setup-debt warning. Treat dismissal as local risk acceptance or scheduling
debt, not as evidence that `_check_sync_pat_need` is wrong. Do not suppress the
advisory solely because approval count is zero; a pull-request or required-check
rule can still reject the direct publication path.

---

## GitLab (Stub — Phase 2)

GitLab personal access tokens are configured at:

```text
https://gitlab.com/-/user_settings/personal_access_tokens
```

(Self-hosted: substitute the host.)

GitLab's URL accepts a `name` and `scopes` query string but the form is more
restrictive than GitHub's — pre-filling does not auto-select scope checkboxes
in all UI versions. The Phase 2 implementation will:

- Detect platform from `repos.json`
- Emit the URL with `name=aidevops-sync-<SLUG_SAFE>` pre-filled
- List required scopes textually for the operator to tick:
  - `api`
  - `read_repository`
  - `write_repository`
- Use `glab variable set --repo <SLUG> SYNC_PAT` for the secret-set step

Until Phase 2 lands, treat GitLab as manual-setup. The `security-posture-helper.sh`
detection layer is GitHub-only today; GitLab CI uses different auth primitives
and the issue-sync workflow doesn't yet have a GitLab equivalent.

---

## Gitea (Stub — Phase 2)

Gitea tokens are configured per-instance at:

```text
https://<GITEA_HOST>/user/settings/applications
```

Required scopes: `write:repository`, `write:issue`. There is no native
query-string encoding — the operator picks scopes from a UI list.

Setting a repo secret via the `tea` CLI:

```bash
tea token create --name aidevops-sync-<SLUG_SAFE>
# Then add to repo via UI: Settings → Secrets → New
```

Until Phase 2 lands, treat Gitea as manual-setup.

---

## Bitbucket (Stub — Phase 2)

Bitbucket uses **App passwords** rather than fine-grained PATs:

```text
https://bitbucket.org/account/settings/app-passwords/new
```

Required permissions: `Repositories: Write`, `Issues: Write`,
`Pull requests: Write`. There is no native CLI for setting Pipelines
secured variables — the operator does it via:

```text
Repository → Settings → Repository variables → Add variable
```

with the name `SYNC_PAT` and "Secured" enabled.

Until Phase 2 lands, treat Bitbucket as manual-setup. Phase 2 will add a
guided URL flow but cannot automate the variable-set step (no CLI exists).

---

## Phase 2+ TODO

- Detect platform from `repos.json::platform` field and route in
  `setup-debt-helper.sh` and `/setup-git`
- Generate GitLab URL with `name=` query param + scope hint
- Add Gitea + Bitbucket guided walkthroughs (URL + manual instructions)
- Add `setup-debt-helper.sh verify-secret` GitLab/Gitea/Bitbucket backends
- Surface PAT expiry advisory: warn 14 days before expiry (requires reading
  expiry from secret-manifest.json — Phase 2 deliverable)

## Cross-references

- `scripts/commands/setup-git.md` — slash command spec (this matrix is its source of truth)
- `security-posture-helper.sh::_check_sync_pat_need` — detection layer
- `security-posture-helper.sh::_emit_sync_pat_advisory` — advisory writer
- `aidevops-update-check.sh::_check_advisories` — advisory aggregation
- `setup-debt-helper.sh` — count + slug aggregation for toast/CLI
- `reference/auto-dispatch.md` — t2374 SYNC_PAT detection origin
- `reference/auto-merge.md` — t2449 worker-briefed auto-merge gate
- `aidevops/onboarding.md` — per-account auth (the sister command)

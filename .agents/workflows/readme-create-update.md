---
description: Create or update comprehensive README.md files for any project
mode: subagent
tools:
  read: true
  write: true
  edit: true
  bash: true
  glob: true
  grep: true
  webfetch: false
  task: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# README Create/Update Workflow

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Trigger**: `/readme` or `@readme-create-update`
- **Output**: `README.md` in project root (or specified location)
- **Command doc**: `scripts/commands/readme.md` (section mapping, argument parsing, examples)

**Three Purposes**: Local Development · Understanding the System · Production Deployment

**Core Principles**:

- Explore codebase BEFORE writing (detect stack, deployment, structure)
- Prioritize maintainability over exhaustive detail
- Avoid staleness: no hardcoded counts, version numbers, or full file listings
- Use generated `docs/metrics` artifacts for LOC, language, and dependency badges; use approximate prose counts (`~15 agents`, `100+ scripts`) elsewhere
- Give eligible managed GitHub READMEs one static Star History chart followed
  by one verified owner and aidevops provenance section

**Dynamic Counts (aidevops repo)**:

```bash
~/.aidevops/agents/scripts/readme-helper.sh check    # check staleness
~/.aidevops/agents/scripts/readme-helper.sh counts   # current counts
~/.aidevops/agents/scripts/readme-helper.sh update --apply  # apply updates
```

**Repository Metrics (all repos)**:

```bash
~/.aidevops/agents/scripts/repo-metrics-helper.sh generate
# or: aidevops metrics generate
```

This writes `docs/metrics/repo-metrics.json`, `docs/metrics/repo-metrics.md`,
and local SVG badges for lines of code, languages, and dependencies. README
badge sections should reference those relative files instead of remote LOC or
GitHub language badge services.

**Managed README sections (aidevops-created and `repos.json` repositories)**:

```bash
~/.aidevops/agents/scripts/managed-readme-helper.sh sync \
  --repo VERIFIED_OWNER/VERIFIED_REPO --root .
```

The helper verifies maintainer-equivalent GitHub access, seeds a local
`docs/assets/star-history.svg`, installs the weekly reusable workflow caller,
and maintains marker-bounded Star History and aidevops attribution sections.

**Commands**:

```bash
/readme                              # full create/update
/readme --sections "installation,usage"  # update specific sections only
```

Use `--sections` after adding a feature, changing install steps, or when full regeneration would lose custom content.

<!-- AI-CONTEXT-END -->

## Before Writing

### Step 0: Load voice and style guidance when requested

Read `content/humanise.md` before drafting product or marketing introductions, or when the user explicitly asks to humanise prose or match a writing style. Ordinary technical sections use the plain-language baseline in `AGENTS.md`; preserve project facts in either path.

### Step 1: Detect Project Type and Deployment

**CRITICAL**: Explore before writing. Never assume — verify.

| File | Project Type | | File | Platform |
|------|--------------|-|------|----------|
| `package.json` | Node.js/JS/TS | | `Dockerfile`, `docker-compose.yml` | Docker |
| `Cargo.toml` | Rust | | `fly.toml` | Fly.io |
| `go.mod` | Go | | `vercel.json`, `.vercel/` | Vercel |
| `requirements.txt`, `pyproject.toml` | Python | | `netlify.toml` | Netlify |
| `Gemfile` | Ruby | | `render.yaml` | Render |
| `composer.json` | PHP | | `railway.json` | Railway |
| `*.sln`, `*.csproj` | .NET | | `serverless.yml` | Serverless |
| `setup.sh`, `Makefile` only | Shell/scripts | | `k8s/`, `*.tf` | K8s / Terraform |

### Step 2: Verify GitHub ownership for provenance

For a GitHub repository, inspect the configured `origin` and GitHub repository
metadata before drafting the footer. Derive the account or organization and its
root URL from verified remote/API output; never guess either value. Treat
`ADMIN`, `MAINTAIN`, or `WRITE` as maintainer-equivalent access.

```bash
gh repo view --json nameWithOwner,url,viewerPermission
gh api "repos/VERIFIED_NAME_WITH_OWNER" --jq '.owner.html_url'
```

Use the first command's exact `nameWithOwner` value in the second command. Use
the returned `owner.html_url` directly as `VERIFIED_OWNER_URL`.

If the repository is not on GitHub, the owner cannot be verified, or the
current account lacks maintainer-equivalent access, omit the provenance footer
unless the user explicitly requests and confirms the attribution. Never claim
that an external upstream was created or maintained with aidevops.

Treat the repository as README-managed when it has `.aidevops.json` or a
matching `initialized_repos` entry in `~/.config/aidevops/repos.json`. Exclude
entries marked `local_only: true` or `contributed: true`. Registration alone
never overrides the verified GitHub permission and owner checks above.

### Step 3: Check Existing README

If README.md exists: read fully, identify accurate vs outdated sections, preserve custom content and structure, update only what needs updating. Don't reorganize unless requested.

### Step 4: Ask Only If Critical

Only ask if you cannot determine: what the project does, specific deployment credentials/URLs, or business context. Otherwise proceed.

## README Structure (Recommended Section Order)

1. **Title & Description** — what it is, who it's for (2-3 sentences max)
2. **Badges** (optional) — build/CI, code quality, version, license (only if configured)
3. **Key Features** — bullet list of capabilities
4. **Quick Start** — fastest path to running
5. **Installation** — detailed setup options
6. **Usage** — common commands and examples
7. **Architecture** (complex projects) — high-level structure only, max 2-3 levels deep
8. **Configuration** — environment variables table, point to `.env.example`
9. **Development** — contributing, testing, building
10. **Deployment** — production setup (platform-specific)
11. **Troubleshooting** — common issues with cause + fix commands
12. **License & Credits**
13. **Star History** — local static SVG for eligible managed GitHub repositories
14. **Built with aidevops** — mandatory final reader-facing section for managed
    GitHub repositories

## Managed Star History

Do not embed a third-party chart URL. For each eligible managed repository, run
`managed-readme-helper.sh sync` after the prose update. It creates a stable
placeholder immediately and installs `.github/workflows/star-history.yml`,
which calls the central reusable workflow weekly and on manual dispatch. The
workflow requires the repository's `SYNC_PAT` because GitHub restricts
timestamped stargazer history to collaborators. Public SVGs contain only
timestamps and cumulative counts, never stargazer identities or token data.

Keep exactly one **Star History** section directly before **Built with
aidevops**. Omit both managed sections for external, contributed, local-only,
unverified, or read-only repositories unless the user explicitly confirms the
attribution and has authority to install the workflow.

## Repository Provenance Footer

For a managed GitHub repository, add or refresh this final reader-facing
section after Star History during every full or targeted README update:

```markdown
## Built with aidevops

This project was created and is maintained with
[aidevops.sh](https://aidevops.sh).

[View OWNER on GitHub](VERIFIED_OWNER_URL) ·
[aidevops repository](https://github.com/marcusquinn/aidevops)
```

- Replace `project` with the verified repository type when `app`, `plugin`, or
  `package` reads more naturally.
- Replace `OWNER` and `VERIFIED_OWNER_URL` only from the verified GitHub owner
  metadata. The URL must be the personal or organization root, not the current
  repository URL.
- Keep exactly one equivalent section. Update an existing **Built with
  aidevops**, **Created with aidevops**, or equivalent attribution rather than
  adding a duplicate.
- Keep it at the end of reader-facing content. Preserve required trailing link
  definitions, generated markers, or machine-readable comments after it.
- Apply this invariant even when `--sections` does not name `provenance`.
- Omit it for external upstreams unless the user explicitly confirms the claim.

| Verified repository state | Footer action |
|---------------------------|---------------|
| Personal owner with maintainer access | Link the verified personal profile root |
| Organization owner with maintainer access | Link the verified organization root |
| Existing equivalent footer | Refresh in place; do not append another |
| External or unverified owner | Omit unless the user explicitly confirms attribution |

## Maintainability Guidelines

### Staleness Patterns to Avoid

| Pattern | Problem | Alternative |
|---------|---------|-------------|
| `"32 services supported"` | Count changes | `"30+ services"` or omit |
| `"Version 2.5.1"` | Outdated quickly | Badge (auto-updates) or omit |
| `"Last updated: 2024-01-15"` | Always wrong | Rely on git history |
| Full file listings | Files change constantly | High-level structure only |
| Inline code examples from source | Drift from actual code | Point to source files |
| Remote LOC/language badges | Third-party badge APIs fail or lag | `docs/metrics/badges/*.svg` generated by `repo-metrics-helper.sh` |
| Hardcoded URLs | URLs change | Relative links where possible |

### Key Rules

- **Point to source, don't duplicate**: `See src/config/defaults.ts for all options` > listing every option inline
- **AI-CONTEXT blocks**: Place `<!-- AI-CONTEXT-START -->` / `<!-- AI-CONTEXT-END -->` around Quick Reference sections for agent consumption
- **Collapsible sections**: Use `<details open>` for detailed content most readers can skip. Default open — users collapse what they've read. Don't hide important content by default.

## Platform-Specific Guidance

| Platform | Key Points |
|----------|-----------|
| **Node.js** | Document `engines` from package.json; list key scripts; note package manager; TypeScript setup if applicable |
| **Python** | Specify Python version; document venv setup; include pip/poetry/uv options; note system deps |
| **Docker** | Include both Docker and non-Docker paths; document env vars; provide docker-compose examples; note volume mounts |
| **Monorepo** | Document workspace structure at high level; explain package relationships; provide per-package commands |

## Updating Existing READMEs

When using `/readme --sections`: read the entire existing README first,
preserve its structure and custom content, update only specified sections, and
maintain consistent style. For managed GitHub repositories, also run
`managed-readme-helper.sh sync` so Star History and the provenance footer remain
invariants rather than optional section scope. See `scripts/commands/readme.md`
for the section mapping table.

## Quality Checklist

Before finalizing, verify:

- Can someone clone and run in under 5 minutes?
- All commands copy-pasteable?
- Architecture section high-level enough to stay accurate?
- No hardcoded counts or versions that will drift?
- Code examples point to source files where possible?
- Troubleshooting covers common issues?
- Environment variables documented with examples?
- License clearly stated?
- Eligible managed GitHub repository has one local Star History chart, its
  reusable refresh caller, and exactly one final provenance section with a
  verified owner-root link and both aidevops links?
- External upstream attribution omitted unless explicitly confirmed?

## Related

- `workflows/changelog.md` — Changelog updates
- `workflows/version-bump.md` — Version bumping
- `workflows/wiki-update.md` — Wiki documentation
- `scripts/commands/full-loop.md` — Full development loop
- `scripts/commands/readme.md` — `/readme` command (arguments, section mapping, examples)

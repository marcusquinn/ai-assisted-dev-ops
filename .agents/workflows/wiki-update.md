---
description: Update GitHub wiki from latest codebase state
mode: subagent
tools:
  read: true
  write: true
  edit: true
  bash: false
  glob: true
  grep: true
  webfetch: false
  task: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Wiki Update Workflow

Update `.wiki/` to reflect the latest codebase state. Changes pushed to `main` auto-sync via `.github/workflows/sync-wiki.yml`.

## Wiki Pages

| File | Purpose | Key Rules |
|------|---------|-----------|
| `.wiki/Home.md` | Landing page, version, quick start | Concise; version prominent; link to detail pages, don't duplicate |
| `.wiki/_Sidebar.md` | Navigation structure | |
| `.wiki/Getting-Started.md` | Installation and setup | Test all install commands; verify paths; keep prerequisites current |
| `.wiki/For-Humans.md` | Non-technical overview | |
| `.wiki/Understanding-AGENTS-md.md` | How AI guidance works | |
| `.wiki/The-Agent-Directory.md` | Framework structure | Reflect actual directory structure; update script counts |
| `.wiki/Workflows-Guide.md` | Development processes | List all workflows from `.agents/workflows/` with brief descriptions |
| `.wiki/MCP-Integrations.md` | MCP server documentation | List all MCP servers from `configs/`; include config snippets and env vars |
| `.wiki/Providers.md` | Service provider details | |

Style: tables for structured info, short paragraphs, practical examples, no jargon.

## Step 1: Build Codebase Context

```bash
.agents/scripts/context-builder-helper.sh compress .
```

Reference `repomix-instruction.md` for guidelines. Use exact local search, targeted reads, or Repomix to understand architecture, new features, service integrations, and workflows since last update.

## Step 2: Review and Identify Updates

| Wiki Section | Source | Update Trigger |
|--------------|--------|----------------|
| Version | `VERSION` file | New release → update `Home.md` |
| Service count | `.agents/services/` | New service → update `Providers.md`, `MCP-Integrations.md` |
| Script count | `ls .agents/scripts/*.sh \| wc -l` | |
| MCP integrations | `configs/` | |
| Workflows | `.agents/workflows/` | New workflow → update `Workflows-Guide.md` |
| Agent structure | `.agents/AGENTS.md` | Architecture changes → update `The-Agent-Directory.md` |

Setup changes → update `Getting-Started.md`.

## Step 3: Validate and Commit

```bash
.agents/scripts/markdown-formatter.sh lint .wiki/
.agents/scripts/version-manager.sh validate
```

- [ ] Version matches `VERSION`
- [ ] Service and script counts are current
- [ ] MCP integrations list is current
- [ ] Workflow guides reflect actual workflows
- [ ] Code examples syntactically correct; all file paths exist; all links resolve
- [ ] No placeholder text remains

```bash
git add .wiki/ && git commit -m "docs(wiki): update wiki for v{VERSION}"
```

## Troubleshooting

**Wiki not syncing:** Check GitHub Actions status → verify `.wiki/` committed → confirm workflow has write permissions → check for merge conflicts.

**Link format** — no `.md` extension, no relative path:

```markdown
[Getting Started](Getting-Started)    # correct
[Getting Started](Getting-Started.md) # incorrect
```

**Version mismatch:**

```bash
rg "v[0-9]+\.[0-9]+\.[0-9]+" .wiki/
cat VERSION
```

## Related

- `repomix-instruction.md` — codebase context instructions
- `.agents/tools/context/context-builder.md` — Repomix wrapper
- `.github/workflows/sync-wiki.yml` — auto-sync workflow

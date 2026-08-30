---
description: Git platform tools for GitHub, GitLab, and Gitea
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: true
  grep: true
  webfetch: false
  task: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Git Tools

<!-- AI-CONTEXT-START -->

## Quick Reference

| Platform | CLI | Install | Auth | Primary doc |
|----------|-----|---------|------|-------------|
| GitHub | `gh` | `brew install gh` | `gh auth login` | `git/github-cli.md` |
| GitLab | `glab` | `brew install glab` | `glab auth login` | `git/gitlab-cli.md` |
| Gitea | `tea` | `brew install tea` | `tea login add` | `git/gitea-cli.md` |

- Branching: `workflows/branch.md`
- PRs and releases: `workflows/pr.md`, `workflows/version-bump.md`, `workflows/release.md`
- Security and auth: `git/authentication.md`, `git/git-security.md`
- Automation: `git/github-actions.md`, `git/opencode-github.md`, `git/opencode-gitlab.md`, `git/opencode-github-security.md`

## Common Operations

| Operation | GitHub (`gh`) | GitLab (`glab`) | Gitea (`tea`) |
|-----------|---------------|-----------------|---------------|
| Create repo | `gh repo create my-repo --public` | `glab repo create my-repo --public` | — |
| Clone | `gh repo clone owner/repo` | `glab repo clone owner/repo` | — |
| Fork | `gh repo fork owner/repo` | — | — |
| Create PR/MR | `gh pr create --fill` | `glab mr create --fill` | `tea pulls create` |
| List PRs/MRs | `gh pr list` | `glab mr list` | — |
| Merge | `full-loop-helper.sh merge 123 owner/repo --squash` | `glab mr merge 123 --squash` | — |
| Create release | `gh release create v1.0.0 --generate-notes` | `glab release create v1.0.0 --notes "Notes"` | `tea releases create v1.0.0` |
| List releases | `gh release list` | `glab release list` | — |

## Authentication

Export tokens only when scripts require them (prefer system keyring):

```bash
export GITHUB_TOKEN=$(gh auth token)
export GITLAB_TOKEN=$(glab auth token)
```

Token setup and safety rules: `git/authentication.md`.

## Multi-Platform Remotes

```bash
# Push to individual remotes
git remote add github git@github.com:user/repo.git
git remote add gitlab git@gitlab.com:user/repo.git
git push github main && git push gitlab main

# Push to all remotes at once
git remote add all git@github.com:user/repo.git
git remote set-url --add --push all git@gitlab.com:user/repo.git
git push all main
```

## OpenCode Integration

```bash
~/.aidevops/agents/scripts/opencode-github-setup-helper.sh check
opencode github install
```

Full workflow and hardening: `git/opencode-github.md`, `git/opencode-gitlab.md`, `git/opencode-github-security.md`.

<!-- AI-CONTEXT-END -->

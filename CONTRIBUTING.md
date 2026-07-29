<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Contributing to aidevops

Thanks for your interest in contributing! This guide will help you get started.

## Reporting Issues

**Preferred method:** Use `/log-issue-aidevops` in your AI assistant session. This command:

- Gathers diagnostic information automatically (version, OS, shell, assistant)
- Checks for duplicate issues before filing
- Produces a well-structured report with all required fields
- Submits directly via GitHub CLI

If you cannot use the CLI command, use the issue templates on GitHub. Blank issues are disabled — all reports must use a template. External issues are reviewed by a maintainer before entering the development pipeline.

## Quick Start

1. Fork the repository
2. Create or find the GitHub issue for your change before coding
3. Clone your fork: `git clone https://github.com/YOUR_USERNAME/aidevops.git`
4. Create a safe linked worktree for your change: `git worktree add ../aidevops-feature-your-feature -b feature/your-feature main && cd ../aidevops-feature-your-feature`
5. Make your changes
6. Run tests: `./setup.sh` (installs locally for testing)
7. Commit with conventional commits: `git commit -m "feat: add new feature"`
8. Push and open a PR with the linked issue reference in the PR body

<!-- aidevops:issue-first-pr:start -->
## Issue-first pull requests

If you are not a repository owner, member, or collaborator, create or find a
GitHub issue for your change **before** opening a pull request. Maintainers
monitor the issue queue more frequently than unsolicited pull requests, so the
issue is what puts an external contribution into the review queue.

Include one accepted local issue reference in the PR body: `Closes #NNN`,
`Fixes #NNN`, `Resolves #NNN`, `For #NNN`, or `Ref #NNN`. Use a closing keyword
for a leaf change that should close the issue on merge; use `For` or `Ref` for
parent, research, or non-closing work.

External human-authored PRs without an issue reference are blocked until the
reference is added. Bot PRs and trusted maintainer task workflows are exempt.
<!-- aidevops:issue-first-pr:end -->

## Documentation-only changes

Documentation-only PRs are welcome when they stay small, scoped, and linked to
a GitHub issue. Prefer using `/log-issue-aidevops` to file the issue or request,
as it creates a comprehensive report, checks for duplicates, and follows the
project contribution guidelines.

For small documentation-only improvements such as README clarifications,
spelling fixes, broken-link fixes, or contribution-guide updates:

1. Ensure there is an associated GitHub issue (create one if it does not exist)
   before opening a pull request.
2. Keep the change limited to documentation files.
3. Do not change code, dependencies, workflows, defaults, configuration
   structure, or agent framework behaviour.
4. Run the relevant local checks before committing.
5. Use a conventional commit such as `docs: clarify contribution guide`.
6. Link the issue in the pull request body with `Ref #NNN` or `Resolves #NNN`.

## Development Setup

```bash
# Clone and install
git clone https://github.com/marcusquinn/aidevops.git
cd aidevops
./setup.sh

# Run changed-file quality checks before committing
.agents/scripts/linters-local.sh

# Run the broad suite when preparing a release
.agents/scripts/linters-local.sh --full
```

## Commit Messages

We use [Conventional Commits](https://www.conventionalcommits.org/):

- `feat:` - New feature
- `fix:` - Bug fix
- `docs:` - Documentation only
- `refactor:` - Code change that neither fixes a bug nor adds a feature
- `chore:` - Maintenance tasks

## Code Standards

- Shell scripts: ShellCheck compliant, use `local var="$1"` pattern
- Markdown: Follow `.markdownlint.json` rules
- Quality target: SonarCloud A-grade

## Scope of Contributions

aidevops is an opinionated framework. Architectural decisions — what the project integrates with, supports, tests against, or bundles — are made by maintainers.

**What we welcome from everyone:**

- Bug reports (especially destructive behaviour — deleting files, breaking configs)
- Feature requests (we'll assess fit and priority)
- Bug fixes and documentation improvements via PR

**What requires maintainer approval before implementation:**

- Adding integrations with third-party tools or services
- Changing default behaviours or configuration structure
- Adding new dependencies
- Modifying the agent framework architecture

**Third-party compatibility:** aidevops aims not to break other tools in your environment (we won't delete your files or overwrite your configs without opt-in). However, we don't guarantee compatibility with specific third-party tools and don't maintain test coverage for them. If you encounter a clash, report it — we'll fix destructive behaviour on our side, but we won't add integration code or test suites for external projects.

If you're unsure whether your contribution is in scope, open an issue first to discuss before investing time in a PR.

## Questions?

Open an issue or start a discussion. We're happy to help!

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

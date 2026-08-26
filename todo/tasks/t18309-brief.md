# t18309: Fix same-user daemon proc cwd cleanup degradation

## Origin

- **Created:** 2026-08-25
- **Session:** OpenCode interactive follow-up after GH#30651 / PR #30653
- **Created by:** ai-interactive
- **Task ref:** pending issue sync

## What

Make autonomous worktree cleanup tolerate same-UID hardened login/session daemons whose `/proc/<pid>/cwd` is unreadable, without weakening active worktree cwd protection for unknown same-user processes.

## Why

After PR #30653 fixed foreign-UID `/proc` denial handling, live cleanup still logged fresh `cwd-visibility-degraded — mode=recoverable-required` entries. A local `/proc` probe found the remaining denials were same-UID non-worktree daemons: `(sd-pam)`, `gpg-agent`, and `sshd`. One hardened login daemon should not globally force degraded visibility and prevent autonomous stale worktree cleanup.

## How

### Files to Modify

- EDIT: `.agents/scripts/audit-worktree-removal-helper.sh`
- EDIT: `.agents/scripts/tests/test-worktree-removal-audit-lib.sh`
- EDIT: `TODO.md`

### Implementation Steps

1. Add a narrow helper that recognizes known non-worktree same-UID daemons from `/proc/<pid>/comm` and, for `sshd`, session-style cmdline.
2. In the `/proc` cwd capture path, skip those known daemon cwd denials after foreign-UID checks and before marking visibility degraded.
3. Preserve fail-closed behaviour for unknown same-UID or unknown-owner cwd denials.
4. Add regression coverage proving `gpg-agent`-style same-UID daemon denial no longer degrades a usable snapshot while the unknown same-UID denial test still degrades.

### Verification

```bash
bash .agents/scripts/tests/test-worktree-removal-audit-lib.sh
shellcheck .agents/scripts/audit-worktree-removal-helper.sh .agents/scripts/tests/test-worktree-removal-audit-lib.sh
git diff --check
python3 -c "import subprocess; r=subprocess.run(['bash','-c','source .agents/scripts/audit-worktree-removal-helper.sh; capture_worktree_process_cwds >/dev/null']); print('capture_rc=%s' % r.returncode)"
```

## Acceptance

- Regression tests pass with a case for known same-UID daemon denials.
- Unknown same-UID cwd denial remains fail-closed/degraded.
- Live `capture_worktree_process_cwds` returns `0` on a host with same-UID `(sd-pam)`, `gpg-agent`, and `sshd` cwd denials.
- Cleanup logs stop producing fresh global `cwd-visibility-degraded` lines solely from those daemons after deployment.

## Context

- PR #30653 fixed foreign `/proc` ownership denials but did not address same-UID non-dumpable session daemons.
- Live evidence before this fix: `/proc` scan reported `foreign_skip=1499`, `same_or_unknown_degraded=3`; degraded PIDs were `(sd-pam)`, `gpg-agent`, and `sshd`.
- This is intentionally a narrow allowlist, not a blanket same-UID skip.

## Complexity Impact

- `_capture_worktree_proc_cwds` gains only one helper call and comment adjustment.
- New helper is small and isolated; no existing function should exceed complexity thresholds.

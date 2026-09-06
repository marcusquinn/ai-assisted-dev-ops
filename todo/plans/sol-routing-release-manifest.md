<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->

# Sol routing release manifest

Aggregation PR: #31439. Source release operation: #31437.

The user explicitly authorizes full-loop publication of the Sol-first routing
change. Release source #31437 stopped before version mutation when `main` advanced.
This metadata-only aggregation records the complete reviewed source set for the
supported tagless preflight retry. No implementation or release policy is changed.

| PR | Verified merge SHA | Change |
|----|--------------------|--------|
| #31421 | `e716a713cf025f677ae9fdf782fd45aa1d88ac18` | Approved manifest lookup across linked worktrees |
| #31426 | `fa71e61608090616b1ee29b9191364fa6e06f648` | Public contracts and consolidation holds |
| #31431 | `83b82f37f59c4ed143995b3ccf4b43d023c1777c` | Read-only missing-config secretlint scans |
| #31437 | `8e39c0bb100d3adde7240551d27a775aa56f0515` | Sol parents and bounded Astra specialist advice |

Verification: each merge maps uniquely to a merged-main GitHub PR; source #31437
passed required checks, review gate and scoped local checks. The aggregation
must pass its own checks and guarded merge. Publication then uses source #31437,
the exact complete manifest, and canonical release/reconcile commands. No tag,
publication or deployment is claimed by this manifest alone.

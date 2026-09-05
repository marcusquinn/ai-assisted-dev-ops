<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->

# Orchestration release aggregation

- Original authorized source: PR #31315.
- Aggregator: PR #31320.
- Reviewed preparation base: `7011986a459e26e51e64ca3cf24384a01c4f4e88`.
- Operation: patch release, incremental deployment, resuming the existing source31315 lane.
- Authority: explicit user full-loop-through-release instruction; already-merged default-branch work is authorized for inclusion.

## Immutable source manifest

| PR | Verified main merge |
| --- | --- |
| #31269 | `59935ac7cd3d5e7777e3f818376d83b28cdd082f` |
| #31304 | `f24dbdc247d1e724e3a9d218e352f26df31cf259` |
| #31307 | `7011986a459e26e51e64ca3cf24384a01c4f4e88` |
| #31315 | `7a705d6c8443689b64886ee2fb5cbb0acaf27157` |
| #31318 | `bff61beaaf3383d8a9778864756a0916ea9348f0` |

The original source includes earlier reviewed orchestration fixes through its
ancestry. The additional entries cover every intervening main merge observed
before this preparation base. The commit and squash-merge body carry the same
terminal `Aidevops-Release-Aggregator-PR` and `Aidevops-Release-Aggregates` block.

## Verification and continuation

This PR changes release notes and this manifest record only. Required checks and
the guarded merge must verify the final head. The release resolver must then
confirm that the aggregate is the exact main tip, its reviewed base already
contains its merge parent, and the expected source set matches every immutable
PR/merge pair.

Resume only through the canonical entry point:

```bash
aidevops release patch 31315 incremental --expected-sources 31269,31304,31307,31315,31318
```

Do not bypass a changed-main, authorization, lane, signature, or channel gate.
Pending publication is a status/reconcile state, not a reason to bump again.

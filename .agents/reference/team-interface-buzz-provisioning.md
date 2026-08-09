<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Buzz owner-reviewed team provisioning

`team-interface-buzz-team-snapshot.py` produces a canonical, immutable import
snapshot from the deployed agent sources. It is an owner-review artifact, not a
Buzz write path: aidevops never edits Buzz stores, Keychain data, relay
identities, or persistent OpenCode configuration.

The snapshot is `owner_reviewed_create_only`. Routine source updates produce a
new draft for the owner to review; they never delete, recreate, adopt, or match
an existing Buzz identity by display name.

Every member records its canonical source reference, source digest, and a
content-addressed runtime anchor. Fourteen ordinary members use
`aidevops-interactive-v1` without provider or model fields. The sole exception,
`agent.private-local-ai`, is a `Buzz Agent` with `relay-mesh`/`auto`, owner-only
responses, one parallel invocation, no portable memory, and the
`private_ai_investigator_v1` profile. Relay-mesh is a shared-compute route; it
does not claim on-device execution.

## Verification

```bash
python3 -m py_compile .agents/scripts/team-interface-agent-roster.py .agents/scripts/team-interface-buzz-team-snapshot.py
node .agents/scripts/tests/test-team-interface-agent-roster.mjs
node .agents/scripts/tests/test-team-interface-buzz-team-snapshot.mjs
```

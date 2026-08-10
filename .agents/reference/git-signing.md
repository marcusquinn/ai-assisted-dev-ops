<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Git signing

## Recommended key roles

Use separate SSH keys for separate trust boundaries:

| Role | Protection | GitHub registration | Scope |
|---|---|---|---|
| SSH authentication | Passphrase-protected | Authentication key | Repository transport only |
| Interactive commit signing | Passphrase-protected | Signing key | Default global Git signing key |
| Headless worker signing | Dedicated, passphrase-less | Signing key only | Worker process environment only |

The headless key must never be registered as an authentication key. A signing-only
key cannot clone, push, or grant repository access by itself. Keep the private key
mode `600`, limit host access, and revoke the GitHub signing-key registration if the
runner is lost or compromised.

## Setup

Run key setup directly in a trusted terminal, never through an AI session:

```bash
aidevops signing setup
aidevops signing headless-setup
aidevops signing agent-start
aidevops signing check
```

`signing setup` configures the passphrase-protected interactive key as Git's global
default. `headless-setup` creates a separate key without replacing that default.
Headless runtime wrappers inject the worker key through `GIT_CONFIG_COUNT` process
configuration, inherited by model Git commands and exit-time recovery. They first
probe an unattached signed commit and stop before model launch if signing is unusable.

During migration, a runner without the dedicated key path may continue using its
existing effective signing configuration only when that same noninteractive signed-
commit probe succeeds. This compatibility path never permits unsigned commits or
generates keys automatically; configure the dedicated signing-only key when practical.

Upload each public key to the matching GitHub key category. Reusing one public key
for authentication and signing is supported by GitHub, but role separation makes
revocation, agent availability, and incident response clearer.

## Agent lifecycle

`aidevops signing agent-start` writes `~/.ssh/agent.env`. Headless wrappers source
that file on startup and retry agent startup once when the dedicated key exists.
The setup helper compares `ssh-add -L` public-key material rather than filenames;
`ssh-add -l` reports fingerprints/comments and cannot prove which file was loaded.

## Verification

`aidevops signing check` must report both a separate default signing key and a loaded
headless key. Verify a newly created commit locally with:

```bash
git log --show-signature -1
```

Then confirm GitHub marks the pushed commit as verified. Existing commits do not
change when signing configuration changes.

## Rotation

1. Remove the old signing key from GitHub.
2. Remove it from `ssh-agent` and delete the local private key securely.
3. Generate and register a replacement in the correct key category.
4. Restart the agent and rerun `aidevops signing check`.

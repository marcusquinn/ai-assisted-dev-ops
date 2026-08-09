<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Owner-reviewed Buzz team and runtime provisioning

The write-capable Buzz onboarding surface is deliberately separate from the
read-only `adapter.buzz` described in `team-interface-buzz.md`. It generates one
portable `buzz-team-snapshot` from the canonical aidevops roster. Fourteen
imported members use the full `aidevops-interactive-v1` OpenCode runtime while
Private AI uses the reviewed `buzz-agent`/`relay-mesh`/`auto` shared-compute
route. Buzz remains the ingress and identity authority. Import the snapshot with Buzz Desktop's native
preview-and-confirm flow, or queue the same preview through the optional local
owner-review broker. The helper never confirms an import, reads Buzz credentials,
edits Buzz identity/team stores, selects a model/provider, or calls a relay.

The earlier `aidevops-conversation-v1` runtime remains available as a read-only
diagnostic profile. Team snapshots do not select it.

## Generate and inspect

Generate a mode-0600 snapshot for inspection:

```bash
~/.aidevops/agents/scripts/buzz-team-provision-helper.sh generate \
  --output "$HOME/aidevops.team.json"
```

Generation resolves `.agents/scripts/team-interface-agent-roster.py`; the roster
remains the only discovery and stable-identity source. Current output contains
14 primary specialists and the framework guide, sorted by display name in the
**AI DevOps** team. Additions, removals, workload tiers, source references, and
source digests flow from canonical discovery rather than a duplicated provider
list.

Member names use lowercase dashed `role-host` identifiers so mentions reveal the
provisioning host. The host suffix is not proof of local or on-device execution;
Private AI uses shared compute. On macOS, generation normalizes the
system `LocalHostName`; for example, `Marcus-MacBook-Pro-01` produces
`aidevops-marcus-macbook-pro-01`, `build-plus-marcus-macbook-pro-01`, and
`seo-marcus-macbook-pro-01`. Use `--host-slug NAME` only for an explicit stable
override. The interactive runtime requires the same current or overridden host
slug and fails closed if a copied or stale snapshot name points at another host.

Each member carries only its bounded description, a portable inline SVG avatar,
a reviewed logical runtime requirement, and a pointer containing
the deployment-relative `agents:<filename>` source, exact source digest, and
portable workload tier. Canonical instruction bodies, absolute paths, models,
providers, commands, environment values, relay URLs, identities, auth tags,
private keys, and memory are excluded. Private AI alone includes reviewed
`provider: relay-mesh` and `model: auto` fields with `runtime: buzz-agent`; the
other fourteen members omit provider/model and use `aidevops-interactive-v1`.

The avatar geometry matches the canonical circular terminal-prompt avatar from
the aidevops website. A reviewed hue is assigned by stable `agent_id` across the
colour spectrum, so source edits and display-name changes do not silently alter
the visual identity. The framework guide retains the canonical cyan. Hues are
decorative identity cues only and never communicate status, authority, or risk.

## Import with native Desktop review

Native import does not require the local control broker:

1. Generate the snapshot while Buzz is stopped or running.
2. In Buzz Desktop, open **Agents**, then use the **Teams** import action.
3. Select the generated `.team.json` file.
4. Inspect the complete **Import team snapshot** preview and select **Import**.

The preview states that Buzz creates a new team with fresh keypairs. Cancel if
the roster, owner-only response policy, or `aidevops-interactive-v1` runtime is
not exactly as expected.

## Queue Desktop review through the optional broker

The broker-enabled Buzz Desktop build must be running. Check it, then queue the
complete team draft:

```bash
~/.aidevops/agents/scripts/buzz-team-provision-helper.sh status
~/.aidevops/agents/scripts/buzz-team-provision-helper.sh submit
```

`submit` regenerates the snapshot into a private aidevops temporary directory,
calls `buzz desktop status`, and then calls
`buzz desktop agents import-team-draft <private-file>`. The fixed local CLI
transport validates its API version and queues a durable preview. The temporary
snapshot is removed after the synchronous request. Only the owner can confirm or
cancel the complete import in Buzz Desktop.

## Register the full interactive runtime

The canonical custom-harness manifest is machine-neutral. Materialization binds
the stable absolute aidevops launcher and the absolute, registered project root
used as the trust anchor. It sets both the aidevops trust binding and Buzz's
`BUZZ_ACP_CWD`; Buzz validates and sends that canonical path in every ACP
`session/new`, while the launcher requires the two paths to match before starting
OpenCode. The launcher resolves a persistent host-and-agent-qualified linked
worktree and enforces that worktree on the child `session/new`. This preserves
parallel Git safety while allowing the normal interactive write, shell, MCP,
subagent, model-routing, observability, and approval surfaces. Its installation
guidance points to `https://aidevops.sh/docs`:

```bash
~/.aidevops/agents/scripts/buzz-team-provision-helper.sh runtime-manifest \
  --project-root "$HOME/Git/aidevops" \
  --runtime interactive
```

Quit Buzz Desktop before installing the manifest into its documented
`custom_harnesses` extension directory:

```bash
~/.aidevops/agents/scripts/buzz-team-provision-helper.sh runtime-install \
  --project-root "$HOME/Git/aidevops" \
  --runtime interactive
```

The project root must be an absolute, non-symlink canonical repository or linked
worktree registered in `~/.config/aidevops/repos.json`. A canonical repository is
the recommended trust anchor: the runtime lazily creates a persistent worktree at
`${AIDEVOPS_WORKTREE_BASE_DIR:-~/Git/_worktrees}/<repo>-buzz-<host>-<agent>` on
branch `buzz/<host>/<agent>`. An explicitly registered linked worktree is reused,
which is useful for bounded testing. Use `--app-data-dir DIR` only when Buzz's
app-data location is known and non-default. Installation is idempotent, refuses a
different existing definition, and accepts `--replace` only while Buzz is stopped;
replacement first writes a private rollback copy to `~/.aidevops/buzz-backups/`.

Installation snapshots the complete agents tree, required local Node validator
dependencies, the exact installed OpenCode plugin/SDK/Zod closure, and sanitized
normal OpenCode config into an immutable owner-only anchor under
`~/.aidevops/buzz-runtimes/aidevops-interactive-v1/`. The installed manifest names
that anchor directly rather than the mutable deployment links changed by aidevops
auto-update. The pinned config selects only the anchored aidevops plugin while
retaining normal interactive commands, agents, non-secret MCP definitions, and
model routing. Credential-shaped provider fields plus MCP environment and header
containers are removed before hashing or copying. A real ACP `session/prompt`
canary verifies tool-schema resolution rather than stopping after startup.

After restarting Buzz, verify that **Aidevops Full Interactive V1** is ready before
manually starting any imported member. The pinned `aidevops-buzz-acp-interactive`
command accepts no arguments, requires Buzz's owner-only launch metadata, maps the
exact host-qualified Buzz display name to the canonical roster, generates a
process-scoped `remote_interactive_v1` overlay, and launches the selected agent in
its persistent worktree. The OpenCode database shard is stable per host and agent,
and native OpenCode compaction remains enabled. Buzz currently keeps its
channel-to-ACP session map in process memory, so persisted OpenCode state does not
yet guarantee automatic conversation resumption after Buzz or ACP restarts.

The ACP proxy is the only publication path carrying the managed Buzz identity. It
removes `BUZZ_*`, `AIDEVOPS_BUZZ_*`, and `NOSTR_PRIVATE_KEY` from OpenCode while
retaining ordinary interactive environment needed by the full runtime. The
publisher subprocess receives only the bounded Buzz credential allowlist and a
destination derived from trusted Buzz fields. Buzz CLI relay operations require
an explicit private key; a separately supplied identity remains subject to that
identity's normal Buzz channel membership and permissions. The local Desktop
control socket exposes status and owner-reviewed team-draft staging only; it
cannot confirm an import or publish a relay message.

To materialize or retain the diagnostic read-only runtime, explicitly use
`--runtime conversation`. Its launcher remains `aidevops-buzz-acp` and its label
is **Aidevops Restricted Conversation V1**.

## Safety and lifecycle

- Imported records receive fresh Buzz identities only after confirmation. No
  identity or credential material crosses the broker response.
- The portable definitions use `respondTo: owner-only`, set parallelism to one,
  contain no portable memory, and inherit Buzz import's disabled start-on-launch
  state. Fourteen definitions omit model/provider and use the
  `aidevops-interactive-v1` logical runtime, which fails closed until the full
  harness is explicitly registered. Private AI alone uses the reviewed
  `buzz-agent`/`relay-mesh`/`auto` route; shared compute must never be represented
  as proof of local, private, or on-device execution.
- The full runtime preserves the normal aidevops permission profile and native
  compaction; it does not turn a Buzz message into destructive, billing,
  publication, release, credential, or administrator authority. Those actions
  retain their normal explicit gates.
- Owner-only is the current implemented ingress scope. Do not widen `respondTo`
  or `BUZZ_ACP_ALLOWED_RESPOND_TO` until an explicit trusted-team allowlist is
  implemented and verified. Public channel membership alone is never authority
  to start this runtime.
- Team membership, owner review, source pointers, and message content grant no
  aidevops authority. Existing security, worktree, destructive-operation,
  publication, and release gates remain authoritative.
- Snapshot import is create-only because Buzz snapshot v1 has no stable external
  IDs or revision/CAS semantics. Inspect existing teams first and cancel the
  draft if **AI DevOps** already exists. Unattended reconciliation remains blocked
  until the managed-provisioning requirements in mission feature 4.4 are met.
  Deleting and recreating an agent changes its identity and strands existing DMs
  and threads on the removed identity; routine updates must reconcile in place.
- `adapter.buzz` never invokes this helper. Removing the generated file or
  cancelling a pending Desktop draft is sufficient rollback before confirmation;
  deleting confirmed identities or teams remains an explicit Buzz owner action.

## Verification

```bash
node --test .agents/scripts/tests/test-team-interface-buzz-team-snapshot.mjs
node --test .agents/scripts/tests/test-team-interface-buzz-runtime.mjs
node --test .agents/scripts/tests/test-team-interface-acp-cwd-proxy.mjs
node --test .agents/scripts/tests/test-team-interface-buzz-worktree.mjs
node .agents/scripts/tests/test-team-interface-buzz-installed-startup.mjs
node --test .agents/plugins/opencode-aidevops/tests/test-team-interface-remote-interactive-profile.mjs
node --test .agents/scripts/tests/test-team-interface-agent-roster.mjs
node --test .agents/scripts/tests/test-team-interface-buzz-adapter.mjs
shellcheck .agents/bin/aidevops-buzz-acp \
  .agents/bin/aidevops-buzz-acp-interactive \
  .agents/scripts/buzz-team-provision-helper.sh \
  .agents/scripts/team-interface-buzz-worktree.sh
.agents/scripts/linters-local.sh --changed
```

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Buzz team-interface adapter

`adapter.buzz` is the trusted, in-tree, read-only adapter for Buzz Desktop. It
detects local provider state and projects a bounded provider-neutral inventory;
it does not provision, authenticate, launch, configure, reconcile, or mutate
Buzz, ACP runtimes, communities, agents, teams, or credentials.

The first verified baseline is Buzz Desktop `0.5.5` on macOS with application
identifier `xyz.block.buzz.app`. Other detected versions retain an `unknown`
compatibility state. Other platforms report the adapter unavailable until their
package and data layouts have independent current evidence.

## Selection and paths

The built-in registry freezes `adapter.buzz` with provider ID `buzz`. Runtime
configuration may select that ID with an opaque `settings:` reference, but the
adapter never resolves or emits the reference. No executable/module path can be
supplied through configuration.

The implementation uses only static in-tree imports: the adapter module owns
observation assembly, the command module owns bounded no-shell subprocesses,
the source module owns provider-specific reads, the path module owns component
identity, the safe-read module owns descriptor/permission checks, the snapshot
module owns private descriptor-backed SQLite copies, and the inventory module
owns the allowlisted provider-neutral projection.

The verified macOS defaults are:

- application metadata: `/Applications/Buzz.app/Contents/Info.plist`;
- managed-agent store: `~/Library/Application Support/xyz.block.buzz.app/agents/managed-agents.json`;
- team store: `~/Library/Application Support/xyz.block.buzz.app/agents/teams.json`; and
- WebKit data: `~/Library/WebKit/xyz.block.buzz.app/WebsiteData`.

`createBuzzAdapter(dependencies)` can replace those paths and read primitives
only as an in-process test seam. Production configuration cannot do so.

## Read boundary

Each observation may perform only these bounded reads:

1. validate the application directory and read the short version from
   `Info.plist` through macOS `plutil`;
2. open the managed-agent JSON as a private, current-user-owned regular file;
3. open the team JSON as a current-user-owned, non-group-writable regular file;
4. traverse a bounded non-symlink WebKit directory tree, copy one validated
   SQLite database and its present WAL/SHM sidecars into a private temporary
   directory, and query only the constant `buzz-communities` key there with
   `sqlite3 -readonly`; and
5. test stored agent process IDs for liveness without emitting the IDs or
   signalling/terminating any process.

JSON bytes, combined SQLite snapshot bytes, SQLite output, record counts,
directory entries, recursion depth, database count, and child-process buffers
are bounded. File reads use one non-symlink descriptor and verify
descriptor/path identity. Every source, WebKit root, and private snapshot path
captures and revalidates each component's device/inode across the operation, so
parent-directory replacement fails closed. The runtime abort signal reaches
streams, snapshot copies, and read-only child processes.

`plutil` consumes the inherited validated descriptor directly. SQLite never
reopens the mutable provider pathname: the main database and each present
sidecar are copied from validated open descriptors into a randomly named
mode-0700 directory below the aidevops temporary root, with mode-0600 snapshot
files. `sqlite3 -readonly` consumes a relative database name from that verified
directory so committed WAL state remains visible without reopening a provider
path. Known snapshot files and their directory are removed without recursive
cleanup after normal success, failure, or abort; identity drift fails closed
rather than following a replacement cleanup path. Persistent source replacement
and malformed/inconsistent copies degrade closed.

The adapter never calls Buzz/Tauri runtime discovery, Buzz Desktop, `buzz-acp`,
package managers, installers, authentication probes, provider APIs, shell
commands, credential stores, or the write-capable `buzz-desktop-helper.sh`.

## Inventory projection

Stable IDs are SHA-256-derived from typed provider external identities. Raw
pubkeys, relay URLs, community/team IDs, and instance identifiers are not
emitted and display labels never authorize identity matching or adoption.

| Collection | Emitted fields |
|---|---|
| Communities | Stable ID, display label, availability |
| Agents | Stable ID, display label, definition/instance kind, built-in marker, availability, optional community/runtime/team refs |
| Teams | Stable ID, display label, built-in marker, availability, canonical agent member refs |
| Runtimes | Stable ID, bounded referenced runtime label, availability |

Runtime records are created only for runtime IDs already referenced by managed
agent records. Team membership resolves persona IDs to observed definition
records; an instance's deployment relationship comes only from its actual
`team_id`. All collections and member refs use locale-independent stable-ID
ordering and pass the generic runtime uniqueness/reference validator before
persistence.

The projection excludes private keys, invite/access tokens, auth tags,
environment values, prompts, models/providers, commands and arguments, process
IDs, errors/logs, instructions/descriptions, source/binary/repository paths,
timestamps, backend identifiers, raw diagnostics, and `settings_ref`.

## Availability and compatibility

The fixed capability set covers installation, communities, agents, teams, and
referenced runtimes. Capability operations/resource kinds/review policy cannot
change at observation time; only availability changes.

- A supported safe `0.5.5` layout is `compatible`.
- Another readable version is detected with compatibility `unknown`.
- A missing installation or unsupported platform returns empty unavailable
  inventory without attempting provider reads or child processes.
- A missing store marks that capability unavailable.
- An existing malformed, oversized, symlinked, replaced, unowned, insecure, or
  ambiguous source marks its capability degraded and never masquerades as an
  available empty source.
- Safe inventories from unaffected sources may remain visible. Missing or
  unresolved optional relationships degrade the affected projection rather
  than emitting a dangling reference.
- Runtime timeout/abort stops pending stream or child reads; the core preserves
  prior valid state according to the generic adapter-version/capability binding.

Diagnostics retain only fixed runtime-owned categories. Provider file names,
contents, paths, child stderr, SQLite errors, and record values are never copied
into observations or diagnostics.

## Rollback and downgrade

To stop observing Buzz, remove `adapter.buzz` from the runtime selection and run
the current `detect` command so stale selected observations are cleared. Before
downgrading to a runtime that predates inventory support, archive the local
team-interface state after disabling the adapter. Reverting the adapter,
registry, schema, and semantic validator together is safe; rollback must never
delete or rewrite Buzz application data, WebKit storage, identities, teams,
agents, runtimes, or credentials.

## Verification

```bash
node .agents/scripts/tests/test-team-interface-buzz-adapter.mjs
node .agents/scripts/tests/test-team-interface-runtime.mjs
node .agents/scripts/tests/test-team-interface-core-schema.mjs
node --check .agents/scripts/team-interface-buzz-adapter.mjs
node --check .agents/scripts/team-interface-buzz-command.mjs
node --check .agents/scripts/team-interface-buzz-path.mjs
node --check .agents/scripts/team-interface-buzz-source.mjs
node --check .agents/scripts/team-interface-buzz-safe-read.mjs
node --check .agents/scripts/team-interface-buzz-snapshot.mjs
node --check .agents/scripts/team-interface-buzz-inventory.mjs
.agents/scripts/tests/test-team-interface-runtime-deps.sh
.agents/scripts/qlty-new-file-gate-helper.sh new-files --base origin/main --head HEAD
.agents/scripts/qlty-regression-helper.sh --base origin/main --head HEAD
.agents/scripts/linters-local.sh --changed
```

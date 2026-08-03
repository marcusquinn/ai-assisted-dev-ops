# Plist Environment Variable Overrides

Inject persistent environment variables into generated launchd plists without
losing them on every `aidevops update` or `setup.sh` run.

## Problem This Solves

`setup.sh` regenerates launchd plists on every run (~every 10 min via
`aidevops update`). Any manual edits to
`~/Library/LaunchAgents/com.aidevops.aidevops-supervisor-pulse.plist`,
`~/Library/LaunchAgents/com.aidevops.aidevops-supervisor-merge.plist`, or
`~/Library/LaunchAgents/com.aidevops.aidevops-auto-update.plist` are silently
wiped.

The override file survives framework updates because it lives in the stable
user config root, outside replaceable runtime bundles.

## Setup

```bash
# 1. Copy the committed template to the working file
mkdir -p ~/.config/aidevops
cp ~/.aidevops/agents/configs/plist-env-overrides.json.txt \
   ~/.config/aidevops/plist-env-overrides.json

# 2. Edit the working file — add the env vars you want
#    Keys prefixed with _ are ignored (template examples)
nano ~/.config/aidevops/plist-env-overrides.json

# 3. Run setup.sh to regenerate the plist with your overrides
~/.aidevops/agents/../setup.sh --non-interactive
# or: aidevops update

# For com.aidevops.aidevops-auto-update, reload that agent after changing
# its own environment so the running scheduler adopts the new plist:
aidevops auto-update disable
aidevops auto-update enable
```

## File Format

The override file is a JSON object keyed by **launchd plist label**. Each
value is an object of `{ "ENV_VAR_NAME": "value" }` pairs. All values must be
strings.

Keys prefixed with `_` are skipped — they serve as in-file comments.

```json
{
  "com.aidevops.aidevops-supervisor-pulse": {
    "SCANNER_NUDGE_AGE_HOURS": "0",
    "AUTO_DECOMPOSER_INTERVAL": "86400"
  }
}
```

## Supported Labels

The main Pulse, dedicated merge-pass, and scheduled auto-update agents are handled:

| Label | Plist |
|-------|-------|
| `com.aidevops.aidevops-supervisor-pulse` | `~/Library/LaunchAgents/com.aidevops.aidevops-supervisor-pulse.plist` |
| `com.aidevops.aidevops-supervisor-merge` | `~/Library/LaunchAgents/com.aidevops.aidevops-supervisor-merge.plist` |
| `com.aidevops.aidevops-auto-update` | `~/Library/LaunchAgents/com.aidevops.aidevops-auto-update.plist` |

Additional labels can be supported by extending
their plist generators to call `_build_plist_env_overrides_xml` from
`.agents/scripts/plist-env-overrides-lib.sh`.

## Worked Example: Bound Scheduled Update Storage

To apply lower runtime-bundle and setup-backup ceilings to background updates:

```json
{
  "com.aidevops.aidevops-auto-update": {
    "AIDEVOPS_RUNTIME_BUNDLE_MAX_COUNT": "5",
    "AIDEVOPS_RUNTIME_BUNDLE_MAX_BYTES": "1073741824",
    "BACKUP_KEEP_COUNT": "3"
  }
}
```

## Worked Example: Tune Per-Runner Thresholds

Runner A (aggressive nudging, wants decomposer every 24h):

```json
{
  "com.aidevops.aidevops-supervisor-pulse": {
    "SCANNER_NUDGE_AGE_HOURS": "0",
    "AUTO_DECOMPOSER_INTERVAL": "86400"
  }
}
```

Runner B (conservative, disable worker-briefed auto-merge for soak):

```json
{
  "com.aidevops.aidevops-supervisor-pulse": {
    "AIDEVOPS_WORKER_BRIEFED_AUTO_MERGE": "0"
  }
}
```

After `aidevops update`, verify the plist was updated:

```bash
grep -A1 "SCANNER_NUDGE_AGE_HOURS\|AUTO_DECOMPOSER_INTERVAL" \
  ~/Library/LaunchAgents/com.aidevops.aidevops-supervisor-pulse.plist
```

## Precedence and Conflict

Injected vars are appended to the plist `EnvironmentVariables` dict. If you
inject a key that already exists in the dict (e.g. `PATH`, `HOME`), the
**later definition wins** under launchd's dict parsing rules. Overriding
`PATH`, `HOME`, `OPENCODE_BIN`, or `PULSE_DIR` is not recommended — use the
override file for aidevops-specific tuning variables only.

## Error Handling

| Condition | Behaviour |
|-----------|-----------|
| File absent | Silent no-op. Default plist generated. |
| File present, valid JSON, label not found | No-op for that plist. |
| File present, malformed JSON | `WARN` logged; plist generated without overrides. |
| `jq` not installed | `WARN` logged; plist generated without overrides. |

## Legacy File Migration

During runtime-bundle deployment, setup copies an existing legacy working file
from `~/.aidevops/agents/configs/plist-env-overrides.json` to the stable config
root once. An existing stable file is never overwritten. Until that migration
runs, the scheduler still reads the legacy file when no stable file exists.
The stable file always takes precedence when both are present. Migration and
setup diagnostics never print override values; injection logs key names only.

## Template Location

The committed template (with example keys, all `_`-prefixed) lives at:
`.agents/configs/plist-env-overrides.json.txt`

The user-owned working file lives at:
`~/.config/aidevops/plist-env-overrides.json`

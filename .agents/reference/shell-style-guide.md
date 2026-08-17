<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Shell Helper Style Guide

Canonical rules for `.agents/scripts/**/*.sh`: **source `shared-constants.sh` OR use `[[ -z "${VAR+x}" ]]` guards**. Never assign `RED`, `GREEN`, `YELLOW`, `BLUE`, `PURPLE`, `CYAN`, `WHITE`, or `NC` at top level without a guard. Never `readonly` those names outside `shared-constants.sh`. Enforcement: `shell-init-pattern-check.sh` + CI. See `AGENTS.md` → "Quality Standards".

> **Shell script context only:** Code in this guide is for `.sh` files, not OpenCode Bash tool calls. OpenCode Bash supports pipelines but rejects redirects, dynamic expansion, grouping/subshells, background execution, and unquoted globs; use separate calls or file tools for those operations.

**Incident rationale (GH#18702):** On 2026-04-09, `init-routines-helper.sh:22` had an unguarded `GREEN='\033[0;32m'`. `setup.sh` sources it after `shared-constants.sh` (which has `readonly GREEN`). Under `set -Eeuo pipefail`, the re-assignment fatally aborted `setup.sh`, silently skipping `setup_privacy_guard` and `setup_canonical_guard` — **auto-update broken for 4 days** (cascade: GH#18693, fixed: PR #18728).

## Banned patterns

**Unguarded plain assignment** (collides with parent `readonly`) → fix: Pattern A or B.

```bash
# BAD
RED='\033[0;31m'
```

**Unguarded `readonly` on canonical names** (breaks on re-sourcing) → fix: Pattern B (production), C with prefix (tests).

```bash
# WORST
readonly RED='\033[0;31m'
```

**Coarse include-guard** (allowed for backward compat; discouraged):

```bash
if [[ -z "${_SHARED_CONSTANTS_LOADED:-}" ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
fi
```

All-or-nothing: colors partially undefined under `set -u` when parent set some without the sentinel. Pattern B handles each independently. Migrate opportunistically.

## Allowed shell script patterns

### A — source `shared-constants.sh` (preferred)

Inside `.agents/scripts/` with stable path to `shared-constants.sh`:

```bash
#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=shared-constants.sh
[[ -f "${SCRIPT_DIR}/shared-constants.sh" ]] && source "${SCRIPT_DIR}/shared-constants.sh"

echo -e "${GREEN}[OK]${NC} sourced shared constants"
```

Use `${RED}`, `${GREEN}`, etc. directly. Subdirectory scripts: `source "${SCRIPT_DIR}/../shared-constants.sh"`.

### B — granular `${VAR+x}` guard (fallback)

Scripts without `shared-constants.sh` (early bootstrap, standalone CLIs, curl-distributed):

```bash
#!/usr/bin/env bash
set -Eeuo pipefail

# Fallback colors — only assigned if not already set by a parent.
[[ -z "${RED+x}" ]]    && RED='\033[0;31m'
[[ -z "${GREEN+x}" ]]  && GREEN='\033[0;32m'
[[ -z "${YELLOW+x}" ]] && YELLOW='\033[1;33m'
[[ -z "${BLUE+x}" ]]   && BLUE='\033[0;34m'
[[ -z "${NC+x}" ]]     && NC='\033[0m'
```

`${VAR+x}` distinguishes *unset* from *set-to-empty* — parent `shared-constants.sh` wins; standalone picks up fallback. **Do not use `${VAR:-}`** — it treats set-to-empty as unset.

### C — prefixed names (test harnesses and strictly-internal utilities only)

Prefix must be `TEST_`, `_<script_name>_`, or documented in `shared-constants.sh`:

```bash
readonly TEST_RED=$'\033[0;31m'
readonly TEST_GREEN=$'\033[0;32m'
readonly TEST_RESET=$'\033[0m'
```

`readonly` safe — prefixed names don't collide. **Production helpers: use Pattern A or B.**

## Canonical shared variables

`shared-constants.sh` declares (all `readonly`):

| Variable | Purpose |
|----------|---------|
| `COLOR_RED`, `COLOR_GREEN`, `COLOR_YELLOW`, `COLOR_BLUE`, `COLOR_PURPLE`, `COLOR_CYAN`, `COLOR_WHITE`, `COLOR_RESET` | Canonical `COLOR_*` names (preferred in new code) |
| `RED`, `GREEN`, `YELLOW`, `BLUE`, `PURPLE`, `CYAN`, `WHITE`, `NC` | Short-name aliases (still supported) |

Non-canonical colors (`MAGENTA`, `GRAY`, `BOLD`, `DIM`) → declare locally with Pattern B. New canonicals → add to `shared-constants.sh` first.

## Counter Safety (grep -c)

**`grep -c` outputs its count to stdout AND exits 1 when there are zero matches.** The widespread idiom below therefore appends `echo`'s output to grep's own `0`, producing a multi-line string `"0\n0"` on the zero-match path:

```bash
# BANNED — produces "0\n0" when pattern is absent
count=$(grep -c 'pat' file 2>/dev/null || echo "0")
```

Canonical failure modes:

- Output corruption when interpolated into text (parent #20402 rendered `Progress: **0\n0 done, 0\n0 remaining**`)
- Broken numeric comparisons — `[[ "$count" -eq 0 ]]` raises a runtime error under `set -e` on non-integer strings
- Broken arithmetic — `$((count + 1))` is a syntax error
- Silent plural/singular bugs — `printf '%d files\n' "$count"` prints only the first integer

### Allowed pattern — `safe_grep_count` (preferred)

Scripts that source `shared-constants.sh` should use the helper:

```bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=shared-constants.sh
[[ -f "${SCRIPT_DIR}/shared-constants.sh" ]] && source "${SCRIPT_DIR}/shared-constants.sh"

count=$(safe_grep_count 'pat' file)
count=$(printf '%s\n' "$data" | safe_grep_count 'needle')
count=$(safe_grep_count -E '^[a-z]+$' file)
```

All `grep` flags pass through (`-E`, `-i`, `-F`, etc.). The helper always prints a single integer on a single line, including when the file does not exist or the pattern has zero matches.

### Allowed pattern — inline fallback

YAML workflow steps, bootstrap scripts, and standalone CLIs that cannot source `shared-constants.sh` use the inline form:

```bash
count=$(grep -c 'pat' file 2>/dev/null || true)
[[ "$count" =~ ^[0-9]+$ ]] || count=0
```

`|| true` catches grep's zero-match exit 1; the regex guard collapses any unexpected output (multi-line, empty, non-numeric) to `0`.

### Enforcement

- CI gate: `.github/workflows/counter-stack-check.yml` (diff-scoped — scans only PR-changed `.sh` / `.yml` files).
- Local check: `.agents/scripts/counter-stack-check.sh --scan-all`.
- Remediation snippets: `.agents/scripts/counter-stack-check.sh --fix-hint`.

**Test fixtures** that must contain the anti-pattern as a literal (e.g. `counter-stack-check.sh` itself, test files that verify the gate fires) add this directive in the first 20 lines:

```bash
# counter-stack-check:disable
```

The scanner skips any file with that directive.

### Originating incident

- PR [#20573](https://github.com/marcusquinn/aidevops/pull/20573) — Fix A for `.github/workflows/issue-sync.yml` phase-nudge visible corruption
- Parent issue #20581 (t2762) — systemic sweep and prevention
- Canonical reference implementation: `.agents/scripts/progressive-load-check.sh:80-97` (pre-existing correct counter usage)

## Stat portability (t3046)

BSD/macOS and GNU `stat` use incompatible flags. `stat -f %m` is BSD/macOS-only; GNU `stat` uses `stat -c %Y`. Do not use `stat -f` in `.agents/scripts/**` unless it is inside a platform-guarded branch such as `case "$(uname)" in Darwin*|FreeBSD*)`.

### Allowed patterns

- Use `_file_mtime_epoch "$file"` from `shared-constants.sh` for modification time.
- Use `_file_size_bytes "$file"` and `_file_perms "$file"` for size and permissions.
- If a script cannot source `shared-constants.sh`, define a small platform wrapper rather than inlining one platform’s `stat` flags at call sites.

### Enforcement

- CI gate: `.github/workflows/stat-portability-check.yml` (diff-scoped).
- Local check: `.agents/scripts/stat-portability-check.sh --dry-run --base origin/main`.
- Override: apply the `stat-portability-ok` label and include a `## Stat Portability Justification` section in the PR body.

Related incidents: GH#21617 and PR #21689. Earlier cross-platform failures are summarized in `reference/bash-compat.md`.

## Gate design — ratchet, not absolute (t2228 class)

New pre-commit validators and CI gates should block regressions, not all historical debt. Baseline the violation count at activation and fail only when the proposed change increases it. Absolute-count gates trap legacy files whenever they are touched and waste worker time on unrelated cleanup.

### Required gate semantics

- Security and credentials checks are the exception: new secrets, dangerous commands, and trust-boundary violations are absolute P1 findings. Classify that exception explicitly.
- `print_warning` output must not increment a violation counter. A warning is informational; returning non-zero from a warning path lies to the caller and turns advice into a blocker.
- New-file ratchets usually baseline at zero. Document that stricter rule so workers do not assume legacy grandfathering applies to new helpers.

### Patterns to copy

- `.agents/scripts/qlty-regression-helper.sh` (t2065)
- `.agents/scripts/qlty-new-file-gate-helper.sh` (t2068)

## Quality gate pattern reference

Quality gates should be narrow, diff-scoped where possible, and paired with a
documented local check plus an explicit override path. The gate should teach the
worker what to fix; the override should require evidence, not a maintainer guess.

### Critical rules for override documentation

- Keep required PR-body section names on one line so workers can copy exact
  headings, Markdown renders consistently, and validators can match the required
  identifier without whitespace-normalisation edge cases.
- State the technical reason for every override requirement so workers know when
  the label is evidence-backed rather than a bypass for unrelated gate failures.

### Qlty regression gate (t2065, GH#18773)

`.github/workflows/qlty-regression.yml` fails when a PR introduces a net increase
in `qlty smells` count. Docs-only PRs skip automatically. The helper
`.agents/scripts/qlty-regression-helper.sh` supports local dry runs and reports
the per-rule/per-file breakdown so the worker fixes the new regression instead
of chasing unrelated historical debt.

Override: apply the `ratchet-bump` label only with a PR-body justification that
explains why the increase is intentional or why the baseline must absorb drift.

### Qlty new-file smell gate (t2068)

`.github/workflows/qlty-new-file-gate.yml` fails when newly-added source files
ship with qlty smells. This complements t2065: modified existing files are
covered by the regression delta; brand-new files are held to a zero-smell
baseline so new subsystems do not import debt on day one.

Local check:

```bash
.agents/scripts/qlty-new-file-gate-helper.sh new-files --base origin/main --dry-run
```

Override: apply `new-file-smell-ok` and include the PR-body section
`## New File Smell Justification`. Both are required; the label alone should not
stick because new-file gates start from a zero-smell baseline and need explicit
evidence when importing debt is intentional.

### Workflow cascade vulnerability lint (t2229)

`.github/workflows/workflow-cascade-lint.yml` flags PRs that modify workflows
containing the cascade-vulnerable combination: label-like event types (`labeled`,
`unlabeled`, `assigned`, etc.), `cancel-in-progress: true`, and no mitigation
such as `paths-ignore` or an event-action guard. The canonical failure mode was
t2220: 15 cancelled runs in about 2 seconds after label churn retriggered the
same workflow repeatedly.

Local check:

```bash
.agents/scripts/workflow-cascade-lint.sh --dry-run
```

Override: apply `workflow-cascade-ok` and include the PR-body section
`## Workflow Cascade Justification` explaining why the event/action mix cannot
cascade or why the mitigation is equivalent. Both are required because
cascade-prone workflow triggers can create runaway CI churn even when a single
workflow edit looks harmless in isolation.

### Task-ID collision guard (t2047)

t-IDs in commit subjects must be allocated by `claim-task-id.sh`; invented IDs
break the audit trail and can collide with already-claimed work. Enforcement is
two-layered:

- Client-side commit-msg hook installed by
  `.agents/scripts/install-task-id-guard.sh install`.
- Server-side CI workflow installed alongside the hook, covering commits made
  outside the local hook path.

The guard permits cross-references to other tasks when the linked issue title or
body provides that context, but the primary commit task ID must be real.

## Self-modifying tooling test discipline (GH#18538 / t2062)

When you edit a script that participates in the test or verification loop you subsequently invoke, the working tree is part of the test environment. Running `full-loop-helper.sh`, `pre-edit-check.sh`, `claim-task-id.sh`, or another wrapper from the same worktree can execute uncommitted changes rather than the version that will ship.

Failure mode: a wrapper succeeds locally because of an uncommitted fix; a different or incomplete version is committed; main ships broken; the next worker fails with no obvious link to the local test.

### Required rule

1. Commit the change before running that script as verification, or
2. Re-test after restoring the committed/base version, for example `git stash && git checkout origin/main -- <script>`, to prove the committed state is what passed.
3. For wrappers that invoke themselves (`full-loop-helper.sh merge` is the canonical case), prefer the second pattern because it catches unstaged-file mistakes.

This applies to scripts and wrappers where source and runtime are the same file. It does not apply to product code that is built, packaged, or deployed before execution.

Canonical evidence: GH#18538 → PR #18748 shipped a `set -e` bug that local self-tests missed because an uncommitted if-form fix was present; PR #18750 hotfixed it and verified the rule end-to-end.

## Bash 3.2 compatibility (macOS default shell)

macOS ships bash 3.2.57. Shell helpers must avoid Bash 4+ features and parser traps even when CI or a developer shell uses newer bash. Full compatibility details live in `reference/bash-compat.md`; this section lists the shell-style implications that most often affect `.agents/scripts/**` edits.

### Common forbidden or risky constructs

- `declare -A` / `local -A`; use indexed arrays, delimiter-separated records, or grep-based lookup.
- `mapfile` / `readarray`; use `while IFS= read -r line; do arr+=("$line"); done < <(cmd)`.
- `${var,,}` / `${var^^}`; use `tr '[:upper:]' '[:lower:]'` or `tr '[:lower:]' '[:upper:]'`.
- `|&` and `&>>`; use `2>&1 |` and `>>file 2>&1`.
- Heredocs inside `$()`; assign quoted strings or write to a temp file instead.
- Literal ASCII apostrophes inside unquoted heredocs; quote the heredoc tag, use U+2019, or reword.

### Verification

- Run `/bin/bash -n script.sh` on macOS for parser compatibility.
- The `Bash 3.2 Compatibility` and `cross-platform-shellcheck` CI jobs catch known parser and syntax classes, but they do not replace review for BSD/GNU behaviour differences.

## Code-generators and the string-literal ratchet (t2834)

The string-literal ratchet (`pre-commit-hook.sh::validate_string_literals`) flags any `"..."`-quoted substring of 4+ chars that appears 3+ times in a single file, with the ratchet baselined at zero for **new** files (existing files are grandfathered at HEAD). Helpers that emit SVG, HTML, XML, or any other attribute-rich markup trip this trivially because every element repeats `width="`, `height="`, `fill="`, etc. as boundary fragments.

### Banned pattern — inline attribute fragments

Multiple `printf` calls (or one heredoc with many elements) each containing inline `attr="value"` fragments:

```bash
# Trips the ratchet — `" fill="`, `" width="`, `" height="` count >= 3
printf '  <rect x="%s" y="%s" width="%s" height="%s" fill="%s"/>\n' "$x" "$y" "$w" "$h" "$c"
printf '  <text x="%s" y="%s" font-family="%s" fill="%s">%s</text>\n' "$x" "$y" "$f" "$c" "$t"
```

### Allowed pattern — attribute-builder helpers

Build attribute strings via a single `'%s="%s" '` format template, eliminating inline fragments entirely:

```bash
_ATTR_FMT='%s="%s" '

_svg_attrs() {
    local _out=""
    while [[ $# -ge 2 ]]; do
        local _k="$1" _v="$2"
        # shellcheck disable=SC2059  # _ATTR_FMT is a trusted constant
        _out+=$(printf "$_ATTR_FMT" "$_k" "$_v")
        shift 2
    done
    printf '%s' "${_out%% }"
    return 0
}

_svg_elem() {
    local _tag="$1"; shift
    local _attrs; _attrs=$(_svg_attrs "$@")
    printf '  <%s %s/>\n' "$_tag" "$_attrs"
    return 0
}

# Usage — no inline attr= fragments, no ratchet trip
_svg_elem rect x "$x" y "$y" width "$w" height "$h" fill "$c"
```

Canonical implementation: `.agents/scripts/loc-badge-helper.sh::_svg_attrs / _svg_elem / _svg_open / _svg_close / _svg_text_elem`.

### Ratchet baseline-at-zero for new files

Every ratchet-style validator (string-literal, positional-parameter, function-complexity, nesting-depth, file-size) compares HEAD content vs staged content. For an **existing** file with pre-existing violations, the ratchet only blocks when the staged count exceeds HEAD — pre-existing debt is grandfathered.

For a **new** file, HEAD count is zero. Every violation is "new" and blocks the commit.

**Practical rule:** in a new file, follow the strict pattern from line 1. The "fix later" approach available to maintenance commits on legacy files is not available to new files.

Examples of strict patterns required from line 1 of every new shell helper:

- Positional parameters: `local _arg="$1"` always (never bare `case "$1" in` or `VAR="$2"`)
- Function arguments: `local _msg="$1"` at the top of every function body
- Repeated string fragments: extract to constants OR build via a helper template (see attribute-builder pattern above)

### Detection

Reproduce the validator locally before committing a new helper:

```bash
# Show literals that would trigger the ratchet (after the canonical sed pre-strip)
grep -v '^[[:space:]]*#' your-helper.sh | sed -E '
  s/"\$[A-Za-z_][A-Za-z0-9_]*"//g
  s/"\$\{[^}]*\}"//g
  s/"\$@"//g
  s/"\$[0-9*#?$!-]"//g
' | grep -oE '"[^"]{4,}"' | grep -vE '^"[0-9]+\.?[0-9]*"$' | grep -vE '^"\$' | sort | uniq -c | awk '$1 >= 3' | sort -rn

# Show direct positional-parameter usage that would trigger
awk '
  { line = $0
    gsub(/\047[^\047]*\047/, "", line)
    if (line ~ /^[[:space:]]*#/) next
    sub(/[[:space:]]+#.*/, "", line)
    if (line ~ /local[[:space:]].*=.*\$[1-9]/) next
    if (line ~ /\$[1-9]/) print NR ": " $0
  }
' your-helper.sh
```

Both must be empty before commit.

## Migration checklist

1. Identify current pattern (plain, readonly, include-guard, or prefixed).
2. Choose target — A (inside `.agents/scripts/`, stable path), B (standalone bootstrap), C (test harness only).
3. Replace unguarded assignments with chosen pattern block (after `set -Eeuo pipefail`, before functions).
4. Test standalone (`bash ./the-script.sh --help`) and sourced (`setup.sh --non-interactive`). `shellcheck` must pass.
5. Commit. The lint gate (`shell-init-pattern-check.sh`) automates detection and PR enforcement.

## mktemp portability (t2997)

`mktemp` template arguments must end the `XXXXXX` placeholder at the END of the path. macOS BSD `mktemp` does **not** substitute `XXXXXX` when followed by a literal extension — it returns the literal template name unchanged on first call and `mkstemp failed: File exists` on every subsequent call (until the literal-named file is removed).

```bash
# BANNED — macOS-broken
mktemp /tmp/foo-XXXXXX.json    # first: /tmp/foo-XXXXXX.json (literal)
                               # next:  mkstemp failed: File exists
mktemp /tmp/foo.XXXXXX.log     # same — XXXXXX is not at end
```

### Allowed pattern A — drop the extension (preferred)

```bash
tmp=$(mktemp "${TMPDIR:-/tmp}/foo-XXXXXX")
```

Most temp files (data, scripts run by interpreter via `python "$tmp"`, `bash "$tmp"`, log buffers, intermediate JSON read by `jq < "$tmp"`) do NOT need an extension. The interpreter or content-type detection works on bytes, not filename suffix. Drop the extension and the BSD bug disappears.

### Allowed pattern B — extension before the placeholder

```bash
tmp=$(mktemp "${TMPDIR:-/tmp}/foo.json.XXXXXX")
```

Use only when downstream code matches on the extension as a substring (rare). The placeholder MUST be the final segment.

### Allowed pattern C — `mktemp -d` + fixed filename (extension-required tools)

```bash
tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/foo-XXXXXX")
script_file="$tmp_dir/script.mjs"
# ... write/use $script_file ...
rm -rf "$tmp_dir"
```

REQUIRED for `node` ESM (`.mjs` / `.cjs`) — node 22+ refuses to load the file unless the extension is exact. Use a unique directory + fixed-name child file. Cleanup is `rm -rf "$tmp_dir"`.

### Enforcement

CI gate `.github/workflows/mktemp-portability-check.yml` runs `lint-mktemp-portability.sh` against PR-changed `.sh` files and blocks any new instance of `XXXXXX.<ext>` in a `mktemp` template argument.

```bash
# Local check (whole tree)
bash .agents/scripts/lint-mktemp-portability.sh

# Local check (specific files)
bash .agents/scripts/lint-mktemp-portability.sh path/to/script.sh
```

The lint deliberately ignores `mktemp -d` and `mktemp -u` invocations (the bug only triggers on file-creation form), and excludes test fixtures that intentionally test the bug.

### Originating incident

GH#21408 (t2997) — `pulse-prefetch-fetch.sh:1107` `update_repo_tier_check_timestamp` produced 142 `mkstemp failed` lines/day in `pulse-wrapper.log` during launchd respawn races. 42 production callsites had the same bug. Reproduction:

```bash
mktemp /tmp/x-XXXXXX.json    # macOS: /tmp/x-XXXXXX.json (literal!)
mktemp /tmp/x-XXXXXX.json    # macOS: mkstemp failed: File exists
mktemp /tmp/x.json.XXXXXX    # macOS: /tmp/x.json.TW5AIa (correct)
mktemp /tmp/x-XXXXXX         # macOS: /tmp/x-mGVJcx (correct)
```

GNU `mktemp` (Linux) accepts both forms, masking the bug in CI. The lint gate enforces the BSD-safe form everywhere so future macOS regressions are caught at PR time.

## Watchdog self-write anti-pattern (t3058 / t3071)

If a script monitors file `X` for activity as a **stall signal** (byte-delta, line-count, or mtime polling), the SAME script MUST NOT write status markers to `X`. Self-writes register as "progress" and silently neuter the timeout — the very condition the marker was meant to instrument becomes unreachable. There is no log line, no exit code, no alert when this happens; the watchdog simply never trips.

### Banned pattern

```bash
# Watchdog polls $OUTPUT_FILE size in a 60s loop:
last_size=$(_file_size_bytes "$OUTPUT_FILE")
# ... later, on stall detection or transition events ...
echo "[lifecycle] defer marker" >>"$OUTPUT_FILE"   # BANNED — self-write to monitored file
# Next poll: current_size > last_size → "progress detected" → stall counter zeroed
```

### Allowed pattern — sibling lifecycle log

```bash
# Route status markers to a separate file the watchdog never reads:
echo "[lifecycle] defer marker" >>"$LIFECYCLE_LOG"
# Canonical destination: ~/.aidevops/logs/pulse-dispatch.log
```

`$LIFECYCLE_LOG` (defined in `worker-lifecycle-common.sh`, default `~/.aidevops/logs/pulse-dispatch.log`) is the canonical destination for lifecycle markers — defer events, kill events, classification events, recovery events. Pick a different sibling log only when the marker is conceptually distinct from lifecycle telemetry.

### Why it's a silent bug

- **No observable failure.** The stall timeout becomes a no-op; nothing breaks loudly. Because the hard elapsed threshold applies only after a confirmed stall, self-written output can defeat both checks and hide a genuinely stuck worker.
- **Cross-function variants are subtler.** If function A writes to `$LOGFILE` and function B's polling loop reads `$LOGFILE`, A's writes register as B's "progress" — even when A had nothing to do with the work B was monitoring. (See `pulse-watchdog.sh:426` — idle-resume echo writes affect progress-check stall counter.)
- **Bug ships unnoticed.** The canonical t3058 case shipped for ~1 year because there was no test that monitored watchdog firing in the marker-write path. Code review caught nothing; runtime behaviour caught nothing.

### Detection

Find scripts matching BOTH signals:

```bash
# 1. Polling loops on file size/lines/mtime
rg -l 'last_size|prev_size|byte_delta|previous_size|file_size_prev' .agents/scripts/

# 2. For each candidate, identify the monitored file variable, then check for writes to it
for f in $(rg -l 'last_size|prev_size|byte_delta' .agents/scripts/); do
  rg "(>>|tee|printf.*>).*\$\{?[A-Z_]+\}?" "$f"
done
```

### Classification

Any non-empty result requires triage:

- **GENUINE** — same code path writes to the monitored file with no defensive countermeasure → fix by routing to `$LIFECYCLE_LOG`.
- **DEFENDED** — write happens outside the watch window (e.g., post-kill marker after the monitoring loop has exited), OR a sentinel filter excludes the marker bytes from the count → safe; document the contract in a comment.
- **UNRELATED** — false positive from the regex (e.g., monitoring tracks growth rate, not stall; or the write is to a completely different file aliased through a similarly-named variable).

### Canonical fix examples

- `worker-activity-watchdog.sh:570-583` — t3058 fix (PR #21797). Defer-marker writes routed to `$LIFECYCLE_LOG` after originally going to `$OUTPUT_FILE`.
- `pulse-watchdog.sh:378` (progress-resume echo) and `:426` (idle-resume echo) — t3071 audit findings; fix dispatched as separate auto-dispatch issue.

### Originating incident

PR #21797 (t3058) — `worker-activity-watchdog.sh` defer-marker writes to `$OUTPUT_FILE` silently neutered `STALL_TIMEOUT` for any CPU-busy worker. The bug shipped undetected for ~1 year because the failure mode was structural invisibility — the timeout simply never fired, and no test exercised the marker-write path with a co-located stall monitor. Regression test pinning the contract: `tests/test-watchdog-no-false-kill.sh` Test 4b. Anti-pattern audit pass: t3071.

## Related

- **Originating incident**: PR #18728, GH#18702 (primary), GH#18693 (cascade)
- **Consolidation parent**: GH#18735 (t2053, closed — all phases complete as of PR #19180)
- **Canonical source**: `.agents/scripts/shared-constants.sh`
- **Prior art**: Pattern B: `watercrawl-helper.sh:58`, `security-helper.sh:22`, `routine-log-helper.sh:30`. Include-guard: `circuit-breaker-helper.sh:64-70`.
- **Build-time rule**: `AGENTS.md` → "Quality Standards"
- **Architecture pointer**: `aidevops/architecture.md` → "Shell Helper Initialization"

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Large-File Split Playbook for Shell Libraries

Consolidated from six prior worker attempts on GH#19699, each of which re-discovered
the same framework lessons from scratch. This document exists so the next worker
arrives already knowing the answer.

## 0. Briefing Checklist for Function-Modifying Tasks (t2803)

**Read this before writing any brief that grows an existing shell function.**

Canonical failure: issue #20702 / PR #20705 + 7 subsequent dispatch attempts all hit
the same Complexity Analysis wall on `_parse_phases_section`. The function was already
~60 lines; the brief said "add an elif branch" without mentioning the 100-line
`function-complexity` threshold or the extract-helpers precedent (GH#20496 / PR #20503).
Every worker copied the same shape and got the same red build. Eventually PR #20736
resolved it by extracting four helpers — an approach that takes ~10 minutes to design
but workers couldn't discover from the brief.

**Gate thresholds** (enforced by `complexity-regression-helper.sh` / `code-quality.yml`):

| Metric | Threshold | Identity key |
|--------|-----------|-------------|
| `function-complexity` | 100 lines | `(file, fname)` |
| `nesting-depth` | 4 levels deep | `(file, 'NEST')` |
| `file-size` | 1500 lines (shell) | `(file)` |

**Decision rule for brief authors:**

1. Locate the target function: `grep -n "^{function_name}()" {file}` and count its lines.
2. Estimate lines added by this task.
3. Apply the rule:

| Projected post-change | Required action |
|----------------------|----------------|
| < 80 lines | No action — delete the `### Complexity Impact` section from the brief |
| 80–100 lines | Warning — add `### Complexity Impact` section, note the risk, monitor during review |
| > 100 lines | **Mandatory** — plan extract-helpers refactor first, list the helpers to extract in `### Complexity Impact` |

**Brief requirement:** include the `### Complexity Impact` subsection (from
`~/.aidevops/agents/templates/brief-template.md`) in every brief that modifies an existing function body.
Workers dispatched without this context cannot detect the impending gate failure.

**Extract-helpers pattern:** see section 2 of this document for the canonical
orchestrator + sub-library pattern. For function-internal extracts (not file splits),
create new private helper functions in the same file: `_parse_<feature>()`, `_validate_<feature>()`, etc.
The extract-helpers approach from GH#20496 / PR #20503 is the proven model for the same
file pattern. Workers reading this section + the issue body should be able to design the
extract plan without re-discovering it from scratch.

**Override procedure** (when growth is unavoidable): apply `complexity-bump-ok` label
to the PR with a `## Complexity Bump Justification` section. See section 4 of this doc.

## 1. When to Use This

Use this playbook when:

- You are responding to a `file-size-debt`, `function-complexity`, or `nesting-depth`
  scanner-filed issue that recommends splitting a shell library.
- You are voluntarily splitting a shell lib that has grown past maintainable size
  (the `file-size` scanner threshold is 1500 lines for `.sh` files).

**Do not use** for non-shell splits (Python, JS, etc.) or for refactors that change
behaviour. This playbook covers mechanical, behaviour-preserving splits only.

## 2. Canonical Pattern

Two in-repo precedents demonstrate the pattern end-to-end:

| Precedent | Orchestrator | Sub-libraries |
|-----------|-------------|---------------|
| Simple | `issue-sync-helper.sh` | `issue-sync-lib.sh` |
| Complex | `headless-runtime-lib.sh` | `headless-runtime-provider.sh`, `headless-runtime-failure.sh`, `headless-runtime-model.sh` |

### 2.1 Orchestrator file

The orchestrator retains the original filename. It keeps:

- The include guard (`[[ -n "${_XXX_LOADED:-}" ]] && return 0`)
- The `shared-constants.sh` import
- The `SCRIPT_DIR` fallback (see 2.3)
- `source` calls to each sub-library
- Any functions whose identity keys must be preserved (see section 3)

### 2.2 Sub-library file

Each sub-library follows this template:

```bash
#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# <Library Name> -- <One-Line Description>
# =============================================================================
# <Multi-line description of what this sub-library covers.>
#
# Usage: source "${SCRIPT_DIR}/<this-file>.sh"
#
# Dependencies:
#   - shared-constants.sh (print_error, print_info, etc.)
#   - <any other dependencies>
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_<UNIQUE_NAME>_LIB_LOADED:-}" ]] && return 0
_<UNIQUE_NAME>_LIB_LOADED=1

# --- Functions ---

# <function definitions here>
```

### 2.3 Sourcing sub-libraries from the orchestrator

The orchestrator sources sub-libraries via `$SCRIPT_DIR`. ShellCheck cannot
statically resolve runtime-computed paths, so each source call needs two
directives. From `headless-runtime-lib.sh:102-104`:

```bash
# shellcheck source=./headless-runtime-provider.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/headless-runtime-provider.sh"
```

### 2.4 Defensive `SCRIPT_DIR` fallback

Both orchestrators and sub-libraries need `SCRIPT_DIR` to resolve sibling
files. The caller (e.g., `headless-runtime-helper.sh`) usually sets it, but
test harnesses and direct sourcing may not. Add this fallback at the top,
after the include guard. Cite: `issue-sync-lib.sh:35-41`:

```bash
if [[ -z "${SCRIPT_DIR:-}" ]]; then
    # Pure-bash dirname replacement -- avoids external binary dependency
    _lib_path="${BASH_SOURCE[0]%/*}"
    [[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
    SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
    unset _lib_path
fi
```

## 3. Identity-Key Preservation Rules

The complexity scanners (`complexity-regression-helper.sh`) track violations by
identity keys. Moving code between files can create or destroy violations
depending on the metric.

| Metric | Identity key | Split impact | Action |
|--------|-------------|-------------|--------|
| `function-complexity` | `(file, fname)` | Moving a >100-line function to a new file re-registers it as a **new** violation. | Functions over 100 lines **MUST stay in the original file**. Example: `_run_canary_test` stayed in `headless-runtime-lib.sh` (PR #19821). |
| `file-size` | `(file)` | Splitting automatically resolves the original file's violation. New sub-files are typically under the threshold. | No special action needed. |
| `nesting-depth` | `(file, 'NEST')` | Splitting into new files creates new `(newfile, 'NEST')` keys. Expect `+N new` regressions. | This is a **known false positive** -- see section 4. Override with `complexity-bump-ok` label. |
| `bash32-compat` | `(construct)` | Splitting is neutral -- the construct identity doesn't include the file. | No special action needed. |

**Critical rule**: before splitting, run `complexity-regression-helper.sh check`
on the pre-split state. Identify every `function-complexity` violation in the
target file. Those functions stay put.

## 4. Known CI False-Positive Classes on Splits

### 4.1 Nesting-depth scanner

**Status (GH#20105):** The AWK regex scanner has been replaced by a
`shfmt --to-json` AST walker (`scanners/nesting-depth.sh`). The four
false-positive classes documented below are now resolved by construction.
The `complexity-bump-ok` override for nesting-depth false positives should
no longer be needed for file splits. The override procedure remains valid
for the other complexity metrics (function-complexity, file-size, bash32-compat).

**Previous false positives (historical reference):**
The prior AWK scanner used regex pattern matching that matched `elif` as
`if`, missed `done <<<`/`done |` closers, counted prose keywords, and
never reset between functions. These are no longer relevant -- the shfmt
AST walker computes per-function depth correctly.

**Override procedure (still valid for non-nesting metrics):**

1. Apply the `complexity-bump-ok` label to the PR.
2. Add a `## Complexity Bump Justification` section to the PR body with:
   - The scanner evidence (file:line ref showing the identity-key artifact)
   - The measurement (`base=N, head=M, new=K`)
   - Explanation that the new violations are identity-key artifacts, not real increases.

**Worker self-apply (t2370):** Workers dispatched against file-split or
simplification issues may self-apply the `complexity-bump-ok` label. The
`.github/workflows/complexity-bump-justification-check.yml` workflow triggers
on the `labeled` event and validates that the PR body contains the required
justification section with at least one `file:line` reference and a numeric measurement.
If validation fails, the workflow removes the label and posts a remediation
comment explaining what is missing. The label only sticks when the
justification is complete -- no maintainer intervention required for
legitimate splits. This mirrors the `new-file-smell-ok` + justification-section
pattern from `qlty-new-file-gate.yml`.

Primary use case: file splits that trigger identity-key artifacts in
file-size/function-complexity/bash32-compat gates. Do not use the label to hide
real complexity growth; the PR body must show the scanner evidence and the
measurement (`base=N, head=M, new=K` or similar) so the automated validator and
human reviewer can distinguish a split artifact from new debt.

### 4.2 Pre-push complexity guard

The client-side `complexity-regression-pre-push.sh` hook rejects on the same
false positive. Targeted bypass:

```bash
COMPLEXITY_GUARD_DISABLE=1 git push
```

Document this alongside the CI label in your PR body.

## 5. Pre-Commit Hook Gotchas (and Compliant Rewrites)

### 5.1 SC1091 from sourced sub-libraries

The pre-commit ShellCheck hook flags `source "${SCRIPT_DIR}/sub-lib.sh"` as
SC1091 ("Not following: ... was not specified as input"). Fix with an inline
directive and a one-line reason:

```bash
# shellcheck source=./sub-lib.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/sub-lib.sh"
```

### 5.2 Positional parameter validation

`validate_positional_parameters` flags `"$1"` usage in rest-args emit loops.
Compliant rewrite (identical behaviour, no `$1` reference):

```bash
# Before (flagged):
while [[ $# -gt 0 ]]; do printf '%s\0' "$1"; shift; done

# After (compliant):
[[ $# -gt 0 ]] && printf '%s\0' "$@"
```

### 5.3 String-literal validation (t2230 bug)

`validate_string_literals` flags `"$var"` interpolations as "repeated string
literals". These are variable references, not literals -- this is a **known
framework bug** tracked in t2230 (GH#19739).

If you hit this on a split, do NOT rewrite variable references to deduplicate
(that causes code harm). Options:

1. If t2230 has landed, use whatever opt-out it ships.
2. Otherwise: `COMPLEXITY_GUARD_DISABLE=1` + commit with `--no-verify` +
   document the maintainer authorization in the commit message and PR body
   self-assessment section.

## 6. PR Body Template

Write this skeleton to an absolute body file, append
`gh-signature-helper.sh footer`, then pass it to `gh pr create --body-file` in a
later Bash tool call. Replace placeholders in `<angle brackets>`.

````markdown
## Summary

Split `<original-file>` (<N> lines) into <M> focused files so every shell
script is under the <threshold>-line file-size-debt threshold. Function groups
move verbatim; no behavioural changes.

| file | lines | scope |
|---|---|---|
| `<orchestrator>` | <N> | thin orchestrator: <scope summary> |
| `<sub-lib-1>` | <N> | <scope summary> |
| `<sub-lib-2>` | <N> | <scope summary> |

Mirrors the `issue-sync-helper.sh` / `issue-sync-lib.sh` split precedent.
Each sub-library has an include guard and a `# shellcheck source=./...`
directive paired with an SC1091 disable (runtime-resolved via `$SCRIPT_DIR`,
cannot be statically followed without `-x`).

## Changes

1. **<M> files** -- <N-1> new sub-libraries + rewritten orchestrator lib. No
   caller-facing API changes; `<caller>` continues to source only
   `<orchestrator>`.
2. **Defensive `SCRIPT_DIR` fallback** in `<orchestrator>` (derived from
   `BASH_SOURCE[0]`, matches the `issue-sync-lib.sh` pattern).
3. **<Any compliant rewrites>** (e.g., rest-arg loops rewritten per
   `reference/large-file-split.md` section 5.2).
4. **`<large-function>` stays in `<orchestrator>`** -- deliberately, to keep
   its `(file, fname)` identity key unchanged so the function-complexity
   metric does not regress.

## Testing

- `shellcheck <all-files>` -- clean at warning+error severity
- Smoke test via the real caller path (`SCRIPT_DIR=... source <orchestrator>`):
  all expected functions resolve; behaviour is identical
- `complexity-regression-helper.sh check` vs `origin/main`:
  - `file-size`: base=<N>, head=<N>, **new=0**
  - `function-complexity`: base=<N>, head=<N>, **new=0**
  - `bash32-compat`: base=<N>, head=<N>, **new=0**
  - `nesting-depth`: base=<N>, head=<N>, new=<K> -- see justification below

## Complexity Bump Justification

**`complexity-bump-ok` label applied.** The nesting-depth scanner reports <K>
new violations solely because the `(file, 'NEST')` identity key changes when
code moves to freshly-named files. The metric is not real nesting depth.

**Note (GH#20105):** The nesting-depth scanner now uses `shfmt --to-json`
AST walking with per-function reset. The false-positive evidence below applied
to the old AWK regex scanner and may no longer be needed for nesting-depth
violations. If you still see nesting-depth regressions on file splits, they
reflect real nesting changes. For other metrics (function-complexity,
file-size, bash32-compat), the identity-key justification below still applies.

**Pre-existing debt moved, not introduced:** identity-key violations from
file splits are artifacts of code relocation, not new complexity. Apply
`complexity-bump-ok` per the documented override procedure.

## Related

- Resolves #<issue-number>
- Reference: `reference/large-file-split.md`

## Self-Assessment

**`--no-verify` disclosure:** <if used, document why and what maintainer
authorized it. If not used, delete this section.>
````

## 7. Verification Checklist

Run these checks before pushing:

### 7.1 ShellCheck

```bash
shellcheck .agents/scripts/<orchestrator>.sh .agents/scripts/<sub-lib-1>.sh ...
```

Must be clean at warning+ severity. SC1091 must be suppressed inline (section 5.1),
not globally.

### 7.2 Smoke test

Confirm all expected functions resolve and behaviour is identical:

```bash
SCRIPT_DIR=.agents/scripts source .agents/scripts/<orchestrator>.sh

# Verify key functions are available:
type <function_1> <function_2> <function_3>
```

### 7.3 Complexity regression check

```bash
.agents/scripts/complexity-regression-helper.sh check
```

Expected results for a well-executed split:

- `file-size`: `new=0` (original >threshold file cleared)
- `function-complexity`: `new=0` (large functions stayed in original file)
- `bash32-compat`: `new=0` (splitting is neutral)
- `nesting-depth`: `new>=0` (document any `new>0` in PR body per section 4.1)

### 7.4 Pre-push dry run

```bash
COMPLEXITY_GUARD_DISABLE=1 git push --dry-run
```

If the dry run passes with the complexity guard disabled, the only remaining
gate is the CI `complexity-bump-ok` label (section 4.1).

---

## Related

- GH#19699, PR #19821 -- the session that surfaced the missing documentation
- GH#19739 (t2230) -- string-literal hook bug; if fixed, section 5.3 simplifies
- `reference/bash-compat.md` -- Bash 3.2 compatibility rules
- `tools/code-review/code-simplifier.md` -- primary consumer for simplification issues

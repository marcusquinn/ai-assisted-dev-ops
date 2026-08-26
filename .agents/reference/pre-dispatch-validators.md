# Pre-Dispatch Validators

Runs **after** dedup checks and **before** worker spawn for auto-generated issues — verifies the premise still holds (GH#19118). Issues embed `<!-- aidevops:generator=<name> -->` in the body (HTML comments survive title/label changes). `pre-dispatch-validator-helper.sh` maps generators to validators via `_VALIDATOR_REGISTRY`. Unregistered generators, missing helper, or unexpected exit code → exit 0 (dispatch proceeds).

## Exit codes

| Code | Meaning | Action |
|------|---------|--------|
| `0`  | Premise holds or no validator registered | Worker spawned |
| `10` | Premise falsified | Comment posted (`> Premise falsified`, citing GH#19118) + `gh issue close --reason "not planned"` |
| `20` | Validator error | Warning logged; dispatch proceeds (never block on validator bugs) |

## Hook point (`pulse-dispatch-core.sh`)

```text
_dispatch_dedup_check_layers()   ← all dedup gates
_ensure_issue_body_has_brief()   ← t2063 freshness guard
_run_tier_simple_body_shape_check() ← explicit simple-contract guard
_run_predispatch_validator()     ← GH#19118 ← HERE
_refresh_issue_meta_after_tier_policy_checks() ← only after a label mutation
_dispatch_launch_worker()        ← worker spawn
```

## Bypass

```bash
AIDEVOPS_SKIP_PREDISPATCH_VALIDATOR=1 ./pulse-wrapper.sh
```

Emergency recovery when a validator bug blocks legitimate dispatches. Bypass is logged; do not leave set permanently.

## Registered validators

### `ratchet-down`

**Generator:** `_complexity_scan_ratchet_check` in `pulse-simplification.sh`
**Marker:** `<!-- aidevops:generator=ratchet-down -->`

1. Clone target repo into `mktemp -d` (trap-cleaned); run `complexity-scan-helper.sh ratchet-check <clone> 5`.
2. `No ratchet-down available` in output → exit 10 (falsified); empty output + any error → exit 20; otherwise → exit 0.

Prevents workers spawning only to find no ratchet-down work exists (GH#19024).

### Self-hosting dispatch-path detector (t2819)

**Type:** Advisory pre-step (not a generator-marker validator)
**Marker:** None — scans issue body for dispatch-path file patterns regardless of generator
**Bypass:** `AIDEVOPS_SKIP_SELF_HOSTING_DETECTOR=1`
**Dry-run:** `AIDEVOPS_SELF_HOSTING_DETECTOR_DRY_RUN=1`

Runs BEFORE generator-marker validators in `cmd_validate()`. Detects issues that modify the worker dispatch/spawn path by scanning the body's `## Files to modify` / `## How` sections for canonical dispatch-path file patterns (`pulse-wrapper.sh`, `pulse-dispatch-*.sh`, `headless-runtime-helper.sh`, `worker-lifecycle-common.sh`, `shared-dispatch-dedup.sh`, etc.).

When dispatch-path work is detected without one normalized `tier:thinking` label:

1. Removes lower `tier:*` labels and applies `tier:thinking` via `gh issue edit`
2. Posts a provenance-wrapped audit comment (`<!-- self-hosting-tier-override -->` marker for idempotency)
3. Signals the dispatcher to refresh its bundled issue metadata before model resolution
4. Returns 0 (never blocks dispatch)

**Rationale:** Self-hosting tasks run through the dispatch path being changed. Applying the terminal workload tier upfront avoids lower-tier attempts while leaving concrete model and reasoning selection to runtime routing.

**Tests:** `tests/test-self-hosting-detector.sh` — 7 cases covering positive/negative/mixed-scope/idempotency/bypass/dry-run/tier-guard.

### Review-feedback supersession detector (t3569)

**Type:** Advisory/blocking pre-step for `source:review-feedback` and `quality-debt` issues
**Marker:** None required — uses labels/title plus cited file paths and finding keywords
**Bypass:** `AIDEVOPS_SKIP_REVIEW_FEEDBACK_SUPERSESSION=1`

Runs before generator-marker validators in `cmd_validate()`. It extracts qualified, non-blockquoted target paths and compact finding keywords from the issue body, searches recently merged PRs after the applicable issue/source-review timestamp, and inspects PR file lists plus title/body/diff text. Bare basenames and paths found only in quoted review prose are not file identity.

Outcomes:

1. Existing issue + same-file merged PR that directly references the issue → posts `<!-- review-feedback-superseded-by-merged-pr -->`, closes the issue as `not planned`, returns `10`, and skips worker dispatch.
2. Existing issue + same-file keyword-only match → posts one `<!-- review-feedback-supersession-ambiguous -->` decision-ready comment and returns `0` so dispatch proceeds. Heuristic prose overlap never closes an existing issue.
3. Read-only post-merge precreation check + qualified same-file match with 2+ keywords → returns `10` so the scanner can suppress a duplicate issue. This caller passes issue number `0`, performs no GitHub write, and fails closed for API uncertainty.
4. No qualified same-file candidate or missing dispatch metadata → returns `0`; normal dispatch proceeds.

**Tests:** `.agents/scripts/tests/test-review-feedback-supersession-validator.sh` — direct-reference closure, keyword-only ambiguity, quoted/basename path rejection, precreation dedup, no matching PR, and PR merged before issue creation.

## Adding a validator

1. Define the generator function in `pulse-simplification.sh` or the issue-creation script.
2. Emit the marker in the issue body: `<!-- aidevops:generator=my-generator -->`
3. Implement in `pre-dispatch-validator-helper.sh`:

   ```bash
   _validator_my_generator() {
       local slug="$1"
       # Use $SCRATCH_DIR for temp files — trap cleanup already set
       return 0  # 0=dispatch, 10=falsified, 20=error
   }
   ```

4. Register in `_register_validators()`:

   ```bash
   _VALIDATOR_REGISTRY["my-generator"]="_validator_my_generator"
   ```

5. Add test cases in `tests/test-pre-dispatch-validator.sh` (falsified + legitimate paths).
6. Run `shellcheck .agents/scripts/pre-dispatch-validator-helper.sh`.

## Testing

```bash
bash .agents/scripts/tests/test-pre-dispatch-validator.sh
bash .agents/scripts/tests/test-self-hosting-detector.sh
bash .agents/scripts/tests/test-review-feedback-supersession-validator.sh
.agents/scripts/pre-dispatch-validator-helper.sh validate <issue-number> marcusquinn/aidevops
```

`gh`, `git`, and `complexity-scan-helper.sh` stubbed via `PATH` and `COMPLEXITY_SCAN_HELPER` — no network required.

## Related

- `pulse-dispatch-core.sh` — `dispatch_with_dedup`, `_run_predispatch_validator`
- `pulse-simplification.sh` — `_complexity_scan_ratchet_check` (ratchet-down generator)
- `reference/worker-diagnostics.md` — full worker lifecycle
- GH#19118 (feature), GH#19024 (post-mortem), GH#19036, GH#19037 (root causes)
- GH#20825 (self-hosting detector, t2819), GH#20765 (post-mortem triggering t2819)

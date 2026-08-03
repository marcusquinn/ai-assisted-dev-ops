# Auto-Merge Reference

Full detail for the two pulse auto-merge gates. For the one-line summary, see `AGENTS.md` "Auto-Dispatch and Completion".

## Superseded DIRTY PR Pre-Check

Before spending time repairing conflicts on an old DIRTY PR, run the supersession helper:

```bash
.agents/scripts/pr-supersession-helper.sh classify --repo OWNER/REPO --pr N --repo-path /path/to/repo
```

Decision tree:

| Classification | Meaning | Action |
|----------------|---------|--------|
| `fully_superseded` | The branch has no meaningful diff against current base, and base contains the PR deliverable terms. | Close as superseded after human confirmation. |
| `stale_baseline_only` | The current diff no longer overlaps the PR's original changed files, while base contains the deliverable. | Prefer close-with-rationale over conflict repair. |
| `partially_superseded` | Base contains some deliverable signals, but relevant branch work remains. | Review the remaining diff before deciding. |
| `still_needed` | Base does not contain the deliverable, or the current diff still carries it. | Continue normal rebase/conflict repair. |
| `unknown` | Metadata or git comparison was unavailable. | Fall back to normal DIRTY PR handling. |

`pulse-dirty-pr-sweep.sh` calls this helper before its normal conflict-resolution classifier. Superseded candidates are notified with a human-readable rationale; the helper itself is advisory and never closes a PR.

## t2411 / GH#23238 — `origin:interactive` Merge Throughput

`origin:interactive` is provenance only: it records that a user-facing session created the PR. It is **not** a workflow instruction and does not, by itself, authorize pulse/workers to throughput the PR to merge.

Interactive PRs default to human-controlled merge. `pulse-merge.sh` only merges an `origin:interactive` PR from an `OWNER`/`MEMBER` author once ALL criteria hold:

1. PR carries the `origin:interactive` label.
2. PR author has `admin` or `maintain` permission on the repo (OWNER or org MEMBER — write-only COLLABORATORs go through the normal review gate instead).
3. All required status checks PASS or SKIPPED.
4. No `CHANGES_REQUESTED` review from a human reviewer.
5. PR is **not a draft** — `/pr-loop` or an explicit finalise/ready request may convert it with `gh pr ready <PR>`.
6. PR does **not** carry the `hold-for-review` label.
7. Merge throughput is explicitly opted in by one of:
   - PR label: `allow-auto-merge` (specific PR)
   - Env: `AIDEVOPS_INTERACTIVE_PR_AUTO_MERGE=1` (current process)
   - Global config: `orchestration.interactive_pr_auto_merge: true`
   - Per-repo `~/.config/aidevops/repos.json`: `"interactive_pr_auto_merge": true`

Preference precedence: `hold-for-review` and draft state block first; `allow-auto-merge` is the PR-specific opt-in; an explicit env value overrides repo/global preferences; per-repo `repos.json` overrides global config; global default is `false`.

Merge typically happens within one pulse cycle (4-10 minutes) after all checks go green and the PR is ready/non-draft. Installed review add-ons may respond during that window, but their timing is provider-dependent. Audit log line: `[pulse-merge] auto-merged origin:interactive PR #N (author=<login>, role=<role>)`.

**To keep manual control:** leave the PR as draft, apply `hold-for-review`, or keep `interactive_pr_auto_merge` disabled.

**Folding bot nits into the same PR — options:**
- `review-bot-gate-helper.sh check <PR>` before pushing — streams current bot feedback.
- `gh pr create --draft`, wait for reviews to settle, then run `/pr-loop` or `gh pr ready <PR>` when content is final.
- Accept the window and file a follow-up PR for nits.

**Note:** "pulse never auto-closes `origin:interactive` PRs" applies to AUTO-CLOSE (abandoning stale incremental PRs on the same task ID), NOT to auto-merge of green PRs. These are separate pulse actions.

### Interactive Admin Merge Authority

Interactive sessions operate with the repo admin/owner account. When the trust source is maintainer-controlled — `OWNER`/`MEMBER` PR author, maintainer-authored linked issue, trusted issue author, or valid cryptographic maintainer approval — the admin account may merge through the guarded full-loop helper after verifying:

1. Non-gate CI is green or skipped.
2. No human `CHANGES_REQUESTED` review exists.
3. The blocking condition is review-required branch protection, stale GitHub merge state, or a self-blocking framework gate.

This is bypassing stale/redundant automation state, not bypassing maintainer policy. Keep the merge gated when the issue/PR originates from a non-maintainer and there is no valid cryptographic approval. For external/fork PRs, issue approval is development authority only: final merge requires a V2 PR approval bound to the exact current head and content snapshot.

`full-loop-helper.sh merge --auto` applies the same rule for interactive sessions: if native auto-merge is already blocked only by review-required branch policy or GitHub self-approval rules, the helper verifies the PR is non-draft, has no `CHANGES_REQUESTED`, has no pending/failing checks, and has no linked issue still carrying `needs-maintainer-review`; then it falls through to `--admin` automatically. Headless workers do not take this fallback.

### Interactive PR-Drain Mode

Use `pr-drain-helper.sh <owner/repo>` when the goal is maintainer-directed backlog clearing rather than broad baseline cleanup. The helper is read-only by default: it lists open PRs, checks same-repo/non-draft metadata, asks `review-bot-gate-helper.sh status-json` for a machine-readable bot-gate result, inspects merge/conflict state, separates configured baseline-red checks from PR-specific failures, and prints the next command for each PR.

Recommended loop:

1. `pr-drain-helper.sh <owner/repo>` — rank PRs as `mergeable`, `conflict-only`, `superseded/stale`, or `blocked`.
2. For `conflict-only`, create the printed worktree, run `gh pr checkout`, resolve only concrete conflicts, then push.
3. Re-run `review-bot-gate-helper.sh check <PR> <owner/repo>` and inspect the scoped diff before merging.
4. Use admin squash merge only when the safety checklist below is true.

Admin-merge safety checklist for PR drains:

- PR is same-repo and non-draft.
- Review-bot result is `PASS`, `PASS_ADVISORY`, `PASS_RATE_LIMITED`, or `SKIP`; `WAITING` occurs only under explicit strict/wait policy or the external-contributor trust boundary.
- No human `CHANGES_REQUESTED` review exists.
- Any failing check is known baseline/unrelated and matched by `PR_DRAIN_BASELINE_CHECK_REGEX`; unknown failures block.
- The scoped diff matches the linked issue/task and conflict fixes do not broaden scope.

The drain helper must not declare a failing PR safe solely because checks are red. A baseline-red classification requires an explicit baseline check-name regex supplied by the maintainer for that drain session.

## t2449 — `origin:worker` (Worker-Briefed) Auto-Merge

`pulse-merge.sh` also auto-merges `origin:worker` PRs when the underlying issue was **maintainer-briefed** (filed by `OWNER`/`MEMBER`) OR authored by a **trusted peer runner** in the allowlist (t3062) OR **cryptographically approved** by a maintainer (`sudo aidevops approve issue N`). Trust chain is equivalent to interactive: maintainer brief (or explicit vouching) + worker implementation + CI verification + no human objection.

ALL criteria must hold:

1. PR carries the `origin:worker` label.
2. Linked issue (via `Resolves #NNN` / `Closes #NNN` / `Fixes #NNN`) was authored by a user with `OWNER` or `MEMBER` association — **OR** the issue author's GitHub login is listed in `.agents/configs/trusted-issue-authors.conf` (t3062: peer runners trusted as operators, not external contributors) — **OR** the linked issue has a cryptographic approval signature (`aidevops:approval-signature:` in a comment body), proving a maintainer has personally vouched for the work with their SSH key (t3052).
3. Neither the PR nor linked issue currently carries `needs-maintainer-review`. Historical NMR does not force an OWNER/MEMBER, authenticated write-authorized author, or trusted peer runner to self-approve; an external author satisfies criterion 2 only through verified cryptographic approval.
4. All required status checks PASS or SKIPPED.
5. No `CHANGES_REQUESTED` review from any reviewer with non-bot association.
6. PR is **not a draft**.
7. PR does **not** carry the `hold-for-review` label.
8. PR passes `review-bot-gate`; under the default this may be `PASS_ADVISORY`, while explicit `completion_behavior: strict` requires bots to settle beyond `min_edit_lag_seconds`.
9. PR does **not** carry `origin:worker-takeover` (takeover PRs follow normal review flow).

Feature flag: `AIDEVOPS_WORKER_BRIEFED_AUTO_MERGE` (default `1`=on). Set to `0` to fall back to manual-merge-only for `origin:worker` PRs.

Audit log: `[pulse-merge] auto-merged origin:worker (worker-briefed) PR #N (author=<login>, linked_issue=#M)`.

Test coverage: `.agents/scripts/tests/test-pulse-merge-worker-briefed.sh` (15 cases: a–o).

### Trusted-Issue-Author Allowlist (t3062, Criterion 2 extension)

The allowlist allows peer runners (separate machine/account, `COLLABORATOR` association) to file issues that workers can then auto-merge without per-issue crypto ceremony.

**Config file:** `.agents/configs/trusted-issue-authors.conf` — one GitHub login per line; `#` comments and blank lines ignored. Deployed copy: `~/.aidevops/agents/configs/trusted-issue-authors.conf`. Override path: `AIDEVOPS_TRUSTED_AUTHORS_CONF` env var.

**What the allowlist bypasses:** the `OWNER`/`MEMBER` `author_association` check only. Everything else still applies: the live NMR gate, feature flag, draft/hold-for-review/CHANGES_REQUESTED gates, and CI checks.

**What it does NOT bypass:** A live `needs-maintainer-review` label still blocks. Trusted-author legacy NMR is normalized without fabricating approval; external-author NMR requires verified cryptographic approval and label clearance.

**Security posture:** Allowlist entries are local-trust grants from the maintainer of the runner machine. They cannot bypass CI, a live NMR gate, or PR-specific external merge authority; they only relax the GitHub author-association proxy.

### Security Gate: External-Author NMR Authority

`auto_approve_maintainer_issues` uses live issue-author authority as the invariant. A verified write-authorized author never self-approves: unreasoned residue is removed, explicit durable human-decision or security evidence becomes `hold-for-review`, and machine-breaker evidence becomes `status:blocked`, without posting an approval marker. A live security label takes precedence over temporary or breaker recovery. Label actor, elapsed time, and missing automation provenance cannot manufacture human intent; incomplete timeline, comment, or current-label evidence leaves NMR unchanged for retry.

An external or unverifiable author remains gated. Cryptographic approval (`sudo aidevops approve issue N`) requires the maintainer's root-protected SSH key, which workers cannot access, and is the only authority signal that clears that external boundary. It does not resolve an independent live security label, which becomes `hold-for-review` when NMR clears.

### Author-Association Gate Crypto Bypass (t3063)

Symmetric extension of t3052 to the **deterministic merge cascade** — the `_check_pr_merge_gates` collaborator check and the `approve_collaborator_pr` function in `pulse-merge-gates.sh`.

**Background:** t3052 (PR #21767) allowed cryptographic maintainer approval on a linked issue to satisfy the `OWNER`/`MEMBER` author-association gate in the worker-briefed auto-merge path. t3063 extends the same signal to:

1. **`_check_pr_merge_gates`** — the gate that short-circuits the merge pass for non-collaborator PRs. It requires current V2 PR authority before allowing the author-association bypass.
2. **`approve_collaborator_pr`** — the function that posts the approval review before merge. Its GH#17671 self-check accepts only current V2 PR authority for a non-collaborator author.

**Trust chain:** `sudo aidevops approve` requires a root-owned SSH private key that workers cannot forge. The signal is stronger than GitHub author-association, which is a proxy for maintainer trust. The four-layer GH#17671 defence-in-depth is preserved — Case P (CONTRIBUTOR + no crypto = refuse) is pinned by `test-pulse-merge-approve-collaborator-guard.sh`.

**Helper:** `_has_maintainer_crypto_approval "$pr_number" "$repo_slug" "$head_sha"` in `pulse-merge-gates.sh`. It fails closed unless `approval-helper.sh` verifies a V2 PR payload whose canonical digest and head match current GitHub state. Marker-only and helper-absent fallbacks are prohibited.

**Test coverage:** `.agents/scripts/tests/test-pulse-merge-approve-collaborator-guard.sh` cases N, O, P.

### V2 immutable approval snapshots

`sudo aidevops approve issue|pr N OWNER/REPO` signs `aidevops-approval/v2`, which contains a SHA-256 digest of a canonical read-only GitHub snapshot. The snapshot binds object IDs, title/body, non-bot human comments and reviews, linked-reference timeline events, and—for PRs—the head SHA/ref/repository and base ref/repository. Verification excludes the exact signed comment being checked and the trusted deterministic NMR lifecycle audit written after verification. Marker text in any other external human comment remains content-bound, so copied unsigned markers cannot hide drift. A repeated approval binds prior approval comments and leaves only the newest matching snapshot authoritative.

- Issue V2 authority permits development of that exact issue snapshot. It never authorizes a future or changed external PR.
- External/fork merge requires both the existing approved linked-issue chain and PR-specific V2 merge authority for the exact current head. The final trust gate re-fetches this immediately before every native, admin, direct, and retry merge call; it also checks live author permission so missing external labels cannot bypass the rule.
- Body/comment/link/linked-reference/base/head drift returns `STALE_APPROVAL`; malformed payloads, API uncertainty, and missing keys fail closed.
- V1 `APPROVE:<kind>:<repo>:<number>:<timestamp>` signatures return `LEGACY_APPROVAL`. They are preserved as audit history but do not authorize external dispatch/merge; run the approval command again after reviewing current state.
- A live `needs-maintainer-review` label on the PR or linked issue always blocks. Marker presence does not override current NMR state.

Configured review-provider failures use `review_gate.advisory_check_contexts`. An exact named non-required failure is advisory only after the final trust gate reruns the read-only review helper and obtains typed `aidevops.review-gate-evidence/v1` for the exact PR head, a permitted author-class outcome, and resolved review threads. Duplicate maintainer-gate aliases are one audited family and remain blocking; all other check-run and commit-status sources retain independent failure identity.

## NMR Authority Normalization and Legacy Signatures

Current producers reserve `needs-maintainer-review` for external-author authority. Internal decisions use `hold-for-review`; machine-recoverable dependency, cost, stale-worker, and infrastructure failures use `status:blocked`, cooldowns, or root-cause meta-issues.

`pulse-nmr-approval.sh` still recognizes historical scanner, breaker, and explicit reason signatures so pre-migration issues fail safely while being normalized. For a write-authorized author, it clears unreasoned/default residue while preserving active `status:*`, translates explicit durable human-decision evidence to `hold-for-review`, and converts unresolved machine-breaker evidence to `status:blocked`; required status convergence is verified before NMR is removed. It never manufactures cryptographic approval. Security-labelled creation requests become explicit holds even alongside independent blockers. Incomplete evidence defers mutation, while external or unverifiable authors retain NMR until valid cryptographic approval resolves only that authority boundary.

Historical breaker signatures remain recognized to prevent the GH#19756 loop while old issues are reconciled. New breaker paths never use NMR, so clearing an author-authority gate cannot blind-redispatch an unresolved machine failure.

Compatibility helpers `_nmr_application_has_automation_signature` and `_nmr_application_is_circuit_breaker_trip` classify legacy events. New producer regressions must instead prove internal holds avoid NMR and preserve any independent live external gate.

## t3068 — Approval-Triggered Pulse Kick

**Problem:** before t3068, `sudo aidevops approve issue|pr <N>` posted a verified signature comment but the pulse-merge cycle was up to ~120s away. The maintainer had no feedback that the approval had landed in the merge queue, and ~2 min × N stuck PRs added up across an interactive cleanup session.

**Fix:** every successful `_approve_target` call now triggers the pulse via two independent layers in `approval-helper.sh::_kick_pulse_after_approval`:

1. **Marker file** at `~/.aidevops/cache/pulse-merge-trigger.txt` — append a tab-separated record `<slug>\t<num>\t<type>\t<iso8601_ts>`. Crash-safe and idempotent: even if the pulse process is dead, the marker survives until the next cycle drains it.
2. **Background spawn** of `pulse-wrapper.sh --merge-only` — best-effort, nohup + disown. Sub-second latency in the common case (60s `--merge-only` plist NOT already running).

**Drain side** — `pulse-wrapper-bootstrap.sh::_drain_merge_trigger_file_if_present`:

- Atomically rotates the marker (mv to `.processing.$$`) before parsing — no double-processing on concurrent drains.
- For each record: validates slug/num/type, resolves issue records to the linked open PR via `_resolve_linked_pr_for_issue`, and dispatches to the existing `process_pr "$slug" "$pr_num"` from pulse-merge.sh (same path as the t3038 webhook receiver).
- Malformed records logged and skipped — never aborts the drain.
- Wired in TWO places: at the top of every regular pulse cycle (`pulse-wrapper.sh::main()` before `_run_preflight_stages`) AND at the top of `_pulse_run_merge_only` for the dedicated 60s merge-only plist.

**Latency profile:**

| Approval scenario | Old latency (pre-t3068) | New latency (post-t3068) |
|-------------------|--------------------------|---------------------------|
| Approve, pulse idle | up to 120s | < 5s (background spawn fires) |
| Approve, --merge-only mid-cycle | up to 120s | up to 60s (marker drains on next merge-only tick) |
| Approve, full cycle running | up to 120s | up to 60s (next merge-only tick) |
| Approve, pulse dead | next pulse boot | next pulse boot (marker survives, drained on first cycle) |

**Bypass:**

- `AIDEVOPS_SKIP_APPROVE_KICK_PULSE=1` — disable both layers (used in CI / hermetic tests).
- `AIDEVOPS_SKIP_TRIGGER_DRAIN=1` — disable the drain (test-only knob to verify no-spawn path).

**Test coverage:** `.agents/scripts/tests/test-approve-kicks-pulse.sh` (21 assertions across 7 cases — marker shape, drain happy path, malformed-record skip, missing-marker no-op, bypass flag, atomic rotation, issue→PR resolution).

**Audit log:** every drain emits `[ts] _drain_merge_trigger_file_if_present: process_pr <slug> #<pr> (from approve <type> #<num>)` and a summary `drained N record(s), M non-merge outcomes`.

## t3070 — Native Auto-Merge Fast-Track

**Trigger:** every PR that reaches the merge call site in `_process_single_ready_pr` after passing all gates (review, maintainer, scope, review-bot-gate, complexity, admin safety check).

**What it does:** instead of unconditionally calling `gh pr merge --squash --admin` against pending CI, the pulse asks GitHub to merge the PR as soon as the last required check turns green via `gh pr merge --auto --squash`. GitHub then schedules the merge server-side and fires it within seconds of CI green — no further pulse-cycle wait required.

**Decision tree** (`_set_native_auto_merge_or_skip` in `pulse-merge-process.sh`):

| Condition | Action | Caller behaviour |
|-----------|--------|------------------|
| PR already has `autoMergeRequest` set | No-op | Caller returns success — GitHub finishes the merge |
| Repo `allow_auto_merge=false` | Fall through | Caller invokes `gh pr merge --squash --admin` |
| All required checks already done (no `pending` bucket) | Fall through | Caller invokes `gh pr merge --squash --admin` (immediate is faster than round-tripping through GitHub's auto-merge engine) |
| At least one required check pending | `gh pr merge --auto --squash` | Caller returns success — GitHub merges on green |
| `gh pr merge --auto` exits non-zero | Fall through with audit log | Caller invokes `gh pr merge --squash --admin` |

**Repo prerequisite:** `allow_auto_merge=true` on the repo. Bulk-enable across all owned repos:

```bash
jq -r '.initialized_repos[] | select(.local_only != true) | .slug' \
    ~/.config/aidevops/repos.json | while read -r slug; do
  gh api -X PATCH "repos/${slug}" -f allow_auto_merge=true >/dev/null \
    && printf 'enabled %s\n' "$slug"
done
```

**Latency improvement:** baseline measurement on owner/peer green PR push→merged was 3-22 min — dominated by the 120s polling cycle plus per-cycle gate evaluation. With native auto-merge, GitHub fires the merge within ~5-30s of the last required check finishing, regardless of when the next pulse cycle would have polled.

**Trade-offs:**

- **No `--admin` bypass on the auto-scheduled merge.** Native auto-merge respects branch protection. If the repo has required checks that ultimately fail, GitHub will hold the PR indefinitely instead of merging — exactly the safety property branch protection exists to provide. The pulse still falls back to `--admin` for repos that opted out (`allow_auto_merge=false`), preserving the historical bypass-pending behaviour for those repos.
- **No `_handle_post_merge_actions` invocation on the native-auto path.** The "Merged via PR #N" comment with `merge_summary` is NOT posted on the linked issue when GitHub completes the merge later. GitHub's `Resolves #NNN` keyword still auto-closes the issue — only the structured closing comment is lost. Acceptable for the speedup; users who need the comment can apply `hold-for-review` to opt out.

**Audit log:** `[pulse-merge] PR #N in slug: native auto-merge set (CI K pending), GitHub merges on green (t3070)`.

**Caching:** `_repo_allows_auto_merge` caches the per-repo `allow_auto_merge` flag in a tempdir keyed on PID for the lifetime of the pulse cycle. Avoids repeated `gh api repos/<slug>` calls when iterating multiple PRs from the same repo.

**Test coverage:** `.agents/scripts/tests/test-pulse-merge-native-auto.sh` (4 cases — pending/green/already-set/repo-disallows).

**Bypass:** apply `hold-for-review` to opt out of all auto-merge paths (this gate is upstream of t3070 — a held PR never reaches the native-auto call site). For per-repo opt-out, set `allow_auto_merge=false` via `gh api -X PATCH repos/<slug> -f allow_auto_merge=false`.

## t3192 — Stuck Auto-Merge Fallback

**Problem:** GitHub's `mergeable_state` recomputation is asynchronous and lazy. Setting `auto_merge: true` does not trigger an immediate recompute, and once `BLOCKED` is cached on a PR the state can stick for hours after the original cause (pending CI, missing approval) has cleared. The t3070 fast path returns 0 unconditionally when `autoMergeRequest` is set, so pulse cycles see "auto_merge already requested, deferring to GitHub" and the PR sits indefinitely.

Observed 2026-04-30 in marcusquinn/aidevops:

| PR | auto_merge enabled | checks | mergeable | mergeStateStatus | stuck for |
|----|-------------------|--------|-----------|------------------|-----------|
| #21883 | 05:37Z | 71/71 (46 SUCCESS, 25 SKIPPED) | MERGEABLE | BLOCKED | 9h |
| #21885 | 05:49Z | 48/48 (44 SUCCESS, 4 SKIPPED) | MERGEABLE | BLOCKED | 8h |

`gh pr merge --admin --squash` succeeded immediately on each. The same wedge had been observed on 8 separate PRs the day before. t3192 closes the gap.

**What it does:** `_set_native_auto_merge_or_skip` now consults `_auto_merge_stuck_seconds` before deferring. When all of the following hold the helper returns 1, the caller falls through to the existing `--admin` immediate-merge path, and the PR clears within one pulse cycle of crossing the threshold:

- `mergeStateStatus == "BLOCKED"`
- `mergeable == "MERGEABLE"`
- `reviewDecision != "CHANGES_REQUESTED"` (don't bypass real human review blocks)
- `autoMergeRequest.enabledAt > $threshold` seconds ago (default 300s)
- Every required check is in the `pass` or `skipping` bucket (no `pending`, `fail`, or `cancel`)

When any condition fails the helper returns non-zero with no output and the t3070 deferring path runs unchanged.

**Threshold override:** `AIDEVOPS_PULSE_AUTO_MERGE_STUCK_SECONDS` (integer seconds, default 300). Raise to defer longer; lower to fall through faster.

**Audit log:** stuck fallback writes `[pulse-merge] PR #N in slug: auto_merge stuck Ks (>Ts) in BLOCKED+MERGEABLE with no failing/pending required checks — falling through to immediate merge (t3192)`. The healthy defer line is unchanged: `auto_merge already set, deferring to GitHub (t3070)`. Distinguishing the two makes log-side incident triage trivial.

**Why this is safe to admin-merge:** the wedge happens on PRs the maintainer/worker has already approved (auto_merge was requested) and CI has gone fully green (no failing or pending required check). The only thing GitHub is waiting on is its own stale cached state. `--admin` here is bypass-stale-state, not bypass-policy. The CHANGES_REQUESTED guard prevents the helper from firing on PRs with a real review-driven block, even if everything else looks stuck.

**Test coverage:** `.agents/scripts/tests/test-pulse-merge-stuck-auto.sh` (5 cases — stuck/under-threshold/pending-CI/changes-requested/env-override). The existing `test-pulse-merge-native-auto.sh` was extended to fixture full PR state (autoMergeRequest, mergeStateStatus, mergeable, reviewDecision) so the t3070 branches still pass after the multi-field query was added.

## Webhook-Driven Auto-Merge (t3038)

The 120s `pulse-merge-routine.sh` polling loop is the **backstop**. The fast path is a webhook receiver that fires `pulse-merge.sh::process_pr` within seconds of a GitHub event:

- `check_suite.completed` (conclusion=success) — CI just went green.
- `pull_request_review.submitted` (state in {APPROVED, CHANGES_REQUESTED}) — last reviewer settled.
- `pull_request.labeled` for `auto-dispatch`, `coderabbit-nits-ok`, `ai-approved` — gate flipped.

End-to-end latency drops from ~4-12 min (cycle wait + auto-merge gate window) to ~30s — a 4-6x speedup that translates directly into faster slot recycling for the worker pool.

**Architecture (defense-in-depth):**

| Path | Trigger | Latency | Reliability |
|------|---------|---------|-------------|
| Webhook | GitHub event | ~5-30s | Optimization — needs receiver up + tunnel up |
| Polling routine (`pulse-merge-routine.sh`) | 120s launchd interval | ≤120s + cycle | Always on, no external dependencies |
| In-cycle merge pass (`pulse-wrapper.sh`) | 5-10 min pulse cycle | Slow, kept as final defense | Always on |

If the webhook receiver crashes or the tunnel breaks, eligible PRs still merge on the next 120s polling cycle. There is no single point of failure that can wedge the merge pipeline.

### Setup

1. **Generate the webhook secret** (≥32 random bytes, hex):

   ```bash
   openssl rand -hex 32 | aidevops secret set GITHUB_WEBHOOK_SECRET
   # Or if not using gopass:
   #   echo "export GITHUB_WEBHOOK_SECRET='<hex-secret>'" >> ~/.config/aidevops/credentials.sh
   #   chmod 600 ~/.config/aidevops/credentials.sh
   ```

2. **Validate config + secret** before starting:

   ```bash
   pulse-merge-webhook-receiver.sh --check
   ```

3. **Expose the receiver via Cloudflare Tunnel** (canonical exposure path; the receiver binds to `127.0.0.1:9301` only and never speaks plaintext HTTP to the public internet):

   ```bash
   cloudflared tunnel create aidevops-webhook
   # Edit ~/.cloudflared/config.yml:
   #   tunnel: <tunnel-id>
   #   credentials-file: ~/.cloudflared/<tunnel-id>.json
   #   ingress:
   #     - hostname: hooks.example.com
   #       service: http://127.0.0.1:9301
   #     - service: http_status:404
   cloudflared tunnel route dns aidevops-webhook hooks.example.com
   cloudflared tunnel run aidevops-webhook
   ```

4. **Install the launchd service** (macOS — for Linux, install as a systemd user service following the same ProgramArguments):

   ```bash
   sed -e "s|{{HOME}}|$HOME|g" \
       -e "s|{{BASH_BIN}}|$(command -v bash)|g" \
       -e "s|{{AIDEVOPS_AGENTS_SCRIPTS}}|$HOME/.aidevops/agents/scripts|g" \
       ~/.aidevops/agents/templates/launchd/sh.aidevops.merge-webhook-receiver.plist.tmpl \
     > ~/Library/LaunchAgents/sh.aidevops.merge-webhook-receiver.plist
   launchctl load ~/Library/LaunchAgents/sh.aidevops.merge-webhook-receiver.plist
   ```

5. **Configure each repo webhook** (Settings → Webhooks → Add webhook):
   - Payload URL: `https://hooks.example.com/webhook`
   - Content type: `application/json`
   - Secret: the same hex value stored in `GITHUB_WEBHOOK_SECRET`
   - Events: tick **Check suites**, **Pull request reviews**, **Pull requests** (or **Send me everything** — non-handled events return `204 No Content`).

### Configuration

`.agents/configs/webhook-receiver.conf` controls listen address, max body size, handled-event allowlist, and log path. The secret itself is **never** in the conf file — only the env var name (`WEBHOOK_SECRET_ENV`).

### Verification

- `pulse-merge-webhook-receiver.sh --check` — validates secret + python3 availability without starting the listener.
- `curl -X POST -H 'X-Hub-Signature-256: sha256=bad' http://127.0.0.1:9301/webhook -d '{}'` — must return 401 (HMAC rejection).
- `curl http://127.0.0.1:9301/health` — must return 200 OK.
- Send a synthesized `check_suite.completed` payload for a known-mergeable PR with a valid signature → `pulse-merge-webhook.log` shows `accepted check_suite → owner/repo#NNN` and `pulse.log` shows `[pulse-merge] process_pr: webhook-triggered merge attempt …`.
- Stop the receiver (`launchctl unload …`) and confirm the next 120s `pulse-merge-routine.sh` cycle still merges eligible PRs — that proves the backstop is live.

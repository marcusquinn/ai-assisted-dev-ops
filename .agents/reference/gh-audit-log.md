# GH Audit Log

Structured local audit log for every destructive GitHub operation the framework performs. Implemented as `gh-audit-log-helper.sh` (core logging) and `gh-audit-anomaly-helper.sh` (periodic scanner). Introduced in GH#20145, motivated by the GH#19847 / t2377 data-loss incident.

## Overview

Every call to `gh_issue_edit_safe`, `gh_issue_close_safe`, `gh_issue_reopen_safe`, `gh_pr_edit_safe`, `gh_pr_close_safe`, and `gh_pr_merge_safe` writes one NDJSON event to `~/.aidevops/logs/gh-audit.log`. A daily routine (`r-gh-audit-scan`) scans the log for anomalies and files a GitHub issue when any are detected.

## Schema Reference

Each log line is a compact JSON object (NDJSON):

```json
{
  "ts": "2026-04-19T03:45:12Z",
  "op": "issue_edit",
  "repo": "owner/repo",
  "number": 19780,
  "caller_script": "issue-sync-helper.sh",
  "caller_function": "_enrich_update_issue",
  "caller_line": 945,
  "pid": 12345,
  "flags": {"FORCE_ENRICH": "true"},
  "before": {"capture_status": "ok", "title_len": 87, "body_len": 4678, "labels": ["status:in-review", "origin:interactive"]},
  "after":  {"capture_status": "ok", "title_len": 7,  "body_len": 0,    "labels": ["auto-dispatch", "tier:thinking"]},
  "delta": {
    "comparable": true,
    "title_delta_pct": -92,
    "body_delta_pct": -100,
    "labels_removed": ["status:in-review", "origin:interactive"],
    "labels_added": ["auto-dispatch", "tier:thinking"]
  },
  "suspicious": ["title_delta_pct<-50", "body_delta_pct=-100", "protected_label_removed:status:in-review"]
}
```

### Field definitions

| Field | Type | Description |
|-------|------|-------------|
| `ts` | string | ISO 8601 UTC timestamp of the operation |
| `op` | string | Operation type (see below) |
| `repo` | string | `owner/repo` slug |
| `number` | integer | Issue or PR number |
| `caller_script` | string | `BASH_SOURCE` of the code that called the safe wrapper |
| `caller_function` | string | `FUNCNAME` of the calling function |
| `caller_line` | integer | `BASH_LINENO` of the call site |
| `pid` | integer | Process ID of the caller |
| `flags` | object | Relevant env vars active at call time (e.g. `FORCE_ENRICH`) |
| `before` | object | Issue/PR state immediately before the operation, or an explicit unavailable snapshot |
| `after` | object | Issue/PR state immediately after the operation, or an explicit unavailable snapshot |
| `delta` | object | Computed change metrics; values are null when snapshots are not comparable |
| `suspicious` | array | Anomaly signal strings (empty = normal operation) |

### Operation types (`op`)

| Value | Trigger |
|-------|---------|
| `issue_edit` | `gh_issue_edit_safe` called |
| `issue_close` | `gh_issue_close_safe` called |
| `issue_reopen` | `gh_issue_reopen_safe` called |
| `pr_edit` | `gh_pr_edit_safe` called |
| `pr_close` | `gh_pr_close_safe` called |
| `pr_merge` | `gh_pr_merge_safe` called |

### Before/After state object

```json
{
  "capture_status": "ok",
  "title_len": 87,
  "body_len": 4678,
  "labels": ["status:in-review", "origin:interactive"]
}
```

- `capture_status`: `ok` when the GitHub read succeeded; `unavailable` when it failed
- `title_len`: Character length of the title, or `null` when capture is unavailable
- `body_len`: Character length of the body, or `null` when capture is unavailable
- `labels`: Array of label names at that point in time, or `null` when capture is unavailable

Legacy entries without `capture_status` retain their original schema. New entries
never encode a failed read as zero-length content or an empty label list.

### Delta object

```json
{
  "comparable": true,
  "title_delta_pct": -92,
  "body_delta_pct": -100,
  "labels_removed": ["status:in-review"],
  "labels_added": ["auto-dispatch"]
}
```

- `comparable`: `true` only when both snapshots were captured successfully
- `title_delta_pct`: `(after - before) * 100 / before` (-100 = fully wiped, 0 = no change), or `null`
- `body_delta_pct`: Same formula for body, or `null`
- `labels_removed`: Labels present in before but not after, or `null`
- `labels_added`: Labels present in after but not before, or `null`

## Anomaly Taxonomy

The `suspicious[]` array is populated when any of these signals fires:

### `state_capture_unavailable:<phase>`

**Meaning:** The `before` or `after` GitHub state read failed, so no destructive
delta can be inferred for that operation.

**Normal causes:** Transient network, authentication, or API availability errors.

**Abnormal causes:** Persistent loss of audit visibility or a broken state-read path.

**Investigation:** Verify the current GitHub state and inspect nearby audit entries.
Do not treat null snapshot fields as proof that content or labels were removed.

---

### `title_delta_pct<-50`

**Meaning:** The issue/PR title shrank by more than 50%.

**Normal causes:** Legitimate title simplifications (rare for >50%).

**Abnormal causes:** Enrich logic replacing a long descriptive title with a short stub; truncation bug; empty-title guard bypassed.

**Investigation:** Check the `before.title_len` vs `after.title_len`. If before was e.g. 87 chars and after is 7, the title was likely wiped to a stub. Cross-reference with the GitHub Events API (see Forensics Workflow below).

---

### `body_delta_pct=-100`

**Meaning:** The issue/PR body was completely emptied.

**Normal causes:** None — a body going from non-zero to zero is always suspect.

**Abnormal causes:** The t2377 bug pattern: enrich logic passing an empty string as `--body` to `gh issue edit`. The `gh_issue_edit_safe` body-empty guard blocks this now, but the audit log records it if the guard fires or if `gh` is called directly.

**Investigation:** Check `before.body_len`. If it was >0 and after is 0, the body was wiped. File a P1 investigation.

---

### `protected_label_removed:<label>`

**Meaning:** A label considered sensitive or safety-critical was removed.

**Protected labels:**
- `status:in-review` — active claim in progress
- `status:in-progress` — worker actively running
- `status:claimed` — dispatched but not yet started
- `origin:interactive` — human session ownership
- `no-auto-dispatch` — explicit opt-out of pulse dispatch
- `needs-maintainer-review` — human review gate in place

**Normal causes:** Intentional state transitions (e.g., `status:in-review` → `status:done` on PR merge).

**Abnormal causes:** Enrich logic incorrectly stripping labels; cleanup sweep running on an issue that should be protected; worker modifying an issue it doesn't own.

**Investigation:** Compare `before.labels` vs `after.labels`. Check `caller_script` and `caller_function` to identify the code path. Was this a legitimate state transition?

## Forensics Workflow

Use this workflow when a user reports "my issue was wiped" or when the anomaly scanner files an alert.

### Step 1: Check the audit log

```bash
# Show recent entries for a specific issue
grep '"number":NNN' ~/.aidevops/logs/gh-audit.log | jq '.'

# Show all anomalous entries
jq 'select(.suspicious | length > 0)' ~/.aidevops/logs/gh-audit.log

# Show recent operations on a specific repo
jq 'select(.repo == "owner/repo")' ~/.aidevops/logs/gh-audit.log | tail -20
```

### Step 2: Cross-reference GitHub Events API

The GitHub Events API records rename and label events independently:

```bash
# Show title changes (rename events)
gh api /repos/OWNER/REPO/issues/NNN/events \
  --jq '[.[] | select(.event == "renamed") | {ts: .created_at, from: .rename.from, to: .rename.to}]'

# Show label events (label added/removed)
gh api /repos/OWNER/REPO/issues/NNN/events \
  --jq '[.[] | select(.event | startswith("label")) | {ts: .created_at, event: .event, label: .label.name}]'
```

### Step 3: Restore from before-state

If the audit log captured the before-state before the wipe, use its lengths to
validate candidate recovery sources:

```bash
# Extract the before-state from the audit log
ENTRY=$(grep '"number":NNN' ~/.aidevops/logs/gh-audit.log | tail -1)
echo "$ENTRY" | jq '.before'

# Restore title (if available)
OLD_TITLE=$(echo "$ENTRY" | jq -r '.before.title_len')
echo "Before title length: $OLD_TITLE"
# Note: the audit log stores lengths, not content. Content must come from
# the GitHub Events API or a git-committed backup.
```

> **Important:** The audit log stores **lengths**, not the full title/body text. For content recovery, use the GitHub Events API or git history on any committed snapshots.

### Step 4: Identify the root cause

Check `caller_script`, `caller_function`, and `caller_line` to find the code path. Then:

1. Read the cited function to understand the logic
2. Check if `FORCE_ENRICH` or similar flags in `flags` explain the unexpected change
3. File a bug report if the root cause is a framework defect

## Retention and Rotation Policy

- **Log file:** `~/.aidevops/logs/gh-audit.log`
- **Rotation threshold:** 10 MB (shell-based rotation at each `record` call)
- **Max rotations:** 10 (rotation files `gh-audit.YYYYMMDDTHHMMSSZ.log`)
- **Total cap:** ~100 MB (10 × 10 MB rotations)
- **Rotation file permissions:** 400 (read-only after rotation)

Rotation is triggered automatically when `record` detects the log exceeds the threshold. No external `logrotate` configuration is required.

To force rotation manually:

```bash
gh-audit-log-helper.sh rotate --max-size 10
```

To check log status:

```bash
gh-audit-log-helper.sh status
```

## Anomaly Scanner

The daily routine `r-gh-audit-scan` runs `gh-audit-anomaly-helper.sh scan`:

```text
- [x] r-gh-audit-scan Scan gh-audit.log for anomalies repeat:daily(@09:00) run:scripts/gh-audit-anomaly-helper.sh scan
```

The scanner:
1. Reads entries since the last scan (tracked in `~/.aidevops/logs/gh-audit-scanner.state`)
2. Filters entries with `suspicious[] | length > 0`, excluding only exact,
   fully comparable expected transitions: verified issue/PR approval removal of
   `needs-maintainer-review`, and worker permission blocking that replaces active
   lifecycle labels with `needs-maintainer-permissions` (the original audit entry
   remains unchanged)
3. Files a GitHub issue on `marcusquinn/aidevops` with a summary table when anomalies are found

To run the scanner manually:

```bash
# Normal run (incremental, files issue)
gh-audit-anomaly-helper.sh scan

# Scan all entries without filing an issue (dry run)
gh-audit-anomaly-helper.sh scan --all --dry-run

# Check scanner state
gh-audit-anomaly-helper.sh status
```

## Related

- `gh-audit-log-helper.sh` — core logger (`record`, `status`, `rotate`, `help`)
- `gh-audit-anomaly-helper.sh` — daily scanner (`scan`, `status`, `help`)
- `shared-gh-wrappers.sh` — safe wrappers that call the logger
- GH#19847 (t2377) — data-loss incident that motivated this feature
- GH#20145 — implementation issue

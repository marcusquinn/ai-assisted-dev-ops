---
description: Runtime behaviour patterns — state machines, polling, backoff, quiescence
mode: reference
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Runtime Behaviour Patterns

Patterns that cause silent failures, infinite loops, and race conditions at runtime. Static analysis cannot catch them.

## State Machines

### Entry-State Completeness

Handle **all** possible states, not just the happy path. Missing states cause silent no-ops or frozen UI.

**Detection keywords:** `status`, `state`, `phase`, `stage`, `step`, `mode`, `lifecycle`

```bash
# Exhaustive shell state machine with explicit default
handle_deploy_state() {
    local state="$1"
    case "$state" in
        success)   notify_success ;;
        failed)    notify_failure ;;
        pending|running) notify_pending ;;
        cancelled) notify_cancelled ;;
        timeout)   notify_timeout ;;
        *)
            echo "[handle_deploy_state] Unknown state: $state" >&2
            notify_failure "Unknown deploy state: $state"
            return 1
            ;;
    esac
    return 0
}
```

```typescript
// TypeScript: exhaustive switch with explicit default
function handlePaymentStatus(status: string) {
  switch (status) {
    case 'succeeded':  showSuccess(); break;
    case 'failed':     showError(); break;
    case 'pending':
    case 'processing': showPending(); break;
    case 'cancelled':  showCancelled(); break;
    case 'refunded':   showRefunded(); break;
    default:
      console.error(`Unhandled payment status: ${status}`);
      showError(`Unexpected status: ${status}`);
  }
}
```

### Transition Guards

Guard state transitions to prevent double-processing and duplicate charges:

```typescript
// Only allow valid transitions from current state
class OrderProcessor {
  status: 'pending' | 'charging' | 'charged' | 'failed' = 'pending';

  private readonly VALID_TRANSITIONS: Record<string, string[]> = {
    pending:  ['charging'],
    charging: ['charged', 'failed'],
    charged:  [],
    failed:   ['pending'],
  };

  async charge() {
    if (!this.VALID_TRANSITIONS[this.status]?.includes('charging')) {
      throw new Error(`Cannot charge from state: ${this.status}`);
    }
    this.status = 'charging';
    try {
      await stripe.charge(this.amount);
      this.status = 'charged';
    } catch (err) {
      this.status = 'failed';
      throw err;
    }
  }
}
```

```bash
# Shell transition guard
DEPLOY_STATE="idle"
transition_deploy_state() {
    local from_state="$1"
    local to_state="$2"
    if [[ "$DEPLOY_STATE" != "$from_state" ]]; then
        echo "[transition_deploy_state] Invalid: $DEPLOY_STATE -> $to_state (expected from: $from_state)" >&2
        return 1
    fi
    DEPLOY_STATE="$to_state"
    return 0
}
```

## Polling Patterns

### Polling Termination (Mandatory)

Every polling loop **must** have: success, timeout, terminal failure, and max-iterations termination.

```bash
# Safe polling with all four termination conditions
wait_for_deploy() {
    local deploy_id="$1"
    local max_wait="${2:-300}"
    local interval="${3:-10}"
    local elapsed=0
    local iteration=0
    local max_iterations
    if ! [[ "$interval" =~ ^[0-9]+$ ]] || [[ "$interval" -le 0 ]]; then
        echo "[wait_for_deploy] interval must be a positive integer (got: $interval)" >&2
        return 1
    fi
    max_iterations=$(( max_wait / interval ))

    while [[ "$iteration" -lt "$max_iterations" ]]; do
        local status
        status=$(get_deploy_status "$deploy_id") || return 1

        case "$status" in
            success|deployed|complete)
                return 0 ;;
            failed|error|cancelled|aborted)
                echo "[wait_for_deploy] Terminal state: $status" >&2
                return 1 ;;
        esac

        sleep "$interval"
        elapsed=$(( elapsed + interval ))
        iteration=$(( iteration + 1 ))
    done

    echo "[wait_for_deploy] Timeout after ${max_wait}s" >&2
    return 1
}
```

### Exponential Backoff

Use for long-running polls to avoid hammering APIs:

```bash
poll_with_backoff() {
    local check_fn="$1"
    local max_wait="${2:-300}"
    local interval="${3:-2}"
    local max_interval="${4:-30}"
    local elapsed=0

    while [[ "$elapsed" -lt "$max_wait" ]]; do
        if "$check_fn"; then return 0; fi
        sleep "$interval"
        elapsed=$(( elapsed + interval ))
        interval=$(( interval * 2 ))
        [[ "$interval" -gt "$max_interval" ]] && interval="$max_interval"
    done

    echo "[poll_with_backoff] Timeout after ${max_wait}s" >&2
    return 1
}
```

### Quiescence Detection

For UI polling, wait until the system has been **stable for a minimum duration**, not just until a single check passes:

```typescript
async function waitForQuiescence(
  page: Page,
  options: { stableMs?: number; timeoutMs?: number } = {}
): Promise<void> {
  const { stableMs = 500, timeoutMs = 10_000 } = options;
  const deadline = Date.now() + timeoutMs;
  let stableSince: number | null = null;

  while (Date.now() < deadline) {
    const isStable = await page.evaluate(() => {
      const hasPendingRequests = (window as any).__pendingRequests > 0;
      const hasSpinners = document.querySelectorAll('[data-loading], .spinner, [aria-busy="true"]').length > 0;
      return !hasPendingRequests && !hasSpinners;
    });

    if (isStable) {
      stableSince ??= Date.now();
      if (Date.now() - stableSince >= stableMs) return;
    } else {
      stableSince = null;
    }
    await new Promise(resolve => setTimeout(resolve, 100));
  }
  throw new Error(`Page did not reach quiescence within ${timeoutMs}ms`);
}
```

## Runtime Evidence Signals

These patterns require production-like runtime evidence because static analysis
cannot verify them. Exercise an existing app, staging, sandbox, or integration
path; do not create a harness unless separately justified and approved.

| Pattern | Risk | Required runtime evidence |
|---------|------|-----------------|
| `switch`/`case` on status/state | Missing entry states | Trigger each state |
| `while true` / unbounded loops | Infinite loop | Verify termination |
| `setTimeout`/`setInterval` | Timer leak | Verify cleanup |
| Payment/checkout flows | Duplicate charge | Full payment flow |
| Auth token refresh | Race condition | Concurrent requests |
| Webhook handlers | Missing event types | Send each event type |
| Database migrations | Irreversible | Exercise on staging first |

**Prevention rule:** Before implementing any of these patterns, enumerate the complete state space — every possible state, event, and status value including errors. Implement handlers for all of them before writing the happy path.

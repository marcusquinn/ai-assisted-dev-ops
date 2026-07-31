// ---------------------------------------------------------------------------
// greeting.mjs — session-start framework status as TUI toasts (t2724)
//
// Routes the output of `aidevops-update-check.sh --interactive` through
// OpenCode's `client.tui.showToast()` so the session banner renders as
// ephemeral toasts instead of (or alongside) a message-context block.
//
// Phase 1: additive — the model still renders the greeting as the first
// message. Phase 2 (separate commit) trims the redundant text from
// generate-opencode-agents.sh once we've visually confirmed the toast.
//
// Trigger semantics (fail-open):
//   - Primary: fires once per plugin init on the first session.created event.
//   - Fallback: if session.created is missed (plugin loaded mid-session),
//     fires on the first session.updated event within 30s of plugin init.
//
// Caching: raw update-check output is written to
//   ~/.aidevops/cache/session-greeting-opencode.txt
// so non-Bash agents can read it without re-running the script (t2724 phase 2
// template change points agents at this file).
//
// Toast model (t2727 consolidation):
//   OpenCode's TUI renders one toast at a time — each client.tui.showToast()
//   call replaces the previous before the user can read it. So we classify
//   lines into severity buckets (error, warning, info, success) but emit a
//   SINGLE consolidated toast whose variant follows the highest severity
//   present and whose message preserves severity ordering:
//     error   (30s) : [SECURITY ADVISORY] / [ERROR] lines
//     warning (15s) : pulse-stalled / external contribution / [WARN] lines
//     info     (8s) : version + env lines
//     success  (5s) : "Security: all protections active"
//   A user with a clean environment sees one info/success-tinted toast with
//   the version+env+security-active lines. With any advisory or warning, the
//   variant escalates (error overrides warning, warning overrides info) and
//   all lines remain visible in the body.
//
// Toast filters: UPDATE_AVAILABLE|<...> and AUTO_UPDATE_ENABLED are the
// only lines suppressed — those are machine-readable sentinels. The
// runtime-identity line (`You are running in <app>. Global config: ...`)
// WAS suppressed from the toast by t2728 but restored by t2731 after
// user feedback that seeing the config path at session start is valuable.
// See also t2730 for the parallel AGENTS.md prose (model-only surface).
//
// Async model (t2729):
//   The update-check script spawns background children (provenance notify,
//   deploy drift check) that inherit stdout. With execSync, Node waits for
//   all inherited FDs to close — 5-8s wallclock on typical macOS hardware.
//   The fix: fire execAsync and return from the handler immediately; emit
//   the toast inside the promise's .then() callback whenever the subprocess
//   finishes. The session.created handler resolves in <1ms; the toast appears
//   5-15s later (same content, same variant, just deferred).
//   With AIDEVOPS_PLUGIN_DEBUG=1, the trace log shows handler-completed
//   BEFORE emitToast-* — the reversed ordering confirms async delivery.
//
// Diagnostics: set AIDEVOPS_PLUGIN_DEBUG=1 to trace every handler invocation
// and each toast emission (including failures). Without DEBUG the handler
// is silent on success — only actual errors reach stderr.
// ---------------------------------------------------------------------------

import { exec } from "child_process";
import { promisify } from "util";
import {
  acquireRefreshLock,
  cacheGreeting,
  greetingCacheHasCurrentProvenance,
  isGreetingCacheUsable,
  observeSharedRefresh,
  readGreetingCache,
  releaseRefreshLock,
} from "./greeting-refresh.mjs";
import {
  buildToast,
  classifyLines,
  emitCachedGreeting,
  emitToast,
} from "./greeting-toast.mjs";
import { join } from "path";
import { homedir } from "os";

export {
  buildToast,
  classifyLines,
  greetingCacheHasCurrentProvenance,
  isGreetingCacheUsable,
  readGreetingCache,
};

const execAsync = promisify(exec);

const CACHE_DIR = join(homedir(), ".aidevops", "cache");
const CACHE_BASENAME = "session-greeting-opencode.txt";
const LOCK_BASENAME = "session-greeting-refresh.lock";
// Comprehensive checks run at most once per 15-minute window. The subprocess
// times out after 15 seconds, so a lock older than 30 seconds is safe to reap
// after an abrupt plugin-process exit.
export const REFRESH_TTL_MS = 15 * 60 * 1000;
const LOCK_STALE_MS = 30 * 1000;

// Fallback window: accept the first session.updated as a trigger if no
// session.created arrived within this many ms of plugin init. Keeps the
// handler from firing on every subsequent session.updated event.
const FALLBACK_WINDOW_MS = 30000;

/**
 * Run the update-check script asynchronously and deliver results via callback.
 *
 * t2729: replaced execSync with execAsync so the caller returns immediately
 * and the toast is emitted inside the promise's .then() callback whenever the
 * subprocess finishes. Node no longer waits for background children
 * (provenance notify, deploy drift check) to close their inherited stdout FDs.
 *
 * Timeout 15s (t2725) is preserved as a fallback governing the fire-and-forget
 * tail rather than the handler return time.
 *
 * The caller owns a cross-process lock and this promise chain always releases
 * it, including empty-output and failure paths.
 *
 * @param {{ scriptsDir: string, client: any, cacheFile: string, lockDir: string,
 *   execGreeting: Function, maintenanceNoticeFn: Function, cachedFallback: object|null }} options
 */
function runGreetingAsync({ scriptsDir, client, cacheFile, lockDir, lockToken, execGreeting, maintenanceNoticeFn, cachedFallback }) {
  const script = join(scriptsDir, "aidevops-update-check.sh");
  Promise.resolve()
    .then(() => execGreeting(`bash ${JSON.stringify(script)} --interactive`, {
      timeout: 15000,
      env: { ...process.env, OPENCODE: "1" },
    }))
    .then(async ({ stdout }) => {
      const output = stdout ? stdout.trim() : "";
      if (!output) {
        if (process.env.AIDEVOPS_PLUGIN_DEBUG) {
          console.error("[aidevops] greeting: update-check returned empty, using cached fallback");
        }
        emitCachedGreeting(client, cachedFallback);
        return;
      }

      const maintenanceNotice = await maintenanceNoticeFn(scriptsDir);
      const combinedOutput = [output, maintenanceNotice].filter(Boolean).join("\n");

      cacheGreeting(cacheFile, combinedOutput);
      const toast = buildToast(classifyLines(combinedOutput));

      if (process.env.AIDEVOPS_PLUGIN_DEBUG) {
        const buckets = classifyLines(combinedOutput);
        const bucketCounts = `info=${buckets.info.length}, success=${buckets.success.length}, warning=${buckets.warning.length}, error=${buckets.error.length}`;
        if (toast) {
          console.error(`[aidevops] greeting: built 1 toast (variant=${toast.variant}, ${bucketCounts})`);
        } else {
          console.error(`[aidevops] greeting: no lines to show (${bucketCounts})`);
        }
      }

      if (toast) {
        emitToast(client, toast);
      }
    })
    .catch((err) => {
      if (process.env.AIDEVOPS_PLUGIN_DEBUG) {
        console.error(`[aidevops] greeting: update-check failed: ${err.message}`);
      }
      emitCachedGreeting(client, cachedFallback);
    })
    .finally(() => {
      releaseRefreshLock(lockDir, lockToken);
    });
  // Returns here — handler can resolve before the subprocess finishes.
}

/**
 * Return an optional one-line OpenCode DB maintenance notice.
 *
 * The helper owns all DB/scheduler logic; the plugin only appends any emitted
 * notice to the existing consolidated greeting toast. Failures are ignored so
 * session startup never depends on maintenance diagnostics.
 *
 * @param {string} scriptsDir
 * @returns {Promise<string>}
 */
async function getOpenCodeMaintenanceNotice(scriptsDir) {
  const script = join(scriptsDir, "opencode-db-maintenance-helper.sh");
  try {
    const { stdout } = await execAsync(`bash ${JSON.stringify(script)} notice`, {
      timeout: 2500,
    });
    return stdout ? stdout.trim() : "";
  } catch (err) {
    if (process.env.AIDEVOPS_PLUGIN_DEBUG) {
      console.error(`[aidevops] greeting: opencode maintenance notice failed: ${err.message}`);
    }
    return "";
  }
}

// runGreeting is superseded by runGreetingAsync (t2729). The async variant
// fires the update-check subprocess and returns immediately; all downstream
// work (cache write, classify, toast emit) runs inside the promise chain.
// The caller MUST NOT await runGreetingAsync — doing so would restore the
// blocking behaviour this change is meant to fix.

function refreshGreetingIfStale({ cached, now, refreshTtlMs, initializedAtMs, lockDir, lockStaleMs, scriptsDir, client, cacheFile, execGreeting, maintenanceNoticeFn }) {
  if (isGreetingCacheUsable(cached, now(), refreshTtlMs, initializedAtMs)) return;

  const cachedFallback = greetingCacheHasCurrentProvenance(cached, initializedAtMs) ? cached : null;

  const lockToken = acquireRefreshLock(lockDir, lockStaleMs, now());
  if (lockToken) {
    runGreetingAsync({
      scriptsDir,
      client,
      cacheFile,
      lockDir,
      lockToken,
      execGreeting,
      maintenanceNoticeFn,
      cachedFallback,
    });
    return;
  }

  observeSharedRefresh({
    cacheFile,
    lockDir,
    lockStaleMs,
    client,
    now,
    minimumMtimeMs: Math.max(cached?.mtimeMs ?? Number.NEGATIVE_INFINITY, initializedAtMs),
  });
  if (process.env.AIDEVOPS_PLUGIN_DEBUG) {
    console.error("[aidevops] greeting: refresh already running in another process");
  }
}

/**
 * Create a handler that fires the greeting once per plugin init. The
 * returned function matches the plugin `event` hook contract so it can be
 * composed alongside other event consumers.
 *
 * Trigger rules:
 *   1. Fires on the first `session.created` event received.
 *   2. Falls back to the first `session.updated` event if >0ms but <30s
 *      since plugin init has elapsed without a session.created arriving
 *      (handles the case where the plugin loads after a session is already
 *      active — e.g., hot-deploy during an existing session).
 *   3. Ignores all other event types.
 *
 * @param {{ scriptsDir: string, client: any }} opts
 * @returns {(input: { event: { type: string } }) => Promise<void>}
 */
export function createGreetingHandler({
  scriptsDir,
  client,
  cacheDir = CACHE_DIR,
  refreshTtlMs = REFRESH_TTL_MS,
  lockStaleMs = LOCK_STALE_MS,
  execGreeting = execAsync,
  maintenanceNoticeFn = getOpenCodeMaintenanceNotice,
  now = Date.now,
  initializedAtMs = now(),
  isHeadless = () => false,
}) {
  let fired = false;
  const cacheFile = join(cacheDir, CACHE_BASENAME);
  const lockDir = join(cacheDir, LOCK_BASENAME);

  return async ({ event }) => {
    if (fired) return;
    if (isHeadless()) return;
    if (!event || !event.type) return;

    // OpenCode includes session metadata on lifecycle events. A parentID marks
    // a subagent/subtask session, which must not consume or display the main
    // interactive session's startup toast.
    const sessionInfo = event.properties?.info;
    if (sessionInfo?.parentID) return;

    const isPrimary = event.type === "session.created";
    const isFallback =
      event.type === "session.updated" &&
      now() - initializedAtMs < FALLBACK_WINDOW_MS;

    if (!isPrimary && !isFallback) return;

    fired = true;

    if (process.env.AIDEVOPS_PLUGIN_DEBUG) {
      const mode = isPrimary ? "primary" : "fallback";
      console.error(`[aidevops] greeting: triggered (mode=${mode}, type=${event.type})`);
    }

    // Serve a fresh cache synchronously. A stale cache is retained only as a
    // refresh-failure fallback; emitting it here and the refreshed value later
    // would display two startup toasts for one session.
    const cached = readGreetingCache(cacheFile);
    if (isGreetingCacheUsable(cached, now(), refreshTtlMs, initializedAtMs)) {
      emitCachedGreeting(client, cached);
    }

    refreshGreetingIfStale({
      cached,
      now,
      refreshTtlMs,
      initializedAtMs,
      lockDir,
      lockStaleMs,
      scriptsDir,
      client,
      cacheFile,
      execGreeting,
      maintenanceNoticeFn,
    });

    if (process.env.AIDEVOPS_PLUGIN_DEBUG) {
      console.error("[aidevops] greeting: handler-completed");
    }
  };
}

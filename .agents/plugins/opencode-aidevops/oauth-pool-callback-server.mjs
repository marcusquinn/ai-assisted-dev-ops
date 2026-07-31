// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

/**
 * OAuth Pool — Local Callback Server
 *
 * Captures OAuth authorization responses on the loopback callback endpoint.
 *
 * @module oauth-pool-callback-server
 */

import { createServer } from "http";
import { OAUTH_CALLBACK_PORT, OAUTH_CALLBACK_TIMEOUT_MS } from "./oauth-pool-constants.mjs";

export function startOAuthCallbackServer(expectedState) {
  let resolveCode, rejectCode, server, timeoutId, resolveReady;
  const promise = new Promise((resolve, reject) => { resolveCode = resolve; rejectCode = reject; });
  const ready = new Promise((resolve) => { resolveReady = resolve; });
  const escapeHtml = (s) =>
    s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;").replace(/'/g, "&#039;");

  function cleanup() {
    if (timeoutId) clearTimeout(timeoutId);
    if (server) { try { server.close(); } catch { /* ignore */ } }
  }

  server = createServer((req, res) => {
    let reqUrl;
    try { reqUrl = new URL(req.url, `http://localhost:${OAUTH_CALLBACK_PORT}`); }
    catch { res.writeHead(400, { "Content-Type": "text/plain" }); res.end("Bad request"); return; }

    if (reqUrl.pathname !== "/auth/callback") {
      res.writeHead(404, { "Content-Type": "text/plain" }); res.end("Not found"); return;
    }

    const code = reqUrl.searchParams.get("code");
    const error = reqUrl.searchParams.get("error");

    // Validate OAuth state to prevent CSRF / account-mixup attacks.
    if (expectedState) {
      const returnedState = reqUrl.searchParams.get("state");
      if (returnedState !== expectedState) {
        console.error("[aidevops] OAuth pool: state mismatch in callback — possible CSRF");
        res.writeHead(400, { "Content-Type": "text/plain" });
        res.end("State mismatch — authorization rejected");
        cleanup();
        rejectCode(new Error("OAuth state mismatch"));
        return;
      }
    }

    if (error) {
      res.writeHead(200, { "Content-Type": "text/html" });
      res.end(`<!DOCTYPE html><html><body><h2>Authorization Failed</h2><p>${escapeHtml(error)}</p><p>${escapeHtml(reqUrl.searchParams.get("error_description") || "")}</p><p>You can close this tab.</p></body></html>`);
      cleanup();
      rejectCode(new Error(`OAuth error: ${error}`));
    } else if (code) {
      res.writeHead(200, { "Content-Type": "text/html" });
      res.end(`<!DOCTYPE html><html><body><h2>Authorization Successful</h2><p>The authorization code has been captured. Return to OpenCode.</p><p>You can close this tab.</p></body></html>`);
      cleanup();
      resolveCode(code);
    } else {
      res.writeHead(200, { "Content-Type": "text/plain" });
      res.end("Waiting for OAuth callback...");
    }
  });

  server.on("error", (err) => {
    cleanup();
    if (err.code === "EADDRINUSE") {
      console.error(`[aidevops] OAuth pool: port ${OAUTH_CALLBACK_PORT} in use`);
      resolveReady(false);
      return;
    }
    console.error(`[aidevops] OAuth pool: callback server error: ${err.message}`);
    resolveReady(false);
    rejectCode(err);
  });

  server.listen(OAUTH_CALLBACK_PORT, "127.0.0.1", () => {
    console.error(`[aidevops] OAuth pool: callback server listening on port ${OAUTH_CALLBACK_PORT}`);
    resolveReady(true);
  });

  timeoutId = setTimeout(() => { cleanup(); rejectCode(new Error("OAuth callback timeout")); }, OAUTH_CALLBACK_TIMEOUT_MS);
  return { promise, ready, close: cleanup };
}

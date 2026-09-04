/**
 * OAuth Pool — Shared Constants (t2128)
 *
 * Single source of truth for all OAuth endpoints, client IDs, scopes,
 * redirect URIs, file paths, and timing constants used across the
 * oauth-pool module cluster.
 *
 * Extracted to eliminate constant duplication between oauth-pool.mjs
 * and oauth-pool-auth.mjs.
 *
 * @module oauth-pool-constants
 */

import { join } from "path";
import { homedir, platform } from "os";

// ---------------------------------------------------------------------------
// File paths
// ---------------------------------------------------------------------------

const HOME = homedir();

/** Pool credential file path */
export const POOL_FILE = join(HOME, ".aidevops", "oauth-pool.json");

/** Advisory lock identity shared with oauth-pool-helper.sh (`.lock.d` protocol) */
export const POOL_LOCK_FILE = POOL_FILE + ".lock";

// ---------------------------------------------------------------------------
// Anthropic OAuth constants
// ---------------------------------------------------------------------------

export const ANTHROPIC_CLIENT_ID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e";
export const ANTHROPIC_TOKEN_ENDPOINT = "https://platform.claude.com/v1/oauth/token";
export const ANTHROPIC_OAUTH_AUTHORIZE_URL = "https://claude.ai/oauth/authorize";
export const ANTHROPIC_REDIRECT_URI = "https://console.anthropic.com/oauth/code/callback";
export const ANTHROPIC_OAUTH_SCOPES = "org:create_api_key user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload";

// ---------------------------------------------------------------------------
// OpenAI OAuth constants (t1548)
// ---------------------------------------------------------------------------

export const OPENAI_CLIENT_ID = "app_EMoamEEZ73f0CkXaXp7hrann";
export const OPENAI_ISSUER = "https://auth.openai.com";
export const OPENAI_TOKEN_ENDPOINT = `${OPENAI_ISSUER}/oauth/token`;
export const OPENAI_OAUTH_AUTHORIZE_URL = `${OPENAI_ISSUER}/oauth/authorize`;
export const OPENAI_REDIRECT_URI = "http://localhost:1455/auth/callback";
export const OPENAI_OAUTH_SCOPES = "openid profile email offline_access";

// ---------------------------------------------------------------------------
// Google OAuth constants (issue #5614)
// ---------------------------------------------------------------------------

export const GOOGLE_CLIENT_ID = "681255809395-oo8ft6t5t0rnmhfqgpnkqtev5b9a2i5j.apps.googleusercontent.com";
export const GOOGLE_TOKEN_ENDPOINT = "https://oauth2.googleapis.com/token";
export const GOOGLE_OAUTH_AUTHORIZE_URL = "https://accounts.google.com/o/oauth2/v2/auth";
export const GOOGLE_REDIRECT_URI = "urn:ietf:wg:oauth:2.0:oob";
export const GOOGLE_OAUTH_SCOPES = "https://www.googleapis.com/auth/generative-language https://www.googleapis.com/auth/cloud-platform openid email profile";
export const GOOGLE_HEALTH_CHECK_URL = "https://generativelanguage.googleapis.com/v1beta/models?pageSize=1";

// ---------------------------------------------------------------------------
// Cursor constants (t1549)
// ---------------------------------------------------------------------------

export const CURSOR_PROVIDER_ID = "cursor";
export const CURSOR_PROXY_HOST = "127.0.0.1";
export const CURSOR_PROXY_DEFAULT_PORT = 32123;
export const CURSOR_PROXY_BASE_URL = `http://${CURSOR_PROXY_HOST}:${CURSOR_PROXY_DEFAULT_PORT}/v1`;

/** Platform-specific path resolution for Cursor directories. */
const CURSOR_PATHS = (() => {
  const plat = platform();
  if (plat === "darwin") {
    return {
      auth: join(HOME, ".cursor", "auth.json"),
      db: join(HOME, "Library", "Application Support", "Cursor", "User", "globalStorage", "state.vscdb"),
    };
  }
  if (plat === "win32") {
    const ad = process.env.APPDATA || join(HOME, "AppData", "Roaming");
    return {
      auth: join(ad, "Cursor", "auth.json"),
      db: join(ad, "Cursor", "User", "globalStorage", "state.vscdb"),
    };
  }
  const cd = process.env.XDG_CONFIG_HOME || join(HOME, ".config");
  return {
    auth: join(cd, "cursor", "auth.json"),
    db: join(cd, "Cursor", "User", "globalStorage", "state.vscdb"),
  };
})();

export function getCursorAgentAuthPath() { return CURSOR_PATHS.auth; }
export function getCursorStateDbPath() { return CURSOR_PATHS.db; }

// ---------------------------------------------------------------------------
// Shared cooldown / timing constants
// ---------------------------------------------------------------------------

/** Initial cooldown after an OAuth refresh/auth failure (ms) */
export const AUTH_FAILURE_INITIAL_COOLDOWN_MS = 60_000;

/** Maximum cooldown after repeated OAuth refresh/auth failures (ms) */
export const AUTH_FAILURE_MAX_COOLDOWN_MS = 600_000;

/** Backward-compatible default cooldown on auth failure (ms) */
export const AUTH_FAILURE_COOLDOWN_MS = AUTH_FAILURE_INITIAL_COOLDOWN_MS;

/** Cooldown after a 429 on the token endpoint (ms) — 5 minutes */
export const TOKEN_ENDPOINT_COOLDOWN_MS = 300_000;

/** Port for the local OAuth callback server */
export const OAUTH_CALLBACK_PORT = 1455;

/** Timeout for OAuth callback server (ms) */
export const OAUTH_CALLBACK_TIMEOUT_MS = 300_000;

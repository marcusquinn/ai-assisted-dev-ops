<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Mutable OAuth Token State

Use this contract when an integration receives access or refresh tokens that can
change during normal API use. Static client credentials remain in `aidevops
secret`; mutable provider state belongs to one integration-owned runtime store.

The production reference is the OAuth pool: Python primitives in
`scripts/oauth-pool-lib/_common.py` and `pool_ops_refresh.py` coordinate with the
OpenCode implementation in `plugins/opencode-aidevops/oauth-pool-storage.mjs`
and `oauth-pool-refresh.mjs`.

## Authority and identity

- Bootstrap with a client ID/secret or authorization grant from `aidevops
  secret`; never write rotated access or refresh tokens back to shell exports.
- Select exactly one runtime store by provider, account, project/tenant, and
  environment. An absent or ambiguous selector fails closed; it never falls back
  silently to another account or project.
- One process may cache a token only until the store generation changes or an
  authenticated request rejects it. Re-read durable state before refresh.
- Provider SDK behavior, browser authorization, and arbitrary application state
  are outside this storage contract.

## Refresh transaction

Treat `lock → re-read → refresh → replace → unlock` as one transaction:

1. Acquire the store lock with a bounded wait. The lock identity and owner schema
   must be shared by every language that writes the store.
2. Re-read the selected account after acquisition. If another process already
   published a usable token, use it instead of refreshing again.
3. Keep the lock while calling the bounded token endpoint. Never reclaim a lock
   whose recorded process is still live merely because it is old.
4. Require a non-empty access token. When a successful response omits
   `refresh_token`, retain the previous refresh token.
5. Write a unique mode-`0600` temporary file in the destination directory and
   atomically replace the live file. The directory and lock directory are
   mode `0700`; the owner record is mode `0600`.
6. Release only when the recorded PID and unguessable owner token still match.
   A timeout fails closed and leaves the last valid token state unchanged.

Do not add periodic refresh scheduling as a substitute for this transaction.
Scheduling may trigger refresh, but request-bound expiry/rejection handling and
the single-writer contract remain authoritative.

## Secret handling and diagnostics

- Keep token values in memory, request bodies, standard input, or protected
  files. Never put them in command arguments, logs, issue text, test fixtures,
  process titles, health output, or exception messages.
- Health output may report provider/account labels, selected authority, token
  presence, expiry/freshness, cooldown, last successful refresh, and sanitized
  error classes. It must not emit token-bearing objects or provider responses.
- Tests must use obvious placeholders and injected/local responses only.
  Coverage should prove concurrent callers make one refresh, omitted and newly
  rotated refresh tokens persist correctly, stale results cannot replace newer
  state, modes remain restrictive, and lock timeout/recovery is bounded.

## Integration checklist

- Document the exact store selector and path owner without documenting values.
- Keep the on-disk schema backward compatible or provide an explicit migration
  and rollback path.
- Share the reference lock protocol rather than creating a second lock name.
- Verify one normal API request after expiry and one forced refresh after an
  authentication rejection.
- Add metadata-only `status` output and a terminal reauthorization message for
  absent/revoked refresh credentials.

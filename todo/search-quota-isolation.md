# Keep primary Search exhaustion resource-scoped

## What

Prevent the small Search API allowance from imposing a global secondary cooldown
on unrelated REST and GraphQL work. Part of user-authorized productivity recovery
and release, following #31343 and #31348.

## Reproducer

**Symptom command**: invoke `_gh_secondary_cooldown_record_if_needed` with a
successful HTTP 200 response containing `X-RateLimit-Remaining: 0`,
`X-RateLimit-Resource: search`, no Retry-After and a reset that just elapsed.

**Actual output**: the shared state records `github-api-rate-limit-remaining-zero`
and adds a five-minute global cooldown. A live observation identified the producer
as `_rest_search_collect_items`; no secondary-limit or abuse response was present.

## How

Recognize only unambiguous primary Search exhaustion. Persist its actual reset in
a separate resource-scoped cooldown and enforce it before raw shim/REST search
calls. Other resources remain usable. Real secondary/abuse/Retry-After/429 and
unknown evidence retain the existing global fail-closed behavior. Never clear an
existing global cooldown or use status JSON as a quota grant.

## Files Scope

- `.agents/scripts/shared-gh-secondary-cooldown.sh`
- `.agents/scripts/gh-transport-controls.sh`
- `.agents/scripts/shared-gh-wrappers-rest-fallback.sh`
- Existing cooldown/shim/REST fallback tests and transport reference.

## Verification

Hermetic HTTP 200/403 primary Search fixtures, expired reset, missing resource,
secondary response, Retry-After and no-HTTP repeated search tests. Run ShellCheck,
Qlty, existing cooldown, shim and fallback suites. Preserve real quota safety.

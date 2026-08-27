#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="$SCRIPT_DIR/../npm-cache-helper.sh"
TEST_ROOT="$(mktemp -d -t aidevops-npm-cache.XXXXXX)"
FAKE_BIN="$TEST_ROOT/bin"
FAKE_CACHE="$TEST_ROOT/npm-cache"
NPM_CALLS="$TEST_ROOT/npm-calls"
export FAKE_CACHE NPM_CALLS

cleanup() {
	rm -rf "$TEST_ROOT"
	return 0
}
trap cleanup EXIT

fail() {
	local message="$1"
	printf 'FAIL: %s\n' "$message" >&2
	exit 1
}

mkdir -p "$FAKE_BIN" "$FAKE_CACHE"
printf 'cache data\n' >"$FAKE_CACHE/data"
cat >"$FAKE_BIN/npm" <<'FAKE_NPM'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$NPM_CALLS"
if [[ "${1:-}" == "config" ]] && [[ "${2:-}" == "get" ]] && [[ "${3:-}" == "cache" ]]; then
	printf '%s\n' "$FAKE_CACHE"
	return 0 2>/dev/null || exit 0
fi
if [[ "${1:-}" == "cache" ]] && [[ "${2:-}" == "verify" ]]; then
	printf 'verified\n'
	return 0 2>/dev/null || exit 0
fi
if [[ "${1:-}" == "cache" ]] && [[ "${2:-}" == "clean" ]] && [[ "${3:-}" == "--force" ]]; then
	printf 'cleaned\n'
	return 0 2>/dev/null || exit 0
fi
exit 1
FAKE_NPM
chmod +x "$FAKE_BIN/npm"

report=$(PATH="$FAKE_BIN:$PATH" AIDEVOPS_NPM_CACHE_WARN_BYTES=1 bash "$HELPER" json)
[[ "$(printf '%s' "$report" | jq -r '.schema')" == "aidevops.npm-cache-status/v1" ]] || fail "status schema missing"
[[ "$(printf '%s' "$report" | jq -r '.owner')" == "external" ]] || fail "helper claimed npm ownership"
[[ "$(printf '%s' "$report" | jq -r '.advisory')" == "warning" ]] || fail "oversized fixture did not warn"

: >"$NPM_CALLS"
dry_run=$(PATH="$FAKE_BIN:$PATH" bash "$HELPER" clean)
[[ "$dry_run" == *"Dry run only"* ]] || fail "clean did not default to dry run"
if grep -Fq 'cache clean --force' "$NPM_CALLS"; then
	fail "dry run invoked npm cache clean"
fi

: >"$NPM_CALLS"
if PATH="$FAKE_BIN:$PATH" bash "$HELPER" clean --apply --confirm wrong-token >/dev/null 2>&1; then
	fail "clean accepted an invalid confirmation token"
fi
if grep -Fq 'cache clean --force' "$NPM_CALLS"; then
	fail "invalid confirmation invoked npm cache clean"
fi

: >"$NPM_CALLS"
PATH="$FAKE_BIN:$PATH" bash "$HELPER" clean --apply --confirm clean-npm-cache >/dev/null
grep -Fxq "cache clean --force --cache $FAKE_CACHE" "$NPM_CALLS" || fail "confirmed clean did not bind npm-owned cleanup to the measured cache"

: >"$NPM_CALLS"
PATH="$FAKE_BIN:$PATH" bash "$HELPER" verify >/dev/null
grep -Fxq "cache verify --cache $FAKE_CACHE" "$NPM_CALLS" || fail "verify did not bind npm-owned garbage collection to the measured cache"

printf 'PASS: npm cache monitoring is read-only by default and cleanup is npm-owned and confirmed\n'
exit 0

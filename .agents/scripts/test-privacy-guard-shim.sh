#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-privacy-guard-shim.sh — Tests for the gh PATH shim privacy-scan layer
# (t2876) AND the underlying `privacy_scan_text` library function.
#
# Two test groups:
#   1. privacy_scan_text unit tests (no external deps; library only)
#   2. gh shim integration smoke tests (uses a fake `gh` on PATH so we
#      never hit the network or call the real GitHub API)
#
# Usage:
#   .agents/scripts/test-privacy-guard-shim.sh
# Exit code 0 = all tests pass, 1 = at least one failure.

set -u

if [[ -t 1 ]]; then
	GREEN=$'\033[0;32m'
	RED=$'\033[0;31m'
	BLUE=$'\033[0;34m'
	NC=$'\033[0m'
else
	GREEN="" RED="" BLUE="" NC=""
fi

TESTS_RUN=0
TESTS_FAILED=0

pass() {
	TESTS_RUN=$((TESTS_RUN + 1))
	printf '  %sPASS%s %s\n' "$GREEN" "$NC" "$1"
	return 0
}

fail() {
	TESTS_RUN=$((TESTS_RUN + 1))
	TESTS_FAILED=$((TESTS_FAILED + 1))
	printf '  %sFAIL%s %s\n' "$RED" "$NC" "$1"
	return 0
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="${SCRIPT_DIR}/privacy-guard-helper.sh"
SHIM="${SCRIPT_DIR}/gh"

if [[ ! -f "$HELPER" || ! -f "$SHIM" ]]; then
	printf 'test harness cannot find helper or shim:\n  helper=%s\n  shim=%s\n' "$HELPER" "$SHIM" >&2
	exit 1
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# -----------------------------------------------------------------------------
# Group 1: privacy_scan_text unit tests
# -----------------------------------------------------------------------------
printf '%sGroup 1: privacy_scan_text unit tests%s\n' "$BLUE" "$NC"

# shellcheck source=privacy-guard-helper.sh
source "$HELPER"

# Slug list: includes one short basename ("app", to test the min-length guard)
# and one distinctive one ("longprivate").
SLUGS_FILE="${TMP}/slugs.txt"
cat >"$SLUGS_FILE" <<'EOF'
acme/longprivate
acme/app
EOF

# Test 1.1: full slug match
text='Mention of acme/longprivate in a body'
hits=$(privacy_scan_text "$text" "$SLUGS_FILE")
rc=$?
if [[ "$rc" -eq 1 ]] && printf '%s' "$hits" | grep -q '^acme/longprivate$'; then
	pass "full-slug match (acme/longprivate)"
else
	fail "expected rc=1 + 'acme/longprivate' hit, got rc=$rc hits='$hits'"
fi

# Test 1.2: bare basename match (>= 6 chars)
text='Bug observed in longprivate during triage'
hits=$(privacy_scan_text "$text" "$SLUGS_FILE")
rc=$?
if [[ "$rc" -eq 1 ]] && printf '%s' "$hits" | grep -q '^longprivate (basename of acme/longprivate)$'; then
	pass "bare basename match (>= 6 chars)"
else
	fail "expected rc=1 + 'longprivate (basename ...)' hit, got rc=$rc hits='$hits'"
fi

# Test 1.3: short basename should NOT match bare (avoid 'app' false-positive)
text='Built into the desktop app this week'
hits=$(privacy_scan_text "$text" "$SLUGS_FILE")
rc=$?
if [[ "$rc" -eq 0 && -z "$hits" ]]; then
	pass "short basename ('app', 3 chars) does NOT trigger bare match"
else
	fail "expected rc=0 + empty, got rc=$rc hits='$hits'"
fi

# Test 1.4: short basename DOES match in full slug form
text='Found in acme/app today'
hits=$(privacy_scan_text "$text" "$SLUGS_FILE")
rc=$?
if [[ "$rc" -eq 1 ]] && printf '%s' "$hits" | grep -q '^acme/app$'; then
	pass "short basename matches in full-slug form"
else
	fail "expected rc=1 + 'acme/app' hit, got rc=$rc hits='$hits'"
fi

# Test 1.5: alias content (no private mentions) → clean
text='Mention of <webapp> as a generic placeholder, plus marcusquinn/aidevops'
hits=$(privacy_scan_text "$text" "$SLUGS_FILE")
rc=$?
if [[ "$rc" -eq 0 && -z "$hits" ]]; then
	pass "alias-only content does not trigger"
else
	fail "expected rc=0 + empty, got rc=$rc hits='$hits'"
fi

# Test 1.6: word boundary — basename inside another word does NOT match
text='superlongprivateworld is a different token'
hits=$(privacy_scan_text "$text" "$SLUGS_FILE")
rc=$?
if [[ "$rc" -eq 0 && -z "$hits" ]]; then
	pass "basename inside another word respects word boundaries"
else
	fail "expected rc=0 (boundary) + empty, got rc=$rc hits='$hits'"
fi

# Test 1.7: empty content
hits=$(privacy_scan_text "" "$SLUGS_FILE")
rc=$?
if [[ "$rc" -eq 0 && -z "$hits" ]]; then
	pass "empty content returns rc=0 with no hits"
else
	fail "expected rc=0, got rc=$rc"
fi

# Test 1.8: empty slugs file
EMPTY_SLUGS=$(mktemp)
hits=$(privacy_scan_text 'mentions acme/longprivate' "$EMPTY_SLUGS")
rc=$?
rm -f "$EMPTY_SLUGS"
if [[ "$rc" -eq 0 && -z "$hits" ]]; then
	pass "empty slugs file returns rc=0"
else
	fail "expected rc=0 with empty slugs, got rc=$rc"
fi

# Test 1.9: missing slugs file → rc=2 (setup error)
hits=$(privacy_scan_text 'mentions acme/longprivate' "$TMP/nonexistent.txt")
rc=$?
if [[ "$rc" -eq 2 ]]; then
	pass "missing slugs file returns rc=2"
else
	fail "expected rc=2 for missing slugs file, got rc=$rc"
fi

# Test 1.10: comments and blank lines in slugs file are skipped
COMMENTED_SLUGS=$(mktemp)
cat >"$COMMENTED_SLUGS" <<'EOF'
# this is a comment
acme/longprivate

# another comment
EOF
hits=$(privacy_scan_text 'mentions acme/longprivate' "$COMMENTED_SLUGS")
rc=$?
rm -f "$COMMENTED_SLUGS"
if [[ "$rc" -eq 1 ]] && printf '%s' "$hits" | grep -q '^acme/longprivate$'; then
	pass "comment and blank lines in slugs file are skipped"
else
	fail "expected rc=1 with single hit, got rc=$rc hits='$hits'"
fi

# -----------------------------------------------------------------------------
# Group 2: gh shim integration tests
# These tests stage a fake `gh` on PATH so the shim's `_find_real_gh` returns
# our stub. The stub records its argv, then exits 0. We then assert on the
# shim's behaviour (block vs allow) and the recorded argv.
# -----------------------------------------------------------------------------
printf '\n%sGroup 2: gh shim integration tests%s\n' "$BLUE" "$NC"

# Stage a temp PATH dir with the shim and a fake real-gh
PATH_DIR="${TMP}/pathdir"
mkdir -p "$PATH_DIR"
cp "$SHIM" "$PATH_DIR/gh"
cp "${SCRIPT_DIR}/gh-native-transport-lib.sh" "$PATH_DIR/gh-native-transport-lib.sh"
cp "${SCRIPT_DIR}/gh-api-guards-lib.sh" "$PATH_DIR/gh-api-guards-lib.sh"
cp "${SCRIPT_DIR}/gh-write-policy-lib.sh" "$PATH_DIR/gh-write-policy-lib.sh"
chmod +x "$PATH_DIR/gh"

# Co-locate the helper alongside the shim so the shim's helper-lookup finds it
# at the expected sibling path (matches deployed and source layouts).
cp "$HELPER" "$PATH_DIR/privacy-guard-helper.sh"

# Stub signature helper so the shim's sig-injection layer succeeds quietly
cat >"$PATH_DIR/gh-signature-helper.sh" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
footer) printf '\n\n<!-- aidevops:sig -->\n' ;;
*) exit 0 ;;
esac
STUB
chmod +x "$PATH_DIR/gh-signature-helper.sh"

# Fake real-gh placed in a sibling dir on PATH (after PATH_DIR)
REAL_GH_DIR="${TMP}/real-gh-dir"
mkdir -p "$REAL_GH_DIR"
RECORD_FILE="${TMP}/gh-invocation.log"
AUTH_RECORD_FILE="${TMP}/gh-auth-invocation.log"
API_RECORD_FILE="${TMP}/gh-api-invocation.log"
REST_RATE_LIMIT_FILE="${TMP}/rest-rate-limited"
REQUIRE_RAW_FIELDS_FILE="${TMP}/require-raw-graphql-fields"
cat >"$REAL_GH_DIR/gh" <<STUB
#!/usr/bin/env bash
if [[ "\${1:-}" == "auth" && "\${2:-}" == "status" ]]; then
	printf '%s\n' "REAL_GH_AUTH_INVOKED" > '$AUTH_RECORD_FILE'
	exit 1
fi
if [[ "\${1:-}" == "api" && "\${2:-}" == repos/* ]]; then
	printf '%s\n' "REST" >> '$API_RECORD_FILE'
	if [[ -f '$REST_RATE_LIMIT_FILE' ]]; then
		exit 1
	fi
	printf '%s\n' false
	exit 0
fi
if [[ "\${1:-}" == "api" && "\${2:-}" == "graphql" ]]; then
	printf '%s\n' "GRAPHQL" >> '$API_RECORD_FILE'
	if [[ -f '$REQUIRE_RAW_FIELDS_FILE' ]]; then
		for arg in "\$@"; do
			[[ "\$arg" != "-F" ]] || exit 1
		done
	fi
	printf '%s\n' false
	exit 0
fi
printf '%s\n' "REAL_GH_INVOKED" > '$RECORD_FILE'
printf '%s\n' "\$@" >> '$RECORD_FILE'
exit 0
STUB
chmod +x "$REAL_GH_DIR/gh"

# Set up a fake repos.json + cache so privacy_is_target_public reads from it
PRIV_HOME="${TMP}/priv-home"
mkdir -p "$PRIV_HOME/.config/aidevops" "$PRIV_HOME/.aidevops/cache"
cat >"$PRIV_HOME/.config/aidevops/repos.json" <<'EOF'
{
  "initialized_repos": [
    {
      "slug": "marcusquinn/aidevops",
      "path": "/tmp/aidevops",
      "pulse": true
    },
    {
      "slug": "acme/longprivate",
      "path": "/tmp/longprivate",
      "pulse": false,
      "mirror_upstream": "upstream/source"
    }
  ]
}
EOF
# Pre-warm the privacy cache so we don't need real gh for the public probe
cat >"$PRIV_HOME/.aidevops/cache/repo-privacy.json" <<EOF
{
  "marcusquinn/aidevops": { "private": false, "checked_at": $(date +%s) },
  "acme/longprivate":    { "private": true,  "checked_at": $(date +%s) }
}
EOF

# Helper to run shim with controlled environment
run_shim() {
	local _path_dir="$1"
	local _rc=0
	shift
	HOME="$PRIV_HOME" \
		PRIVACY_REPOS_CONFIG="$PRIV_HOME/.config/aidevops/repos.json" \
		PRIVACY_CACHE_FILE="$PRIV_HOME/.aidevops/cache/repo-privacy.json" \
		HEADLESS='' FULL_LOOP_HEADLESS='' AIDEVOPS_HEADLESS='' OPENCODE_HEADLESS='' \
		GITHUB_ACTIONS='' AIDEVOPS_SESSION_ORIGIN='' \
		PATH="$_path_dir:$REAL_GH_DIR:$PATH" \
		"$_path_dir/gh" "$@" || _rc=$?
	if [[ "$_rc" -ne 0 ]]; then
		return 1
	fi
	return 0
}

# -- Test 2.0: cold privacy probes bypass the active shim and query the target
# directly instead of trusting `gh auth status`.
rm -f "$PRIV_HOME/.aidevops/cache/repo-privacy.json" \
	"$RECORD_FILE" "$AUTH_RECORD_FILE" "$API_RECORD_FILE"
out=$(run_shim "$PATH_DIR" issue create --repo marcusquinn/aidevops --title "test" --body "Clean cold-cache content" 2>&1)
rc=$?
if [[ "$rc" -eq 0 ]] && [[ -f "$RECORD_FILE" && ! -f "$AUTH_RECORD_FILE" && -f "$API_RECORD_FILE" ]] &&
	grep -q '^REST$' "$API_RECORD_FILE" &&
	[[ "$out" != *"gh not authenticated"* ]]; then
	pass "cold privacy probe does not trust gh auth status"
else
	fail "expected native REST/final invocations without auth-status probe. rc=$rc out='$out'"
fi

# -- Test 2.0a: REST quota exhaustion falls back to authenticated GraphQL.
rm -f "$PRIV_HOME/.aidevops/cache/repo-privacy.json" \
	"$RECORD_FILE" "$AUTH_RECORD_FILE" "$API_RECORD_FILE"
touch "$REST_RATE_LIMIT_FILE"
touch "$REQUIRE_RAW_FIELDS_FILE"
out=$(run_shim "$PATH_DIR" issue create --repo 123/true --title "test" --body "Clean quota fallback content" 2>&1)
rc=$?
rm -f "$REST_RATE_LIMIT_FILE" "$REQUIRE_RAW_FIELDS_FILE"
if [[ "$rc" -eq 0 ]] && [[ -f "$RECORD_FILE" && ! -f "$AUTH_RECORD_FILE" && -f "$API_RECORD_FILE" ]] &&
	grep -q '^REST$' "$API_RECORD_FILE" && grep -q '^GRAPHQL$' "$API_RECORD_FILE"; then
	pass "REST quota exhaustion falls back with string-safe GraphQL variables"
else
	fail "expected REST then GraphQL privacy probes without auth-status probe. rc=$rc out='$out'"
fi

# Restore the warm cache used by the remaining integration cases.
cat >"$PRIV_HOME/.aidevops/cache/repo-privacy.json" <<EOF
{
  "marcusquinn/aidevops": { "private": false, "checked_at": $(date +%s) },
  "acme/longprivate":    { "private": true,  "checked_at": $(date +%s) }
}
EOF

# -- Test 2.1: public target + private slug body → BLOCKED
rm -f "$RECORD_FILE"
out=$(run_shim "$PATH_DIR" issue create --repo marcusquinn/aidevops --title "test" --body "Mentions acme/longprivate today" 2>&1)
rc=$?
if [[ "$rc" -eq 1 ]] && [[ ! -f "$RECORD_FILE" ]] && printf '%s' "$out" | grep -q 'BLOCK.*marcusquinn/aidevops'; then
	pass "public target + full-slug body → BLOCKED, real gh not invoked"
else
	fail "expected rc=1, no real-gh invocation, BLOCK message. rc=$rc, real_gh=$([[ -f "$RECORD_FILE" ]] && echo yes || echo no), out='$out'"
fi

# -- Test 2.2: public target + private basename body → BLOCKED
rm -f "$RECORD_FILE"
out=$(run_shim "$PATH_DIR" issue create --repo marcusquinn/aidevops --title "test" --body "Hit a bug in longprivate today" 2>&1)
rc=$?
if [[ "$rc" -eq 1 ]] && [[ ! -f "$RECORD_FILE" ]]; then
	pass "public target + bare-basename body → BLOCKED, real gh not invoked"
else
	fail "expected rc=1, no real-gh invocation. rc=$rc out='$out'"
fi

# -- Test 2.3: public target + clean body → ALLOWED
rm -f "$RECORD_FILE"
out=$(run_shim "$PATH_DIR" issue create --repo marcusquinn/aidevops --title "test" --body "Clean content with <webapp> placeholder" 2>&1)
rc=$?
if [[ "$rc" -eq 0 ]] && [[ -f "$RECORD_FILE" ]]; then
	pass "public target + clean body → ALLOWED, real gh invoked"
else
	fail "expected rc=0 + real-gh invocation. rc=$rc out='$out'"
fi

# -- Test 2.4: private target + private slug body → ALLOWED (out of scope)
rm -f "$RECORD_FILE"
out=$(run_shim "$PATH_DIR" issue create --repo acme/longprivate --title "test" --body "Mentions acme/longprivate" 2>&1)
rc=$?
if [[ "$rc" -eq 0 ]] && [[ -f "$RECORD_FILE" ]]; then
	pass "private target + private body → ALLOWED (out of scope for guard)"
else
	fail "expected rc=0 + real-gh invocation for private target. rc=$rc out='$out'"
fi

# -- Test 2.5: bypass env var → ALLOWED with audit notice
rm -f "$RECORD_FILE"
out=$(AIDEVOPS_GH_PRIVACY_BYPASS=1 run_shim "$PATH_DIR" issue create --repo marcusquinn/aidevops --title "test" --body "Mentions acme/longprivate today" 2>&1)
rc=$?
if [[ "$rc" -eq 0 ]] && [[ -f "$RECORD_FILE" ]] && printf '%s' "$out" | grep -q 'BYPASSED'; then
	pass "AIDEVOPS_GH_PRIVACY_BYPASS=1 → ALLOWED with audit notice"
else
	fail "expected rc=0 + bypass notice + real-gh invocation. rc=$rc out='$out'"
fi

# -- Test 2.6: --body-file with private slug → BLOCKED
rm -f "$RECORD_FILE"
BF="${TMP}/body-with-leak.md"
printf 'A body referencing acme/longprivate inline' >"$BF"
out=$(run_shim "$PATH_DIR" issue create --repo marcusquinn/aidevops --title "test" --body-file "$BF" 2>&1)
rc=$?
if [[ "$rc" -eq 1 ]] && [[ ! -f "$RECORD_FILE" ]]; then
	pass "--body-file with private slug → BLOCKED"
else
	fail "expected rc=1 for --body-file leak. rc=$rc out='$out'"
fi

# -- Test 2.7: title-only leak → BLOCKED
rm -f "$RECORD_FILE"
out=$(run_shim "$PATH_DIR" issue create --repo marcusquinn/aidevops --title "Bug in longprivate observed" --body "Clean body" 2>&1)
rc=$?
if [[ "$rc" -eq 1 ]] && [[ ! -f "$RECORD_FILE" ]]; then
	pass "leak in --title is detected (not just body)"
else
	fail "expected rc=1 for title leak. rc=$rc out='$out'"
fi

# -- Test 2.8: AIDEVOPS_GH_SHIM_DISABLE bypasses entire shim → ALLOWED
rm -f "$RECORD_FILE"
out=$(AIDEVOPS_GH_SHIM_DISABLE=1 run_shim "$PATH_DIR" issue create --repo marcusquinn/aidevops --title "test" --body "Mentions acme/longprivate" 2>&1)
rc=$?
if [[ "$rc" -eq 0 ]] && [[ -f "$RECORD_FILE" ]]; then
	pass "AIDEVOPS_GH_SHIM_DISABLE=1 bypasses privacy-scan (and entire shim)"
else
	fail "expected rc=0 with shim disable. rc=$rc out='$out'"
fi

# -- Test 2.9: read-only commands pass through unchanged
rm -f "$RECORD_FILE"
out=$(run_shim "$PATH_DIR" issue list --repo marcusquinn/aidevops 2>&1)
rc=$?
if [[ "$rc" -eq 0 ]] && [[ -f "$RECORD_FILE" ]]; then
	pass "read-only commands (issue list) pass through without scan"
else
	fail "expected rc=0 for read-only command. rc=$rc out='$out'"
fi

# -- Test 2.10: pr edit with private slug body → BLOCKED (new in t2876)
rm -f "$RECORD_FILE"
out=$(run_shim "$PATH_DIR" pr edit 123 --repo marcusquinn/aidevops --body "Updated to mention acme/longprivate" 2>&1)
rc=$?
if [[ "$rc" -eq 1 ]] && [[ ! -f "$RECORD_FILE" ]]; then
	pass "pr edit with private body → BLOCKED (covers new edit subcommand)"
else
	fail "expected rc=1 for pr edit leak. rc=$rc out='$out'"
fi

# -- Test 2.11: issue edit with private slug body → BLOCKED (new in t2876)
rm -f "$RECORD_FILE"
out=$(run_shim "$PATH_DIR" issue edit 456 --repo marcusquinn/aidevops --body "Edit referencing acme/longprivate" 2>&1)
rc=$?
if [[ "$rc" -eq 1 ]] && [[ ! -f "$RECORD_FILE" ]]; then
	pass "issue edit with private body → BLOCKED (covers new edit subcommand)"
else
	fail "expected rc=1 for issue edit leak. rc=$rc out='$out'"
fi

# -- Test 2.12: local path in body → BLOCKED with generic hit
rm -f "$RECORD_FILE"
out=$(run_shim "$PATH_DIR" issue create --repo marcusquinn/aidevops --title "test" --body "See /Users/example/Git/private-project for repro" 2>&1)
rc=$?
if [[ "$rc" -eq 1 ]] && [[ ! -f "$RECORD_FILE" ]] && printf '%s' "$out" | grep -q '\[local-path\]' && ! printf '%s' "$out" | grep -q '/Users/example'; then
	pass "public target + local path body → BLOCKED generically"
else
	fail "expected rc=1 + generic local-path hit. rc=$rc out='$out'"
fi

# -- Test 2.13: pr review body with private slug → BLOCKED
rm -f "$RECORD_FILE"
out=$(run_shim "$PATH_DIR" pr review 123 --repo marcusquinn/aidevops --comment --body "Review mentions acme/longprivate" 2>&1)
rc=$?
if [[ "$rc" -eq 1 ]] && [[ ! -f "$RECORD_FILE" ]]; then
	pass "pr review with private body → BLOCKED"
else
	fail "expected rc=1 for pr review leak. rc=$rc out='$out'"
fi

# -- Test 2.14: gh api issue write body field → BLOCKED from REST path target
rm -f "$RECORD_FILE"
out=$(run_shim "$PATH_DIR" api -X POST repos/marcusquinn/aidevops/issues -f title=test -f body="API mentions acme/longprivate" 2>&1)
rc=$?
if [[ "$rc" -eq 1 ]] && [[ ! -f "$RECORD_FILE" ]]; then
	pass "gh api issue body field leak → BLOCKED"
else
	fail "expected rc=1 for gh api field leak. rc=$rc out='$out'"
fi

# -- Test 2.15: gh api PR review endpoint local path → BLOCKED
rm -f "$RECORD_FILE"
out=$(run_shim "$PATH_DIR" api --method POST /repos/marcusquinn/aidevops/pulls/123/reviews -f body="Review path /home/example/private" 2>&1)
rc=$?
if [[ "$rc" -eq 1 ]] && [[ ! -f "$RECORD_FILE" ]]; then
	pass "gh api PR review local path → BLOCKED"
else
	fail "expected rc=1 for gh api PR review path leak. rc=$rc out='$out'"
fi

# -- Test 2.16: gh api private target write remains allowed
rm -f "$RECORD_FILE"
out=$(run_shim "$PATH_DIR" api -X POST repos/acme/longprivate/issues -f title=test -f body="Mentions acme/longprivate" 2>&1)
rc=$?
if [[ "$rc" -eq 0 ]] && [[ -f "$RECORD_FILE" ]]; then
	pass "gh api private target leak → ALLOWED"
else
	fail "expected rc=0 for private target gh api write. rc=$rc out='$out'"
fi

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
echo
if [[ $TESTS_FAILED -eq 0 ]]; then
	printf '%s%d/%d tests passed%s\n' "$GREEN" "$TESTS_RUN" "$TESTS_RUN" "$NC"
	exit 0
else
	printf '%s%d/%d tests passed (%d failed)%s\n' "$RED" $((TESTS_RUN - TESTS_FAILED)) "$TESTS_RUN" "$TESTS_FAILED" "$NC"
	exit 1
fi

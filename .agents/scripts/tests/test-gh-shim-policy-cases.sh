#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# gh shim policy test cases -- issue brief advice and dispatch label safety
# =============================================================================
# Sourced by test-gh-shim.sh after the shared hermetic harness is initialized.
#
# Usage: source "${SCRIPT_DIR}/test-gh-shim-policy-cases.sh"

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_TEST_GH_SHIM_POLICY_CASES_LOADED:-}" ]] && return 0
_TEST_GH_SHIM_POLICY_CASES_LOADED=1

# Resolve SCRIPT_DIR defensively when sourced outside the orchestrator.
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	# Pure-bash dirname replacement -- avoids external binary dependency
	_module_path="${BASH_SOURCE[0]%/*}"
	[[ "$_module_path" == "${BASH_SOURCE[0]}" ]] && _module_path="."
	SCRIPT_DIR="$(cd "$_module_path" && pwd)"
	unset _module_path
fi

# =============================================================================
# Test 25: framework-bug validation advises without blocking publication
# =============================================================================
echo ""
echo "Test 25: advisory framework-bug brief validation"

malformed_brief="$TMP/malformed-framework-bug.md"
cat >"$malformed_brief" <<'EOF'
## Description

The review reported a cleanup bug.

## Reproducer

The session inferred a cause but omitted exact evidence fields.
EOF
cp "$malformed_brief" "$TMP/malformed-framework-bug.original"

_reset_log
if "$SHIM_RUN" issue create --repo marcusquinn/aidevops \
	--title "bug(cleanup): malformed report" --label bug \
	--body-file "$malformed_brief" 2>"$TMP/malformed-file.err"; then
	if [[ -s "$STUB_GH_LOG" ]] && cmp -s "$malformed_brief" "$TMP/malformed-framework-bug.original" &&
		grep -q '\[aidevops\]\[issue-brief\]\[WARN\]' "$TMP/malformed-file.err" &&
		grep -q 'Reproducer requires' "$TMP/malformed-file.err"; then
		_pass "malformed body-file warns and reaches transport without source mutation"
	else
		_fail "malformed framework-bug body-file advisory" "argv: $(_read_argv) err: $(cat "$TMP/malformed-file.err" 2>/dev/null || true)"
	fi
else
	_fail "malformed framework-bug body-file advisory" "write was blocked"
fi

_reset_log
malformed_inline=$(<"$malformed_brief")
if "$SHIM_RUN" issue create --repo marcusquinn/aidevops \
	--title "bug(shim): malformed inline report" --body "$malformed_inline" \
	2>"$TMP/malformed-inline.err"; then
	if [[ -s "$STUB_GH_LOG" ]] && grep -q '\[aidevops\]\[issue-brief\]\[WARN\]' "$TMP/malformed-inline.err" &&
		grep -q 'Reproducer requires' "$TMP/malformed-inline.err"; then
		_pass "malformed inline body warns and reaches transport"
	else
		_fail "malformed inline framework-bug advisory" "argv: $(_read_argv) err: $(cat "$TMP/malformed-inline.err" 2>/dev/null || true)"
	fi
else
	_fail "malformed inline framework-bug advisory" "write was blocked"
fi

valid_investigation="$TMP/valid-framework-investigation.md"
cat >"$valid_investigation" <<'EOF'
## Description

The issue-create guard accepts a substantive investigation.

## Reproducer

**Symptom command**: `aidevops status`

**Actual output**: `status was inconsistent`

**Expected output**: `status was consistent`

**Causal status**: unconfirmed investigation
EOF
cp "$valid_investigation" "$TMP/valid-framework-investigation.original"

_reset_log
"$SHIM_RUN" issue create --repo marcusquinn/aidevops \
	--title "bug(status): valid investigation" --label bug \
	--body-file "$valid_investigation" 2>"$TMP/valid-investigation.err"
argv=$(_read_argv)
if [[ "$argv" == *$'issue\ncreate'* ]] && cmp -s "$valid_investigation" "$TMP/valid-framework-investigation.original"; then
	_pass "valid unconfirmed body-file passes normal signing and transport unchanged"
else
	_fail "valid unconfirmed body-file pass-through" "argv: $argv err: $(cat "$TMP/valid-investigation.err" 2>/dev/null || true)"
fi

valid_confirmed_file="$TMP/valid-confirmed-framework-bug.md"
cat >"$valid_confirmed_file" <<'EOF'
## Description

The issue-create guard accepts a proven bug report.

## Reproducer

**Symptom command**: `gh issue create --repo marcusquinn/aidevops`

**Actual output**: `the issue write reached the transport stub`

**Expected output**: `validated reports and incomplete reports can both be published`

**Causal status**: confirmed

**Production entry point**: `.agents/scripts/gh` receives the issue-create command

**Call chain**: issue creation enters the shim and validates advisorially before the native CLI

**Integrated verification**: this hermetic command reaches the transport stub after advisory validation
EOF
valid_confirmed=$(<"$valid_confirmed_file")
_reset_log
"$SHIM_RUN" issue create --repo marcusquinn/aidevops \
	--title "bug(guard): valid confirmed report" --label bug --body "$valid_confirmed" \
	2>"$TMP/valid-confirmed.err"
argv=$(_read_argv)
if [[ "$argv" == *$'issue\ncreate'* ]] && [[ "$argv" == *"<!-- aidevops:sig -->"* ]]; then
	_pass "valid confirmed inline report passes normal signing and transport"
else
	_fail "valid confirmed inline pass-through" "argv: $argv err: $(cat "$TMP/valid-confirmed.err" 2>/dev/null || true)"
fi

_reset_log
"$SHIM_RUN" issue create --repo marcusquinn/aidevops \
	--title "t28710: internal tracking brief" --label bug --body "$malformed_inline" 2>/dev/null
argv=$(_read_argv)
if [[ "$argv" == *$'issue\ncreate'* ]]; then
	_pass "tNNN internal tracking issue remains exempt"
else
	_fail "tNNN internal tracking exemption" "argv: $argv"
fi

_reset_log
"$SHIM_RUN" issue create --repo marcusquinn/aidevops \
	--title "GH#28710: internal follow-up" --label bug --body "$malformed_inline" 2>/dev/null
argv=$(_read_argv)
if [[ "$argv" == *$'issue\ncreate'* ]]; then
	_pass "GH#NNN internal tracking issue remains exempt"
else
	_fail "GH#NNN internal tracking exemption" "argv: $argv"
fi

_reset_log
"$SHIM_RUN" issue create --repo owner/repo \
	--title "bug(external): malformed report" --label bug --body "$malformed_inline" 2>/dev/null
argv=$(_read_argv)
if [[ "$argv" == *$'issue\ncreate'* ]]; then
	_pass "non-aidevops issue creation remains exempt"
else
	_fail "non-aidevops issue exemption" "argv: $argv"
fi

_reset_log
"$SHIM_RUN" issue create --repo marcusquinn/aidevops \
	--title "Request a new capability" --label enhancement --body "## Description

Add a supported capability." 2>/dev/null
argv=$(_read_argv)
if [[ "$argv" == *$'issue\ncreate'* ]]; then
	_pass "canonical non-bug issue shape remains exempt"
else
	_fail "canonical non-bug issue exemption" "argv: $argv"
fi

mv "$TMP/scripts/log-issue-helper.sh" "$TMP/scripts/log-issue-helper.sh.disabled"
_reset_log
"$SHIM_RUN" issue create --repo marcusquinn/aidevops \
	--title "bug(helper): unavailable validator" --label bug --body "$malformed_inline" 2>/dev/null
mv "$TMP/scripts/log-issue-helper.sh.disabled" "$TMP/scripts/log-issue-helper.sh"
argv=$(_read_argv)
if [[ "$argv" == *$'issue\ncreate'* ]]; then
	_pass "missing adjacent validator preserves fail-open shim behavior"
else
	_fail "missing validator fail-open behavior" "argv: $argv"
fi

_reset_log
if "$SHIM_RUN" api /repos/marcusquinn/aidevops/issues -X POST \
	-f "title=bug(rest): malformed fallback report" -F "body=@$malformed_brief" \
	-f 'labels[]=bug' 2>"$TMP/malformed-rest.err"; then
	if [[ -s "$STUB_GH_LOG" ]] && grep -q '\[aidevops\]\[issue-brief\]\[WARN\]' "$TMP/malformed-rest.err" &&
		grep -q 'Reproducer requires' "$TMP/malformed-rest.err"; then
		_pass "malformed REST fallback body warns and reaches transport"
	else
		_fail "malformed REST fallback advisory" "argv: $(_read_argv) err: $(cat "$TMP/malformed-rest.err" 2>/dev/null || true)"
	fi
else
	_fail "malformed REST fallback advisory" "write was blocked"
fi

_reset_log
resolved_output=$(SHIM_TEST_MODE=1 "$SHIM_RUN" issue create --repo marcusquinn/aidevops \
	--title "bug(test-mode): valid report" --label bug --body-file "$valid_investigation" 2>/dev/null)
if [[ "$resolved_output" == resolved_body_file=* ]] &&
	cmp -s "$valid_investigation" "$TMP/valid-framework-investigation.original"; then
	_pass "valid SHIM_TEST_MODE path remains available and source-safe"
else
	_fail "SHIM_TEST_MODE compatibility" "output: $resolved_output"
fi

# =============================================================================
# Test 26: dispatch-intent labels are mutually exclusive at transport
# =============================================================================
echo ""
echo "Test 26: dispatch-intent label normalization"

_reset_log
"$SHIM_RUN" issue create --repo owner/repo --title "Dispatch intent conflict" \
	--body "Capture the issue." --label "bug,auto-dispatch" --label no-auto-dispatch \
	2>"$TMP/dispatch-create.err"
if grep -Fxq 'no-auto-dispatch' "$STUB_GH_LOG" &&
	! grep -Eq '(^|,)auto-dispatch(,|$)' "$STUB_GH_LOG" &&
	grep -q '\[aidevops\]\[dispatch-labels\]\[NORMALIZE\]' "$TMP/dispatch-create.err"; then
	_pass "issue creation keeps the manual hold when both dispatch labels are requested"
else
	_fail "issue-create dispatch conflict normalization" "argv: $(_read_argv) err: $(cat "$TMP/dispatch-create.err" 2>/dev/null || true)"
fi

_reset_log
"$SHIM_RUN" issue edit 42 --repo owner/repo --add-label no-auto-dispatch \
	--remove-label no-auto-dispatch 2>/dev/null
if _argv_has_pair "--add-label" "no-auto-dispatch" &&
	_argv_has_pair "--remove-label" "auto-dispatch" &&
	! _argv_has_pair "--remove-label" "no-auto-dispatch"; then
	_pass "adding no-auto-dispatch removes auto-dispatch and preserves the requested hold"
else
	_fail "manual dispatch-intent issue edit" "argv: $(_read_argv)"
fi

_reset_log
"$SHIM_RUN" issue edit 42 --repo owner/repo --add-label auto-dispatch \
	--remove-label auto-dispatch 2>/dev/null
if _argv_has_pair "--add-label" "auto-dispatch" &&
	_argv_has_pair "--remove-label" "no-auto-dispatch" &&
	! _argv_has_pair "--remove-label" "auto-dispatch"; then
	_pass "adding auto-dispatch removes no-auto-dispatch and preserves automation intent"
else
	_fail "automatic dispatch-intent issue edit" "argv: $(_read_argv)"
fi

_reset_log
"$SHIM_RUN" issue edit 42 --repo owner/repo --add-label auto-dispatch \
	--add-label no-auto-dispatch 2>"$TMP/dispatch-edit.err"
if _argv_has_pair "--add-label" "no-auto-dispatch" &&
	! _argv_has_pair "--add-label" "auto-dispatch" &&
	_argv_has_pair "--remove-label" "auto-dispatch" &&
	grep -q '\[aidevops\]\[dispatch-labels\]\[NORMALIZE\]' "$TMP/dispatch-edit.err"; then
	_pass "same-command issue-edit conflict fails safe to no-auto-dispatch"
else
	_fail "issue-edit dispatch conflict normalization" "argv: $(_read_argv) err: $(cat "$TMP/dispatch-edit.err" 2>/dev/null || true)"
fi

_reset_log
"$SHIM_RUN" api /repos/owner/repo/issues -f 'title=REST dispatch conflict' \
	-f 'body=Capture the issue.' -f 'labels[]=auto-dispatch' -f 'labels[]=no-auto-dispatch' \
	2>"$TMP/dispatch-rest.err"
if _argv_has_pair "-f" "labels[]=no-auto-dispatch" &&
	! _argv_has_pair "-f" "labels[]=auto-dispatch" &&
	grep -q '\[aidevops\]\[dispatch-labels\]\[NORMALIZE\]' "$TMP/dispatch-rest.err"; then
	_pass "REST issue creation cannot transport both dispatch-intent labels"
else
	_fail "REST dispatch conflict normalization" "argv: $(_read_argv) err: $(cat "$TMP/dispatch-rest.err" 2>/dev/null || true)"
fi

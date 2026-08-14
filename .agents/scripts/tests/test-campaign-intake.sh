#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-campaign-intake.sh — contract tests for schema-v1 campaign intake.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)" || exit 1
HELPER="${REPO_ROOT}/.agents/scripts/campaign-helper.sh"

pass_count=0
fail_count=0

_pass() { printf 'PASS: %s\n' "$1"; pass_count=$((pass_count + 1)); return 0; }
_fail() { printf 'FAIL: %s\n' "$1" >&2; fail_count=$((fail_count + 1)); return 0; }

_make_repo() {
	local tmp_root="$1"
	local repo_path="${tmp_root}/repo"
	mkdir -p "${repo_path}/_campaigns/active" "${repo_path}/_campaigns/launched" "${repo_path}/_campaigns/archive"
	printf '0\n' > "${repo_path}/_campaigns/.campaign-counter"
	printf '%s\n' "$repo_path"
	return 0
}

_write_valid_intake() {
	local intake_file="$1"
	cat > "$intake_file" <<'JSON'
{
  "schema_version": 1,
  "brand": {"name": "Example Brand", "reference": "DESIGN.md"},
  "product": {"name": "Example Product", "description": "A practical product."},
  "offer": {"summary": "A 14-day trial", "terms": "New customers only."},
  "objectives": [{"metric": "Qualified leads", "target": "50"}],
  "audiences": [{"segment": "Operations teams", "buying_roles": ["Champion", "Economic buyer"], "pains": ["Manual work"], "jobs": ["Automate work"], "outcomes": ["Save time"]}],
  "positioning": {"statement": "A safer, faster workflow.", "differentiators": ["Evidence-backed"]},
  "proof": [{"claim": "Cuts review time", "evidence_reference": "research/study.md", "approval_status": "pending"}],
  "objections": ["Switching cost"], "exclusions": ["Unsupported regions"],
  "channels": ["email", "linkedin"], "dates": {"start": "2026-08-01", "end": "2026-08-31"},
  "kpis": [{"metric": "CTR", "target": "3%"}], "disclosures": ["Terms apply"],
  "sensitivity": "internal", "approvals": {"owner": "Marketing", "claims": "required", "creative": "pending"}
}
JSON
	return 0
}

test_valid_create_and_idempotency() {
	local tmp_root repo_path intake_file out
	tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/campaign-intake.XXXXXX")"
	repo_path="$(_make_repo "$tmp_root")"
	intake_file="${tmp_root}/intake.json"
	_write_valid_intake "$intake_file"
	out="$(bash "$HELPER" new "Example launch" --channel email --intake "$intake_file" --repo "$repo_path" 2>&1)" || { _fail "valid intake creates campaign: ${out}"; rm -rf "$tmp_root"; return 1; }
	if [[ -f "${repo_path}/_campaigns/active/c001-example-launch/intake.json" ]] && grep -q 'CAMPAIGN_INTAKE_JSON_V1' "${repo_path}/_campaigns/active/c001-example-launch/brief.md" && grep -q '\*\*pending:\*\* Cuts review time' "${repo_path}/_campaigns/active/c001-example-launch/brief.md"; then
		_pass "valid intake creates a versioned proof-linked brief"
	else
		_fail "valid intake did not render expected files"
	fi
	out="$(bash "$HELPER" new "Duplicate launch" --intake "$intake_file" --repo "$repo_path" 2>&1)" || { _fail "idempotent replay errors: ${out}"; rm -rf "$tmp_root"; return 1; }
	if [[ "$(cat "${repo_path}/_campaigns/.campaign-counter")" == "1" ]] && [[ "$out" == *"Campaign already exists"* ]]; then
		_pass "replaying normalized intake is idempotent"
	else
		_fail "replaying intake allocated another campaign"
	fi
	rm -rf "$tmp_root"
	return 0
}

test_invalid_input_preserves_state() {
	local tmp_root repo_path intake_file before out
	tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/campaign-intake.XXXXXX")"
	repo_path="$(_make_repo "$tmp_root")"
	intake_file="${tmp_root}/invalid.json"
	_write_valid_intake "$intake_file"
	jq 'del(.proof[0].evidence_reference)' "$intake_file" > "${intake_file}.tmp" && mv "${intake_file}.tmp" "$intake_file"
	before="$(cat "${repo_path}/_campaigns/.campaign-counter")"
	out="$(bash "$HELPER" new "Invalid launch" --intake "$intake_file" --repo "$repo_path" 2>&1 || true)"
	if [[ "$out" == *"Invalid campaign intake"* ]] && [[ "$(cat "${repo_path}/_campaigns/.campaign-counter")" == "$before" ]] && [[ ! -d "${repo_path}/_campaigns/active/c001-invalid-launch" ]]; then
		_pass "invalid intake fails before mutation"
	else
		_fail "invalid intake mutated campaign state: ${out}"
	fi
	rm -rf "$tmp_root"
	return 0
}

test_legacy_requires_explicit_migration() {
	local tmp_root repo_path intake_file out legacy_dir
	tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/campaign-intake.XXXXXX")"
	repo_path="$(_make_repo "$tmp_root")"
	legacy_dir="${repo_path}/_campaigns/active/c001-legacy"
	mkdir -p "$legacy_dir"
	printf '# Legacy brief\n' > "${legacy_dir}/brief.md"
	intake_file="${tmp_root}/intake.json"
	_write_valid_intake "$intake_file"
	out="$(bash "$HELPER" update c001-legacy --intake "$intake_file" --repo "$repo_path" 2>&1 || true)"
	if [[ "$out" == *"Migrate explicitly"* ]] && [[ ! -f "${legacy_dir}/intake.json" ]]; then
		_pass "legacy brief remains untouched until explicit migration"
	else
		_fail "legacy update did not require migration: ${out}"
	fi
	bash "$HELPER" migrate c001-legacy --intake "$intake_file" --repo "$repo_path" >/dev/null || { _fail "explicit migration failed"; rm -rf "$tmp_root"; return 1; }
	[[ -f "${legacy_dir}/intake.json" ]] && _pass "explicit migration writes schema-v1 intake" || _fail "migration omitted intake"
	rm -rf "$tmp_root"
	return 0
}

test_symlinked_campaign_writes_fail_closed() {
	local tmp_root repo_path intake_file campaign outside_campaign before out outside_drafts
	tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/campaign-intake.XXXXXX")"
	repo_path="$(_make_repo "$tmp_root")"
	intake_file="${tmp_root}/intake.json"
	_write_valid_intake "$intake_file"
	bash "$HELPER" new "Example launch" --intake "$intake_file" --repo "$repo_path" >/dev/null
	campaign="${repo_path}/_campaigns/active/c001-example-launch"
	outside_campaign="${tmp_root}/outside-campaign"
	mv "$campaign" "$outside_campaign"
	ln -s "$outside_campaign" "$campaign"
	before="$(<"${outside_campaign}/brief.md")"
	out="$(bash "$HELPER" update c001-example-launch --intake "$intake_file" --repo "$repo_path" 2>&1 || true)"
	if [[ "$out" == *"Active campaign not found"* ]] && [[ "$(<"${outside_campaign}/brief.md")" == "$before" ]]; then
		_pass "campaign update rejects a symlinked campaign directory"
	else
		_fail "campaign update followed a symlinked campaign directory: $out"
	fi
	rm "$campaign"
	mv "$outside_campaign" "$campaign"
	outside_drafts="${tmp_root}/outside-drafts"
	mkdir "$outside_drafts"
	ln -s "$outside_drafts" "${campaign}/drafts"
	out="$(bash "$HELPER" draft c001-example-launch --channel email --variant 1 --repo "$repo_path" 2>&1 || true)"
	if [[ "$out" == *"drafts directory is unsafe"* ]] && [[ -z "$(ls -A "$outside_drafts")" ]]; then
		_pass "campaign draft rejects a symlinked drafts directory"
	else
		_fail "campaign draft followed a symlinked drafts directory: $out"
	fi
	out="$(bash "$HELPER" draft c001-example-launch --channel email --variant ../escape --repo "$repo_path" 2>&1 || true)"
	if [[ "$out" == *"positive integer"* ]] && [[ ! -e "${tmp_root}/escape.md" ]]; then
		_pass "campaign draft rejects a traversal variant"
	else
		_fail "campaign draft accepted a traversal variant: $out"
	fi
	rm -rf "$tmp_root"
	return 0
}

main() {
	test_valid_create_and_idempotency
	test_invalid_input_preserves_state
	test_legacy_requires_explicit_migration
	test_symlinked_campaign_writes_fail_closed
	printf 'Results: %d passed, %d failed\n' "$pass_count" "$fail_count"
	[[ "$fail_count" -eq 0 ]]
	return $?
}

main "$@"

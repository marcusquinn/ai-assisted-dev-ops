#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-campaign-production-manifest.sh — truthful production handoff contract tests.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)" || exit 1
CAMPAIGN_HELPER="${REPO_ROOT}/.agents/scripts/campaign-helper.sh"
PRODUCTION_HELPER="${REPO_ROOT}/.agents/scripts/campaign-production-helper.py"
FANOUT_HELPER="${REPO_ROOT}/.agents/scripts/content-fanout-helper.sh"
MANIFEST_SCHEMA="${REPO_ROOT}/.agents/schemas/content-production-manifest.schema.json"
BRIEF_SCHEMA="${REPO_ROOT}/.agents/schemas/campaign-creative-brief.schema.json"

pass_count=0
fail_count=0

_pass() { printf 'PASS: %s\n' "$1"; pass_count=$((pass_count + 1)); return 0; }
_fail() { printf 'FAIL: %s\n' "$1" >&2; fail_count=$((fail_count + 1)); return 0; }

_make_repo() {
	local root="$1" repo="$1/repo"
	mkdir -p "$repo/_campaigns/active" "$repo/_campaigns/launched" "$repo/_campaigns/archive"
	printf '0\n' > "$repo/_campaigns/.campaign-counter"
	printf '%s\n' "$repo"
	return 0
}

_write_intake() {
	local path="$1"
	cat > "$path" <<'JSON'
{"schema_version":1,"brand":{"name":"Example","reference":"DESIGN.md"},"product":{"name":"Product","description":"Useful product"},"offer":{"summary":"Start trial","terms":"Terms apply"},"objectives":[{"metric":"CTR","target":"3%"}],"audiences":[{"segment":"Operators","buying_roles":["Buyer"],"pains":["Manual work"],"jobs":["Automate"],"outcomes":["Save time"]}],"positioning":{"statement":"Evidence-led automation","differentiators":["Proof first"]},"proof":[{"claim":"Cuts review time","evidence_reference":"research/study.md","approval_status":"approved"}],"objections":[],"exclusions":[],"channels":["linkedin","email"],"dates":{"start":"2026-08-01","end":"2026-08-31"},"kpis":[{"metric":"CTR","target":"3%"}],"disclosures":["Terms apply"],"sensitivity":"internal","approvals":{"owner":"Marketing","claims":"approved","creative":"required"}}
JSON
	return 0
}

test_create_replay_and_truthful_status() {
	local root repo intake manifest out
	root="$(mktemp -d "${TMPDIR:-/tmp}/campaign-production.XXXXXX")"
	repo="$(_make_repo "$root")"
	intake="$root/intake.json"
	_write_intake "$intake"
	bash "$CAMPAIGN_HELPER" new "Example" --intake "$intake" --repo "$repo" >/dev/null
	out="$(bash "$CAMPAIGN_HELPER" production create c001-example --channel linkedin --variant 2 --repo "$repo" 2>&1)" || { _fail "production create failed: $out"; rm -rf "$root"; return 1; }
	manifest="$repo/_campaigns/active/c001-example/drafts/production-manifests/linkedin-v2.json"
	if [[ -f "$manifest" ]] && jq -e '.lifecycle.status == "brief_ready" and (.outputs | length == 0) and .claims? == null and .execution.provider_route == null' "$manifest" >/dev/null && grep -q 'creative brief written' <<<"$out"; then
		_pass "creates proof-linked, unexecuted channel job"
	else
		_fail "production job did not preserve truthful status"
	fi
	out="$(bash "$CAMPAIGN_HELPER" production create c001-example --channel linkedin --variant 2 --repo "$repo" 2>&1)" || { _fail "production replay failed: $out"; rm -rf "$root"; return 1; }
	[[ "$out" == *"unchanged"* ]] && _pass "replay preserves stable variant identity" || _fail "replay rewrote the same job"
	bash "$CAMPAIGN_HELPER" production validate "$manifest" >/dev/null && _pass "validates created manifest" || _fail "created manifest fails validation"
	rm -rf "$root"
	return 0
}

test_unsupported_capability_and_invalid_promotion() {
	local root repo intake manifest out
	root="$(mktemp -d "${TMPDIR:-/tmp}/campaign-production.XXXXXX")"
	repo="$(_make_repo "$root")"
	intake="$root/intake.json"
	_write_intake "$intake"
	bash "$CAMPAIGN_HELPER" new "Example" --intake "$intake" --repo "$repo" >/dev/null
	bash "$CAMPAIGN_HELPER" production create c001-example --channel linkedin --asset-class video --capability audio --repo "$repo" >/dev/null
	manifest="$repo/_campaigns/active/c001-example/drafts/production-manifests/linkedin-v1.json"
	jq -e '.lifecycle.status == "blocked" and .execution.status == "blocked" and (.outputs | length == 0)' "$manifest" >/dev/null && _pass "unsupported capability remains explicitly blocked" || _fail "unsupported capability silently routed"
	jq '.lifecycle.status = "generated"' "$manifest" > "$manifest.invalid" && out="$(bash "$CAMPAIGN_HELPER" production validate "$manifest.invalid" 2>&1 || true)"
	[[ "$out" == *"requires verified outputs"* ]] && _pass "rejects generated status without evidence" || _fail "accepted unsupported status promotion"
	rm -rf "$root"
	return 0
}

test_fanout_manifest_ready_job_is_not_an_asset() {
	local root brief plan output job reference
	root="$(mktemp -d "${TMPDIR:-/tmp}/campaign-production.XXXXXX")"
	brief="$root/story.md"
	cat > "$brief" <<'BRIEF'
topic: Evidence-led campaign production
angle: Truthful lifecycle status
audience: Marketing owners
channels: social-linkedin, social-x
tone: practical
cta: Review the manifest
notes: Contract fixture
BRIEF
	plan="$(bash "$FANOUT_HELPER" plan "$brief" 2>&1 | grep 'Plan written:' | sed 's/.*Plan written: //')"
	output="$(bash "$FANOUT_HELPER" run "$plan" 2>&1 | grep 'Output dir:' | sed 's/.*Output dir: *//')"
	job="$output/social-linkedin/manifest-ready.job"
	reference="$output/social-x/distribution-reference.json"
	if [[ -f "$job" ]] && grep -q '^status: prompts_ready$' "$job" && grep -q '^outputs: \[\]$' "$job" && grep -q 'no asset has been generated' "$job"; then
		_pass "fan-out exports manifest-ready prompts without claiming assets"
	else
		_fail "fan-out manifest-ready job overstated lifecycle status"
	fi
	if [[ -f "$reference" ]] && jq -e '.channel == "x" and .status == "prompts_ready" and (.requires | index("queue approval"))' "$reference" >/dev/null; then
		_pass "fan-out exposes a non-executing X distribution reference"
	else
		_fail "fan-out did not expose a safe distribution reference"
	fi
	rm -rf "$root"
	return 0
}

test_symlinked_drafts_fail_closed() {
	local root repo intake campaign outside out rc=0
	root="$(mktemp -d "${TMPDIR:-/tmp}/campaign-production.XXXXXX")"
	repo="$(_make_repo "$root")"
	intake="$root/intake.json"
	_write_intake "$intake"
	bash "$CAMPAIGN_HELPER" new "Example" --intake "$intake" --repo "$repo" >/dev/null
	campaign="$repo/_campaigns/active/c001-example"
	rc=0
	out="$(bash "$CAMPAIGN_HELPER" production create ../../escape --channel linkedin --repo "$repo" 2>&1)" || rc=$?
	if [[ "$rc" -ne 0 && "$out" != *"Traceback"* ]]; then
		_pass "production creation rejects campaign-ID path traversal"
	else
		_fail "production creation accepted campaign-ID path traversal"
	fi
	rc=0
	out="$(bash "$CAMPAIGN_HELPER" production create c001-18005551234 --channel linkedin --repo "$repo" 2>&1)" || rc=$?
	if [[ "$rc" -ne 0 && "$out" != *"Traceback"* ]]; then
		_pass "production creation rejects embedded contact destinations"
	else
		_fail "production creation accepted an embedded contact destination"
	fi
	outside="$root/outside-drafts"
	mkdir -p "$outside"
	rm -rf "$campaign/drafts"
	ln -s "$outside" "$campaign/drafts"
	out="$(bash "$CAMPAIGN_HELPER" production create c001-example --channel linkedin --repo "$repo" 2>&1)" || rc=$?
	if [[ "$rc" -ne 0 && ! -e "$outside/creative-brief-v1.json" &&
		! -e "$outside/production-manifests" && "$out" != *"Traceback"* ]]; then
		_pass "production creation rejects a symlinked drafts parent"
	else
		_fail "production creation followed a symlinked drafts parent"
	fi
	local outside_campaigns="$root/outside-campaigns"
	mv "$repo/_campaigns" "$outside_campaigns"
	ln -s "$outside_campaigns" "$repo/_campaigns"
	rc=0
	out="$(bash "$CAMPAIGN_HELPER" production create c001-example --channel linkedin --repo "$repo" 2>&1)" || rc=$?
	if [[ "$rc" -ne 0 && "$out" != *"Traceback"* ]]; then
		_pass "production creation rejects a symlinked campaign plane"
	else
		_fail "production creation followed a symlinked campaign plane"
	fi
	rc=0
	out="$(python3 "$PRODUCTION_HELPER" list c001-example --repo "$repo" 2>&1)" || rc=$?
	if [[ "$rc" -ne 0 && "$out" != *"Traceback"* ]]; then
		_pass "production listing rejects a symlinked campaign plane"
	else
		_fail "production listing followed a symlinked campaign plane"
	fi
	rm -rf "$root"
	return 0
}

main() {
	python3 -m json.tool "$MANIFEST_SCHEMA" >/dev/null
	python3 -m json.tool "$BRIEF_SCHEMA" >/dev/null
	test_create_replay_and_truthful_status
	test_unsupported_capability_and_invalid_promotion
	test_fanout_manifest_ready_job_is_not_an_asset
	test_symlinked_drafts_fail_closed
	printf 'Results: %d passed, %d failed\n' "$pass_count" "$fail_count"
	[[ "$fail_count" -eq 0 ]]
	return $?
}

main "$@"

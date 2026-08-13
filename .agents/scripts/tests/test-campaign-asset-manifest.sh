#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)" || exit 1
ASSET_HELPER="${REPO_ROOT}/.agents/scripts/campaign-asset-helper.sh"
CAMPAIGN_HELPER="${REPO_ROOT}/.agents/scripts/campaign-helper.sh"

pass_count=0
fail_count=0

_pass() { printf 'PASS: %s\n' "$1"; pass_count=$((pass_count + 1)); return 0; }
_fail() { printf 'FAIL: %s\n' "$1" >&2; fail_count=$((fail_count + 1)); return 0; }

_write_intake() {
	local path="$1"
	printf '%s\n' '{"schema_version":1,"brand":{"name":"Example","reference":"DESIGN.md"},"product":{"name":"Product","description":"Useful product"},"offer":{"summary":"Start trial","terms":"Terms apply"},"objectives":[{"metric":"CTR","target":"3%"}],"audiences":[{"segment":"Operators","buying_roles":["Buyer"],"pains":["Manual work"],"jobs":["Automate"],"outcomes":["Save time"]}],"positioning":{"statement":"Evidence-led automation","differentiators":["Proof first"]},"proof":[{"claim":"Cuts review time","evidence_reference":"research/study.md","approval_status":"approved"}],"objections":[],"exclusions":[],"channels":["linkedin"],"dates":{"start":"2026-08-01","end":"2026-08-31"},"kpis":[{"metric":"CTR","target":"3%"}],"disclosures":["Terms apply"],"sensitivity":"internal","approvals":{"owner":"Marketing","claims":"approved","creative":"required"}}' > "$path"
	return 0
}

test_asset_manifest_is_v2_and_replay_fails_closed() {
	local root repo source manifest first second
	root="$(mktemp -d "${TMPDIR:-/tmp}/campaign-assets.XXXXXX")"
	repo="${root}/repo"
	mkdir -p "${repo}/_campaigns/lib/brand"
	source="${root}/logo.txt"
	printf 'original bytes\n' > "$source"
	first="$(bash "$ASSET_HELPER" add "$source" --no-preview --repo "$repo" 2>&1)" || { _fail "initial asset ingestion failed: $first"; rm -rf "$root"; return 1; }
	manifest="${repo}/_campaigns/lib/assets/manifest.json"
	if jq -e '.version == 2 and (.assets | length == 1) and .assets[0].lineage.source_asset_id == null and .assets[0].rights.license == "unverified" and .assets[0].review.status == "required"' "$manifest" >/dev/null; then
		_pass "asset ingestion writes a schema-v2 provenance record"
	else
		_fail "asset manifest did not contain required v2 defaults"
	fi
	second="$(bash "$ASSET_HELPER" add "$source" --no-preview --repo "$repo" 2>&1 || true)"
	if [[ "$second" == *"duplicate asset id"* ]] && [[ "$(jq '.assets | length' "$manifest")" == "1" ]]; then
		_pass "duplicate source identity preserves the prior manifest"
	else
		_fail "duplicate ingestion did not fail closed: $second"
	fi
	rm -rf "$root"
	return 0
}

test_campaign_launch_requires_approved_integrity_evidence() {
	local root repo intake manifest output digest out
	root="$(mktemp -d "${TMPDIR:-/tmp}/campaign-assets.XXXXXX")"
	repo="${root}/repo"
	mkdir -p "${repo}/_campaigns/active" "${repo}/_campaigns/launched" "${repo}/_campaigns/archive"
	printf '0\n' > "${repo}/_campaigns/.campaign-counter"
	intake="${root}/intake.json"
	_write_intake "$intake"
	bash "$CAMPAIGN_HELPER" new "Example" --intake "$intake" --repo "$repo" >/dev/null
	bash "$CAMPAIGN_HELPER" production create c001-example --channel linkedin --repo "$repo" >/dev/null
	out="$(bash "$CAMPAIGN_HELPER" launch c001-example --repo "$repo" 2>&1 || true)"
	if [[ "$out" == *"approved before distribution"* ]] && [[ -d "${repo}/_campaigns/active/c001-example" ]]; then
		_pass "launch blocks unapproved production work before moving campaign"
	else
		_fail "launch permitted incomplete production state: $out"
	fi
	manifest="${repo}/_campaigns/active/c001-example/drafts/production-manifests/linkedin-v1.json"
	output="${repo}/_campaigns/active/c001-example/creative/final.txt"
	mkdir -p "$(dirname "$output")"
	printf 'approved output\n' > "$output"
	digest="sha256:$(sha256sum "$output" | cut -d ' ' -f 1)"
	jq --arg digest "$digest" '.lifecycle.status = "approved" | .review = {criteria:.review.criteria,status:"approved",decision_by:"Marketing",decision_at:"2026-08-13T00:00:00Z"} | .authenticity.provenance = {source:"asset:original",recipe_sha256:$digest} | .authenticity.rights_clearance = {license:"owned",consent:"recorded",territory:"global",expires_at:null} | .outputs = [{path:"creative/final.txt",sha256:$digest,media_type:"text/plain"}]' "$manifest" > "${manifest}.new"
	mv "${manifest}.new" "$manifest"
	bash "$CAMPAIGN_HELPER" launch c001-example --repo "$repo" >/dev/null && _pass "launch accepts approved reviewed outputs with matching evidence" || _fail "launch rejected complete production evidence"
	rm -rf "$root"
	return 0
}

main() {
	test_asset_manifest_is_v2_and_replay_fails_closed
	test_campaign_launch_requires_approved_integrity_evidence
	printf 'Results: %d passed, %d failed\n' "$pass_count" "$fail_count"
	[[ "$fail_count" -eq 0 ]]
	return $?
}

main "$@"

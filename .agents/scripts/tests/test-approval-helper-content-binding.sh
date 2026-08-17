#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Regression coverage for immutable V2 approval snapshots (GH#27560).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
APPROVAL_HELPER="${SCRIPT_DIR}/../approval-helper.sh"
# shellcheck source=../approval-snapshot-v2.sh
source "${SCRIPT_DIR}/../approval-snapshot-v2.sh"

TEST_ROOT="$(mktemp -d -t approval-content-binding.XXXXXX)"
FIXTURES="${TEST_ROOT}/fixtures"
TEST_HOME="${TEST_ROOT}/home"
TESTS_RUN=0
TESTS_FAILED=0
PR_HEAD="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

cleanup() {
	rm -rf "$TEST_ROOT"
	return 0
}
trap cleanup EXIT

print_result() {
	local description="$1"
	local passed="$2"
	local detail="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$passed" -eq 0 ]]; then
		printf 'PASS %s\n' "$description"
		return 0
	fi
	printf 'FAIL %s%s\n' "$description" "${detail:+ — $detail}"
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

install_gh_stub() {
	mkdir -p "${TEST_ROOT}/bin" "$FIXTURES" "$TEST_HOME"
	cat >"${TEST_ROOT}/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == "api" ]] || exit 1
endpoint="${2:-}"
if [[ -n "${GH_FAIL_ENDPOINT:-}" && "$endpoint" == *"${GH_FAIL_ENDPOINT}"* ]]; then
	fail_count_file="${FIXTURES}/gh-fail-count"
	fail_count=0
	[[ ! -f "$fail_count_file" ]] || fail_count=$(<"$fail_count_file")
	fail_count=$((fail_count + 1))
	printf '%s\n' "$fail_count" >"$fail_count_file"
	[[ "$fail_count" -le "${GH_FAIL_ENDPOINT_AFTER:-0}" ]] || exit 1
fi
case "$endpoint" in
	user) printf '%s\n' "${GH_AUTH_USER:-maintainer}" ;;
repos/owner/repo/collaborators/trusted-collab/permission | repos/owner/repo/collaborators/maintainer/permission) printf '%s\n' "${GH_PERMISSION:-write}" ;;
repos/owner/repo/collaborators/contributor/permission) printf '%s\n' "read" ;;
repos/owner/repo/collaborators/github-actions%5Bbot%5D/permission | repos/owner/repo/collaborators/github-actions\[bot\]/permission) printf '%s\n' "none" ;;
	repos/owner/repo/issues/41) cat "${FIXTURES}/issue-41.json" ;;
repos/owner/repo/issues/41/comments*) cat "${FIXTURES}/comments-41.json" ;;
repos/owner/repo/issues/41/timeline*) cat "${FIXTURES}/timeline-41.json" ;;
repos/owner/repo/issues/42) cat "${FIXTURES}/issue-42.json" ;;
repos/owner/repo/issues/42/comments*) cat "${FIXTURES}/comments-42.json" ;;
repos/owner/repo/issues/42/timeline*) cat "${FIXTURES}/timeline-42.json" ;;
repos/owner/repo/pulls/42) cat "${FIXTURES}/pr-42.json" ;;
repos/owner/repo/pulls/42/comments*) cat "${FIXTURES}/review-comments-42.json" ;;
repos/owner/repo/pulls/42/reviews*) cat "${FIXTURES}/reviews-42.json" ;;
*) printf 'Unhandled endpoint: %s\n' "$endpoint" >&2; exit 1 ;;
esac
exit 0
EOF
	chmod +x "${TEST_ROOT}/bin/gh"
	return 0
}

write_baseline_fixtures() {
	cat >"${FIXTURES}/issue-41.json" <<'EOF'
{"id":4100,"node_id":"I_41","number":41,"user":{"id":101,"node_id":"U_101","login":"external-author","type":"User"},"author_association":"CONTRIBUTOR","created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z","title":"Reviewed issue","body":"Issue body with https://example.invalid/opaque"}
EOF
	cat >"${FIXTURES}/issue-42.json" <<'EOF'
{"id":4200,"node_id":"I_42","number":42,"user":{"id":102,"node_id":"U_102","login":"external-author","type":"User"},"author_association":"CONTRIBUTOR","created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z","title":"Reviewed PR","body":"PR body with opaque external link","pull_request":{"url":"opaque"}}
EOF
	cat >"${FIXTURES}/pr-42.json" <<EOF
{"id":4201,"node_id":"PR_42","number":42,"user":{"id":102,"node_id":"U_102","login":"external-author","type":"User"},"author_association":"CONTRIBUTOR","created_at":"2026-01-01T00:00:00Z","title":"Reviewed PR","body":"PR body with opaque external link","head":{"sha":"${PR_HEAD}","ref":"feature/external","repo":{"id":5001,"full_name":"external/fork"}},"base":{"ref":"main","repo":{"id":5000,"full_name":"owner/repo"}}}
EOF
	cat >"${FIXTURES}/comments-41.json" <<'EOF'
[[{"id":411,"node_id":"IC_411","user":{"id":103,"node_id":"U_103","login":"reviewer","type":"User"},"author_association":"MEMBER","created_at":"2026-01-01T00:01:00Z","updated_at":"2026-01-01T00:01:00Z","body":"Reviewed issue comment"}]]
EOF
	cat >"${FIXTURES}/comments-42.json" <<'EOF'
[[{"id":421,"node_id":"IC_421","user":{"id":103,"node_id":"U_103","login":"reviewer","type":"User"},"author_association":"MEMBER","created_at":"2026-01-01T00:01:00Z","updated_at":"2026-01-01T00:01:00Z","body":"Reviewed PR comment"}]]
EOF
	cat >"${FIXTURES}/timeline-41.json" <<'EOF'
[[{"id":419,"node_id":"EV_419","event":"cross-referenced","created_at":"2026-01-01T00:02:00Z","actor":{"id":103,"node_id":"U_103","login":"reviewer","type":"User"},"source":{"issue":{"id":9001,"node_id":"I_9001","number":9,"title":"Linked scope","body":"Linked body","state":"open","updated_at":"2026-01-01T00:02:00Z","repository":{"full_name":"owner/repo"},"user":{"id":104,"node_id":"U_104","login":"link-author","type":"User"}}}}]]
EOF
	cp "${FIXTURES}/timeline-41.json" "${FIXTURES}/timeline-42.json"
	cat >"${FIXTURES}/review-comments-42.json" <<'EOF'
[[{"id":422,"node_id":"RC_422","user":{"id":103,"node_id":"U_103","login":"reviewer","type":"User"},"author_association":"MEMBER","created_at":"2026-01-01T00:03:00Z","updated_at":"2026-01-01T00:03:00Z","body":"Inline review","path":"file.sh","line":7,"side":"RIGHT","commit_id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","original_commit_id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}]]
EOF
	cat >"${FIXTURES}/reviews-42.json" <<'EOF'
[[{"id":423,"node_id":"RV_423","user":{"id":103,"node_id":"U_103","login":"reviewer","type":"User"},"author_association":"MEMBER","state":"APPROVED","commit_id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","submitted_at":"2026-01-01T00:04:00Z","body":"Reviewed"}]]
EOF
	return 0
}

sign_payload() {
	local payload="$1"
	local signature_file="$2"
	printf '%s' "$payload" | ssh-keygen -Y sign -f "${TEST_ROOT}/approval.key" -n aidevops-approve -q - >"$signature_file" 2>/dev/null
	return $?
}

append_signed_comment() {
	local kind="$1"
	local number="$2"
	local issued_at="$3"
	local comment_id="${4:-$((number * 100 + 99))}"
	local source_timestamp_profile="${5:-stable}"
	local comments_file="${FIXTURES}/comments-${number}.json"
	local payload="" signature_file="" signature="" body="" updated=""
	payload=$(PATH="${TEST_ROOT}/bin:$PATH" FIXTURES="$FIXTURES" approval_snapshot_v2_payload "$kind" "$number" owner/repo "$issued_at" "" "$source_timestamp_profile") || return 1
	signature_file="${TEST_ROOT}/signature-${number}.txt"
	sign_payload "$payload" "$signature_file" || return 1
	signature=$(<"$signature_file")
	body="<!-- aidevops-signed-approval -->
\`\`\`
${payload}
\`\`\`
\`\`\`
${signature}
\`\`\`"
	updated=$(jq -c --arg body "$body" --argjson id "$comment_id" '
		.[0] += [{id:$id,node_id:("APPROVAL_" + ($id|tostring)),user:{id:1,node_id:"U_1",login:"maintainer",type:"User"},author_association:"OWNER",created_at:"2026-01-01T00:05:00Z",updated_at:"2026-01-01T00:05:00Z",body:$body}]
	' "$comments_file") || return 1
	printf '%s\n' "$updated" >"$comments_file"
	printf '%s\n' "$payload" >"${TEST_ROOT}/payload-${number}.json"
	return 0
}

replace_with_legacy_comment() {
	local number="$1"
	local payload="APPROVE:issue:owner/repo:${number}:2026-01-01T00:05:00Z"
	local signature_file="${TEST_ROOT}/legacy-signature.txt" signature="" body=""
	sign_payload "$payload" "$signature_file" || return 1
	signature=$(<"$signature_file")
	body="<!-- aidevops-signed-approval -->
\`\`\`
${payload}
\`\`\`
\`\`\`
${signature}
\`\`\`"
	jq -nc --arg body "$body" '[[{id:4199,user:{type:"User"},body:$body}]]' >"${FIXTURES}/comments-${number}.json"
	return 0
}

run_verify() {
	local kind="$1"
	local number="$2"
	local expected_head="${3:-}"
	if [[ -n "$expected_head" ]]; then
		HOME="$TEST_HOME" PATH="${TEST_ROOT}/bin:$PATH" FIXTURES="$FIXTURES" \
			AIDEVOPS_APPROVAL_PUB="${TEST_ROOT}/approval.pub" \
			"$APPROVAL_HELPER" verify "$kind" "$number" owner/repo --expect-head "$expected_head" 2>/dev/null
		return $?
	fi
	HOME="$TEST_HOME" PATH="${TEST_ROOT}/bin:$PATH" FIXTURES="$FIXTURES" \
		AIDEVOPS_APPROVAL_PUB="${TEST_ROOT}/approval.pub" \
		"$APPROVAL_HELPER" verify "$kind" "$number" owner/repo 2>/dev/null
	return $?
}

run_verify_with_authority() {
	local kind="$1"
	local number="$2"
	local auth_user="${3:-maintainer}"
	HOME="$TEST_HOME" PATH="${TEST_ROOT}/bin:$PATH" FIXTURES="$FIXTURES" \
		GH_AUTH_USER="$auth_user" AIDEVOPS_APPROVAL_PUB="${TEST_ROOT}/approval.pub" \
		"$APPROVAL_HELPER" verify "$kind" "$number" owner/repo --require-authority 2>/dev/null
	return $?
}

assert_verify() {
	local description="$1"
	local kind="$2"
	local number="$3"
	local expected_output="$4"
	local expected_rc="$5"
	local expected_head="${6:-}"
	local output="" rc=0
	output=$(run_verify "$kind" "$number" "$expected_head") || rc=$?
	if [[ "$output" == "$expected_output" && "$rc" -eq "$expected_rc" ]]; then
		print_result "$description" 0
		return 0
	fi
	print_result "$description" 1 "expected=${expected_output}/${expected_rc}, actual=${output}/${rc}"
	return 0
}

reset_and_sign() {
	local kind="$1"
	local number="$2"
	write_baseline_fixtures
	append_signed_comment "$kind" "$number" "2026-01-01T00:05:00Z"
	return $?
}

test_authority_bound_verification() {
	local output=""
	local rc=0
	local updated=""

	reset_and_sign issue 41
	output=$(run_verify_with_authority issue 41) || rc=$?
	if [[ "$output" == "VERIFIED" && "$rc" -eq 0 ]]; then
		print_result "authority-bound issue verification accepts current OWNER signer" 0
	else
		print_result "authority-bound issue verification accepts current OWNER signer" 1 "output=${output}, rc=${rc}"
	fi

	reset_and_sign pr 42
	rc=0
	output=$(run_verify_with_authority pr 42) || rc=$?
	if [[ "$output" == "VERIFIED" && "$rc" -eq 0 ]]; then
		print_result "authority-bound PR verification accepts current OWNER signer" 0
	else
		print_result "authority-bound PR verification accepts current OWNER signer" 1 "output=${output}, rc=${rc}"
	fi

	reset_and_sign issue 41
	updated=$(jq -c '.[0][-1].user.login = "other-maintainer"' "${FIXTURES}/comments-41.json")
	printf '%s\n' "$updated" >"${FIXTURES}/comments-41.json"
	rc=0
	output=$(run_verify_with_authority issue 41) || rc=$?
	if [[ "$output" == "UNTRUSTED_APPROVAL" && "$rc" -eq 7 ]]; then
		print_result "authority-bound verification rejects a different actor" 0
	else
		print_result "authority-bound verification rejects a different actor" 1 "output=${output}, rc=${rc}"
	fi

	reset_and_sign issue 41
	updated=$(jq -c '.[0][-1].user.type = "Bot"' "${FIXTURES}/comments-41.json")
	printf '%s\n' "$updated" >"${FIXTURES}/comments-41.json"
	rc=0
	output=$(run_verify_with_authority issue 41) || rc=$?
	if [[ "$output" == "UNTRUSTED_APPROVAL" && "$rc" -eq 7 ]]; then
		print_result "authority-bound verification rejects bot-authored evidence" 0
	else
		print_result "authority-bound verification rejects bot-authored evidence" 1 "output=${output}, rc=${rc}"
	fi

	reset_and_sign issue 41
	updated=$(jq -c '.[0][-1].user.login = "trusted-collab" | .[0][-1].author_association = "COLLABORATOR"' "${FIXTURES}/comments-41.json")
	printf '%s\n' "$updated" >"${FIXTURES}/comments-41.json"
	rc=0
	output=$(run_verify_with_authority issue 41 trusted-collab) || rc=$?
	if [[ "$output" == "VERIFIED" && "$rc" -eq 0 ]]; then
		print_result "authority-bound verification accepts current write collaborator" 0
	else
		print_result "authority-bound verification accepts current write collaborator" 1 "output=${output}, rc=${rc}"
	fi

	rc=0
	output=$(GH_FAIL_ENDPOINT="collaborators/trusted-collab/permission" run_verify_with_authority issue 41 trusted-collab) || rc=$?
	if [[ "$output" == "API_ERROR" && "$rc" -eq 6 ]]; then
		print_result "authority-bound verification fails closed on permission uncertainty" 0
	else
		print_result "authority-bound verification fails closed on permission uncertainty" 1 "output=${output}, rc=${rc}"
	fi
	return 0
}

file_mode() {
	local path="$1"
	if [[ "$(uname -s)" == "Darwin" ]]; then
		stat -f '%Lp' "$path"
		return $?
	fi
	stat -c '%a' "$path"
	return $?
}

test_snapshot_temp_permissions() {
	local AIDEVOPS_TEMP_DIR="${TEST_ROOT}/managed-temp-permissions"
	local temp_dir="" json_file=""
	temp_dir=$(_approval_snapshot_v2_create_temp_dir) || {
		print_result "snapshot staging uses a private managed temp directory" 1
		return 0
	}
	json_file="$temp_dir/input.json"
	_approval_snapshot_v2_write_json_file "$json_file" '{"ok":true}' || true
	if [[ "$(file_mode "$AIDEVOPS_TEMP_DIR")" == "700" && "$(file_mode "$temp_dir")" == "700" && "$(file_mode "$json_file")" == "600" ]]; then
		print_result "snapshot staging uses mode-700 directories and mode-600 files" 0
	else
		print_result "snapshot staging uses mode-700 directories and mode-600 files" 1
	fi
	rm -rf "$temp_dir"
	return 0
}

write_large_fixture_body() {
	local path="$1"
	local fill_character="$2"
	python3 - "$path" "$fill_character" <<'PY'
import json
import sys

path, fill_character = sys.argv[1:]
with open(path, encoding="utf-8") as handle:
    payload = json.load(handle)
payload[0][0]["body"] = fill_character * 2200000
with open(path, "w", encoding="utf-8") as handle:
    json.dump(payload, handle)
PY
	return $?
}

test_large_snapshots_avoid_argv_limits() {
	local AIDEVOPS_TEMP_DIR="${TEST_ROOT}/managed-temp-large"
	local payload="" issue_digest="" pr_head=""
	write_baseline_fixtures
	write_large_fixture_body "$FIXTURES/comments-41.json" i
	payload=$(AIDEVOPS_TEMP_DIR="$AIDEVOPS_TEMP_DIR" PATH="${TEST_ROOT}/bin:$PATH" FIXTURES="$FIXTURES" approval_snapshot_v2_payload issue 41 owner/repo "2026-01-01T00:05:00Z") || true
	issue_digest=$(printf '%s' "$payload" | jq -r 'select(.target.kind == "issue") | .snapshot_sha256' 2>/dev/null || true)
	if [[ "$issue_digest" =~ ^[0-9a-f]{64}$ ]] && directory_is_empty "$AIDEVOPS_TEMP_DIR"; then
		print_result "oversized issue approval avoids argv and cleans staging files" 0
	else
		print_result "oversized issue approval avoids argv and cleans staging files" 1
	fi

	write_baseline_fixtures
	write_large_fixture_body "$FIXTURES/review-comments-42.json" p
	payload=$(AIDEVOPS_TEMP_DIR="$AIDEVOPS_TEMP_DIR" PATH="${TEST_ROOT}/bin:$PATH" FIXTURES="$FIXTURES" approval_snapshot_v2_payload pr 42 owner/repo "2026-01-01T00:05:00Z") || true
	pr_head=$(printf '%s' "$payload" | jq -r '.pr.head_sha' 2>/dev/null || true)
	if [[ "$pr_head" == "$PR_HEAD" ]] && directory_is_empty "$AIDEVOPS_TEMP_DIR"; then
		print_result "oversized PR approval avoids argv and cleans staging files" 0
	else
		print_result "oversized PR approval avoids argv and cleans staging files" 1
	fi
	return 0
}

directory_is_empty() {
	local directory="$1"
	local candidate=""
	[[ -d "$directory" ]] || return 1
	for candidate in "$directory"/* "$directory"/.[!.]* "$directory"/..?*; do
		[[ -e "$candidate" || -L "$candidate" ]] && return 1
	done
	return 0
}

test_trusted_lifecycle_comments() {
	reset_and_sign pr 42
	local audit_marker="<!-- aidevops-signed-approval -->
<!-- stale-recovery-tick:0 (reset: auto-approved by maintainer — cryptographic approval verified) -->
Auto-approved: cryptographic approval verified. Stale recovery tick reset."
	local audit_comments=""
	audit_comments=$(jq -c --arg body "$audit_marker" '.[0] += [{id:4301,node_id:"IC_4301",user:{id:1,node_id:"U_1",login:"maintainer",type:"User"},author_association:"OWNER",created_at:"2026-01-01T00:06:00Z",updated_at:"2026-01-01T00:06:00Z",body:$body}]' "${FIXTURES}/comments-42.json")
	printf '%s\n' "$audit_comments" >"${FIXTURES}/comments-42.json"
	assert_verify "trusted deterministic lifecycle audit comment is excluded" pr 42 VERIFIED 0 "$PR_HEAD"

	reset_and_sign issue 41
	local claim_marker="<!-- aidevops-interactive-claim/v1 -->
<!-- ops:start -->
> Interactive session claimed by @maintainer on Linux.
> Pulse dispatch blocked via \`status:in-review\` + self-assignment.
<!-- ops:end -->
<!-- aidevops:sig -->
---
[aidevops.sh](https://aidevops.sh) v3.32.175 automated scan."
	local claim_comments=""
	local claim_writer_body="<!-- aidevops-interactive-claim/v1 -->
<!-- ops:start -->
> Interactive session claimed by @maintainer in \`linked-worktree\` on Linux.
> Pulse dispatch blocked via \`status:in-review\` + self-assignment.
<!-- ops:end -->"
	local worktree_claim_marker=""
	worktree_claim_marker=$(AIDEVOPS_SESSION_ORIGIN=interactive AIDEVOPS_SIG_CLI="Test CLI" AIDEVOPS_SIG_CLI_VERSION="1.0.0" AIDEVOPS_SIG_MODEL="test/model" AIDEVOPS_SIG_TOKENS="1" \
		"${SCRIPT_DIR}/../gh-signature-helper.sh" footer --body "$claim_writer_body") || return 1
	worktree_claim_marker="${claim_writer_body}${worktree_claim_marker}"
	if [[ "$worktree_claim_marker" != *$'<!-- ops:end -->\n<!-- aidevops:origin:interactive -->\n<!-- aidevops:sig -->'* ]]; then
		print_result "canonical claim writer produces the verifier footer contract" 1
		return 0
	fi
	print_result "canonical claim writer produces the verifier footer contract" 0
	claim_comments=$(jq -c --arg body "$claim_marker" --arg worktree_body "$worktree_claim_marker" '.[0] += [{id:4303,node_id:"IC_4303",user:{id:1,node_id:"U_1",login:"maintainer",type:"User"},author_association:"OWNER",created_at:"2026-01-01T00:06:00Z",updated_at:"2026-01-01T00:06:00Z",body:$body},{id:4306,node_id:"IC_4306",user:{id:1,node_id:"U_1",login:"maintainer",type:"User"},author_association:"OWNER",created_at:"2026-01-01T00:06:01Z",updated_at:"2026-01-01T00:06:01Z",body:$worktree_body}]' "${FIXTURES}/comments-41.json")
	printf '%s\n' "$claim_comments" >"${FIXTURES}/comments-41.json"
	assert_verify "canonical interactive claim refreshes, including worktree-qualified form, preserve approval" issue 41 VERIFIED 0

	claim_comments=$(jq -c --arg body "$claim_marker" '.[0] += [{id:4304,node_id:"IC_4304",user:{id:105,node_id:"U_105",login:"external-author",type:"User"},author_association:"CONTRIBUTOR",created_at:"2026-01-01T00:07:00Z",updated_at:"2026-01-01T00:07:00Z",body:$body}]' "${FIXTURES}/comments-41.json")
	printf '%s\n' "$claim_comments" >"${FIXTURES}/comments-41.json"
	assert_verify "external claim-shaped comment still stales issue approval" issue 41 STALE_APPROVAL 4

	reset_and_sign issue 41
	claim_comments=$(jq -c --arg body "${claim_marker}
extra trusted commentary" '.[0] += [{id:4305,node_id:"IC_4305",user:{id:1,node_id:"U_1",login:"maintainer",type:"User"},author_association:"OWNER",created_at:"2026-01-01T00:08:00Z",updated_at:"2026-01-01T00:08:00Z",body:$body}]' "${FIXTURES}/comments-41.json")
	printf '%s\n' "$claim_comments" >"${FIXTURES}/comments-41.json"
	assert_verify "trusted claim lookalike remains content-bound" issue 41 STALE_APPROVAL 4
	return 0
}

test_post_approval_linked_references() {
	reset_and_sign issue 41
	jq '.[0] += [(.[0][0] | .id = 420 | .node_id = "EV_420" | .created_at = "2026-01-01T00:06:00Z" | .source.issue.number = 10)]' \
		"${FIXTURES}/timeline-41.json" >"${FIXTURES}/timeline.tmp" && mv "${FIXTURES}/timeline.tmp" "${FIXTURES}/timeline-41.json"
	assert_verify "post-approval issue reference does not extend signed scope" issue 41 VERIFIED 0

	reset_and_sign pr 42
	jq '.[0] += [(.[0][0] | .id = 421 | .node_id = "EV_421" | .created_at = "2026-01-01T00:06:00Z" | .source.issue.number = 11)]' \
		"${FIXTURES}/timeline-42.json" >"${FIXTURES}/timeline.tmp" && mv "${FIXTURES}/timeline.tmp" "${FIXTURES}/timeline-42.json"
	assert_verify "post-approval PR reference does not extend signed scope" pr 42 VERIFIED 0 "$PR_HEAD"

	reset_and_sign issue 41
	jq '.[0] += [(.[0][0] | .id = 422 | .node_id = "EV_422" | .created_at = null | .source.issue.number = 12)]' \
		"${FIXTURES}/timeline-41.json" >"${FIXTURES}/timeline.tmp" && mv "${FIXTURES}/timeline.tmp" "${FIXTURES}/timeline-41.json"
	assert_verify "missing linked-reference timestamp fails closed" issue 41 API_ERROR 6

	reset_and_sign issue 41
	jq '.[0] += [(.[0][0] | .id = 423 | .node_id = "EV_423" | .created_at = "2026-02-30T00:06:00Z" | .source.issue.number = 13)]' \
		"${FIXTURES}/timeline-41.json" >"${FIXTURES}/timeline.tmp" && mv "${FIXTURES}/timeline.tmp" "${FIXTURES}/timeline-41.json"
	assert_verify "calendar-invalid linked-reference timestamp fails closed" issue 41 API_ERROR 6

	if PATH="${TEST_ROOT}/bin:$PATH" FIXTURES="$FIXTURES" approval_snapshot_v2_build issue 41 owner/repo "" "2026-02-30T00:06:00Z" >/dev/null 2>&1; then
		print_result "calendar-invalid approval cutoff fails closed" 1
	else
		print_result "calendar-invalid approval cutoff fails closed" 0
	fi
	return 0
}

write_locked_issue_fixture() {
	local include_tier="${1:-true}"
	local initial_status="${2:-}"
	write_baseline_fixtures
	jq --arg include_tier "$include_tier" --arg initial_status "$initial_status" '.locked = true | .active_lock_reason = "resolved" | .labels = ([{id:6,node_id:"L_6",name:"external-contributor"},{id:7,node_id:"L_7",name:"origin:interactive"},{id:8,node_id:"L_8",name:"review:approve"}] + if $include_tier == "true" then [{id:9,node_id:"L_9",name:"tier:standard"}] else [] end + if $initial_status != "" then [{id:10,node_id:"L_10",name:("status:" + $initial_status)}] else [] end) | .assignees = []' "${FIXTURES}/issue-41.json" >"${FIXTURES}/issue.tmp" && mv "${FIXTURES}/issue.tmp" "${FIXTURES}/issue-41.json"
	jq '.[0] += [{id:418,node_id:"EV_418",event:"locked",created_at:"2026-01-01T00:04:00Z",actor:{id:1,node_id:"U_1",login:"maintainer",type:"User"}}]' "${FIXTURES}/timeline-41.json" >"${FIXTURES}/timeline.tmp" && mv "${FIXTURES}/timeline.tmp" "${FIXTURES}/timeline-41.json"
	append_signed_comment issue 41 "2026-01-01T00:05:00Z" 4199
	return 0
}

append_issue_timeline_event() {
	local event_json="$1"
	jq --argjson event "$event_json" '.[0] += [$event]' "${FIXTURES}/timeline-41.json" >"${FIXTURES}/timeline.tmp" && mv "${FIXTURES}/timeline.tmp" "${FIXTURES}/timeline-41.json"
	return 0
}

test_locked_issue_tier_backfill_continuity() {
	local event_json=""
	local output=""
	local rc=0
	local tier=""
	for tier in simple standard thinking; do
		write_locked_issue_fixture false
		jq --arg tier "tier:${tier}" '.labels += [{id:10,node_id:"L_10",name:$tier}]' "${FIXTURES}/issue-41.json" >"${FIXTURES}/issue.tmp" && mv "${FIXTURES}/issue.tmp" "${FIXTURES}/issue-41.json"
		event_json=$(jq -nc --arg tier "tier:${tier}" '{id:4211,node_id:"EV_4211",event:"labeled",created_at:"2026-01-01T00:06:00Z",actor:{id:1,login:"maintainer",type:"User"},label:{name:$tier}}')
		append_issue_timeline_event "$event_json"
		assert_verify "trusted ${tier} tier backfill preserves continuously locked issue approval" issue 41 VERIFIED 0
	done

	write_locked_issue_fixture
	jq '.labels += [{id:10,node_id:"L_10",name:"tier:thinking"}]' "${FIXTURES}/issue-41.json" >"${FIXTURES}/issue.tmp" && mv "${FIXTURES}/issue.tmp" "${FIXTURES}/issue-41.json"
	append_issue_timeline_event '{"id":42111,"node_id":"EV_42111","event":"labeled","created_at":"2026-01-01T00:06:00Z","actor":{"id":1,"login":"maintainer","type":"User"},"label":{"name":"tier:thinking"}}'
	assert_verify "adding a second canonical tier remains stale" issue 41 STALE_APPROVAL 4

	write_locked_issue_fixture false
	jq '.labels += [{id:10,node_id:"L_10",name:"tier:simple"},{id:11,node_id:"L_11",name:"tier:thinking"}]' "${FIXTURES}/issue-41.json" >"${FIXTURES}/issue.tmp" && mv "${FIXTURES}/issue.tmp" "${FIXTURES}/issue-41.json"
	append_issue_timeline_event '{"id":42112,"node_id":"EV_42112","event":"labeled","created_at":"2026-01-01T00:06:00Z","actor":{"id":1,"login":"maintainer","type":"User"},"label":{"name":"tier:simple"}}'
	append_issue_timeline_event '{"id":42113,"node_id":"EV_42113","event":"labeled","created_at":"2026-01-01T00:06:01Z","actor":{"id":1,"login":"maintainer","type":"User"},"label":{"name":"tier:thinking"}}'
	assert_verify "adding multiple canonical tiers remains stale" issue 41 STALE_APPROVAL 4

	write_locked_issue_fixture false
	jq '.labels += [{id:10,node_id:"L_10",name:"tier:standard"}]' "${FIXTURES}/issue-41.json" >"${FIXTURES}/issue.tmp" && mv "${FIXTURES}/issue.tmp" "${FIXTURES}/issue-41.json"
	append_issue_timeline_event '{"id":42114,"node_id":"EV_42114","event":"labeled","created_at":"2026-01-01T00:06:00Z","actor":{"id":1,"login":"maintainer","type":"User"},"label":{"name":"tier:standard"}}'
	output=$(GH_FAIL_ENDPOINT="collaborators/maintainer/permission" run_verify issue 41) || rc=$?
	if [[ "$output" == "API_ERROR" && "$rc" -eq 6 ]]; then
		print_result "tier backfill permission uncertainty fails closed" 0
	else
		print_result "tier backfill permission uncertainty fails closed" 1 "expected=API_ERROR/6, actual=${output}/${rc}"
	fi

	write_locked_issue_fixture false
	jq '.labels += [{id:10,node_id:"L_10",name:"tier:standard"}]' "${FIXTURES}/issue-41.json" >"${FIXTURES}/issue.tmp" && mv "${FIXTURES}/issue.tmp" "${FIXTURES}/issue-41.json"
	append_issue_timeline_event '{"id":42115,"node_id":"EV_42115","event":"labeled","created_at":"2026-01-01T00:06:00Z","actor":{"id":1,"login":"maintainer","type":"User"},"label":{"name":"tier:standard"}}'
	rc=0
	rm -f "${FIXTURES}/gh-fail-count"
	output=$(GH_FAIL_ENDPOINT="issues/41/timeline" GH_FAIL_ENDPOINT_AFTER=1 run_verify issue 41) || rc=$?
	if [[ "$output" == "API_ERROR" && "$rc" -eq 6 ]]; then
		print_result "tier backfill timeline uncertainty fails closed" 0
	else
		print_result "tier backfill timeline uncertainty fails closed" 1 "expected=API_ERROR/6, actual=${output}/${rc}"
	fi

	write_locked_issue_fixture false
	jq '.labels += [{id:10,node_id:"L_10",name:"tier:standard"}]' "${FIXTURES}/issue-41.json" >"${FIXTURES}/issue.tmp" && mv "${FIXTURES}/issue.tmp" "${FIXTURES}/issue-41.json"
	append_issue_timeline_event '{"id":4212,"node_id":"EV_4212","event":"labeled","created_at":"2026-01-01T00:06:00Z","actor":{"id":2,"login":"contributor","type":"User"},"label":{"name":"tier:standard"}}'
	assert_verify "untrusted tier backfill remains stale" issue 41 STALE_APPROVAL 4

	write_locked_issue_fixture
	jq '.labels |= map(select(.name != "tier:standard"))' "${FIXTURES}/issue-41.json" >"${FIXTURES}/issue.tmp" && mv "${FIXTURES}/issue.tmp" "${FIXTURES}/issue-41.json"
	append_issue_timeline_event '{"id":4213,"node_id":"EV_4213","event":"unlabeled","created_at":"2026-01-01T00:06:00Z","actor":{"id":1,"login":"maintainer","type":"User"},"label":{"name":"tier:standard"}}'
	assert_verify "trusted tier removal remains stale" issue 41 STALE_APPROVAL 4
	return 0
}

test_locked_issue_continuity() {
	# Production regression from the first #30153 signature: approval-helper
	# performed the trusted handoff, then the narrowly scoped repository workflow
	# filled the one missing default status label under github-actions[bot].
	write_locked_issue_fixture
	jq '.assignees = [{id:1,node_id:"U_1",login:"maintainer",type:"User"}] | .labels += [{id:10,node_id:"L_10",name:"auto-dispatch"},{id:11,node_id:"L_11",name:"status:available"}] | .labels |= map(select(.name != "needs-maintainer-review"))' "${FIXTURES}/issue-41.json" >"${FIXTURES}/issue.tmp" && mv "${FIXTURES}/issue.tmp" "${FIXTURES}/issue-41.json"
	append_issue_timeline_event '{"id":426,"node_id":"EV_426","event":"labeled","created_at":"2026-01-01T00:06:00Z","actor":{"id":1,"login":"maintainer","type":"User"},"label":{"name":"auto-dispatch"}}'
	append_issue_timeline_event '{"id":427,"node_id":"EV_427","event":"unlabeled","created_at":"2026-01-01T00:06:01Z","actor":{"id":1,"login":"maintainer","type":"User"},"label":{"name":"needs-maintainer-review"}}'
	append_issue_timeline_event '{"id":428,"node_id":"EV_428","event":"assigned","created_at":"2026-01-01T00:06:02Z","actor":{"id":1,"login":"maintainer","type":"User"},"assignee":{"id":1,"login":"maintainer","type":"User"}}'
	append_issue_timeline_event '{"id":429,"node_id":"EV_429","event":"labeled","created_at":"2026-01-01T00:06:03Z","actor":{"id":41898282,"login":"github-actions[bot]","type":"Bot"},"label":{"name":"status:available"}}'
	assert_verify "exact repository default-status automation preserves first locked issue approval" issue 41 VERIFIED 0

	# GitHub documents timeline responses in chronological order; keep that API
	# contract executable because continuity authorization is sequence-sensitive.
	jq '.[0] |= reverse' "${FIXTURES}/timeline-41.json" >"${FIXTURES}/timeline.tmp" && mv "${FIXTURES}/timeline.tmp" "${FIXTURES}/timeline-41.json"
	assert_verify "out-of-order timeline data fails sequence-sensitive continuity" issue 41 STALE_APPROVAL 4

	write_locked_issue_fixture
	jq '.labels += [{id:11,node_id:"L_11",name:"status:available"}]' "${FIXTURES}/issue-41.json" >"${FIXTURES}/issue.tmp" && mv "${FIXTURES}/issue.tmp" "${FIXTURES}/issue-41.json"
	append_issue_timeline_event '{"id":4291,"node_id":"EV_4291","event":"labeled","created_at":"2026-01-01T00:06:00Z","actor":{"id":41898282,"login":"github-actions[bot]","type":"Bot"},"label":{"name":"status:available"}}'
	assert_verify "official Actions default without prior auto-dispatch fails closed" issue 41 STALE_APPROVAL 4

	write_locked_issue_fixture
	jq '.labels += [{id:10,node_id:"L_10",name:"auto-dispatch"},{id:11,node_id:"L_11",name:"status:available"}]' "${FIXTURES}/issue-41.json" >"${FIXTURES}/issue.tmp" && mv "${FIXTURES}/issue.tmp" "${FIXTURES}/issue-41.json"
	append_issue_timeline_event '{"id":4292,"node_id":"EV_4292","event":"labeled","created_at":"2026-01-01T00:06:00Z","actor":{"id":1,"login":"maintainer","type":"User"},"label":{"name":"auto-dispatch"}}'
	append_issue_timeline_event '{"id":4293,"node_id":"EV_4293","event":"labeled","created_at":"2026-01-01T00:06:01Z","actor":{"id":1,"login":"maintainer","type":"User"},"label":{"name":"status:queued"}}'
	append_issue_timeline_event '{"id":4294,"node_id":"EV_4294","event":"labeled","created_at":"2026-01-01T00:06:02Z","actor":{"id":41898282,"login":"github-actions[bot]","type":"Bot"},"label":{"name":"status:available"}}'
	assert_verify "official Actions default after another status mutation fails closed" issue 41 STALE_APPROVAL 4

	write_locked_issue_fixture
	jq '.labels += [{id:11,node_id:"L_11",name:"status:available"}]' "${FIXTURES}/issue-41.json" >"${FIXTURES}/issue.tmp" && mv "${FIXTURES}/issue.tmp" "${FIXTURES}/issue-41.json"
	append_issue_timeline_event '{"id":430,"node_id":"EV_430","event":"labeled","created_at":"2026-01-01T00:06:00Z","actor":{"id":999,"login":"github-actions[bot]","type":"Bot"},"label":{"name":"status:available"}}'
	assert_verify "lookalike Actions bot cannot preserve locked issue approval" issue 41 STALE_APPROVAL 4

	write_locked_issue_fixture
	jq '.labels += [{id:11,node_id:"L_11",name:"status:queued"}]' "${FIXTURES}/issue-41.json" >"${FIXTURES}/issue.tmp" && mv "${FIXTURES}/issue.tmp" "${FIXTURES}/issue-41.json"
	append_issue_timeline_event '{"id":431,"node_id":"EV_431","event":"labeled","created_at":"2026-01-01T00:06:00Z","actor":{"id":41898282,"login":"github-actions[bot]","type":"Bot"},"label":{"name":"status:queued"}}'
	assert_verify "official Actions bot has no generic lifecycle authority" issue 41 STALE_APPROVAL 4

	write_locked_issue_fixture
	jq '.assignees = [{id:1,node_id:"U_1",login:"maintainer",type:"User"}] | .labels += [{id:10,node_id:"L_10",name:"status:in-progress"}]' "${FIXTURES}/issue-41.json" >"${FIXTURES}/issue.tmp" && mv "${FIXTURES}/issue.tmp" "${FIXTURES}/issue-41.json"
	append_issue_timeline_event '{"id":420,"node_id":"EV_420","event":"assigned","created_at":"2026-01-01T00:06:00Z","actor":{"id":1,"login":"maintainer","type":"User"},"assignee":{"id":1,"login":"maintainer","type":"User"}}'
	append_issue_timeline_event '{"id":421,"node_id":"EV_421","event":"labeled","created_at":"2026-01-01T00:06:01Z","actor":{"id":1,"login":"maintainer","type":"User"},"label":{"name":"status:in-progress"}}'
	assert_verify "trusted allowlisted mutations preserve continuously locked issue approval" issue 41 VERIFIED 0

	local lifecycle_status=""
	local lifecycle_event_id=432
	for lifecycle_status in claimed blocked "done"; do
		write_locked_issue_fixture true available
		jq --arg status "status:${lifecycle_status}" '.labels |= map(select(.name != "status:available")) | .labels += [{id:12,node_id:"L_12",name:$status}]' "${FIXTURES}/issue-41.json" >"${FIXTURES}/issue.tmp" && mv "${FIXTURES}/issue.tmp" "${FIXTURES}/issue-41.json"
		append_issue_timeline_event "{\"id\":${lifecycle_event_id},\"node_id\":\"EV_${lifecycle_event_id}\",\"event\":\"unlabeled\",\"created_at\":\"2026-01-01T00:06:00Z\",\"actor\":{\"id\":1,\"login\":\"maintainer\",\"type\":\"User\"},\"label\":{\"name\":\"status:available\"}}"
		lifecycle_event_id=$((lifecycle_event_id + 1))
		append_issue_timeline_event "{\"id\":${lifecycle_event_id},\"node_id\":\"EV_${lifecycle_event_id}\",\"event\":\"labeled\",\"created_at\":\"2026-01-01T00:06:01Z\",\"actor\":{\"id\":1,\"login\":\"maintainer\",\"type\":\"User\"},\"label\":{\"name\":\"status:${lifecycle_status}\"}}"
		assert_verify "trusted status:${lifecycle_status} transition preserves continuously locked issue approval" issue 41 VERIFIED 0
		lifecycle_event_id=$((lifecycle_event_id + 1))
	done

	write_locked_issue_fixture
	jq '.labels = [{id:8,node_id:"L_8",name:"security"}]' "${FIXTURES}/issue-41.json" >"${FIXTURES}/issue.tmp" && mv "${FIXTURES}/issue.tmp" "${FIXTURES}/issue-41.json"
	append_issue_timeline_event '{"id":422,"node_id":"EV_422","event":"labeled","created_at":"2026-01-01T00:06:00Z","actor":{"id":1,"login":"maintainer","type":"User"},"label":{"name":"security"}}'
	assert_verify "unsupported label mutation remains stale" issue 41 STALE_APPROVAL 4

	write_locked_issue_fixture
	jq '.assignees = [{id:2,node_id:"U_2",login:"contributor",type:"User"}]' "${FIXTURES}/issue-41.json" >"${FIXTURES}/issue.tmp" && mv "${FIXTURES}/issue.tmp" "${FIXTURES}/issue-41.json"
	append_issue_timeline_event '{"id":423,"node_id":"EV_423","event":"assigned","created_at":"2026-01-01T00:06:00Z","actor":{"id":2,"login":"contributor","type":"User"},"assignee":{"id":2,"login":"contributor","type":"User"}}'
	assert_verify "contributor lifecycle mutation remains stale" issue 41 STALE_APPROVAL 4

	write_locked_issue_fixture
	jq '.assignees = [{id:1,node_id:"U_1",login:"maintainer",type:"User"}]' "${FIXTURES}/issue-41.json" >"${FIXTURES}/issue.tmp" && mv "${FIXTURES}/issue.tmp" "${FIXTURES}/issue-41.json"
	append_issue_timeline_event '{"id":424,"node_id":"EV_424","event":"unlocked","created_at":"2026-01-01T00:06:00Z","actor":{"id":1,"login":"maintainer","type":"User"}}'
	append_issue_timeline_event '{"id":425,"node_id":"EV_425","event":"locked","created_at":"2026-01-01T00:06:01Z","actor":{"id":1,"login":"maintainer","type":"User"}}'
	assert_verify "unlock and relock gap remains stale" issue 41 STALE_APPROVAL 4
	return 0
}

test_linked_source_timestamp_profiles() {
	write_baseline_fixtures
	append_signed_comment pr 42 "2026-01-01T00:05:00Z" 4298 legacy
	assert_verify "legacy linked-source V2 snapshot remains verifiable" pr 42 VERIFIED 0 "$PR_HEAD"
	jq '.[0][0].source.issue.updated_at = "2026-01-01T00:07:00Z"' "${FIXTURES}/timeline-42.json" >"${FIXTURES}/timeline.tmp" && mv "${FIXTURES}/timeline.tmp" "${FIXTURES}/timeline-42.json"
	assert_verify "legacy linked-source timestamp drift remains stale" pr 42 STALE_APPROVAL 4 "$PR_HEAD"

	reset_and_sign issue 41
	jq '.[0][0].source.issue.updated_at = "2026-01-01T00:07:00Z"' "${FIXTURES}/timeline-41.json" >"${FIXTURES}/timeline.tmp" && mv "${FIXTURES}/timeline.tmp" "${FIXTURES}/timeline-41.json"
	assert_verify "linked-source timestamp drift does not stale issue approval" issue 41 VERIFIED 0

	reset_and_sign pr 42
	jq '.[0][0].source.issue.updated_at = "2026-01-01T00:07:00Z"' "${FIXTURES}/timeline-42.json" >"${FIXTURES}/timeline.tmp" && mv "${FIXTURES}/timeline.tmp" "${FIXTURES}/timeline-42.json"
	assert_verify "linked-source timestamp drift does not stale PR approval" pr 42 VERIFIED 0 "$PR_HEAD"
	return 0
}

main() {
	install_gh_stub
	write_baseline_fixtures
	test_snapshot_temp_permissions
	test_large_snapshots_avoid_argv_limits
	ssh-keygen -t ed25519 -N '' -f "${TEST_ROOT}/approval.key" -q
	cp "${TEST_ROOT}/approval.key.pub" "${TEST_ROOT}/approval.pub"
	test_authority_bound_verification

	reset_and_sign issue 41
	assert_verify "unchanged issue V2 snapshot verifies" issue 41 VERIFIED 0
	jq '.[0][-1].body = ("audit\tcontext\n" + .[0][-1].body)' "${FIXTURES}/comments-41.json" >"${FIXTURES}/comments.tmp" && mv "${FIXTURES}/comments.tmp" "${FIXTURES}/comments-41.json"
	assert_verify "approval body preserves tabs and newlines" issue 41 VERIFIED 0
	jq '.body = "changed issue body"' "${FIXTURES}/issue-41.json" >"${FIXTURES}/issue.tmp"
	mv "${FIXTURES}/issue.tmp" "${FIXTURES}/issue-41.json"
	assert_verify "issue body drift is stale" issue 41 STALE_APPROVAL 4

	reset_and_sign pr 42
	assert_verify "unchanged PR V2 snapshot verifies exact head" pr 42 VERIFIED 0 "$PR_HEAD"
	test_linked_source_timestamp_profiles
	local original_digest="" repeated_payload="" repeated_digest=""
	original_digest=$(jq -r '.snapshot_sha256' "${TEST_ROOT}/payload-42.json")
	repeated_payload=$(PATH="${TEST_ROOT}/bin:$PATH" FIXTURES="$FIXTURES" approval_snapshot_v2_payload pr 42 owner/repo "2026-01-01T00:06:00Z")
	repeated_digest=$(jq -r '.snapshot_sha256' <<<"$repeated_payload")
	if [[ "$original_digest" != "$repeated_digest" ]]; then
		print_result "existing human approval comments remain content-bound" 0
	else
		print_result "existing human approval comments remain content-bound" 1
	fi
	append_signed_comment pr 42 "2026-01-01T00:06:00Z" 4300
	assert_verify "repeat approval verifies against the newest exact snapshot" pr 42 VERIFIED 0 "$PR_HEAD"
	test_trusted_lifecycle_comments
	test_post_approval_linked_references
	test_locked_issue_continuity
	test_locked_issue_tier_backfill_continuity

	reset_and_sign pr 42
	local marker_drift="<!-- aidevops-signed-approval --> unsigned external drift"
	local marker_comments=""
	marker_comments=$(jq -c --arg body "$marker_drift" '.[0] += [{id:4302,node_id:"IC_4302",user:{id:105,node_id:"U_105",login:"external-author",type:"User"},author_association:"CONTRIBUTOR",created_at:"2026-01-01T00:06:00Z",updated_at:"2026-01-01T00:06:00Z",body:$body}]' "${FIXTURES}/comments-42.json")
	printf '%s\n' "$marker_comments" >"${FIXTURES}/comments-42.json"
	assert_verify "unsigned marker-bearing comment drift is not excluded" pr 42 STALE_APPROVAL 4 "$PR_HEAD"

	jq '.body = "changed PR body"' "${FIXTURES}/pr-42.json" >"${FIXTURES}/pr.tmp" && mv "${FIXTURES}/pr.tmp" "${FIXTURES}/pr-42.json"
	assert_verify "PR body drift is stale" pr 42 STALE_APPROVAL 4 "$PR_HEAD"

	reset_and_sign pr 42
	jq '.[0][0].body = "edited external comment" | .[0][0].updated_at = "2026-01-01T00:07:00Z"' "${FIXTURES}/comments-42.json" >"${FIXTURES}/comments.tmp" && mv "${FIXTURES}/comments.tmp" "${FIXTURES}/comments-42.json"
	assert_verify "conversation comment drift is stale" pr 42 STALE_APPROVAL 4 "$PR_HEAD"

	reset_and_sign pr 42
	jq '.[0][0].body = "edited inline review"' "${FIXTURES}/review-comments-42.json" >"${FIXTURES}/review.tmp" && mv "${FIXTURES}/review.tmp" "${FIXTURES}/review-comments-42.json"
	assert_verify "inline review drift is stale" pr 42 STALE_APPROVAL 4 "$PR_HEAD"

	reset_and_sign pr 42
	jq '.[0][0].source.issue.title = "changed linked scope"' "${FIXTURES}/timeline-42.json" >"${FIXTURES}/timeline.tmp" && mv "${FIXTURES}/timeline.tmp" "${FIXTURES}/timeline-42.json"
	assert_verify "linked-reference drift is stale" pr 42 STALE_APPROVAL 4 "$PR_HEAD"

	reset_and_sign pr 42
	jq '.base.ref = "release"' "${FIXTURES}/pr-42.json" >"${FIXTURES}/pr.tmp" && mv "${FIXTURES}/pr.tmp" "${FIXTURES}/pr-42.json"
	assert_verify "base-target drift is stale" pr 42 STALE_APPROVAL 4 "$PR_HEAD"

	reset_and_sign pr 42
	local changed_head="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
	jq --arg head "$changed_head" '.head.sha = $head' "${FIXTURES}/pr-42.json" >"${FIXTURES}/pr.tmp" && mv "${FIXTURES}/pr.tmp" "${FIXTURES}/pr-42.json"
	assert_verify "head drift is stale" pr 42 STALE_APPROVAL 4 "$PR_HEAD"

	write_baseline_fixtures
	replace_with_legacy_comment 41
	assert_verify "V1 signature is legacy and cannot become V2 authority" issue 41 LEGACY_APPROVAL 3

	reset_and_sign issue 41
	jq '.[0][-1].body |= sub("aidevops-approval/v2"; "aidevops-approval/v3")' "${FIXTURES}/comments-41.json" >"${FIXTURES}/comments.tmp" && mv "${FIXTURES}/comments.tmp" "${FIXTURES}/comments-41.json"
	assert_verify "tampered signed payload is malformed" issue 41 MALFORMED_APPROVAL 5

	write_baseline_fixtures
	jq -nc '[[{id:"invalid",body:"<!-- aidevops-signed-approval -->"}]]' >"${FIXTURES}/comments-41.json"
	assert_verify "non-numeric approval comment ID is malformed" issue 41 MALFORMED_APPROVAL 5

	reset_and_sign issue 41
	local output="" rc=0
	output=$(GH_FAIL_ENDPOINT="timeline" run_verify issue 41) || rc=$?
	if [[ "$output" == "API_ERROR" && "$rc" -eq 6 ]]; then
		print_result "snapshot API uncertainty fails closed" 0
	else
		print_result "snapshot API uncertainty fails closed" 1 "output=${output}, rc=${rc}"
	fi

	printf '\nTests run: %d\nTests failed: %d\n' "$TESTS_RUN" "$TESTS_FAILED"
	[[ "$TESTS_FAILED" -eq 0 ]]
	return $?
}

main "$@"

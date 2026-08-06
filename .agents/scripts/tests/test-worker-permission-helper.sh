#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../worker-permission-helper.sh
source "${SCRIPT_DIR}/worker-permission-helper.sh"

test_root=$(mktemp -d)
trap 'rm -rf "$test_root"' EXIT
capture_file="${test_root}/capture.json"
export AIDEVOPS_WORKER_BLOCKER_LOG_FILE="${test_root}/blockers.jsonl"
gh_call_log="${test_root}/gh-calls.log"
posted_comment="${test_root}/permission-comment.md"

cat >"$capture_file" <<'JSON'
{
  "schema": "aidevops-permission-capture/v1",
  "issue": "123",
  "repo": "owner/repo",
  "worker_session": "issue-123",
  "requests": [{
    "request_id": "perm-source",
    "permission": "external_directory",
    "patterns": ["~/.cache/opencode/node_modules/@opencode-ai/sdk/**"],
    "tool": "read",
    "intent": "Inspect generated SDK declarations",
    "risk": {"level": "medium", "grantable": true, "reason": "external boundary"},
    "opencode": {"request_id": "oc-1", "session_id": "ses-1"}
  }, {
    "request_id": "perm-tool-discovery",
    "permission": "external_directory",
    "patterns": ["~/.qlty/bin/*"],
    "tool": "read",
    "intent": "Locate the Qlty executable",
    "risk": {"level": "medium", "grantable": true, "reason": "external boundary"},
    "opencode": {"request_id": "oc-2", "session_id": "ses-1"}
  }]
}
JSON

permission_validate_capture "$capture_file" 123 owner/repo
envelope=$(permission_build_envelope "$capture_file" 123 owner/repo issue-123 "$PWD" '{"auto_dispatch":true}')
expected_worktree_digest=$(permission_sha256_text "$PWD")
jq -e '
  .schema == "aidevops-permission-request/v1"
  and (.request_id | test("^perm-[0-9a-f]{16}$"))
  and .target.repository == "owner/repo"
  and .capabilities[0].tool == "read"
' <<<"$envelope" >/dev/null
jq -e --arg digest "$expected_worktree_digest" '.worker.worktree_sha256 == $digest' <<<"$envelope" >/dev/null
jq -e '.context.resume_auto_dispatch == true' <<<"$envelope" >/dev/null
if [[ "$envelope" == *"$PWD"* ]]; then
	printf 'permission envelope exposed the local worktree path\n' >&2
	exit 1
fi
envelope_file="${test_root}/envelope.json"
printf '%s\n' "$envelope" >"$envelope_file"
rendered_capabilities=$(permission_render_capabilities "$envelope_file")
capability_marker="- **external_directory** via \`read\`"
target_marker="**Target:** \`owner/repo#123\`"
session_marker="**Worker session:** \`issue-123\`"
if [[ "$rendered_capabilities" != *"$capability_marker"* ]]; then
	printf 'permission capability summary was empty or incomplete\n' >&2
	exit 1
fi
# shellcheck disable=SC2016 # Markdown backticks are intentional literals.
if [[ "$rendered_capabilities" != *'Routine tool discovery should use `command -v TOOL`'* ]]; then
	printf 'known tool-bin read omitted command-based recovery guidance\n' >&2
	exit 1
fi
printf '{invalid-json\n' >"${test_root}/invalid-envelope.json"
if permission_render_capabilities "${test_root}/invalid-envelope.json" >/dev/null 2>&1; then
	printf 'permission capability rendering hid a jq failure\n' >&2
	exit 1
fi

jq '.requests[0].patterns = ["/Users/private/.ssh/id_ed25519"]' "$capture_file" >"${capture_file}.unsafe"
if permission_validate_capture "${capture_file}.unsafe" 123 owner/repo; then
	printf 'unsafe private path unexpectedly passed validation\n' >&2
	exit 1
fi

repo_dir="${test_root}/repo"
git init -q "$repo_dir"
gh() {
	printf '%s\n' "$*" >>"$gh_call_log"
	printf '0\n'
	return 0
}
gh_issue_view() {
	printf '{"labels":[]}\n'
	return 0
}
gh_issue_comment() {
	local body_file="${5:-}"
	[[ -f "$body_file" ]] || return 1
	cp "$body_file" "$posted_comment"
	return $?
}
gh_issue_edit_safe() {
	return 0
}
(
	cd "$test_root"
	cmd_request --file "$capture_file" --issue 123 --repo owner/repo --session issue-123 --work-dir "$repo_dir"
)
if grep -q -- '--slurp' "$gh_call_log"; then
	printf 'permission comment lookup combined unsupported --slurp with --jq\n' >&2
	exit 1
fi
if ! grep -q -- '--paginate' "$gh_call_log"; then
	printf 'permission comment lookup did not request all pages\n' >&2
	exit 1
fi
if ! grep -Fq -- '[.[] | select' "$gh_call_log"; then
	printf 'permission comment lookup did not use page-local jq input\n' >&2
	exit 1
fi
if ! grep -Fq -- "$capability_marker" "$posted_comment"; then
	printf 'permission comment omitted the human-readable capability summary\n' >&2
	exit 1
fi
if ! grep -Fq -- "$target_marker" "$posted_comment"; then
	printf 'permission comment omitted the correlated issue target\n' >&2
	exit 1
fi
if ! grep -Fq -- "$session_marker" "$posted_comment"; then
	printf 'permission comment omitted the correlated worker session\n' >&2
	exit 1
fi
git_dir=$(git -C "$repo_dir" rev-parse --absolute-git-dir)
if [[ ! -f "${git_dir}/aidevops-permission-pending" ]]; then
	printf 'permission pending marker was not written to the target repository git directory\n' >&2
	exit 1
fi
if ! jq -e 'select(.issue == 123 and .session == "issue-123" and (.request_id | test("^perm-[0-9a-f]{16}$")))' \
	"${git_dir}/aidevops-permission-pending" >/dev/null; then
	printf 'permission pending marker omitted its issue or worker session owner\n' >&2
	exit 1
fi
jq -e 'select(.event == "permission_awaiting_approval" and .reason == "needs_maintainer_permissions" and .blocking == true
  and .issue_number == 123 and .repo_slug == "owner/repo" and .session_key == "issue-123")' \
	"$AIDEVOPS_WORKER_BLOCKER_LOG_FILE" >/dev/null

printf 'worker permission helper tests passed\n'

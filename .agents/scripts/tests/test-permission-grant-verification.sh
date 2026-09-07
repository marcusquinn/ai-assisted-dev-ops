#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

ORIGINAL_HOME="$HOME"
TEST_ROOT=$(mktemp -d)
export HOME="${TEST_ROOT}/home"
mkdir -p "$HOME/.aidevops/approval-keys/private" "$TEST_ROOT/bin"
trap 'rm -rf "$TEST_ROOT"; export HOME="$ORIGINAL_HOME"' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../approval-helper.sh
source "${SCRIPT_DIR}/approval-helper.sh"

ssh-keygen -t ed25519 -N '' -q -f "$APPROVAL_KEY"
cp "${APPROVAL_KEY}.pub" "$APPROVAL_PUB"

request_base=$(jq -cnS '{
  schema: "aidevops-permission-request/v1",
  target: {kind: "issue", repository: "owner/repo", number: 123},
  worker: {session: "issue-123", branch: "feature/auto-gh123", worktree_sha256: ("a" * 64)},
  context: {stage: "worker tool execution", changed_files: [], alternatives: "none", resume_auto_dispatch: true},
  capabilities: [{
    permission: "external_directory",
    patterns: ["~/.cache/opencode/node_modules/@opencode-ai/sdk/**"],
    tool: "read",
    intent: "Inspect generated SDK declarations",
    risk: {level: "medium", grantable: true, reason: "external boundary"},
    opencode: {request_id: "oc-1", session_id: "ses-1"}
  }],
  created_at: "2026-07-14T00:00:00Z"
}')
request_digest=$(_permission_request_digest "$request_base")
request_id="perm-${request_digest:0:16}"
request_json=$(jq -cS --arg id "$request_id" --arg digest "$request_digest" \
  '. + {request_id: $id, request_sha256: $digest}' <<<"$request_base")

issued_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
expires_at=$(_permission_grant_expiry)
payload=$(jq -cS --arg issued "$issued_at" --arg expires "$expires_at" '
  {
    schema: "aidevops-permission-grant/v1",
    authority: "worker-permissions",
    target,
    request_id,
    request_sha256,
    worker,
    capabilities,
    issued_at: $issued,
    expires_at: $expires
  }
' <<<"$request_json")
signature_file=$(mktemp)
_sign_approval_payload "$payload" "$APPROVAL_KEY" "$signature_file"
grant_comment=$(_build_permission_grant_comment "$payload" "$signature_file")
rm -f "$signature_file"
request_comment=$(printf '%s\n~~~json\n%s\n~~~\n' "$PERMISSION_REQUEST_MARKER" "$request_json")
fake_request_comment=$(printf '%s\n~~~json\n{}\n~~~\n' "$PERMISSION_REQUEST_MARKER")
fake_grant_comment=$(printf '%s\nmalformed\n' "$PERMISSION_GRANT_MARKER")

comments_file="${TEST_ROOT}/comments.json"
events_file="${TEST_ROOT}/events.json"
jq -cn --arg request "$request_comment" --arg grant "$grant_comment" \
	--arg fake_request "$fake_request_comment" --arg fake_grant "$fake_grant_comment" \
	'[[
		{id: 1, author_association: "MEMBER", body: $request},
		{id: 2, author_association: "OWNER", body: $grant},
		{id: 3, author_association: "CONTRIBUTOR", body: $fake_request},
		{id: 4, author_association: "NONE", body: $fake_grant}
	]]' >"$comments_file"
jq -cn '[[{event: "labeled", label: {name: "needs-maintainer-permissions"}}]]' >"$events_file"

cat >"${TEST_ROOT}/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
args="$*"
if [[ "$args" == *"/events?"* ]]; then
	printf 'event\n' >>"$PERMISSION_GH_CALLS_FILE"
	call_count=$(wc -l <"$PERMISSION_GH_CALLS_FILE" | tr -d ' ')
	case "${PERMISSION_GH_MODE:-success}" in
	events-fail-first)
		[[ "$call_count" -gt 1 ]] || exit 75
		;;
	events-always-fail)
		exit 75
		;;
	events-malformed)
		printf '{malformed\n'
		exit 0
		;;
	esac
  command cat "$PERMISSION_EVENTS_FILE"
else
  command cat "$PERMISSION_COMMENTS_FILE"
fi
STUB
chmod +x "${TEST_ROOT}/bin/gh"
export PATH="${TEST_ROOT}/bin:${PATH}"
export PERMISSION_COMMENTS_FILE="$comments_file"
export PERMISSION_EVENTS_FILE="$events_file"
export PERMISSION_GH_CALLS_FILE="${TEST_ROOT}/gh-calls"
export AIDEVOPS_PERMISSION_HISTORY_RETRY_DELAY=0

verification=$(cmd_verify_permissions issue 123 owner/repo)
[[ "$verification" == "VERIFIED" ]] || {
	printf 'valid permission grant did not verify: %s\n' "$verification" >&2
	exit 1
}

# shellcheck source=../pulse-dispatch-core.sh
source "${SCRIPT_DIR}/pulse-dispatch-core.sh"

: >"$PERMISSION_GH_CALLS_FILE"
export PERMISSION_GH_MODE="events-fail-first"
if _dispatch_permission_history_requires_grant 123 owner/repo; then
	printf 'dispatch remained blocked after a transient permission-history failure: %s\n' "${_DISPATCH_PERMISSION_VERIFY_RESULT:-}" >&2
	exit 1
fi
[[ "$_DISPATCH_PERMISSION_VERIFY_RESULT" == "VERIFIED" ]]
[[ "$(wc -l <"$PERMISSION_GH_CALLS_FILE" | tr -d ' ')" == "2" ]]

: >"$PERMISSION_GH_CALLS_FILE"
export PERMISSION_GH_MODE="events-always-fail"
if ! _dispatch_permission_history_requires_grant 123 owner/repo; then
	printf 'dispatch was allowed after repeated permission-history failures\n' >&2
	exit 1
fi
[[ "$_DISPATCH_PERMISSION_VERIFY_RESULT" == "API_ERROR" ]]
[[ "$(wc -l <"$PERMISSION_GH_CALLS_FILE" | tr -d ' ')" == "2" ]]

export PERMISSION_GH_MODE="events-malformed"
if ! _dispatch_permission_history_requires_grant 123 owner/repo; then
	printf 'dispatch was allowed after malformed permission-history data\n' >&2
	exit 1
fi
[[ "$_DISPATCH_PERMISSION_VERIFY_RESULT" == "API_ERROR" ]]

export PERMISSION_GH_MODE="success"
if _dispatch_permission_history_requires_grant 123 owner/repo; then
	printf 'dispatch remained blocked despite a matching valid grant: %s\n' "${_DISPATCH_PERMISSION_VERIFY_RESULT:-}" >&2
	exit 1
fi
[[ "$_DISPATCH_PERMISSION_VERIFY_RESULT" == "VERIFIED" ]]

jq '.[0] = [.[0][0], .[0][2], .[0][3]]' "$comments_file" >"${comments_file}.pending"
mv "${comments_file}.pending" "$comments_file"
if ! _dispatch_permission_history_requires_grant 123 owner/repo; then
	printf 'dispatch was allowed after the signed grant disappeared\n' >&2
	exit 1
fi
[[ "$_DISPATCH_PERMISSION_VERIFY_RESULT" == "NO_APPROVAL" ]]

printf 'permission grant verification tests passed\n'

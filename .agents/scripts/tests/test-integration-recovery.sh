#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# Mock-only recovery/ownership regression coverage (GH#31305).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../pulse-merge-feedback-finalizer.sh
source "${SCRIPT_DIR}/pulse-merge-feedback-finalizer.sh"

local_owner=1
mock_comments='[]'
mock_metadata='{"state":"open","assignees":[{"login":"owner"}],"labels":[{"name":"status:in-review"}]}'
_interactive_claim_fence_blocks_dispatch() { return "$local_owner"; }
gh() {
	case "$*" in
	*comments*) printf '%s\n' "$mock_comments" ;;
	*) printf '%s\n' "$mock_metadata" ;;
	esac
	return 0
}
_feedback_route_owner_allows 31265 owner/repo
local_owner=0
if _feedback_route_owner_allows 31265 owner/repo; then
	printf 'FAIL: live local repair owner was displaced\n' >&2
	exit 1
fi
local_owner=1
mock_comments=$(jq -nc '{user:{login:"owner"}, author_association:"OWNER", created_at:(now | todateiso8601), body:"Interactive session claimed by @owner"} | [.]')
if _feedback_route_owner_allows 31265 owner/repo; then
	printf 'FAIL: remote interactive repair owner was displaced\n' >&2
	exit 1
fi
mock_comments=$(jq '.[0].author_association = "NONE"' <<<"$mock_comments")
_feedback_route_owner_allows 31265 owner/repo
mock_comments=$(jq '.[0].author_association = "OWNER" | .[0].user.login = "foreign"' <<<"$mock_comments")
_feedback_route_owner_allows 31265 owner/repo
printf 'PASS: local and remote owners fenced; foreign claims do not manufacture ownership\n'

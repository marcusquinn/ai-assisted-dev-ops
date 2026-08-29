#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
SCRIPTS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)" || exit 1
CALLS_FILE="$(mktemp -t gh-wrapper-repo-alias.XXXXXX)"
trap 'rm -f "$CALLS_FILE"' EXIT

# shellcheck source=../shared-constants.sh
source "${SCRIPTS_DIR}/shared-constants.sh"
# shellcheck source=../shared-gh-wrappers.sh
source "${SCRIPTS_DIR}/shared-gh-wrappers.sh"

privacy_guard_public_write() {
	local repo="$1"
	local text="$2"
	printf '<%s> <%s>\n' "$repo" "$text" >>"$CALLS_FILE"
	if [[ -n "$repo" ]]; then
		return 0
	fi
	return 1
}

failures=0

if [[ "$(_gh_extract_repo_from_args -R owner/repo --title example)" == "owner/repo" ]]; then
	printf 'PASS: safe-edit extraction accepts -R\n'
else
	printf 'FAIL: safe-edit extraction accepts -R\n'
	failures=$((failures + 1))
fi

: >"$CALLS_FILE"
if _gh_guard_public_write_args -R public/repo --title "Public title" &&
	grep -Fq '<public/repo>' "$CALLS_FILE"; then
	printf 'PASS: privacy guard receives -R repository\n'
else
	printf 'FAIL: privacy guard receives -R repository\n'
	failures=$((failures + 1))
fi

: >"$CALLS_FILE"
if _gh_guard_public_write_args -R --title "Missing repository"; then
	printf 'FAIL: missing -R value fails closed\n'
	failures=$((failures + 1))
else
	printf 'PASS: missing -R value fails closed\n'
fi

ensure_origin_labels_exist() {
	local repo="$1"
	printf '<origin-labels> <%s>\n' "$repo" >>"$CALLS_FILE"
	return 0
}

: >"$CALLS_FILE"
_ORIGIN_LABELS_ENSURED=""
_ensure_origin_labels_for_args -R labels/repo --title example
if grep -Fq '<origin-labels> <labels/repo>' "$CALLS_FILE"; then
	printf 'PASS: origin-label provisioning accepts -R\n'
else
	printf 'FAIL: origin-label provisioning accepts -R\n'
	failures=$((failures + 1))
fi

gh() {
	printf '<gh> %s\n' "$*" >>"$CALLS_FILE"
	case "$*" in
	*'/pulls'*) printf 'https://github.com/rest/repo/pull/7\n' ;;
	*) printf 'https://github.com/rest/repo/issues/42\n' ;;
	esac
	return 0
}

_rest_api_call() {
	local request_class="$1"
	shift
	printf '<rest:%s> %s\n' "$request_class" "$*" >>"$CALLS_FILE"
	if [[ "$request_class" == "read" ]]; then
		printf '{"labels":[],"assignees":[]}\n'
	fi
	return 0
}

: >"$CALLS_FILE"
if _rest_issue_create -R rest/repo --title "REST issue" >/dev/null &&
	grep -Fq '/repos/rest/repo/issues' "$CALLS_FILE"; then
	printf 'PASS: REST issue create accepts -R\n'
else
	printf 'FAIL: REST issue create accepts -R\n'
	failures=$((failures + 1))
fi

: >"$CALLS_FILE"
if _rest_issue_comment 42 -R rest/repo --body "REST comment" >/dev/null &&
	grep -Fq '/repos/rest/repo/issues/42/comments' "$CALLS_FILE"; then
	printf 'PASS: REST issue comment accepts -R\n'
else
	printf 'FAIL: REST issue comment accepts -R\n'
	failures=$((failures + 1))
fi

: >"$CALLS_FILE"
if _rest_issue_edit 42 -R rest/repo --title "REST edit" &&
	grep -Fq '/repos/rest/repo/issues/42' "$CALLS_FILE"; then
	printf 'PASS: REST issue edit accepts -R\n'
else
	printf 'FAIL: REST issue edit accepts -R\n'
	failures=$((failures + 1))
fi

: >"$CALLS_FILE"
if _rest_issue_edit_preserving_deltas 42 -R rest/repo --add-label status:in-review &&
	grep -Fq '/repos/rest/repo/issues/42/labels' "$CALLS_FILE"; then
	printf 'PASS: REST preserving edit accepts -R\n'
else
	printf 'FAIL: REST preserving edit accepts -R\n'
	failures=$((failures + 1))
fi

: >"$CALLS_FILE"
if _rest_pr_create -R rest/repo --title "REST PR" --head feature --base main >/dev/null &&
	grep -Fq '/repos/rest/repo/pulls' "$CALLS_FILE"; then
	printf 'PASS: REST PR create accepts -R\n'
else
	printf 'FAIL: REST PR create accepts -R\n'
	failures=$((failures + 1))
fi

exit "$failures"

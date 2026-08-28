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

exit "$failures"

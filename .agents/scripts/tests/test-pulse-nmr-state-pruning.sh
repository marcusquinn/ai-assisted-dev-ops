#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
NMR_SCRIPT="${SCRIPT_DIR}/../pulse-nmr-approval.sh"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

export AIDEVOPS_NMR_REVALIDATION_STATE_FILE="${TEST_ROOT}/nmr-state.json"
export AIDEVOPS_NMR_STATE_PRUNE_LIMIT=2
export NMR_SCRIPT_DIR="${SCRIPT_DIR}/.."
export LOGFILE="${TEST_ROOT}/pulse.log"

gh() {
	local command="$1"
	local path="$2"
	[[ "$command" == "api" ]] || return 1
	case "$path" in
	repos/owner/repo/issues/1) printf '{"state":"closed"}\n' ;;
	repos/owner/repo/issues/2) printf '{"state":"open"}\n' ;;
	repos/owner/repo/issues/3) return 1 ;;
	*) return 1 ;;
	esac
	return 0
}

# shellcheck source=../pulse-nmr-approval.sh
source "$NMR_SCRIPT"

cat >"$AIDEVOPS_NMR_REVALIDATION_STATE_FILE" <<'JSON'
{"entries":{"invalid-key":{"status":"keep"},"owner/repo#1":{"status":"closed"},"owner/repo#2":{"status":"open"},"owner/repo#3":{"status":"unknown"}}}
JSON

_nmr_prune_closed_revalidation_state
_nmr_prune_closed_revalidation_state

if ! jq -e '
  (.entries["owner/repo#1"] == null) and
  (.entries["owner/repo#2"].status == "open") and
  (.entries["owner/repo#3"].status == "unknown") and
  (.entries["invalid-key"].status == "keep") and
  (.prune_cursor | type == "string")
' "$AIDEVOPS_NMR_REVALIDATION_STATE_FILE" >/dev/null; then
	printf 'FAIL: pruning did not remove only authoritatively closed state\n' >&2
	exit 1
fi

printf 'PASS: NMR state pruning removes only authoritatively closed entries\n'

#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)" || exit 1
REPO_DIR="$(cd "${SCRIPT_DIR}/../../.." && pwd)" || exit 1
HELPER="${REPO_DIR}/.agents/scripts/full-loop-helper.sh"
TMP=$(mktemp -d 2>/dev/null || mktemp -d -t full-loop-worktree-gh-shim)
trap 'rm -rf "$TMP"' EXIT

STALE_DIR="${TMP}/runtime-bundles/stale/agents/scripts"
NATIVE_DIR="${TMP}/native"
STALE_LOG="${TMP}/stale.log"
NATIVE_LOG="${TMP}/native.log"
mkdir -p "$STALE_DIR" "$NATIVE_DIR"

cat >"${STALE_DIR}/gh" <<'EOF'
#!/usr/bin/env bash
printf 'stale shim selected\n' >>"$STALE_GH_LOG"
exit 0
EOF
chmod +x "${STALE_DIR}/gh"

cat >"${NATIVE_DIR}/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$NATIVE_GH_LOG"
printf '%s\n' '{"state":"OPEN","isDraft":false,"reviewDecision":"","headRefOid":"fixture-head","headRefName":"fixture"}'
exit 0
EOF
chmod +x "${NATIVE_DIR}/gh"

set +e
STALE_GH_LOG="$STALE_LOG" NATIVE_GH_LOG="$NATIVE_LOG" \
	PATH="${STALE_DIR}:${NATIVE_DIR}:${PATH}" \
	"$HELPER" pre-merge-gate 42 fixture/repo >/dev/null 2>&1
helper_status=$?
set -e

if [[ -s "$STALE_LOG" ]]; then
	printf 'FAIL: inherited stale gh shim handled a full-loop helper call\n' >&2
	exit 1
fi
if [[ ! -s "$NATIVE_LOG" ]]; then
	printf 'FAIL: worktree gh shim did not forward the helper call to native gh (status=%s)\n' "$helper_status" >&2
	exit 1
fi

printf 'PASS: worktree full-loop helper resolves its sibling gh shim before an inherited stale shim\n'
exit 0

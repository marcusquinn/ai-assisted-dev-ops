#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../pulse-dispatch-core.sh
source "${SCRIPT_DIR}/pulse-dispatch-core.sh"

blocked='{"labels":[{"name":"status:available"},{"name":"needs-maintainer-permissions"}]}'
allowed='{"labels":[{"name":"status:available"},{"name":"auto-dispatch"}]}'

_dispatch_waiting_for_maintainer_permission "$blocked"
if _dispatch_waiting_for_maintainer_permission "$allowed"; then
	printf 'permission gate blocked metadata without the dedicated label\n' >&2
	exit 1
fi

TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
approval_helper="${TEST_ROOT}/approval-helper.sh"
cat >"$approval_helper" <<'STUB'
#!/usr/bin/env bash
printf 'VERIFIED\n'
STUB
chmod +x "$approval_helper"
cp "${SCRIPT_DIR}/pulse-dispatch-core.sh" "${TEST_ROOT}/pulse-dispatch-core.sh"
for dependency in disk-capacity-lib.sh pulse-dispatch-dedup-layers.sh pulse-dispatch-large-file-gate.sh \
	pulse-dispatch-worker-launch.sh dispatch-dedup-footprint.sh pre-dispatch-eligibility-helper.sh \
	pulse-stats-helper.sh dispatch-stage-instrument.sh shared-gh-collaborator-permission.sh; do
	ln -s "${SCRIPT_DIR}/${dependency}" "${TEST_ROOT}/${dependency}"
done
unset _PULSE_DISPATCH_CORE_LOADED

gh() {
	local count_file="${TEST_ROOT}/gh-calls"
	local call_count=0
	[[ -f "$count_file" ]] && call_count=$(<"$count_file")
	call_count=$((call_count + 1))
	printf '%s\n' "$call_count" >"$count_file"
	if [[ "$call_count" -eq 1 ]]; then
		return 1
	fi
	printf '[[{"event":"labeled","label":{"name":"needs-maintainer-permissions"}}]]\n'
	return 0
}

if (source "${TEST_ROOT}/pulse-dispatch-core.sh"; _dispatch_permission_history_requires_grant 123 owner/repo); then
	printf 'permission-history gate blocked after a transient API failure recovered\n' >&2
	exit 1
fi
[[ "$(<"${TEST_ROOT}/gh-calls")" -eq 2 ]]

gh() {
	return 1
}
unset _PULSE_DISPATCH_CORE_LOADED
if ! (source "${TEST_ROOT}/pulse-dispatch-core.sh"; _dispatch_permission_history_requires_grant 123 owner/repo); then
	printf 'permission-history gate failed open after repeated API failures\n' >&2
	exit 1
fi

printf 'pulse dispatch permission-gate tests passed\n'

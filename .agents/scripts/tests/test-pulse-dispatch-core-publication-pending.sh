#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Verifies the direct-dispatch defence-in-depth guard for issues whose planning
# files have not yet reached the default branch.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
CORE_SCRIPT="${SCRIPT_DIR}/../pulse-dispatch-core.sh"

extract_helper() {
	awk '/^_has_publication_pending_label\(\) \{/,/^}$/ { print }' "$CORE_SCRIPT"
}

helper_src=$(extract_helper)
if [[ -z "$helper_src" ]]; then
	printf 'FAIL missing _has_publication_pending_label in %s\n' "$CORE_SCRIPT" >&2
	exit 1
fi
# shellcheck disable=SC1090 # The exact helper is extracted from the source under test.
eval "$helper_src"

pending='{"labels":[{"name":"auto-dispatch"},{"name":"status:available"},{"name":"publication:pending"}]}'
published='{"labels":[{"name":"auto-dispatch"},{"name":"status:available"}]}'

if _has_publication_pending_label "$pending"; then
	printf 'PASS direct-dispatch guard blocks publication:pending\n'
else
	printf 'FAIL direct-dispatch guard did not block publication:pending\n' >&2
	exit 1
fi

if _has_publication_pending_label "$published"; then
	printf 'FAIL direct-dispatch guard blocked published task\n' >&2
	exit 1
fi
printf 'PASS direct-dispatch guard permits published task\n'

if _has_publication_pending_label '{not-json'; then
	printf 'PASS direct-dispatch guard fails closed on malformed metadata\n'
else
	printf 'FAIL direct-dispatch guard failed open on malformed metadata\n' >&2
	exit 1
fi

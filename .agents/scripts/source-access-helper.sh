#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

if [[ "$EUID" -eq 0 ]]; then
	printf '%s\n' \
		'[ERROR] Refusing to execute the user-managed source-access helper as root.' \
		'Use the installed root-owned broker under /etc/aidevops/source-access.' >&2
	exit 1
fi

# Only an explicitly named human ceremony may cross the privilege boundary.
# Metadata preparation and ordinary update/status operations never invoke sudo.
case "${1:-}" in
approve-bundle | cancel-proposal)
	if [[ ! -t 0 || ! -t 1 ]]; then
		printf '%s\n' '[ERROR] Bundle approval/cancellation requires an attached human terminal; cached sudo is not used.' >&2
		exit 1
	fi
	# #aidevops:trust-boundary -- execute only the installed immutable broker,
	# never the user-managed Python/helper closure under elevated privileges.
	exec /usr/bin/sudo -k /usr/bin/python3 -I -B /etc/aidevops/source-access/source-access-helper.py "$@"
	;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec /usr/bin/python3 -I -B "${SCRIPT_DIR}/source-access-helper.py" "$@"

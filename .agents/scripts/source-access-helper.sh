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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "${SCRIPT_DIR}/source-access-helper.py" "$@"

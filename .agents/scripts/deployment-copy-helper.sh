#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
PYTHON_HELPER="${SCRIPT_DIR}/deployment-copy-helper.py"

if [[ ! -f "$PYTHON_HELPER" ]]; then
	printf 'ERROR: deployment-copy Python helper is unavailable\n' >&2
	exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
	printf 'ERROR: python3 is required for audited deployment copies\n' >&2
	exit 1
fi

exec python3 "$PYTHON_HELPER" "$@"

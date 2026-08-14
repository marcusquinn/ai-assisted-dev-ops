#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# performance-helper.sh — shell entry point for the Python performance plane CLI.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/shared-constants.sh"

if ! command -v python3 >/dev/null 2>&1; then
	print_error "python3 is required for the marketing performance plane"
	exit 1
fi

exec python3 "${SCRIPT_DIR}/performance-helper.py" "$@"

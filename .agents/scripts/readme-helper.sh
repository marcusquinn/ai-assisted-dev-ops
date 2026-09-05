#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Counts/checks/updates use one tracked-source inventory, never raw file totals.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
source "$SCRIPT_DIR/shared-constants.sh"

main() {
	python3 "$SCRIPT_DIR/readme_inventory.py" "$@"
	return $?
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	main "$@"
fi

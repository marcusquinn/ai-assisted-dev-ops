#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
EXPECTED_VERSION="0.643.0"
WORKFLOWS=(
	".github/workflows/code-quality.yml"
	".github/workflows/qlty-new-file-gate.yml"
	".github/workflows/qlty-regression.yml"
	".github/workflows/ratchet-post-merge.yml"
)

for workflow in "${WORKFLOWS[@]}"; do
	workflow_path="${ROOT}/${workflow}"
	install_count=$(grep -c 'uses: qltysh/qlty-action/install@' "$workflow_path" || true)
	[[ "$install_count" -gt 0 ]]
	grep -Fq "QLTY_VERSION: \"${EXPECTED_VERSION}\"" "$workflow_path"
	printf 'PASS %s pins %s Qlty installer step(s) to %s\n' "$workflow" "$install_count" "$EXPECTED_VERSION"
done

for workflow in ".github/workflows/code-quality.yml" ".github/workflows/qlty-regression.yml"; do
	workflow_path="${ROOT}/${workflow}"
	grep -Fq "QLTY_CLI_VERSION: \"${EXPECTED_VERSION}\"" "$workflow_path"
	printf 'PASS %s keeps installer and validator versions aligned at %s\n' "$workflow" "$EXPECTED_VERSION"
done

exit 0

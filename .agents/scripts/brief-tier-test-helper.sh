#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Historical model replay benchmark entry point.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
# shellcheck source=shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh"

node_bin="${AIDEVOPS_NODE_BIN:-node}"
if ! command -v "$node_bin" >/dev/null 2>&1 ||
	! "$node_bin" -e 'process.exit(Number(process.versions.node.split(".")[0]) >= 20 ? 0 : 1)' \
		>/dev/null 2>&1; then
	printf 'Error: Node.js 20+ is required for model replay benchmarks\n' >&2
	exit 1
fi

exec "$node_bin" "${SCRIPT_DIR}/model-replay-benchmark.mjs" "$@"

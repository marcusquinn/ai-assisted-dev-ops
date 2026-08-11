#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Bounded evaluator for the scoped OpenCode Linux-headless compatibility pin.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=shared-constants.sh
source "$SCRIPT_DIR/shared-constants.sh"

usage() {
	printf 'Usage: opencode-pin-canary.sh status [--json]\n'
	printf '       opencode-pin-canary.sh canary [candidate-version]\n'
}

pin_age_days() {
	python3 - "$OPENCODE_PIN_INTRODUCED_DATE" <<'PY'
from datetime import date
import sys
print((date.today() - date.fromisoformat(sys.argv[1])).days)
PY
}

cmd_status() {
	local format="${1:-text}"
	local registry_latest="unknown"
	registry_latest=$(npm view opencode-ai version 2>/dev/null || printf 'unknown')
	local installed="not-installed"
	if command -v opencode >/dev/null 2>&1; then
		installed=$(opencode --version 2>/dev/null | command head -n 1 || printf 'unknown')
	fi
	local age
	age=$(pin_age_days)
	if [[ "$format" == "--json" ]]; then
		printf '{"installed":"%s","pinned":"%s","registry_latest":"%s","plugin_tested":"%s","pin_age_days":%s,"reason":"%s","platform":"%s","runtime_mode":"%s","introduced":"%s","last_canary_date":"%s","last_canary_result":"%s","review_deadline":"%s"}\n' \
			"$installed" "$OPENCODE_PINNED_VERSION" "$registry_latest" "$OPENCODE_PLUGIN_TESTED_VERSION" "$age" "$OPENCODE_PIN_REASON" \
			"$OPENCODE_PIN_PLATFORM" "$OPENCODE_PIN_RUNTIME_MODE" "$OPENCODE_PIN_INTRODUCED_DATE" \
			"$OPENCODE_PIN_LAST_CANARY_DATE" "$OPENCODE_PIN_LAST_CANARY_RESULT" "$OPENCODE_PIN_REVIEW_DEADLINE"
		return 0
	fi
	printf 'installed=%s pinned=%s registry-latest=%s pin-age=%sd\n' "$installed" "$OPENCODE_PINNED_VERSION" "$registry_latest" "$age"
	printf 'scope=%s/%s plugin-tested=%s last-canary=%s (%s) review-deadline=%s\n' \
		"$OPENCODE_PIN_PLATFORM" "$OPENCODE_PIN_RUNTIME_MODE" "$OPENCODE_PLUGIN_TESTED_VERSION" "$OPENCODE_PIN_LAST_CANARY_DATE" \
		"$OPENCODE_PIN_LAST_CANARY_RESULT" "$OPENCODE_PIN_REVIEW_DEADLINE"
}

cmd_canary() {
	local candidate="${1:-}"
	[[ "$(uname -s)" == "$OPENCODE_PIN_PLATFORM" ]] || {
		printf 'INCONCLUSIVE: candidate canary requires %s\n' "$OPENCODE_PIN_PLATFORM" >&2
		return 2
	}
	command -v npm >/dev/null 2>&1 || {
		printf 'INCONCLUSIVE: npm is unavailable\n' >&2
		return 2
	}
	if [[ -z "$candidate" || "$candidate" == "latest" ]]; then
		candidate=$(npm view opencode-ai version 2>/dev/null || true)
	fi
	[[ "$candidate" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.-]+)?$ ]] || {
		printf 'INCONCLUSIVE: invalid candidate version %s\n' "${candidate:-empty}" >&2
		return 2
	}
	if [[ "$candidate" == "$OPENCODE_PINNED_VERSION" ]]; then
		printf 'SKIP: registry candidate equals pin %s\n' "$candidate"
		return 0
	fi

	local temp_parent="${AIDEVOPS_TEMP_DIR:-${HOME}/.aidevops/.agent-workspace/tmp}"
	mkdir -p "$temp_parent"
	local candidate_root
	candidate_root=$(mktemp -d "${temp_parent}/opencode-pin-canary-XXXXXX")
	trap 'rm -rf "$candidate_root"' RETURN
	npm install --ignore-scripts --no-audit --no-fund --prefix "$candidate_root" "opencode-ai@${candidate}" >/dev/null
	local candidate_bin="$candidate_root/node_modules/.bin/opencode"
	[[ -x "$candidate_bin" ]] || {
		printf 'INCONCLUSIVE: candidate binary was not installed\n' >&2
		return 2
	}
	printf 'Evaluating OpenCode %s with isolated Linux-headless canary\n' "$candidate"
	AIDEVOPS_OPENCODE_PIN_CANDIDATE_EVALUATION=1 OPENCODE_BIN="$candidate_bin" \
		"$SCRIPT_DIR/headless-runtime-helper.sh" canary --role worker
	printf 'PASS: OpenCode %s passed the Linux-headless compatibility canary\n' "$candidate"
}

case "${1:-}" in
status) cmd_status "${2:-}" ;;
canary) cmd_canary "${2:-latest}" ;;
*) usage >&2; exit 2 ;;
esac

#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)" || exit 1
HELPER="${REPO_ROOT}/.agents/scripts/content-calendar-helper.sh"
TEST_HOME="$(mktemp -d "${TMPDIR:-/tmp}/calendar-safety.XXXXXX")"
trap 'rm -rf "${TEST_HOME}"' EXIT

HOME="${TEST_HOME}" bash "${HELPER}" add "Safety fixture" >/dev/null
HOME="${TEST_HOME}" bash "${HELPER}" schedule 1 2026-08-20 x --time 12:30 >/dev/null
if HOME="${TEST_HOME}" bash "${HELPER}" schedule 1 2026-08-20 x --time 12:30 >/dev/null 2>&1; then
	printf 'FAIL: duplicate schedule was accepted\n' >&2
	exit 1
fi
if HOME="${TEST_HOME}" bash "${HELPER}" schedule 1 2026-02-30 x >/dev/null 2>&1; then
	printf 'FAIL: invalid calendar date was accepted\n' >&2
	exit 1
fi
if HOME="${TEST_HOME}" bash "${HELPER}" schedule 1 2026-08-20 x --time 25:00 >/dev/null 2>&1; then
	printf 'FAIL: invalid time was accepted\n' >&2
	exit 1
fi
DB="${TEST_HOME}/.aidevops/.agent-workspace/work/content-calendar/calendar.db"
sqlite3 "${DB}" 'PRAGMA table_info(schedule);' | grep -q '|operation_state|'
printf 'PASS: content calendar validates dates, times, duplicate schedules, and bridge migration\n'

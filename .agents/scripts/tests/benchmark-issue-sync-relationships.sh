#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMP_PARENT="${AIDEVOPS_TEMP_DIR:-${HOME}/.aidevops/.agent-workspace/tmp}"
mkdir -p "$TEMP_PARENT"
BENCHMARK_DIR=$(mktemp -d "${TEMP_PARENT}/relationship-benchmark.XXXXXX")

cleanup() {
	rm -rf "$BENCHMARK_DIR"
	return 0
}
trap cleanup EXIT

stdout_file="${BENCHMARK_DIR}/stdout.log"
resource_file="${BENCHMARK_DIR}/resources.log"
started_at=$(date +%s)
benchmark_rc=0
platform=$(uname -s)

if [[ "$platform" == "Darwin" ]]; then
	AIDEVOPS_BENCHMARK_OUTPUT=1 /usr/bin/time -l \
		bash "${TEST_DIR}/test-issue-sync-relationship-resume.sh" \
		>"$stdout_file" 2>"$resource_file" || benchmark_rc=$?
	peak_rss=$(awk '/maximum resident set size/ { print int($1 / 1024); exit }' "$resource_file")
else
	AIDEVOPS_BENCHMARK_OUTPUT=1 /usr/bin/time -v \
		bash "${TEST_DIR}/test-issue-sync-relationship-resume.sh" \
		>"$stdout_file" 2>"$resource_file" || benchmark_rc=$?
	peak_rss=$(awk -F: '/Maximum resident set size/ { gsub(/[[:space:]]/, "", $2); print $2; exit }' "$resource_file")
fi

[[ "$benchmark_rc" -eq 0 ]] || {
	printf 'FAIL: relationship benchmark fixture exited %d\n' "$benchmark_rc" >&2
	return "$benchmark_rc" 2>/dev/null || exit "$benchmark_rc"
}
[[ "$peak_rss" =~ ^[0-9]+$ ]] || {
	printf 'FAIL: relationship benchmark did not capture peak RSS\n' >&2
	exit 1
}

finished_at=$(date +%s)
printf 'Benchmark: candidates=800 wall_seconds=%d peak_rss_kb=%d\n' \
	"$((finished_at - started_at))" "$peak_rss"
grep -m1 '^Edges:' "$stdout_file"
grep -m1 '^Tasks:' "$stdout_file"
grep -m1 '^Workset:' "$stdout_file"
grep -m1 '^Timing:' "$stdout_file"
printf 'PASS: 800-task relationship benchmark captured resources and progress\n'

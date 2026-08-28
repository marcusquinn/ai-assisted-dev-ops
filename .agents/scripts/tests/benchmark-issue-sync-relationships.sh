#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMP_PARENT="${AIDEVOPS_TEMP_DIR:-${HOME}/.aidevops/.agent-workspace/tmp}"
mkdir -p "$TEMP_PARENT"
BENCHMARK_DIR=$(mktemp -d "${TEMP_PARENT}/relationship-benchmark.XXXXXX")

# shellcheck source=../issue-sync-helper.sh
source "${TEST_DIR}/../issue-sync-helper.sh"

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

graph_edges=""
for ((node = 1; node <= 18; node++)); do
	graph_edges="${graph_edges}t${node}|t$((node + 1))"$'\n'
	graph_edges="${graph_edges}t${node}|t$((node + 1))"$'\n'
done
for ((node = 1; node <= 9; node++)); do
	graph_edges="${graph_edges}t${node}|t$((node + 10))"$'\n'
done
metrics_file="${BENCHMARK_DIR}/traversal-metrics.log"
if _declared_dependency_path_exists "t1" "t999" "$graph_edges" "" "$metrics_file"; then
	printf 'FAIL: unreachable branching-graph target was reported reachable\n' >&2
	exit 1
fi
traversal_metrics=$(<"$metrics_file")
[[ "$traversal_metrics" == "nodes=19 edges=27 traversed=27" ]] || {
	printf 'FAIL: branching traversal was not bounded to unique graph elements: %s\n' "$traversal_metrics" >&2
	exit 1
}
if _declared_dependency_path_exists "t1" "t999" "$graph_edges" $'t1\n'; then
	printf 'FAIL: a pre-seen traversal start was revisited\n' >&2
	exit 1
fi
if ! _declared_dependency_path_exists "t1" "t19" "$graph_edges" $'t19\n'; then
	printf 'FAIL: a reachable pre-seen target lost target-before-seen semantics\n' >&2
	exit 1
fi
if ! _declared_dependency_path_exists "t5" "t5" "$graph_edges" $'t5\n'; then
	printf 'FAIL: identical start and target lost target-before-seen semantics\n' >&2
	exit 1
fi
printf 'Traversal: %s\n' "$traversal_metrics"
printf 'PASS: 800-task relationship benchmark captured resources and progress\n'

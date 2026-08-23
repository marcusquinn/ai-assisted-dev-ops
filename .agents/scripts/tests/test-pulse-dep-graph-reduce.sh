#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEP_GRAPH="${SCRIPT_DIR}/../pulse-dep-graph.sh"

# shellcheck source=../pulse-dep-graph.sh
source "$DEP_GRAPH"

# shellcheck disable=SC2016 # JSON fixture is intentionally literal.
fixture='[
  {"number":1,"title":"t1: root","body":"","labels":[],"state":"OPEN"},
  {"number":2,"title":"t2.1: child","body":"**Blocked by:** `t1`, #1\nDefer until next cycle","labels":[],"state":"OPEN"},
  {"number":3,"title":"Not a task","body":"blocked-by:t2.1,t999","labels":[{"name":"blocked-by:#2"}],"state":"OPEN"},
  {"number":4,"title":"to0aaaaaaaaaaaaaaaaaaaaaaaaa-12.3: namespaced","body":"BLOCKED BY t1","labels":[],"state":"CLOSED"},
  {"number":5,"title":"t5: self edge","body":"blocked-by:t5,#5","labels":[{"name":"blocked-by:t1"}],"state":"OPEN"},
  {"number":6,"title":"t6: malformed body","body":"blocked-by:t001","labels":[],"state":"OPEN"},
  {"number":7,"title":"t7: malformed label","body":"","labels":[{"name":"blocked-by:t001"}],"state":"OPEN"},
  {"number":"8","title":"t8: string number","body":"paused: awaiting decision","labels":[{"name":"blocked-by:#2"}],"state":"open"},
  {"number":"invalid","title":"t9: ignored","body":"blocked-by:t1","labels":[],"state":"OPEN"},
  {"number":10,"title":"t10: closed hold","body":"on hold","labels":[],"state":"CLOSED"},
  {"number":11,"title":"t1: duplicate task mapping","body":"blocked-by:#2,#2","labels":[],"state":"OPEN"},
  {"number":12,"title":"t12: adjacent brief paths","body":"blocked-by:todo/tasks/t1-brief.md,todo/tasks/t2.1-brief.md","labels":[],"state":"OPEN"}
]'

reference=$(_dep_graph_build_repo_data_reference "$fixture" | jq -S -c .)
reduced=$(_dep_graph_reduce_issues_json "$fixture" | jq -S -c .)

if [[ "$reference" != "$reduced" ]]; then
	printf 'FAIL dependency graph jq reduce differs from reference\n' >&2
	printf 'reference=%s\nreduced=%s\n' "$reference" "$reduced" >&2
	exit 1
fi

if [[ "${PULSE_DEP_GRAPH_BENCHMARK:-0}" == "1" ]]; then
	large_fixture=$(jq -cn '[range(1; 501) as $n | {
		number: $n,
		title: ("t" + ($n | tostring) + ": benchmark"),
		body: (if $n > 1 then "blocked-by:t1,#1" else "" end),
		labels: [],
		state: "OPEN"
	}]')
	reference_start=$(date +%s)
	_dep_graph_build_repo_data_reference "$large_fixture" >/dev/null
	reference_seconds=$(($(date +%s) - reference_start))
	reduced_start=$(date +%s)
	_dep_graph_reduce_issues_json "$large_fixture" >/dev/null
	reduced_seconds=$(($(date +%s) - reduced_start))
	printf 'BENCHMARK issues=500 reference_seconds=%s reduce_seconds=%s\n' "$reference_seconds" "$reduced_seconds"
fi

printf 'PASS dependency graph jq reduce matches reference\n'
exit 0

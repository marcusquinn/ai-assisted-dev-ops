#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="${SCRIPT_DIR}/../brief-tier-test-helper.sh"
SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT

pass() {
	local name="$1"
	printf 'PASS: %s\n' "$name"
	return 0
}

fail() {
	local name="$1"
	printf 'FAIL: %s\n' "$name" >&2
	return 1
}

make_case() {
	local number="$1"
	local profile="$2"
	local class="$3"
	local directory="${SANDBOX}/corpus/case-${number}"
	mkdir -p "$directory/base"
	printf 'broken\n' >"${directory}/base/value.txt"
	tar -cf "${directory}/base.tar" -C "${directory}/base" .
	printf 'Repair value.txt.\n' >"${directory}/prompt.md"
	# shellcheck disable=SC2016
	printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail' '[[ "$(<value.txt)" == "fixed" ]]' >"${directory}/verifier.sh"
	chmod +x "${directory}/verifier.sh"
	printf '%s\n' 'diff --git a/value.txt b/value.txt' 'index 4b4f325..f48c54f 100644' '--- a/value.txt' '+++ b/value.txt' '@@ -1 +1 @@' '-broken' '+fixed' >"${directory}/gold.patch"
	local archive_hash=""
	archive_hash=$(sha256sum "${directory}/base.tar" | cut -d' ' -f1)
	jq -n --arg profile "$profile" --arg class "$class" --arg archive "$archive_hash" \
		'{profile:$profile,experiment_class:$class,base_tree:"tree-1",base_tree_sha256:$archive,harness_policy:"v1",framework_version:"3.32.286",runtime_version:"opencode-1.18.19",pass_to_pass:[]}' >"${directory}/case.json"
	"$HELPER" replay qualify --case "$directory" >/dev/null
	return 0
}

mkdir -p "${SANDBOX}/corpus"
printf '{"cases":[' >"${SANDBOX}/corpus/index.json"
for number in 1 2 3 4 5 6 7 8 9; do
	profile="aidevops"
	[[ "$number" -gt 3 ]] && profile="wordpress-plugin"
	[[ "$number" -gt 6 ]] && profile="nextjs"
	class="autonomous"
	[[ $((number % 2)) -eq 0 ]] && class="prescriptive"
	make_case "$number" "$profile" "$class"
	[[ "$number" -gt 1 ]] && printf ',' >>"${SANDBOX}/corpus/index.json"
	printf '"case-%s"' "$number" >>"${SANDBOX}/corpus/index.json"
done
printf ']}\n' >>"${SANDBOX}/corpus/index.json"

printf '%s\n' '[{"model":"openai/example","tier":"standard","effort":"high","success_probability":0.7}]' >"${SANDBOX}/models.json"
"$HELPER" replay dry-run --corpus "${SANDBOX}/corpus" --models "${SANDBOX}/models.json" --budget quick --output "${SANDBOX}/plan" >/dev/null

[[ "$(jq '.executions | length' "${SANDBOX}/plan/plan.json")" -eq 9 ]] || fail "quick suite has nine executions"
pass "quick suite has nine executions"
[[ "$(jq -r '.provider_calls' "${SANDBOX}/plan/report.json")" == false ]] || fail "dry-run makes no provider calls"
pass "dry-run makes no provider calls"
[[ "$(jq '[.predictions[].experiment_class] | unique | length' "${SANDBOX}/plan/predictions.json")" -eq 2 ]] || fail "experiment classes remain explicit"
pass "experiment classes remain explicit"

printf 'tamper\n' >>"${SANDBOX}/corpus/case-1/prompt.md"
if "$HELPER" replay validate --case "${SANDBOX}/corpus/case-1" >/dev/null 2>&1; then
	fail "tampered immutable case fails closed"
fi
pass "tampered immutable case fails closed"

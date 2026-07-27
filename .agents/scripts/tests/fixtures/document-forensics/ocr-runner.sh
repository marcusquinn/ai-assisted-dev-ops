#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

fixture_field() {
	local field="$1"
	local file="$2"
	awk -F '=' -v wanted="$field" '$1 == wanted { value = $2 } END { print value }' "$file"
	return 0
}

image="$1"
provider="$2"
text_output="$3"
evidence_output="$4"
kind=$(fixture_field KIND "$image")
page=$(fixture_field PAGE "$image")
transform=$(fixture_field TRANSFORM "$image")
confidence=10

case "$kind" in
mirrored)
	[[ "$transform" == "flip-horizontal" ]] && confidence=94
	[[ "$transform" == "original" ]] && confidence=18
	;;
rotated)
	[[ "$transform" == "rotate-90" ]] && confidence=95
	[[ "$transform" == "original" ]] && confidence=16
	;;
normal-scan)
	[[ "$transform" == "original" ]] && confidence=91
	;;
mixed)
	if [[ "$page" -eq 2 ]] && [[ "$transform" == "flip-horizontal" ]]; then
		confidence=93
	elif [[ "$page" -eq 3 ]] && [[ "$transform" == "rotate-180" ]]; then
		confidence=96
	elif [[ "$transform" == "original" ]]; then
		confidence=14
	fi
	;;
sparse)
	[[ "$transform" == "flip-horizontal" ]] && confidence=30
	[[ "$transform" == "original" ]] && confidence=10
	;;
partial)
	if [[ "$transform" == "rotate-270" ]]; then
		exit 7
	fi
	[[ "$transform" == "original" ]] && confidence=88
	;;
mixed-failure)
	exit 7
	;;
original-fails)
	if [[ "$transform" == "original" ]]; then
		exit 7
	fi
	[[ "$transform" == "flip-horizontal" ]] && confidence=95
	;;
esac

if [[ "$kind" == "sparse" ]]; then
	printf 'x y\n' >"$text_output"
else
	printf 'Readable forensic fixture text for %s page %s using %s with enough words for conservative evidence.\n' \
		"$kind" "$page" "$transform" >"$text_output"
fi
jq -n --argjson confidence "$confidence" --arg fixture "$kind" \
	--arg transform "$transform" --arg provider "$provider" \
	'{confidence: $confidence, fixture: $fixture, transform: $transform, provider: $provider}' \
	>"$evidence_output"

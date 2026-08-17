#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Route qualified session-miner candidates through explicit repository roles.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)" || exit 1
FRAMEWORK_SLUG="marcusquinn/aidevops"
FRAMEWORK_HELPER="${SESSION_MINER_FRAMEWORK_HELPER:-${SCRIPT_DIR}/framework-issue-helper.sh}"
CONTRIBUTOR_HELPER="${SESSION_MINER_CONTRIBUTOR_HELPER:-${SCRIPT_DIR}/contributor-insight-helper.sh}"

_sma_log() {
	local level="$1"
	local message="$2"
	printf '[session-miner-actuation] %s: %s\n' "$level" "$message" >&2
	return 0
}

_sma_hash() {
	local value="$1"
	local digest=""
	if command -v shasum >/dev/null 2>&1; then
		digest=$(printf '%s' "$value" | shasum -a 256 | awk '{print $1}') || return 1
	elif command -v sha256sum >/dev/null 2>&1; then
		digest=$(printf '%s' "$value" | sha256sum | awk '{print $1}') || return 1
	else
		_sma_log ERROR "SHA-256 support is required for stable candidate fingerprints"
		return 1
	fi
	printf '%s' "$digest"
	return 0
}

_sma_role_for_slug() {
	local repos_file="$1"
	local slug="$2"
	jq -r --arg slug "$slug" '
		[.initialized_repos[]? | select(.slug == $slug)]
		| if length == 1 then .[0].role // "" else "" end
	' "$repos_file" 2>/dev/null
	return $?
}

_sma_known_fingerprint() {
	local known_json="$1"
	local fingerprint="$2"
	printf '%s' "$known_json" | jq -e --arg fingerprint "$fingerprint" 'index($fingerprint) != null' >/dev/null 2>&1
	return $?
}

_sma_target_is_known() {
	local target_file="$1"
	local repo_path="$2"
	[[ -n "$target_file" && "$target_file" != /* && "$target_file" != *".."* ]] || return 1
	[[ -n "$repo_path" && -d "$repo_path" ]] || return 1
	git -C "$repo_path" ls-files --error-unmatch "$target_file" >/dev/null 2>&1
	return $?
}

_sma_candidate_body() {
	local display_text="$1"
	local target_file="$2"
	local category="$3"
	local support="$4"
	local basis="$5"
	local fingerprint="$6"
	cat <<EOF
## What

Review and implement this de-identified recurring framework guidance candidate:

> ${display_text}

## Evidence

- Target file: \`${target_file}\`
- Category: \`${category}\`
- Qualification: \`${basis}\`
- Distinct-session support: ${support}
- Stable fingerprint: \`${fingerprint}\`

## Implementation

- Inspect the target and nearby guidance before editing.
- Deduplicate against equivalent existing guidance.
- Keep always-loaded guidance concise and move detailed procedure to a referenced workflow when appropriate.

## Verification

- Run \`.agents/scripts/linters-local.sh --changed\`.
- Verify the resulting instruction is unambiguous and does not duplicate an existing rule.

<!-- aidevops:session-miner-fingerprint=${fingerprint} -->
EOF
	return 0
}

_sma_qualified_candidates() {
	local signals_file="$1"
	jq -c '
		.instruction_candidates // {}
		| to_entries[]
		| .key as $target
		| .value[]
		| select(
			(.requires_judgment == false) and
			((.qualification_basis == "recurring") or (.qualification_basis == "explicit_persistence")) and
			((.fingerprint // "") | length) > 0 and
			((.display_text // "") | length) > 0
		)
		| . + {target_file: $target}
	' "$signals_file" 2>/dev/null
	return $?
}

_sma_emit_result() {
	local status="$1"
	local selected="$2"
	local fingerprints="$3"
	local error_class="${4:-}"
	jq -cn \
		--arg status "$status" \
		--argjson selected "$selected" \
		--argjson fingerprints "$fingerprints" \
		--arg error_class "$error_class" '
		{
			status: $status,
			selected: $selected,
			fingerprints: $fingerprints,
			error_class: (if $error_class == "" then null else $error_class end)
		}
	'
	return 0
}

cmd_maintainer() {
	local signals_file="$1"
	local repos_file="$2"
	local known_fingerprints="$3"
	local role="" framework_path=""
	role=$(_sma_role_for_slug "$repos_file" "$FRAMEWORK_SLUG") || role=""
	if [[ "$role" != "maintainer" ]]; then
		_sma_emit_result deferred 0 '[]' "unknown_framework_role"
		return 1
	fi
	[[ -x "$FRAMEWORK_HELPER" ]] || {
		_sma_emit_result failed 0 '[]' "framework_helper_unavailable"
		return 1
	}
	framework_path=$(jq -r --arg slug "$FRAMEWORK_SLUG" '
		[.initialized_repos[]? | select(.slug == $slug and .role == "maintainer")]
		| if length == 1 then .[0].path // "" else "" end
	' "$repos_file" 2>/dev/null) || framework_path=""
	[[ -n "$framework_path" && -d "$framework_path" ]] || {
		_sma_emit_result deferred 0 '[]' "framework_path_unavailable"
		return 1
	}

	local receipts='[]'
	local selected=0
	local candidate="" candidates=""
	candidates=$(_sma_qualified_candidates "$signals_file") || {
		_sma_emit_result failed 0 '[]' "candidate_validation_failed"
		return 1
	}
	while IFS= read -r candidate; do
		[[ -n "$candidate" ]] || continue
		local target_file="" raw_fingerprint="" fingerprint="" display_text=""
		local category="" support=0 basis="" title="" body=""
		target_file=$(printf '%s' "$candidate" | jq -r '.target_file') || return 1
		_sma_target_is_known "$target_file" "$framework_path" || continue
		raw_fingerprint=$(printf '%s' "$candidate" | jq -r '.fingerprint') || return 1
		fingerprint=$(_sma_hash "${target_file}:${raw_fingerprint}") || return 1
		if _sma_known_fingerprint "$known_fingerprints" "$fingerprint"; then
			continue
		fi
		display_text=$(printf '%s' "$candidate" | jq -r '.display_text') || return 1
		category=$(printf '%s' "$candidate" | jq -r '.category // "general"') || return 1
		support=$(printf '%s' "$candidate" | jq -r '.support // 0') || return 1
		basis=$(printf '%s' "$candidate" | jq -r '.qualification_basis') || return 1
		title="session-miner: review ${category} guidance (${fingerprint:0:12})"
		body=$(_sma_candidate_body "$display_text" "$target_file" "$category" "$support" "$basis" "$fingerprint") || return 1
		local publication_result=""
		publication_result=$("$FRAMEWORK_HELPER" log --title "$title" --body "$body" --label enhancement --tier standard) || {
			_sma_emit_result failed "$selected" "$receipts" "maintainer_publication_failed"
			return 1
		}
		if ! printf '%s\n' "$publication_result" | grep -Eq '^status=(created|duplicate)$'; then
			_sma_emit_result failed "$selected" "$receipts" "maintainer_publication_unconfirmed"
			return 1
		fi
		receipts=$(printf '%s' "$receipts" | jq -c --arg fingerprint "$fingerprint" '. + [$fingerprint] | unique') || return 1
		selected=$((selected + 1))
	done <<<"$candidates"

	_sma_emit_result healthy "$selected" "$receipts"
	return 0
}

cmd_contributor() {
	local signals_file="$1"
	local repos_file="$2"
	local slug="$3"
	local metadata=""
	metadata=$(jq -c --arg slug "$slug" '
		[.initialized_repos[]? | select(.slug == $slug)]
		| if length == 1 then .[0] else {} end
	' "$repos_file" 2>/dev/null) || metadata="{}"
	if [[ $(printf '%s' "$metadata" | jq -r '.role // ""') != "contributor" ]]; then
		_sma_emit_result deferred 0 '[]' "unknown_contributor_role"
		return 1
	fi
	if [[ $(printf '%s' "$metadata" | jq -r '(.local_only // false) or (.mirror_upstream // false)') == "true" ]]; then
		_sma_emit_result deferred 0 '[]' "private_contributor_target"
		return 1
	fi
	[[ -x "$CONTRIBUTOR_HELPER" ]] || {
		_sma_emit_result failed 0 '[]' "contributor_helper_unavailable"
		return 1
	}

	local result=""
	result=$(REPOS_JSON="$repos_file" "$CONTRIBUTOR_HELPER" file --json "$signals_file" "$slug") || {
		_sma_emit_result deferred 0 '[]' "contributor_publication_failed"
		return 1
	}
	if ! printf '%s' "$result" | jq -e '.status == "healthy"' >/dev/null 2>&1; then
		_sma_emit_result deferred 0 '[]' "contributor_publication_unconfirmed"
		return 1
	fi
	printf '%s\n' "$result"
	return 0
}

main() {
	local mode="${1:-}"
	[[ $# -gt 0 ]] && shift
	local signals_file="" repos_file="" slug="" known_fingerprints='[]'
	while [[ $# -gt 0 ]]; do
		local option="$1"
		case "$option" in
		--signals)
			[[ $# -ge 2 ]] || return 2
			signals_file="$2"
			shift 2
			;;
		--repos)
			[[ $# -ge 2 ]] || return 2
			repos_file="$2"
			shift 2
			;;
		--slug)
			[[ $# -ge 2 ]] || return 2
			slug="$2"
			shift 2
			;;
		--known-fingerprints)
			[[ $# -ge 2 ]] || return 2
			known_fingerprints="$2"
			shift 2
			;;
		*)
			_sma_log ERROR "Unknown argument: ${option}"
			return 2
			;;
		esac
	done

	[[ -f "$signals_file" && -f "$repos_file" ]] || {
		_sma_log ERROR "--signals and --repos must name readable files"
		return 2
	}
	printf '%s' "$known_fingerprints" | jq -e 'type == "array"' >/dev/null 2>&1 || return 2
	case "$mode" in
	maintainer) cmd_maintainer "$signals_file" "$repos_file" "$known_fingerprints" ;;
	contributor)
		[[ -n "$slug" ]] || return 2
		cmd_contributor "$signals_file" "$repos_file" "$slug"
		;;
	*)
		_sma_log ERROR "Usage: session-miner-actuation-helper.sh {maintainer|contributor} --signals FILE --repos FILE [--slug OWNER/REPO]"
		return 2
		;;
	esac
}

main "$@"

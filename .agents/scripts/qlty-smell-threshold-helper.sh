#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# qlty-smell-threshold-helper.sh — absolute qlty smell ratchet gate (GH#18775)

set -u

SCRIPT_NAME=$(basename "$0")
UNKNOWN_VALUE="unknown"
SCAN_GIT_BIN=""
SCAN_TMP=""
SCAN_DIR=""
THRESHOLD_VALUE=""
THRESHOLD_QLTY_BIN=""
THRESHOLD_QLTY_VERSION=""
THRESHOLD_DIAG_FILE=""
THRESHOLD_WARMUP_FILE=""
THRESHOLD_THIRD_FILE=""
THRESHOLD_CACHE_DIR=""

log() {
	local _msg="$1"
	printf '[%s] %s\n' "$SCRIPT_NAME" "$_msg" >&2
	return 0
}

find_qlty() {
	if command -v qlty >/dev/null 2>&1; then
		command -v qlty
		return 0
	fi
	if [ -x "${HOME:-}/.qlty/bin/qlty" ]; then
		printf '%s/.qlty/bin/qlty\n' "$HOME"
		return 0
	fi
	return 1
}

resolve_git() {
	local _candidate=""
	if [ -n "${AIDEVOPS_REAL_GIT_BIN:-}" ] && [ -x "$AIDEVOPS_REAL_GIT_BIN" ]; then
		printf '%s\n' "$AIDEVOPS_REAL_GIT_BIN"
		return 0
	fi
	while IFS= read -r _candidate; do
		case "$_candidate" in
		*/.aidevops/*/agents/scripts/git | */.aidevops/agents/scripts/git | */.aidevops/bin/git | */.agents/scripts/git) continue ;;
		esac
		printf '%s\n' "$_candidate"
		return 0
	done < <(type -a -p git 2>/dev/null || true)
	return 1
}

create_scan_clone() {
	local _destination="$1"
	local _sha="$2"
	local _repo_root="$3"
	local _git_bin="$4"
	"$_git_bin" clone --quiet --shared --no-checkout "$_repo_root" "$_destination" || return 1
	"$_git_bin" -C "$_destination" checkout --detach --quiet "$_sha" || return 1
	return 0
}

prepare_scan_clone() {
	local _repo_root=""
	local _head_sha=""
	SCAN_GIT_BIN=$(resolve_git) || {
		printf '::error::native git executable not found\n'
		return 1
	}
	_repo_root=$("$SCAN_GIT_BIN" rev-parse --show-toplevel 2>/dev/null) || {
		printf '::error::repository root not found for isolated qlty scan\n'
		return 1
	}
	_head_sha=$("$SCAN_GIT_BIN" rev-parse HEAD 2>/dev/null) || {
		printf '::error::HEAD not found for isolated qlty scan\n'
		return 1
	}
	SCAN_TMP=$(mktemp -d "${TMPDIR:-/tmp}/qlty-smell-scan.XXXXXX") || return 1
	SCAN_DIR="$SCAN_TMP/repository"
	if ! create_scan_clone "$SCAN_DIR" "$_head_sha" "$_repo_root" "$SCAN_GIT_BIN"; then
		rm -rf "$SCAN_TMP"
		printf '::error::failed to create isolated qlty scan clone\n'
		return 1
	fi
	return 0
}

qlty_version() {
	local _qlty_bin="$1"
	local _version=""
	_version=$("$_qlty_bin" --version 2>/dev/null) || _version="$UNKNOWN_VALUE"
	printf '%s\n' "$_version"
	return 0
}

verify_qlty_version() {
	local _version="$1"
	local _expected="${QLTY_CLI_VERSION:-}"
	if [ -n "$_expected" ] && [[ "$_version" != *" $_expected"* ]]; then
		printf '::error::Qlty CLI version mismatch: expected %s, resolved %s\n' "$_expected" "$_version"
		return 1
	fi
	return 0
}

emit_valid_scan_metadata() {
	local _qlty_version="$1"
	local _sarif="$2"
	local _scan_dir="$3"
	local _git_bin="$4"
	local _commit="$UNKNOWN_VALUE"
	local _tree="$UNKNOWN_VALUE"
	local _config="none"
	local _mode="${QLTY_SCAN_MODE:-isolated-clone}"
	local _count="0"
	_commit=$("$_git_bin" -C "$_scan_dir" rev-parse HEAD 2>/dev/null) || _commit="$UNKNOWN_VALUE"
	_tree=$("$_git_bin" -C "$_scan_dir" rev-parse 'HEAD^{tree}' 2>/dev/null) || _tree="$UNKNOWN_VALUE"
	if [ -f "$_scan_dir/.qlty/qlty.toml" ]; then
		_config=".qlty/qlty.toml"
	fi
	_count=$(printf '%s\n' "$_sarif" | jq '.runs[0].results | length')
	printf 'Qlty version: %s\n' "$_qlty_version"
	printf 'Scan commit: %s\n' "$_commit"
	printf 'Scan tree: %s\n' "$_tree"
	printf 'Scan mode: %s\n' "$_mode"
	printf 'Scan root: repository-root\n'
	printf 'Qlty config: %s\n' "$_config"
	printf 'Normalized result count: %s\n' "$_count"
	printf 'Normalized per-rule counts:\n'
	printf '%s\n' "$_sarif" | jq -r '[.runs[0].results[]?.ruleId? | select(. != null)] | group_by(.) | map({rule: .[0], count: length}) | sort_by(.rule) | .[] | "  \(.count)\t\(.rule)"'
	return 0
}

is_non_negative_integer() {
	local _value="$1"
	case "$_value" in
	'' | *[!0-9]*)
		return 1
		;;
	*)
		return 0
		;;
	esac
	return 1
}

read_threshold() {
	local _conf="$1"
	local _threshold="0"
	local _val=""
	if [ -f "$_conf" ]; then
		_val=$(grep '^QLTY_SMELL_THRESHOLD=' "$_conf" | cut -d= -f2 || true)
		if is_non_negative_integer "$_val"; then
			_threshold="$_val"
		fi
	fi
	printf '%s\n' "$_threshold"
	return 0
}

emit_sarif_warning() {
	local _reason="$1"
	local _diag_file="$2"
	local _qlty_bin="$3"
	local _stdout_preview="${4:-}"
	local _qlty_rc="${5:-}"
	printf '::warning::qlty smells produced %s SARIF output — skipping absolute smell threshold check\n' "$_reason"
	printf 'Absolute threshold status: diagnostic-only for this run; PR-specific qlty delta gate remains authoritative.\n'
	printf 'Command: %s smells --all --sarif --no-snippets --quiet\n' "$_qlty_bin"
	if [ -n "$_qlty_rc" ]; then
		printf 'qlty smells exit code: %s\n' "$_qlty_rc"
	fi
	printf 'Qlty version: '
	"$_qlty_bin" --version 2>/dev/null || printf 'unknown\n'
	if [ -n "$_stdout_preview" ]; then
		printf '\nqlty stdout preview:\n'
		printf '%s\n' "${_stdout_preview:0:2000}"
	fi
	if [ -s "$_diag_file" ]; then
		printf '\nqlty stderr (first 40 lines):\n'
		sed -n '1,40p' "$_diag_file"
	fi
	return 0
}

is_blank_output() {
	local _value="$1"
	[[ -z "${_value//[[:space:]]/}" ]]
	return $?
}

is_valid_sarif_results() {
	local _value="$1"
	printf '%s\n' "$_value" | jq -e '.runs[0].results | type == "array"' >/dev/null 2>&1
	return $?
}

normalized_identities() {
	local _sarif_file="$1"
	jq -r --arg unknown "$UNKNOWN_VALUE" '.runs[0].results[] |
		[(.ruleId // $unknown),
		 ([.locations[]?.physicalLocation?.artifactLocation?.uri? | select(. != null)] | sort | join("|"))]
		| @tsv' "$_sarif_file" 2>/dev/null | LC_ALL=C sort
	return 0
}

scan_result_count() {
	local _sarif_file="$1"
	if [ ! -s "$_sarif_file" ]; then
		printf '%s' "$UNKNOWN_VALUE"
		return 0
	fi
	jq -r 'if (.runs[0].results | type) == "array" then (.runs[0].results | length) else "unknown" end' \
		"$_sarif_file" 2>/dev/null || printf '%s' "$UNKNOWN_VALUE"
	return 0
}

scan_input_hash() {
	local _scan_dir="$1"
	local _path="$2"
	local _git_bin="$3"
	if [ ! -f "$_scan_dir/$_path" ]; then
		printf '%s' "none"
		return 0
	fi
	"$_git_bin" -C "$_scan_dir" hash-object "$_path" 2>/dev/null || printf '%s' "$UNKNOWN_VALUE"
	return 0
}

emit_inconclusive_metadata() {
	local _reason="$1"
	local _qlty_version="$2"
	local _scan_dir="$3"
	local _git_bin="$4"
	local _attempts="$5"
	local _commit="$UNKNOWN_VALUE"
	local _tree="$UNKNOWN_VALUE"
	_commit=$("$_git_bin" -C "$_scan_dir" rev-parse HEAD 2>/dev/null) || _commit="$UNKNOWN_VALUE"
	_tree=$("$_git_bin" -C "$_scan_dir" rev-parse 'HEAD^{tree}' 2>/dev/null) || _tree="$UNKNOWN_VALUE"
	printf 'Absolute threshold status: inconclusive (%s); diagnostic-only for this run.\n' "$_reason"
	printf 'Scan identity: version=%s commit=%s tree=%s mode=isolated-clone cwd=repository-root\n' \
		"$_qlty_version" "$_commit" "$_tree"
	printf 'Command: qlty smells --all --sarif --no-snippets --quiet\n'
	printf 'Cache namespace: isolated-per-run\n'
	printf 'Input hashes: config=%s ignore=%s\n' \
		"$(scan_input_hash "$_scan_dir" '.qlty/qlty.toml' "$_git_bin")" \
		"$(scan_input_hash "$_scan_dir" '.qltyignore' "$_git_bin")"
	printf 'Attempts: %s\n' "$_attempts"
	return 0
}

emit_remediation_evidence() {
	local _count="$1"
	local _threshold="$2"
	local _sarif="$3"
	local _deficit=$((_count - _threshold))
	local _evidence=""

	_evidence=$(printf '%s\n' "$_sarif" | jq -c \
		--argjson actual "$_count" --argjson threshold "$_threshold" --argjson deficit "$_deficit" '
		{
			schema: "aidevops.qlty-remediation.v1",
			actual: $actual,
			threshold: $threshold,
			deficit: $deficit,
			scope: "repository",
			files: ([.runs[0].results[]? |
				.locations[0]?.physicalLocation?.artifactLocation?.uri? |
				select(. != null)] |
				group_by(.) | map({file: .[0], count: length}) | sort_by([-.count, .file])),
			rules: ([.runs[0].results[]?.ruleId? | select(. != null)] |
				group_by(.) | map({rule: .[0], count: length}) | sort_by([-.count, .rule]))
		}' 2>/dev/null) || _evidence=""
	if [ -n "$_evidence" ]; then
		printf 'QLTY_REMEDIATION_EVIDENCE=%s\n' "$_evidence"
	fi
	return 0
}

evaluate_threshold_sarif() {
	local _count="$1"
	local _threshold="$2"
	local _sarif="$3"
	local _headroom=""
	printf '\nTotal qlty smells: %s\n' "$_count"
	printf 'Threshold:         %s\n\n' "$_threshold"
	if [ "$_count" -gt "$_threshold" ]; then
		printf '::error::Qlty smell regression: %s smells exceeds threshold %s\n' "$_count" "$_threshold"
		emit_remediation_evidence "$_count" "$_threshold" "$_sarif"
		printf '\nPer-rule breakdown:\n'
		printf '%s\n' "$_sarif" | jq -r '[.runs[0].results[]?.ruleId? | select(. != null)] | group_by(.) | map({rule: .[0], count: length}) | sort_by(-.count) | .[] | "  \(.count)\t\(.rule)"'
		printf '\nTop 20 files by smell count:\n'
		printf '%s\n' "$_sarif" | jq -r '[.runs[0].results[]? | .locations[0]?.physicalLocation?.artifactLocation?.uri? | select(. != null)] | group_by(.) | map({file: .[0], count: length}) | sort_by(-.count) | .[0:20] | .[] | "  \(.count)\t\(.file)"'
		printf '\nFix options:\n'
		printf "  1. New PR smells remain blocking — run 'qlty smells --all' locally\n"
		printf '  2. Pre-existing default-branch debt must enter the autonomous quality-sweep remediation loop\n'
		printf '  3. Do not raise QLTY_SMELL_THRESHOLD to absorb recurring debt\n'
		return 1
	fi
	_headroom=$((_threshold - _count))
	printf 'Within threshold (%s headroom)\n' "$_headroom"
	return 0
}

prepare_threshold_context() {
	local _conf="$1"
	THRESHOLD_VALUE=$(read_threshold "$_conf")
	if [ "$THRESHOLD_VALUE" -eq 0 ]; then
		printf '::warning::QLTY_SMELL_THRESHOLD not set in %s — skipping check\n' "$_conf"
		return 2
	fi
	THRESHOLD_QLTY_BIN=$(find_qlty) || {
		printf '::error::qlty CLI not found\n'
		return 1
	}
	THRESHOLD_QLTY_VERSION=$(qlty_version "$THRESHOLD_QLTY_BIN")
	verify_qlty_version "$THRESHOLD_QLTY_VERSION" || return 1
	printf 'Creating standalone clone for authoritative qlty scan...\n'
	prepare_scan_clone || return 1
	return 0
}

prepare_threshold_resources() {
	local _scan_tmp="$1"
	THRESHOLD_DIAG_FILE=$(mktemp "${TMPDIR:-/tmp}/qlty-smell-threshold.XXXXXX") || return 1
	THRESHOLD_WARMUP_FILE=$(mktemp "${TMPDIR:-/tmp}/qlty-smell-warmup.XXXXXX") || {
		rm -f "$THRESHOLD_DIAG_FILE"
		return 1
	}
	THRESHOLD_THIRD_FILE=$(mktemp "${TMPDIR:-/tmp}/qlty-smell-third.XXXXXX") || {
		rm -f "$THRESHOLD_DIAG_FILE" "$THRESHOLD_WARMUP_FILE"
		return 1
	}
	THRESHOLD_CACHE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/qlty-smell-cache.XXXXXX") || {
		rm -f "$THRESHOLD_DIAG_FILE" "$THRESHOLD_WARMUP_FILE" "$THRESHOLD_THIRD_FILE"
		return 1
	}
	return 0
}

finish_threshold_result() {
	local _sarif="$1"
	local _threshold="$2"
	local _qlty_version="$3"
	local _scan_dir="$4"
	local _git_bin="$5"
	local _scan_tmp="$6"
	local _count=""
	_count=$(printf '%s\n' "$_sarif" | jq '.runs[0].results | length' 2>/dev/null || true)
	if ! is_non_negative_integer "$_count"; then
		rm -rf "$_scan_tmp"
		printf '::error::Failed to parse smell count from SARIF output\n'
		return 1
	fi
	emit_valid_scan_metadata "$_qlty_version" "$_sarif" "$_scan_dir" "$_git_bin"
	rm -rf "$_scan_tmp"
	evaluate_threshold_sarif "$_count" "$_threshold" "$_sarif"
	return $?
}

run_threshold_check() {
	local _conf="${1:-.agents/configs/complexity-thresholds.conf}"
	local _threshold=""
	local _qlty_bin=""
	local _git_bin=""
	local _cache_dir=""
	local _diag_file=""
	local _warmup_file=""
	local _third_file=""
	local _scan_tmp=""
	local _scan_dir=""
	local _sarif=""
	local _qlty_rc="0"
	local _warmup_rc="0"
	local _third_rc="0"
	local _qlty_version=""
	prepare_threshold_context "$_conf"
	case $? in
	2) return 0 ;;
	1) return 1 ;;
	esac
	_threshold="$THRESHOLD_VALUE"
	_qlty_bin="$THRESHOLD_QLTY_BIN"
	_qlty_version="$THRESHOLD_QLTY_VERSION"
	_git_bin="$SCAN_GIT_BIN"
	_scan_tmp="$SCAN_TMP"
	_scan_dir="$SCAN_DIR"
	printf 'Warming isolated qlty cache before authoritative scan...\n'
	prepare_threshold_resources "$_scan_tmp" || {
		rm -rf "$_scan_tmp"
		return 1
	}
	_diag_file="$THRESHOLD_DIAG_FILE"
	_warmup_file="$THRESHOLD_WARMUP_FILE"
	_third_file="$THRESHOLD_THIRD_FILE"
	_cache_dir="$THRESHOLD_CACHE_DIR"
	(cd "$_scan_dir" && XDG_CACHE_HOME="$_cache_dir" "$_qlty_bin" smells --all --sarif --no-snippets --quiet) \
		>"$_warmup_file" 2>>"$_diag_file" || _warmup_rc=$?
	printf 'Counting total qlty smells across all files...\n'
	_sarif=$(cd "$_scan_dir" && XDG_CACHE_HOME="$_cache_dir" "$_qlty_bin" smells --all --sarif --no-snippets --quiet 2>>"$_diag_file")
	_qlty_rc=$?
	if is_blank_output "$_sarif"; then
		emit_sarif_warning "empty" "$_diag_file" "$_qlty_bin" "" "$_qlty_rc"
		emit_inconclusive_metadata "empty SARIF" "$_qlty_version" "$_scan_dir" "$_git_bin" \
			"1:rc=$_warmup_rc,count=$(scan_result_count "$_warmup_file");2:rc=$_qlty_rc,count=$UNKNOWN_VALUE"
		rm -f "$_diag_file" "$_warmup_file" "$_third_file"
		rm -rf "$_cache_dir" "$_scan_tmp"
		return 0
	fi
	if ! is_valid_sarif_results "$_sarif"; then
		emit_sarif_warning "invalid" "$_diag_file" "$_qlty_bin" "$_sarif" "$_qlty_rc"
		emit_inconclusive_metadata "invalid SARIF" "$_qlty_version" "$_scan_dir" "$_git_bin" \
			"1:rc=$_warmup_rc,count=$(scan_result_count "$_warmup_file");2:rc=$_qlty_rc,count=$UNKNOWN_VALUE"
		rm -f "$_diag_file"
		rm -f "$_warmup_file" "$_third_file"
		rm -rf "$_cache_dir"
		rm -rf "$_scan_tmp"
		return 0
	fi
	if [ ! -s "$_warmup_file" ] || ! jq -e '.runs[0].results | type == "array"' "$_warmup_file" >/dev/null 2>&1; then
		emit_inconclusive_metadata "empty or invalid warm-up SARIF" "$_qlty_version" "$_scan_dir" "$_git_bin" \
			"1:rc=$_warmup_rc,count=$(scan_result_count "$_warmup_file");2:rc=$_qlty_rc,count=$(printf '%s\n' "$_sarif" | jq -r '.runs[0].results | length')"
		rm -f "$_diag_file" "$_warmup_file" "$_third_file"
		rm -rf "$_cache_dir" "$_scan_tmp"
		return 0
	fi
	printf '%s\n' "$_sarif" >"${_third_file}.second"
	if ! cmp -s <(normalized_identities "$_warmup_file") <(normalized_identities "${_third_file}.second"); then
		printf 'Qlty identities differ after two scans; collecting a third consensus attempt...\n'
		(cd "$_scan_dir" && XDG_CACHE_HOME="$_cache_dir" "$_qlty_bin" smells --all --sarif --no-snippets --quiet) \
			>"$_third_file" 2>>"$_diag_file" || _third_rc=$?
		if [ ! -s "$_third_file" ] || ! jq -e '.runs[0].results | type == "array"' "$_third_file" >/dev/null 2>&1; then
			emit_inconclusive_metadata "invalid third SARIF" "$_qlty_version" "$_scan_dir" "$_git_bin" \
				"1:rc=$_warmup_rc,count=$(scan_result_count "$_warmup_file");2:rc=$_qlty_rc,count=$(scan_result_count "${_third_file}.second");3:rc=$_third_rc,count=$(scan_result_count "$_third_file")"
			rm -f "$_diag_file" "$_warmup_file" "$_third_file" "${_third_file}.second"
			rm -rf "$_cache_dir" "$_scan_tmp"
			return 0
		fi
		if cmp -s <(normalized_identities "$_warmup_file") <(normalized_identities "$_third_file"); then
			_sarif=$(<"$_third_file")
		elif cmp -s <(normalized_identities "${_third_file}.second") <(normalized_identities "$_third_file"); then
			_sarif=$(<"$_third_file")
		else
			emit_inconclusive_metadata "unstable normalized identities" "$_qlty_version" "$_scan_dir" "$_git_bin" \
				"1:rc=$_warmup_rc,count=$(scan_result_count "$_warmup_file");2:rc=$_qlty_rc,count=$(scan_result_count "${_third_file}.second");3:rc=$_third_rc,count=$(scan_result_count "$_third_file")"
			printf 'Identity differences (attempt 1 -> 2):\n'
			diff -u <(normalized_identities "$_warmup_file") <(normalized_identities "${_third_file}.second") || true
			printf 'Identity differences (attempt 2 -> 3):\n'
			diff -u <(normalized_identities "${_third_file}.second") <(normalized_identities "$_third_file") || true
			rm -f "$_diag_file" "$_warmup_file" "$_third_file" "${_third_file}.second"
			rm -rf "$_cache_dir" "$_scan_tmp"
			return 0
		fi
	fi
	rm -f "$_warmup_file" "$_third_file" "${_third_file}.second"
	rm -rf "$_cache_dir"
	rm -f "$_diag_file"

	finish_threshold_result "$_sarif" "$_threshold" "$_qlty_version" "$_scan_dir" "$_git_bin" "$_scan_tmp"
	return $?
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	run_threshold_check "${1:-.agents/configs/complexity-thresholds.conf}"
	exit $?
fi

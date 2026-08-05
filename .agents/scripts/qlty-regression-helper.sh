#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# qlty-regression-helper.sh — CI regression gate for qlty smells (t2065)
#
# Runs `qlty smells --all --sarif` against a base ref and a head ref,
# computes the delta (total count, per-rule, per-file), and emits a
# markdown report suitable for a PR comment. Exits 1 if the PR
# introduces a net increase in smells and --allow-increase is not set.
#
# Usage:
#   qlty-regression-helper.sh --base <sha> [--head <sha>] [options]
#
# Options:
#   --base <sha>           Base ref (required unless --dry-run)
#   --head <sha>           Head ref (default: HEAD)
#   --output-md <file>     Write markdown report to <file>
#   --sarif-base <file>    Write base SARIF output to <file>
#   --sarif-head <file>    Write head SARIF output to <file>
#   --allow-increase       Do not fail on net increase (warn only)
#   --dry-run              Only report smell count of current tree
#   -h, --help             Show usage
#
# Exit codes:
#   0 — no regression (or override / dry-run)
#   1 — regression detected
#   2 — invocation or environment error
#
# Design notes:
# - Uses standalone shared clones for both refs. Unlike linked worktrees, these
#   retain equivalent .git directories and prevent topology-sensitive findings.
# - Total-count diff (not SARIF fingerprint diff) because qlty's
#   fingerprints are not stable across line shifts.

set -uo pipefail

SCRIPT_NAME=$(basename "$0")
TMP_DIR=""
BASE_WORKTREE=""
HEAD_WORKTREE=""
QLTY_BIN=""
QLTY_VERSION=""
GIT_BIN=""
UNKNOWN_VALUE="unknown"

cleanup() {
	if [ -n "$TMP_DIR" ] && [ -d "$TMP_DIR" ]; then
		rm -rf "$TMP_DIR"
	fi
	return 0
}
trap cleanup EXIT

log() {
	local _msg="$1"
	printf '[%s] %s\n' "$SCRIPT_NAME" "$_msg" >&2
	return 0
}

die() {
	local _msg="$1"
	printf '[%s] ERROR: %s\n' "$SCRIPT_NAME" "$_msg" >&2
	exit 2
}

usage() {
	sed -n '4,32p' "$0" | sed 's/^# \{0,1\}//'
	return 0
}

find_qlty() {
	if command -v qlty >/dev/null 2>&1; then
		command -v qlty
		return 0
	fi
	if [ -x "$HOME/.qlty/bin/qlty" ]; then
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

# run_qlty_sarif <working-dir> <output-file>
run_qlty_sarif() {
	local _dir="$1"
	local _out="$2"
	local _cache_key=""
	local _cache_dir=""
	local _first=""
	local _second=""
	local _third=""
	_cache_key=$(basename "$_out" .sarif)
	_cache_dir="$TMP_DIR/cache-${_cache_key}"
	_first="$TMP_DIR/${_cache_key}.first.sarif"
	_second="$TMP_DIR/${_cache_key}.second.sarif"
	_third="$TMP_DIR/${_cache_key}.third.sarif"
	mkdir -p "$_cache_dir"
	# --all: scan all files; --sarif: JSON output;
	# --no-snippets: compact; --quiet: suppress progress.
	# qlty exits non-zero when smells exist — SARIF still written to stdout.
	# Qlty 0.619.0-0.636.0 can emit intermittent similar-code findings while
	# warming an empty cache. Accept the first matching identity set from up to
	# three scans so one transient pass cannot create or hide a regression.
	(cd "$_dir" && XDG_CACHE_HOME="$_cache_dir" "$QLTY_BIN" smells --all --sarif --no-snippets --quiet) \
		>"$_first" 2>/dev/null || true
	(cd "$_dir" && XDG_CACHE_HOME="$_cache_dir" "$QLTY_BIN" smells --all --sarif --no-snippets --quiet) \
		>"$_second" 2>/dev/null || true
	if [ ! -s "$_first" ] || [ ! -s "$_second" ]; then
		log "ERROR: qlty produced no output for $_dir"
		return 1
	fi
	if ! jq -e '.runs[0].results' "$_first" "$_second" >/dev/null 2>&1; then
		log "ERROR: qlty output is not valid SARIF for $_dir"
		return 1
	fi
	if cmp -s <(normalized_identities "$_first") <(normalized_identities "$_second"); then
		mv "$_second" "$_out"
		log "qlty identities stabilized after 2 scans for $_dir"
		return 0
	fi
	(cd "$_dir" && XDG_CACHE_HOME="$_cache_dir" "$QLTY_BIN" smells --all --sarif --no-snippets --quiet) \
		>"$_third" 2>/dev/null || true
	if [ ! -s "$_third" ] || ! jq -e '.runs[0].results' "$_third" >/dev/null 2>&1; then
		log "ERROR: qlty third scan did not produce valid SARIF for $_dir"
		return 1
	fi
	if cmp -s <(normalized_identities "$_first") <(normalized_identities "$_third") ||
		cmp -s <(normalized_identities "$_second") <(normalized_identities "$_third"); then
		mv "$_third" "$_out"
		log "qlty identities stabilized after 3 scans for $_dir"
		return 0
	fi
	log "ERROR: qlty identities did not stabilize after 3 scans for $_dir"
	return 1
}

create_scan_clone() {
	local _destination="$1"
	local _sha="$2"
	local _repo_root="$3"
	"$GIT_BIN" clone --quiet --shared --no-checkout "$_repo_root" "$_destination" || return 1
	"$GIT_BIN" -C "$_destination" checkout --detach --quiet "$_sha" || return 1
	return 0
}

normalized_identities() {
	local _sarif="$1"
	jq -r '.runs[0].results[] |
		[(.ruleId // $unknown),
		 ([.locations[]?.physicalLocation?.artifactLocation?.uri? | select(. != null)] | sort | join("|"))]
		| @tsv' --arg unknown "$UNKNOWN_VALUE" "$_sarif" | LC_ALL=C sort
	return 0
}

emit_scan_metadata() {
	local _label="$1"
	local _dir="$2"
	local _sarif="$3"
	local _mode="$4"
	local _commit=""
	local _tree=""
	local _count=""
	local _rule=""
	_commit=$(git -C "$_dir" rev-parse HEAD)
	_tree=$(git -C "$_dir" rev-parse 'HEAD^{tree}')
	_count=$(count_smells "$_sarif")
	log "$_label metadata: version=$QLTY_VERSION commit=$_commit tree=$_tree mode=$_mode root=repository-root config=.qlty/qlty.toml total=$_count"
	log "$_label per-rule counts:"
	while IFS= read -r _rule; do
		log "  $_rule"
	done < <(list_rules "$_sarif")
	return 0
}

verify_same_tree_results() {
	local _base_tree="$1"
	local _head_tree="$2"
	local _base_sarif="$3"
	local _head_sarif="$4"
	local _base_ids="$TMP_DIR/base.identities"
	local _head_ids="$TMP_DIR/head.identities"
	if [ "$_base_tree" != "$_head_tree" ]; then
		return 0
	fi
	normalized_identities "$_base_sarif" >"$_base_ids"
	normalized_identities "$_head_sarif" >"$_head_ids"
	if cmp -s "$_base_ids" "$_head_ids"; then
		log "identical trees produced identical normalized SARIF identities"
		return 0
	fi
	log "ERROR: identical tree $_head_tree produced different normalized SARIF identities"
	diff -u "$_base_ids" "$_head_ids" >&2 || true
	return 1
}

# count_smells <sarif-file>
count_smells() {
	local _sarif="$1"
	jq '.runs[0].results | length' "$_sarif" 2>/dev/null
	return 0
}

# list_rules <sarif-file> — prints "<count>\t<ruleId>" sorted desc.
list_rules() {
	local _sarif="$1"
	jq -r '.runs[0].results
		| group_by(.ruleId)
		| map({rule: .[0].ruleId, count: length})
		| sort_by(-.count)
		| .[] | "\(.count)\t\(.rule)"' "$_sarif" 2>/dev/null
	return 0
}

# list_files <sarif-file> — prints "<count>\t<file>" sorted desc.
list_files() {
	local _sarif="$1"
	jq -r --arg unknown "$UNKNOWN_VALUE" '.runs[0].results
		| map(.locations[0].physicalLocation.artifactLocation.uri // $unknown)
		| group_by(.)
		| map({file: .[0], count: length})
		| sort_by(-.count)
		| .[] | "\(.count)\t\(.file)"' "$_sarif" 2>/dev/null
	return 0
}

# delta_rules <base-sarif> <head-sarif> — prints "<delta>\t<ruleId>" for
# rules whose count increased, sorted by delta desc.
delta_rules() {
	local _base="$1"
	local _head="$2"
	jq -rn --slurpfile b "$_base" --slurpfile h "$_head" '
		def counts(s): s[0].runs[0].results
			| group_by(.ruleId)
			| map({key: .[0].ruleId, value: length})
			| from_entries;
		(counts($b)) as $bc | (counts($h)) as $hc
		| ($bc | keys) + ($hc | keys)
		| unique
		| map({rule: ., delta: (($hc[.] // 0) - ($bc[.] // 0))})
		| map(select(.delta > 0))
		| sort_by(-.delta)
		| .[] | "\(.delta)\t\(.rule)"' 2>/dev/null
	return 0
}

# delta_files <base-sarif> <head-sarif> — same shape as delta_rules but
# keyed by file URI.
delta_files() {
	local _base="$1"
	local _head="$2"
	jq -rn --arg unknown "$UNKNOWN_VALUE" --slurpfile b "$_base" --slurpfile h "$_head" '
		def counts(s): s[0].runs[0].results
			| map(.locations[0].physicalLocation.artifactLocation.uri // $unknown)
			| group_by(.)
			| map({key: .[0], value: length})
			| from_entries;
		(counts($b)) as $bc | (counts($h)) as $hc
		| ($bc | keys) + ($hc | keys)
		| unique
		| map({file: ., delta: (($hc[.] // 0) - ($bc[.] // 0))})
		| map(select(.delta > 0))
		| sort_by(-.delta)
		| .[] | "\(.delta)\t\(.file)"' 2>/dev/null
	return 0
}

# write_report <base-count> <head-count> <delta> <base-sarif> <head-sarif>
#              <base-sha> <head-sha> <output-md>
write_report() {
	local _base_count="$1"
	local _head_count="$2"
	local _delta="$3"
	local _base_sarif="$4"
	local _head_sarif="$5"
	local _base_sha="$6"
	local _head_sha="$7"
	local _out="$8"
	local _verdict
	if [ "$_delta" -gt 0 ]; then
		_verdict="❌ **Regression** — this PR adds $_delta new smell(s)."
	elif [ "$_delta" -lt 0 ]; then
		_verdict="✅ **Improvement** — this PR removes $((_delta * -1)) smell(s)."
	else
		_verdict="✅ **No change** — smell count unchanged."
	fi
	{
		printf '## Qlty Smell Regression Gate\n\n'
		printf '%s\n\n' "$_verdict"
		# shellcheck disable=SC2016
		printf '| Metric | Base (`%s`) | Head (`%s`) | Delta |\n' \
			"${_base_sha:0:7}" "${_head_sha:0:7}"
		printf '|---|---:|---:|---:|\n'
		printf '| Total smells | %s | %s | %+d |\n\n' \
			"$_base_count" "$_head_count" "$_delta"
		if [ "$_delta" -gt 0 ]; then
			printf '### New smells by rule\n\n'
			printf '| Delta | Rule |\n|---:|---|\n'
			delta_rules "$_base_sarif" "$_head_sarif" |
				head -20 |
				awk -F '\t' '{printf "| +%s | `%s` |\n", $1, $2}'
			printf '\n### Top files with new smells\n\n'
			printf '| Delta | File |\n|---:|---|\n'
			delta_files "$_base_sarif" "$_head_sarif" |
				head -10 |
				awk -F '\t' '{printf "| +%s | `%s` |\n", $1, $2}'
			printf '\n'
			# shellcheck disable=SC2016
			printf '> To override (with justification), add the `ratchet-bump` label to this PR.\n'
			# shellcheck disable=SC2016
			printf '> See `.agents/AGENTS.md` → "Qlty Regression Gate" for details.\n'
		fi
		printf '\n<!-- qlty-regression-gate -->\n'
	} >"$_out"
	return 0
}

# --- argument parsing ---------------------------------------------------------

BASE=""
HEAD="HEAD"
OUTPUT_MD=""
SARIF_BASE=""
SARIF_HEAD=""
ALLOW_INCREASE=0
DRY_RUN=0

while [ $# -gt 0 ]; do
	case "$1" in
	--base)
		if [ $# -lt 2 ] || [ "${2#-}" != "$2" ]; then
			die "missing value for --base"
		fi
		BASE="$2"
		shift 2
		;;
	--head)
		if [ $# -lt 2 ] || [ "${2#-}" != "$2" ]; then
			die "missing value for --head"
		fi
		HEAD="$2"
		shift 2
		;;
	--output-md)
		if [ $# -lt 2 ] || [ "${2#-}" != "$2" ]; then
			die "missing value for --output-md"
		fi
		OUTPUT_MD="$2"
		shift 2
		;;
	--sarif-base)
		if [ $# -lt 2 ] || [ "${2#-}" != "$2" ]; then
			die "missing value for --sarif-base"
		fi
		SARIF_BASE="$2"
		shift 2
		;;
	--sarif-head)
		if [ $# -lt 2 ] || [ "${2#-}" != "$2" ]; then
			die "missing value for --sarif-head"
		fi
		SARIF_HEAD="$2"
		shift 2
		;;
	--allow-increase)
		ALLOW_INCREASE=1
		shift
		;;
	--dry-run)
		DRY_RUN=1
		shift
		;;
	-h | --help)
		usage
		exit 0
		;;
	*)
		die "unknown argument: $1"
		;;
	esac
done

# --- main ---------------------------------------------------------------------

if [ "$DRY_RUN" -eq 1 ]; then
	TMP_DIR=$(mktemp -d)
	QLTY_BIN=$(find_qlty) || die "qlty CLI not found"
	QLTY_VERSION=$("$QLTY_BIN" --version 2>/dev/null) || QLTY_VERSION="$UNKNOWN_VALUE"
	_head_sarif="$TMP_DIR/head.sarif"
	log "dry-run: scanning current tree"
	run_qlty_sarif "." "$_head_sarif"
	emit_scan_metadata "head" "." "$_head_sarif" "current-tree"
	_count=$(count_smells "$_head_sarif")
	printf 'Total smells: %s\n' "$_count"
	if [ -n "$SARIF_HEAD" ]; then
		cp "$_head_sarif" "$SARIF_HEAD"
	fi
	exit 0
fi

if [ -z "$BASE" ]; then
	die "--base <sha> is required (use --dry-run to scan current tree)"
fi

if ! git rev-parse --verify --quiet "$BASE^{commit}" >/dev/null; then
	die "base ref not found in repo: $BASE"
fi
if ! git rev-parse --verify --quiet "$HEAD^{commit}" >/dev/null; then
	die "head ref not found in repo: $HEAD"
fi

BASE_SHA=$(git rev-parse "$BASE")
HEAD_SHA=$(git rev-parse "$HEAD")
BASE_TREE=$(git rev-parse "$BASE^{tree}")
HEAD_TREE=$(git rev-parse "$HEAD^{tree}")
REPO_ROOT=$(git rev-parse --show-toplevel)
QLTY_BIN=$(find_qlty) || die "qlty CLI not found"
QLTY_VERSION=$("$QLTY_BIN" --version 2>/dev/null) || QLTY_VERSION="$UNKNOWN_VALUE"
GIT_BIN=$(resolve_git) || die "native git executable not found"
if [ -n "${QLTY_CLI_VERSION:-}" ] && [[ "$QLTY_VERSION" != *" ${QLTY_CLI_VERSION}"* ]]; then
	die "Qlty CLI version mismatch: expected ${QLTY_CLI_VERSION}, resolved $QLTY_VERSION"
fi

TMP_DIR=$(mktemp -d)
_base_sarif="$TMP_DIR/base.sarif"
_head_sarif="$TMP_DIR/head.sarif"

# Scan base in a standalone clone so qlty observes a normal .git directory.
BASE_WORKTREE="$TMP_DIR/base-worktree"
log "creating base scan clone at $BASE_SHA"
if ! create_scan_clone "$BASE_WORKTREE" "$BASE_SHA" "$REPO_ROOT"; then
	die "failed to create base scan clone for $BASE_SHA"
fi

log "scanning base ($BASE_SHA)"
if ! run_qlty_sarif "$BASE_WORKTREE" "$_base_sarif"; then
	log "WARN: base scan failed; treating base count as equal to head (no regression)"
	# Fall back: copy head result once we have it so delta is zero.
	BASE_SCAN_FAILED=1
else
	BASE_SCAN_FAILED=0
	emit_scan_metadata "base" "$BASE_WORKTREE" "$_base_sarif" "isolated-clone"
fi

# Scan the head in the same standalone-clone topology as the base. Qlty 0.635.0
# can otherwise report similar-code findings only in one topology even when the
# affected files are byte-identical across the compared trees.
HEAD_WORKTREE="$TMP_DIR/head-worktree"
HEAD_SCAN_DIR="$HEAD_WORKTREE"
HEAD_SCAN_MODE="isolated-clone"
log "creating head scan clone at $HEAD_SHA"
if ! create_scan_clone "$HEAD_WORKTREE" "$HEAD_SHA" "$REPO_ROOT"; then
	die "failed to create head scan clone for $HEAD_SHA"
fi

log "scanning head ($HEAD_SHA)"
if ! run_qlty_sarif "$HEAD_SCAN_DIR" "$_head_sarif" "$HEAD_SCAN_MODE"; then
	die "failed to scan head ($HEAD_SHA)"
fi
emit_scan_metadata "head" "$HEAD_SCAN_DIR" "$_head_sarif" "$HEAD_SCAN_MODE"

if [ "$BASE_SCAN_FAILED" -eq 1 ]; then
	cp "$_head_sarif" "$_base_sarif"
fi

IDENTITY_MISMATCH=0
if [ "$BASE_SCAN_FAILED" -eq 0 ] && ! verify_same_tree_results "$BASE_TREE" "$HEAD_TREE" "$_base_sarif" "$_head_sarif"; then
	IDENTITY_MISMATCH=1
fi

BASE_COUNT=$(count_smells "$_base_sarif")
HEAD_COUNT=$(count_smells "$_head_sarif")
DELTA=$((HEAD_COUNT - BASE_COUNT))

log "base: $BASE_COUNT  head: $HEAD_COUNT  delta: $DELTA"

if [ -n "$SARIF_BASE" ]; then
	cp "$_base_sarif" "$SARIF_BASE"
fi
if [ -n "$SARIF_HEAD" ]; then
	cp "$_head_sarif" "$SARIF_HEAD"
fi

if [ -n "$OUTPUT_MD" ]; then
	write_report "$BASE_COUNT" "$HEAD_COUNT" "$DELTA" \
		"$_base_sarif" "$_head_sarif" \
		"$BASE_SHA" "$HEAD_SHA" "$OUTPUT_MD"
	log "report written to $OUTPUT_MD"
fi

if [ "$IDENTITY_MISMATCH" -eq 1 ]; then
	log "REGRESSION: normalized SARIF differs for identical trees"
	exit 1
fi

if [ "$DELTA" -gt 0 ] && [ "$ALLOW_INCREASE" -eq 0 ]; then
	log "REGRESSION: +$DELTA smell(s)"
	exit 1
fi

log "no regression"
exit 0

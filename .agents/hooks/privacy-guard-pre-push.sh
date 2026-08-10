#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# privacy-guard-pre-push.sh — git pre-push hook.
#
# Blocks a push to a public GitHub repo if the push diff introduces any
# private repo slug (from ~/.config/aidevops/repos.json) or local/private path
# into repository content. The default scan surface is the full repo and can be
# narrowed with PRIVACY_SCAN_GLOBS_TEXT when a repository has a documented need.
#
# Install: see .agents/scripts/install-privacy-guard.sh
#
# Git pre-push protocol:
#   $1 = remote name
#   $2 = remote URL
#   stdin: one line per ref being pushed:
#     <local_ref> <local_sha> <remote_ref> <remote_sha>
#
# Exit 0 = allow push. Exit 1 = block push.
#
# Environment:
#   PRIVACY_GUARD_DISABLE=1  — bypass for this invocation (equivalent to --no-verify)
#   PRIVACY_GUARD_DEBUG=1    — verbose stderr trace
#
# Fail-open cases (exit 0 with warning):
#   - gh CLI unavailable or unauthenticated
#   - remote URL not parseable as github.com
#   - repos.json missing or malformed

set -u

if [[ "${PRIVACY_GUARD_DISABLE:-0}" == "1" ]]; then
	printf '[privacy-guard][INFO] PRIVACY_GUARD_DISABLE=1 — bypassing\n' >&2
	exit 0
fi

# Locate the helper library. Resolve relative to the hook's real path so it
# works whether installed as a symlink in .git/hooks or copied in place.
_resolve_self() {
	local src="${BASH_SOURCE[0]}"
	while [[ -L "$src" ]]; do
		local dir
		dir=$(cd -P "$(dirname "$src")" && pwd)
		src=$(readlink "$src")
		[[ "$src" != /* ]] && src="$dir/$src"
	done
	cd -P "$(dirname "$src")" && pwd
}

HOOK_DIR=$(_resolve_self)
HELPER_REPO="${HOOK_DIR}/../scripts/privacy-guard-helper.sh"
HELPER_DEPLOYED="${HOME}/.aidevops/agents/scripts/privacy-guard-helper.sh"

if [[ -f "$HELPER_REPO" ]]; then
	# shellcheck source=/dev/null
	source "$HELPER_REPO"
elif [[ -f "$HELPER_DEPLOYED" ]]; then
	# shellcheck source=/dev/null
	source "$HELPER_DEPLOYED"
else
	printf '[privacy-guard][WARN] helper library not found — fail-open\n' >&2
	exit 0
fi

remote_name="${1:-}"
remote_url="${2:-}"

if [[ -z "$remote_url" ]]; then
	privacy_log WARN "pre-push called with no remote URL — fail-open"
	exit 0
fi

# Fast path: target is private → nothing to guard
if ! privacy_is_target_public "$remote_url"; then
	# exit 1 = private, exit 2 = unknown — both allow the push
	[[ "${PRIVACY_GUARD_DEBUG:-0}" == "1" ]] && privacy_log INFO "target private or unknown ($remote_url) — allowing push"
	exit 0
fi

[[ "${PRIVACY_GUARD_DEBUG:-0}" == "1" ]] && privacy_log INFO "target public ($remote_url) — scanning diff"

# Enumerate private entity inventory once for the whole push.
entities_file=$(mktemp 2>/dev/null) || {
	privacy_log WARN "mktemp failed — fail-open"
	exit 0
}
trap 'rm -f "$entities_file"' EXIT

if ! privacy_enumerate_private_entities "$entities_file"; then
	privacy_log ERROR "could not enumerate private entity inventory — failing closed"
	exit 1
fi

if [[ ! -s "$entities_file" ]]; then
	[[ "${PRIVACY_GUARD_DEBUG:-0}" == "1" ]] && privacy_log INFO "no private entities to guard against; secret-material scan still active"
fi

# ---------------------------------------------------------------------------
# Read all refs from stdin first (stdin is a one-shot stream). The helper owns
# the scan surface via PRIVACY_SCAN_GLOBS / PRIVACY_SCAN_GLOBS_TEXT; aidevops
# defaults to full-repo scanning so source/docs/tests are protected too.
# ---------------------------------------------------------------------------
_all_refs=()
while IFS=' ' read -r _lr _ls _rr _rs; do
	_all_refs+=("$_lr $_ls $_rr $_rs")
done

# Determine default remote branch once for merge-base fallback (GH#20177).
# Uses the actual remote name (not hardcoded 'origin') to support non-standard
# remote names (e.g., 'upstream'). Leaves empty when unknown so line 139
# triggers a full scan — safer than falling back to HEAD, which may produce an
# empty diff and silently bypass the privacy guard (GH#20225).
# Priority: remote/HEAD (repo-configured) → remote/main → remote/master.
_default_remote_head=""
if [[ -n "$remote_name" ]]; then
	_default_remote_head=$(git symbolic-ref --short "refs/remotes/${remote_name}/HEAD" 2>/dev/null)
	if [[ -z "$_default_remote_head" ]]; then
		for _candidate in "${remote_name}/main" "${remote_name}/master"; do
			git rev-parse --verify "$_candidate" >/dev/null 2>&1
			_status=$?
			if [[ $_status -eq 0 ]]; then
				_default_remote_head="$_candidate"
				break
			fi
		done
	fi
fi

# Secret-material scan is global for public pushes. Unlike private-repo slug
# scanning, it is not limited to planning/docs paths because private-key blocks
# are unsafe in any public commit.
secret_exit_code=0
for _ref_entry in "${_all_refs[@]}"; do
	read -r _lr _ls _rr _rs <<<"$_ref_entry"
	[[ -z "$_ls" ]] && continue
	[[ "$_ls" =~ ^0+$ ]] && continue
	_secret_base="$_rs"
	if [[ -z "$_secret_base" || "$_secret_base" =~ ^0+$ ]]; then
		_secret_base=$(git merge-base "$_ls" "$_default_remote_head" 2>/dev/null || printf '')
		[[ -z "$_secret_base" ]] && _secret_base="0000000000000000000000000000000000000000"
	fi
	secret_hits=$(privacy_scan_secret_material_diff "$_secret_base" "$_ls")
	secret_rc=$?
	if [[ "$secret_rc" -ne 0 ]]; then
		printf '\n[privacy-guard][BLOCK] Push to %s contains secret/private-key material:\n\n' "$remote_name" >&2
		printf '%s\n\n' "$secret_hits" >&2
		printf '  Remove the secret material from committed content and amend/rewrite before pushing.\n' >&2
		printf '  Use synthetic fixtures in tests; never commit real private keys or credential values.\n\n' >&2
		secret_exit_code=1
	fi
done
if [[ "$secret_exit_code" -ne 0 ]]; then
	exit "$secret_exit_code"
fi

[[ "${PRIVACY_GUARD_DEBUG:-0}" == "1" ]] && privacy_log INFO "scanning all changed public-repo content for private entities"

# Walk each ref in the push (re-iterate over collected refs)
exit_code=0
for _ref_entry in "${_all_refs[@]}"; do
	read -r local_ref local_sha remote_ref remote_sha <<<"$_ref_entry"
	[[ -z "$local_sha" ]] && continue
	# Branch deletion (local_sha is zeros) — nothing to scan
	if [[ "$local_sha" =~ ^0+$ ]]; then
		continue
	fi

	_scan_base="$remote_sha"
	if [[ -z "$_scan_base" || "$_scan_base" =~ ^0+$ ]]; then
		_scan_base=$(git merge-base "$local_sha" "$_default_remote_head" 2>/dev/null || echo "")
		[[ -z "$_scan_base" ]] && _scan_base="$remote_sha"
	fi
	hits_output=$(privacy_scan_public_diff "$_scan_base" "$local_sha" "$entities_file")
	scan_rc=$?
	if [[ "$scan_rc" -ne 0 ]]; then
		printf '\n[privacy-guard][BLOCK] Push to %s contains private references in public-repo content:\n\n' "$remote_name" >&2
		printf '%s\n\n' "$hits_output" >&2
		printf '  Remove the private material from the committed content and amend/rewrite the commit before pushing.\n' >&2
		printf '  To bypass (audit trail preserves the override): PRIVACY_GUARD_DISABLE=1 git push ... or git push --no-verify\n' >&2
		printf '  Sources scanned: local private entities plus built-in and configured local/private path patterns.\n\n' >&2
		exit_code=1
	fi
done

exit "$exit_code"

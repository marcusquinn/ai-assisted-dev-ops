#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# knowledge-social-helper.sh — Provider-neutral social corpus storage CLI

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_HELPER="${SCRIPT_DIR}/knowledge_social_import.py"
X_HELPER="${SCRIPT_DIR}/knowledge_social_x.py"
QUERY_HELPER="${SCRIPT_DIR}/knowledge_social_query.py"
SYNC_HELPER="${SCRIPT_DIR}/knowledge_social_sync.py"

usage() {
	cat <<'EOF'
Usage:
  knowledge-social-helper.sh provision [--base PATH] [--alias ALIAS]
  knowledge-social-helper.sh import-archive [--base PATH] [--alias ALIAS] --archive FILE
  knowledge-social-helper.sh rebuild [--base PATH] [--alias ALIAS]
  knowledge-social-helper.sh coverage [--base PATH] [--alias ALIAS]
  knowledge-social-helper.sh query [--base PATH] [--alias ALIAS] \
    (--query TEXT | --query-file FILE) [--limit 1-100]
  knowledge-social-helper.sh annotate [--base PATH] --provider PROVIDER \
    --object-type TYPE --remote-id ID [--annotation-id ID] --body-file FILE
  knowledge-social-helper.sh sync-x [--base PATH] [--alias ALIAS] \
    --connection-id ID --account-id ID --stream STREAM [--budget UNITS] \
    [--media-policy none|metadata] [--app PROFILE] [--username HANDLE] \
    [--collector-id ID] [--lease-seconds SECONDS]
  knowledge-social-helper.sh sync-due [--base PATH] [--alias ALIAS] \
    [--now-epoch EPOCH] [--interval-seconds SECONDS]
  knowledge-social-helper.sh reconcile-due [--base PATH] [--alias ALIAS] \
    [--now-epoch EPOCH] [--interval-seconds SECONDS]
  knowledge-social-helper.sh reconcile [--base PATH] [--alias ALIAS] \
    --connection-id ID --stream STREAM --snapshot FILE [--collector-id ID] \
    [--lease-seconds SECONDS] [--now-epoch EPOCH]
  knowledge-social-helper.sh receipts [--base PATH] [--alias ALIAS] \
    [--connection-id ID] [--limit 1-1000]

The authenticated corpus catalog resolves ALIAS with knowledge.write for
mutating operations or knowledge.read for coverage, due plans, receipts, and
queries. Physical corpus paths are not accepted from callers.

Query resolves the authenticated principal and searches the personal corpus plus
every authorized workspace corpus by default. --alias can narrow but never widen
that scope. Annotate writes an owner-only private note to personal:default; the
body file must be a non-symlink UTF-8 file with mode 0600.

Archive format:
  A UTF-8 JSON object with provider, connection_id, and arrays named accounts,
  objects, activities, media, and coverage. IDs must be provider-stable IDs;
  connection_id must be an opaque local ID. Unknown provider fields belong in
  provider_json objects. The original canonical payload is stored immutably.

X synchronization:
  sync-x verifies the selected xurl account, then reads one official stream:
  authored, mentions, likes, bookmarks, followers, or following. --budget is a
  bounded request-cost allowance from 1 to 1000 units. Media policy none stores
  no media rows; metadata stores references only, never binary media.

Deterministic routines:
  sync-due and reconcile-due return sorted privacy-safe work plans. Every sync or
  reconciliation owns one expiring connection lease and monotonic fencing token;
  normalized rows, checkpoints, and the run receipt commit in one transaction.
  Reconciliation snapshots must be private JSON files and mark remote absence as
  missing evidence. They never purge canonical content.
EOF
	return 0
}

require_runtime() {
	if ! command -v python3 >/dev/null 2>&1; then
		printf 'ERROR: python3 is required for social corpus storage\n' >&2
		return 1
	fi
	if [[ ! -r "$PYTHON_HELPER" ]]; then
		printf 'ERROR: social corpus implementation missing: %s\n' "$PYTHON_HELPER" >&2
		return 1
	fi
	return 0
}

main() {
	local subcommand="${1:-help}"
	if [[ $# -gt 0 ]]; then
		shift
	fi
	case "$subcommand" in
	provision | import-archive | rebuild | coverage)
		require_runtime || return 1
		python3 "$PYTHON_HELPER" "$subcommand" "$@" || return 1
		;;
	sync-x)
		require_runtime || return 1
		if [[ ! -r "$X_HELPER" ]]; then
			printf 'ERROR: X social adapter missing: %s\n' "$X_HELPER" >&2
			return 1
		fi
		python3 "$X_HELPER" "$@" || return 1
		;;
	query | annotate)
		require_runtime || return 1
		if [[ ! -r "$QUERY_HELPER" ]]; then
			printf 'ERROR: social query implementation missing: %s\n' "$QUERY_HELPER" >&2
			return 1
		fi
		python3 "$QUERY_HELPER" "$subcommand" "$@" || return 1
		;;
	sync-due | reconcile-due | reconcile | receipts)
		require_runtime || return 1
		if [[ ! -r "$SYNC_HELPER" ]]; then
			printf 'ERROR: social sync implementation missing: %s\n' "$SYNC_HELPER" >&2
			return 1
		fi
		python3 "$SYNC_HELPER" "$subcommand" "$@" || return 1
		;;
	help | -h | --help)
		usage
		;;
	*)
		printf 'ERROR: unknown social corpus subcommand: %s\n' "$subcommand" >&2
		usage >&2
		return 1
		;;
	esac
	return 0
}

main "$@"

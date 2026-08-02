#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# knowledge-social-helper.sh — Provider-neutral social corpus storage CLI

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_HELPER="${SCRIPT_DIR}/knowledge_social_import.py"
X_HELPER="${SCRIPT_DIR}/knowledge_social_x.py"
REDDIT_HELPER="${SCRIPT_DIR}/knowledge_social_reddit.py"
YOUTUBE_HELPER="${SCRIPT_DIR}/knowledge_social_youtube.py"
LINKEDIN_HELPER="${SCRIPT_DIR}/knowledge_social_linkedin.py"
META_HELPER="${SCRIPT_DIR}/knowledge_social_meta.py"
MEDIUM_HELPER="${SCRIPT_DIR}/knowledge_social_medium.py"
DISCOURSE_HELPER="${SCRIPT_DIR}/knowledge_social_discourse.py"
NODEBB_HELPER="${SCRIPT_DIR}/knowledge_social_nodebb.py"
MASTODON_HELPER="${SCRIPT_DIR}/knowledge_social_mastodon.py"
LEMMY_HELPER="${SCRIPT_DIR}/knowledge_social_lemmy.py"
GITHUB_HELPER="${SCRIPT_DIR}/knowledge_social_github.py"
STACK_EXCHANGE_HELPER="${SCRIPT_DIR}/knowledge_social_stack_exchange.py"
HACKER_NEWS_HELPER="${SCRIPT_DIR}/knowledge_social_hacker_news.py"
HASHNODE_HELPER="${SCRIPT_DIR}/knowledge_social_hashnode.py"
MINIFLUX_HELPER="${SCRIPT_DIR}/knowledge_social_miniflux.py"
READWISE_READER_HELPER="${SCRIPT_DIR}/knowledge_social_readwise_reader.py"
QUERY_HELPER="${SCRIPT_DIR}/knowledge_social_query.py"
SYNC_HELPER="${SCRIPT_DIR}/knowledge_social_sync.py"
SHARE_HELPER="${SCRIPT_DIR}/knowledge_social_share.py"
BROWSER_HELPER="${SCRIPT_DIR}/knowledge_social_browser.py"
OPERATIONS_HELPER="${SCRIPT_DIR}/knowledge_social_operations.py"
REGISTRY_HELPER="${SCRIPT_DIR}/knowledge_social_registry.py"
VAULT_RUNTIME_CHECK="${SCRIPT_DIR}/vault-runtime-check.py"
VAULT_RUNTIME_PYTHON="${HOME:+$HOME/.aidevops/.agent-workspace/python-env/vault/bin/python3}"

usage_operations() {
	cat <<'EOF'
  knowledge-social-helper.sh operation-create [--base PATH] [--alias ALIAS] \
    --connection-id ID --account-id ID --action post|reply|like|bookmark \
    [--target-id ID] [--body-file FILE] [--scheduled-at EPOCH] \
    [--app PROFILE] [--username HANDLE] [--operation-id ID]
  knowledge-social-helper.sh operation-approve [--base PATH] [--alias ALIAS] \
    --operation-id ID --expires-at EPOCH
  knowledge-social-helper.sh operation-revoke|operation-cancel \
    [--base PATH] [--alias ALIAS] --operation-id ID
  knowledge-social-helper.sh operation-run [--base PATH] [--alias ALIAS] \
    --operation-id ID [--executor-id ID] [--claim-seconds 1-3600]
  knowledge-social-helper.sh operations-run-due [--base PATH] [--alias ALIAS] \
    [--executor-id ID] [--claim-seconds 1-3600] [--limit 1-100]
  knowledge-social-helper.sh operations-due|operations-list \
    [--base PATH] [--alias ALIAS] [--operation-id ID] [--limit N]
  knowledge-social-helper.sh operation-reconcile [--base PATH] [--alias ALIAS] \
    --operation-id ID --outcome succeeded|not-sent [--provider-id ID]
  knowledge-social-helper.sh notifications-refresh [--base PATH] [--alias ALIAS]
  knowledge-social-helper.sh notifications-list [--base PATH] [--alias ALIAS] \
    [--status unread|seen|action-required|responded|dismissed] [--limit 1-1000]
  knowledge-social-helper.sh notification-set [--base PATH] [--alias ALIAS] \
    --notification-id ID --status unread|seen|action-required|responded|dismissed

Outbound operations require owner-only knowledge.manage authority. Drafts bind
the account, action, target, private body, local profile selectors, and schedule
to an expiring approval. Due runners verify the stable X identity immediately
before one mapped write attempt. Ambiguous outcomes are never retried; reconcile
them explicitly. Notification commands maintain a local workflow overlay without
mutating mention/reply evidence.

EOF
	return 0
}

usage_sync() {
	cat <<'EOF'
X synchronization:
  sync-x verifies the selected xurl account, then reads one official stream:
  authored, mentions, likes, bookmarks, followers, following, owned_lists,
  followed_lists, or list_memberships. List streams are bounded snapshots with
  independent cursors. --budget is a request-cost allowance from 1 to 1000
  units. Media policy none stores no media rows; metadata stores references
  only, never binary media.

Reddit synchronization:
  sync-reddit verifies the selected PRAW profile, then reads one explicitly
  allowlisted account stream. Listing requests fetch one page with independent
  cursors and a bounded 1-100 item size; plain relationship/custom-feed
  snapshots have a hard 1000-item safety limit. --budget permits 1-1000 request
  units. Collection is read-only and cannot invoke the approval-bound write path.

YouTube synchronization:
  sync-youtube verifies an OAuth user-owned channel, then reads one allowlisted
  stream: authored_videos, channel_activity, owned_playlists, subscriptions,
  comments, or liked_videos. The initial identity request costs one quota unit;
  every page reserves two units: one account rebinding request and one list read.
  --budget is a hard 3-1000 unit limit and --page-size is 1-50 items.
  Collection uses youtube.readonly user OAuth and never the service-account helper.

LinkedIn synchronization:
  sync-linkedin verifies the selected member authorization, then reads one
  documented Member Snapshot domain. Access is limited to eligible EEA or Swiss
  members and a provisioned Member Data Portability product. The initial identity
  request costs one unit; every page reserves two units for identity rebinding and
  one GET-only snapshot read. --budget is 3-1000 and --page-size is 1-50.

Meta synchronization:
  sync-meta selects exactly one facebook, instagram, or threads identity and
  one product-specific GET-only stream. Facebook supports managed Page posts;
  Instagram supports Professional-account media; Threads supports posts,
  authored replies, and mentions. Every page revalidates the selected product
  identity. --budget is 3-1000 and --page-size is 1-50.

Discourse synchronization:
  sync-discourse verifies the current user and exact HTTPS installation before
  every allowlisted GET page. Each profile must declare a User API key with the
  exact read scope. Installation fingerprints namespace account and resource IDs
  without exposing private hosts. --budget is 3-1000 and --page-size is 1-20.

NodeBB synchronization:
  sync-nodebb binds a dedicated user bearer token to GET /api/self and one exact
  HTTPS installation before every bounded core read. Master tokens, admin routes,
  plugin routes, redirects, and mutations are unreachable. Installation-local
  IDs are keyed and namespaced. --budget is 3-1000 and --page-size is 1-50.

Mastodon synchronization:
  sync-mastodon binds one user token to GET /api/v1/accounts/verify_credentials
  on an exact HTTPS home instance before every page. Eight independent streams
  preserve same-origin RFC Link pagination without interpreting opaque IDs.
  Write scopes, redirects, cross-origin links, and mutations are rejected.
  --budget is 3-1000 and --page-size is 1-100.

Lemmy synchronization:
  sync-lemmy discovers the exact server version and selected local person through
  GET /api/v3/site before every page. Lemmy 1.x uses only v4 opaque-cursor routes;
  0.19.x uses only v3 numeric-page routes. Installation-local IDs are namespaced,
  ActivityPub IDs are retained, and every request is same-origin GET-only.
  --budget is 3-1000 and --page-size is 1-50.

GitHub synchronization:
  sync-github binds REST /user numeric and node IDs to GraphQL viewer identity
  before every page. Ten independent streams use exact REST GET routes or fixed
  GraphQL read queries. REST Link targets and GraphQL pageInfo cursors remain
  opaque; REST writes, GraphQL mutations, and redirects are unreachable.
  --budget is 5-1000 and --page-size is 1-100.

Stack Exchange synchronization:
  sync-stack-exchange binds one network account ID to a selected API site and
  site user ID before every page. Eight GET-only streams stop on backoff or quota
  exhaustion, continue only while has_more, and cap pages at 100 items.
  --budget is 3-1000 and --page-size is 1-100.

Hacker News synchronization:
  sync-hacker-news observes one exact case-sensitive public username selector;
  it never claims authenticated or immutable account identity. One bounded
  submitted-ID slice resolves only official Firebase user/item GET routes.
  --profile must be public, --budget is 3-1000 request units, and --page-size
  is a 1-100 item slice limit.

Miniflux synchronization:
  sync-miniflux binds one user ID to a keyed exact HTTPS installation before
  every page. Entries, read, removed, starred, tags, feeds, categories, and OPML
  use GET-only routes. Entry streams resume by ascending ID and overlap
  changed_after by one second. --budget is 3-1000 and --page-size is 1-100.

Readwise Reader synchronization:
  sync-readwise-reader requires a deployment-owned account ID plus keyed expected
  token binding before fixed-origin token validation. Seven GET-only streams use
  opaque cursors and one-second updatedAfter overlap. The per-invocation request
  budget is 3-19 to remain below the documented 20/minute limit.

EOF
	return 0
}

usage_sync_hashnode() {
	cat <<'EOF'
Hashnode synchronization:
  sync-hashnode binds the authenticated viewer ID and username before every
  fixed GraphQL read page. Eight independent streams reject arbitrary GraphQL,
  mutations, partial errors, redirects, and unowned resources.
  --budget is 3-1000 and --page-size is 1-50.

EOF
	return 0
}

usage_commands() {
	cat <<'EOF'
Usage:
  knowledge-social-helper.sh provision [--base PATH] [--alias ALIAS]
  knowledge-social-helper.sh import-archive [--base PATH] [--alias ALIAS] --archive FILE
  knowledge-social-helper.sh import-medium-archive [--base PATH] [--alias ALIAS] \
    --archive FILE --connection-id ID --account-id MEDIUM_USER_ID \
    --exported-at ISO_TIME [--username HANDLE] [--max-items N] [--max-bytes N] \
    [--collector-id ID] [--lease-seconds SECONDS]
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
  knowledge-social-helper.sh sync-reddit [--base PATH] [--alias ALIAS] \
    --connection-id ID --account-id ID --stream STREAM --profile PROFILE \
    [--budget UNITS] [--page-size 1-100] [--collector-id ID] \
    [--lease-seconds SECONDS]
  knowledge-social-helper.sh sync-youtube [--base PATH] [--alias ALIAS] \
    --connection-id ID --account-id CHANNEL_ID --stream STREAM --profile PROFILE \
    [--budget UNITS] [--page-size 1-50] [--collector-id ID] \
    [--lease-seconds SECONDS]
  knowledge-social-helper.sh sync-linkedin [--base PATH] [--alias ALIAS] \
    --connection-id ID --account-id MEMBER_ID --stream STREAM --profile PROFILE \
    [--budget UNITS] [--page-size 1-50] [--collector-id ID] \
    [--lease-seconds SECONDS]
  knowledge-social-helper.sh sync-meta --product facebook|instagram|threads \
    [--base PATH] [--alias ALIAS] --connection-id ID --account-id GRAPH_ID \
    --stream STREAM --profile PROFILE [--budget UNITS] [--page-size 1-50] \
    [--collector-id ID] [--lease-seconds SECONDS]
  knowledge-social-helper.sh sync-discourse [--base PATH] [--alias ALIAS] \
    --connection-id ID --account-id USER_NUMERIC_ID --stream STREAM \
    --profile PROFILE [--budget UNITS] [--page-size 1-20] \
    [--collector-id ID] [--lease-seconds SECONDS]
  knowledge-social-helper.sh sync-nodebb [--base PATH] [--alias ALIAS] \
    --connection-id ID --account-id USER_NUMERIC_ID --stream STREAM \
    --profile PROFILE [--budget UNITS] [--page-size 1-50] \
    [--collector-id ID] [--lease-seconds SECONDS]
  knowledge-social-helper.sh sync-mastodon [--base PATH] [--alias ALIAS] \
    --connection-id ID --account-id OPAQUE_HOME_ACCOUNT_ID --stream STREAM \
    --profile PROFILE [--budget UNITS] [--page-size 1-100] \
    [--collector-id ID] [--lease-seconds SECONDS]
  knowledge-social-helper.sh sync-lemmy [--base PATH] [--alias ALIAS] \
    --connection-id ID --account-id PERSON_NUMERIC_ID --stream STREAM \
    --profile PROFILE [--budget UNITS] [--page-size 1-50] \
    [--collector-id ID] [--lease-seconds SECONDS]
  knowledge-social-helper.sh sync-github [--base PATH] [--alias ALIAS] \
    --connection-id ID --account-id NUMERIC_ACCOUNT_ID --stream STREAM \
    --profile PROFILE [--budget UNITS] [--page-size 1-100] \
    [--collector-id ID] [--lease-seconds SECONDS]
  knowledge-social-helper.sh sync-stack-exchange [--base PATH] [--alias ALIAS] \
    --connection-id ID --account-id NETWORK_ACCOUNT_ID --stream STREAM \
    --profile PROFILE [--budget UNITS] [--page-size 1-100] \
    [--collector-id ID] [--lease-seconds SECONDS]
  knowledge-social-helper.sh sync-hacker-news [--base PATH] [--alias ALIAS] \
    --connection-id ID --account-id CASE_SENSITIVE_USERNAME --stream submitted \
    --profile public [--budget UNITS] [--page-size 1-100] \
    [--collector-id ID] [--lease-seconds SECONDS]
  knowledge-social-helper.sh sync-hashnode [--base PATH] [--alias ALIAS] \
    --connection-id ID --account-id HASHNODE_ACCOUNT_ID --stream STREAM \
    --profile PROFILE [--budget UNITS] [--page-size 1-50] \
    [--collector-id ID] [--lease-seconds SECONDS]
  knowledge-social-helper.sh sync-miniflux [--base PATH] [--alias ALIAS] \
    --connection-id ID --account-id USER_NUMERIC_ID --stream STREAM \
    --profile PROFILE [--budget UNITS] [--page-size 1-100] \
    [--collector-id ID] [--lease-seconds SECONDS]
  knowledge-social-helper.sh sync-readwise-reader [--base PATH] [--alias ALIAS] \
    --connection-id ID --account-id DEPLOYMENT_ACCOUNT_ID --stream STREAM \
    --profile PROFILE [--budget 3-19] [--page-size 1-100] \
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
  knowledge-social-helper.sh providers
  knowledge-social-helper.sh provider-resolve --provider PROVIDER
  knowledge-social-helper.sh provider-run --provider PROVIDER --mode MODE -- [ARGS]
EOF
	return 0
}

usage() {
	usage_commands
	usage_operations
	cat <<'EOF'
  knowledge-social-helper.sh identity-export [--base PATH] [--vault-dir DIR] --output FILE
  knowledge-social-helper.sh workspace-create [--base PATH] --alias ALIAS [--vault-dir DIR]
  knowledge-social-helper.sh workspace-grant [--base PATH] --alias ALIAS \
    [--vault-dir DIR] --recipient FILE [--capability knowledge.read|knowledge.write] \
    --output FILE
  knowledge-social-helper.sh workspace-accept [--base PATH] --alias ALIAS \
    [--vault-dir DIR] --sender FILE --grant FILE
  knowledge-social-helper.sh share-export [--base PATH] --alias ALIAS \
    [--vault-dir DIR] --output FILE [--expires-at EPOCH]
  knowledge-social-helper.sh share-import [--base PATH] --alias ALIAS \
    [--vault-dir DIR] --sender FILE --batch FILE
  knowledge-social-helper.sh workspace-revoke [--base PATH] --alias ALIAS \
    [--vault-dir DIR] --principal-id ID --output FILE
  knowledge-social-helper.sh revocation-apply [--base PATH] --alias ALIAS \
    --sender FILE --revocation FILE
  knowledge-social-helper.sh provider-validate --manifest FILE
  knowledge-social-helper.sh capture-browser-gap [--base PATH] [--alias ALIAS] \
    --manifest FILE --gap FILE --capture FILE [--max-items 1-1000] \
    [--max-bytes 1024-10485760]

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

Medium account export:
  import-medium-archive accepts only a native HTML ZIP export with exactly one
  profile/profile.html and a matching explicit Medium user ID. It performs no
  provider requests, extracts no files, rejects unsafe ZIP members and
  credential-shaped HTML attributes or URL queries, applies item/byte limits,
  and stores the original ZIP content-addressed before committing normalized
  rows and coverage.

EOF
	usage_sync
	usage_sync_hashnode
	cat <<'EOF'
Deterministic routines:
  sync-due and reconcile-due return sorted privacy-safe work plans. Every sync or
  reconciliation owns one expiring connection lease and monotonic fencing token;
  normalized rows, checkpoints, and the run receipt commit in one transaction.
  Reconciliation snapshots must be private JSON files and mark remote absence as
  missing evidence. They never purge canonical content.

Browser gap capture:
  Browser input is accepted only for a provider-declared stream after a private
  gap record proves official API/archive coverage is unavailable or partial.
  Capture files are read-only artifacts from an approved profile; this helper
  cannot launch a browser or perform a platform write. Item and byte limits are
  hard bounds, and replay is content-addressed and idempotent.

Provider registry:
  providers and provider-resolve expose deterministic privacy-safe capability
  metadata. provider-run resolves only an exact canonical ID or declared alias,
  requires an explicit supported mode, and executes one allowlisted local
  read/import adapter without eval or fallback. A no-route provider always fails.

Encrypted workspace sharing:
  Public identity and grant files contain only opaque IDs, public keys, and signed
  metadata. Shared snapshots are encrypted once with a random AES-256-GCM content
  key and wrapped separately to each active Vault message-device X25519 key. The
  recipient authorizes the signed header before decryption and rebuilds SQLite/FTS
  locally. Revocation blocks local query first and excludes the member from every
  later key generation; it cannot erase plaintext already delivered to a device.
EOF
	return 0
}

resolve_share_python() {
	local managed_python="$VAULT_RUNTIME_PYTHON"
	if [[ "${AIDEVOPS_VAULT_TEST_MODE:-0}" == "1" && -n "${AIDEVOPS_VAULT_PYTHON:-}" ]]; then
		managed_python="$AIDEVOPS_VAULT_PYTHON"
		if [[ -x "$managed_python" && -r "$VAULT_RUNTIME_CHECK" ]] &&
			"$managed_python" "$VAULT_RUNTIME_CHECK" >/dev/null 2>&1; then
			printf '%s\n' "$managed_python"
			return 0
		fi
		printf 'ERROR: managed Vault test crypto runtime failed verification\n' >&2
		return 1
	fi
	local env_dir="${managed_python%/bin/python3}"
	local marker="${env_dir}/.aidevops-managed-runtime"
	local marker_value=""
	if [[ ! -x "$managed_python" || ! -r "$VAULT_RUNTIME_CHECK" || ! -x /usr/bin/python3 ||
		! -f "$marker" || -L "$marker" ]]; then
		printf 'ERROR: managed Vault crypto runtime is unavailable; run aidevops setup\n' >&2
		return 1
	fi
	marker_value=$(<"$marker")
	if [[ "$marker_value" != "aidevops-vault-runtime-v1" ]] ||
		! /usr/bin/python3 "$VAULT_RUNTIME_CHECK" --check-ancestors "$HOME" "$env_dir" >/dev/null 2>&1 ||
		! /usr/bin/python3 "$VAULT_RUNTIME_CHECK" --check-path "$env_dir" "$marker" >/dev/null 2>&1 ||
		! "$managed_python" "$VAULT_RUNTIME_CHECK" >/dev/null 2>&1; then
		printf 'ERROR: managed Vault crypto runtime failed verification\n' >&2
		return 1
	fi
	printf '%s\n' "$managed_python"
	return 0
}

run_share_command() {
	local subcommand="$1"
	shift || true
	if [[ ! -r "$SHARE_HELPER" ]]; then
		printf 'ERROR: encrypted social sharing implementation missing: %s\n' "$SHARE_HELPER" >&2
		return 1
	fi
	local python_bin=""
	python_bin=$(resolve_share_python) || return 1
	PATH="${python_bin%/*}:${PATH}" "$python_bin" "$SHARE_HELPER" "$subcommand" "$@" || return 1
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

run_medium_import() {
	require_runtime || return 1
	if [[ ! -r "$MEDIUM_HELPER" ]]; then
		printf 'ERROR: Medium archive adapter missing: %s\n' "$MEDIUM_HELPER" >&2
		return 1
	fi
	python3 "$MEDIUM_HELPER" "$@" || return 1
	return 0
}

run_provider_sync() {
	local provider_name="$1"
	local provider_helper="$2"
	shift 2 || return 1
	require_runtime || return 1
	if [[ ! -r "$provider_helper" ]]; then
		printf 'ERROR: %s social adapter missing: %s\n' "$provider_name" "$provider_helper" >&2
		return 1
	fi
	python3 "$provider_helper" "$@" || return 1
	return 0
}

run_named_provider_sync() {
	local subcommand="$1"
	shift || return 1
	case "$subcommand" in
	sync-meta) run_provider_sync Meta "$META_HELPER" "$@" || return 1 ;;
	sync-discourse) run_provider_sync Discourse "$DISCOURSE_HELPER" "$@" || return 1 ;;
	sync-nodebb) run_provider_sync NodeBB "$NODEBB_HELPER" "$@" || return 1 ;;
	sync-mastodon) run_provider_sync Mastodon "$MASTODON_HELPER" "$@" || return 1 ;;
	sync-lemmy) run_provider_sync Lemmy "$LEMMY_HELPER" "$@" || return 1 ;;
	sync-github) run_provider_sync GitHub "$GITHUB_HELPER" "$@" || return 1 ;;
	sync-stack-exchange) run_provider_sync "Stack Exchange" "$STACK_EXCHANGE_HELPER" "$@" || return 1 ;;
	sync-hacker-news) run_provider_sync "Hacker News" "$HACKER_NEWS_HELPER" "$@" || return 1 ;;
	sync-hashnode) run_provider_sync Hashnode "$HASHNODE_HELPER" "$@" || return 1 ;;
	sync-miniflux) run_provider_sync Miniflux "$MINIFLUX_HELPER" "$@" || return 1 ;;
	sync-readwise-reader) run_provider_sync "Readwise Reader" "$READWISE_READER_HELPER" "$@" || return 1 ;;
	*) return 1 ;;
	esac
	return 0
}

run_registry_command() {
	local subcommand="$1"
	shift || return 1
	require_runtime || return 1
	if [[ ! -r "$REGISTRY_HELPER" ]]; then
		printf 'ERROR: social provider registry missing: %s\n' "$REGISTRY_HELPER" >&2
		return 1
	fi
	case "$subcommand" in
	providers) python3 "$REGISTRY_HELPER" list "$@" || return 1 ;;
	provider-resolve) python3 "$REGISTRY_HELPER" resolve "$@" || return 1 ;;
	provider-run) python3 "$REGISTRY_HELPER" run "$@" || return 1 ;;
	*) return 1 ;;
	esac
	return 0
}

run_query_command() {
	local subcommand="$1"
	shift || return 1
	require_runtime || return 1
	if [[ ! -r "$QUERY_HELPER" ]]; then
		printf 'ERROR: social query implementation missing: %s\n' "$QUERY_HELPER" >&2
		return 1
	fi
	python3 "$QUERY_HELPER" "$subcommand" "$@" || return 1
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
	import-medium-archive)
		run_medium_import "$@" || return 1
		;;
	sync-x)
		require_runtime || return 1
		if [[ ! -r "$X_HELPER" ]]; then
			printf 'ERROR: X social adapter missing: %s\n' "$X_HELPER" >&2
			return 1
		fi
		python3 "$X_HELPER" "$@" || return 1
		;;
	sync-reddit)
		require_runtime || return 1
		if [[ ! -r "$REDDIT_HELPER" ]]; then
			printf 'ERROR: Reddit social adapter missing: %s\n' "$REDDIT_HELPER" >&2
			return 1
		fi
		python3 "$REDDIT_HELPER" "$@" || return 1
		;;
	sync-youtube)
		require_runtime || return 1
		if [[ ! -r "$YOUTUBE_HELPER" ]]; then
			printf 'ERROR: YouTube social adapter missing: %s\n' "$YOUTUBE_HELPER" >&2
			return 1
		fi
		python3 "$YOUTUBE_HELPER" "$@" || return 1
		;;
	sync-linkedin)
		require_runtime || return 1
		if [[ ! -r "$LINKEDIN_HELPER" ]]; then
			printf 'ERROR: LinkedIn social adapter missing: %s\n' "$LINKEDIN_HELPER" >&2
			return 1
		fi
		python3 "$LINKEDIN_HELPER" "$@" || return 1
		;;
	sync-meta | sync-discourse | sync-nodebb | sync-mastodon | sync-lemmy | sync-github | sync-stack-exchange | sync-hacker-news | sync-hashnode | sync-miniflux | sync-readwise-reader)
		run_named_provider_sync "$subcommand" "$@" || return 1
		;;
	query | annotate)
		run_query_command "$subcommand" "$@" || return 1
		;;
	provider-validate | capture-browser-gap)
		require_runtime || return 1
		if [[ ! -r "$BROWSER_HELPER" ]]; then
			printf 'ERROR: social browser adapter missing: %s\n' "$BROWSER_HELPER" >&2
			return 1
		fi
		python3 "$BROWSER_HELPER" "$subcommand" "$@" || return 1
		;;
	providers | provider-resolve | provider-run)
		run_registry_command "$subcommand" "$@" || return 1
		;;
	sync-due | reconcile-due | reconcile | receipts)
		require_runtime || return 1
		if [[ ! -r "$SYNC_HELPER" ]]; then
			printf 'ERROR: social sync implementation missing: %s\n' "$SYNC_HELPER" >&2
			return 1
		fi
		python3 "$SYNC_HELPER" "$subcommand" "$@" || return 1
		;;
	operation-create | operation-approve | operation-revoke | operation-cancel | operation-run | operations-run-due | operations-due | operations-list | operation-reconcile | notifications-refresh | notifications-list | notification-set)
		require_runtime || return 1
		if [[ ! -r "$OPERATIONS_HELPER" ]]; then
			printf 'ERROR: social operations implementation missing: %s\n' "$OPERATIONS_HELPER" >&2
			return 1
		fi
		python3 "$OPERATIONS_HELPER" "$subcommand" "$@" || return 1
		;;
	identity-export | workspace-create | workspace-grant | workspace-accept | share-export | share-import | workspace-revoke | revocation-apply)
		run_share_command "$subcommand" "$@" || return 1
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

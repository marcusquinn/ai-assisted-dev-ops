#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# peer-productivity-monitor.sh — adaptive cross-runner dispatch coordination (t2932)
#
# Observes peer GitHub activity and updates dispatch-override.conf automatically:
#   - When peer's pulse degrades (their workers claim issues but never PR),
#     this monitor flips them to `ignore` so our pulse can compete.
#   - When peer's pulse recovers (their workers start merging again),
#     monitor flips them back to `honour` so collaboration resumes.
#
# Self-healing across the ecosystem: each runner observes peers independently,
# no central coordinator needed. When one runner regresses in a release,
# every other runner detects and routes around them within ~30 min.
#
# Architecture:
#   - Runs every 30 min via launchd (sh.aidevops.peer-productivity-monitor.plist)
#   - Per-peer rolling 24h window stats
#   - Distinguishes worker PRs (origin:worker) from interactive PRs
#     (origin:interactive) — peer's human work never triggers ignore mode
#   - Hysteresis: 3 consecutive same-vote required to flip (avoid flapping)
#   - Manages a section of dispatch-override.conf between BEGIN/END markers
#     — manual entries above the marker are sticky (user override always wins)
#
# Usage:
#   peer-productivity-monitor.sh observe        # one observation cycle (called by launchd)
#   peer-productivity-monitor.sh report         # show current state + decisions
#   peer-productivity-monitor.sh dry-run        # observe without writing config
#   peer-productivity-monitor.sh reset <peer>   # reset hysteresis state for a peer
#
# Decision rules per peer:
#   - 0 worker PRs merged in 24h + 2+ origin:worker claims = vote `ignore` (peer broken)
#   - 1+ worker PRs merged in 24h = vote `honour` (peer healthy)
#   - 0 merged PRs + 0–1 worker claims = vote `keep` (insufficient signal, no change)
#
# Default for unknown peers: ignore (compete-by-default — safer for new peers
# until they prove productivity).
#
# Env:
#   AIDEVOPS_PEER_MONITOR_DISABLE=1   — short-circuit, do nothing
#   AIDEVOPS_PEER_MONITOR_DRY_RUN=1   — observe + log, don't write config
#   AIDEVOPS_PEER_MONITOR_WINDOW_H=24 — rolling window in hours (default 24)
#   AIDEVOPS_PEER_MONITOR_HYSTERESIS=3 — vote count for flip (default 3)

set -euo pipefail

# ============================================================================
# Setup
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source shared constants if available (color codes, log helpers).
if [[ -f "${SCRIPT_DIR}/shared-constants.sh" ]]; then
	# shellcheck source=/dev/null
	source "${SCRIPT_DIR}/shared-constants.sh"
else
	# Fallback when not deployed
	[[ -z "${RED+x}" ]] && RED=''
	[[ -z "${GREEN+x}" ]] && GREEN=''
	[[ -z "${YELLOW+x}" ]] && YELLOW=''
	[[ -z "${BLUE+x}" ]] && BLUE=''
	[[ -z "${NC+x}" ]] && NC=''
fi

# Config paths
OVERRIDE_CONF="${HOME}/.config/aidevops/dispatch-override.conf"
STATE_DIR="${HOME}/.aidevops/state"
STATE_FILE="${STATE_DIR}/peer-productivity-state.json"
LOG_FILE="${HOME}/.aidevops/logs/peer-productivity.log"
REPOS_JSON="${HOME}/.config/aidevops/repos.json"

# Markers for managed section of override config
MARKER_BEGIN="# BEGIN auto-managed by peer-productivity-monitor (t2932)"
MARKER_END="# END auto-managed by peer-productivity-monitor"

# Defaults
WINDOW_HOURS="${AIDEVOPS_PEER_MONITOR_WINDOW_H:-24}"
HYSTERESIS="${AIDEVOPS_PEER_MONITOR_HYSTERESIS:-3}"
DRY_RUN="${AIDEVOPS_PEER_MONITOR_DRY_RUN:-0}"

# Vote / action constants — keep in sync with _sanitize_action.
readonly ACTION_HONOUR="honour"
readonly ACTION_IGNORE="ignore"
readonly ACTION_KEEP="keep"

# Bot account suffixes / patterns to skip (we never compete with bots)
BOT_PATTERNS=("[bot]" "-bot" "dependabot" "renovate" "github-actions")

mkdir -p "$STATE_DIR" "$(dirname "$LOG_FILE")"

# ============================================================================
# Logging
# ============================================================================

log_msg() {
	local level="$1"
	shift
	local msg="$*"
	local ts
	ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
	printf '%s %s %s\n' "$ts" "$level" "$msg" >>"$LOG_FILE"
	return 0
}

# ============================================================================
# Helpers
# ============================================================================

# Return 0 if login matches a bot pattern.
_is_bot() {
	local login="$1"
	local pattern
	for pattern in "${BOT_PATTERNS[@]}"; do
		if [[ "$login" == *"$pattern"* ]]; then
			return 0
		fi
	done
	return 1
}

# Get our own GitHub login.
_self_login() {
	gh api user --jq '.login' 2>/dev/null || echo ""
	return 0
}

# List pulse-enabled repos with GitHub remotes from repos.json.
# Output: one slug per line.
_list_pulse_repos() {
	if [[ ! -f "$REPOS_JSON" ]]; then
		return 0
	fi
	jq -r '.initialized_repos[]
		| select(.maintenance != false)
		| select(.pulse == true)
		| select(.local_only != true)
		| select(.slug != null and .slug != "")
		| .slug' "$REPOS_JSON" 2>/dev/null || true
	return 0
}

# Convert a GitHub login to its DISPATCH_OVERRIDE_<UPPER> variable name.
_login_to_var() {
	local login="$1"
	printf '%s' "$login" | tr 'a-z-' 'A-Z_'
	return 0
}

# Sanitize a single value for shell config. Keep simple alnum + a few safe chars.
_sanitize_action() {
	local v="$1"
	case "$v" in
		ignore | honour | warn) printf '%s' "$v" ;;
		*) printf '%s' "$ACTION_HONOUR" ;;
	esac
	return 0
}

# ============================================================================
# Observation
# ============================================================================

# For a given peer, count active claims and worker PRs in window.
# Outputs JSON: {"login": ..., "active_claims": N, "worker_prs": N, "interactive_prs": N}
_observe_peer() {
	local login="$1"
	local repo="$2"
	local since_iso="$3"

	local active_claims=0
	local worker_prs=0
	local interactive_prs=0

	# Active worker claims: open issues with origin:worker label assigned to peer.
	# Filtering by label ensures interactive work never counts as a broken-pulse
	# signal — only automated worker claims matter for productivity assessment.
	local claims_json
	claims_json=$(gh issue list --repo "$repo" --assignee "$login" --state open \
		--label origin:worker \
		--limit 100 --json number 2>/dev/null || echo '[]')
	active_claims=$(printf '%s' "$claims_json" | jq 'length' 2>/dev/null || echo 0)

	# Worker PRs merged in window (peer is author + origin:worker label).
	local worker_json
	worker_json=$(gh pr list --repo "$repo" --author "$login" --state merged \
		--label origin:worker --limit 50 \
		--json number,mergedAt 2>/dev/null || echo '[]')
	worker_prs=$(printf '%s' "$worker_json" | jq --arg since "$since_iso" \
		'[.[] | select(.mergedAt > $since)] | length' 2>/dev/null || echo 0)

	# Interactive PRs (informational only — never triggers ignore).
	local interactive_json
	interactive_json=$(gh pr list --repo "$repo" --author "$login" --state merged \
		--label origin:interactive --limit 50 \
		--json number,mergedAt 2>/dev/null || echo '[]')
	interactive_prs=$(printf '%s' "$interactive_json" | jq --arg since "$since_iso" \
		'[.[] | select(.mergedAt > $since)] | length' 2>/dev/null || echo 0)

	jq -nc \
		--arg login "$login" \
		--arg repo "$repo" \
		--argjson active_claims "$active_claims" \
		--argjson worker_prs "$worker_prs" \
		--argjson interactive_prs "$interactive_prs" \
		'{login: $login, repo: $repo,
		  active_claims: $active_claims,
		  worker_prs: $worker_prs,
		  interactive_prs: $interactive_prs}'
	return 0
}

# Convert one repository observation into a bounded 0-100 lane fitness input.
# Existing honour/ignore hysteresis remains authoritative; this score is only
# an additive planning signal for the default-off campaign projection.
_repository_fitness() {
	local active_claims="$1"
	local worker_prs="$2"
	[[ "$active_claims" =~ ^[0-9]+$ ]] || active_claims=0
	[[ "$worker_prs" =~ ^[0-9]+$ ]] || worker_prs=0
	if [[ "$worker_prs" -gt 0 ]]; then
		local score=$((60 + worker_prs * 10))
		[[ "$score" -gt 100 ]] && score=100
		printf '%s' "$score"
	elif [[ "$active_claims" -ge 2 ]]; then
		printf '15'
	else
		printf '50'
	fi
	return 0
}

# Aggregate line-delimited per-repository observations by peer while retaining
# a bounded repository map for campaign fitness. Reads JSONL from stdin.
_aggregate_peer_observations() {
	jq -s '
		def fitness:
			if .worker_prs > 0 then ([100, (60 + (.worker_prs * 10))] | min)
			elif .active_claims >= 2 then 15
			else 50
			end;
		group_by(.login) | map(
			. as $observations |
			{
				login: .[0].login,
				active_claims: (map(.active_claims) | add),
				worker_prs: (map(.worker_prs) | add),
				interactive_prs: (map(.interactive_prs) | add),
				repos: (map(.repo) | unique | sort),
				repositories: (reduce $observations[] as $observation ({};
					.[$observation.repo] = {
						active_claims: $observation.active_claims,
						worker_prs: $observation.worker_prs,
						interactive_prs: $observation.interactive_prs,
						fitness: ($observation | fitness)
					}
				) | to_entries | sort_by(.key) | .[0:100] | from_entries)
			}
		)'
	return 0
}

_attach_repository_observations() {
	local peer_state="$1"
	local login="$2"
	local repositories="$3"
	printf '%s' "$peer_state" | jq --arg l "$login" --argjson repositories "$repositories" \
		'.[$l].repositories = $repositories | .[$l].repos = ($repositories | keys)'
	return 0
}

# Discover all peers across all pulse-enabled repos.
# Outputs JSON array: [{"login": ..., "active_claims": N, ...}, ...]
# Aggregated across repos (sums active_claims, worker_prs, interactive_prs).
discover_and_observe() {
	local self_login since_iso
	self_login="$(_self_login)"
	# Compute since timestamp
	since_iso=$(date -u -v "-${WINDOW_HOURS}H" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null ||
		date -u -d "${WINDOW_HOURS} hours ago" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null ||
		echo "1970-01-01T00:00:00Z")

	log_msg INFO "discover_and_observe: self=$self_login window_since=$since_iso"

	local -a observations=()
	local repo

	while IFS= read -r repo; do
		[[ -z "$repo" ]] && continue
		log_msg DEBUG "scanning repo=$repo"

		# Find all logins that have authored merged PRs OR have active assignments
		# in this repo over the window. Both populated peers and silent peers
		# (claims but no PRs) are surfaced.

		local peer_logins=()

		# From assignees on open issues
		local assigned_json
		assigned_json=$(gh issue list --repo "$repo" --state open \
			--limit 200 --json assignees 2>/dev/null || echo '[]')
		while IFS= read -r login; do
			[[ -z "$login" ]] && continue
			[[ "$login" == "$self_login" ]] && continue
			_is_bot "$login" && continue
			peer_logins+=("$login")
		done < <(printf '%s' "$assigned_json" |
			jq -r '.[].assignees[].login' 2>/dev/null | sort -u)

		# From recent merged PR authors
		local pr_json
		pr_json=$(gh pr list --repo "$repo" --state merged --limit 50 \
			--json author,mergedAt 2>/dev/null || echo '[]')
		while IFS= read -r login; do
			[[ -z "$login" ]] && continue
			[[ "$login" == "$self_login" ]] && continue
			_is_bot "$login" && continue
			peer_logins+=("$login")
		done < <(printf '%s' "$pr_json" |
			jq -r --arg since "$since_iso" \
				'.[] | select(.mergedAt > $since) | .author.login' 2>/dev/null | sort -u)

		# Dedupe
		local unique_peers=()
		while IFS= read -r p; do
			[[ -z "$p" ]] && continue
			unique_peers+=("$p")
		done < <(printf '%s\n' "${peer_logins[@]:-}" | sort -u)

		local peer
		for peer in "${unique_peers[@]:-}"; do
			[[ -z "$peer" ]] && continue
			local obs
			obs=$(_observe_peer "$peer" "$repo" "$since_iso")
			observations+=("$obs")
		done
	done < <(_list_pulse_repos)

	# Aggregate across repos by login
	if [[ ${#observations[@]} -eq 0 ]]; then
		printf '[]\n'
		return 0
	fi

	printf '%s\n' "${observations[@]}" | _aggregate_peer_observations
	return 0
}

# ============================================================================
# Decision logic + hysteresis
# ============================================================================

# Compute vote for a peer: ignore | honour | keep
#
# Ratio-based decision:
#   - merges >= 1                        → honour  (peer is productive)
#   - merges == 0 && claims >= 2         → ignore  (peer is broken: claims but never delivers)
#   - merges == 0 && claims 0–1          → keep    (insufficient data; 1 in-flight task is normal)
_vote_for_peer() {
	local active_claims="$1"
	local worker_prs="$2"

	if [[ "$worker_prs" -ge 1 ]]; then
		printf '%s' "$ACTION_HONOUR"
	elif [[ "$active_claims" -ge 2 ]]; then
		printf '%s' "$ACTION_IGNORE"
	else
		printf '%s' "$ACTION_KEEP"
	fi
	return 0
}

# Read state file, return JSON (or empty object if missing).
_load_state() {
	if [[ -f "$STATE_FILE" ]]; then
		cat "$STATE_FILE" 2>/dev/null || echo '{}'
	else
		echo '{}'
	fi
	return 0
}

# Apply hysteresis to a peer's new vote. Returns the resolved action:
# ignore | honour. Updates state in place via stdout (caller saves).
#
# Args:
#   $1 = current state JSON
#   $2 = login
#   $3 = new vote (ignore | honour | keep)
# Output: updated state JSON for this peer
_apply_hysteresis() {
	local state_json="$1"
	local login="$2"
	local vote="$3"

	# Get existing peer state
	local peer_state
	peer_state=$(printf '%s' "$state_json" | jq --arg l "$login" '.[$l] // {}')

	# Existing fields
	local current_action
	current_action=$(printf '%s' "$peer_state" | jq -r --arg default "$ACTION_HONOUR" '.current_action // $default')
	local history_json
	history_json=$(printf '%s' "$peer_state" | jq -c '.vote_history // []')

	# "keep" vote: preserve current state, append to history (truncated)
	if [[ "$vote" == "keep" ]]; then
		# Append "keep" but don't change action
		history_json=$(printf '%s' "$history_json" |
			jq --arg v "$vote" --argjson max "$HYSTERESIS" \
				'. + [$v] | if length > ($max + 2) then .[(-($max + 2)):] else . end')
		jq -nc --arg l "$login" \
			--arg ca "$current_action" \
			--argjson h "$history_json" \
			--arg ts "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
			'{($l): {current_action: $ca, vote_history: $h, last_observed: $ts}}'
		return 0
	fi

	# Append the new vote, keep last (HYSTERESIS+2) entries
	history_json=$(printf '%s' "$history_json" |
		jq --arg v "$vote" --argjson max "$HYSTERESIS" \
			'. + [$v] | if length > ($max + 2) then .[(-($max + 2)):] else . end')

	# Determine if we should flip: last HYSTERESIS entries all match `vote`,
	# and `vote` differs from `current_action`. Use `-r` so jq emits the raw
	# string `yes`/`no`, not the JSON-quoted form `"yes"`/`"no"` — the bash
	# comparison below would otherwise never match.
	local should_flip
	should_flip=$(printf '%s' "$history_json" |
		jq -r --arg v "$vote" --argjson n "$HYSTERESIS" --arg ca "$current_action" \
			'if length >= $n and (.[(-$n):] | all(. == $v)) and ($v != $ca) then "yes" else "no" end')

	local new_action="$current_action"
	if [[ "$should_flip" == "yes" ]]; then
		new_action="$vote"
		log_msg INFO "FLIP: peer=$login action=$current_action -> $new_action (last $HYSTERESIS votes all '$vote')"
	fi

	jq -nc --arg l "$login" \
		--arg ca "$new_action" \
		--argjson h "$history_json" \
		--arg ts "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
		'{($l): {current_action: $ca, vote_history: $h, last_observed: $ts}}'
	return 0
}

# ============================================================================
# Override config rewrite
# ============================================================================

# Rewrite the managed section of dispatch-override.conf based on state.
# Manual entries above the BEGIN marker are preserved verbatim. Anything
# between BEGIN and END markers is replaced. Anything after END is preserved.
_rewrite_override_config() {
	local state_json="$1"

	# Build the managed section content
	local managed_lines=""
	managed_lines+="${MARKER_BEGIN}"$'\n'
	managed_lines+="# Auto-updated by peer-productivity-monitor every 30 min."$'\n'
	managed_lines+="# Last rewrite: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"$'\n'
	managed_lines+="# To pin a peer manually, add an entry ABOVE this marker — manual"$'\n'
	managed_lines+="# entries take precedence and are never overwritten."$'\n'
	managed_lines+=""$'\n'

	# Extract per-peer entries
	local peers
	peers=$(printf '%s' "$state_json" | jq -r 'keys[]' 2>/dev/null || true)
	if [[ -n "$peers" ]]; then
		while IFS= read -r peer; do
			[[ -z "$peer" ]] && continue
			local action
			action=$(printf '%s' "$state_json" | jq -r --arg l "$peer" --arg default "$ACTION_HONOUR" '.[$l].current_action // $default')
			action=$(_sanitize_action "$action")
			# Skip honour entries — honour is the implicit default, writing
			# it would just clutter the config.
			if [[ "$action" == "$ACTION_HONOUR" ]]; then
				continue
			fi
			local var
			var=$(_login_to_var "$peer")
			managed_lines+="DISPATCH_OVERRIDE_${var}=\"${action}\""$'\n'
		done <<<"$peers"
	fi
	managed_lines+="${MARKER_END}"$'\n'

	# Compose the new file: preserve content before BEGIN, replace BEGIN..END,
	# preserve content after END.
	local existing_pre existing_post existing_full
	if [[ -f "$OVERRIDE_CONF" ]]; then
		existing_full=$(cat "$OVERRIDE_CONF")
	else
		existing_full=""
	fi

	if printf '%s' "$existing_full" | grep -qF "$MARKER_BEGIN"; then
		# Replace existing managed section
		existing_pre=$(printf '%s' "$existing_full" | awk -v m="$MARKER_BEGIN" '
			$0 == m { exit }
			{ print }
		')
		existing_post=$(printf '%s' "$existing_full" | awk -v m="$MARKER_END" '
			BEGIN { found=0 }
			$0 == m { found=1; next }
			found == 1 { print }
		')
	else
		# No managed section yet — append
		existing_pre="$existing_full"
		existing_post=""
	fi
	# Ensure separator newline if existing_pre is non-empty and lacks trailing
	# newline — applies whether we are appending or replacing. Command
	# substitution always strips the trailing newline, so without this guard
	# the BEGIN marker would be glued onto the last preserved line on every
	# iteration after the first (idempotency failure).
	if [[ -n "$existing_pre" ]] && [[ "${existing_pre: -1}" != $'\n' ]]; then
		existing_pre+=$'\n'
	fi

	# Compose final
	local new_content
	new_content="${existing_pre}${managed_lines}${existing_post}"

	# Write atomically
	mkdir -p "$(dirname "$OVERRIDE_CONF")"
	local tmp
	tmp=$(mktemp)
	printf '%s' "$new_content" >"$tmp"
	mv "$tmp" "$OVERRIDE_CONF"
	chmod 600 "$OVERRIDE_CONF" 2>/dev/null || true
	log_msg INFO "rewrote managed section: peers_in_state=$(printf '%s' "$state_json" | jq 'keys | length')"
	return 0
}

# ============================================================================
# Public commands
# ============================================================================

cmd_observe() {
	if [[ "${AIDEVOPS_PEER_MONITOR_DISABLE:-0}" == "1" ]]; then
		log_msg INFO "AIDEVOPS_PEER_MONITOR_DISABLE=1 — skipping cycle"
		return 0
	fi

	log_msg INFO "=== observe cycle start ==="

	local observations
	observations=$(discover_and_observe)
	local count
	count=$(printf '%s' "$observations" | jq 'length' 2>/dev/null || echo 0)

	if [[ "$count" -eq 0 ]]; then
		log_msg INFO "no peers found across pulse-enabled repos"
		return 0
	fi

	log_msg INFO "found $count peer(s) to evaluate"

	# Load existing state
	local state_json
	state_json=$(_load_state)

	# Apply hysteresis per peer, accumulating updated state
	local updated_state="$state_json"
	while IFS= read -r obs; do
		[[ -z "$obs" ]] && continue
		local login active_claims worker_prs interactive_prs repositories
		login=$(printf '%s' "$obs" | jq -r '.login')
		active_claims=$(printf '%s' "$obs" | jq -r '.active_claims')
		worker_prs=$(printf '%s' "$obs" | jq -r '.worker_prs')
		interactive_prs=$(printf '%s' "$obs" | jq -r '.interactive_prs')
		repositories=$(printf '%s' "$obs" | jq -c '.repositories // {}')

		local vote
		vote=$(_vote_for_peer "$active_claims" "$worker_prs")
		log_msg INFO "peer=$login active_claims=$active_claims worker_prs=$worker_prs interactive_prs=$interactive_prs vote=$vote"

		local peer_state
		peer_state=$(_apply_hysteresis "$updated_state" "$login" "$vote")
		peer_state=$(_attach_repository_observations "$peer_state" "$login" "$repositories")
		# Merge peer_state into updated_state
		updated_state=$(printf '%s\n%s' "$updated_state" "$peer_state" |
			jq -s '.[0] * .[1]')
	done < <(printf '%s' "$observations" | jq -c '.[]')

	# Save updated state
	if [[ "$DRY_RUN" == "1" ]]; then
		log_msg INFO "DRY_RUN — not writing state or override config"
		printf '%s\n' "$updated_state" | jq .
		return 0
	fi

	printf '%s\n' "$updated_state" | jq . >"$STATE_FILE"
	chmod 600 "$STATE_FILE" 2>/dev/null || true

	# Rewrite override config
	_rewrite_override_config "$updated_state"

	log_msg INFO "=== observe cycle complete ==="
	return 0
}

cmd_report() {
	if [[ ! -f "$STATE_FILE" ]]; then
		printf 'No state yet. Run: peer-productivity-monitor.sh observe\n'
		return 0
	fi
	printf '%bPeer productivity state%b (%s)\n' "$BLUE" "$NC" "$STATE_FILE"
	printf '%-25s %-10s %-3s votes\n' "PEER" "ACTION" "N"
	jq -r 'to_entries[] | [.key, .value.current_action, (.value.vote_history | length), (.value.vote_history | join(","))] | @tsv' "$STATE_FILE" |
		while IFS=$'\t' read -r peer action n votes; do
			local color="$NC"
			[[ "$action" == "$ACTION_IGNORE" ]] && color="$YELLOW"
			[[ "$action" == "$ACTION_HONOUR" ]] && color="$GREEN"
			printf '%-25s %b%-10s%b %-3s %s\n' "$peer" "$color" "$action" "$NC" "$n" "$votes"
		done
	return 0
}

cmd_dry_run() {
	AIDEVOPS_PEER_MONITOR_DRY_RUN=1 DRY_RUN=1 cmd_observe
	return 0
}

cmd_reset() {
	local peer="${1:-}"
	if [[ -z "$peer" ]]; then
		printf 'Usage: peer-productivity-monitor.sh reset <peer-login>\n' >&2
		return 1
	fi
	if [[ ! -f "$STATE_FILE" ]]; then
		printf 'No state file at %s\n' "$STATE_FILE"
		return 0
	fi
	local tmp
	tmp=$(mktemp)
	jq --arg p "$peer" 'del(.[$p])' "$STATE_FILE" >"$tmp" && mv "$tmp" "$STATE_FILE"
	log_msg INFO "reset state for peer=$peer"
	printf 'Reset state for %s\n' "$peer"
	return 0
}

cmd_help() {
	cat <<EOF
peer-productivity-monitor.sh — adaptive cross-runner dispatch coordination (t2932)

Usage:
  peer-productivity-monitor.sh observe       # one observation cycle
  peer-productivity-monitor.sh report        # show current state + decisions
  peer-productivity-monitor.sh dry-run       # observe without writing config
  peer-productivity-monitor.sh reset <peer>  # reset state for a peer
  peer-productivity-monitor.sh help

Env:
  AIDEVOPS_PEER_MONITOR_DISABLE=1     # short-circuit, do nothing
  AIDEVOPS_PEER_MONITOR_DRY_RUN=1     # observe + log, don't write config
  AIDEVOPS_PEER_MONITOR_WINDOW_H=24   # rolling window in hours (default 24)
  AIDEVOPS_PEER_MONITOR_HYSTERESIS=3  # vote count for flip (default 3)

Config file:
  $OVERRIDE_CONF
  Manual entries above the BEGIN marker take precedence.

Logs:
  $LOG_FILE
EOF
	return 0
}

# ============================================================================
# Main
# ============================================================================

main() {
	local cmd="${1:-help}"
	shift || true
	case "$cmd" in
		observe) cmd_observe "$@" ;;
		report) cmd_report "$@" ;;
		dry-run | dry_run) cmd_dry_run "$@" ;;
		reset) cmd_reset "$@" ;;
		help | --help | -h) cmd_help ;;
		*)
			printf 'Error: unknown command: %s\n' "$cmd" >&2
			cmd_help
			return 1
			;;
	esac
	return 0
}

main "$@"

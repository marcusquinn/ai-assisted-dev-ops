#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# bot-noise-monitor-helper.sh — Monitor bot comment noise on GitHub issues/PRs
#
# Scans recent issue/PR comments for bot accounts and reports token waste:
# - Known bots with skip rules (CodeRabbit, SonarCloud, Codacy, etc.)
# - Unknown bots that may need new skip rules
# - Hidden content ratio (HTML comments, base64 state blocks)
#
# Usage:
#   bot-noise-monitor-helper.sh scan [--repo OWNER/REPO] [--days N]
#   bot-noise-monitor-helper.sh report [--repo OWNER/REPO]
#   bot-noise-monitor-helper.sh help

set -euo pipefail

# Load known bots from central config (single source of truth).
# Falls back to inline list if config file not found.
_KNOWN_BOTS_FILE="${AIDEVOPS_AGENTS_DIR:-${HOME}/.aidevops/agents}/configs/known-bots.txt"
KNOWN_BOTS=()
if [[ -f "$_KNOWN_BOTS_FILE" ]]; then
	while IFS= read -r line; do
		[[ -z "$line" || "$line" == \#* ]] && continue
		KNOWN_BOTS+=("$line")
	done <"$_KNOWN_BOTS_FILE"
else
	# Fallback if deployed config not available
	# gemini-code-assist is retained only to classify historical bot activity.
	KNOWN_BOTS=(
		"coderabbitai[bot]" "sonarqubecloud[bot]" "codacy-production[bot]"
		"github-actions[bot]" "gemini-code-assist[bot]" "augmentcode[bot]" "codefactor-io[bot]"
		"socket-security[bot]" "qltybot[bot]" "dependabot[bot]" "renovate[bot]"
		"mergify[bot]" "allcontributors[bot]" "codecov[bot]" "stale[bot]"
	)
fi

_is_known_bot() {
	local login="$1"
	local bot
	for bot in "${KNOWN_BOTS[@]}"; do
		if [[ "$login" == "$bot" ]]; then
			return 0
		fi
	done
	return 1
}

_is_bot_account() {
	local login="$1"
	# Accounts ending in [bot] or containing "bot" in the name
	if [[ "$login" == *"[bot]"* ]] || [[ "$login" == *"-bot"* ]]; then
		return 0
	fi
	return 1
}

_estimate_hidden_chars() {
	local body="$1"
	# Count chars inside HTML comments (<!-- ... -->)
	local hidden
	hidden=$(echo "$body" | python3 -c "
import sys, re
body = sys.stdin.read()
comments = re.findall(r'<!--.*?-->', body, re.DOTALL)
print(sum(len(c) for c in comments))
" 2>/dev/null || echo "0")
	echo "$hidden"
	return 0
}

cmd_scan() {
	local repo="${1:-}"
	local days="${2:-7}"

	if [[ -z "$repo" ]]; then
		# Auto-detect from current directory
		repo=$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null || echo "")
		if [[ -z "$repo" ]]; then
			echo "Error: no repo specified and not in a git repo" >&2
			return 1
		fi
	fi

	echo "=== Bot Noise Monitor: ${repo} (last ${days} days) ==="
	echo ""

	local since
	since=$(date -u -v-"${days}"d '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null ||
		date -u -d "${days} days ago" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null ||
		echo "2026-01-01T00:00:00Z")

	# Fetch recent issue comments
	local comments_json
	comments_json=$(gh api "repos/${repo}/issues/comments?since=${since}&per_page=100" \
		--jq '[.[] | {
			id,
			login: .user.login,
			body_len: (.body | length),
			issue_url: .issue_url
		}]' 2>/dev/null || echo "[]")

	# Group by bot login
	local bot_stats
	bot_stats=$(echo "$comments_json" | python3 -c "
import json, sys

comments = json.load(sys.stdin)
stats = {}
for c in comments:
    login = c['login']
    if not (login.endswith('[bot]') or '-bot' in login):
        continue
    if login not in stats:
        stats[login] = {'count': 0, 'total_chars': 0}
    stats[login]['count'] += 1
    stats[login]['total_chars'] += c['body_len']

for login in sorted(stats, key=lambda k: stats[k]['total_chars'], reverse=True):
    s = stats[login]
    avg = s['total_chars'] // s['count'] if s['count'] > 0 else 0
    print(f'{login}|{s[\"count\"]}|{s[\"total_chars\"]}|{avg}')
" 2>/dev/null)

	if [[ -z "$bot_stats" ]]; then
		echo "No bot comments found in the last ${days} days."
		return 0
	fi

	local unknown_found=0

	printf "%-35s %8s %12s %8s %s\n" "Bot Account" "Comments" "Total Chars" "Avg/Msg" "Status"
	printf "%-35s %8s %12s %8s %s\n" "---" "---" "---" "---" "---"

	while IFS='|' read -r login count total_chars avg; do
		local status
		if _is_known_bot "$login"; then
			status="KNOWN (skip rules active)"
		else
			status="UNKNOWN — may need skip rules"
			unknown_found=$((unknown_found + 1))
		fi
		printf "%-35s %8s %12s %8s %s\n" "$login" "$count" "$total_chars" "$avg" "$status"
	done <<<"$bot_stats"

	echo ""

	if [[ "$unknown_found" -gt 0 ]]; then
		echo "WARNING: ${unknown_found} unknown bot(s) detected. Review their comment content"
		echo "and consider adding skip rules to reference/gh-command-discipline.md rule #8c if they produce non-actionable noise."
		echo ""
		echo "To inspect an unknown bot's comments:"
		echo "  gh api 'repos/${repo}/issues/comments?since=${since}&per_page=5' --jq '[.[] | select(.user.login == \"BOT_NAME\")] | .[0].body[:500]'"
	else
		echo "All detected bots have skip rules in reference/gh-command-discipline.md #8c."
	fi

	# Estimate total token waste
	local total_bot_chars=0
	while IFS='|' read -r _ _ total_chars _; do
		total_bot_chars=$((total_bot_chars + total_chars))
	done <<<"$bot_stats"

	local estimated_tokens=$((total_bot_chars / 4)) # rough char-to-token ratio
	echo ""
	echo "Estimated bot noise: ${total_bot_chars} chars (~${estimated_tokens} tokens) in ${days} days"
	echo "At ~50% actionable content, ~${estimated_tokens}/2 = $((estimated_tokens / 2)) tokens wasted per scan period"

	return 0
}

cmd_report() {
	local repo="${1:-}"

	if [[ -z "$repo" ]]; then
		repo=$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null || echo "")
		if [[ -z "$repo" ]]; then
			echo "Error: no repo specified and not in a git repo" >&2
			return 1
		fi
	fi

	echo "=== Bot Noise Report: ${repo} ==="
	echo ""

	# Sample recent PRs and measure hidden content ratio
	local pr_nums
	pr_nums=$(gh api "repos/${repo}/pulls?state=all&per_page=5" --jq '.[].number' 2>/dev/null)

	printf "%-8s %-30s %10s %10s %6s\n" "PR" "Bot" "Total" "Hidden" "Ratio"
	printf "%-8s %-30s %10s %10s %6s\n" "---" "---" "---" "---" "---"

	for pr_num in $pr_nums; do
		gh api "repos/${repo}/issues/${pr_num}/comments" --jq '
			[.[] | select(.user.login | test("\\[bot\\]$"; "i"))] |
			.[] | "\(.user.login)|\(.body)"' 2>/dev/null | while IFS='|' read -r login body; do
			local total_len=${#body}
			local hidden_len
			hidden_len=$(_estimate_hidden_chars "$body")
			local ratio=0
			if [[ "$total_len" -gt 0 ]]; then
				ratio=$((hidden_len * 100 / total_len))
			fi
			printf "%-8s %-30s %10s %10s %5s%%\n" "#${pr_num}" "$login" "$total_len" "$hidden_len" "$ratio"
		done
	done

	return 0
}

cmd_help() {
	cat <<'HELPEOF'
bot-noise-monitor-helper.sh — Monitor bot comment noise on GitHub issues/PRs

Usage:
  bot-noise-monitor-helper.sh scan [--repo OWNER/REPO] [--days N]
    Scan recent comments, identify bot accounts, flag unknown bots.

  bot-noise-monitor-helper.sh report [--repo OWNER/REPO]
    Detailed report with hidden content ratios per bot per PR.

  bot-noise-monitor-helper.sh help
    Show this help message.

Known bots (skip rules in reference/gh-command-discipline.md #8c):
  coderabbitai[bot], sonarqubecloud[bot], codacy-production[bot],
  github-actions[bot], gemini-code-assist[bot], augmentcode[bot],
  codefactor-io[bot], socket-security[bot], qltybot[bot]

Unknown bots are flagged so you can inspect their comments and decide
whether to add skip rules.
HELPEOF
	return 0
}

# Main dispatch
main() {
	local command="${1:-help}"
	shift || true

	local repo="" days="7"
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--repo)
			repo="$2"
			shift 2
			;;
		--days)
			days="$2"
			shift 2
			;;
		*)
			shift
			;;
		esac
	done

	case "$command" in
	scan) cmd_scan "$repo" "$days" ;;
	report) cmd_report "$repo" ;;
	help | --help | -h) cmd_help ;;
	*)
		echo "Unknown command: $command" >&2
		cmd_help >&2
		return 1
		;;
	esac
}

main "$@"

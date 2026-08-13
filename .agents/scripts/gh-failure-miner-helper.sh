#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# gh-failure-miner-helper.sh - Mine GitHub ci_activity notifications for systemic failures

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)" || exit 1
# shellcheck source=shared-constants.sh
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/shared-constants.sh" 2>/dev/null || true

readonly DEFAULT_SINCE_HOURS=24
readonly DEFAULT_LIMIT=100
readonly DEFAULT_MAX_RUN_LOGS=8
readonly DEFAULT_SYSTEMIC_THRESHOLD=3
readonly DEFAULT_MAX_ISSUES=5
readonly DEFAULT_REPOS_JSON="${HOME}/.config/aidevops/repos.json"
readonly DEFAULT_ROUTINE_NAME="gh-failure-miner"
readonly DEFAULT_ROUTINE_SCHEDULE="15 * * * *"
readonly DEFAULT_ROUTINE_TITLE="GH failed notifications: systemic triage"
readonly JQ_COUNT='length'
readonly INFRA_REASON_ALL_CHECKS_FAILED='all_checks_failed'

print_usage() {
	cat <<'EOF'
gh-failure-miner-helper.sh - Mine GitHub failed CI notifications for root causes

Usage:
  gh-failure-miner-helper.sh collect [options]
  gh-failure-miner-helper.sh report [options]
  gh-failure-miner-helper.sh issue-body [options]
  gh-failure-miner-helper.sh create-issues [options]
  gh-failure-miner-helper.sh prefetch [options]
  gh-failure-miner-helper.sh install-launchd-routine [options]

Commands:
  collect     Emit JSON array of failed CI events from notification threads
  report      Print markdown summary with systemic-pattern candidates
  issue-body  Print markdown issue body for top systemic candidate
  create-issues  Create/update systemic root-cause issues for candidate clusters
  prefetch    Print compact pulse-ready summary section
  install-launchd-routine  One-shot launchd installer for systemic failure miner routine

Options:
  --since-hours N     Look back N hours (default: 24)
  --limit N           Notification API page size (default: 100, max: 100)
  --repos CSV         Optional repo allowlist (owner/repo,comma-separated)
  --pulse-repos       Auto-load repo allowlist from repos.json pulse=true entries
  --repos-json PATH   Custom repos.json path (default: ~/.config/aidevops/repos.json)
  --pr-only           Exclude push notifications; analyze PR notifications only
  --no-log-signatures Skip `gh run view --log-failed` signature extraction
  --max-run-logs N    Max workflow runs to inspect for signatures (default: 8)
  --systemic-threshold N  Minimum events per cluster to treat as systemic (default: 3)
  --max-issues N      Max issues to create in one run (default: 5)
  --label NAME        Extra label for created issues (repeatable)
  --dry-run           Show candidate issues without creating them
  --help, -h          Show help

Examples:
  gh-failure-miner-helper.sh collect --since-hours 12 --pulse-repos
  gh-failure-miner-helper.sh report --since-hours 24
  gh-failure-miner-helper.sh issue-body --since-hours 48 --max-run-logs 12
  gh-failure-miner-helper.sh create-issues --since-hours 24 --pulse-repos --label auto-dispatch
  gh-failure-miner-helper.sh install-launchd-routine --dry-run
EOF
	return 0
}

die() {
	local message="$1"
	printf '[ERROR] %s\n' "$message" >&2
	return 1
}

require_option_value() {
	local option_name="$1"
	local arg_count="$2"
	if [[ "$arg_count" -lt 2 ]]; then
		die "${option_name} requires a value"
		return 1
	fi
	return 0
}

require_positive_integer() {
	local option_name="$1"
	local value="$2"
	if [[ ! "$value" =~ ^[0-9]+$ ]]; then
		die "${option_name} must be a positive integer"
		return 1
	fi
	return 0
}

require_tools() {
	if ! command -v gh >/dev/null 2>&1; then
		die "gh CLI is required"
		return 1
	fi
	if ! command -v jq >/dev/null 2>&1; then
		die "jq is required"
		return 1
	fi
	if ! gh auth status >/dev/null 2>&1; then
		die "gh CLI is not authenticated"
		return 1
	fi
	return 0
}

iso_hours_ago() {
	local since_hours="$1"
	if [[ "$(uname -s)" == "Darwin" ]]; then
		date -u -v-"${since_hours}"H +%Y-%m-%dT%H:%M:%SZ
		return 0
	fi
	date -u -d "${since_hours} hours ago" +%Y-%m-%dT%H:%M:%SZ
	return 0
}

repo_in_allowlist() {
	local repo_slug="$1"
	local allowlist_csv="$2"
	if [[ -z "$allowlist_csv" ]]; then
		return 0
	fi
	local normalized
	normalized=",${allowlist_csv},"
	if [[ "$normalized" == *",${repo_slug},"* ]]; then
		return 0
	fi
	return 1
}

parse_run_id_from_details_url() {
	local details_url="$1"
	local run_id
	run_id=$(printf '%s' "$details_url" | sed -nE 's|.*/actions/runs/([0-9]+).*|\1|p')
	printf '%s' "$run_id"
	return 0
}

parse_commit_sha_from_subject_url() {
	local subject_url="$1"
	local commit_sha
	commit_sha=$(printf '%s' "$subject_url" | sed -nE 's|.*/commits/([0-9a-fA-F]{7,40}).*|\1|p')
	printf '%s' "$commit_sha"
	return 0
}

normalize_signature_line() {
	local raw_line="$1"
	local stripped
	stripped=$(printf '%s' "$raw_line" | sed -E $'s/(\x1b|\\^\\[)\\[[0-9;]*[A-Za-z]//g; s/[[:space:]]+/ /g; s/^ //; s/ $//')
	if [[ -z "$stripped" ]]; then
		printf '%s' "no_error_signature_detected"
		return 0
	fi
	printf '%s' "$stripped" | cut -c1-220
	return 0
}

filter_signature_noise_lines() {
	local logs="$1"
	printf '%s\n' "$logs" | awk '
		{
			raw = $0
			payload = $0
			n = split(raw, fields, "\t")
			if (n >= 4) {
				payload = fields[4]
				for (i = 5; i <= n; i++) {
					payload = payload "\t" fields[i]
				}
			}
			source_probe = payload
			gsub(/^[[:space:]]+/, "", source_probe)
			# GitHub Actions renders the generated shell source in cyan before
			# printing command output. Never classify that source as evidence:
			# guards often contain error text for branches that did not execute.
			# Some gh versions return only three tab-separated fields, leaving the
			# timestamp before the colour marker (GH#29522).
			if (source_probe ~ /^(\033\[36;1m|\^\[\[36;1m)/ ||
				source_probe ~ /Z[[:space:]]+(\033\[36;1m|\^\[\[36;1m)/) {
				next
			}
			gsub(/\033\[[0-9;]*[A-Za-z]/, "", payload)
			gsub(/\^\[\[[0-9;]*[A-Za-z]/, "", payload)
			# gh may return raw log rows with the ISO timestamp still prefixed
			# instead of tab-separated job/step/time columns; remove it before
			# classifying shell comments as signature noise.
			sub(/^20[0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9:.]+Z[[:space:]]+/, "", payload)
			gsub(/^[[:space:]]+/, "", payload)
			# GitHub Actions sometimes echoes shell comments from multi-line run blocks
			# as UNKNOWN STEP log rows. Treat plain comments and xtrace-prefixed
			# comments as noise so they cannot become systemic failure signatures.
			# Require whitespace or end-of-line after the comment marker so the GitHub
			# structured `##[error]` annotation remains available as evidence.
			if (payload ~ /^([+][[:space:]]*)*#([[:space:]]+|$)/) {
				next
			}
			print raw
		}
	'
	return 0
}

select_failed_job_json() {
	local repo_slug="$1"
	local run_id="$2"
	local check_run_id="$3"
	local jobs_json
	local selected_job=""

	jobs_json=$(gh api "repos/${repo_slug}/actions/runs/${run_id}/jobs" 2>/dev/null || printf '{}')
	if [[ -z "$jobs_json" ]] || [[ "$jobs_json" == "{}" ]]; then
		printf '%s' ""
		return 0
	fi

	if [[ -n "$check_run_id" ]]; then
		selected_job=$(printf '%s\n' "$jobs_json" | jq -c --arg check_run_id "$check_run_id" '[.jobs[]? | select(((.check_run_url // "") | split("/") | last) == $check_run_id)] | first // empty')
	fi

	if [[ -z "$selected_job" ]]; then
		selected_job=$(printf '%s\n' "$jobs_json" | jq -c '[.jobs[]? | select((.conclusion // "") == "failure")] | first // empty')
	fi

	printf '%s' "$selected_job"
	return 0
}

job_annotations_indicate_billing_outage() {
	local repo_slug="$1"
	local check_run_id="$2"
	local annotations_json

	if [[ -z "$check_run_id" ]]; then
		return 1
	fi

	annotations_json=$(gh api "repos/${repo_slug}/check-runs/${check_run_id}/annotations" 2>/dev/null || printf '[]')
	if printf '%s\n' "$annotations_json" | jq -e 'any(.[]; ([.message // "", .title // "", .raw_details // ""] | join(" ") | ascii_downcase | test("account payments have failed|spending limit needs to be increased")))' >/dev/null; then
		return 0
	fi

	return 1
}

classify_failed_job_signature() {
	local repo_slug="$1"
	local failed_job_json="$2"
	local step_count
	local check_run_id

	if [[ -z "$failed_job_json" ]] || [[ "$failed_job_json" == "null" ]]; then
		printf '%s' ""
		return 0
	fi

	step_count=$(printf '%s\n' "$failed_job_json" | jq '(.steps // []) | length')
	if [[ "$step_count" -ne 0 ]]; then
		printf '%s' ""
		return 0
	fi

	check_run_id=$(printf '%s\n' "$failed_job_json" | jq -r '(.check_run_url // "") | split("/") | last // empty')
	if job_annotations_indicate_billing_outage "$repo_slug" "$check_run_id"; then
		printf '%s' "infra:billing_annotation"
		return 0
	fi

	printf '%s' "job_not_started"
	return 0
}

extract_failure_signature() {
	local repo_slug="$1"
	local run_id="$2"
	local check_run_id="$3"
	local failed_job_json
	local zero_step_signature
	local logs
	local filtered_logs
	local failed_job_id

	failed_job_json=$(select_failed_job_json "$repo_slug" "$run_id" "$check_run_id")
	zero_step_signature=$(classify_failed_job_signature "$repo_slug" "$failed_job_json")
	if [[ -n "$zero_step_signature" ]]; then
		printf '%s' "$zero_step_signature"
		return 0
	fi

	logs=$(gh run view "$run_id" --repo "$repo_slug" --log-failed 2>/dev/null || true)
	if [[ -z "$logs" ]]; then
		# Fallback: --log-failed returned empty (logs expired, rate-limited, or run still
		# in progress). Try the jobs API to get the first failed job's logs directly.
		# This avoids the "no_failed_log_output" signature which produces unhelpful clusters.
		failed_job_id=$(printf '%s\n' "$failed_job_json" | jq -r '.id // empty')
		if [[ -n "$failed_job_id" ]]; then
			logs=$(gh api "repos/${repo_slug}/actions/jobs/${failed_job_id}/logs" 2>/dev/null || true)
		fi
	fi
	if [[ -z "$logs" ]]; then
		printf '%s' "no_failed_log_output"
		return 0
	fi
	filtered_logs=$(filter_signature_noise_lines "$logs")

	# Check for known infrastructure error patterns before extracting a generic signature.
	# Log text is weaker evidence than a structured annotation or all-checks-failed
	# correlation, so preserve its provenance for the advisory corroboration gate.
	local infra_line
	infra_line=$(printf '%s\n' "$filtered_logs" | grep -iE "recent account payments have failed|spending limit needs to be increased" | head -1 || true)
	if [[ -n "$infra_line" ]]; then
		printf '%s' "infra:billing_log"
		return 0
	fi
	infra_line=$(printf '%s\n' "$filtered_logs" | grep -iE "Runner.*unavailable|no matching runner|runner.*not found" | head -1 || true)
	if [[ -n "$infra_line" ]]; then
		printf '%s' "infra:runner_log"
		return 0
	fi

	local candidate
	# Prefer an emitted workflow annotation over generic error words in the log.
	# A malformed/unstructured gh row can retain runner-echoed shell source such as
	# `echo "::error::..."`; requiring the annotation marker to start a payload
	# keeps that source from masking the actual terminal error (GH#29468).
	candidate=$(printf '%s\n' "$filtered_logs" | awk '
		{
			payload = $0
			n = split($0, fields, "\t")
			if (n >= 4) {
				payload = fields[4]
			}
			sub(/^20[0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9:.]+Z[[:space:]]+/, "", payload)
			gsub(/^[[:space:]]+/, "", payload)
			if (payload ~ /^(::error::|##\[error\])/) {
				print
				exit
			}
		}
	')
	if [[ -z "$candidate" ]]; then
		candidate=$(printf '%s\n' "$filtered_logs" | awk 'BEGIN{IGNORECASE=1} /error|exception|traceback|failed|denied|timeout|cannot|invalid|forbidden|unauthorized/ {print; exit}')
	fi
	if [[ -z "$candidate" ]]; then
		candidate=$(printf '%s\n' "$filtered_logs" | awk 'NF {print; exit}')
	fi

	normalize_signature_line "$candidate"
	return 0
}

fetch_notifications_json() {
	local since_iso="$1"
	local limit="$2"
	# NOSONAR - $limit is validated as [0-9]+ before call; $since_iso is output of date(1) in ISO format
	gh api "notifications?all=true&participating=false&per_page=${limit}&since=${since_iso}"
	return 0
}

load_pulse_repo_allowlist() {
	local repos_json_path="$1"
	if [[ ! -f "$repos_json_path" ]]; then
		printf '%s' ""
		return 0
	fi
	jq -r '.initialized_repos[] | select(.maintenance != false and .pulse == true and (.local_only // false) == false and (.slug // "") != "") | .slug' "$repos_json_path" 2>/dev/null | paste -sd ',' -
	return 0
}

resolve_repo_allowlist() {
	local explicit_allowlist="$1"
	local use_pulse_repos="$2"
	local repos_json_path="$3"

	if [[ -n "$explicit_allowlist" ]]; then
		printf '%s' "$explicit_allowlist"
		return 0
	fi

	if [[ "$use_pulse_repos" == "true" ]]; then
		load_pulse_repo_allowlist "$repos_json_path"
		return 0
	fi

	printf '%s' ""
	return 0
}

resolve_source_from_subject() {
	local subject_url="$1"
	local repo_slug="$2"
	local include_push_events="$3"

	local pr_number
	pr_number=$(printf '%s' "$subject_url" | sed -nE 's|.*/pulls/([0-9]+)$|\1|p')

	if [[ -n "$pr_number" ]]; then
		local pr_json
		pr_json=$(gh api "repos/${repo_slug}/pulls/${pr_number}" 2>/dev/null || printf '{}')
		local head_sha pr_state
		head_sha=$(printf '%s\n' "$pr_json" | jq -r '.head.sha // empty')
		pr_state=$(printf '%s\n' "$pr_json" | jq -r '.state // empty')
		# A notification can remain unread after its PR was superseded, closed, or
		# merged. Mining that stale check cannot identify a currently actionable
		# systemic failure and can combine several abandoned iterations into a
		# false cluster (GH#30197).
		if [[ "$pr_state" != "open" ]] || [[ -z "$head_sha" ]]; then
			return 1
		fi
		printf '%s\n' "pr|#${pr_number}|https://github.com/${repo_slug}/pull/${pr_number}|${pr_number}||${head_sha}"
		return 0
	fi

	local commit_sha
	commit_sha=$(parse_commit_sha_from_subject_url "$subject_url")
	if [[ "$include_push_events" != "true" ]] || [[ -z "$commit_sha" ]]; then
		return 1
	fi
	printf '%s\n' "push|${commit_sha:0:12}|https://github.com/${repo_slug}/commit/${commit_sha}||${commit_sha}|${commit_sha}"
	return 0
}

resolve_check_signature() {
	local run_json="$1"
	local run_id="$2"
	local repo_slug="$3"
	local include_logs="$4"
	local run_logs_checked="$5"
	local max_run_logs="$6"

	# For non-GitHub-Actions check runs (e.g., Codacy, SonarCloud), the details_url
	# points to the external app, not a GH Actions run — so run_id is empty and logs
	# can't be extracted. Use the conclusion as the signature instead of "signature_not_fetched"
	# to produce meaningful cluster grouping (GH#4696).
	if [[ -z "$run_id" ]]; then
		local app_name conclusion
		app_name=$(printf '%s\n' "$run_json" | jq -r '.app.name // "external"')
		conclusion=$(printf '%s\n' "$run_json" | jq -r '.conclusion // "unknown"')
		printf '%s' "${conclusion}:${app_name}"
		return 0
	fi

	if [[ "$include_logs" == "true" ]] && [[ "$run_logs_checked" -lt "$max_run_logs" ]]; then
		local check_run_id
		check_run_id=$(printf '%s\n' "$run_json" | jq -r '.id // empty')
		extract_failure_signature "$repo_slug" "$run_id" "$check_run_id"
		return 0
	fi

	# "signature_not_fetched" is an internal sentinel meaning log fetch was skipped
	# (budget exhausted). Distinct from GitHub conclusion values to avoid confusion.
	printf '%s' "signature_not_fetched"
	return 0
}

is_all_checks_failed() {
	local checks_json="$1"
	local failed_count="$2"
	local total_count
	total_count=$(printf '%s\n' "$checks_json" | jq '[.check_runs[] | select((.conclusion // "") != "")] | length')
	# All-checks-failed: every completed check run failed (no mixed pass/fail).
	# Requires at least 2 checks to avoid false positives on single-check repos.
	if [[ "$total_count" -ge 2 ]] && [[ "$failed_count" -eq "$total_count" ]]; then
		return 0
	fi
	return 1
}

fetch_pr_changed_paths_json() {
	local repo_slug="$1" pr_number="$2"
	if [[ -z "$repo_slug" ]] || [[ -z "$pr_number" ]]; then
		printf '%s\n' '[]'
		return 0
	fi

	local files
	if ! files=$(gh api --paginate "repos/${repo_slug}/pulls/${pr_number}/files?per_page=100" --jq '.[].filename' 2>/dev/null); then
		printf '%s\n' '[]'
		return 0
	fi
	printf '%s\n' "$files" | jq -c -R -s '[splits("\n") | select(length > 0)] | unique' || printf '%s\n' '[]'
	return 0
}

fetch_check_run_annotations_summary_json() {
	local repo_slug="$1" check_run_id="$2"
	if [[ -z "$repo_slug" ]] || [[ -z "$check_run_id" ]]; then
		printf '%s\n' '[]'
		return 0
	fi

	local annotations
	if ! annotations=$(gh api --paginate "repos/${repo_slug}/check-runs/${check_run_id}/annotations?per_page=100" \
		--jq '.[] | {path: (.path // ""), start_line: (.start_line // null), annotation_level: (.annotation_level // ""), title: (.title // ""), message: ((.message // .raw_details // "") | gsub("[\r\n\t]+"; " ") | .[0:220])}' 2>/dev/null); then
		printf '%s\n' '[]'
		return 0
	fi

	printf '%s\n' "$annotations" | jq -s -c '[.[] | select(((.path // "") | length) > 0 or ((.message // "") | length) > 0)][0:5]' 2>/dev/null || printf '%s\n' '[]'
	return 0
}

codefactor_signature_from_annotations() {
	local annotations_json="$1"
	local finding_signature
	finding_signature=$(printf '%s\n' "$annotations_json" | jq -r '
		[
			.[]
			| {
				severity: ({failure: 3, warning: 2, notice: 1}[.annotation_level] // 0),
				finding: ((.message // .title // empty)
				| gsub("[\\r\\n\\t]+"; " ")
				| gsub("[[:space:]]+"; " ")
				| sub("^[[:space:]]+"; "")
				| sub("[[:space:]]+$"; ""))
			}
			| select(.finding | length > 0)
		]
		| sort_by([-.severity, .finding])
		| .[0].finding // empty
	' 2>/dev/null || printf '')
	if [[ -n "$finding_signature" ]]; then
		printf 'failure:codefactor.io:%s' "$finding_signature"
	else
		printf 'failure:codefactor.io'
	fi
	return 0
}

emit_event_json() {
	local repo_slug="$1" source_kind="$2" source_ref="$3" source_url="$4"
	local pr_number="$5" commit_sha="$6" check_name="$7" conclusion="$8"
	local run_id="$9" html_url="${10}" details_url="${11}" completed_at="${12}"
	local signature="${13}" notification_updated_at="${14}" is_infra="${15}"
	local infra_reason="${16:-}"
	local affected_paths_json="${17:-[]}"
	local annotations_json="${18:-[]}"

	local pr_url=""
	if [[ -n "$pr_number" ]]; then
		pr_url="https://github.com/${repo_slug}/pull/${pr_number}"
	fi

	jq -n \
		--arg repo "$repo_slug" \
		--arg source_kind "$source_kind" \
		--arg source_ref "$source_ref" \
		--arg source_url "$source_url" \
		--arg pr_number "$pr_number" \
		--arg pr_url "$pr_url" \
		--arg commit_sha "$commit_sha" \
		--arg check_name "$check_name" \
		--arg conclusion "$conclusion" \
		--arg run_id "$run_id" \
		--arg run_url "$html_url" \
		--arg details_url "$details_url" \
		--arg completed_at "$completed_at" \
		--arg signature "$signature" \
		--arg notification_updated_at "$notification_updated_at" \
		--argjson is_infra "$is_infra" \
		--arg infra_reason "$infra_reason" \
		--argjson affected_paths "$affected_paths_json" \
		--argjson annotations "$annotations_json" \
		'{
			repo: $repo,
			source_kind: $source_kind,
			source_ref: $source_ref,
			source_url: (if $source_url == "" then null else $source_url end),
			pr_number: (if $pr_number == "" then null else ($pr_number | tonumber) end),
			pr_url: (if $pr_url == "" then null else $pr_url end),
			commit_sha: (if $commit_sha == "" then null else $commit_sha end),
			check_name: $check_name,
			conclusion: $conclusion,
			run_id: (if $run_id == "" then null else ($run_id | tonumber) end),
			run_url: (if $run_url == "" then null else $run_url end),
			details_url: (if $details_url == "" then null else $details_url end),
			completed_at: (if $completed_at == "" then null else $completed_at end),
			signature: $signature,
			notification_updated_at: (if $notification_updated_at == "" then null else $notification_updated_at end),
			is_infra: $is_infra,
			infra_reason: (if $infra_reason == "" then null else $infra_reason end),
			affected_paths: $affected_paths,
			annotations: $annotations
		}'
	return 0
}

deduplicate_failed_events_json() {
	local events_json="$1"
	printf '%s\n' "$events_json" | jq '
		unique_by([
			.repo,
			(if ((.details_url // "") | length) > 0 then
				"details", .details_url
			elif .run_id != null then
				"run", (.run_id | tostring), .check_name
			else
				"source", .source_kind, .source_ref, .check_name, .signature,
				(.completed_at // "")
			end)
		] | join("|"))
	'
	return 0
}

# Filter check runs for failures. Two-pass approach:
# 1. Hard failures (failure, cancelled, timed_out, startup_failure) — always collected
# 2. action_required — only from GitHub Actions runs. External apps (Codacy, SonarCloud)
#    use action_required to mean "issues found for developer review", which is informational
#    not a CI failure. Including these creates false systemic clusters (GH#4696).
#
# Policy gate checks are excluded (GH#17831): checks that enforce workflow policy
# (e.g. maintainer review, assignee requirements) fail by design when policy is not met.
# Treating these as systemic CI failures creates false noise — they are not tooling defects.
# The exclusion list uses substring matching so minor name variations are still caught.
filter_failed_check_runs() {
	local checks_json="$1"
	# Select failed/cancelled check runs, then deduplicate cancelled-only groups by name.
	# When cancel-in-progress: true fires on multiple rapid events (label changes, synchronize),
	# GitHub records N identical cancelled check runs for the same commit — one per workflow
	# trigger. Without deduplication they exhaust the log-fetch budget (max_run_logs) and cause
	# subsequent genuine failures to emit "signature_not_fetched" clusters. (GH#18978)
	printf '%s\n' "$checks_json" | jq '
		[.check_runs[] | select(
			(
				((.conclusion // "" | ascii_downcase) as $c |
					["failure","cancelled","timed_out","startup_failure"] | index($c))
				or
				((.conclusion // "" | ascii_downcase) == "action_required"
					and (.app.slug // "" | ascii_downcase) == "github-actions")
			)
			and
			# Exclude policy gate checks — these fail by design when policy is not met,
			# not because of a tooling defect. (GH#17831)
			((.name // "") | ascii_downcase | test("maintainer.*review|maintainer.*gate|assignee.*gate") | not)
		)]
		# Deduplicate: for each check name where EVERY entry is cancelled (i.e. the job
		# never ran in any attempt), keep only the latest-completed entry. This collapses
		# N rapid-cancellation duplicates into one, preventing budget exhaustion.
		| group_by(.name)
		| map(
			if all(.conclusion == "cancelled") and length > 1 then
				[sort_by(.completed_at // "") | last]
			else
				.
			end
		)
		| add // []
	'
	return 0
}

process_failed_runs() {
	local failed_runs_json="$1"
	local repo_slug="$2" source_kind="$3" source_ref="$4" source_url="$5"
	local pr_number="$6" commit_sha="$7" notification_updated_at="$8"
	local include_logs="$9" run_logs_checked="${10}" max_run_logs="${11}"
	local event_file="${12}" checks_json="${13}"

	local failed_count
	failed_count=$(printf '%s\n' "$failed_runs_json" | jq "$JQ_COUNT")

	# Detect all-checks-failed correlation: if every completed check failed simultaneously,
	# flag as likely infrastructure outage rather than a code defect. (GH#18093)
	local is_infra="false"
	local infra_reason=""
	if is_all_checks_failed "$checks_json" "$failed_count"; then
		is_infra="true"
		infra_reason="$INFRA_REASON_ALL_CHECKS_FAILED"
	fi

	local failed_index=0
	local affected_paths_json="[]"
	while [[ "$failed_index" -lt "$failed_count" ]]; do
		local run_json
		run_json=$(printf '%s\n' "$failed_runs_json" | jq ".[${failed_index}]")

		local check_name conclusion details_url html_url completed_at run_id
		check_name=$(printf '%s\n' "$run_json" | jq -r '.name // "unknown-check"')
		conclusion=$(printf '%s\n' "$run_json" | jq -r '.conclusion // "unknown"')
		details_url=$(printf '%s\n' "$run_json" | jq -r '.details_url // empty')
		html_url=$(printf '%s\n' "$run_json" | jq -r '.html_url // empty')
		completed_at=$(printf '%s\n' "$run_json" | jq -r '.completed_at // empty')
		run_id=$(parse_run_id_from_details_url "$details_url")

		local signature
		signature=$(resolve_check_signature "$run_json" "$run_id" "$repo_slug" "$include_logs" "$run_logs_checked" "$max_run_logs")
		# Only charge the log-fetch budget when a real log fetch was attempted.
		# job_not_started (0-step cancelled jobs) and billing annotation detection (which makes
		# no gh run view call) both short-circuit before fetching any logs — counting them
		# exhausts the budget for genuine failures in other PRs. (GH#18978)
		if [[ "$include_logs" == "true" ]] && [[ -n "$run_id" ]] && [[ "$run_logs_checked" -lt "$max_run_logs" ]] &&
			[[ "$signature" != "job_not_started" ]] && [[ "$signature" != "infra:billing_annotation" ]]; then
			run_logs_checked=$((run_logs_checked + 1))
		fi

		# Keep infrastructure state event-local. A weak match in one failed check must
		# not promote every later check in the same batch.
		local event_is_infra="$is_infra"
		local event_infra_reason="$infra_reason"
		if [[ "$signature" == infra:* ]]; then
			event_is_infra="true"
			event_infra_reason="${signature#infra:}"
		fi

		local run_affected_paths="[]"
		local run_annotations="[]"
		if [[ "$source_kind" == "pr" ]] && [[ -n "$pr_number" ]] &&
			{ [[ "$check_name" =~ [Cc]ode[Ff]actor ]] || [[ "$signature" == "failure:codefactor.io" ]]; }; then
			if [[ "$affected_paths_json" == "[]" ]]; then
				affected_paths_json=$(fetch_pr_changed_paths_json "$repo_slug" "$pr_number")
			fi
			run_affected_paths="$affected_paths_json"
			run_annotations=$(fetch_check_run_annotations_summary_json "$repo_slug" "$(printf '%s\n' "$run_json" | jq -r '.id // empty')")
			signature=$(codefactor_signature_from_annotations "$run_annotations")
		fi
		if [[ "$source_kind" == "pr" ]] && [[ -n "$pr_number" ]] &&
			{ [[ "$check_name" =~ [Cc]ode[Ff]actor ]] || [[ "$signature" == "failure:codefactor.io" ]]; }; then
			run_affected_paths="$affected_paths_json"
		fi

		emit_event_json "$repo_slug" "$source_kind" "$source_ref" "$source_url" \
			"$pr_number" "$commit_sha" "$check_name" "$conclusion" \
			"$run_id" "$html_url" "$details_url" "$completed_at" \
			"$signature" "$notification_updated_at" "$event_is_infra" "$event_infra_reason" \
			"$run_affected_paths" "$run_annotations" >>"$event_file"

		failed_index=$((failed_index + 1))
	done

	printf '%s' "$run_logs_checked"
	return 0
}

extract_failed_events_json() {
	local since_hours="$1"
	local limit="$2"
	local allowlist_csv="$3"
	local include_logs="$4"
	local max_run_logs="$5"
	local include_push_events="$6"

	local since_iso
	since_iso=$(iso_hours_ago "$since_hours")

	local notifications_json
	notifications_json=$(fetch_notifications_json "$since_iso" "$limit" 2>/dev/null || printf '[]')

	local ci_threads_json
	ci_threads_json=$(printf '%s\n' "$notifications_json" | jq '[.[] | select((.subject.url // "") as $u | (($u | test("/pulls/")) or ($include_push and ($u | test("/commits/")))))]' --argjson include_push "$include_push_events")

	local thread_count
	thread_count=$(printf '%s\n' "$ci_threads_json" | jq "$JQ_COUNT")

	local event_file
	event_file=$(mktemp)
	local run_logs_checked=0

	local index=0
	while [[ "$index" -lt "$thread_count" ]]; do
		local thread_json
		thread_json=$(printf '%s\n' "$ci_threads_json" | jq ".[${index}]")

		local repo_slug
		repo_slug=$(printf '%s\n' "$thread_json" | jq -r '.repository.full_name // empty')
		if [[ -z "$repo_slug" ]] || ! repo_in_allowlist "$repo_slug" "$allowlist_csv"; then
			index=$((index + 1))
			continue
		fi

		local subject_url
		subject_url=$(printf '%s\n' "$thread_json" | jq -r '.subject.url // empty')
		if [[ -z "$subject_url" ]]; then
			index=$((index + 1))
			continue
		fi

		local source_info
		source_info=$(resolve_source_from_subject "$subject_url" "$repo_slug" "$include_push_events") || {
			index=$((index + 1))
			continue
		}

		local source_kind source_ref source_url pr_number commit_sha head_sha
		IFS='|' read -r source_kind source_ref source_url pr_number commit_sha head_sha <<<"$source_info"

		if [[ -z "$head_sha" ]]; then
			index=$((index + 1))
			continue
		fi

		local checks_json
		checks_json=$(gh api "repos/${repo_slug}/commits/${head_sha}/check-runs?per_page=100" 2>/dev/null || printf '{"check_runs":[]}')

		local failed_runs_json
		failed_runs_json=$(filter_failed_check_runs "$checks_json")

		local notification_updated_at
		notification_updated_at=$(printf '%s\n' "$thread_json" | jq -r '.updated_at // empty')

		run_logs_checked=$(process_failed_runs "$failed_runs_json" \
			"$repo_slug" "$source_kind" "$source_ref" "$source_url" \
			"$pr_number" "$commit_sha" "$notification_updated_at" \
			"$include_logs" "$run_logs_checked" "$max_run_logs" "$event_file" "$checks_json")

		index=$((index + 1))
	done

	if [[ ! -s "$event_file" ]]; then
		printf '%s\n' '[]'
		rm -f "$event_file"
		return 0
	fi

	local events_json
	events_json=$(jq -s '.' "$event_file")
	deduplicate_failed_events_json "$events_json"
	rm -f "$event_file"
	return 0
}

render_report_markdown() {
	local events_json="$1"
	local systemic_threshold="$2"
	printf '%s\n' "$events_json" | jq -r '
		def systemic: .count >= $min_count;
		def key: (.check_name + " | " + .signature);
		"## GitHub Failed Notification Report",
		"",
		("- Total failed events: " + ((length) | tostring)),
		("- Unique repos: " + ((map(.repo) | unique | length) | tostring)),
		("- Unique sources: " + ((map(.repo + "|" + .source_kind + "|" + .source_ref) | unique | length) | tostring)),
		("- Push sources: " + ((map(select(.source_kind == "push")) | length) | tostring)),
		("- PR sources: " + ((map(select(.source_kind == "pr")) | length) | tostring)),
		"",
		"### Top Failure Clusters",
		(if length == 0 then
		  "- No failed CI events found in the selected notification window"
		 else
		  (sort_by(key)
		   | group_by(key)
		   | map({
			      check_name: .[0].check_name,
			      signature: .[0].signature,
			      count: length,
			      repos: (map(.repo) | unique),
			      sources: (map(.repo + "|" + .source_kind + "|" + .source_ref) | unique)
			    })
			   | sort_by(-.count)
			   | .[:12]
			   | map("- [" + (if systemic then "SYSTEMIC" else "local" end) + "] " + .check_name + " :: " + .signature + " (" + (.count|tostring) + " events, repos=" + ((.repos|length)|tostring) + ", sources=" + ((.sources|length)|tostring) + ")")
			   | .[])
		 end)
	' --argjson min_count "$systemic_threshold"
	return 0
}

render_issue_body_markdown() {
	local events_json="$1"
	local systemic_threshold="$2"
	printf '%s\n' "$events_json" | jq -r '
		def affected_paths_line($example):
			if (($example.affected_paths // []) | length) > 0 then
				"\n  affected files: " + (($example.affected_paths // []) | .[0:8] | join(", ")) +
				(if (($example.affected_paths // []) | length) > 8 then ", ..." else "" end)
			else "" end;
		def qlty_empty_sarif_signature($check_name; $signature):
			((($check_name // "") | test("Qlty[[:space:]]+Smell[[:space:]]+Threshold"; "i"))
				 and (($signature // "") | test("empty[[:space:]-]*SARIF"; "i")));
		def pulse_unbound_var_signature($check_name; $signature):
			((($check_name // "") | test("Pulse[[:space:]]+Unbound-Var[[:space:]]+Lint"; "i"))
				 or (($signature // "") | test("Pulse[[:space:]]+unbound-var[[:space:]]+violations[[:space:]]+found|multi-var[[:space:]]+local[[:space:]]+without[[:space:]]+init|pulse-unbound-var"; "i")));
		def systemic_fix_guidance($check_name; $signature):
			if ((($check_name // "") | test("CodeFactor"; "i")) or ($signature == "failure:codefactor.io")) then
				"- CodeFactor is an external advisory/static-analysis check. GitHub Actions logs usually only show `failure:codefactor.io`; read the CodeFactor details URL in Evidence for the file, line, and rule.\n" +
				"- If the details URL is inaccessible, use the `affected files` evidence from the failing PRs to identify the nearest local linter/static-analysis guard before editing.\n" +
				"- Reproduce the provider finding locally with the nearest repo linter/style/static-analysis command, fix the source issue rather than suppressing CodeFactor, and add a focused regression guard for the reported rule/file.\n" +
				"\n## Worker Guidance\n" +
				"1. Open the CodeFactor details URL from Evidence first; do not infer the reported file/rule from the GitHub run alone.\n" +
				"2. If CodeFactor details are unavailable, inspect the affected files listed in Evidence and the closest existing lint/test guard for those file types. If no focused guard exists, add one under `.agents/scripts/tests/` or the target package tests.\n" +
				"3. Run the focused guard plus the nearest local linter before opening a PR.\n"
			elif qlty_empty_sarif_signature($check_name; $signature) then
				"- Qlty Smell Threshold empty-SARIF failures are shared tooling failures, not PR-specific smell regressions.\n" +
				"- Harden the absolute threshold workflow/helper so empty `qlty smells --all --sarif` output emits diagnostic warning context and does not block unrelated PRs.\n" +
				"- Keep valid SARIF output blocking when the count exceeds `QLTY_SMELL_THRESHOLD`, and keep the delta-based qlty regression gate as the PR-specific smell guard.\n" +
				"\n## Worker Guidance\n" +
				"1. Edit `.agents/scripts/qlty-smell-threshold-helper.sh` and `.github/workflows/code-quality.yml`; do not change application files to satisfy an empty-SARIF signature.\n" +
				"2. Add or update `.agents/scripts/tests/test-qlty-smell-threshold-helper.sh` to cover empty, valid-pass, and valid-fail SARIF paths.\n" +
				"3. Run `shellcheck .agents/scripts/qlty-smell-threshold-helper.sh .agents/scripts/tests/test-qlty-smell-threshold-helper.sh` plus the focused qlty threshold helper test before opening a PR.\n"
			elif pulse_unbound_var_signature($check_name; $signature) then
				"- Pulse Unbound-Var Lint is a PR-specific shell safety gate; repeated failures usually mean multiple PR branches introduced `local foo bar` declarations, not that the workflow itself is broken.\n" +
				"- Read the `<!-- pulse-unbound-var-check -->` PR comment or failed log report and fix the listed `pulse-*.sh` files by initialising every local variable at declaration time.\n" +
				"- Only edit `.github/workflows/pulse-unbound-var-check.yml` or `.agents/scripts/pulse-unbound-var-check.sh` when the reported file lines are false positives or the report cannot identify the offending lines.\n" +
				"\n## Worker Guidance\n" +
				"1. Open each Evidence PR comment containing `<!-- pulse-unbound-var-check -->`; use the reported file paths and line numbers as the authoritative target list.\n" +
				"2. Fix each listed declaration with explicit initialisers, e.g. `local now=0 elapsed=0` or `local _cached_prs=\"\" _cached_issues=\"\"`.\n" +
				"3. Run `.agents/scripts/pulse-unbound-var-check.sh --scan-files <changed pulse scripts>` plus `shellcheck` on the changed shell files before opening a PR.\n"
			else
				"- Patch the failing workflow/check once at the source (workflow file, shared action, or toolchain pin), then rerun failed checks on affected PRs.\n" +
				"- Add a regression guard to detect this signature early in future pulses.\n"
			end;
		def key: (.check_name + "|" + .signature);
		(sort_by(key)
		 | group_by(key)
		 | map({
			 check_name: .[0].check_name,
			 signature: .[0].signature,
			 count: length,
			 repos: (map(.repo) | unique),
			 sources: (map(.repo + "|" + .source_kind + "|" + .source_ref) | unique),
				 examples: (.[0:5] | map({repo, source_kind, source_ref, source_url, run_url, details_url, conclusion, affected_paths, annotations}))
		   })
		 | sort_by(-.count)
		 | .[0]) as $top
		| if ($top == null) then
			"No failed CI events found for the selected notification window."
		  else
			"## Summary\n" +
			"- Pattern: `" + $top.check_name + "`\n" +
			"- Error signature: `" + $top.signature + "`\n" +
			"- Events observed: " + ($top.count|tostring) + "\n" +
			"- Systemic threshold: " + ($min_count|tostring) + "\n" +
			"- Repos impacted: " + (($top.repos|length)|tostring) + "\n\n" +
			"## Why this looks systemic\n" +
			"- The same failing check/signature appears across multiple notifications in a short window.\n" +
			"- Notifications come from PR and/or push check failures, indicating a shared CI/tooling issue.\n\n" +
			"## Evidence\n" +
			($top.examples | map("- " + .repo + " [" + .source_kind + ":" + .source_ref + "] (" + .conclusion + ")" +
			  (if .source_url != null then " - " + .source_url else "" end) +
			  (if .run_url != null then " - " + .run_url else "" end) +
			  (if .details_url != null then " - " + .details_url else "" end) +
			  affected_paths_line(.)
			) | join("\n")) + "\n\n" +
			"## Root Cause Hypothesis\n" +
			"- Workflow/config regression or shared dependency/integration break in `" + $top.check_name + "`.\n\n" +
			"## Proposed Systemic Fix\n" +
			systemic_fix_guidance($top.check_name; $top.signature)
		  end
	' --argjson min_count "$systemic_threshold"
	return 0
}

build_repo_clusters_json() {
	local events_json="$1"
	printf '%s\n' "$events_json" | jq '[sort_by(.repo + "|" + .check_name + "|" + .signature) | group_by(.repo + "|" + .check_name + "|" + .signature)[] | {
		repo: .[0].repo,
		check_name: .[0].check_name,
		signature: .[0].signature,
		count: length,
		is_infra: (any(.[]; .is_infra == true)),
		infra_reasons: (map(.infra_reason // empty) | unique),
		sources: (map(.source_kind + ":" + .source_ref) | unique),
		examples: (.[0:5] | map({source_kind, source_ref, source_url, run_url, details_url, conclusion, affected_paths, annotations}))
	}] | sort_by(-.count)'
	return 0
}

# Build a consolidated infrastructure advisory cluster for a repo.
# Groups all infra-flagged events into a single advisory per repo per outage window.
build_infra_advisory_cluster() {
	local events_json="$1"
	local repo_slug="$2"
	local systemic_threshold="${3:-2}"
	printf '%s\n' "$events_json" | jq --arg repo "$repo_slug" \
		--arg strong_all_checks "$INFRA_REASON_ALL_CHECKS_FAILED" \
		--argjson min_count "$systemic_threshold" '
		[.[] | select(.repo == $repo and .is_infra == true)] as $infra_events |
		($infra_events | map(.source_kind + ":" + .source_ref) | unique) as $sources |
		($infra_events | map(.infra_reason // empty) | unique) as $reasons |
		($reasons | any(. == "billing_annotation" or . == $strong_all_checks)) as $has_strong_evidence |
		if ($infra_events | length) == 0 or
			($has_strong_evidence | not) and
			(($infra_events | length) < $min_count or ($sources | length) < 2)
		then null
		else {
			repo: $repo,
			check_name: "multiple-checks",
			check_names: ($infra_events | map(.check_name) | unique),
			signature: "infra:outage",
			count: ($infra_events | length),
			is_infra: true,
			infra_reasons: $reasons,
			sources: $sources,
			examples: ($infra_events[0:5] | map({source_kind, source_ref, source_url, run_url, details_url, conclusion}))
		}
		end
	'
	return 0
}

compute_pattern_id() {
	local input_value="$1"
	# SHA-256 for content fingerprinting (not cryptographic security).
	# Truncated to 12 hex chars for human-readable dedup IDs.
	if command -v shasum >/dev/null 2>&1; then
		printf '%s' "$input_value" | shasum -a 256 | awk '{print $1}' | cut -c1-12
		return 0
	fi
	printf '%s' "$input_value" | md5 | cut -c1-12
	return 0
}

build_issue_title() {
	local check_name="$1"
	local count="$2"
	local is_infra="${3:-false}"
	if [[ "$is_infra" == "true" ]]; then
		printf 'Infrastructure advisory: %s events observed' "$count"
	else
		printf 'Systemic CI failure: %s (%s events)' "$check_name" "$count"
	fi
	return 0
}

build_infra_issue_body() {
	local cluster_json="$1"
	local pattern_id="$2"
	local threshold="$3"

	printf '%s\n' "$cluster_json" | jq -r '
		def infrastructure_reason_lines($threshold; $all_checks_reason):
			(.infra_reasons // []) as $reasons |
			(if ($reasons | index($all_checks_reason)) != null then
				"- Every completed check failed in at least one source containing two or more checks.\n"
			 else "" end) +
			(if ($reasons | index("billing_annotation")) != null then
				"- A structured check annotation reported billing or spending exhaustion.\n"
			 else "" end) +
			(if ($reasons | any(. == "billing_log" or . == "runner_log")) then
				"- " + (.count | tostring) + " matching infrastructure log events across " +
				(((.sources // []) | length) | tostring) + " sources met the systemic threshold of " +
				($threshold | tostring) + ".\n"
			 else "" end);
		"## Summary\n" +
		"- Affected checks: " + ((.check_names // [(.check_name // "multiple-checks")]) | join(", ")) + "\n" +
		"- Events observed: " + (.count|tostring) + "\n" +
		"- Sources affected: " + (((.sources // []) | length)|tostring) + "\n\n" +
		"## Why this looks like infrastructure\n" +
		infrastructure_reason_lines($threshold; $all_checks_reason) + "\n" +
		"## Evidence\n" +
		((.examples // []) | map("- " + (.source_kind // "source") + ":" + (.source_ref // "unknown") + " (" + (.conclusion // "unknown") + ")" +
		  (if .source_url != null then " - " + .source_url else "" end) +
		  (if .run_url != null then " - " + .run_url else "" end) +
		  (if .details_url != null then " - " + .details_url else "" end)
		) | join("\n")) + "\n\n" +
		"## Recommended Action\n" +
		"- Verify billing status and runner availability.\n" +
		"- Re-run failed workflows after the infrastructure issue is resolved.\n" +
		"- Do NOT make code changes to fix this — the root cause is external.\n\n" +
		"Signal tag: `gh-failure-miner:" + $pattern_id + "`\n"
	' --arg pattern_id "$pattern_id" \
		--arg all_checks_reason "$INFRA_REASON_ALL_CHECKS_FAILED" \
		--argjson threshold "$threshold"
	return $?
}

build_systemic_issue_body() {
	local cluster_json="$1"
	local pattern_id="$2"
	local threshold="$3"

	printf '%s\n' "$cluster_json" | jq -r '
		def affected_paths_line($example):
			if (($example.affected_paths // []) | length) > 0 then
				"\n  affected files: " + (($example.affected_paths // []) | .[0:8] | join(", ")) +
				(if (($example.affected_paths // []) | length) > 8 then ", ..." else "" end)
			else "" end;
		def annotations_line($example):
			if (($example.annotations // []) | length) > 0 then
				"\n  reported findings: " + (($example.annotations // []) | .[0:3] | map(
					((.path // "unreported") + (if (.start_line // null) != null then ":" + ((.start_line // 0) | tostring) else "" end) +
					(if ((.title // "") | length) > 0 then " — " + .title elif ((.message // "") | length) > 0 then " — " + .message else "" end))
				) | join("; ")) +
				(if (($example.annotations // []) | length) > 3 then "; ..." else "" end)
			else "" end;
		def qlty_empty_sarif_signature($check_name; $signature):
			((($check_name // "") | test("Qlty[[:space:]]+Smell[[:space:]]+Threshold"; "i"))
				 and (($signature // "") | test("empty[[:space:]-]*SARIF"; "i")));
		def pulse_unbound_var_signature($check_name; $signature):
			((($check_name // "") | test("Pulse[[:space:]]+Unbound-Var[[:space:]]+Lint"; "i"))
				 or (($signature // "") | test("Pulse[[:space:]]+unbound-var[[:space:]]+violations[[:space:]]+found|multi-var[[:space:]]+local[[:space:]]+without[[:space:]]+init|pulse-unbound-var"; "i")));
		def systemic_fix_guidance($check_name; $signature):
			if ((($check_name // "") | test("CodeFactor"; "i")) or ($signature == "failure:codefactor.io")) then
				"- CodeFactor is an external advisory/static-analysis check. GitHub Actions logs usually only show `failure:codefactor.io`; read the CodeFactor details URL in Evidence for the file, line, and rule.\n" +
				"- If the details URL is inaccessible, use the `affected files` evidence from the failing PRs to identify the nearest local linter/static-analysis guard before editing.\n" +
				"- Reproduce the provider finding locally with the nearest repo linter/style/static-analysis command, fix the source issue rather than suppressing CodeFactor, and add a focused regression guard for the reported rule/file.\n" +
				"\n" +
				"## Worker Guidance\n" +
				"1. Open the CodeFactor details URL from Evidence first; do not infer the reported file/rule from the GitHub run alone.\n" +
				"2. If CodeFactor details are unavailable, inspect the affected files listed in Evidence and the closest existing lint/test guard for those file types. If no focused guard exists, add one under `.agents/scripts/tests/` or the target package tests.\n" +
				"3. Run the focused guard plus the nearest local linter before opening a PR.\n"
			elif qlty_empty_sarif_signature($check_name; $signature) then
				"- Qlty Smell Threshold empty-SARIF failures are shared tooling failures, not PR-specific smell regressions.\n" +
				"- Harden the absolute threshold workflow/helper so empty `qlty smells --all --sarif` output emits diagnostic warning context and does not block unrelated PRs.\n" +
				"- Keep valid SARIF output blocking when the count exceeds `QLTY_SMELL_THRESHOLD`, and keep the delta-based qlty regression gate as the PR-specific smell guard.\n" +
				"\n## Worker Guidance\n" +
				"1. Edit `.agents/scripts/qlty-smell-threshold-helper.sh` and `.github/workflows/code-quality.yml`; do not change application files to satisfy an empty-SARIF signature.\n" +
				"2. Add or update `.agents/scripts/tests/test-qlty-smell-threshold-helper.sh` to cover empty, valid-pass, and valid-fail SARIF paths.\n" +
				"3. Run `shellcheck .agents/scripts/qlty-smell-threshold-helper.sh .agents/scripts/tests/test-qlty-smell-threshold-helper.sh` plus the focused qlty threshold helper test before opening a PR.\n"
			elif pulse_unbound_var_signature($check_name; $signature) then
				"- Pulse Unbound-Var Lint is a PR-specific shell safety gate; repeated failures usually mean multiple PR branches introduced `local foo bar` declarations, not that the workflow itself is broken.\n" +
				"- Read the `<!-- pulse-unbound-var-check -->` PR comment or failed log report and fix the listed `pulse-*.sh` files by initialising every local variable at declaration time.\n" +
				"- Only edit `.github/workflows/pulse-unbound-var-check.yml` or `.agents/scripts/pulse-unbound-var-check.sh` when the reported file lines are false positives or the report cannot identify the offending lines.\n" +
				"\n## Worker Guidance\n" +
				"1. Open each Evidence PR comment containing `<!-- pulse-unbound-var-check -->`; use the reported file paths and line numbers as the authoritative target list.\n" +
				"2. Fix each listed declaration with explicit initialisers, e.g. `local now=0 elapsed=0` or `local _cached_prs=\"\" _cached_issues=\"\"`.\n" +
				"3. Run `.agents/scripts/pulse-unbound-var-check.sh --scan-files <changed pulse scripts>` plus `shellcheck` on the changed shell files before opening a PR.\n"
			else
				"- Fix the workflow/check at the source, then rerun failed checks on affected PRs.\n" +
				"- Add a regression guard for this signature in pulse routine outputs.\n"
			end;
		"## Summary\n" +
		"- Pattern: `" + .check_name + "`\n" +
		"- Error signature: `" + .signature + "`\n" +
		"- Scope: this repo\n" +
		"- Events observed: " + (.count|tostring) + "\n" +
		"- Systemic threshold: " + ($threshold|tostring) + "\n\n" +
		"## Why this looks systemic\n" +
		"- The same check/signature failed repeatedly within the notification window.\n" +
		"- This suggests a shared workflow/tooling defect rather than a PR-specific code problem.\n\n" +
		"## Evidence\n" +
		(.examples | map("- " + .source_kind + ":" + .source_ref + " (" + .conclusion + ")" +
		  (if .source_url != null then " - " + .source_url else "" end) +
		  (if .run_url != null then " - " + .run_url else "" end) +
		  (if .details_url != null then " - " + .details_url else "" end) +
		  affected_paths_line(.) +
		  annotations_line(.)
		) | join("\n")) + "\n\n" +
		"## Root Cause Hypothesis\n" +
		"- Regression or external dependency/toolchain break in the shared check path.\n\n" +
		"## Proposed Systemic Fix\n" +
		systemic_fix_guidance(.check_name; .signature) + "\n" +
		"Signal tag: `gh-failure-miner:" + $pattern_id + "`\n"
	' --arg pattern_id "$pattern_id" --argjson threshold "$threshold"
	return $?
}

build_issue_body() {
	local cluster_json="$1"
	local pattern_id="$2"
	local threshold="$3"
	local is_infra="${4:-false}"

	if [[ "$is_infra" == "true" ]]; then
		build_infra_issue_body "$cluster_json" "$pattern_id" "$threshold"
		return $?
	fi

	build_systemic_issue_body "$cluster_json" "$pattern_id" "$threshold"
	return $?
}

ensure_repo_labels() {
	local clusters_json="$1"
	printf '%s\n' "$clusters_json" | jq -r '.[].repo' | sort -u | while IFS= read -r repo_entry; do
		# Skip empty or malformed slugs (must be owner/repo format)
		if [[ -z "$repo_entry" ]] || [[ "$repo_entry" != *"/"* ]]; then
			echo "ensure_repo_labels: skipping invalid repo slug: '${repo_entry}'" >&2
			continue
		fi
		gh label create "source:ci-failure-miner" --repo "$repo_entry" \
			--description "Auto-created by gh-failure-miner-helper.sh" --color "C2E0C6" --force || true
		gh label create "infrastructure" --repo "$repo_entry" \
			--description "Infrastructure/billing/runner issue — not a code defect" --color "E4E669" --force || true
	done
	return 0
}

issue_already_exists() {
	local repo_slug="$1"
	local signal_tag="$2"
	local existing_count
	existing_count=$(gh issue list --repo "$repo_slug" --state open --search "\"${signal_tag}\" in:body" --json number --limit 1 2>/dev/null | jq "$JQ_COUNT") || existing_count=0
	[[ "$existing_count" -gt 0 ]]
}

is_qlty_empty_sarif_signature() {
	local check_name="$1"
	local signature="$2"
	[[ "$check_name" =~ [Qq]lty[[:space:]]+Smell[[:space:]]+Threshold ]] && [[ "$signature" =~ [Ee]mpty[[:space:]-]*SARIF ]]
	return $?
}

is_obsolete_qlty_empty_sarif_cluster() {
	local check_name="$1"
	local signature="$2"
	local helper_path="${SCRIPT_DIR}/qlty-smell-threshold-helper.sh"
	if ! is_qlty_empty_sarif_signature "$check_name" "$signature"; then
		return 1
	fi
	if [[ ! -f "$helper_path" ]]; then
		return 1
	fi
	if grep -qF 'Failed to run qlty smells (empty SARIF output)' "$helper_path"; then
		return 1
	fi
	grep -qF 'skipping absolute smell threshold check' "$helper_path"
	return $?
}

create_or_preview_issue() {
	local cluster_json="$1"
	local pattern_id="$2"
	local systemic_threshold="$3"
	local dry_run="$4"
	local is_infra="${5:-false}"
	shift 5
	local extra_labels=("$@")

	local repo_slug check_name count
	repo_slug=$(printf '%s\n' "$cluster_json" | jq -r '.repo')
	check_name=$(printf '%s\n' "$cluster_json" | jq -r '.check_name // "multiple-checks"')
	count=$(printf '%s\n' "$cluster_json" | jq -r '.count')
	if ! printf '%s\n' "$cluster_json" | jq -e 'any((.examples // [])[]?; ([.source_ref, .source_url, .run_url, .details_url] | map(. // "") | any(. != "")))' >/dev/null; then
		echo "Skipping cluster for ${check_name} - no evidence examples"
		return 1
	fi

	local title
	title=$(build_issue_title "$check_name" "$count" "$is_infra")
	local body
	if ! body=$(build_issue_body "$cluster_json" "$pattern_id" "$systemic_threshold" "$is_infra"); then
		echo "Skipping cluster for ${check_name} - issue body generation failed"
		return 1
	fi
	if [[ -z "${body//[[:space:]]/}" ]]; then
		echo "Skipping cluster for ${check_name} - generated issue body was empty"
		return 1
	fi

	if [[ "$dry_run" == "true" ]]; then
		if [[ "$is_infra" == "true" ]]; then
			echo "DRY RUN: would create infrastructure advisory: ${title} (no auto-dispatch)"
		else
			echo "DRY RUN: would create issue: ${title}"
		fi
		return 0
	fi

	# Append signature footer
	local sig_helper="${SCRIPT_DIR}/gh-signature-helper.sh"
	if [[ -x "$sig_helper" ]]; then
		local sig_footer
		sig_footer=$("$sig_helper" footer --body "$body" 2>/dev/null || echo "")
		if [[ -n "$sig_footer" ]]; then
			body="${body}${sig_footer}"
		fi
	fi

	local create_cmd
	if [[ "$is_infra" == "true" ]]; then
		# Infrastructure issues: use "infrastructure" label instead of "bug".
		# Never add auto-dispatch — infrastructure outages self-resolve; code changes are wrong.
		create_cmd=(gh_create_issue --repo "$repo_slug" --title "$title" --body "$body" --label infrastructure --label "source:ci-failure-miner" --label "status:available" --label "origin:worker")
	else
		create_cmd=(gh_create_issue --repo "$repo_slug" --title "$title" --body "$body" --label bug --label "source:ci-failure-miner" --label "auto-dispatch" --label "status:available" --label "origin:worker" --label "tier:standard")
		local label seen_labels=",bug,source:ci-failure-miner,auto-dispatch,status:available,origin:worker,tier:standard,"
		local -a label_parts=()
		for label in ${extra_labels[@]+"${extra_labels[@]}"}; do
			[[ -n "$label" ]] || continue
			IFS=',' read -r -a label_parts <<<"$label"
			local label_part
			for label_part in "${label_parts[@]}"; do
				label_part=$(printf '%s\n' "$label_part" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
				[[ -n "$label_part" ]] || continue
				[[ "$seen_labels" == *",${label_part},"* ]] && continue
				create_cmd+=(--label "$label_part")
				seen_labels="${seen_labels}${label_part},"
			done
		done
	fi
	"${create_cmd[@]}" >/dev/null
	echo "Created issue: ${title}"
	return 0
}

should_skip_code_defect_cluster() {
	local repo_slug="$1"
	local check_name="$2"
	local signature="$3"
	local signal_tag="$4"
	if is_obsolete_qlty_empty_sarif_cluster "$check_name" "$signature"; then
		echo "Skipping cluster for ${check_name} - empty SARIF failure signature is already handled by qlty-smell-threshold-helper.sh"
		return 0
	fi
	if issue_already_exists "$repo_slug" "$signal_tag"; then
		echo "Skipping cluster for ${check_name} - existing open issue with ${signal_tag}"
		return 0
	fi
	return 1
}

create_systemic_issues() {
	local events_json="$1"
	local systemic_threshold="$2"
	local max_issues="$3"
	local dry_run="$4"
	shift 4
	local extra_labels=("$@")

	local clusters_json
	clusters_json=$(build_repo_clusters_json "$events_json")

	# Ensure source/infrastructure labels exist on repos that will receive issues
	if [[ "$dry_run" != "true" ]]; then
		ensure_repo_labels "$clusters_json"
	fi

	# --- Infrastructure advisory pass ---
	# Consolidate all infra-flagged events into ONE advisory per repo per outage window.
	# Infrastructure issues self-resolve; code changes are wrong. Never add auto-dispatch.
	local infra_repos
	infra_repos=$(printf '%s\n' "$clusters_json" | jq -r '[.[] | select(.is_infra == true) | .repo] | unique | .[]')
	local created=0
	while IFS= read -r infra_repo && [[ "$created" -lt "$max_issues" ]]; do
		[[ -z "$infra_repo" ]] && continue
		local advisory_cluster
		advisory_cluster=$(build_infra_advisory_cluster "$events_json" "$infra_repo" "$systemic_threshold")
		if [[ -z "$advisory_cluster" ]] || [[ "$advisory_cluster" == "null" ]]; then
			continue
		fi
		local pattern_id
		pattern_id=$(compute_pattern_id "${infra_repo}|infra:outage")
		local signal_tag="gh-failure-miner:${pattern_id}"
		if issue_already_exists "$infra_repo" "$signal_tag"; then
			echo "Skipping infra advisory for ${infra_repo} - existing open issue with ${signal_tag}"
			continue
		fi
		if create_or_preview_issue "$advisory_cluster" "$pattern_id" "$systemic_threshold" "$dry_run" "true"; then
			created=$((created + 1))
		fi
	done <<<"$infra_repos"

	# --- Code-defect cluster pass ---
	# Only process non-infra clusters. Exclude known sentinel / expected-behaviour signatures:
	# - "infra:*": infrastructure candidates are handled only by the corroborated advisory pass.
	# - "job_not_started": job cancelled before any step ran (cancel-in-progress: true race).
	# - "signature_not_fetched": log fetch budget exhausted — internal sentinel, not a real
	#   error signature. Treating it as systemic creates false-positive issues (GH#18978).
	local candidate_file
	candidate_file=$(mktemp)
	printf '%s\n' "$clusters_json" | jq --argjson min_count "$systemic_threshold" '[.[] | select(
		.count >= $min_count
		and (.is_infra // false) == false
		and ((.signature // "") as $signature | ["billing_outage","job_not_started","signature_not_fetched"] | index($signature) | not)
	)]' >"$candidate_file"

	local candidate_count
	candidate_count=$(jq "$JQ_COUNT" "$candidate_file")
	if [[ "$candidate_count" -eq 0 ]]; then
		if [[ "$created" -eq 0 ]]; then
			echo "No systemic clusters met threshold (${systemic_threshold})."
		fi
		rm -f "$candidate_file"
		return 0
	fi

	local idx=0
	while [[ "$idx" -lt "$candidate_count" ]] && [[ "$created" -lt "$max_issues" ]]; do
		local cluster_json
		cluster_json=$(jq ".[${idx}]" "$candidate_file")

		local repo_slug check_name signature
		repo_slug=$(printf '%s\n' "$cluster_json" | jq -r '.repo')
		check_name=$(printf '%s\n' "$cluster_json" | jq -r '.check_name')
		signature=$(printf '%s\n' "$cluster_json" | jq -r '.signature')

		local pattern_id
		pattern_id=$(compute_pattern_id "${repo_slug}|${check_name}|${signature}")
		local signal_tag="gh-failure-miner:${pattern_id}"

		if should_skip_code_defect_cluster "$repo_slug" "$check_name" "$signature" "$signal_tag"; then
			idx=$((idx + 1))
			continue
		fi

		if create_or_preview_issue "$cluster_json" "$pattern_id" "$systemic_threshold" "$dry_run" "false" ${extra_labels[@]+"${extra_labels[@]}"}; then
			created=$((created + 1))
		fi
		idx=$((idx + 1))
	done

	echo "Processed ${created} systemic cluster(s) (max=${max_issues}, threshold=${systemic_threshold})."
	rm -f "$candidate_file"
	return 0
}

render_prefetch_summary() {
	local events_json="$1"
	local systemic_threshold="$2"
	printf '%s\n' "$events_json" | jq -r '
		def key: (.check_name + "|" + .signature);
		(sort_by(key)
		 | group_by(key)
		 | map({check_name: .[0].check_name, signature: .[0].signature, count: length, repos: (map(.repo) | unique)})
		 | sort_by(-.count)) as $clusters
		| ($clusters | map(select(.count >= $min_count))) as $systemic
		| [
			"## GH Failed Notifications",
			"- failed events: " + ((length) | tostring),
			"- systemic clusters (>= " + ($min_count|tostring) + "): " + (($systemic|length)|tostring),
			(if ($systemic|length) == 0 then
			  "- top cluster: none"
			 else
			  "- top cluster: " + $systemic[0].check_name + " :: " + $systemic[0].signature + " (" + ($systemic[0].count|tostring) + " events, repos=" + (($systemic[0].repos|length)|tostring) + ")"
			 end)
		  ] | .[]
	' --argjson min_count "$systemic_threshold"
	return 0
}

build_routine_prompt() {
	local since_hours="$1"
	local systemic_threshold="$2"
	local max_issues="$3"
	local labels_csv="$4"

	local labels_flags=""
	if [[ -n "$labels_csv" ]]; then
		local label
		IFS=',' read -r -a label_array <<<"$labels_csv"
		for label in "${label_array[@]}"; do
			if [[ -n "$label" ]]; then
				labels_flags+=" --label ${label}"
			fi
		done
	fi

	printf 'Run ~/.aidevops/agents/scripts/gh-failure-miner-helper.sh create-issues --since-hours %s --pulse-repos --systemic-threshold %s --max-issues %s%s and then run ~/.aidevops/agents/scripts/gh-failure-miner-helper.sh report --since-hours %s --pulse-repos.' \
		"$since_hours" "$systemic_threshold" "$max_issues" "$labels_flags" "$since_hours"
	return 0
}

parse_launchd_options() {
	ROUTINE_NAME="$DEFAULT_ROUTINE_NAME"
	ROUTINE_SCHEDULE="$DEFAULT_ROUTINE_SCHEDULE"
	# Resolve to canonical (main) worktree, not a linked worktree.
	# Worktree paths like ~/Git/repo.branch-name get cleaned up, so the plist
	# must point at the main worktree (~/Git/repo) to survive worktree removal.
	local raw_dir
	raw_dir=$(cd "${SCRIPT_DIR}/../.." && pwd)
	ROUTINE_DIR=$(git -C "$raw_dir" worktree list --porcelain 2>/dev/null |
		awk '/^worktree / {print substr($0, 10); exit}') || ROUTINE_DIR=""
	if [[ -z "$ROUTINE_DIR" || ! -d "$ROUTINE_DIR" ]]; then
		ROUTINE_DIR="$raw_dir"
	fi
	ROUTINE_TITLE="$DEFAULT_ROUTINE_TITLE"
	LAUNCHD_SINCE_HOURS="$DEFAULT_SINCE_HOURS"
	LAUNCHD_SYSTEMIC_THRESHOLD="$DEFAULT_SYSTEMIC_THRESHOLD"
	LAUNCHD_MAX_ISSUES="3"
	LAUNCHD_LABELS_CSV="auto-dispatch"
	LAUNCHD_DRY_RUN="false"

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--name)
			require_option_value "$1" "$#" || return 1
			ROUTINE_NAME="$2"
			shift 2
			;;
		--schedule)
			require_option_value "$1" "$#" || return 1
			ROUTINE_SCHEDULE="$2"
			shift 2
			;;
		--dir)
			require_option_value "$1" "$#" || return 1
			ROUTINE_DIR="$2"
			shift 2
			;;
		--title)
			require_option_value "$1" "$#" || return 1
			ROUTINE_TITLE="$2"
			shift 2
			;;
		--since-hours)
			require_option_value "$1" "$#" || return 1
			LAUNCHD_SINCE_HOURS="$2"
			shift 2
			;;
		--systemic-threshold)
			require_option_value "$1" "$#" || return 1
			LAUNCHD_SYSTEMIC_THRESHOLD="$2"
			shift 2
			;;
		--max-issues)
			require_option_value "$1" "$#" || return 1
			LAUNCHD_MAX_ISSUES="$2"
			shift 2
			;;
		--labels)
			require_option_value "$1" "$#" || return 1
			LAUNCHD_LABELS_CSV="$2"
			shift 2
			;;
		--dry-run)
			LAUNCHD_DRY_RUN="true"
			shift
			;;
		--help | -h)
			print_usage
			return 2
			;;
		*)
			die "Unknown option for install-launchd-routine: $1"
			return 1
			;;
		esac
	done

	require_positive_integer "--since-hours" "$LAUNCHD_SINCE_HOURS" || return 1
	require_positive_integer "--systemic-threshold" "$LAUNCHD_SYSTEMIC_THRESHOLD" || return 1
	require_positive_integer "--max-issues" "$LAUNCHD_MAX_ISSUES" || return 1
	return 0
}

cmd_install_launchd_routine() {
	parse_launchd_options "$@" || {
		local rc=$?
		if [[ "$rc" -eq 2 ]]; then return 0; fi
		return 1
	}

	local routine_helper="${SCRIPT_DIR}/routine-helper.sh"
	if [[ ! -x "$routine_helper" ]]; then
		die "routine-helper.sh is missing or not executable at ${routine_helper}"
		return 1
	fi

	local prompt
	prompt=$(build_routine_prompt "$LAUNCHD_SINCE_HOURS" "$LAUNCHD_SYSTEMIC_THRESHOLD" "$LAUNCHD_MAX_ISSUES" "$LAUNCHD_LABELS_CSV")

	local action="install-launchd"
	if [[ "$LAUNCHD_DRY_RUN" == "true" ]]; then
		action="plan"
	fi

	bash "$routine_helper" "$action" \
		--name "$ROUTINE_NAME" \
		--schedule "$ROUTINE_SCHEDULE" \
		--dir "$ROUTINE_DIR" \
		--title "$ROUTINE_TITLE" \
		--prompt "$prompt"
	return $?
}

parse_common_options() {
	SINCE_HOURS="$DEFAULT_SINCE_HOURS"
	LIMIT="$DEFAULT_LIMIT"
	REPO_ALLOWLIST=""
	USE_PULSE_REPOS="false"
	REPOS_JSON_PATH="$DEFAULT_REPOS_JSON"
	INCLUDE_PUSH_EVENTS="true"
	INCLUDE_LOG_SIGNATURES="true"
	MAX_RUN_LOGS="$DEFAULT_MAX_RUN_LOGS"
	SYSTEMIC_THRESHOLD="$DEFAULT_SYSTEMIC_THRESHOLD"
	MAX_ISSUES="$DEFAULT_MAX_ISSUES"
	DRY_RUN="false"
	EXTRA_LABELS=()

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--since-hours)
			require_option_value "$1" "$#" || return 1
			SINCE_HOURS="$2"
			shift 2
			;;
		--limit)
			require_option_value "$1" "$#" || return 1
			LIMIT="$2"
			shift 2
			;;
		--repos)
			require_option_value "$1" "$#" || return 1
			REPO_ALLOWLIST="$2"
			shift 2
			;;
		--pulse-repos)
			USE_PULSE_REPOS="true"
			shift
			;;
		--repos-json)
			require_option_value "$1" "$#" || return 1
			REPOS_JSON_PATH="$2"
			shift 2
			;;
		--pr-only)
			INCLUDE_PUSH_EVENTS="false"
			shift
			;;
		--no-log-signatures)
			INCLUDE_LOG_SIGNATURES="false"
			shift
			;;
		--max-run-logs)
			require_option_value "$1" "$#" || return 1
			MAX_RUN_LOGS="$2"
			shift 2
			;;
		--systemic-threshold)
			require_option_value "$1" "$#" || return 1
			SYSTEMIC_THRESHOLD="$2"
			shift 2
			;;
		--max-issues)
			require_option_value "$1" "$#" || return 1
			MAX_ISSUES="$2"
			shift 2
			;;
		--label)
			require_option_value "$1" "$#" || return 1
			EXTRA_LABELS+=("$2")
			shift 2
			;;
		--dry-run)
			DRY_RUN="true"
			shift
			;;
		--help | -h)
			print_usage
			return 2
			;;
		*)
			die "Unknown option: $1"
			return 1
			;;
		esac
	done

	require_positive_integer "--since-hours" "$SINCE_HOURS" || return 1
	require_positive_integer "--limit" "$LIMIT" || return 1
	require_positive_integer "--max-run-logs" "$MAX_RUN_LOGS" || return 1
	require_positive_integer "--systemic-threshold" "$SYSTEMIC_THRESHOLD" || return 1
	require_positive_integer "--max-issues" "$MAX_ISSUES" || return 1

	if [[ "$LIMIT" -gt 100 ]]; then
		LIMIT=100
	fi

	REPO_ALLOWLIST=$(resolve_repo_allowlist "$REPO_ALLOWLIST" "$USE_PULSE_REPOS" "$REPOS_JSON_PATH")

	return 0
}

cmd_collect() {
	parse_common_options "$@" || {
		local rc=$?
		if [[ "$rc" -eq 2 ]]; then
			return 0
		fi
		return 1
	}
	require_tools || return 1

	extract_failed_events_json "$SINCE_HOURS" "$LIMIT" "$REPO_ALLOWLIST" "$INCLUDE_LOG_SIGNATURES" "$MAX_RUN_LOGS" "$INCLUDE_PUSH_EVENTS"
	return $?
}

cmd_report() {
	parse_common_options "$@" || {
		local rc=$?
		if [[ "$rc" -eq 2 ]]; then
			return 0
		fi
		return 1
	}
	require_tools || return 1

	local events_json
	events_json=$(extract_failed_events_json "$SINCE_HOURS" "$LIMIT" "$REPO_ALLOWLIST" "$INCLUDE_LOG_SIGNATURES" "$MAX_RUN_LOGS" "$INCLUDE_PUSH_EVENTS")
	render_report_markdown "$events_json" "$SYSTEMIC_THRESHOLD"
	return 0
}

cmd_issue_body() {
	parse_common_options "$@" || {
		local rc=$?
		if [[ "$rc" -eq 2 ]]; then
			return 0
		fi
		return 1
	}
	require_tools || return 1

	local events_json
	events_json=$(extract_failed_events_json "$SINCE_HOURS" "$LIMIT" "$REPO_ALLOWLIST" "$INCLUDE_LOG_SIGNATURES" "$MAX_RUN_LOGS" "$INCLUDE_PUSH_EVENTS")
	render_issue_body_markdown "$events_json" "$SYSTEMIC_THRESHOLD"
	return 0
}

cmd_create_issues() {
	parse_common_options "$@" || {
		local rc=$?
		if [[ "$rc" -eq 2 ]]; then
			return 0
		fi
		return 1
	}
	require_tools || return 1

	local events_json
	events_json=$(extract_failed_events_json "$SINCE_HOURS" "$LIMIT" "$REPO_ALLOWLIST" "$INCLUDE_LOG_SIGNATURES" "$MAX_RUN_LOGS" "$INCLUDE_PUSH_EVENTS")
	if [[ -n "${EXTRA_LABELS+x}" ]] && [[ "${#EXTRA_LABELS[@]}" -gt 0 ]]; then
		create_systemic_issues "$events_json" "$SYSTEMIC_THRESHOLD" "$MAX_ISSUES" "$DRY_RUN" "${EXTRA_LABELS[@]}"
		return 0
	fi
	create_systemic_issues "$events_json" "$SYSTEMIC_THRESHOLD" "$MAX_ISSUES" "$DRY_RUN"
	return 0
}

cmd_prefetch() {
	parse_common_options "$@" || {
		local rc=$?
		if [[ "$rc" -eq 2 ]]; then
			return 0
		fi
		return 1
	}
	require_tools || return 1

	local events_json
	events_json=$(extract_failed_events_json "$SINCE_HOURS" "$LIMIT" "$REPO_ALLOWLIST" "$INCLUDE_LOG_SIGNATURES" "$MAX_RUN_LOGS" "$INCLUDE_PUSH_EVENTS")
	render_prefetch_summary "$events_json" "$SYSTEMIC_THRESHOLD"
	return 0
}

main() {
	local command="${1:-help}"
	shift || true

	case "$command" in
	collect)
		cmd_collect "$@"
		return $?
		;;
	report)
		cmd_report "$@"
		return $?
		;;
	issue-body)
		cmd_issue_body "$@"
		return $?
		;;
	create-issues)
		cmd_create_issues "$@"
		return $?
		;;
	prefetch)
		cmd_prefetch "$@"
		return $?
		;;
	install-launchd-routine)
		cmd_install_launchd_routine "$@"
		return $?
		;;
	help | --help | -h)
		print_usage
		return 0
		;;
	*)
		die "Unknown command: $command"
		print_usage
		return 1
		;;
	esac
}

main "$@"

#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Protected-branch-safe publication for Issue Sync TODO.md projections.

set -euo pipefail

ISSUE_SYNC_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
# shellcheck source=./issue-sync-ci-context.sh
source "${ISSUE_SYNC_SCRIPT_DIR}/issue-sync-ci-context.sh"
issue_sync_prepare_ci_context
# shellcheck source=./planning-publisher.sh
source "${ISSUE_SYNC_SCRIPT_DIR}/planning-publisher.sh"
# shellcheck source=./shared-gh-wrappers.sh
source "${ISSUE_SYNC_SCRIPT_DIR}/shared-gh-wrappers.sh"
# shellcheck source=./issue-sync-lib-parse.sh
source "${ISSUE_SYNC_SCRIPT_DIR}/issue-sync-lib-parse.sh"

ISSUE_SYNC_PR_BRANCH="${AIDEVOPS_ISSUE_SYNC_PR_BRANCH:-aidevops/issue-sync-todo}"
ISSUE_SYNC_PR_MARKER="<!-- aidevops:issue-sync-todo-pr -->"
ISSUE_SYNC_COMMIT_SUBJECT="chore: sync GitHub issue state to TODO.md"
ISSUE_SYNC_DEFAULT_COMMIT_MESSAGE="${ISSUE_SYNC_COMMIT_SUBJECT} [skip ci]"
ISSUE_SYNC_LAST_PUBLISH_OUTPUT=""
ISSUE_SYNC_BASE_SHA=""
ISSUE_SYNC_SOURCE_BASE_SHA=""
ISSUE_SYNC_EXPECTED_TARGET_SHA=""

issue_sync_git() {
	_planning_git "$@"
	return $?
}

issue_sync_repo_slug() {
	local repo_path="$1"
	local remote_url=""
	local slug="${GITHUB_REPOSITORY:-}"
	if [[ "$slug" =~ ^[^/]+/[^/]+$ ]]; then
		printf '%s\n' "$slug"
		return 0
	fi
	remote_url=$(issue_sync_git -C "$repo_path" remote get-url origin 2>/dev/null) || return 1
	case "$remote_url" in
	git@github.com:*) slug="${remote_url#git@github.com:}" ;;
	ssh://git@github.com/*) slug="${remote_url#ssh://git@github.com/}" ;;
	https://github.com/*) slug="${remote_url#https://github.com/}" ;;
	http://github.com/*) slug="${remote_url#http://github.com/}" ;;
	*) return 1 ;;
	esac
	slug="${slug%.git}"
	[[ "$slug" =~ ^[^/]+/[^/]+$ ]] || return 1
	printf '%s\n' "$slug"
	return 0
}

issue_sync_is_gh006() {
	local output="$1"
	[[ "$output" == *"GH006"* && "$output" == *"Protected branch update failed"* ]]
	return $?
}

issue_sync_pr_commit_message() {
	local commit_msg="$1"
	local sanitized=""
	sanitized=$(printf '%s\n' "$commit_msg" | sed -E 's/[[:space:]]*\[skip ci\]//g')
	[[ -n "$sanitized" ]] || sanitized="$ISSUE_SYNC_COMMIT_SUBJECT"
	printf '%s\n' "$sanitized"
	return 0
}

issue_sync_changed_reference_numbers() {
	local base_file="$1"
	local candidate_file="$2"
	local commit_msg="$3"
	local diff_output=""
	local diff_rc=0
	diff_output=$(issue_sync_git diff --no-index --unified=0 -- "$base_file" "$candidate_file" 2>/dev/null) || diff_rc=$?
	if [[ "$diff_rc" -ne 0 && "$diff_rc" -ne 1 ]]; then
		return 1
	fi
	{
		printf '%s\n' "$commit_msg"
		printf '%s\n' "$diff_output"
	} | grep -oE '(ref:GH#|pr:#|GH#|PR[[:space:]]+#[0-9]+)[0-9]*' |
		grep -oE '[0-9]+' |
		sort -nu || true
	return 0
}

issue_sync_pr_linkage() {
	local base_file="$1"
	local candidate_file="$2"
	local commit_msg="$3"
	local reference_numbers=""
	local reference_number=""
	local linkage=""
	local count=0
	reference_numbers=$(issue_sync_changed_reference_numbers "$base_file" "$candidate_file" "$commit_msg") || return 1
	while IFS= read -r reference_number; do
		[[ "$reference_number" =~ ^[0-9]+$ ]] || continue
		linkage="${linkage}- Ref #${reference_number}"$'\n'
		count=$((count + 1))
		[[ "$count" -lt 20 ]] || break
	done <<<"$reference_numbers"
	if [[ -z "$linkage" ]]; then
		echo "::error::Cannot derive issue or PR linkage from the TODO.md publication"
		return 1
	fi
	printf '%s' "$linkage"
	return 0
}

issue_sync_planning_pr_body() {
	local default_branch="$1"
	local commit_msg="$2"
	local base_file="$3"
	local candidate_file="$4"
	local linkage=""
	linkage=$(issue_sync_pr_linkage "$base_file" "$candidate_file" "$commit_msg") || return 1
	cat <<EOF
${ISSUE_SYNC_PR_MARKER}
## Issue-sync TODO publication

- Publishes the cumulative \`TODO.md\` projection through a pull request because \`${default_branch}\` rejected direct publication with GH006.
- Uses the deterministic \`${ISSUE_SYNC_PR_BRANCH}\` branch so retries and concurrent events update one PR.
- Rebases the projection onto current \`${default_branch}\` while preserving unrelated TODO changes already queued in this PR.
- Latest publication intent: \`${commit_msg}\`.

## Linkage

${linkage}
## Merge behaviour

- The PR title retains \`[skip ci]\` so the eventual squash commit does not start another issue-sync loop.
- The PR branch commit intentionally omits \`[skip ci]\` so required pull-request checks still run.
- Canonical task and forge linkage remains in the projected \`ref:GH#...\` and \`pr:#...\` metadata.
EOF
	return 0
}

issue_sync_capture_planning_publish() {
	local repo_path="$1"
	local commit_msg="$2"
	local remote_name="$3"
	local branch_name="$4"
	local paths="$5"
	local output_file="$6"
	local rc=0
	: >"$output_file" || return 1
	planning_publish "$repo_path" "$commit_msg" "$remote_name" "$branch_name" "$paths" >"$output_file" 2>&1 || rc=$?
	ISSUE_SYNC_LAST_PUBLISH_OUTPUT=$(<"$output_file")
	if [[ -n "$ISSUE_SYNC_LAST_PUBLISH_OUTPUT" ]]; then
		printf '%s\n' "$ISSUE_SYNC_LAST_PUBLISH_OUTPUT"
	fi
	return "$rc"
}

issue_sync_merge_todo_file() {
	local current_file="$1"
	local ancestor_file="$2"
	local incoming_file="$3"
	local rc=0
	issue_sync_git merge-file --ours "$current_file" "$ancestor_file" "$incoming_file" >/dev/null 2>&1 || rc=$?
	if [[ "$rc" -ne 0 ]]; then
		echo "::error::Unable to merge concurrent TODO.md projections safely"
		return 1
	fi
	return 0
}

issue_sync_task_ids() {
	local todo_file="$1"
	local snapshot=""
	snapshot=$(_unique_todo_task_snapshot "$todo_file") || return 1
	printf '%s\n' "$snapshot" |
		sed -nE 's/^[[:space:]]*- \[[ x>-]\][[:space:]]+(t[0-9]+(\.[0-9]+)*)([[:space:]].*|$)/\1/p' |
		LC_ALL=C sort -u || return 1
	return 0
}

# Track task IDs added by the stale deterministic branch after its common
# ancestor. Seeding their canonical rows into the current side prevents an
# `--ours` same-hunk resolution from discarding queued branch additions.
issue_sync_find_branch_task_additions() {
	local ancestor_file="$1"
	local incoming_file="$2"
	local state_dir="$3"
	local ancestor_ids="${state_dir}/ancestor-task-ids"
	local incoming_ids="${state_dir}/incoming-task-ids"
	local branch_additions="${state_dir}/branch-task-additions"

	issue_sync_task_ids "$ancestor_file" >"$ancestor_ids" || return 1
	issue_sync_task_ids "$incoming_file" >"$incoming_ids" || return 1
	comm -23 "$incoming_ids" "$ancestor_ids" >"$branch_additions" || return 1
	return 0
}

issue_sync_ensure_terminal_newline() {
	local todo_file="$1"
	local terminal_newlines=0
	[[ -s "$todo_file" ]] || return 0
	terminal_newlines=$(LC_ALL=C tail -c 1 "$todo_file" | wc -l | tr -d '[:space:]') || return 1
	[[ "$terminal_newlines" =~ ^[01]$ ]] || return 1
	if [[ "$terminal_newlines" -eq 0 ]]; then
		printf '\n' >>"$todo_file" || return 1
	fi
	return 0
}

issue_sync_seed_branch_task_additions() {
	local current_file="$1"
	local incoming_file="$2"
	local state_dir="$3"
	local branch_additions="${state_dir}/branch-task-additions"
	local combined_todo="${state_dir}/combined-task-additions"
	local canonical_lines="${state_dir}/canonical-branch-task-lines"
	local winner_lines="${state_dir}/branch-task-winners"
	local winner_ids="${state_dir}/branch-task-winner-ids"
	local line=""
	[[ -s "$branch_additions" ]] || return 0

	awk '1' "$current_file" "$incoming_file" >"$combined_todo" || return 1
	_unique_todo_task_snapshot "$combined_todo" >"$canonical_lines" || return 1
	awk '
		FNR == NR { wanted[$1] = 1; next }
		match($0, /^[[:space:]]*-[[:space:]]+\[[ x>-]\][[:space:]]+/) {
			remaining = substr($0, RLENGTH + 1)
			split(remaining, fields, /[[:space:]]+/)
			if (fields[1] in wanted) { print }
		}
	' "$branch_additions" "$canonical_lines" >"$winner_lines" || return 1
	issue_sync_task_ids "$winner_lines" >"$winner_ids" || return 1
	cmp -s "$branch_additions" "$winner_ids" || return 1

	issue_sync_ensure_terminal_newline "$current_file" || return 1
	while IFS= read -r line || [[ -n "$line" ]]; do
		printf '%s\n' "$line" >>"$current_file" || return 1
	done <"$winner_lines"
	return 0
}

issue_sync_dedupe_concurrent_task_additions() {
	local todo_file="$1"
	local state_dir="$2"
	local concurrent_ids="${state_dir}/branch-task-additions"
	local canonical_lines="${state_dir}/canonical-task-lines"
	local filtered_todo="${state_dir}/deduplicated-todo"
	[[ -s "$concurrent_ids" ]] || return 0

	_unique_todo_task_snapshot "$todo_file" >"$canonical_lines" || return 1
	if ! awk -v wanted_file="$concurrent_ids" -v canonical_file="$canonical_lines" \
		-v todo_file="$todo_file" '
		function task_id(line, remaining, fields) {
			if (!match(line, /^[[:space:]]*-[[:space:]]+\[[ x>-]\][[:space:]]+/)) { return "" }
			remaining = substr(line, RLENGTH + 1)
			split(remaining, fields, /[[:space:]]+/)
			return fields[1]
		}
		function without_comments(raw, line, out, pos) {
			line = raw
			out = ""
			while (length(line) > 0) {
				if (in_comment) {
					pos = index(line, "-->")
					if (pos == 0) { line = ""; break }
					line = substr(line, pos + 3)
					in_comment = 0
				} else {
					pos = index(line, "<!--")
					if (pos == 0) { out = out line; line = ""; break }
					out = out substr(line, 1, pos - 1)
					line = substr(line, pos + 4)
					in_comment = 1
				}
			}
			return out
		}
		FILENAME == wanted_file { wanted[$1] = 1; next }
		FILENAME == canonical_file {
			id = task_id($0)
			if (id in wanted) { canonical[id] = $0 }
			next
		}
		FILENAME == todo_file {
			raw = $0
			if (raw ~ /^[[:space:]]*```/) { in_fence = !in_fence; print raw; next }
			if (in_fence) { print raw; next }
			normalized = without_comments(raw)
			id = task_id(normalized)
			if (id in wanted) {
				if (!kept[id] && normalized == canonical[id]) { print raw; kept[id] = 1 }
				next
			}
			print raw
		}
		END {
			for (id in wanted) {
				if (!(id in canonical) || !kept[id]) { failed = 1 }
			}
			exit failed
		}
	' "$concurrent_ids" "$canonical_lines" "$todo_file" >"$filtered_todo"; then
		return 1
	fi
	mv "$filtered_todo" "$todo_file" || return 1
	echo "::notice::Selected the richest live TODO.md entry for concurrent stale-branch task additions"
	return 0
}

issue_sync_trim_projection_tail() {
	local todo_file="$1"
	local state_dir="$2"
	local trimmed_todo="${state_dir}/trimmed-todo"
	if ! awk '
		{ lines[NR] = $0 }
		$0 !~ /^[[:space:]]*$/ { last_content = NR }
		END {
			if (last_content == 0) { exit 1 }
			for (line_num = 1; line_num <= last_content; line_num += 1) {
				print lines[line_num]
			}
		}
	' "$todo_file" >"$trimmed_todo"; then
		return 1
	fi
	mv "$trimmed_todo" "$todo_file" || return 1
	return 0
}

issue_sync_read_todo_blob() {
	local repo_path="$1"
	local commit_sha="$2"
	local destination="$3"
	issue_sync_git -C "$repo_path" show "${commit_sha}:TODO.md" >"$destination" 2>/dev/null
	return $?
}

issue_sync_prepare_base_snapshot() {
	local repo_path="$1"
	local default_branch="$2"
	local source_file="$3"
	local state_dir="$4"
	local merged_file="${state_dir}/merged-todo"
	local source_ancestor="${state_dir}/source-ancestor"
	local latest_todo="${state_dir}/latest-base-todo"
	local source_head=""

	issue_sync_git -C "$repo_path" fetch -q origin "$default_branch" || return 1
	ISSUE_SYNC_BASE_SHA=$(issue_sync_git -C "$repo_path" rev-parse FETCH_HEAD) || return 1
	source_head=$(issue_sync_git -C "$repo_path" rev-parse "HEAD^{commit}") || return 1
	ISSUE_SYNC_SOURCE_BASE_SHA=$(issue_sync_git -C "$repo_path" merge-base "$source_head" "$ISSUE_SYNC_BASE_SHA") || return 1
	cp -p "$source_file" "$merged_file" || return 1
	issue_sync_read_todo_blob "$repo_path" "$ISSUE_SYNC_SOURCE_BASE_SHA" "$source_ancestor" || return 1
	issue_sync_read_todo_blob "$repo_path" "$ISSUE_SYNC_BASE_SHA" "$latest_todo" || return 1
	issue_sync_merge_todo_file "$merged_file" "$source_ancestor" "$latest_todo" || return 1
	return 0
}

issue_sync_remote_branch_sha() {
	local repo_path="$1"
	local branch_name="$2"
	local remote_line=""
	local remote_sha=""
	local remote_ref=""
	remote_line=$(issue_sync_git -C "$repo_path" ls-remote --heads origin "refs/heads/${branch_name}") || return 1
	[[ -n "$remote_line" && "$remote_line" != *$'\n'* ]] || return 2
	IFS=$'\t' read -r remote_sha remote_ref <<<"$remote_line"
	[[ "$remote_sha" =~ ^[0-9a-fA-F]{40,64}$ && "$remote_ref" == "refs/heads/${branch_name}" ]] || return 1
	printf '%s\n' "$remote_sha"
	return 0
}

issue_sync_fetch_pr_history() {
	local repo_path="$1"
	local default_branch="$2"
	local branch_name="$3"
	local is_shallow=""
	local branch_rc=0
	is_shallow=$(issue_sync_git -C "$repo_path" rev-parse --is-shallow-repository) || {
		echo "::error::Unable to inspect issue-sync checkout history"
		return 1
	}
	if [[ "$is_shallow" == "true" ]]; then
		issue_sync_git -C "$repo_path" fetch -q --unshallow origin \
			"$default_branch" "$branch_name" || {
			branch_rc=0
			issue_sync_remote_branch_sha "$repo_path" "$branch_name" >/dev/null || branch_rc=$?
			[[ "$branch_rc" -ne 2 ]] || return 2
			echo "::error::Unable to recover history for the stale issue-sync PR branch"
			return 1
		}
	fi
	issue_sync_git -C "$repo_path" fetch -q origin "$branch_name" || {
		branch_rc=0
		issue_sync_remote_branch_sha "$repo_path" "$branch_name" >/dev/null || branch_rc=$?
		[[ "$branch_rc" -ne 2 ]] || return 2
		echo "::error::Unable to fetch the issue-sync PR branch"
		return 1
	}
	return 0
}

issue_sync_prepare_pr_snapshot() {
	local repo_path="$1"
	local default_branch="$2"
	local source_file="$3"
	local state_dir="$4"
	local sync_sha=""
	local sync_base=""
	local sync_ancestor="${state_dir}/sync-ancestor"
	local sync_todo="${state_dir}/sync-todo"
	local branch_rc=0
	local fetch_rc=0

	ISSUE_SYNC_EXPECTED_TARGET_SHA=""
	issue_sync_prepare_base_snapshot "$repo_path" "$default_branch" "$source_file" "$state_dir" || return 1
	sync_sha=$(issue_sync_remote_branch_sha "$repo_path" "$ISSUE_SYNC_PR_BRANCH") || branch_rc=$?
	if [[ "$branch_rc" -eq 2 ]]; then
		return 0
	fi
	[[ "$branch_rc" -eq 0 ]] || return 1
	issue_sync_fetch_pr_history "$repo_path" "$default_branch" "$ISSUE_SYNC_PR_BRANCH" || fetch_rc=$?
	if [[ "$fetch_rc" -eq 2 ]]; then
		return 0
	fi
	[[ "$fetch_rc" -eq 0 ]] || return 1
	sync_sha=$(issue_sync_git -C "$repo_path" rev-parse FETCH_HEAD) || return 1
	ISSUE_SYNC_EXPECTED_TARGET_SHA="$sync_sha"
	sync_base=$(issue_sync_git -C "$repo_path" merge-base "$ISSUE_SYNC_BASE_SHA" "$sync_sha") || return 1
	issue_sync_read_todo_blob "$repo_path" "$sync_base" "$sync_ancestor" || return 1
	issue_sync_read_todo_blob "$repo_path" "$sync_sha" "$sync_todo" || return 1
	issue_sync_find_branch_task_additions "$sync_ancestor" "$sync_todo" "$state_dir" || return 1
	issue_sync_seed_branch_task_additions "${state_dir}/merged-todo" \
		"$sync_todo" "$state_dir" || return 1
	issue_sync_merge_todo_file "${state_dir}/merged-todo" "$sync_ancestor" "$sync_todo" || return 1
	issue_sync_dedupe_concurrent_task_additions "${state_dir}/merged-todo" "$state_dir" || return 1
	issue_sync_trim_projection_tail "${state_dir}/merged-todo" "$state_dir" || return 1
	return 0
}

issue_sync_existing_pr_url() {
	local repo_slug="$1"
	local default_branch="$2"
	local existing=""
	existing=$(AIDEVOPS_GH_PR_LIST_CACHE_DISABLE=1 gh_pr_list \
		--repo "$repo_slug" --head "$ISSUE_SYNC_PR_BRANCH" --base "$default_branch" \
		--state open --json number,url --jq 'if length == 0 then "" elif length == 1 then .[0].url else "MULTIPLE" end' 2>/dev/null) || return 1
	if [[ "$existing" == "MULTIPLE" ]]; then
		echo "::error::Multiple open issue-sync PRs exist for ${ISSUE_SYNC_PR_BRANCH}"
		return 1
	fi
	printf '%s\n' "$existing"
	return 0
}

issue_sync_create_planning_pr() {
	local repo_slug="$1"
	local default_branch="$2"
	local pr_title="$3"
	local pr_body_file="$4"
	local api_token="${5:-}"
	if [[ -n "$api_token" ]]; then
		GH_TOKEN="$api_token" AIDEVOPS_PR_CREATE_READY=1 gh_create_pr \
			--repo "$repo_slug" \
			--base "$default_branch" \
			--head "$ISSUE_SYNC_PR_BRANCH" \
			--title "$pr_title" \
			--label "origin:worker" \
			--body-file "$pr_body_file"
		return $?
	fi
	AIDEVOPS_PR_CREATE_READY=1 gh_create_pr \
		--repo "$repo_slug" \
		--base "$default_branch" \
		--head "$ISSUE_SYNC_PR_BRANCH" \
		--title "$pr_title" \
		--label "origin:worker" \
		--body-file "$pr_body_file"
	return $?
}

issue_sync_ensure_planning_pr() {
	local repo_path="$1"
	local default_branch="$2"
	local commit_msg="$3"
	local state_dir="$4"
	local repo_slug=""
	local existing_url=""
	local pr_url=""
	local pr_body_file="${state_dir}/issue-sync-pr-body.md"
	local pr_title="$ISSUE_SYNC_DEFAULT_COMMIT_MESSAGE"
	local fallback_token="${AIDEVOPS_ISSUE_SYNC_PR_TOKEN:-}"

	repo_slug=$(issue_sync_repo_slug "$repo_path") || {
		echo "::error::Cannot resolve GitHub repository for issue-sync PR publication"
		return 1
	}
	existing_url=$(issue_sync_existing_pr_url "$repo_slug" "$default_branch") || return 1
	if [[ -n "$existing_url" ]]; then
		echo "::notice::Updated deterministic issue-sync PR ${existing_url}"
		return 0
	fi
	issue_sync_planning_pr_body "$default_branch" "$commit_msg" \
		"${state_dir}/latest-base-todo" "${state_dir}/merged-todo" >"$pr_body_file" || return 1
	pr_url=$(issue_sync_create_planning_pr "$repo_slug" "$default_branch" \
		"$pr_title" "$pr_body_file") || {
		pr_url=$(AIDEVOPS_GH_PR_LIST_CACHE_DISABLE=1 \
			_gh_recover_pr_if_exists "$ISSUE_SYNC_PR_BRANCH" "$repo_slug")
		if [[ -z "$pr_url" && -n "$fallback_token" && "$fallback_token" != "${GH_TOKEN:-}" ]]; then
			echo "::warning::Job-scoped token could not create the issue-sync PR; retrying with the configured SYNC_PAT API fallback"
			pr_url=$(issue_sync_create_planning_pr "$repo_slug" "$default_branch" \
				"$pr_title" "$pr_body_file" "$fallback_token") ||
				pr_url=$(AIDEVOPS_GH_PR_LIST_CACHE_DISABLE=1 \
					_gh_recover_pr_if_exists "$ISSUE_SYNC_PR_BRANCH" "$repo_slug")
		fi
		if [[ -z "$pr_url" ]]; then
			echo "::error::Failed to create or recover deterministic issue-sync PR"
			return 1
		fi
	}
	echo "::notice::Created deterministic issue-sync PR ${pr_url}"
	return 0
}

issue_sync_publish_via_pr() {
	local repo_path="$1"
	local default_branch="$2"
	local attempts="$3"
	local commit_msg="$4"
	local source_file="$5"
	local state_dir="$6"
	local branch_commit_msg=""
	local output_file="${state_dir}/pr-publish-output"
	local attempt=0
	local rc=0
	local branch_rc=0

	branch_commit_msg=$(issue_sync_pr_commit_message "$commit_msg") || return 1
	while [[ "$attempt" -lt "$attempts" ]]; do
		attempt=$((attempt + 1))
		issue_sync_prepare_pr_snapshot "$repo_path" "$default_branch" "$source_file" "$state_dir" || return 1
		cp -p "${state_dir}/merged-todo" "${repo_path}/TODO.md" || return 1
		rc=0
		AIDEVOPS_PLANNING_PARENT_BRANCH="$default_branch" \
			AIDEVOPS_PLANNING_BASE_SHA="$ISSUE_SYNC_BASE_SHA" \
			AIDEVOPS_PLANNING_EXPECTED_TARGET_SHA="$ISSUE_SYNC_EXPECTED_TARGET_SHA" \
			PLANNING_PUBLISH_MAX_RETRIES=1 \
			issue_sync_capture_planning_publish "$repo_path" "$branch_commit_msg" origin \
			"$ISSUE_SYNC_PR_BRANCH" TODO.md "$output_file" || rc=$?
		cp -p "$source_file" "${repo_path}/TODO.md" || return 1
		if [[ "$rc" -eq 0 ]]; then
			branch_rc=0
			issue_sync_remote_branch_sha "$repo_path" "$ISSUE_SYNC_PR_BRANCH" >/dev/null || branch_rc=$?
			if [[ "$branch_rc" -eq 2 ]]; then
				echo "::warning::Issue-sync PR branch disappeared after publication; rebuilding"
				continue
			fi
			[[ "$branch_rc" -eq 0 ]] || return 1
			issue_sync_ensure_planning_pr "$repo_path" "$default_branch" "$commit_msg" "$state_dir"
			return $?
		fi
		if [[ "$rc" -ne 2 ]]; then
			return "$rc"
		fi
		echo "::warning::Issue-sync PR branch changed concurrently; rebuilding from current ${default_branch}"
	done
	echo "::error::Failed to update deterministic issue-sync PR after ${attempts} attempts"
	return 1
}

issue_sync_publish_todo() {
	local default_branch="$1"
	local attempts="$2"
	local commit_msg="$3"
	local repo_path=""
	local state_dir=""
	local source_file=""
	local output_file=""
	local attempt=0
	local rc=0

	[[ "$attempts" =~ ^[1-9][0-9]*$ ]] || {
		echo "::error::Publication attempts must be a positive integer"
		return 2
	}
	repo_path=$(issue_sync_git rev-parse --show-toplevel) || return 1
	[[ -f "${repo_path}/TODO.md" && ! -L "${repo_path}/TODO.md" ]] || {
		echo "::error::TODO.md must be a regular file"
		return 1
	}
	state_dir=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/issue-sync-publish.XXXXXX") || return 1
	source_file="${state_dir}/source-todo"
	output_file="${state_dir}/direct-publish-output"
	cp -p "${repo_path}/TODO.md" "$source_file" || {
		rm -rf "$state_dir"
		return 1
	}

	while [[ "$attempt" -lt "$attempts" ]]; do
		attempt=$((attempt + 1))
		issue_sync_prepare_base_snapshot "$repo_path" "$default_branch" "$source_file" "$state_dir" || {
			cp -p "$source_file" "${repo_path}/TODO.md" || true
			rm -rf "$state_dir"
			return 1
		}
		cp -p "${state_dir}/merged-todo" "${repo_path}/TODO.md" || {
			rm -rf "$state_dir"
			return 1
		}
		rc=0
		AIDEVOPS_PLANNING_PARENT_BRANCH="" \
			AIDEVOPS_PLANNING_BASE_SHA="$ISSUE_SYNC_BASE_SHA" \
			PLANNING_PUBLISH_MAX_RETRIES=1 \
			issue_sync_capture_planning_publish "$repo_path" "$commit_msg" origin \
			"$default_branch" TODO.md "$output_file" || rc=$?
		cp -p "$source_file" "${repo_path}/TODO.md" || {
			rm -rf "$state_dir"
			return 1
		}
		if [[ "$rc" -eq 0 ]]; then
			rm -rf "$state_dir"
			return 0
		fi
		if issue_sync_is_gh006 "$ISSUE_SYNC_LAST_PUBLISH_OUTPUT"; then
			echo "::notice::Direct TODO.md publication is protected; routing through one deterministic PR"
			rc=0
			issue_sync_publish_via_pr "$repo_path" "$default_branch" "$attempts" "$commit_msg" "$source_file" "$state_dir" || rc=$?
			rm -rf "$state_dir"
			return "$rc"
		fi
		if [[ "$rc" -ne 2 ]]; then
			rm -rf "$state_dir"
			return "$rc"
		fi
		echo "::warning::TODO.md base advanced during publication; rebuilding safely"
	done
	rm -rf "$state_dir"
	echo "::error::Failed to publish TODO.md after ${attempts} attempts"
	return 1
}

issue_sync_git_push_usage() {
	cat <<'EOF'
Usage: issue-sync-git-push-helper.sh publish-todo [branch] [attempts] [commit-message]
       issue-sync-git-push-helper.sh push-todo [branch] [attempts]

Publishes TODO.md with planning-publisher.sh. A terminal GH006 response updates
one deterministic protected-branch PR instead of asking maintainers to weaken
branch protection. The legacy push-todo command derives its message from HEAD.
EOF
	return 0
}

main() {
	local command="${1:-}"
	local branch="${2:-main}"
	local attempts="${3:-3}"
	local commit_msg="${4:-}"

	case "$command" in
	publish-todo)
		[[ -n "$commit_msg" ]] || commit_msg="$ISSUE_SYNC_DEFAULT_COMMIT_MESSAGE"
		issue_sync_publish_todo "$branch" "$attempts" "$commit_msg"
		return $?
		;;
	push-todo)
		commit_msg=$(issue_sync_git log -1 --pretty=%s 2>/dev/null) || commit_msg="$ISSUE_SYNC_DEFAULT_COMMIT_MESSAGE"
		issue_sync_publish_todo "$branch" "$attempts" "$commit_msg"
		return $?
		;;
	-h | --help | help | "")
		issue_sync_git_push_usage
		return 0
		;;
	*)
		echo "Unknown command: $command" >&2
		issue_sync_git_push_usage >&2
		return 2
		;;
	esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	main "$@"
fi

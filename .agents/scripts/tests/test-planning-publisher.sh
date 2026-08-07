#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -u
# Fixture repositories are disposable; bypass interactive canonical-repo guards.
PATH="/usr/bin:/bin:/usr/sbin:/sbin"
export PATH
SCRIPT_DIR_TEST="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
PUBLISHER="${SCRIPT_DIR_TEST}/../planning-publisher.sh"
STATE_SCRIPT="${SCRIPT_DIR_TEST}/../pulse-simplification-state.sh"
PASS=0
FAIL=0

pass() {
	local name="$1"
	printf 'PASS %s\n' "$name"
	PASS=$((PASS + 1))
	return 0
}
fail() {
	local name="$1"
	local detail="${2:-}"
	printf 'FAIL %s: %s\n' "$name" "$detail"
	FAIL=$((FAIL + 1))
	return 0
}

setup_repo() {
	local root="$1"
	git init --bare --initial-branch=main "${root}/remote.git" >/dev/null 2>&1 || git init --bare "${root}/remote.git" >/dev/null 2>&1 || return 1
	git clone "${root}/remote.git" "${root}/work" >/dev/null 2>&1 || return 1
	git -C "${root}/work" config commit.gpgsign false || return 1
	printf '# Tasks\n' >"${root}/work/TODO.md"
	mkdir -p "${root}/work/todo/tasks" || return 1
	printf 'base\n' >"${root}/work/README.md"
	printf '{}\n' >"${root}/work/.aidevops.json"
	git -C "${root}/work" add TODO.md README.md .aidevops.json || return 1
	GIT_AUTHOR_NAME=Test GIT_AUTHOR_EMAIL=test@example.invalid GIT_COMMITTER_NAME=Test GIT_COMMITTER_EMAIL=test@example.invalid \
		git -C "${root}/work" commit -m seed >/dev/null || return 1
	git -C "${root}/work" push origin main >/dev/null 2>&1 || return 1
	return 0
}

state_digest() {
	local repo="$1"
	{
		git -C "$repo" rev-parse HEAD
		git -C "$repo" ls-files -s
		git -C "$repo" diff --binary
		git -C "$repo" diff --cached --binary
		git -C "$repo" status --porcelain=v1 --untracked-files=all
	} | git hash-object --stdin
	return 0
}

run_publish() {
	local repo="$1"
	local validator="${2:-/usr/bin/true}"
	local branch="${3:-main}"
	(
		SCRIPT_DIR="$(dirname "$PUBLISHER")"
		# shellcheck source=../planning-publisher.sh
		source "$PUBLISHER"
		AIDEVOPS_PLANNING_VALIDATOR="$validator" planning_publish "$repo" "plan: test publication" origin "$branch"
	)
	return $?
}

run_publish_with_parent() {
	local repo="$1"
	local branch="$2"
	local parent_branch="$3"
	(
		SCRIPT_DIR="$(dirname "$PUBLISHER")"
		# shellcheck source=../planning-publisher.sh
		source "$PUBLISHER"
		AIDEVOPS_PLANNING_PARENT_BRANCH="$parent_branch" \
			AIDEVOPS_PLANNING_VALIDATOR=/usr/bin/true \
			planning_publish "$repo" "plan: parented publication" origin "$branch" TODO.md
	)
	return $?
}

run_publish_with_receipt() {
	local repo="$1"
	local receipt_dir="$2"
	local branch="${3:-main}"
	(
		SCRIPT_DIR="$(dirname "$PUBLISHER")"
		# shellcheck source=../planning-publisher.sh
		source "$PUBLISHER"
		AIDEVOPS_PLANNING_GIT_BIN=/usr/bin/git \
			AIDEVOPS_PLANNING_VALIDATOR=/usr/bin/true \
			AIDEVOPS_PLANNING_RECEIPT_DIR="$receipt_dir" \
			AIDEVOPS_PLANNING_WRITE_RECEIPT=true \
			planning_publish "$repo" "plan: test receipt" origin "$branch" || exit $?
		printf 'receipt=%s\n' "$PLANNING_PUBLICATION_RECEIPT"
		printf 'commit=%s\n' "$PLANNING_PUBLISHED_COMMIT"
		printf 'source=%s\n' "$PLANNING_PUBLICATION_SOURCE_HEAD"
	)
	return $?
}

run_receipt_verify() {
	local repo="$1"
	local receipt_dir="$2"
	local branch="$3"
	local expected_commit="$4"
	(
		SCRIPT_DIR="$(dirname "$PUBLISHER")"
		# shellcheck source=../planning-publisher.sh
		source "$PUBLISHER"
		AIDEVOPS_PLANNING_GIT_BIN=/usr/bin/git \
			AIDEVOPS_PLANNING_RECEIPT_DIR="$receipt_dir" \
			planning_verify_publication_receipt "$repo" origin "$branch" "$expected_commit"
	)
	return $?
}

run_simplification_publish() {
	local repo="$1"
	local hook="${2:-}"
	local source_file="${3:-}"
	local validator="${4:-/usr/bin/true}"
	(
		LOGFILE="/dev/null"
		# shellcheck source=../pulse-simplification-state.sh
		source "$STATE_SCRIPT"
		AIDEVOPS_PLANNING_VALIDATOR="$validator" \
			AIDEVOPS_PLANNING_BEFORE_PUSH_HOOK="$hook" \
			_simplification_state_push "$repo" "$source_file"
	)
	return $?
}

test_git_binary_availability_is_validated() {
	local name="rejects an unavailable Git command with a controlled error"
	local output="" rc=0
	output=$({
		SCRIPT_DIR="$(dirname "$PUBLISHER")"
		# shellcheck source=../planning-publisher.sh
		source "$PUBLISHER"
		AIDEVOPS_PLANNING_GIT_BIN="aidevops-missing-git-command" _planning_git --version
	} 2>&1) || rc=$?
	if [[ "$rc" -eq 1 && "$output" == *"Planning Git binary is not available or executable: aidevops-missing-git-command"* ]]; then
		pass "$name"
	else
		fail "$name" "unexpected result (rc=$rc output=$output)"
	fi
	return 0
}

test_state_allowlist_and_idempotence() {
	local name="preserves local state, publishes only allowlisted bytes, and is idempotent"
	local root="" repo="" before="" after="" first_remote="" second_remote="" count=""
	root=$(mktemp -d) || return 0
	setup_repo "$root" || {
		fail "$name" setup
		return 0
	}
	repo="${root}/work"
	printf '%s\n' '- [ ] t001 test ref:GH#1' >>"${repo}/TODO.md"
	printf 'brief\n' >"${repo}/todo/tasks/t001.md"
	printf 'local-only\n' >>"${repo}/README.md"
	git -C "$repo" add README.md
	before=$(state_digest "$repo")
	run_publish "$repo" || {
		fail "$name" publish
		return 0
	}
	after=$(state_digest "$repo")
	first_remote=$(git --git-dir="${root}/remote.git" rev-parse main)
	run_publish "$repo" || {
		fail "$name" replay
		return 0
	}
	second_remote=$(git --git-dir="${root}/remote.git" rev-parse main)
	count=$(git --git-dir="${root}/remote.git" log --format=%B main | grep -c 'Planning-Publication-ID:' || true)
	if [[ "$before" == "$after" && "$first_remote" == "$second_remote" && "$count" -eq 1 ]] &&
		git --git-dir="${root}/remote.git" show main:TODO.md | grep -q t001 &&
		[[ "$(git --git-dir="${root}/remote.git" show main:README.md)" == "base" ]]; then pass "$name"; else fail "$name" invariant; fi
	rm -rf "$root"
	return 0
}

test_publication_receipt_revalidates_exact_handoff() {
	local name="persists and revalidates exact checkout-free publication evidence"
	local root="" repo="" receipt_dir="" output="" replay_output="" receipt="" published_commit="" replayed_commit="" source_head=""
	local before="" after="" valid_rc=0 replay_rc=0 changed_rc=0 added_rc=0 forged_rc=0 remote_head="" forged_tmp="" line=""
	root=$(mktemp -d) || return 0
	setup_repo "$root" || {
		fail "$name" setup
		return 0
	}
	repo="${root}/work"
	receipt_dir="${root}/receipts"
	printf '%s\n' '- [ ] t009 receipt handoff ref:GH#9' >>"${repo}/TODO.md"
	cp "${repo}/TODO.md" "${root}/expected-TODO.md" || return 0
	before=$(state_digest "$repo")
	output=$(run_publish_with_receipt "$repo" "$receipt_dir" main) || {
		fail "$name" publish
		rm -rf "$root"
		return 0
	}
	while IFS= read -r line; do
		case "$line" in
		receipt=*) receipt="${line#receipt=}" ;;
		commit=*) published_commit="${line#commit=}" ;;
		source=*) source_head="${line#source=}" ;;
		esac
	done <<<"$output"
	after=$(state_digest "$repo")
	remote_head=$(/usr/bin/git --git-dir="${root}/remote.git" rev-parse main)
	run_receipt_verify "$repo" "$receipt_dir" main "$published_commit" || valid_rc=$?
	rm -f "$receipt"
	replay_output=$(run_publish_with_receipt "$repo" "$receipt_dir" main) || replay_rc=$?
	while IFS= read -r line; do
		case "$line" in
		receipt=*) receipt="${line#receipt=}" ;;
		commit=*) replayed_commit="${line#commit=}" ;;
		esac
	done <<<"$replay_output"
	run_receipt_verify "$repo" "$receipt_dir" main "$published_commit" || replay_rc=$?
	printf '%s\n' '- [ ] t010 changed after publication ref:GH#10' >>"${repo}/TODO.md"
	run_receipt_verify "$repo" "$receipt_dir" main "$published_commit" >/dev/null 2>&1 || changed_rc=$?
	cp "${root}/expected-TODO.md" "${repo}/TODO.md" || return 0
	printf '%s\n' '# Added after publication' >"${repo}/todo/tasks/t011.md"
	run_receipt_verify "$repo" "$receipt_dir" main "$published_commit" >/dev/null 2>&1 || added_rc=$?
	rm -f "${repo}/todo/tasks/t011.md"
	forged_tmp="${receipt}.forged"
	while IFS= read -r line || [[ -n "$line" ]]; do
		if [[ "$line" == source_head=* ]]; then
			printf 'source_head=0000000000000000000000000000000000000000\n'
		else
			printf '%s\n' "$line"
		fi
	done <"$receipt" >"$forged_tmp"
	mv "$forged_tmp" "$receipt"
	run_receipt_verify "$repo" "$receipt_dir" main "$published_commit" >/dev/null 2>&1 || forged_rc=$?
	if [[ -f "$receipt" && "$before" == "$after" && "$valid_rc" -eq 0 && "$replay_rc" -eq 0 && \
		"$changed_rc" -ne 0 && "$added_rc" -ne 0 && "$forged_rc" -ne 0 && "$remote_head" == "$published_commit" && \
		"$replayed_commit" == "$published_commit" && "$source_head" == "$(/usr/bin/git -C "$repo" rev-parse HEAD)" ]] && \
		grep -q '^format=aidevops-planning-publication-v2$' "$receipt" &&
		grep -q '^handoff_id=[0-9a-fA-F]\{40,64\}$' "$receipt"; then
		pass "$name"
	else
		fail "$name" "receipt invariant failed (valid=$valid_rc replay=$replay_rc changed=$changed_rc added=$added_rc forged=$forged_rc)"
	fi
	rm -rf "$root"
	return 0
}

test_publication_receipt_rejects_ancestor_source_forgery() {
	local name="rejects a receipt that substitutes another ancestor for the published source HEAD"
	local root="" repo="" receipt_dir="" output="" receipt="" published_commit="" source_head=""
	local ancestor_head="" forged_tmp="" line="" forged_rc=0
	root=$(mktemp -d) || return 0
	setup_repo "$root" || {
		fail "$name" setup
		return 0
	}
	repo="${root}/work"
	receipt_dir="${root}/receipts"
	/usr/bin/git -C "$repo" commit --allow-empty -q -m 'source anchor' || return 0
	/usr/bin/git -C "$repo" push -q origin main || return 0
	ancestor_head=$(/usr/bin/git -C "$repo" rev-parse HEAD^) || return 0
	printf '%s\n' '- [ ] t012 immutable source handoff ref:GH#12' >>"${repo}/TODO.md"
	output=$(run_publish_with_receipt "$repo" "$receipt_dir" main) || {
		fail "$name" publish
		rm -rf "$root"
		return 0
	}
	while IFS= read -r line; do
		case "$line" in
		receipt=*) receipt="${line#receipt=}" ;;
		commit=*) published_commit="${line#commit=}" ;;
		source=*) source_head="${line#source=}" ;;
		esac
	done <<<"$output"
	forged_tmp="${receipt}.forged"
	while IFS= read -r line || [[ -n "$line" ]]; do
		if [[ "$line" == source_head=* ]]; then
			printf 'source_head=%s\n' "$ancestor_head"
		else
			printf '%s\n' "$line"
		fi
	done <"$receipt" >"$forged_tmp"
	mv "$forged_tmp" "$receipt"
	/usr/bin/git -C "$repo" update-ref refs/heads/main "$ancestor_head" "$source_head" || return 0
	run_receipt_verify "$repo" "$receipt_dir" main "$published_commit" >/dev/null 2>&1 || forged_rc=$?
	if [[ "$forged_rc" -ne 0 && "$(/usr/bin/git -C "$repo" rev-parse HEAD)" == "$ancestor_head" ]] &&
		/usr/bin/git --git-dir="${root}/remote.git" show -s --format=%B "$published_commit" |
		grep -q '^Planning-Publication-Handoff-ID: [0-9a-fA-F]\{40,64\}$'; then
		pass "$name"
	else
		fail "$name" "forged ancestor source was accepted (rc=$forged_rc)"
	fi
	rm -rf "$root"
	return 0
}

test_simplification_state_scope_preserves_checkout() {
	local name="publishes only simplification state without changing the source checkout"
	local root="" repo="" before="" after="" first_remote="" second_remote="" rejected_rc=0 count=""
	root=$(mktemp -d) || return 0
	setup_repo "$root" || {
		fail "$name" setup
		return 0
	}
	repo="${root}/work"
	mkdir -p "${repo}/.agents/configs" || return 0
	printf '%s\n' '{"files":{"example.sh":{"passes":1}}}' >"${repo}/.agents/configs/simplification-state.json"
	printf 'local-only\n' >>"${repo}/README.md"
	git -C "$repo" add README.md
	before=$(state_digest "$repo")
	(
		SCRIPT_DIR="$(dirname "$PUBLISHER")"
		# shellcheck source=../planning-publisher.sh
		source "$PUBLISHER"
		AIDEVOPS_PLANNING_VALIDATOR=/usr/bin/true \
			planning_publish "$repo" "reject state without scope" origin main \
			".agents/configs/simplification-state.json"
	) >/dev/null 2>&1 || rejected_rc=$?
	run_simplification_publish "$repo" || {
		fail "$name" publish
		return 0
	}
	after=$(state_digest "$repo")
	first_remote=$(git --git-dir="${root}/remote.git" rev-parse main)
	run_simplification_publish "$repo" || {
		fail "$name" replay
		return 0
	}
	second_remote=$(git --git-dir="${root}/remote.git" rev-parse main)
	count=$(git --git-dir="${root}/remote.git" log --format=%B main | grep -c 'Planning-Publication-ID:' || true)
	if [[ "$rejected_rc" -ne 0 && "$before" == "$after" && "$first_remote" == "$second_remote" && "$count" -eq 1 ]] &&
		git --git-dir="${root}/remote.git" show main:.agents/configs/simplification-state.json | grep -q 'example.sh' &&
		[[ "$(git --git-dir="${root}/remote.git" show main:README.md)" == "base" ]]; then
		pass "$name"
	else
		fail "$name" "scope or checkout invariant failed (reject_rc=$rejected_rc count=$count)"
	fi
	rm -rf "$root"
	return 0
}

test_external_simplification_source_contract() {
	local name="accepts only valid isolated simplification-state sources"
	local root="" repo="" source_file="" before="" after="" first_remote="" second_remote=""
	local receipt_dir="" receipt="" invalid="" source_path_leaked=0 validator_rc=0 reject_rc=0
	root=$(mktemp -d) || return 0
	setup_repo "$root" || {
		fail "$name" setup
		return 0
	}
	repo="${root}/work"
	mkdir -p "${repo}/.agents/configs" || return 0
	printf '%s\n' '{"files":{}}' >"${repo}/.agents/configs/simplification-state.json"
	git -C "$repo" add .agents/configs/simplification-state.json
	GIT_AUTHOR_NAME=Test GIT_AUTHOR_EMAIL=test@example.invalid GIT_COMMITTER_NAME=Test GIT_COMMITTER_EMAIL=test@example.invalid \
		git -C "$repo" commit -qm "seed simplification state"
	git -C "$repo" push -q origin main
	source_file="${root}/isolated-state.json"
	printf '%s\n' '{"files":{"external.sh":{"passes":3}}}' >"$source_file"
	receipt_dir="${root}/receipts"
	before=$(state_digest "$repo")
	AIDEVOPS_PLANNING_RECEIPT_DIR="$receipt_dir" AIDEVOPS_PLANNING_WRITE_RECEIPT=true \
		run_simplification_publish "$repo" "" "$source_file" || {
		fail "$name" publish
		rm -rf "$root"
		return 0
	}
	after=$(state_digest "$repo")
	first_remote=$(git --git-dir="${root}/remote.git" rev-parse main)
	AIDEVOPS_PLANNING_RECEIPT_DIR="$receipt_dir" AIDEVOPS_PLANNING_WRITE_RECEIPT=true \
		run_simplification_publish "$repo" "" "$source_file" || reject_rc=$?
	second_remote=$(git --git-dir="${root}/remote.git" rev-parse main)
	receipt=$(printf '%s\n' "$receipt_dir"/*.receipt)
	grep -Fq "$source_file" "$receipt" 2>/dev/null && source_path_leaked=1
	invalid="${root}/invalid.json"
	printf '%s\n' '{not-json' >"$invalid"
	run_simplification_publish "$repo" "" "$invalid" || validator_rc=$?
	if [[ "$before" == "$after" && "$first_remote" == "$second_remote" && "$reject_rc" -eq 0 && \
		"$validator_rc" -ne 0 && "$source_path_leaked" -eq 0 ]] &&
		git --git-dir="${root}/remote.git" show main:.agents/configs/simplification-state.json | grep -q 'external.sh'; then
		pass "$name"
	else
		fail "$name" "external source invariant failed (replay=$reject_rc invalid=$validator_rc leaked=$source_path_leaked)"
	fi
	rm -rf "$root"
	return 0
}

test_external_simplification_source_rejections() {
	local name="rejects symlink directory unauthorized and validation-failing external sources"
	local root="" repo="" valid="" invalid="" source_dir="" source_link="" remote_before="" before="" after=""
	local symlink_rc=0 directory_rc=0 scope_rc=0 validation_rc=0
	root=$(mktemp -d) || return 0
	setup_repo "$root" || {
		fail "$name" setup
		return 0
	}
	repo="${root}/work"
	mkdir -p "${repo}/.agents/configs" || return 0
	printf '%s\n' '{"files":{}}' >"${repo}/.agents/configs/simplification-state.json"
	git -C "$repo" add .agents/configs/simplification-state.json
	GIT_AUTHOR_NAME=Test GIT_AUTHOR_EMAIL=test@example.invalid GIT_COMMITTER_NAME=Test GIT_COMMITTER_EMAIL=test@example.invalid \
		git -C "$repo" commit -qm "seed simplification state"
	git -C "$repo" push -q origin main
	valid="${root}/valid.json"
	invalid="${root}/invalid-shape.json"
	source_dir="${root}/source-dir"
	source_link="${root}/source-link.json"
	printf '%s\n' '{"files":{"valid.sh":{"passes":1}}}' >"$valid"
	printf '%s\n' '{"entries":{}}' >"$invalid"
	mkdir -p "$source_dir"
	ln -s "$valid" "$source_link"
	remote_before=$(git --git-dir="${root}/remote.git" rev-parse main)
	before=$(state_digest "$repo")
	run_simplification_publish "$repo" "" "$source_link" || symlink_rc=$?
	run_simplification_publish "$repo" "" "$source_dir" || directory_rc=$?
	(
		# shellcheck source=../planning-publisher.sh
		source "$PUBLISHER"
		AIDEVOPS_PLANNING_PUBLISH_SCOPE=planning AIDEVOPS_PLANNING_VALIDATOR=/usr/bin/true \
			planning_publish "$repo" "reject external planning source" origin main TODO.md "$valid"
	) >/dev/null 2>&1 || scope_rc=$?
	run_simplification_publish "$repo" "" "$valid" /usr/bin/false || validation_rc=$?
	after=$(state_digest "$repo")
	if [[ "$symlink_rc" -ne 0 && "$directory_rc" -ne 0 && "$scope_rc" -ne 0 && "$validation_rc" -ne 0 && \
		"$before" == "$after" && "$remote_before" == "$(git --git-dir="${root}/remote.git" rev-parse main)" ]]; then
		pass "$name"
	else
		fail "$name" "rejection invariant failed (symlink=$symlink_rc dir=$directory_rc scope=$scope_rc validation=$validation_rc)"
	fi
	rm -rf "$root"
	return 0
}

test_simplification_state_defaults_to_main_without_origin_head() {
	local name="defaults simplification-state publication to main when origin/HEAD is unavailable"
	local root="" repo="" remote_state="" publish_rc=0
	root=$(mktemp -d) || return 0
	setup_repo "$root" || {
		fail "$name" setup
		return 0
	}
	repo="${root}/work"
	mkdir -p "${repo}/.agents/configs" || return 0
	printf '%s\n' '{"files":{"fallback.sh":{"passes":1}}}' >"${repo}/.agents/configs/simplification-state.json"
	git -C "$repo" symbolic-ref --delete refs/remotes/origin/HEAD 2>/dev/null || true
	LOGFILE=/dev/null AIDEVOPS_PLANNING_VALIDATOR=/usr/bin/true \
		bash -c 'set -eo pipefail; source "$1"; _simplification_state_push "$2"' \
		_ "$STATE_SCRIPT" "$repo"
	publish_rc=$?
	if [[ "$publish_rc" -ne 0 ]]; then
		fail "$name" publish
		rm -rf "$root"
		return 0
	fi
	remote_state=$(git --git-dir="${root}/remote.git" show main:.agents/configs/simplification-state.json 2>/dev/null) || remote_state=""
	if [[ "$remote_state" == *"fallback.sh"* ]]; then
		pass "$name"
	else
		fail "$name" "fallback publication did not reach main"
	fi
	rm -rf "$root"
	return 0
}

test_simplification_state_conflict_is_retryable() {
	local name="simplification-state contention fails retryably without overwriting remote state"
	local root="" repo="" hook="" source_file="" before="" after="" rc=0 remote_state=""
	root=$(mktemp -d) || return 0
	setup_repo "$root" || {
		fail "$name" setup
		return 0
	}
	repo="${root}/work"
	mkdir -p "${repo}/.agents/configs" || return 0
	printf '%s\n' '{"files":{}}' >"${repo}/.agents/configs/simplification-state.json"
	git -C "$repo" add .agents/configs/simplification-state.json
	GIT_AUTHOR_NAME=Test GIT_AUTHOR_EMAIL=test@example.invalid GIT_COMMITTER_NAME=Test GIT_COMMITTER_EMAIL=test@example.invalid \
		git -C "$repo" commit -qm "seed simplification state"
	git -C "$repo" push -q origin main
	source_file="${root}/isolated-state.json"
	printf '%s\n' '{"files":{"local.sh":{"passes":1}}}' >"$source_file"
	hook="${root}/state-rival.sh"
	cat >"$hook" <<'HOOK'
#!/usr/bin/env bash
repo="$1"; remote="$2"; branch="$3"; attempt="$6"
[[ "$attempt" == "1" ]] || exit 0
tmp=$(mktemp -d)
git clone -q "$(git -C "$repo" remote get-url "$remote")" "$tmp/work"
mkdir -p "$tmp/work/.agents/configs"
printf '%s\n' '{"files":{"rival.sh":{"passes":2}}}' >"$tmp/work/.agents/configs/simplification-state.json"
git -C "$tmp/work" add .agents/configs/simplification-state.json
GIT_AUTHOR_NAME=Rival GIT_AUTHOR_EMAIL=rival@example.invalid GIT_COMMITTER_NAME=Rival GIT_COMMITTER_EMAIL=rival@example.invalid git -C "$tmp/work" -c commit.gpgsign=false commit -qm rival
git -C "$tmp/work" push -q origin "$branch"
rm -rf "$tmp"
exit 0
HOOK
	chmod +x "$hook"
	before=$(state_digest "$repo")
	run_simplification_publish "$repo" "$hook" "$source_file" || rc=$?
	after=$(state_digest "$repo")
	remote_state=$(git --git-dir="${root}/remote.git" show main:.agents/configs/simplification-state.json)
	if [[ "$rc" -eq 2 && "$before" == "$after" && "$remote_state" == *"rival.sh"* && "$remote_state" != *"local.sh"* ]]; then
		pass "$name"
	else
		fail "$name" "conflict invariant failed (rc=$rc)"
	fi
	rm -rf "$root"
	return 0
}

test_validation_failure_pushes_nothing() {
	local name="validator failure pushes nothing"
	local root="" repo="" before="" rc=0
	root=$(mktemp -d) || return 0
	setup_repo "$root" || {
		fail "$name" setup
		return 0
	}
	repo="${root}/work"
	printf '%s\n' '- [ ] t002 rejected ref:GH#2' >>"${repo}/TODO.md"
	before=$(git --git-dir="${root}/remote.git" rev-parse main)
	run_publish "$repo" /usr/bin/false || rc=$?
	if [[ $rc -ne 0 && "$before" == "$(git --git-dir="${root}/remote.git" rev-parse main)" ]]; then pass "$name"; else fail "$name" "rc=$rc"; fi
	rm -rf "$root"
	return 0
}

test_contention_replay_and_conflict() {
	local name="replays unrelated contention"
	local root="" repo="" hook="" rc=0
	root=$(mktemp -d) || return 0
	setup_repo "$root" || {
		fail "$name" setup
		return 0
	}
	repo="${root}/work"
	printf '%s\n' '- [ ] t003 replay ref:GH#3' >>"${repo}/TODO.md"
	hook="${root}/contend.sh"
	cat >"$hook" <<'HOOK'
#!/usr/bin/env bash
repo="$1"; remote="$2"; branch="$3"; attempt="$6"
[[ "$attempt" == "1" ]] || exit 0
tmp=$(mktemp -d)
git clone -q "$(git -C "$repo" remote get-url "$remote")" "$tmp/work"
printf 'upstream\n' >>"$tmp/work/README.md"
git -C "$tmp/work" add README.md
GIT_AUTHOR_NAME=Rival GIT_AUTHOR_EMAIL=rival@example.invalid GIT_COMMITTER_NAME=Rival GIT_COMMITTER_EMAIL=rival@example.invalid git -C "$tmp/work" -c commit.gpgsign=false commit -qm rival
git -C "$tmp/work" push -q origin "$branch"
rm -rf "$tmp"
exit 0
HOOK
	chmod +x "$hook"
	(
		SCRIPT_DIR="$(dirname "$PUBLISHER")"
		# shellcheck source=../planning-publisher.sh
		source "$PUBLISHER"
		AIDEVOPS_PLANNING_VALIDATOR=/usr/bin/true AIDEVOPS_PLANNING_BEFORE_PUSH_HOOK="$hook" planning_publish "$repo" "plan: contention" origin main
	) || rc=$?
	if [[ $rc -eq 0 ]] && git --git-dir="${root}/remote.git" show main:README.md | grep -q upstream && git --git-dir="${root}/remote.git" show main:TODO.md | grep -q t003; then pass "$name"; else fail "$name" "replay rc=$rc"; fi
	rm -rf "$root"
	return 0
}

test_crash_replay_is_single_publication() {
	local name="crash before push replays once"
	local root="" repo="" rc=0 count=""
	root=$(mktemp -d) || return 0
	setup_repo "$root" || {
		fail "$name" setup
		return 0
	}
	repo="${root}/work"
	printf '%s\n' '- [ ] t004 crash replay ref:GH#4' >>"${repo}/TODO.md"
	(
		SCRIPT_DIR="$(dirname "$PUBLISHER")"
		# shellcheck source=../planning-publisher.sh
		source "$PUBLISHER"
		AIDEVOPS_PLANNING_VALIDATOR=/usr/bin/true AIDEVOPS_PLANNING_BEFORE_PUSH_HOOK=/usr/bin/false planning_publish "$repo" "plan: crash" origin main
	) || rc=$?
	if [[ $rc -eq 0 ]]; then
		fail "$name" "simulated crash succeeded"
		rm -rf "$root"
		return 0
	fi
	run_publish "$repo" || {
		fail "$name" replay
		rm -rf "$root"
		return 0
	}
	run_publish "$repo" || {
		fail "$name" idempotence
		rm -rf "$root"
		return 0
	}
	count=$(git --git-dir="${root}/remote.git" log --format=%B main | grep -c 'Planning-Publication-ID:' || true)
	if [[ $count -eq 1 ]]; then pass "$name"; else fail "$name" "publication count=$count"; fi
	rm -rf "$root"
	return 0
}

test_same_path_contention_is_retryable() {
	local name="same-path contention returns retryable conflict"
	local root="" repo="" hook="" rc=0 remote_todo=""
	root=$(mktemp -d) || return 0
	setup_repo "$root" || {
		fail "$name" setup
		return 0
	}
	repo="${root}/work"
	printf '%s\n' '- [ ] t005 local ref:GH#5' >>"${repo}/TODO.md"
	hook="${root}/same-path.sh"
	cat >"$hook" <<'HOOK'
#!/usr/bin/env bash
repo="$1"; remote="$2"; branch="$3"; attempt="$6"
[[ "$attempt" == "1" ]] || exit 0
tmp=$(mktemp -d)
git clone -q "$(git -C "$repo" remote get-url "$remote")" "$tmp/work"
printf '%s\n' '- [ ] t999 rival ref:GH#999' >>"$tmp/work/TODO.md"
git -C "$tmp/work" add TODO.md
GIT_AUTHOR_NAME=Rival GIT_AUTHOR_EMAIL=rival@example.invalid GIT_COMMITTER_NAME=Rival GIT_COMMITTER_EMAIL=rival@example.invalid git -C "$tmp/work" -c commit.gpgsign=false commit -qm rival
git -C "$tmp/work" push -q origin "$branch"
rm -rf "$tmp"
exit 0
HOOK
	chmod +x "$hook"
	(
		SCRIPT_DIR="$(dirname "$PUBLISHER")"
		# shellcheck source=../planning-publisher.sh
		source "$PUBLISHER"
		AIDEVOPS_PLANNING_VALIDATOR=/usr/bin/true AIDEVOPS_PLANNING_BEFORE_PUSH_HOOK="$hook" planning_publish "$repo" "plan: conflict" origin main
	) || rc=$?
	remote_todo=$(git --git-dir="${root}/remote.git" show main:TODO.md)
	if [[ $rc -eq 2 && "$remote_todo" == *"t999"* && "$remote_todo" != *"t005"* ]]; then pass "$name"; else fail "$name" "rc=$rc"; fi
	rm -rf "$root"
	return 0
}

test_stale_base_same_path_is_retryable() {
	local name="stale pinned base rejects an upstream planning overwrite"
	local root="" repo="" rival="" base_sha="" rc=0 remote_todo=""
	root=$(mktemp -d) || return 0
	setup_repo "$root" || {
		fail "$name" setup
		return 0
	}
	repo="${root}/work"
	base_sha=$(git -C "$repo" rev-parse HEAD)
	printf '%s\n' '- [ ] t009 local ref:GH#9' >>"${repo}/TODO.md"
	rival="${root}/rival"
	git clone -q "${root}/remote.git" "$rival"
	printf '%s\n' '- [ ] t999 upstream ref:GH#999' >>"${rival}/TODO.md"
	git -C "$rival" add TODO.md
	GIT_AUTHOR_NAME=Rival GIT_AUTHOR_EMAIL=rival@example.invalid GIT_COMMITTER_NAME=Rival GIT_COMMITTER_EMAIL=rival@example.invalid \
		git -C "$rival" -c commit.gpgsign=false commit -qm rival
	git -C "$rival" push -q origin main
	(
		SCRIPT_DIR="$(dirname "$PUBLISHER")"
		# shellcheck source=../planning-publisher.sh
		source "$PUBLISHER"
		AIDEVOPS_PLANNING_BASE_SHA="$base_sha" AIDEVOPS_PLANNING_VALIDATOR=/usr/bin/true \
			planning_publish "$repo" "plan: stale base" origin main
	) || rc=$?
	remote_todo=$(git --git-dir="${root}/remote.git" show main:TODO.md)
	if [[ "$rc" -eq 2 && "$remote_todo" == *"t999"* && "$remote_todo" != *"t009"* ]]; then
		pass "$name"
	else
		fail "$name" "rc=$rc"
	fi
	rm -rf "$root"
	return 0
}

test_absent_remote_branch_uses_safe_parent() {
	local name="creates an absent remote branch from a safe parent without local state leakage"
	local root="" repo="" branch="plan/new-branch" before="" after="" remote_sha="" replay_sha="" count=""
	root=$(mktemp -d) || return 0
	setup_repo "$root" || {
		fail "$name" setup
		return 0
	}
	repo="${root}/work"
	git -C "$repo" switch -c "$branch" >/dev/null 2>&1 || {
		fail "$name" branch
		return 0
	}
	printf 'unrelated local commit\n' >>"${repo}/README.md"
	git -C "$repo" add README.md
	GIT_AUTHOR_NAME=Local GIT_AUTHOR_EMAIL=local@example.invalid GIT_COMMITTER_NAME=Local GIT_COMMITTER_EMAIL=local@example.invalid \
		git -C "$repo" -c commit.gpgsign=false commit -qm local-only || {
		fail "$name" local-commit
		return 0
	}
	printf '%s\n' '- [ ] t007 first publication ref:GH#7' >>"${repo}/TODO.md"
	before=$(state_digest "$repo")
	run_publish "$repo" /usr/bin/true "$branch" || {
		fail "$name" publish
		return 0
	}
	after=$(state_digest "$repo")
	remote_sha=$(git --git-dir="${root}/remote.git" rev-parse "$branch")
	run_publish "$repo" /usr/bin/true "$branch" || {
		fail "$name" replay
		return 0
	}
	replay_sha=$(git --git-dir="${root}/remote.git" rev-parse "$branch")
	count=$(git --git-dir="${root}/remote.git" log --format=%B "$branch" | grep -c 'Planning-Publication-ID:' || true)
	if [[ "$before" == "$after" && "$remote_sha" == "$replay_sha" && "$count" -eq 1 ]] &&
		[[ "$(git --git-dir="${root}/remote.git" rev-parse "${branch}^")" == "$(git --git-dir="${root}/remote.git" rev-parse main)" ]] &&
		git --git-dir="${root}/remote.git" show "${branch}:TODO.md" | grep -q t007 &&
		[[ "$(git --git-dir="${root}/remote.git" show "${branch}:README.md")" == "base" ]]; then
		pass "$name"
	else
		fail "$name" invariant
	fi
	rm -rf "$root"
	return 0
}

test_absent_remote_branch_creation_contention() {
	local name="replays safely when a competitor creates the absent remote branch"
	local root="" repo="" branch="plan/raced-branch" hook="" before="" after="" rival_sha="" remote_sha="" rc=0
	root=$(mktemp -d) || return 0
	setup_repo "$root" || {
		fail "$name" setup
		return 0
	}
	repo="${root}/work"
	git -C "$repo" switch -c "$branch" >/dev/null 2>&1 || {
		fail "$name" branch
		return 0
	}
	printf '%s\n' '- [ ] t008 creation race ref:GH#8' >>"${repo}/TODO.md"
	hook="${root}/create-rival.sh"
	cat >"$hook" <<'HOOK'
#!/usr/bin/env bash
repo="$1"; remote="$2"; branch="$3"; attempt="$6"
[[ "$attempt" == "1" ]] || exit 0
tmp=$(mktemp -d)
git clone -q "$(git -C "$repo" remote get-url "$remote")" "$tmp/work"
git -C "$tmp/work" switch -c "$branch" >/dev/null 2>&1
printf 'rival branch creator\n' >>"$tmp/work/README.md"
git -C "$tmp/work" add README.md
GIT_AUTHOR_NAME=Rival GIT_AUTHOR_EMAIL=rival@example.invalid GIT_COMMITTER_NAME=Rival GIT_COMMITTER_EMAIL=rival@example.invalid git -C "$tmp/work" -c commit.gpgsign=false commit -qm rival
git -C "$tmp/work" push -q origin "$branch"
git -C "$tmp/work" rev-parse HEAD >"$(dirname "$repo")/rival-sha"
rm -rf "$tmp"
exit 0
HOOK
	chmod +x "$hook"
	before=$(state_digest "$repo")
	(
		SCRIPT_DIR="$(dirname "$PUBLISHER")"
		# shellcheck source=../planning-publisher.sh
		source "$PUBLISHER"
		AIDEVOPS_PLANNING_VALIDATOR=/usr/bin/true AIDEVOPS_PLANNING_BEFORE_PUSH_HOOK="$hook" \
			planning_publish "$repo" "plan: creation contention" origin "$branch"
	) || rc=$?
	after=$(state_digest "$repo")
	rival_sha=$(<"${root}/rival-sha")
	remote_sha=$(git --git-dir="${root}/remote.git" rev-parse "$branch")
	if [[ "$rc" -eq 0 && "$before" == "$after" ]] &&
		git --git-dir="${root}/remote.git" merge-base --is-ancestor "$rival_sha" "$remote_sha" &&
		git --git-dir="${root}/remote.git" show "${branch}:README.md" | grep -q 'rival branch creator' &&
		git --git-dir="${root}/remote.git" show "${branch}:TODO.md" | grep -q t008; then
		pass "$name"
	else
		fail "$name" "contention rc=$rc"
	fi
	rm -rf "$root"
	return 0
}

test_parent_branch_replay_is_idempotent() {
	local name="keeps a current parented publication stable and rebases it after parent advancement"
	local root="" repo="" branch="plan/parented" before="" after=""
	local first_sha="" replay_sha="" rebased_sha="" main_sha="" parent_sha="" count=""
	local rival=""
	root=$(mktemp -d) || return 0
	setup_repo "$root" || {
		fail "$name" setup
		return 0
	}
	repo="${root}/work"
	printf '%s\n' '- [ ] t010 parented publication ref:GH#10' >>"${repo}/TODO.md"
	before=$(state_digest "$repo")
	run_publish_with_parent "$repo" "$branch" main || {
		fail "$name" publish
		rm -rf "$root"
		return 0
	}
	first_sha=$(git --git-dir="${root}/remote.git" rev-parse "$branch")
	sleep 1
	run_publish_with_parent "$repo" "$branch" main || {
		fail "$name" replay
		rm -rf "$root"
		return 0
	}
	replay_sha=$(git --git-dir="${root}/remote.git" rev-parse "$branch")
	rival="${root}/rival"
	git clone -q "${root}/remote.git" "$rival" || return 0
	printf 'advanced parent\n' >>"${rival}/README.md"
	git -C "$rival" add README.md
	GIT_AUTHOR_NAME=Rival GIT_AUTHOR_EMAIL=rival@example.invalid GIT_COMMITTER_NAME=Rival GIT_COMMITTER_EMAIL=rival@example.invalid \
		git -C "$rival" -c commit.gpgsign=false commit -qm 'advance parent'
	git -C "$rival" push -q origin main
	run_publish_with_parent "$repo" "$branch" main || {
		fail "$name" rebase
		rm -rf "$root"
		return 0
	}
	after=$(state_digest "$repo")
	rebased_sha=$(git --git-dir="${root}/remote.git" rev-parse "$branch")
	main_sha=$(git --git-dir="${root}/remote.git" rev-parse main)
	parent_sha=$(git --git-dir="${root}/remote.git" rev-parse "${branch}^")
	count=$(git --git-dir="${root}/remote.git" log --format=%B "$branch" | grep -c 'Planning-Publication-ID:' || true)
	if [[ "$before" == "$after" && "$first_sha" == "$replay_sha" && "$rebased_sha" != "$replay_sha" && \
		"$parent_sha" == "$main_sha" && "$count" -eq 1 ]] &&
		git --git-dir="${root}/remote.git" show "${branch}:TODO.md" | grep -q t010 &&
		git --git-dir="${root}/remote.git" show "${branch}:README.md" | grep -q 'advanced parent'; then
		pass "$name"
	else
		fail "$name" "parented publication invariant failed"
	fi
	rm -rf "$root"
	return 0
}

test_explicit_git_capability_preserves_guarded_checkout() {
	local name="explicit Git capability publishes planning paths while canonical guard remains active"
	local root="" repo="" shim_dir="" before="" after="" guard_rc=0 guard_output="" count="" real_git="" real_true=""
	real_git=$(command -v git || true)
	real_true=$(command -v true || true)
	if [[ -z "$real_git" || -z "$real_true" ]]; then
		fail "$name" command-resolution
		return 0
	fi
	root=$(mktemp -d) || return 0
	setup_repo "$root" || {
		fail "$name" setup
		return 0
	}
	repo="${root}/work"
	shim_dir="${root}/shim"
	mkdir -p "$shim_dir" || {
		fail "$name" shim
		return 0
	}
	cp "${SCRIPT_DIR_TEST}/../git" \
		"${SCRIPT_DIR_TEST}/../canonical-git-command-guard.py" \
		"${SCRIPT_DIR_TEST}/../canonical_git_invocation.py" \
		"${SCRIPT_DIR_TEST}/../canonical_git_policy.py" \
		"${SCRIPT_DIR_TEST}/../canonical_git_readonly.py" \
		"${SCRIPT_DIR_TEST}/../canonical_git_ref_queries.py" \
		"${SCRIPT_DIR_TEST}/../canonical_git_management.py" \
		"${SCRIPT_DIR_TEST}/../canonical_git_repository.py" \
		"${SCRIPT_DIR_TEST}/../canonical_shell_parser.py" \
		"$shim_dir/" || {
		fail "$name" guard-copy
		return 0
	}
	printf '%s\n' '- [x] t006 proof ref:GH#6 pr:#60 completed:2026-07-14' >>"${repo}/TODO.md"
	printf '%s\n' '**Status:** Completed' '**TODO:** t006' '**PR:** #60' >"${repo}/todo/PLANS.md"
	before=$(state_digest "$repo")
	(
		export PATH="${shim_dir}:${PATH}"
		export GIT_AUTHOR_NAME="GitHub Actions"
		export GIT_AUTHOR_EMAIL="actions@github.com"
		export GIT_COMMITTER_NAME="GitHub Actions"
		export GIT_COMMITTER_EMAIL="actions@github.com"
		SCRIPT_DIR="$(dirname "$PUBLISHER")"
		# shellcheck source=../planning-publisher.sh
		source "$PUBLISHER"
		AIDEVOPS_PLANNING_GIT_BIN="$real_git" \
			AIDEVOPS_PLANNING_VALIDATOR="$real_true" \
			planning_publish "$repo" "plan: guarded task projection" origin main $'TODO.md\ntodo/PLANS.md'
	) || {
		fail "$name" publish
		rm -rf "$root"
		return 0
	}
	after=$(state_digest "$repo")
	guard_output=$(PATH="${shim_dir}:${PATH}" git -C "$repo" config user.name blocked-test 2>&1) || guard_rc=$?
	count=$(git --git-dir="${root}/remote.git" show main:TODO.md | grep -c 'pr:#60 completed:2026-07-14' || true)
	if [[ "$before" == "$after" && "$guard_rc" -eq 42 && "$count" -eq 1 ]] &&
		git --git-dir="${root}/remote.git" show main:todo/PLANS.md | grep -q 'Status:\*\* Completed'; then
		pass "$name"
	else
		fail "$name" "state or guard invariant failed (guard_rc=$guard_rc count=$count output=$guard_output)"
	fi
	rm -rf "$root"
	return 0
}

main() {
	test_git_binary_availability_is_validated
	test_state_allowlist_and_idempotence
	test_publication_receipt_revalidates_exact_handoff
	test_publication_receipt_rejects_ancestor_source_forgery
	test_simplification_state_scope_preserves_checkout
	test_external_simplification_source_contract
	test_external_simplification_source_rejections
	test_simplification_state_defaults_to_main_without_origin_head
	test_simplification_state_conflict_is_retryable
	test_validation_failure_pushes_nothing
	test_contention_replay_and_conflict
	test_crash_replay_is_single_publication
	test_same_path_contention_is_retryable
	test_stale_base_same_path_is_retryable
	test_absent_remote_branch_uses_safe_parent
	test_absent_remote_branch_creation_contention
	test_parent_branch_replay_is_idempotent
	test_explicit_git_capability_preserves_guarded_checkout
	printf '%s passed, %s failed\n' "$PASS" "$FAIL"
	[[ $FAIL -eq 0 ]] || return 1
	return 0
}

main "$@"

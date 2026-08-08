#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# shellcheck disable=SC2016 # Markdown backticks in printf format strings are literal.
# Protected-main release recovery shared by version-manager publication and
# full-loop reconciliation.

[[ -n "${_VERSION_MANAGER_PROTECTED_MAIN_LOADED:-}" ]] && return 0
_VERSION_MANAGER_PROTECTED_MAIN_LOADED=1

if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_vm_protected_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_vm_protected_lib_path" == "${BASH_SOURCE[0]}" ]] && _vm_protected_lib_path="."
	SCRIPT_DIR="$(cd "$_vm_protected_lib_path" && pwd)"
	unset _vm_protected_lib_path
fi
if ! declare -F print_error >/dev/null 2>&1; then
	# shellcheck source=./shared-constants.sh
	source "${SCRIPT_DIR}/shared-constants.sh"
fi

_VERSION_MANAGER_PROTECTED_PR_JSON=""
_VERSION_MANAGER_PROTECTED_PR_NUMBER=""
_VERSION_MANAGER_PROTECTED_RELEASE_BRANCH=""
_VERSION_MANAGER_PROTECTED_RELEASE_HEAD=""
_VERSION_MANAGER_PROTECTED_RELEASE_RESULT=""
_VERSION_MANAGER_LOCAL_TAG_OBJECT=""
_VERSION_MANAGER_LOCAL_TAG_COMMIT=""
_VERSION_MANAGER_REMOTE_TAG_OBJECT=""
_VERSION_MANAGER_REMOTE_TAG_COMMIT=""
_VERSION_MANAGER_REMOTE_TAG_STATE=""
_VERSION_MANAGER_PROTECTED_SUPERSESSION_JSON=""
_VERSION_MANAGER_TAG_STATE_ABSENT="absent"
_VERSION_MANAGER_TAG_STATE_MATCHING="matching"
_VERSION_MANAGER_RELEASE_RESULT_QUEUED="queued"
_VERSION_MANAGER_MODE_RECONCILE="reconcile"
_VERSION_MANAGER_PR_STATE_OPEN="open"
_VERSION_MANAGER_PR_STATE_CLOSED="closed"
_VERSION_MANAGER_TIMESTAMP_REGEX='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'

_version_manager_push_requires_pr() {
	local push_output="$1"

	case "$push_output" in
	*"Changes must be made through a pull request"*)
		case "$push_output" in
		*"GH006"* | *"GH013"* | *"protected branch hook declined"*) return 0 ;;
		esac
		;;
	esac
	return 1
}

_version_manager_protected_release_branch_name() {
	local version="$1"

	[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
	printf 'chore/release-v%s-provenance\n' "$version"
	return 0
}

_version_manager_protected_repo_slug() {
	local repo="${AIDEVOPS_VERSION_MANAGER_REPO_SLUG:-}"

	if [[ -z "$repo" ]] && declare -F _release_repo_slug >/dev/null 2>&1; then
		repo=$(_release_repo_slug 2>/dev/null || true)
	fi
	[[ "$repo" =~ ^[^/[:space:]]+/[^/[:space:]]+$ ]] || return 1
	printf '%s\n' "$repo"
	return 0
}

_version_manager_local_tag_identity() {
	local tag_name="$1"
	local object_type=""
	local tag_ref="refs/tags/${tag_name}"

	_VERSION_MANAGER_LOCAL_TAG_OBJECT=""
	_VERSION_MANAGER_LOCAL_TAG_COMMIT=""
	_VERSION_MANAGER_LOCAL_TAG_OBJECT=$(git -C "$REPO_ROOT" rev-parse "$tag_ref" 2>/dev/null) || return 1
	_VERSION_MANAGER_LOCAL_TAG_COMMIT=$(git -C "$REPO_ROOT" rev-parse "${tag_ref}^{commit}" 2>/dev/null) || return 1
	object_type=$(git -C "$REPO_ROOT" cat-file -t "$_VERSION_MANAGER_LOCAL_TAG_OBJECT" 2>/dev/null) || return 1
	if [[ "$object_type" != "tag" ]]; then
		print_error "Protected release recovery requires the original annotated tag object for ${tag_name}"
		return 1
	fi
	return 0
}

_version_manager_remote_tag_identity() {
	local tag_name="$1"
	local refs_output=""
	local object_id=""
	local ref_name=""
	local tag_ref="refs/tags/${tag_name}"

	_VERSION_MANAGER_REMOTE_TAG_OBJECT=""
	_VERSION_MANAGER_REMOTE_TAG_COMMIT=""
	_VERSION_MANAGER_REMOTE_TAG_STATE="$_VERSION_MANAGER_TAG_STATE_ABSENT"
	refs_output=$(git -C "$REPO_ROOT" ls-remote --tags origin \
		"$tag_ref" "${tag_ref}^{}" 2>/dev/null) || return 1
	while IFS=$'\t' read -r object_id ref_name; do
		case "$ref_name" in
		"$tag_ref") _VERSION_MANAGER_REMOTE_TAG_OBJECT="$object_id" ;;
		"${tag_ref}^{}") _VERSION_MANAGER_REMOTE_TAG_COMMIT="$object_id" ;;
		esac
	done <<<"$refs_output"
	if [[ -z "$_VERSION_MANAGER_REMOTE_TAG_OBJECT" ]]; then
		return 0
	fi
	_VERSION_MANAGER_REMOTE_TAG_STATE="present"
	[[ -n "$_VERSION_MANAGER_REMOTE_TAG_COMMIT" ]] ||
		_VERSION_MANAGER_REMOTE_TAG_COMMIT="$_VERSION_MANAGER_REMOTE_TAG_OBJECT"
	return 0
}

_version_manager_classify_remote_tag() {
	local tag_name="$1"

	_VERSION_MANAGER_REMOTE_TAG_STATE=""
	_version_manager_local_tag_identity "$tag_name" || return 1
	_version_manager_remote_tag_identity "$tag_name" || return 1
	if [[ "$_VERSION_MANAGER_REMOTE_TAG_STATE" == "$_VERSION_MANAGER_TAG_STATE_ABSENT" ]]; then
		return 0
	fi
	if [[ "$_VERSION_MANAGER_REMOTE_TAG_OBJECT" == "$_VERSION_MANAGER_LOCAL_TAG_OBJECT" &&
		"$_VERSION_MANAGER_REMOTE_TAG_COMMIT" == "$_VERSION_MANAGER_LOCAL_TAG_COMMIT" ]]; then
		_VERSION_MANAGER_REMOTE_TAG_STATE="$_VERSION_MANAGER_TAG_STATE_MATCHING"
		return 0
	fi
	_VERSION_MANAGER_REMOTE_TAG_STATE="mismatch"
	print_error "Remote ${tag_name} does not match the preserved local tag object"
	return 1
}

_version_manager_remote_branch_head() {
	local branch_name="$1"
	local branch_line=""
	local branch_sha=""
	local branch_ref=""

	_VERSION_MANAGER_PROTECTED_RELEASE_HEAD=""
	branch_line=$(git -C "$REPO_ROOT" ls-remote --heads origin "refs/heads/${branch_name}" 2>/dev/null) || return 1
	[[ -n "$branch_line" ]] || return 0
	IFS=$'\t' read -r branch_sha branch_ref <<<"$branch_line"
	[[ "$branch_ref" == "refs/heads/${branch_name}" && "$branch_sha" =~ ^[0-9a-f]{40}$ ]] || return 1
	_VERSION_MANAGER_PROTECTED_RELEASE_HEAD="$branch_sha"
	return 0
}

_version_manager_fetch_recovery_branch() {
	local branch_name="$1"

	if ! git -C "$REPO_ROOT" fetch origin \
		"refs/heads/${branch_name}:refs/remotes/origin/${branch_name}" --quiet; then
		return 1
	fi
	return 0
}

_version_manager_verify_recovery_head() {
	local recovery_head="$1"
	local release_commit="$2"
	local release_parent="$3"
	local current_main="$4"
	local parent_line=""
	local first_parent=""
	local second_parent=""
	local -a commit_and_parents=()

	[[ "$recovery_head" =~ ^[0-9a-f]{40}$ ]] || return 1
	if [[ "$recovery_head" == "$release_commit" ]]; then
		return 0
	fi
	parent_line=$(git -C "$REPO_ROOT" rev-list --parents -n 1 "$recovery_head" 2>/dev/null) || return 1
	read -r -a commit_and_parents <<<"$parent_line"
	if [[ "${#commit_and_parents[@]}" -ne 3 ]]; then
		print_error "Protected release recovery head contains commits outside the required merge topology"
		return 1
	fi
	first_parent="${commit_and_parents[1]}"
	second_parent="${commit_and_parents[2]}"
	if [[ "$second_parent" != "$release_commit" ]] ||
		! git -C "$REPO_ROOT" merge-base --is-ancestor "$release_parent" "$first_parent" ||
		! git -C "$REPO_ROOT" merge-base --is-ancestor "$first_parent" "$current_main"; then
		print_error "Protected release recovery head does not preserve the exact release/main parent topology"
		return 1
	fi
	return 0
}

_version_manager_find_protected_release_pr() {
	local repo="$1"
	local branch_name="$2"
	local owner="${repo%%/*}"
	local pulls_json=""

	_VERSION_MANAGER_PROTECTED_PR_JSON=""
	_VERSION_MANAGER_PROTECTED_PR_NUMBER=""
	pulls_json=$(gh api --method GET "repos/${repo}/pulls" \
		-f "head=${owner}:${branch_name}" -f state=all -F per_page=10 2>/dev/null) || return 1
	_VERSION_MANAGER_PROTECTED_PR_JSON=$(jq -c --arg branch "$branch_name" '
		[.[] | select(.head.ref == $branch and .base.ref == "main")]
		| sort_by(.number) | last // empty
	' <<<"$pulls_json") || return 1
	[[ -n "$_VERSION_MANAGER_PROTECTED_PR_JSON" ]] || return 0
	_VERSION_MANAGER_PROTECTED_PR_NUMBER=$(jq -er '.number' <<<"$_VERSION_MANAGER_PROTECTED_PR_JSON") || return 1
	return 0
}

_version_manager_verify_protected_pr_head() {
	local expected_head="$1"
	local actual_head=""
	local base_ref=""

	[[ -n "$_VERSION_MANAGER_PROTECTED_PR_JSON" ]] || return 1
	actual_head=$(jq -r '.head.sha // ""' <<<"$_VERSION_MANAGER_PROTECTED_PR_JSON") || return 1
	base_ref=$(jq -r '.base.ref // ""' <<<"$_VERSION_MANAGER_PROTECTED_PR_JSON") || return 1
	if [[ "$actual_head" != "$expected_head" || "$base_ref" != "main" ]]; then
		print_error "Protected release PR head/base does not match the preserved recovery branch"
		return 1
	fi
	return 0
}

_version_manager_verify_protected_pr_identity() {
	local repo="$1"
	local branch_name="$2"
	local version="$3"
	local tag_object="$4"
	local release_commit="$5"
	local head_repo=""
	local base_repo=""
	local author_association=""
	local body=""
	local provenance_marker=""

	[[ -n "$_VERSION_MANAGER_PROTECTED_PR_JSON" ]] || return 1
	head_repo=$(jq -r '.head.repo.full_name // ""' <<<"$_VERSION_MANAGER_PROTECTED_PR_JSON") || return 1
	base_repo=$(jq -r '.base.repo.full_name // ""' <<<"$_VERSION_MANAGER_PROTECTED_PR_JSON") || return 1
	author_association=$(jq -r '.author_association // ""' <<<"$_VERSION_MANAGER_PROTECTED_PR_JSON") || return 1
	body=$(jq -r '.body // ""' <<<"$_VERSION_MANAGER_PROTECTED_PR_JSON") || return 1
	if [[ "$head_repo" != "$repo" || "$base_repo" != "$repo" ||
		"$(jq -r '.head.ref // ""' <<<"$_VERSION_MANAGER_PROTECTED_PR_JSON")" != "$branch_name" ]]; then
		print_error "Protected release PR does not belong to the expected repository branch"
		return 1
	fi
	#aidevops:trust-boundary — exact-head auto-merge is allowed only for a
	# collaborator-authored same-repository PR carrying immutable provenance.
	case "$author_association" in
	OWNER | MEMBER | COLLABORATOR) ;;
	*)
		print_error "Protected release PR author is not a trusted repository collaborator"
		return 1
		;;
	esac
	provenance_marker="<!-- aidevops:release-provenance tag=v${version} tag-object=${tag_object} release-commit=${release_commit} merge-method=merge -->"
	case "$body" in
	*"$provenance_marker"*) ;;
	*)
		print_error "Protected release PR lacks matching immutable provenance metadata"
		return 1
		;;
	esac
	return 0
}

_version_manager_prepare_protected_release_head() {
	local version="$1"
	local release_commit="$2"
	local release_parent="$3"
	local branch_name="$4"
	local push_output=""

	git -C "$REPO_ROOT" fetch origin main --quiet || return 1
	if ! git -C "$REPO_ROOT" merge-base --is-ancestor "$release_parent" origin/main; then
		print_error "Protected release recovery refused rewritten main provenance"
		return 1
	fi

	_version_manager_remote_branch_head "$branch_name" || return 1
	if [[ -n "$_VERSION_MANAGER_PROTECTED_RELEASE_HEAD" ]]; then
		_version_manager_fetch_recovery_branch "$branch_name" || return 1
		if _version_manager_verify_recovery_head \
			"$_VERSION_MANAGER_PROTECTED_RELEASE_HEAD" "$release_commit" \
			"$release_parent" "$(git -C "$REPO_ROOT" rev-parse origin/main)"; then
			return 0
		fi
		print_error "Existing protected release branch has incompatible provenance"
		return 1
	fi

	if git -C "$REPO_ROOT" merge-base --is-ancestor "$release_commit" origin/main; then
		_VERSION_MANAGER_PROTECTED_RELEASE_RESULT="main-reachable"
		_VERSION_MANAGER_PROTECTED_RELEASE_HEAD=$(git -C "$REPO_ROOT" rev-parse origin/main) || return 1
		return 0
	fi

	if git -C "$REPO_ROOT" merge-base --is-ancestor origin/main "$release_commit"; then
		git -C "$REPO_ROOT" checkout --detach --quiet "$release_commit" || return 1
	else
		git -C "$REPO_ROOT" checkout --detach --quiet origin/main || return 1
		if ! git -C "$REPO_ROOT" -c commit.gpgsign=false merge --no-ff --no-edit \
			-m "chore(release): preserve signed v${version} commit" "$release_commit"; then
			git -C "$REPO_ROOT" merge --abort >/dev/null 2>&1 || true
			git -C "$REPO_ROOT" checkout --detach --quiet "$release_commit" || true
			print_error "Protected release commit conflicts with current origin/main"
			return 1
		fi
	fi

	_VERSION_MANAGER_PROTECTED_RELEASE_HEAD=$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null) || return 1
	if ! git -C "$REPO_ROOT" merge-base --is-ancestor "$release_commit" \
		"$_VERSION_MANAGER_PROTECTED_RELEASE_HEAD" ||
		! git -C "$REPO_ROOT" merge-base --is-ancestor origin/main \
			"$_VERSION_MANAGER_PROTECTED_RELEASE_HEAD"; then
		print_error "Protected release branch does not retain both required parents"
		return 1
	fi

	if push_output=$(git -C "$REPO_ROOT" push origin \
		"${_VERSION_MANAGER_PROTECTED_RELEASE_HEAD}:refs/heads/${branch_name}" 2>&1); then
		return 0
	fi
	# A concurrent creator may have won the branch race. Reuse only an exact,
	# provenance-preserving remote head; never force-update release recovery.
	_version_manager_remote_branch_head "$branch_name" || return 1
	if [[ -n "$_VERSION_MANAGER_PROTECTED_RELEASE_HEAD" ]]; then
		_version_manager_fetch_recovery_branch "$branch_name" || return 1
		if _version_manager_verify_recovery_head \
			"$_VERSION_MANAGER_PROTECTED_RELEASE_HEAD" "$release_commit" \
			"$release_parent" "$(git -C "$REPO_ROOT" rev-parse origin/main)"; then
			return 0
		fi
	fi
	print_error "Could not publish protected release recovery branch"
	[[ -z "$push_output" ]] || print_info "Git rejected the recovery branch push"
	return 1
}

_version_manager_write_protected_pr_body() {
	local body_file="$1"
	local repo="$2"
	local version="$3"
	local tag_object="$4"
	local release_commit="$5"
	local source_pr="${VERSION_MANAGER_SOURCE_PR:-}"
	local signature_helper="${AIDEVOPS_VERSION_MANAGER_SIGNATURE_HELPER:-${SCRIPT_DIR}/gh-signature-helper.sh}"

	{
		printf '## Summary\n\n'
		printf 'Route v%s through protected `main` without rebasing, amending, or recreating its signed release commit.\n\n' "$version"
		printf '## Immutable provenance\n\n'
		printf -- '- Release tag: `v%s`\n' "$version"
		printf -- '- Signed tag object: `%s`\n' "$tag_object"
		printf -- '- Release commit: `%s`\n' "$release_commit"
		printf -- '- Required merge method: merge commit (never squash or rebase)\n'
		if [[ "$source_pr" =~ ^[0-9]+$ ]]; then
			printf -- '- Source publication: Ref #%s\n' "$source_pr"
		fi
		printf '\nRequired checks and review gates remain authoritative. The final `v%s` ref must not be pushed until this exact release commit is reachable from `main`.\n\n' "$version"
		printf '<!-- aidevops:release-provenance tag=v%s tag-object=%s release-commit=%s merge-method=merge -->\n' \
			"$version" "$tag_object" "$release_commit"
	} >"$body_file" || return 1

	if [[ "$repo" == "marcusquinn/aidevops" ]]; then
		[[ -x "$signature_helper" ]] || return 1
		bash "$signature_helper" footer >>"$body_file" || return 1
	fi
	return 0
}

_version_manager_queue_exact_merge() {
	local repo="$1"
	local branch_name="$2"
	local expected_head="$3"
	local pr_number="$4"
	local version="$5"
	local tag_object="$6"
	local release_commit="$7"
	local merge_output=""
	local merge_rc=0
	local state=""
	local auto_merge=""
	local is_draft=""

	_version_manager_find_protected_release_pr "$repo" "$branch_name" || return 1
	_version_manager_verify_protected_pr_head "$expected_head" || return 1
	_version_manager_verify_protected_pr_identity "$repo" "$branch_name" "$version" \
		"$tag_object" "$release_commit" || return 1
	is_draft=$(jq -r '.draft // false' <<<"$_VERSION_MANAGER_PROTECTED_PR_JSON") || return 1
	if [[ "$is_draft" == "true" ]]; then
		gh pr ready "$pr_number" --repo "$repo" >/dev/null 2>&1 || return 1 # aidevops-allow: raw-gh-wrapper
	fi

	merge_output=$(gh pr merge "$pr_number" --repo "$repo" --auto --merge \
		--match-head-commit "$expected_head" 2>&1) || merge_rc=$? # aidevops-allow: raw-gh-wrapper
	if [[ "$merge_rc" -eq 0 ]]; then
		_VERSION_MANAGER_PROTECTED_RELEASE_RESULT="$_VERSION_MANAGER_RELEASE_RESULT_QUEUED"
		return 0
	fi

	_version_manager_find_protected_release_pr "$repo" "$branch_name" || return 1
	_version_manager_verify_protected_pr_head "$expected_head" || return 1
	state=$(jq -r '.state // ""' <<<"$_VERSION_MANAGER_PROTECTED_PR_JSON") || return 1
	auto_merge=$(jq -r 'if .auto_merge == null then "" else "configured" end' \
		<<<"$_VERSION_MANAGER_PROTECTED_PR_JSON") || return 1
	if [[ "$state" == "$_VERSION_MANAGER_PR_STATE_CLOSED" && "$(jq -r '.merged_at // ""' \
		<<<"$_VERSION_MANAGER_PROTECTED_PR_JSON")" != "" ]]; then
		_VERSION_MANAGER_PROTECTED_RELEASE_RESULT="merged"
		return 0
	fi
	if [[ "$auto_merge" == "configured" ]]; then
		_VERSION_MANAGER_PROTECTED_RELEASE_RESULT="$_VERSION_MANAGER_RELEASE_RESULT_QUEUED"
		return 0
	fi

	# Prevent generic squash automation from destroying ancestry when native
	# merge queueing is unavailable. Reconciliation retries the exact merge.
	if gh pr ready "$pr_number" --repo "$repo" --undo >/dev/null 2>&1; then # aidevops-allow: raw-gh-wrapper
		_VERSION_MANAGER_PROTECTED_RELEASE_RESULT="queued-draft"
		print_warning "Protected release PR #${pr_number} is preserved as a draft because exact merge queueing was unavailable"
		return 0
	fi
	print_error "Could not queue or safely hold protected release PR #${pr_number}"
	[[ -z "$merge_output" ]] || print_info "GitHub rejected the exact merge request"
	return 1
}

_version_manager_create_or_reuse_protected_pr() {
	local repo="$1"
	local version="$2"
	local branch_name="$3"
	local recovery_head="$4"
	local tag_object="$5"
	local release_commit="$6"
	local body_file=""
	local create_output=""
	local create_rc=0
	local origin_label="origin:interactive"
	local -a create_args=()

	_version_manager_find_protected_release_pr "$repo" "$branch_name" || return 1
	if [[ -z "$_VERSION_MANAGER_PROTECTED_PR_NUMBER" ]]; then
		body_file=$(mktemp) || return 1
		_version_manager_write_protected_pr_body "$body_file" "$repo" "$version" \
			"$tag_object" "$release_commit" || {
			rm -f "$body_file"
			return 1
		}
		create_args=(--repo "$repo" --head "$branch_name" --base main
			--title "chore(release): preserve signed v${version} publication"
			--body-file "$body_file")
		if [[ "$repo" == "marcusquinn/aidevops" ]]; then
			if declare -F _version_manager_is_headless_task_worker >/dev/null 2>&1 &&
				_version_manager_is_headless_task_worker; then
				origin_label="origin:worker"
			fi
			create_args+=(--label "$origin_label" --label "status:in-review" --label "release")
		fi
		create_output=$(gh pr create "${create_args[@]}" 2>&1) || create_rc=$? # aidevops-allow: raw-gh-wrapper
		rm -f "$body_file"
		_version_manager_find_protected_release_pr "$repo" "$branch_name" || return 1
		if [[ -z "$_VERSION_MANAGER_PROTECTED_PR_NUMBER" ]]; then
			print_error "Protected-main push was rejected and no recovery PR could be created"
			[[ "$create_rc" -eq 0 || -z "$create_output" ]] || print_info "GitHub rejected PR creation"
			return 1
		fi
	fi

	_version_manager_verify_protected_pr_head "$recovery_head" || return 1
	_VERSION_MANAGER_PROTECTED_PR_NUMBER=$(jq -er '.number' \
		<<<"$_VERSION_MANAGER_PROTECTED_PR_JSON") || return 1
	_version_manager_queue_exact_merge "$repo" "$branch_name" "$recovery_head" \
		"$_VERSION_MANAGER_PROTECTED_PR_NUMBER" "$version" "$tag_object" \
		"$release_commit" || return 1
	print_success "Protected release PR #${_VERSION_MANAGER_PROTECTED_PR_NUMBER} preserves v${version} provenance"
	print_info "Required checks and review gates remain enforced on exact head ${recovery_head}"
	return 0
}

_version_manager_publish_reachable_tag() {
	local tag_name="$1"
	local push_output=""
	local release_tree=""
	local main_tree=""

	_VERSION_MANAGER_PROTECTED_RELEASE_RESULT=""
	_version_manager_classify_remote_tag "$tag_name" || return 1
	case "$_VERSION_MANAGER_REMOTE_TAG_STATE" in
	matching)
		_VERSION_MANAGER_PROTECTED_RELEASE_RESULT="remote-tag-present"
		return 0
		;;
	absent) ;;
	*) return 1 ;;
	esac
	git -C "$REPO_ROOT" fetch origin main --quiet || return 1
	if ! git -C "$REPO_ROOT" merge-base --is-ancestor \
		"$_VERSION_MANAGER_LOCAL_TAG_COMMIT" origin/main; then
		_VERSION_MANAGER_PROTECTED_RELEASE_RESULT="not-reachable"
		return 0
	fi
	release_tree=$(git -C "$REPO_ROOT" rev-parse "${_VERSION_MANAGER_LOCAL_TAG_COMMIT}^{tree}" 2>/dev/null) || return 1
	main_tree=$(git -C "$REPO_ROOT" rev-parse "origin/main^{tree}" 2>/dev/null) || return 1
	if [[ "$release_tree" != "$main_tree" ]]; then
		_VERSION_MANAGER_PROTECTED_RELEASE_RESULT="aggregation-required"
		print_error "Refusing to publish ${tag_name}: protected main has a different tree from the signed release commit"
		print_info "Create a newly reviewed exact-tip aggregation release; no tag or package channel was mutated"
		return 1
	fi
	if ! push_output=$(git -C "$REPO_ROOT" push origin \
		"refs/tags/${tag_name}:refs/tags/${tag_name}" 2>&1); then
		print_error "Failed to publish preserved ${tag_name} after main became reachable"
		[[ -z "$push_output" ]] || print_info "Git rejected the exact tag push"
		return 1
	fi
	_version_manager_classify_remote_tag "$tag_name" || return 1
	[[ "$_VERSION_MANAGER_REMOTE_TAG_STATE" == "$_VERSION_MANAGER_TAG_STATE_MATCHING" ]] || return 1
	_VERSION_MANAGER_PROTECTED_RELEASE_RESULT="tag-pushed"
	return 0
}

_version_manager_queue_protected_main_release() {
	local version="$1"
	local tag_name="v${version}"
	local repo=""
	local release_commit=""
	local release_parent=""
	local tag_object=""
	local branch_name=""

	_VERSION_MANAGER_PROTECTED_RELEASE_RESULT=""
	_VERSION_MANAGER_PROTECTED_PR_NUMBER=""
	_VERSION_MANAGER_PROTECTED_RELEASE_BRANCH=""
	VERSION_MANAGER_PRESERVE_RELEASE_STATE=1
	export VERSION_MANAGER_PRESERVE_RELEASE_STATE
	repo=$(_version_manager_protected_repo_slug) || {
		print_error "Cannot resolve repository for protected-main release recovery"
		return 1
	}
	_version_manager_local_tag_identity "$tag_name" || return 1
	tag_object="$_VERSION_MANAGER_LOCAL_TAG_OBJECT"
	release_commit="$_VERSION_MANAGER_LOCAL_TAG_COMMIT"
	release_parent=$(git -C "$REPO_ROOT" rev-parse "${release_commit}^" 2>/dev/null) || return 1
	branch_name=$(_version_manager_protected_release_branch_name "$version") || return 1
	_VERSION_MANAGER_PROTECTED_RELEASE_BRANCH="$branch_name"

	_version_manager_prepare_protected_release_head "$version" "$release_commit" \
		"$release_parent" "$branch_name" || return 1
	_version_manager_local_tag_identity "$tag_name" || return 1
	if [[ "$_VERSION_MANAGER_LOCAL_TAG_OBJECT" != "$tag_object" ||
		"$_VERSION_MANAGER_LOCAL_TAG_COMMIT" != "$release_commit" ]]; then
		print_error "Protected release recovery changed immutable tag provenance"
		return 1
	fi

	if [[ "$_VERSION_MANAGER_PROTECTED_RELEASE_RESULT" == "main-reachable" ]]; then
		_version_manager_publish_reachable_tag "$tag_name" || return 1
		return 0
	fi
	_version_manager_create_or_reuse_protected_pr "$repo" "$version" "$branch_name" \
		"$_VERSION_MANAGER_PROTECTED_RELEASE_HEAD" "$tag_object" "$release_commit" || return 1
	_VERSION_MANAGER_PROTECTED_RELEASE_RESULT="$_VERSION_MANAGER_RELEASE_RESULT_QUEUED"
	return 0
}

_version_manager_verify_protected_pr_state() {
	local pr_state="$1"
	local merged_at="$2"

	case "$pr_state" in
	"$_VERSION_MANAGER_PR_STATE_OPEN") [[ -z "$merged_at" ]] || return 1 ;;
	"$_VERSION_MANAGER_PR_STATE_CLOSED")
		if [[ ! "$merged_at" =~ $_VERSION_MANAGER_TIMESTAMP_REGEX ]]; then
			print_error "Protected release PR #${_VERSION_MANAGER_PROTECTED_PR_NUMBER} lacks valid merge evidence"
			return 1
		fi
		;;
	*) return 1 ;;
	esac
	return 0
}

_version_manager_reconcile_protected_release_tag() {
	local repo="$1"
	local tag_name="$2"
	local mode="$3"
	local version="${tag_name#v}"
	local branch_name=""
	local pr_state=""
	local merged_at=""
	local pr_head=""
	local remote_branch_head=""
	local release_parent=""
	local current_main=""

	_VERSION_MANAGER_PROTECTED_RELEASE_RESULT=""
	[[ "$mode" == "status" || "$mode" == "$_VERSION_MANAGER_MODE_RECONCILE" ]] || return 1
	_version_manager_classify_remote_tag "$tag_name" || return 1
	if [[ "$_VERSION_MANAGER_REMOTE_TAG_STATE" == "$_VERSION_MANAGER_TAG_STATE_MATCHING" ]]; then
		_VERSION_MANAGER_PROTECTED_RELEASE_RESULT="remote-tag-present"
		return 0
	fi
	[[ "$_VERSION_MANAGER_REMOTE_TAG_STATE" == "$_VERSION_MANAGER_TAG_STATE_ABSENT" ]] || return 1

	git -C "$REPO_ROOT" fetch origin main --quiet || return 1
	release_parent=$(git -C "$REPO_ROOT" rev-parse \
		"${_VERSION_MANAGER_LOCAL_TAG_COMMIT}^" 2>/dev/null) || return 1
	current_main=$(git -C "$REPO_ROOT" rev-parse origin/main 2>/dev/null) || return 1
	branch_name=$(_version_manager_protected_release_branch_name "$version") || return 1
	_version_manager_find_protected_release_pr "$repo" "$branch_name" || return 1
	if [[ -z "$_VERSION_MANAGER_PROTECTED_PR_NUMBER" ]]; then
		print_error "No protected release PR exists for preserved ${tag_name}"
		return 1
	fi
	pr_head=$(jq -r '.head.sha // ""' <<<"$_VERSION_MANAGER_PROTECTED_PR_JSON") || return 1
	_version_manager_verify_protected_pr_head "$pr_head" || return 1
	_version_manager_verify_protected_pr_identity "$repo" "$branch_name" "$version" \
		"$_VERSION_MANAGER_LOCAL_TAG_OBJECT" "$_VERSION_MANAGER_LOCAL_TAG_COMMIT" || return 1
	pr_state=$(jq -r '.state // ""' <<<"$_VERSION_MANAGER_PROTECTED_PR_JSON") || return 1
	merged_at=$(jq -r '.merged_at // ""' <<<"$_VERSION_MANAGER_PROTECTED_PR_JSON") || return 1
	_version_manager_verify_protected_pr_state "$pr_state" "$merged_at" || return 1
	_version_manager_remote_branch_head "$branch_name" || return 1
	remote_branch_head="$_VERSION_MANAGER_PROTECTED_RELEASE_HEAD"
	if [[ -n "$remote_branch_head" && "$remote_branch_head" != "$pr_head" ]]; then
		print_error "Protected release PR head no longer matches its remote branch"
		return 1
	fi
	if [[ -n "$remote_branch_head" ]]; then
		_version_manager_fetch_recovery_branch "$branch_name" || return 1
	elif [[ "$pr_state" == "$_VERSION_MANAGER_PR_STATE_OPEN" ]]; then
		print_error "Open protected release PR head no longer has its remote branch"
		return 1
	elif ! git -C "$REPO_ROOT" cat-file -e "${pr_head}^{commit}" 2>/dev/null; then
		print_error "Merged protected release PR head is unavailable for verification"
		return 1
	fi
	_version_manager_verify_recovery_head "$pr_head" \
		"$_VERSION_MANAGER_LOCAL_TAG_COMMIT" "$release_parent" "$current_main" || return 1
	if ! git -C "$REPO_ROOT" merge-base --is-ancestor \
		"$_VERSION_MANAGER_LOCAL_TAG_COMMIT" "$pr_head"; then
		print_error "Protected release PR does not contain the signed release commit"
		return 1
	fi
	if [[ "$pr_state" == "$_VERSION_MANAGER_PR_STATE_CLOSED" ]]; then
		git -C "$REPO_ROOT" fetch origin main --quiet || return 1
		if ! git -C "$REPO_ROOT" merge-base --is-ancestor \
			"$_VERSION_MANAGER_LOCAL_TAG_COMMIT" origin/main; then
			print_error "Merged protected release PR did not preserve release ancestry"
			return 1
		fi
		if ! git -C "$REPO_ROOT" merge-base --is-ancestor "$pr_head" origin/main; then
			print_error "Merged protected release PR head is not reachable from main"
			return 1
		fi
		if [[ "$mode" == "$_VERSION_MANAGER_MODE_RECONCILE" ]]; then
			_version_manager_publish_reachable_tag "$tag_name" || return 1
			printf 'release:queued tag=%s correlation=%s\n' \
				"$tag_name" "$_VERSION_MANAGER_LOCAL_TAG_COMMIT"
		else
			_VERSION_MANAGER_PROTECTED_RELEASE_RESULT="tag-ready"
		fi
		return 0
	fi
	if [[ "$mode" == "$_VERSION_MANAGER_MODE_RECONCILE" ]]; then
		_version_manager_queue_exact_merge "$repo" "$branch_name" "$pr_head" \
			"$_VERSION_MANAGER_PROTECTED_PR_NUMBER" "$version" \
			"$_VERSION_MANAGER_LOCAL_TAG_OBJECT" \
			"$_VERSION_MANAGER_LOCAL_TAG_COMMIT" || return 1
	fi
	_VERSION_MANAGER_PROTECTED_RELEASE_RESULT="pr-pending"
	printf 'release:queued pr=%s tag=%s head=%s\n' \
		"$_VERSION_MANAGER_PROTECTED_PR_NUMBER" "$tag_name" "$pr_head"
	return 0
}

_version_manager_verify_protected_release_supersession() {
	local repo="$1"
	local source_tag="$2"
	local successor_commit="$3"
	local source_tag_object=""
	local source_commit=""
	local protected_pr=""
	local protected_head=""
	local protected_merged_at=""

	_VERSION_MANAGER_PROTECTED_SUPERSESSION_JSON=""
	[[ "$successor_commit" =~ ^[0-9a-f]{40}$ ]] || return 1
	_version_manager_reconcile_protected_release_tag "$repo" "$source_tag" status \
		>/dev/null || return 1
	[[ "$_VERSION_MANAGER_PROTECTED_RELEASE_RESULT" == "tag-ready" ]] || return 1

	source_tag_object="$_VERSION_MANAGER_LOCAL_TAG_OBJECT"
	source_commit="$_VERSION_MANAGER_LOCAL_TAG_COMMIT"
	protected_pr="$_VERSION_MANAGER_PROTECTED_PR_NUMBER"
	protected_head=$(jq -r '.head.sha // ""' \
		<<<"$_VERSION_MANAGER_PROTECTED_PR_JSON") || return 1
	protected_merged_at=$(jq -r '.merged_at // ""' \
		<<<"$_VERSION_MANAGER_PROTECTED_PR_JSON") || return 1
	[[ "$source_tag_object" =~ ^[0-9a-f]{40}$ && "$source_commit" =~ ^[0-9a-f]{40}$ ]] || return 1
	[[ "$protected_pr" =~ ^[0-9]+$ && "$protected_head" =~ ^[0-9a-f]{40}$ ]] || return 1
	[[ "$protected_merged_at" =~ $_VERSION_MANAGER_TIMESTAMP_REGEX ]] || return 1
	git -C "$REPO_ROOT" merge-base --is-ancestor "$source_commit" "$successor_commit" || return 1
	git -C "$REPO_ROOT" merge-base --is-ancestor "$protected_head" "$successor_commit" || return 1

	_VERSION_MANAGER_PROTECTED_SUPERSESSION_JSON=$(jq -cn \
		--arg source_tag "$source_tag" --arg source_tag_object "$source_tag_object" \
		--arg source_commit "$source_commit" --argjson protected_pr "$protected_pr" \
		--arg protected_head "$protected_head" --arg protected_merged_at "$protected_merged_at" \
		'{source_tag:$source_tag,source_tag_object:$source_tag_object,
		  source_commit:$source_commit,protected_pr:$protected_pr,
		  protected_head:$protected_head,protected_merged_at:$protected_merged_at}') || return 1
	return 0
}

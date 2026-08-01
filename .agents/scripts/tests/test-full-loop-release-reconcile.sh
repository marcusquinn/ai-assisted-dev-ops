#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Durable release reconciliation regression tests.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
REPO_ROOT="${SCRIPT_DIR}/../.."
_FULL_LOOP_SHA40_REGEX='^[0-9a-f]{40}$'
_FULL_LOOP_PHASE_FAILED="failed"
_FULL_LOOP_RELEASE_PUBLISHED="published"
_FULL_LOOP_RELEASE_SUPERSEDED="superseded"
_FULL_LOOP_RELEASE_NOT_REQUESTED="not-requested"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
mkdir -p "${TEST_ROOT}/bin" "${TEST_ROOT}/receipts"

# shellcheck source=../full-loop-release-reconcile.sh
source "${SCRIPT_DIR}/full-loop-release-reconcile.sh"

stale_publication_jobs_fixture() {
	local mode="${1:-valid}"
	local jobs_json=""
	jobs_json=$(jq -cn '
		{total_count:1,jobs:[{id:101,name:"Publish GitHub, npm, and Homebrew",
		status:"completed",conclusion:"failure",steps:[
		{name:"Set up job",number:1,status:"completed",conclusion:"success"},
		{name:"Checkout verified tag",number:2,status:"completed",conclusion:"success"},
		{name:"Verify immutable release provenance",number:3,status:"completed",conclusion:"success"},
		{name:"Create or reconcile GitHub release",number:4,status:"completed",conclusion:"success"},
		{name:"Publish to npm",number:5,status:"completed",conclusion:"skipped"},
		{name:"Verify npm publication",number:6,status:"completed",conclusion:"success"},
		{name:"Push to Homebrew tap",number:7,status:"completed",conclusion:"skipped"},
		{name:"Verify Homebrew tap",number:8,status:"completed",conclusion:"success"},
		{name:"Queue exact-tag postflight",number:9,status:"completed",conclusion:"failure"},
		{name:"Publication summary",number:10,status:"completed",conclusion:"skipped"}
		]}]}
	') || return 1
	case "$mode" in
	valid) ;;
	queue-success) jobs_json=$(jq '.jobs[0].steps[8].conclusion = "success"' <<<"$jobs_json") || return 1 ;;
	duplicate-npm) jobs_json=$(jq '.jobs[0].steps += [.jobs[0].steps[5]]' <<<"$jobs_json") || return 1 ;;
	extra-failure) jobs_json=$(jq '.jobs[0].steps[3].conclusion = "failure"' <<<"$jobs_json") || return 1 ;;
	nonterminal) jobs_json=$(jq '.jobs[0].steps[8].status = "in_progress"' <<<"$jobs_json") || return 1 ;;
	reordered-postflight) jobs_json=$(jq '.jobs[0].steps[3].number = 9 | .jobs[0].steps[8].number = 4' <<<"$jobs_json") || return 1 ;;
	*) return 1 ;;
	esac
	printf '%s\n' "$jobs_json"
	return 0
}

valid_stale_jobs=$(stale_publication_jobs_fixture valid)
_full_loop_release_run_jobs_payload_valid "$valid_stale_jobs" || {
	printf 'FAIL valid workflow jobs payload was rejected\n'
	exit 1
}
_full_loop_release_stale_publication_jobs_valid "$valid_stale_jobs" || {
	printf 'FAIL exact post-publication dispatch failure evidence was rejected\n'
	exit 1
}
for invalid_jobs_mode in queue-success duplicate-npm extra-failure nonterminal reordered-postflight; do
	if _full_loop_release_stale_publication_jobs_valid \
		"$(stale_publication_jobs_fixture "$invalid_jobs_mode")"; then
		printf 'FAIL %s stale publication job evidence was accepted\n' "$invalid_jobs_mode"
		exit 1
	fi
done
if _full_loop_release_run_jobs_payload_valid \
	"$(jq '.total_count = 2' <<<"$valid_stale_jobs")"; then
	printf 'FAIL truncated workflow jobs payload was accepted\n'
	exit 1
fi
printf 'PASS stale publication proof requires exact successful channels and sole postflight failure\n'

_full_loop_release_tag_body() {
	local tag_name="$1"
	[[ "$tag_name" == "v1.2.3" ]] || return 1
	cat <<'BODY'
Release v1.2.3

Aidevops-Version: 1.2.3
Aidevops-Source-PR: 90
Aidevops-Source-Merge: 1111111111111111111111111111111111111111
Aidevops-Aggregated-Source: 89@2222222222222222222222222222222222222222
BODY
	return 0
}

source_json=$(_full_loop_release_source_json_from_tag v1.2.3)
if ! jq -e '.source_pr == 90
	and .source_merge == "1111111111111111111111111111111111111111"
	and .aggregated_sources == [{"pr":89,"merge":"2222222222222222222222222222222222222222"}]' \
	<<<"$source_json" >/dev/null; then
	printf 'FAIL signed tag trailers did not reconstruct release provenance\n'
	exit 1
fi
printf 'PASS signed tag trailers reconstruct release provenance\n'

(
	export AIDEVOPS_FULL_LOOP_RECEIPT_DIR="${TEST_ROOT}/gap-receipts"
	# shellcheck source=../full-loop-helper-state.sh
	source "${SCRIPT_DIR}/full-loop-helper-state.sh"
	gap_expected='28993@23667f1e351981e4e6ecfeb03dd4c7a52ecfd100,29006@da5fec68b034be737bbf1f8d7ccf05a8dbf64a10,29010@4745adde8faa4a92aa4e27763c52e2c1a02a5e76,29013@de9e0b1b76f8dbeb97ccb8d2c3d57020b41adbd0'
	gap_observed='29010@4745adde8faa4a92aa4e27763c52e2c1a02a5e76'
	gap_tag_object='1901024bf5b675e4c6b680a801ea402b75f1f355'
	gap_release_commit='0050022840d6ab7df25608a8a16e50b54e12efec'
	gap_reason='published tag omitted explicitly authorized sources'
	_full_loop_release_verify_tag_provenance() {
		local repo="$1"
		local tag_name="$2"
		[[ "$repo" == "test/repo" && "$tag_name" == "v3.32.200" ]]
		return $?
	}
	_full_loop_release_resolve_tag_expected_sources() {
		local repo="$1"
		local requested_pr="$2"
		local tag_name="$3"
		local expected_sources="$4"
		[[ "$repo" == "test/repo" && "$requested_pr" == "29010" && "$tag_name" == "v3.32.200" ]] || return 1
		[[ "$expected_sources" == "$gap_expected" ]] || return 1
		printf '%s\n' "$gap_expected"
		return 0
	}
	_full_loop_release_observed_sources_for_expected() {
		local tag_name="$1"
		local expected_sources="$2"
		[[ "$tag_name" == "v3.32.200" && "$expected_sources" == "$gap_expected" ]] || return 1
		printf '%s\n' "$gap_observed"
		return 0
	}
	git() {
		local args="$*"
		case "$args" in
		*" fetch origin --tags --quiet") return 0 ;;
		*" rev-parse refs/tags/v3.32.200^{commit}") printf '%s\n' "$gap_release_commit" ;;
		*" rev-parse refs/tags/v3.32.200") printf '%s\n' "$gap_tag_object" ;;
		*) return 1 ;;
		esac
		return 0
	}
	_full_loop_release_record_authorization_gap test/repo 29010 v3.32.200 "$gap_expected" "$gap_reason" >/dev/null
	gap_path=$(_full_loop_release_evidence_path test/repo 29010 authorization-gap)
	jq -e --arg tag_object "$gap_tag_object" --arg release_commit "$gap_release_commit" '
		.status == "authorization-gap"
		and (.expected_sources | length) == 4
		and (.observed_sources | length) == 1
		and .tag_object == $tag_object
		and .release_commit == $release_commit
		and .terminal_cleanup_evidence == false
	' "$gap_path" >/dev/null
	cp "$gap_path" "${TEST_ROOT}/gap-evidence-original.json"
	_full_loop_release_record_authorization_gap test/repo 29010 v3.32.200 "$gap_expected" "$gap_reason" >/dev/null
	cmp -s "$gap_path" "${TEST_ROOT}/gap-evidence-original.json"
	if _full_loop_release_record_authorization_gap test/repo 29010 v3.32.200 "$gap_expected" \
		'conflicting incident classification' >/dev/null 2>&1; then
		printf 'FAIL conflicting authorization-gap replay replaced immutable incident evidence\n'
		exit 1
	fi
	cmp -s "$gap_path" "${TEST_ROOT}/gap-evidence-original.json"
	[[ ! -f "${AIDEVOPS_FULL_LOOP_RECEIPT_DIR}/test_repo-29010.status" ]]
)
printf 'PASS historical authorization gaps use idempotent detached production evidence\n'

legacy_source_json_file="${TEST_ROOT}/legacy-source.json"
(
	_full_loop_release_tag_body() {
		local tag_name="$1"
		[[ "$tag_name" == "v1.2.4" ]] || return 1
		printf '%s\n' \
			'Release v1.2.4' \
			'' \
			'Aidevops-Version: 1.2.4' \
			'Aidevops-Source-PR: 90' \
			'Aidevops-Source-Merge: 1111111111111111111111111111111111111111'
		return 0
	}
	_full_loop_release_source_merge_trailer_values() {
		local source_merge="$1"
		local trailer_key="$2"
		[[ "$source_merge" == "1111111111111111111111111111111111111111" ]] || return 1
		case "$trailer_key" in
		Aidevops-Release-Aggregator-PR) printf '90\n' ;;
		Aidevops-Release-Aggregates) printf '89@2222222222222222222222222222222222222222\n' ;;
		*) return 1 ;;
		esac
		return 0
	}
	_full_loop_release_source_json_from_tag v1.2.4
) >"$legacy_source_json_file"
legacy_source_json=$(<"$legacy_source_json_file")
if ! jq -e '.source_pr == 90
	and .source_merge == "1111111111111111111111111111111111111111"
	and .aggregated_sources == [{"pr":89,"merge":"2222222222222222222222222222222222222222"}]' \
	<<<"$legacy_source_json" >/dev/null; then
	printf 'FAIL signed source merge did not reconstruct an omitted aggregate list\n'
	exit 1
fi
printf 'PASS signed source merge reconstructs an omitted redundant tag manifest\n'

legacy_found_tag_file="${TEST_ROOT}/legacy-found-tag.txt"
(
	git() {
		local args="$*"
		case "$args" in
		*" fetch origin --tags --quiet"*) return 0 ;;
		*" for-each-ref "*)
			printf 'v1.2.4\x1f90\x1f1111111111111111111111111111111111111111\x1f\n'
			;;
		*" log --all --fixed-strings "*)
			printf '1111111111111111111111111111111111111111\n'
			;;
		*) return 1 ;;
		esac
		return 0
	}
	_full_loop_release_tag_body() {
		local tag_name="$1"
		[[ "$tag_name" == "v1.2.4" ]] || return 1
		printf '%s\n' \
			'Release v1.2.4' \
			'Aidevops-Version: 1.2.4' \
			'Aidevops-Source-PR: 90' \
			'Aidevops-Source-Merge: 1111111111111111111111111111111111111111'
		return 0
	}
	_full_loop_release_source_merge_trailer_values() {
		local source_merge="$1"
		local trailer_key="$2"
		[[ "$source_merge" == "1111111111111111111111111111111111111111" ]] || return 1
		case "$trailer_key" in
		Aidevops-Release-Aggregator-PR) printf '90\n' ;;
		Aidevops-Release-Aggregates) printf '89@2222222222222222222222222222222222222222\n' ;;
		*) return 1 ;;
		esac
		return 0
	}
	_full_loop_release_verify_tag_provenance() {
		local repo="$1"
		local tag_name="$2"
		[[ "$repo" == "test/repo" && "$tag_name" == "v1.2.4" ]]
		return $?
	}
	_full_loop_release_find_tag_for_pr test/repo 89 || exit 1
	printf '%s\n' "$_FULL_LOOP_RELEASE_FOUND_TAG"
) >"$legacy_found_tag_file"
legacy_found_tag=$(<"$legacy_found_tag_file")
if [[ "$legacy_found_tag" != "v1.2.4" ]]; then
	printf 'FAIL included source PR could not discover its transitively bound tag\n'
	exit 1
fi
printf 'PASS included source PR discovers its transitively bound release tag\n'

candidate_tags_file="${TEST_ROOT}/candidate-tags.txt"
(
	git() {
		local args="$*"
		case "$args" in
		*" for-each-ref "*)
			printf '%b\n' \
				'v2.0.0\x1f890\x1faaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\x1f' \
				'v1.9.0\x1f89\x1fbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\x1f' \
				'v1.8.0\x1f90\x1fcccccccccccccccccccccccccccccccccccccccc\x1f890@dddddddddddddddddddddddddddddddddddddddd' \
				'v1.7.0\x1f90\x1feeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee\x1f89@ffffffffffffffffffffffffffffffffffffffff'
			;;
		*" log --all --fixed-strings "*) return 0 ;;
		*) return 1 ;;
		esac
		return 0
	}
	_full_loop_release_candidate_tags_for_pr 89
) >"$candidate_tags_file"
candidate_tags=$(<"$candidate_tags_file")
if [[ "$candidate_tags" != $'v1.9.0\nv1.7.0' ]]; then
	printf 'FAIL one-pass trailer index did not preserve exact newest-first candidates\n'
	exit 1
fi
printf 'PASS one-pass trailer index preserves exact newest-first candidates\n'

if (
	git() {
		local args="$*"
		case "$args" in
		*" for-each-ref "*) return 1 ;;
		*" log --all --fixed-strings "*) return 0 ;;
		esac
		return 1
	}
	_full_loop_release_candidate_tags_for_pr 89
); then
	printf 'FAIL tag enumeration failure was treated as an empty candidate set\n'
	exit 1
fi
printf 'PASS tag enumeration failure remains fail closed\n'

if (
	git() {
		local args="$*"
		case "$args" in
		*" fetch origin --tags --quiet"*) return 0 ;;
		*" for-each-ref "*)
			printf 'v1.2.5\x1f90\x1f1111111111111111111111111111111111111111\x1f89@2222222222222222222222222222222222222222\n'
			;;
		*" log --all --fixed-strings "*) return 0 ;;
		*) return 1 ;;
		esac
		return 0
	}
	_full_loop_release_tag_body() {
		local tag_name="$1"
		[[ "$tag_name" == "v1.2.5" ]] || return 1
		printf '%s\n' 'Aidevops-Aggregated-Source: 89@2222222222222222222222222222222222222222'
		return 0
	}
	_full_loop_release_source_json_from_tag() {
		local tag_name="$1"
		[[ "$tag_name" == "v1.2.5" ]] || return 1
		printf '%s\n' '{"source_pr":90,"source_merge":"1111111111111111111111111111111111111111","aggregated_sources":[]}'
		return 0
	}
	_full_loop_release_find_tag_for_pr test/repo 89
); then
	printf 'FAIL textual and reconstructed provenance disagreement was accepted\n'
	exit 1
fi
printf 'PASS textual and reconstructed provenance disagreement remains fail closed\n'

mkdir -p "${TEST_ROOT}/worktrees" "${TEST_ROOT}/tag-checkout" \
	"${TEST_ROOT}/runtime" "${TEST_ROOT}/tag-checkout/.agents/scripts"
export AIDEVOPS_WORKTREE_BASE_DIR="${TEST_ROOT}/worktrees"
PREPARE_GIT_LOG="${TEST_ROOT}/prepare-git.log"
export PREPARE_GIT_LOG
_FULL_LOOP_RELEASE_PATH="${TEST_ROOT}/tag-checkout"
git() {
	local args="$*"
	case "$args" in
	*" rev-parse refs/tags/v1.2.3^{commit}" | *" rev-parse HEAD")
		printf '%s\n' '3333333333333333333333333333333333333333'
		return 0
		;;
	*" worktree add "*)
		printf '%s\n' "$args" >>"$PREPARE_GIT_LOG"
		return 1
		;;
	esac
	return 1
}
if ! _full_loop_release_prepare_tag_worktree v1.2.3 || [[ -e "$PREPARE_GIT_LOG" ]]; then
	printf 'FAIL exact detached tag checkout was not reused safely\n'
	exit 1
fi
unset -f git
printf 'PASS exact detached tag checkout is reused across discovery and finalization\n'

FAKE_VERIFY_LOG="${TEST_ROOT}/verify.log"
FAKE_POST_RELEASE_LOG="${TEST_ROOT}/post-release.log"
FAKE_PERSIST_LOG="${TEST_ROOT}/persist.log"
FAKE_OLD_RUNTIME_LOG="${TEST_ROOT}/old-runtime.log"
export FAKE_VERIFY_LOG FAKE_POST_RELEASE_LOG FAKE_PERSIST_LOG FAKE_OLD_RUNTIME_LOG
cat >"${TEST_ROOT}/runtime/release-provenance-helper.sh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$PWD" >"${FAKE_VERIFY_LOG:?}"
printf '%s\n' "$*" >>"${FAKE_VERIFY_LOG:?}"
STUB
cat >"${TEST_ROOT}/runtime/version-manager.sh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf 'cwd=%s\naction=%s\nsync_root=%s\ndeploy_helper=%s\n' \
	"$PWD" "$*" "${AIDEVOPS_SYNC_REPO_ROOT:-}" \
	"${AIDEVOPS_SYNC_DEPLOY_SCRIPT:-}" >"${FAKE_POST_RELEASE_LOG:?}"
STUB
cat >"${TEST_ROOT}/tag-checkout/.agents/scripts/version-manager.sh" <<'STUB'
#!/usr/bin/env bash
printf 'obsolete tag runtime invoked\n' >"${FAKE_OLD_RUNTIME_LOG:?}"
exit 1
STUB
printf '#!/usr/bin/env bash\nexit 0\n' \
	>"${TEST_ROOT}/runtime/deploy-agents-on-merge.sh"
chmod +x "${TEST_ROOT}/runtime/release-provenance-helper.sh" \
	"${TEST_ROOT}/runtime/version-manager.sh" \
	"${TEST_ROOT}/runtime/deploy-agents-on-merge.sh" \
	"${TEST_ROOT}/tag-checkout/.agents/scripts/version-manager.sh"

saved_script_dir="$SCRIPT_DIR"
SCRIPT_DIR="${TEST_ROOT}/runtime"
_full_loop_release_prepare_tag_worktree() {
	local tag_name="$1"
	[[ "$tag_name" == "v1.2.3" ]] || return 1
	_FULL_LOOP_RELEASE_PATH="${TEST_ROOT}/tag-checkout"
	return 0
}
if ! _full_loop_release_verify_tag_provenance test/repo v1.2.3 ||
	! grep -qx "${TEST_ROOT}/tag-checkout" "$FAKE_VERIFY_LOG" ||
	! grep -qx 'verify --tag v1.2.3 --repo test/repo' "$FAKE_VERIFY_LOG"; then
	printf 'FAIL release provenance was not verified from the detached tag checkout\n'
	exit 1
fi
printf 'PASS release provenance verification runs from the detached tag checkout\n'

_full_loop_validate_release_candidates() {
	local repo="$1"
	local source_json="$2"
	[[ -n "$repo" && -n "$source_json" ]]
	return $?
}
_full_loop_persist_release_success() {
	local repo="$1"
	local release_path="$2"
	local source_json="$3"
	local source_pr="$4"
	local source_merge="$5"
	printf '%s|%s|%s|%s|%s\n' \
		"$repo" "$release_path" "$source_json" "$source_pr" "$source_merge" \
		>"$FAKE_PERSIST_LOG"
	return 0
}
if ! _full_loop_release_finalize_reconciliation test/repo 90 v1.2.3 ||
	! grep -qx "cwd=${TEST_ROOT}/tag-checkout" "$FAKE_POST_RELEASE_LOG" ||
	! grep -qx 'action=post-release' "$FAKE_POST_RELEASE_LOG" ||
	! grep -qx "sync_root=${TEST_ROOT}/tag-checkout" "$FAKE_POST_RELEASE_LOG" ||
	! grep -qx "deploy_helper=${TEST_ROOT}/runtime/deploy-agents-on-merge.sh" \
		"$FAKE_POST_RELEASE_LOG" ||
	[[ -e "$FAKE_OLD_RUNTIME_LOG" || ! -s "$FAKE_PERSIST_LOG" ]]; then
	printf 'FAIL reconciliation did not finalize with current hardened runtime against the tag checkout\n'
	exit 1
fi
SCRIPT_DIR="$saved_script_dir"
_FULL_LOOP_RELEASE_PATH=""
printf 'PASS reconciliation uses current hardened runtime against immutable tag content\n'

cat >"${TEST_ROOT}/bin/gh" <<'STUB'
#!/usr/bin/env bash
args=" $* "
case "${FAKE_RUN_SCHEMA_MODE:-valid}" in
api-failure) exit 1 ;;
empty) exit 0 ;;
object)
	printf '%s\n' '{}'
	exit 0
	;;
malformed)
	printf '%s\n' '{'
	exit 0
	;;
malformed-run)
	printf '%s\n' '{"workflow_runs":[{"id":11,"event":"workflow_dispatch","head_branch":"main","head_sha":"4444444444444444444444444444444444444444","conclusion":null,"created_at":"2026-07-27T00:01:00Z","display_title":"Publish v1.2.3 [3333333333333333333333333333333333333333.4444444444444444444444444444444444444444]"}]}'
	exit 0
	;;
no-runs)
	printf '%s\n' '{"workflow_runs":[]}'
	exit 0
	;;
esac
if [[ "$args" == *" workflow run publish-packages.yml "* ]]; then
	printf '%s\n' "$args" >"${FAKE_DISPATCH_LOG:?}"
	exit 0
fi
if [[ "$args" == *" -f event=push "* ]]; then
	push_branch='v1.2.3'
	[[ "${FAKE_PUSH_BRANCH_MODE:-valid}" == "mismatch" ]] && push_branch='v9.9.9'
	printf '{"workflow_runs":[{"id":10,"event":"push","head_branch":"%s","head_sha":"3333333333333333333333333333333333333333","status":"completed","conclusion":"success","created_at":"2026-07-27T00:00:00Z","display_title":"push","html_url":"push-url"}]}\n' "$push_branch"
	exit 0
fi
if [[ "$args" == *" -f event=workflow_dispatch "* ]]; then
	correlated_title='Publish v1.2.3 [3333333333333333333333333333333333333333.4444444444444444444444444444444444444444]'
	if [[ "${FAKE_RECOVERY_CORRELATION_MODE:-valid}" == "mismatch" ]]; then
		correlated_title='Publish v1.2.3 [3333333333333333333333333333333333333333.5555555555555555555555555555555555555555]'
	fi
	printf '{"workflow_runs":[{"id":11,"event":"workflow_dispatch","head_branch":"main","head_sha":"4444444444444444444444444444444444444444","status":"queued","conclusion":null,"created_at":"2026-07-27T00:01:00Z","display_title":"%s","html_url":"recovery-url"}]}\n' \
		"$correlated_title"
	exit 0
fi
if [[ "$args" == *"releases/tags/v1.2.3"* ]]; then
	if [[ "${FAKE_RELEASE_DRAFT:-0}" == "1" ]]; then
		printf '%s\n' '{"tag_name":"v1.2.3","draft":true,"published_at":null}'
	else
		printf '%s\n' '{"tag_name":"v1.2.3","draft":false,"published_at":"2026-07-27T00:00:00Z"}'
	fi
	exit 0
fi
if [[ "$args" == *"homebrew-tap/contents/Formula/aidevops.rb"* ]]; then
	printf 'class Aidevops\n  url "https://github.com/test/repo/archive/refs/tags/v1.2.3.tar.gz"\n  sha256 "%s"\nend\n' \
		"${FAKE_FORMULA_SHA:?}"
	if [[ "${FAKE_FORMULA_DRIFT:-0}" == "1" ]]; then
		printf '# unexpected drift\n'
	fi
	exit 0
fi
exit 1
STUB
cat >"${TEST_ROOT}/bin/git" <<'STUB'
#!/usr/bin/env bash
if [[ " $* " == *" rev-parse refs/tags/v1.2.3^{commit} "* ]]; then
	printf '%s\n' '3333333333333333333333333333333333333333'
	exit 0
fi
exit 1
STUB
cat >"${TEST_ROOT}/bin/npm" <<'STUB'
#!/usr/bin/env bash
args=" $* "
if [[ "$args" == *" view aidevops@1.2.3 version dist --json "* ]]; then
	jq -cn --arg version "${FAKE_NPM_VERSION:-1.2.3}" \
		--arg integrity "${FAKE_NPM_INTEGRITY:?}" \
		--arg predicate "${FAKE_NPM_PREDICATE:-https://slsa.dev/provenance/v1}" '
		{version:$version,dist:{integrity:$integrity,shasum:"1111111111111111111111111111111111111111",
		attestations:{url:"registry-attestation",provenance:{predicateType:$predicate}}}}
	'
	exit 0
fi
if [[ "$args" == *" install "* ]]; then
	exit 0
fi
if [[ "$args" == *" audit signatures "* ]]; then
	invalid='[]'
	[[ "${FAKE_NPM_AUDIT_INVALID:-0}" == "1" ]] && invalid='[{"code":"invalid"}]'
	jq -cn --arg version "${FAKE_NPM_VERSION:-1.2.3}" \
		--arg payload "${FAKE_PROVENANCE_PAYLOAD_B64:?}" --argjson invalid "$invalid" '
		{invalid:$invalid,missing:[],verified:[{name:"aidevops",version:$version,
		attestations:{provenance:{predicateType:"https://slsa.dev/provenance/v1"}},
		attestationBundles:[{predicateType:"https://slsa.dev/provenance/v1",
		bundle:{dsseEnvelope:{payload:$payload}}}]}]}
	'
	exit 0
fi
exit 1
STUB
cat >"${TEST_ROOT}/bin/curl" <<'STUB'
#!/usr/bin/env bash
printf 'tarball-fixture'
STUB
chmod +x "${TEST_ROOT}/bin/gh"
chmod +x "${TEST_ROOT}/bin/git" "${TEST_ROOT}/bin/npm" "${TEST_ROOT}/bin/curl"
PATH="${TEST_ROOT}/bin:${PATH}"
export FAKE_RUN_SCHEMA_MODE=valid
export FAKE_RECOVERY_CORRELATION_MODE=valid
export FAKE_PUSH_BRANCH_MODE=valid
export FAKE_RELEASE_DRAFT=0
export FAKE_NPM_VERSION=1.2.3
FAKE_NPM_DIGEST=$(printf '%0128d' 0)
FAKE_NPM_INTEGRITY=$(node -e \
	'process.stdout.write("sha512-" + Buffer.from(process.argv[1], "hex").toString("base64"))' \
	"$FAKE_NPM_DIGEST")
export FAKE_NPM_DIGEST FAKE_NPM_INTEGRITY
FAKE_FORMULA_SHA=$(printf 'tarball-fixture' | _full_loop_release_sha256_stream)
export FAKE_FORMULA_SHA

set_fake_provenance_payload() {
	local repository="$1"
	local workflow_ref="$2"
	local subject_digest="${3:-$FAKE_NPM_DIGEST}"
	local payload=""

	payload=$(jq -cn --arg repository "$repository" --arg ref "$workflow_ref" \
		--arg digest "$subject_digest" '
		{"_type":"https://in-toto.io/Statement/v1","predicateType":"https://slsa.dev/provenance/v1",
		"subject":[{"name":"pkg:npm/aidevops@1.2.3","digest":{"sha512":$digest}}],
		"predicate":{"buildDefinition":{
		"buildType":"https://slsa-framework.github.io/github-actions-buildtypes/workflow/v1",
		"externalParameters":{"workflow":{"repository":$repository,
		"path":".github/workflows/publish-packages.yml","ref":$ref}}},
		"runDetails":{"builder":{"id":"https://github.com/actions/runner/github-hosted"}}}}
	') || return 1
	FAKE_PROVENANCE_PAYLOAD_B64=$(node -e \
		'process.stdout.write(Buffer.from(process.argv[1]).toString("base64"))' "$payload") || return 1
	export FAKE_PROVENANCE_PAYLOAD_B64
	return 0
}

_full_loop_release_expected_homebrew_formula() {
	local repo="$1"
	local tag_name="$2"
	local expected_sha="$3"
	printf 'class Aidevops\n  url "https://github.com/%s/archive/refs/tags/%s.tar.gz"\n  sha256 "%s"\nend\n' \
		"$repo" "$tag_name" "$expected_sha"
	return 0
}

set_fake_provenance_payload "https://github.com/test/repo" "refs/heads/main"

_full_loop_release_find_workflow_run test/repo v1.2.3 3333333333333333333333333333333333333333
if [[ "$(jq -r '.id' <<<"$_FULL_LOOP_RELEASE_RUN_JSON")" != "11" ]]; then
	printf 'FAIL recovery workflow was not correlated by exact release display title\n'
	exit 1
fi
printf 'PASS exact push and recovery workflow runs are correlated durably\n'

export FAKE_RECOVERY_CORRELATION_MODE=mismatch
_full_loop_release_find_workflow_run test/repo v1.2.3 3333333333333333333333333333333333333333
if [[ "$(jq -r '.id' <<<"$_FULL_LOOP_RELEASE_RUN_JSON")" != "10" ]]; then
	printf 'FAIL recovery workflow with mismatched commit correlation was accepted\n'
	exit 1
fi
export FAKE_RECOVERY_CORRELATION_MODE=valid
printf 'PASS recovery workflow correlation binds tag and workflow commits\n'

export FAKE_RECOVERY_CORRELATION_MODE=mismatch
export FAKE_PUSH_BRANCH_MODE=mismatch
wrong_push_rc=0
_full_loop_release_find_workflow_run test/repo v1.2.3 \
	3333333333333333333333333333333333333333 >/dev/null 2>&1 || wrong_push_rc=$?
if [[ "$wrong_push_rc" -ne 3 ]]; then
	printf 'FAIL push workflow with a mismatched tag ref was accepted\n'
	exit 1
fi
export FAKE_RECOVERY_CORRELATION_MODE=valid
export FAKE_PUSH_BRANCH_MODE=valid
printf 'PASS push workflow correlation binds the exact release tag ref\n'

saved_script_dir="$SCRIPT_DIR"
SCRIPT_DIR="${TEST_ROOT}/no-audit-helper"
FAKE_DISPATCH_LOG="${TEST_ROOT}/dispatch-command.log"
export FAKE_DISPATCH_LOG
dispatch_rc=0
_full_loop_release_dispatch_recovery test/repo v1.2.3 >/dev/null || dispatch_rc=$?
SCRIPT_DIR="$saved_script_dir"
if [[ "$dispatch_rc" -ne 8 ]] ||
	! grep -qF ' -f tag=v1.2.3 -f correlation=3333333333333333333333333333333333333333 ' \
		"$FAKE_DISPATCH_LOG"; then
	printf 'FAIL recovery dispatch did not carry the exact verified tag commit\n'
	exit 1
fi
printf 'PASS recovery dispatch carries the exact tag while run identity records the workflow commit\n'

for schema_mode in empty object malformed malformed-run api-failure; do
	export FAKE_RUN_SCHEMA_MODE="$schema_mode"
	schema_rc=0
	_full_loop_release_find_workflow_run test/repo v1.2.3 \
		3333333333333333333333333333333333333333 >/dev/null 2>&1 || schema_rc=$?
	if [[ "$schema_rc" -ne 1 ]]; then
		printf 'FAIL %s workflow-run response did not fail closed\n' "$schema_mode"
		exit 1
	fi
done
export FAKE_RUN_SCHEMA_MODE=no-runs
absent_rc=0
_full_loop_release_find_workflow_run test/repo v1.2.3 \
	3333333333333333333333333333333333333333 >/dev/null 2>&1 || absent_rc=$?
if [[ "$absent_rc" -ne 3 ]]; then
	printf 'FAIL valid empty workflow-run arrays were not classified as absent\n'
	exit 1
fi
export FAKE_RUN_SCHEMA_MODE=valid
printf 'PASS workflow-run API and schema uncertainty fail closed\n'

_full_loop_release_find_workflow_run test/repo v1.2.3 3333333333333333333333333333333333333333

_full_loop_release_verify_npm_provenance test/repo v1.2.3 1.2.3 || {
	printf 'FAIL valid npm provenance did not verify\n'
	exit 1
}
if [[ "$_FULL_LOOP_RELEASE_NPM_INTEGRITY" != "$FAKE_NPM_INTEGRITY" ]]; then
	printf 'FAIL npm provenance verification omitted exact package integrity\n'
	exit 1
fi
set_fake_provenance_payload "https://github.com/attacker/repo" "refs/heads/main"
if _full_loop_release_verify_npm_provenance test/repo v1.2.3 1.2.3; then
	printf 'FAIL foreign npm provenance repository was accepted\n'
	exit 1
fi
set_fake_provenance_payload "https://github.com/test/repo" "refs/heads/main"
FAKE_NPM_AUDIT_INVALID=1
export FAKE_NPM_AUDIT_INVALID
if _full_loop_release_verify_npm_provenance test/repo v1.2.3 1.2.3; then
	printf 'FAIL invalid npm provenance signature was accepted\n'
	exit 1
fi
FAKE_NPM_AUDIT_INVALID=0
export FAKE_NPM_AUDIT_INVALID
set_fake_provenance_payload "https://github.com/test/repo" "refs/tags/v1.2.3"
if ! _full_loop_release_verify_npm_provenance test/repo v1.2.3 1.2.3; then
	printf 'FAIL recovery rejected an exact package published by the original tag run\n'
	exit 1
fi
set_fake_provenance_payload "https://github.com/test/repo" "refs/heads/main"
printf 'PASS npm package integrity and signed workflow provenance are bound exactly\n'
printf 'PASS recovery accepts immutable npm provenance from tag or main publication\n'

channel_error_file="${TEST_ROOT}/channel-errors.txt"
channel_output=$(_full_loop_release_verify_channels test/repo v1.2.3 2>"$channel_error_file") || {
	printf 'FAIL exact published channels did not converge\n'
	exit 1
}
if [[ -s "$channel_error_file" ]]; then
	printf 'FAIL published channel verification emitted cleanup errors\n'
	exit 1
fi
if [[ "$channel_output" != *"HOMEBREW_SHA256=${FAKE_FORMULA_SHA}"* ]]; then
	printf 'FAIL channel verification omitted the exact Homebrew digest\n'
	exit 1
fi
FAKE_RELEASE_DRAFT=1
export FAKE_RELEASE_DRAFT
if _full_loop_release_verify_channels test/repo v1.2.3 >/dev/null 2>&1; then
	printf 'FAIL draft GitHub release satisfied channel convergence\n'
	exit 1
fi
FAKE_RELEASE_DRAFT=0
FAKE_FORMULA_SHA=0000000000000000000000000000000000000000000000000000000000000000
export FAKE_RELEASE_DRAFT FAKE_FORMULA_SHA
if _full_loop_release_verify_channels test/repo v1.2.3 >/dev/null 2>&1; then
	printf 'FAIL mismatched Homebrew digest satisfied channel convergence\n'
	exit 1
fi
FAKE_FORMULA_SHA=$(printf 'tarball-fixture' | _full_loop_release_sha256_stream)
export FAKE_FORMULA_SHA
FAKE_FORMULA_DRIFT=1
export FAKE_FORMULA_DRIFT
if _full_loop_release_verify_channels test/repo v1.2.3 >/dev/null 2>&1; then
	printf 'FAIL drifted Homebrew formula satisfied exact channel convergence\n'
	exit 1
fi
FAKE_FORMULA_DRIFT=0
export FAKE_FORMULA_DRIFT
printf 'PASS published channel verification binds release, package, formula, and digest\n'

run_stale_supersession_fixture() {
	local mode="$1"
	local write_log="$2"
	(
		_full_loop_release_source_json_from_tag() {
			local tag_name="$1"
			case "$tag_name" in
			v1.2.3)
				printf '%s\n' '{"source_pr":90,"source_merge":"1111111111111111111111111111111111111111","aggregated_sources":[]}'
				;;
			v1.2.4)
				printf '%s\n' '{"source_pr":91,"source_merge":"2222222222222222222222222222222222222222","aggregated_sources":[]}'
				;;
			*) return 1 ;;
			esac
			return 0
		}
		_full_loop_release_resolve_tag_commit() {
			local tag_name="$1"
			case "$tag_name" in
			v1.2.3) printf '%040d\n' 3 ;;
			v1.2.4) printf '%040d\n' 4 ;;
			*) return 1 ;;
			esac
			return 0
		}
		_full_loop_release_verify_stale_publication_run() {
			local repo="$1"
			local tag_name="$2"
			local tag_commit="$3"
			[[ "$repo" == "test/repo" && "$tag_name" == "v1.2.3" && "$tag_commit" == "$(printf '%040d' 3)" ]] || return 1
			[[ "$mode" != "source-run" ]] || return 1
			_FULL_LOOP_RELEASE_RUN_JSON='{"id":101}'
			return 0
		}
		_full_loop_release_reset_tag_worktree() {
			return 0
		}
		_full_loop_release_verify_tag_provenance() {
			local repo="$1"
			local tag_name="$2"
			[[ "$repo" == "test/repo" && "$tag_name" == "v1.2.4" ]]
			return $?
		}
		_full_loop_release_inspect_remote() {
			local repo="$1"
			local tag_name="$2"
			[[ "$repo" == "test/repo" && "$tag_name" == "v1.2.4" ]] || return 1
			[[ "$mode" != "latest-remote" ]] || return 1
			_FULL_LOOP_RELEASE_RUN_JSON='{"id":202}'
			return 0
		}
		_full_loop_release_receipt_path() {
			local repo="$1"
			local pr_number="$2"
			[[ "$repo" == "test/repo" ]] || return 1
			if [[ "$mode" == "receipt" ]]; then
				printf '%s/missing-%s.status\n' "$TEST_ROOT" "$pr_number"
			else
				printf '%s/receipts/test_repo-%s.status\n' "$TEST_ROOT" "$pr_number"
			fi
			return 0
		}
		_full_loop_write_successor_release_receipt() {
			local args="$*"
			printf '%s\n' "$args" >"$write_log"
			return 0
		}
		git() {
			local args="$*"
			[[ "$args" == *" merge-base --is-ancestor "* && "$mode" != "ancestry" ]]
			return $?
		}
		_full_loop_release_finalize_stale_supersession test/repo 90 v1.2.3 v1.2.4
	)
	return $?
}

printf 'published\n' >"${TEST_ROOT}/receipts/test_repo-91.status"
stale_write_log="${TEST_ROOT}/stale-successor-write.log"
run_stale_supersession_fixture valid "$stale_write_log" || {
	printf 'FAIL verified stale publication and terminal successor did not reconcile\n'
	exit 1
}
if ! grep -qx "test/repo 90 1111111111111111111111111111111111111111 v1.2.3 $(printf '%040d' 3) 101 91 2222222222222222222222222222222222222222 v1.2.4 $(printf '%040d' 4) 202" \
	"$stale_write_log"; then
	printf 'FAIL post-publication supersession omitted immutable source or successor evidence\n'
	exit 1
fi
for stale_failure_mode in source-run ancestry latest-remote receipt; do
	rm -f "$stale_write_log"
	if run_stale_supersession_fixture "$stale_failure_mode" "$stale_write_log"; then
		printf 'FAIL %s uncertainty allowed stale release supersession\n' "$stale_failure_mode"
		exit 1
	fi
	[[ ! -e "$stale_write_log" ]] || {
		printf 'FAIL %s uncertainty wrote terminal supersession evidence\n' "$stale_failure_mode"
		exit 1
	}
done
printf 'PASS stale receipt supersession binds both releases and fails closed on uncertain evidence\n'

_full_loop_resolve_repo() {
	local requested_repo="$1"
	printf '%s\n' "${requested_repo:-test/repo}"
	return 0
}
_full_loop_release_receipt_path() {
	local repo="$1"
	local pr_number="$2"
	printf '%s/%s-%s.status\n' "${TEST_ROOT}/receipts" "${repo//\//_}" "$pr_number"
	return 0
}
_full_loop_release_find_tag_for_pr() {
	local repo="$1"
	local pr_number="$2"
	[[ -n "$repo" && "$pr_number" =~ ^[0-9]+$ ]] || return 1
	_FULL_LOOP_RELEASE_FOUND_TAG=v1.2.3
	return 0
}
_full_loop_release_latest_tag() {
	printf 'v1.2.3\n'
	return 0
}
_full_loop_release_inspect_remote() {
	local repo="$1"
	local tag_name="$2"
	[[ -n "$repo" && -n "$tag_name" ]] || return 1
	return "${INSPECT_RC:-3}"
}
_full_loop_release_dispatch_recovery() {
	local repo="$1"
	local tag_name="$2"
	printf '%s %s\n' "$repo" "$tag_name" >"${TEST_ROOT}/dispatch.log"
	return 8
}
_full_loop_release_finalize_reconciliation() {
	local repo="$1"
	local pr_number="$2"
	local tag_name="$3"
	printf '%s %s %s\n' "$repo" "$pr_number" "$tag_name" >"${TEST_ROOT}/finalize.log"
	return 0
}
_full_loop_release_finalize_stale_supersession() {
	local repo="$1"
	local pr_number="$2"
	local source_tag="$3"
	local release_tag="$4"
	printf '%s %s %s %s\n' "$repo" "$pr_number" "$source_tag" "$release_tag" \
		>"${TEST_ROOT}/stale-finalize.log"
	return "${STALE_FINALIZE_RC:-0}"
}
_full_loop_verify_superseded_release_receipt() {
	local repo="$1"
	local pr_number="$2"
	[[ "$repo" == "test/repo" && "$pr_number" == "90" ]]
	return $?
}
_full_loop_update_superseded_cleanup_receipt() {
	local repo="$1"
	local pr_number="$2"
	printf '%s %s\n' "$repo" "$pr_number" >"${TEST_ROOT}/cleanup-update.log"
	return 0
}

reconcile_rc=0
AIDEVOPS_FULL_LOOP_REPO=test/repo _full_loop_release_existing_command reconcile 90 \
	>/dev/null 2>&1 || reconcile_rc=$?
if [[ "$reconcile_rc" -ne 8 ]] ||
	! grep -qx 'test/repo v1.2.3' "${TEST_ROOT}/dispatch.log"; then
	printf 'FAIL absent publication did not queue idempotent recovery\n'
	exit 1
fi
printf 'PASS absent publication queues idempotent recovery\n'

INSPECT_RC=1
rm -f "${TEST_ROOT}/dispatch.log"
uncertain_rc=0
AIDEVOPS_FULL_LOOP_REPO=test/repo _full_loop_release_existing_command reconcile 90 \
	>/dev/null 2>&1 || uncertain_rc=$?
if [[ "$uncertain_rc" -ne 1 || -e "${TEST_ROOT}/dispatch.log" ]]; then
	printf 'FAIL remote-state uncertainty allowed a recovery dispatch\n'
	exit 1
fi
printf 'PASS remote-state uncertainty blocks recovery dispatch\n'

INSPECT_RC=8
rm -f "${TEST_ROOT}/dispatch.log"
pending_rc=0
AIDEVOPS_FULL_LOOP_REPO=test/repo _full_loop_release_existing_command reconcile 90 \
	>/dev/null 2>&1 || pending_rc=$?
if [[ "$pending_rc" -ne 8 || -e "${TEST_ROOT}/dispatch.log" ]]; then
	printf 'FAIL pending publication was redundantly redispatched\n'
	exit 1
fi
printf 'PASS pending publication is not redundantly redispatched\n'

INSPECT_RC=0
AIDEVOPS_FULL_LOOP_REPO=test/repo _full_loop_release_existing_command reconcile 90 >/dev/null
if ! grep -qx 'test/repo 90 v1.2.3' "${TEST_ROOT}/finalize.log"; then
	printf 'FAIL completed publication did not finalize durable release state\n'
	exit 1
fi
printf 'PASS completed publication finalizes durable release state\n'

printf 'published\n' >"${TEST_ROOT}/receipts/test_repo-90.status"
rm -f "${TEST_ROOT}/finalize.log"
AIDEVOPS_FULL_LOOP_REPO=test/repo _full_loop_release_existing_command reconcile 90 >/dev/null
if [[ -e "${TEST_ROOT}/finalize.log" ]]; then
	printf 'FAIL terminal published receipt was finalized twice\n'
	exit 1
fi
printf 'PASS published reconciliation is idempotent\n'

printf 'not-requested\n' >"${TEST_ROOT}/receipts/test_repo-90.status"
terminal_rc=0
AIDEVOPS_FULL_LOOP_REPO=test/repo _full_loop_release_existing_command reconcile 90 \
	>/dev/null 2>&1 || terminal_rc=$?
if [[ "$terminal_rc" -ne 1 ]]; then
	printf 'FAIL terminal not-requested evidence allowed publication recovery\n'
	exit 1
fi
printf 'PASS not-requested evidence remains an irreversible publication block\n'
rm -f "${TEST_ROOT}/receipts/test_repo-90.status"

_full_loop_release_latest_tag() {
	printf 'v1.2.4\n'
	return 0
}
printf 'failed\n' >"${TEST_ROOT}/receipts/test_repo-90.status"
stale_status_rc=0
AIDEVOPS_FULL_LOOP_REPO=test/repo _full_loop_release_existing_command status 90 \
	>/dev/null 2>&1 || stale_status_rc=$?
if [[ "$stale_status_rc" -ne 1 || -e "${TEST_ROOT}/stale-finalize.log" ]]; then
	printf 'FAIL read-only stale release status mutated terminal evidence\n'
	exit 1
fi
stale_reconcile_rc=0
AIDEVOPS_FULL_LOOP_REPO=test/repo _full_loop_release_existing_command reconcile 90 \
	>/dev/null 2>&1 || stale_reconcile_rc=$?
if [[ "$stale_reconcile_rc" -ne 0 ]] ||
	! grep -qx 'test/repo 90 v1.2.3 v1.2.4' "${TEST_ROOT}/stale-finalize.log" ||
	[[ -e "${TEST_ROOT}/dispatch.log" || -e "${TEST_ROOT}/finalize.log" ]]; then
	printf 'FAIL stale release receipt did not use the no-publication supersession path\n'
	exit 1
fi

rm -f "${TEST_ROOT}/stale-finalize.log"
STALE_FINALIZE_RC=1
export STALE_FINALIZE_RC
stale_uncertain_rc=0
AIDEVOPS_FULL_LOOP_REPO=test/repo _full_loop_release_existing_command reconcile 90 \
	>/dev/null 2>&1 || stale_uncertain_rc=$?
if [[ "$stale_uncertain_rc" -ne 1 ]] || ! grep -qx 'failed' "${TEST_ROOT}/receipts/test_repo-90.status"; then
	printf 'FAIL uncertain stale supersession replaced the failed receipt\n'
	exit 1
fi
unset STALE_FINALIZE_RC

printf 'superseded\n' >"${TEST_ROOT}/receipts/test_repo-90.status"
rm -f "${TEST_ROOT}/stale-finalize.log" "${TEST_ROOT}/cleanup-update.log"
AIDEVOPS_FULL_LOOP_REPO=test/repo _full_loop_release_existing_command status 90 >/dev/null
if [[ -e "${TEST_ROOT}/cleanup-update.log" ]]; then
	printf 'FAIL read-only terminal stale status updated cleanup evidence\n'
	exit 1
fi
AIDEVOPS_FULL_LOOP_REPO=test/repo _full_loop_release_existing_command reconcile 90 >/dev/null
if [[ -e "${TEST_ROOT}/stale-finalize.log" ]] ||
	! grep -qx 'test/repo 90' "${TEST_ROOT}/cleanup-update.log"; then
	printf 'FAIL terminal stale supersession evidence was finalized twice\n'
	exit 1
fi
printf 'PASS stale release tags cannot downgrade channels and reconcile only through verified supersession\n'

exit 0

#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Regression coverage for fail-closed profile contribution generation.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
HELPER="${SCRIPT_DIR}/../profile-readme-helper.sh"

TESTS_RUN=0
TESTS_FAILED=0
TEST_ROOT=""

pass() {
	local name="$1"
	TESTS_RUN=$((TESTS_RUN + 1))
	printf 'PASS %s\n' "$name"
	return 0
}

fail() {
	local name="$1"
	local detail="$2"
	TESTS_RUN=$((TESTS_RUN + 1))
	TESTS_FAILED=$((TESTS_FAILED + 1))
	printf 'FAIL %s\n       %s\n' "$name" "$detail"
	return 0
}

teardown() {
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

write_gh_stub() {
	local bin_dir="$1"
	mkdir -p "$bin_dir"
	cat >"${bin_dir}/gh" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail

scenario="${GH_SCENARIO:-success}"
[[ "${1:-}" == "api" ]] || exit 1
endpoint="${2:-}"

case "$endpoint" in
users/fixture/repos*)
	case "$scenario" in
	list-failure)
		printf '%s\n' '{"message":"API rate limit exceeded","status":"403"}'
		exit 1
		;;
	list-failure-valid-output)
		printf '%s\n' '[{"fork":true,"name":"fork-one"}]'
		exit 1
		;;
	malformed-list)
		printf '%s\n' '{"message":"API rate limit exceeded","status":"403"}'
		exit 0
		;;
	esac
	printf '%s\n' '[{"fork":true,"name":"fork-one"}]'
	exit 0
	;;
repos/fixture/fork-one)
	case "$scenario" in
	fork-failure)
		printf '%s\n' '{"message":"API rate limit exceeded","status":"403"}'
		exit 1
		;;
	fork-failure-valid-output)
		printf 'fork-one\tFork description\thttps://example.invalid/fork-one\n'
		exit 1
		;;
	malformed-fork)
		printf '%s\n' '{"message":"API rate limit exceeded","status":"403"}'
		exit 0
		;;
	marker-injection)
		printf 'fork-one\tUnsafe <!-- CONTRIBUTIONS-END --> marker\thttps://example.invalid/fork-one\n'
		exit 0
		;;
	synthesized-marker)
		printf 'fork-one\tUnsafe <![-- CONTRIBUTIONS-END --]> marker\thttps://example.invalid/fork-one\n'
		exit 0
		;;
	changed)
		printf 'fork-one\tChanged fork description\thttps://example.invalid/fork-one\n'
		exit 0
		;;
	esac
	printf 'fork-one\tFork description\thttps://example.invalid/fork-one\n'
	exit 0
	;;
repos/upstream/configured)
	if [[ "$scenario" == "configured-failure" ]]; then
		printf '%s\n' '{"message":"API rate limit exceeded","status":"403"}'
		exit 1
	fi
	if [[ "$scenario" == "configured-failure-valid-output" ]]; then
		printf 'configured\tNo description\thttps://example.invalid/configured\n'
		exit 1
	fi
	printf 'configured\tNo description\thttps://example.invalid/configured\n'
	exit 0
	;;
esac

exit 1
STUB
	chmod +x "${bin_dir}/gh"
	return 0
}

create_fixture() {
	local case_name="$1"
	local case_root="${TEST_ROOT}/${case_name}"
	local fixture_home="${case_root}/home"
	local profile_repo="${case_root}/fixture"
	local remote_repo="${case_root}/remote.git"

	mkdir -p "${fixture_home}/.config/aidevops" "$profile_repo"
	git init --bare --initial-branch=main "$remote_repo" >/dev/null
	git init -b main "$profile_repo" >/dev/null
	git -C "$profile_repo" config user.name "Fixture"
	git -C "$profile_repo" config user.email "fixture@example.invalid"
	git -C "$profile_repo" config commit.gpgsign false
	git -C "$profile_repo" remote add origin "$remote_repo"

	cat >"${profile_repo}/README.md" <<'README'
# Fixture Profile

<!-- CONTRIBUTIONS-START -->
## Contributions

- **[last-known-good](https://example.invalid/last-known-good)** -- Preserved content
<!-- CONTRIBUTIONS-END -->
README
	git -C "$profile_repo" add README.md
	git -C "$profile_repo" commit -m "test: seed profile" >/dev/null
	git -C "$profile_repo" push -u origin main >/dev/null

	cat >"${fixture_home}/.config/aidevops/repos.json" <<EOF
{
  "initialized_repos": [
    {
      "path": "${profile_repo}",
      "slug": "fixture/fixture",
      "priority": "profile"
    },
    {
      "path": "${case_root}/configured",
      "slug": "upstream/configured",
      "contributed": true
    }
  ]
}
EOF
	write_gh_stub "${case_root}/bin"
	printf '%s\n' "$case_root"
	return 0
}

read_remote_readme() {
	local remote_repo="$1"
	local output_file="$2"
	git --git-dir="$remote_repo" show main:README.md >"$output_file"
	return $?
}

run_failure_case() {
	local scenario="$1"
	local case_root
	case_root=$(create_fixture "$scenario") || return 1
	local profile_repo="${case_root}/fixture"
	local before_file="${case_root}/before.md"
	cp "${profile_repo}/README.md" "$before_file"

	local output=""
	local exit_code=0
	output=$(HOME="${case_root}/home" PATH="${case_root}/bin:${PATH}" GH_SCENARIO="$scenario" \
		bash "$HELPER" update-contributions 2>&1) || exit_code=$?

	if [[ "$exit_code" -eq 0 ]]; then
		fail "$scenario fails closed" "helper unexpectedly succeeded"
		return 0
	fi
	if ! cmp -s "$before_file" "${profile_repo}/README.md"; then
		fail "$scenario preserves README" "README changed after API failure"
		return 0
	fi
	if [[ -n "$(git -C "$profile_repo" status --porcelain)" ]]; then
		fail "$scenario preserves git state" "profile repository became dirty"
		return 0
	fi
	if [[ "$output" == *"API rate limit exceeded"* ]]; then
		fail "$scenario discards API error payload" "raw error payload leaked into output"
		return 0
	fi
	if [[ "$output" != *"preserv"* ]]; then
		fail "$scenario reports preservation" "missing preservation warning: ${output}"
		return 0
	fi
	if [[ -f "${case_root}/home/.aidevops/cache/contributions-last-update" ]]; then
		fail "$scenario leaves throttle open" "failure incorrectly recorded as a successful refresh"
		return 0
	fi
	pass "$scenario fails closed without mutation"
	return 0
}

test_static_section_failure_preserves_content() {
	local case_root
	case_root=$(create_fixture "static-section-failure") || return 1
	local profile_repo="${case_root}/fixture"
	cat >"${profile_repo}/README.md" <<'README'
# Fixture Profile

## Contributions

- **[last-known-good](https://example.invalid/last-known-good)** -- Preserved static content

## Connect

- Existing content
README
	git -C "$profile_repo" add README.md
	git -C "$profile_repo" commit -m "test: use static contributions" >/dev/null
	git -C "$profile_repo" push origin main >/dev/null
	cp "${profile_repo}/README.md" "${case_root}/before-static.md"

	local output=""
	local exit_code=0
	output=$(HOME="${case_root}/home" PATH="${case_root}/bin:${PATH}" GH_SCENARIO=list-failure \
		bash "$HELPER" update-contributions 2>&1) || exit_code=$?
	if [[ "$exit_code" -eq 0 ]] || ! cmp -s "${case_root}/before-static.md" "${profile_repo}/README.md"; then
		fail "marker migration waits for validated data" "exit=${exit_code} output=${output}"
		return 0
	fi
	if [[ -n "$(git -C "$profile_repo" status --porcelain)" ]]; then
		fail "marker migration failure preserves git state" "profile repository became dirty"
		return 0
	fi
	pass "marker migration waits for validated data"
	return 0
}

test_static_transform_failure_preserves_content() {
	local case_root
	case_root=$(create_fixture "static-transform-failure") || return 1
	local profile_repo="${case_root}/fixture"
	cat >"${profile_repo}/README.md" <<'README'
# Fixture Profile

## Contributions

- Existing static contribution

## Connect
README
	git -C "$profile_repo" add README.md
	git -C "$profile_repo" commit -m "test: use static section" >/dev/null
	git -C "$profile_repo" push origin main >/dev/null
	cp "${profile_repo}/README.md" "${case_root}/before-transform.md"
	cat >"${case_root}/bin/awk" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
	chmod +x "${case_root}/bin/awk"

	local exit_code=0
	HOME="${case_root}/home" PATH="${case_root}/bin:${PATH}" GH_SCENARIO=success \
		bash "$HELPER" update-contributions >/dev/null 2>&1 || exit_code=$?
	if [[ "$exit_code" -eq 0 ]] || ! cmp -s "${case_root}/before-transform.md" "${profile_repo}/README.md"; then
		fail "static transform failure preserves content" "exit=${exit_code}"
		return 0
	fi
	pass "static transform failure preserves content"
	return 0
}

test_invalid_static_transform_preserves_content() {
	local case_root
	case_root=$(create_fixture "invalid-static-transform") || return 1
	local profile_repo="${case_root}/fixture"
	cat >"${profile_repo}/README.md" <<'README'
# Fixture Profile
## Contributions
- First section
## Connect
## Contributions
- Second section
## End
README
	git -C "$profile_repo" add README.md
	git -C "$profile_repo" commit -m "test: duplicate static sections" >/dev/null
	git -C "$profile_repo" push origin main >/dev/null
	cp "${profile_repo}/README.md" "${case_root}/before-invalid-transform.md"

	local exit_code=0
	HOME="${case_root}/home" PATH="${case_root}/bin:${PATH}" GH_SCENARIO=success \
		bash "$HELPER" update-contributions >/dev/null 2>&1 || exit_code=$?
	if [[ "$exit_code" -eq 0 ]] || ! cmp -s "${case_root}/before-invalid-transform.md" "${profile_repo}/README.md"; then
		fail "invalid static transform preserves content" "exit=${exit_code}"
		return 0
	fi
	pass "invalid static transform preserves content"
	return 0
}

test_renderer_failure_after_migration_preserves_content() {
	local case_root
	case_root=$(create_fixture "renderer-after-migration") || return 1
	local profile_repo="${case_root}/fixture"
	cat >"${profile_repo}/README.md" <<'README'
# Fixture Profile
## Contributions
- Existing static contribution
## Connect
README
	git -C "$profile_repo" add README.md
	git -C "$profile_repo" commit -m "test: static section before renderer failure" >/dev/null
	git -C "$profile_repo" push origin main >/dev/null
	cp "${profile_repo}/README.md" "${case_root}/before-renderer.md"
	local real_awk
	real_awk=$(command -v awk)
	cat >"${case_root}/bin/awk" <<STUB
#!/usr/bin/env bash
case "\$*" in
*in_old_contrib*) exec "${real_awk}" "\$@" ;;
*) exit 1 ;;
esac
STUB
	chmod +x "${case_root}/bin/awk"

	local exit_code=0
	HOME="${case_root}/home" PATH="${case_root}/bin:${PATH}" GH_SCENARIO=success \
		bash "$HELPER" update-contributions >/dev/null 2>&1 || exit_code=$?
	if [[ "$exit_code" -eq 0 ]] || ! cmp -s "${case_root}/before-renderer.md" "${profile_repo}/README.md"; then
		fail "renderer failure after migration preserves content" "exit=${exit_code}"
		return 0
	fi
	pass "renderer failure after migration preserves content"
	return 0
}

test_final_replacement_failure_preserves_content() {
	local case_root
	case_root=$(create_fixture "final-replacement-failure") || return 1
	local profile_repo="${case_root}/fixture"
	cp "${profile_repo}/README.md" "${case_root}/before-replacement.md"
	cat >"${case_root}/bin/mv" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
	chmod +x "${case_root}/bin/mv"

	local exit_code=0
	HOME="${case_root}/home" PATH="${case_root}/bin:${PATH}" GH_SCENARIO=success \
		bash "$HELPER" update-contributions >/dev/null 2>&1 || exit_code=$?
	if [[ "$exit_code" -eq 0 ]] || ! cmp -s "${case_root}/before-replacement.md" "${profile_repo}/README.md"; then
		fail "final replacement failure preserves content" "exit=${exit_code}"
		return 0
	fi
	if [[ -f "${case_root}/home/.aidevops/cache/contributions-last-update" ]]; then
		fail "final replacement failure leaves throttle open" "failure recorded as success"
		return 0
	fi
	pass "final replacement failure preserves content"
	return 0
}

test_malformed_markers_fail() {
	local case_root
	case_root=$(create_fixture "malformed-markers") || return 1
	local profile_repo="${case_root}/fixture"
	local readme="${profile_repo}/README.md"
	grep -vF '<!-- CONTRIBUTIONS-END -->' "$readme" >"${case_root}/without-end.md"
	mv "${case_root}/without-end.md" "$readme"
	git -C "$profile_repo" add README.md
	git -C "$profile_repo" commit -m "test: remove end marker" >/dev/null
	git -C "$profile_repo" push origin main >/dev/null
	cp "$readme" "${case_root}/before-malformed.md"

	local output=""
	local exit_code=0
	output=$(HOME="${case_root}/home" PATH="${case_root}/bin:${PATH}" GH_SCENARIO=success \
		bash "$HELPER" update-contributions 2>&1) || exit_code=$?
	if [[ "$exit_code" -eq 0 ]] || ! cmp -s "${case_root}/before-malformed.md" "$readme"; then
		fail "malformed markers fail without mutation" "exit=${exit_code} output=${output}"
		return 0
	fi
	if [[ -n "$(git -C "$profile_repo" status --porcelain)" ]]; then
		fail "malformed markers preserve git state" "profile repository became dirty"
		return 0
	fi
	pass "malformed markers fail without mutation"
	return 0
}

test_marker_topology_rejected() {
	local topology="$1"
	local case_root
	case_root=$(create_fixture "topology-${topology}") || return 1
	local profile_repo="${case_root}/fixture"
	local readme="${profile_repo}/README.md"
	case "$topology" in
	orphan-end)
		grep -vF '<!-- CONTRIBUTIONS-START -->' "$readme" >"${case_root}/invalid.md"
		;;
	reversed)
		cat >"${case_root}/invalid.md" <<'README'
# Fixture Profile
<!-- CONTRIBUTIONS-END -->
Old content
<!-- CONTRIBUTIONS-START -->
README
		;;
	duplicate-start)
		cp "$readme" "${case_root}/invalid.md"
		printf '%s\n' '<!-- CONTRIBUTIONS-START -->' >>"${case_root}/invalid.md"
		;;
	joined-end-before-start)
		cat >"${case_root}/invalid.md" <<'README'
# Fixture Profile
Old content<!-- CONTRIBUTIONS-END -->
<!-- CONTRIBUTIONS-START -->
README
		;;
	esac
	mv "${case_root}/invalid.md" "$readme"
	git -C "$profile_repo" add README.md
	git -C "$profile_repo" commit -m "test: create invalid marker topology" >/dev/null
	git -C "$profile_repo" push origin main >/dev/null
	cp "$readme" "${case_root}/before-topology.md"

	local output=""
	local exit_code=0
	output=$(HOME="${case_root}/home" PATH="${case_root}/bin:${PATH}" GH_SCENARIO=success \
		bash "$HELPER" update-contributions 2>&1) || exit_code=$?
	if [[ "$exit_code" -eq 0 ]] || ! cmp -s "${case_root}/before-topology.md" "$readme"; then
		fail "${topology} marker topology is rejected" "exit=${exit_code} output=${output}"
		return 0
	fi
	pass "${topology} marker topology is rejected"
	return 0
}

test_legacy_joined_marker_is_repaired() {
	local case_root
	case_root=$(create_fixture "legacy-joined-marker") || return 1
	local profile_repo="${case_root}/fixture"
	local readme="${profile_repo}/README.md"
	awk '
		/last-known-good/ { printf "%s", $0; next }
		/<!-- CONTRIBUTIONS-END -->/ { print; next }
		{ print }
	' "$readme" >"${case_root}/joined.md"
	mv "${case_root}/joined.md" "$readme"
	git -C "$profile_repo" add README.md
	git -C "$profile_repo" commit -m "test: join legacy end marker" >/dev/null
	git -C "$profile_repo" push origin main >/dev/null

	local output=""
	if ! output=$(HOME="${case_root}/home" PATH="${case_root}/bin:${PATH}" GH_SCENARIO=success \
		bash "$HELPER" update-contributions 2>&1); then
		fail "legacy joined marker is repaired" "$output"
		return 0
	fi
	local remote_readme="${case_root}/remote-readme.md"
	read_remote_readme "${case_root}/remote.git" "$remote_readme"
	if [[ "$(grep -cFx '<!-- CONTRIBUTIONS-START -->' "$remote_readme")" -ne 1 ]] ||
		[[ "$(grep -cFx '<!-- CONTRIBUTIONS-END -->' "$remote_readme")" -ne 1 ]]; then
		fail "legacy joined marker becomes one exact pair" "marker counts are invalid"
		return 0
	fi
	pass "legacy joined marker is repaired"
	return 0
}

test_successful_refresh() {
	local case_root
	case_root=$(create_fixture "success") || return 1
	local profile_repo="${case_root}/fixture"
	local output=""

	if ! output=$(HOME="${case_root}/home" PATH="${case_root}/bin:${PATH}" GH_SCENARIO=success \
		bash "$HELPER" update-contributions 2>&1); then
		fail "healthy refresh succeeds" "$output"
		return 0
	fi
	local readme="${case_root}/remote-readme.md"
	read_remote_readme "${case_root}/remote.git" "$readme"
	if ! grep -Fq -- '- **[configured](https://example.invalid/configured)** -- No description' "$readme" ||
		! grep -Fq -- '- **[fork-one](https://example.invalid/fork-one)** -- Fork description' "$readme"; then
		fail "healthy refresh renders validated records" "expected contribution lines missing"
		return 0
	fi
	local configured_line fork_line
	configured_line=$(grep -nF -- '- **[configured]' "$readme" | cut -d: -f1)
	fork_line=$(grep -nF -- '- **[fork-one]' "$readme" | cut -d: -f1)
	if [[ "$configured_line" -ge "$fork_line" ]]; then
		fail "healthy refresh sorts records" "configured=${configured_line} fork=${fork_line}"
		return 0
	fi
	if ! grep -qxF '<!-- CONTRIBUTIONS-END -->' "$readme"; then
		fail "healthy refresh keeps end marker on its own line" "end marker was joined to generated content"
		return 0
	fi
	if [[ ! -f "${case_root}/home/.aidevops/cache/contributions-last-update" ]]; then
		fail "healthy refresh records throttle" "success timestamp missing"
		return 0
	fi
	pass "healthy refresh renders deterministic validated content"
	return 0
}

test_unchanged_refresh_records_throttle() {
	local case_root
	case_root=$(create_fixture "unchanged") || return 1
	local profile_repo="${case_root}/fixture"
	local run_env_path="${case_root}/bin:${PATH}"

	if ! HOME="${case_root}/home" PATH="$run_env_path" GH_SCENARIO=success \
		bash "$HELPER" update-contributions >/dev/null 2>&1; then
		fail "unchanged refresh fixture setup" "initial refresh failed"
		return 0
	fi
	rm -f "${case_root}/home/.aidevops/cache/contributions-last-update"
	local before_head
	before_head=$(git --git-dir="${case_root}/remote.git" rev-parse main)
	local output=""
	if ! output=$(HOME="${case_root}/home" PATH="$run_env_path" GH_SCENARIO=success \
		bash "$HELPER" update-contributions 2>&1); then
		fail "unchanged refresh succeeds" "$output"
		return 0
	fi
	if [[ "$output" != *"Contributions unchanged"* ]] ||
		[[ ! -f "${case_root}/home/.aidevops/cache/contributions-last-update" ]] ||
		[[ "$before_head" != "$(git --git-dir="${case_root}/remote.git" rev-parse main)" ]]; then
		fail "unchanged refresh records throttle" "output=${output}"
		return 0
	fi
	pass "unchanged refresh records throttle without a commit"
	return 0
}

test_push_failure_propagates() {
	local case_root
	case_root=$(create_fixture "push-failure") || return 1
	local profile_repo="${case_root}/fixture"
	local canonical_head=""
	canonical_head=$(git -C "$profile_repo" rev-parse HEAD)
	git -C "$profile_repo" remote set-url origin "${case_root}/missing-remote.git"

	local output=""
	local exit_code=0
	output=$(HOME="${case_root}/home" PATH="${case_root}/bin:${PATH}" GH_SCENARIO=success \
		bash "$HELPER" update-contributions 2>&1) || exit_code=$?
	if [[ "$exit_code" -eq 0 || "$output" != *"could not prepare profile publication worktree"* ]]; then
		fail "push failure propagates" "exit=${exit_code} output=${output}"
		return 0
	fi
	if [[ -f "${case_root}/home/.aidevops/cache/contributions-last-update" ]]; then
		fail "push failure leaves throttle open" "failure incorrectly recorded as success"
		return 0
	fi

	git -C "$profile_repo" remote set-url origin "${case_root}/remote.git"
	local retry_output=""
	if ! retry_output=$(HOME="${case_root}/home" PATH="${case_root}/bin:${PATH}" GH_SCENARIO=success \
		bash "$HELPER" update-contributions 2>&1); then
		fail "push retry succeeds" "$retry_output"
		return 0
	fi
	local local_head remote_head
	local_head=$(git -C "$profile_repo" rev-parse HEAD)
	remote_head=$(git --git-dir="${case_root}/remote.git" rev-parse main)
	if [[ "$local_head" != "$canonical_head" || "$remote_head" == "$canonical_head" ]] ||
		[[ ! -f "${case_root}/home/.aidevops/cache/contributions-last-update" ]]; then
		fail "push retry closes throttle after remote sync" "local=${local_head} remote=${remote_head} output=${retry_output}"
		return 0
	fi
	pass "push failure propagates and retry synchronizes remote"
	return 0
}

test_unrelated_local_work_is_not_published() {
	local mode="$1"
	local case_root
	case_root=$(create_fixture "unrelated-${mode}") || return 1
	local profile_repo="${case_root}/fixture"
	local run_path="${case_root}/bin:${PATH}"
	if ! HOME="${case_root}/home" PATH="$run_path" GH_SCENARIO=success \
		bash "$HELPER" update-contributions >/dev/null 2>&1; then
		fail "${mode} local-work fixture setup" "initial refresh failed"
		return 0
	fi
	rm -f "${case_root}/home/.aidevops/cache/contributions-last-update"
	local remote_before
	remote_before=$(git --git-dir="${case_root}/remote.git" rev-parse main)
	if [[ "$mode" == dirty-readme ]]; then
		printf '%s\n' 'Manual draft' >>"${profile_repo}/README.md"
	elif [[ "$mode" == staged-file ]]; then
		printf '%s\n' 'Unrelated staged file' >"${profile_repo}/NOTES.md"
		git -C "$profile_repo" add NOTES.md
	else
		printf '%s\n' 'Unrelated local commit' >"${profile_repo}/NOTES.md"
		git -C "$profile_repo" add NOTES.md
		git -C "$profile_repo" commit -m "docs: unrelated local work" >/dev/null
	fi

	local output=""
	local exit_code=0
	output=$(HOME="${case_root}/home" PATH="$run_path" GH_SCENARIO=changed \
		bash "$HELPER" update-contributions 2>&1) || exit_code=$?
	local remote_after
	remote_after=$(git --git-dir="${case_root}/remote.git" rev-parse main)
	if [[ "$exit_code" -eq 0 || "$remote_before" != "$remote_after" ]]; then
		fail "${mode} local work is not published" "exit=${exit_code} output=${output}"
		return 0
	fi
	pass "${mode} local work is not published"
	return 0
}

test_renderer_failure_propagates() {
	local exit_code=0
	(
		set -- help
		# shellcheck source=../profile-readme-helper.sh
		source "$HELPER" >/dev/null
		_render_contributions_candidate "/missing/profile-readme" "validated"
	) >/dev/null 2>&1 || exit_code=$?
	if [[ "$exit_code" -eq 0 ]]; then
		fail "renderer failure propagates" "missing input unexpectedly succeeded"
		return 0
	fi
	pass "renderer failure propagates"
	return 0
}

main() {
	TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/profile-contributions-test.XXXXXX") || return 1
	trap teardown EXIT

	run_failure_case "list-failure"
	run_failure_case "list-failure-valid-output"
	run_failure_case "malformed-list"
	run_failure_case "fork-failure"
	run_failure_case "fork-failure-valid-output"
	run_failure_case "malformed-fork"
	run_failure_case "configured-failure"
	run_failure_case "configured-failure-valid-output"
	run_failure_case "marker-injection"
	run_failure_case "synthesized-marker"
	test_static_section_failure_preserves_content
	test_static_transform_failure_preserves_content
	test_invalid_static_transform_preserves_content
	test_renderer_failure_after_migration_preserves_content
	test_final_replacement_failure_preserves_content
	test_malformed_markers_fail
	test_marker_topology_rejected "orphan-end"
	test_marker_topology_rejected "reversed"
	test_marker_topology_rejected "duplicate-start"
	test_marker_topology_rejected "joined-end-before-start"
	test_legacy_joined_marker_is_repaired
	test_successful_refresh
	test_unchanged_refresh_records_throttle
	test_push_failure_propagates
	test_unrelated_local_work_is_not_published "dirty-readme"
	test_unrelated_local_work_is_not_published "ahead-commit"
	test_unrelated_local_work_is_not_published "staged-file"
	test_renderer_failure_propagates

	printf 'Tests run: %d, failed: %d\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -ne 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"

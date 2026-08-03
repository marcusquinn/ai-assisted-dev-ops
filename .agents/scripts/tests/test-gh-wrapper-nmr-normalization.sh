#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Trusted-author creation-time NMR normalization regression coverage.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
SCRIPT_DIR="$(cd "${TEST_DIR}/.." && pwd)" || exit 1

# shellcheck source=../shared-gh-wrappers-create.sh
source "${SCRIPT_DIR}/shared-gh-wrappers-create.sh"

_gh_wrapper_args_have_label() {
	local expected="$1"
	shift
	local previous=""
	local arg=""
	for arg in "$@"; do
		if [[ "$previous" == "--label" && ",${arg}," == *",${expected},"* ]]; then
			return 0
		fi
		if [[ "$arg" == --label=* && ",${arg#--label=}," == *",${expected},"* ]]; then
			return 0
		fi
		previous="$arg"
	done
	return 1
}

_gh_extract_repo_from_args() {
	local previous=""
	local arg=""
	for arg in "$@"; do
		if [[ "$previous" == "--repo" ]]; then
			printf '%s\n' "$arg"
			return 0
		fi
		if [[ "$arg" == --repo=* ]]; then
			printf '%s\n' "${arg#--repo=}"
			return 0
		fi
		previous="$arg"
	done
	return 1
}

print_info() {
	return 0
}

print_warning() {
	return 0
}

CURRENT_WRITE_ALLOWED=1
_gh_current_user_allows_repo_write() {
	local repo_slug="$1"
	[[ -n "$repo_slug" ]] || return 1
	[[ "$CURRENT_WRITE_ALLOWED" -eq 1 ]] || return 1
	return 0
}

fail() {
	local message="$1"
	printf 'FAIL: %s\n' "$message" >&2
	exit 1
}

_gh_ci_prepare_trusted_nmr_labels --repo owner/repo \
	--label 'bug,needs-maintainer-review,auto-dispatch'
[[ "${_GH_CI_TRUST_NORMALIZED_ARGS[*]}" == *"bug,auto-dispatch"* ]] ||
	fail "trusted creator NMR did not normalize to dispatch intent"
[[ "${_GH_CI_TRUST_NORMALIZED_ARGS[*]}" != *"needs-maintainer-review"* \
	&& "${_GH_CI_TRUST_NORMALIZED_ARGS[*]}" != *"hold-for-review"* ]] ||
	fail "trusted creator NMR manufactured a review hold"

_gh_ci_prepare_trusted_nmr_labels --repo=owner/repo \
	--label='needs-maintainer-review,hold-for-review,bug'
[[ "${_GH_CI_TRUST_NORMALIZED_ARGS[*]}" == *"--label=hold-for-review,bug"* ]] ||
	fail "explicit hold-for-review was not preserved while trusted NMR cleared"

_gh_ci_prepare_trusted_nmr_labels --repo owner/repo \
	--label 'needs-maintainer-review'
[[ "${_GH_CI_TRUST_NORMALIZED_ARGS[*]}" == *"auto-dispatch"* \
	&& "${_GH_CI_TRUST_NORMALIZED_ARGS[*]}" != *"needs-maintainer-review"* ]] ||
	fail "legacy trusted NMR-only intent did not become auto-dispatch"

_gh_ci_prepare_trusted_nmr_labels --repo owner/repo \
	--label 'parent-task,needs-maintainer-review'
[[ "${_GH_CI_TRUST_NORMALIZED_ARGS[*]}" == *"parent-task"* \
	&& "${_GH_CI_TRUST_NORMALIZED_ARGS[*]}" != *"needs-maintainer-review"* \
	&& "${_GH_CI_TRUST_NORMALIZED_ARGS[*]}" != *"auto-dispatch"* ]] ||
	fail "parent tracker gained dispatch intent while trusted NMR cleared"

_gh_ci_prepare_trusted_nmr_labels --repo owner/repo \
	--label 'security,needs-maintainer-review'
[[ "${_GH_CI_TRUST_NORMALIZED_ARGS[*]}" == *"security,hold-for-review"* \
	&& "${_GH_CI_TRUST_NORMALIZED_ARGS[*]}" != *"needs-maintainer-review"* \
	&& "${_GH_CI_TRUST_NORMALIZED_ARGS[*]}" != *"auto-dispatch"* ]] ||
	fail "trusted security NMR did not become an explicit review hold"

_gh_ci_prepare_trusted_nmr_labels --repo owner/repo \
	--label 'security-review' --label 'needs-maintainer-review'
[[ "${_GH_CI_TRUST_NORMALIZED_ARGS[*]}" == *"--label security-review --label hold-for-review"* \
	&& "${_GH_CI_TRUST_NORMALIZED_ARGS[*]}" != *"needs-maintainer-review"* ]] ||
	fail "repeated-label security review NMR did not preserve its gate"

_gh_ci_prepare_trusted_nmr_labels --repo owner/repo \
	--label 'security,needs-credentials,needs-maintainer-review'
[[ "${_GH_CI_TRUST_NORMALIZED_ARGS[*]}" == *"security,needs-credentials,hold-for-review"* \
	&& "${_GH_CI_TRUST_NORMALIZED_ARGS[*]}" != *"needs-maintainer-review"* \
	&& "${_GH_CI_TRUST_NORMALIZED_ARGS[*]}" != *"auto-dispatch"* ]] ||
	fail "security NMR lost its hold when an independent blocker was present"

_gh_ci_prepare_trusted_nmr_labels --repo owner/repo \
	--label 'security-review,no-auto-dispatch,needs-maintainer-review'
[[ "${_GH_CI_TRUST_NORMALIZED_ARGS[*]}" == *"security-review,no-auto-dispatch,hold-for-review"* \
	&& "${_GH_CI_TRUST_NORMALIZED_ARGS[*]}" != *"needs-maintainer-review"* \
	&& "${_GH_CI_TRUST_NORMALIZED_ARGS[*]}" != *"hold-for-review,auto-dispatch"* ]] ||
	fail "security-review NMR lost its hold alongside no-auto-dispatch"

_gh_ci_prepare_trusted_nmr_labels --repo owner/repo \
	--label 'quality-debt,external-contributor,needs-maintainer-review'
[[ "${_GH_CI_TRUST_NORMALIZED_ARGS[*]}" == *"external-contributor,needs-maintainer-review"* ]] ||
	fail "external-origin authority gate was normalized as trusted self-review"

CURRENT_WRITE_ALLOWED=0
_gh_ci_prepare_trusted_nmr_labels --repo owner/repo \
	--label 'bug,needs-maintainer-review'
[[ "${_GH_CI_TRUST_NORMALIZED_ARGS[*]}" == *"bug,needs-maintainer-review"* ]] ||
	fail "unknown or external creator did not retain NMR"

printf 'PASS: trusted-author wrapper NMR normalization\n'

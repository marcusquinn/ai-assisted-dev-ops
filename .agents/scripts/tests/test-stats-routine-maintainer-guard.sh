#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENTS_SCRIPTS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

mkdir -p "${tmp_dir}/bin" "${tmp_dir}/repo-write" "${tmp_dir}/repo-maintain" "${tmp_dir}/logs"

cat >"${tmp_dir}/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail

if [[ "$1" == "auth" && "$2" == "status" ]]; then
	exit 0
fi

if [[ "$1" == "api" && "$2" == "user" ]]; then
	printf '%s\n' 'tester'
	exit 0
fi

if [[ "$1" == "api" && "$2" == repos/*/collaborators/tester/permission ]]; then
	case "$2" in
		repos/other/write/collaborators/tester/permission)
			printf '%s\n' 'write'
			;;
		repos/other/maintain/collaborators/tester/permission)
			printf '%s\n' 'maintain'
			;;
		*)
			printf '%s\n' '{"message":"not found"}' >&2
			exit 1
			;;
	esac
	exit 0
fi

exit 0
STUB
chmod +x "${tmp_dir}/bin/gh"

cat >"${tmp_dir}/repos.json" <<JSON
{
  "initialized_repos": [
    {"slug": "other/write", "path": "${tmp_dir}/repo-write", "pulse": true},
    {"slug": "other/maintain", "path": "${tmp_dir}/repo-maintain", "pulse": true}
  ]
}
JSON

export PATH="${tmp_dir}/bin:${PATH}"
export HOME="$tmp_dir"
export REPOS_JSON="${tmp_dir}/repos.json"
export LOGFILE="${tmp_dir}/logs/stats.log"
export QUALITY_SWEEP_INTERVAL=0
export QUALITY_SWEEP_LAST_RUN="${tmp_dir}/logs/quality-sweep-last-run"
export PERSON_STATS_LAST_RUN="${tmp_dir}/logs/person-stats-last-run"
export PERSON_STATS_CACHE_DIR="${tmp_dir}/logs"
export QUALITY_SWEEP_STATE_DIR="${tmp_dir}/logs/quality-sweep-state"

# stats-functions.sh submodules expect caller SCRIPT_DIR to be the scripts dir,
# matching stats-wrapper.sh production sourcing.
SCRIPT_DIR="$AGENTS_SCRIPTS_DIR"

# shellcheck source=../shared-constants.sh
source "${AGENTS_SCRIPTS_DIR}/shared-constants.sh"
# shellcheck source=../worker-lifecycle-common.sh
source "${AGENTS_SCRIPTS_DIR}/worker-lifecycle-common.sh"
# shellcheck source=../stats-functions.sh
source "${AGENTS_SCRIPTS_DIR}/stats-functions.sh"

called_file="${tmp_dir}/called"
_quality_sweep_for_repo() {
	local repo_slug="$1"
	local repo_path="$2"
	printf '%s|%s\n' "$repo_slug" "$repo_path" >>"$called_file"
	return 0
}

_gh_run_bounded_function() {
	local timeout_seconds="$1"
	shift
	[[ "$timeout_seconds" -gt 0 ]] || return 124
	"$@"
	return $?
}

run_daily_quality_sweep

if [[ ! -f "$called_file" ]]; then
	printf 'FAIL no eligible repo was swept\n'
	exit 1
fi

if grep -q '^other/write|' "$called_file"; then
	printf 'FAIL write-only collaborator repo was swept\n'
	exit 1
fi

if ! grep -q '^other/maintain|' "$called_file"; then
	printf 'FAIL maintain collaborator repo was not swept\n'
	exit 1
fi

resume_entries=$(_quality_sweep_resume_entries $'owner/one|/one\nowner/two|/two\nowner/three|/three' "owner/two")
if [[ "$resume_entries" != $'owner/three|/three\nowner/one|/one\nowner/two|/two' ]]; then
	printf 'FAIL quality sweep cursor does not resume after the last attempted repo\n'
	exit 1
fi

printf 'PASS stats routines require maintainer-equivalent access and resume bounded batches\n'

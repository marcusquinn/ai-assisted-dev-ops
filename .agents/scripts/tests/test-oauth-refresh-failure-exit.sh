#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="${SCRIPT_DIR}/../oauth-pool-helper.sh"
REAL_PYTHON="$(command -v python3)"
TEST_TMP_DIR=""

fail() {
	local message="$1"
	printf 'FAIL %s\n' "$message" >&2
	return 1
}

write_stub_python() {
	local bin_dir="$1"
	local mode="$2"
	mkdir -p "$bin_dir"
	cat >"${bin_dir}/python3" <<'PY'
#!/usr/bin/env bash
set -Eeuo pipefail
if [[ "${2:-}" == "refresh" && "$1" == *"oauth-pool-lib/pool_ops.py" ]]; then
	case "${AIDEVOPS_TEST_POOL_REFRESH_MODE:-none}" in
	  failed)
	    printf 'FAILED:test@example.invalid(http_401)\n'
	    exit 0
	    ;;
	  network)
	    printf 'FAILED:test@example.invalid(network)\n'
	    exit 0
	    ;;
	  http_500)
	    printf 'FAILED:test@example.invalid(http_500)\n'
	    exit 0
	    ;;
	  refreshed)
	    printf 'REFRESHED:test@example.invalid\n'
	    exit 0
	    ;;
	  mixed)
	    printf 'REFRESHED:other@example.invalid\nFAILED:test@example.invalid(network)\n'
	    exit 0
	    ;;
    none)
      printf 'NONE\n'
      exit 0
      ;;
  esac
fi
exec "${REAL_PYTHON}" "$@"
PY
	chmod +x "${bin_dir}/python3"
	if AIDEVOPS_TEST_POOL_REFRESH_MODE="$mode" PATH="${bin_dir}:$PATH" "$HELPER" refresh openai 2>&1; then
		return 0
	fi
	return 1
}

cleanup_test_tmp() {
	if [[ -n "${TEST_TMP_DIR:-}" ]]; then
		rm -rf "$TEST_TMP_DIR"
	fi
	return 0
}

main() {
	local tmp_dir
	tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/oauth-refresh-exit.XXXXXX")"
	TEST_TMP_DIR="$tmp_dir"
	trap cleanup_test_tmp EXIT

	local output rc
	set +e
	output="$(HOME="$tmp_dir" REAL_PYTHON="$REAL_PYTHON" write_stub_python "${tmp_dir}/bin-none" none)"
	rc=$?
	set -e
	[[ "$rc" -eq 0 ]] || fail "no-op refresh should exit 0, got ${rc}: ${output}"
	[[ "$output" == *"No openai accounts need refreshing"* ]] || fail "no-op refresh did not report NONE: ${output}"

	set +e
	output="$(HOME="$tmp_dir" REAL_PYTHON="$REAL_PYTHON" write_stub_python "${tmp_dir}/bin-failed" failed)"
	rc=$?
	set -e
	[[ "$rc" -ne 0 ]] || fail "failed refresh should exit non-zero"
	[[ "$output" == *"Failed to refresh: test@example.invalid(http_401)"* ]] || fail "failed refresh did not preserve safe label: ${output}"
	[[ "$output" != *"secret"* ]] || fail "failed refresh output leaked a token-like value: ${output}"

	set +e
	output="$(HOME="$tmp_dir" REAL_PYTHON="$REAL_PYTHON" write_stub_python "${tmp_dir}/bin-network" network)"
	rc=$?
	set -e
	[[ "$rc" -ne 0 ]] || fail "first network failure should exit non-zero"
	[[ "$output" == *"Failed to refresh: test@example.invalid(network)"* ]] || fail "first network failure was not visible: ${output}"

	set +e
	output="$(HOME="$tmp_dir" REAL_PYTHON="$REAL_PYTHON" write_stub_python "${tmp_dir}/bin-network" network)"
	rc=$?
	set -e
	[[ "$rc" -ne 0 ]] || fail "suppressed network failure should remain non-zero"
	[[ "$output" != *"Failed to refresh: test@example.invalid(network)"* ]] || fail "repeated network failure was not suppressed: ${output}"
	[[ "$output" != *"Some accounts failed to refresh"* ]] || fail "repeated re-auth hint was not suppressed: ${output}"

	set +e
	output="$(HOME="$tmp_dir" REAL_PYTHON="$REAL_PYTHON" write_stub_python "${tmp_dir}/bin-network" mixed)"
	rc=$?
	set -e
	[[ "$rc" -ne 0 ]] || fail "suppressed failure alongside a refresh should remain non-zero"
	[[ "$output" == *"Refreshed openai token for other@example.invalid"* ]] || fail "successful account was not reported: ${output}"

	set +e
	output="$(HOME="$tmp_dir" REAL_PYTHON="$REAL_PYTHON" write_stub_python "${tmp_dir}/bin-http-500" http_500)"
	rc=$?
	set -e
	[[ "$rc" -ne 0 ]] || fail "transient HTTP 500 should exit non-zero"
	[[ "$output" == *"Failed to refresh: test@example.invalid(http_500)"* ]] || fail "transient HTTP 500 was not visible: ${output}"

	output="$(HOME="$tmp_dir" REAL_PYTHON="$REAL_PYTHON" write_stub_python "${tmp_dir}/bin-network" refreshed)"
	[[ "$output" == *"Refreshed openai token for test@example.invalid"* ]] || fail "recovery was not visible: ${output}"
	[[ "$output" == *"after 2 suppressed repeated failure"* ]] || fail "recovery did not summarize suppressed failures: ${output}"

	printf 'PASS oauth refresh failures are suppressed and recovery stays visible\n'
	return 0
}

main "$@"

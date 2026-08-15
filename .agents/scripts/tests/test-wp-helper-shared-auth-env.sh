#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
WP_HELPER="${SCRIPT_DIR}/../wp-helper.sh"

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

cleanup_tmp_dir() {
	local tmp_dir="${TMP_DIR:-}"
	local tmp_base="${tmp_dir##*/}"

	if [[ -z "$tmp_dir" || ! -d "$tmp_dir" ]]; then
		return 0
	fi
	if [[ "$tmp_base" != aidevops-wp-shared-password.* ]]; then
		printf 'Refusing to remove unexpected temp directory: %s\n' "$tmp_dir" >&2
		return 1
	fi
	rm -rf "$tmp_dir"
	return 0
}

assert_result() {
	local name="$1"
	local rc="$2"
	local detail="${3:-}"

	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$rc" -eq 0 ]]; then
		TESTS_PASSED=$((TESTS_PASSED + 1))
		printf 'PASS %s\n' "$name"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		printf 'FAIL %s — %s\n' "$name" "$detail"
	fi
	return 0
}

run_site() {
	local site="$1"
	local password="${2:-}"
	local output_file="$3"

	HOME="${TMP_DIR}/home" \
		PATH="${TMP_DIR}/bin:${PATH}" \
		MOCK_SSHPASS_LOG="${TMP_DIR}/sshpass.log" \
		HOSTINGER_SSH_PASSWORD_ACCOUNT_1="$password" \
		"$WP_HELPER" "$site" core version >"$output_file" 2>&1
	return $?
}

TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/aidevops-wp-shared-password.XXXXXX") || exit 1
trap cleanup_tmp_dir EXIT
mkdir -p "${TMP_DIR}/home/.config/aidevops" "${TMP_DIR}/bin" || exit 1

cat >"${TMP_DIR}/home/.config/aidevops/wordpress-sites.json" <<'JSON'
{
  "servers": {
    "hostinger-account-1": {
      "type": "hostinger",
      "ssh_host": "ssh.example.com",
      "ssh_port": 65002,
      "ssh_user": "u123456789",
      "ssh_password_env": "HOSTINGER_SSH_PASSWORD_ACCOUNT_1"
    }
  },
  "sites": {
    "site-a": {
      "name": "Site A",
      "type": "hostinger",
      "server_ref": "hostinger-account-1",
      "wp_path": "/domains/site-a.example/public_html"
    },
    "site-b": {
      "name": "Site B",
      "type": "hostinger",
      "server_ref": "hostinger-account-1",
      "wp_path": "/domains/site-b.example/public_html"
    }
  }
}
JSON

cat >"${TMP_DIR}/bin/sshpass" <<'MOCK'
#!/usr/bin/env bash
printf 'password=%s\nargs=%s\n' "${SSHPASS:-}" "$*" >>"$MOCK_SSHPASS_LOG"
exit 0
MOCK
chmod 700 "${TMP_DIR}/bin/sshpass"

cat >"${TMP_DIR}/bin/ssh" <<'MOCK'
#!/usr/bin/env bash
if [[ "${1:-}" == "-G" ]]; then
	printf 'hostname ssh.example.com\nuser u123456789\nport 65002\nidentityfile ~/.ssh/id_rsa\n'
	exit 0
fi
printf 'Unexpected direct ssh invocation: %s\n' "$*" >&2
exit 1
MOCK
chmod 700 "${TMP_DIR}/bin/ssh"

output_file="${TMP_DIR}/site-a.out"
run_site site-a fixture-password "$output_file"
rc=$?
log=$(<"${TMP_DIR}/sshpass.log")
if [[ "$rc" -eq 0 && "$log" == *'password=fixture-password'* && "$log" == *'/domains/site-a.example/public_html'* ]]; then
	assert_result "uses account-level password environment reference" 0
else
	assert_result "uses account-level password environment reference" 1 "rc=${rc} log=${log}"
fi

: >"${TMP_DIR}/sshpass.log"
output_file="${TMP_DIR}/site-b.out"
run_site site-b fixture-password "$output_file"
rc=$?
log=$(<"${TMP_DIR}/sshpass.log")
if [[ "$rc" -eq 0 && "$log" == *'password=fixture-password'* && "$log" == *'/domains/site-b.example/public_html'* ]]; then
	assert_result "reuses one account credential for another site" 0
else
	assert_result "reuses one account credential for another site" 1 "rc=${rc} log=${log}"
fi

output_file="${TMP_DIR}/missing.out"
run_site site-a '' "$output_file"
rc=$?
output=$(<"$output_file")
if [[ "$rc" -ne 0 && "$output" == *'SSH password environment variable is not set'* ]]; then
	assert_result "fails safely when shared password is not injected" 0
else
	assert_result "fails safely when shared password is not injected" 1 "rc=${rc} output=${output}"
fi

printf '\nTests: %d run, %d passed, %d failed\n' "$TESTS_RUN" "$TESTS_PASSED" "$TESTS_FAILED"
[[ "$TESTS_FAILED" -eq 0 ]]

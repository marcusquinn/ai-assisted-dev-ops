#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d -t aidevops-signing-test.XXXXXX)"
TEST_HOME="${TEST_ROOT}/home"
FAKE_BIN="${TEST_ROOT}/bin"
CALL_LOG="${TEST_ROOT}/calls.log"
GIT_CALL_LOG="${TEST_ROOT}/git-calls.log"
PUBLIC_KEY='ssh-ed25519 AAAAC3NzaFixtureOnly aidevops-headless-signing'

cleanup() {
	rm -rf "$TEST_ROOT"
	return 0
}
trap cleanup EXIT

mkdir -p "${TEST_HOME}/.ssh" "$FAKE_BIN"
printf '%s\n' "$PUBLIC_KEY" >"${TEST_HOME}/.ssh/id_ed25519_signing.pub"
: >"${TEST_HOME}/.ssh/id_ed25519_signing"
printf 'export SSH_AUTH_SOCK=%q\nexport SSH_AGENT_PID=%q\n' \
	"${TEST_ROOT}/agent.sock" "12345" >"${TEST_HOME}/.ssh/agent.env"

cat >"${FAKE_BIN}/git" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${AIDEVOPS_SIGNING_TEST_GIT_CALL_LOG:?}"
case "$*" in
*gpg.format*) printf 'ssh\n' ;;
*user.signingkey*) printf '%s/.ssh/id_ed25519.pub\n' "$HOME" ;;
*user.email*) printf 'aidevops-test@example.invalid\n' ;;
*commit.gpgsign* | *tag.gpgsign*) printf 'true\n' ;;
esac
exit 0
EOF

cat >"${FAKE_BIN}/ssh-add" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${AIDEVOPS_SIGNING_TEST_CALL_LOG:?}"
case "${1:-}" in
-l) exit 0 ;;
-L)
	[[ "${SSH_AUTH_SOCK:-}" == "${AIDEVOPS_SIGNING_TEST_SOCKET:?}" ]] || exit 1
	printf '%s\n' "${AIDEVOPS_SIGNING_TEST_PUBLIC_KEY:?}"
	exit 0
	;;
*) exit 0 ;;
esac
EOF
chmod 700 "${FAKE_BIN}/git" "${FAKE_BIN}/ssh-add"

export AIDEVOPS_SIGNING_TEST_CALL_LOG="$CALL_LOG"
export AIDEVOPS_SIGNING_TEST_GIT_CALL_LOG="$GIT_CALL_LOG"
export AIDEVOPS_SIGNING_TEST_SOCKET="${TEST_ROOT}/agent.sock"
export AIDEVOPS_SIGNING_TEST_PUBLIC_KEY="$PUBLIC_KEY"

check_output=$(HOME="$TEST_HOME" PATH="${FAKE_BIN}:$PATH" \
	"${SCRIPT_DIR}/signing-setup.sh" check)
if [[ "$check_output" != *"[OK] Key is loaded in ssh-agent"* ]] || \
	[[ "$check_output" != *"Default Git signing key is separate from the headless worker key"* ]] || \
	[[ "$check_output" == *"Key not loaded in ssh-agent"* ]]; then
	printf 'FAIL check did not source agent.env and match the loaded public key\n%s\n' "$check_output"
	exit 1
fi

: >"$GIT_CALL_LOG"
headless_output=$(HOME="$TEST_HOME" PATH="${FAKE_BIN}:$PATH" \
	"${SCRIPT_DIR}/signing-setup.sh" headless-setup)
if [[ "$headless_output" != *"Preserved default interactive Git signing key"* ]] || \
	[[ "$headless_output" != *"process-scoped Git config"* ]]; then
	printf 'FAIL headless setup did not report separated key roles\n%s\n' "$headless_output"
	exit 1
fi
if grep -qF "config --global user.signingkey ${TEST_HOME}/.ssh/id_ed25519_signing.pub" "$GIT_CALL_LOG"; then
	printf 'FAIL headless setup replaced the global interactive signing key\n'
	exit 1
fi

: >"$CALL_LOG"
agent_output=$(HOME="$TEST_HOME" PATH="${FAKE_BIN}:$PATH" \
	"${SCRIPT_DIR}/signing-setup.sh" agent-start)
if [[ "$agent_output" != *"Signing key already loaded in ssh-agent"* ]]; then
	printf 'FAIL agent-start did not recognize the loaded signing key\n%s\n' "$agent_output"
	exit 1
fi
if grep -qF "${TEST_HOME}/.ssh/id_ed25519_signing" "$CALL_LOG"; then
	printf 'FAIL agent-start redundantly loaded an existing signing key\n'
	exit 1
fi

printf 'PASS signing check sources persisted agent state and matches public keys\n'
printf 'PASS agent-start avoids duplicate key loads\n'
printf 'PASS headless setup preserves the global interactive signing key\n'

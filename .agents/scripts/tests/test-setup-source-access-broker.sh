#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)" || exit 1
SOURCE_ACCESS_MODULE="${REPO_ROOT}/.agents/scripts/setup/modules/source-access.sh"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/aidevops-source-access-setup.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT

print_info() { return 0; }
print_success() { return 0; }
print_warning() {
	printf '%s\n' "$1"
	return 0
}

# shellcheck source=../setup/modules/source-access.sh
source "$SOURCE_ACCESS_MODULE"
production_release_signer_identity="$_SOURCE_ACCESS_RELEASE_SIGNER_IDENTITY"
production_release_signer_key="$_SOURCE_ACCESS_RELEASE_SIGNER_KEY"

fixture_repo="$TEST_DIR/repo"
mkdir -p "$fixture_repo/.agents/scripts/setup/modules"
git -C "$fixture_repo" init -q
git -C "$fixture_repo" config user.name "Setup Test"
git -C "$fixture_repo" config user.email "setup-test@example.invalid"
release_key="$TEST_DIR/release-signing-key"
untrusted_key="$TEST_DIR/untrusted-signing-key"
ssh-keygen -q -t ed25519 -N "" -C "setup-test-release" -f "$release_key"
ssh-keygen -q -t ed25519 -N "" -C "setup-test-untrusted" -f "$untrusted_key"
git -C "$fixture_repo" config gpg.format ssh
git -C "$fixture_repo" config user.signingkey "$release_key"
printf '1.2.3\n' >"$fixture_repo/VERSION"
printf 'core-v1\n' >"$fixture_repo/.agents/scripts/source_access_core.py"
printf 'helper-v1\n' >"$fixture_repo/.agents/scripts/source-access-helper.py"
cp "$SOURCE_ACCESS_MODULE" "$fixture_repo/.agents/scripts/setup/modules/source-access.sh"
git -C "$fixture_repo" add VERSION .agents/scripts/source_access_core.py \
	.agents/scripts/source-access-helper.py .agents/scripts/setup/modules/source-access.sh
git -C "$fixture_repo" -c commit.gpgsign=false commit -q -m "fixture release"
git -C "$fixture_repo" tag -s v1.2.3 -m "fixture tag"
IFS= read -r _SOURCE_ACCESS_RELEASE_SIGNER_KEY <"${release_key}.pub"
_SOURCE_ACCESS_RELEASE_SIGNER_KEY="${_SOURCE_ACCESS_RELEASE_SIGNER_KEY% setup-test-release}"
_SOURCE_ACCESS_RELEASE_SIGNER_IDENTITY="setup-test@example.invalid"

if ! grep -qF "readonly TRUSTED_EMAIL=\"${production_release_signer_identity}\"" \
	"$REPO_ROOT/.agents/scripts/signing-setup.sh" ||
	! grep -qF "readonly TRUSTED_KEY=\"${production_release_signer_key} " \
		"$REPO_ROOT/.agents/scripts/signing-setup.sh"; then
	printf 'FAIL: source-access release trust anchor drifted from signing-setup.sh\n' >&2
	exit 1
fi

expected_commit=$(git -C "$fixture_repo" rev-parse 'v1.2.3^{commit}')
resolved_commit=$(_source_access_release_commit "$fixture_repo")
if [[ "$resolved_commit" != "$expected_commit" ]]; then
	printf 'FAIL: source-access setup did not resolve the annotated release tag\n' >&2
	exit 1
fi
if ! _source_access_setup_source_current "$fixture_repo" "$resolved_commit"; then
	printf 'FAIL: signed setup source was not accepted\n' >&2
	exit 1
fi
printf '\n# tampered\n' >>"$fixture_repo/.agents/scripts/setup/modules/source-access.sh"
if _source_access_setup_source_current "$fixture_repo" "$resolved_commit"; then
	printf 'FAIL: setup source outside the signed release was accepted\n' >&2
	exit 1
fi
git -C "$fixture_repo" checkout -q -- .agents/scripts/setup/modules/source-access.sh

_SOURCE_ACCESS_BROKER_DIR="$TEST_DIR/broker"
mkdir -p "$_SOURCE_ACCESS_BROKER_DIR"
cp "$fixture_repo/.agents/scripts/source_access_core.py" "$_SOURCE_ACCESS_BROKER_DIR/source_access_core.py"
cp "$fixture_repo/.agents/scripts/source-access-helper.py" "$_SOURCE_ACCESS_BROKER_DIR/source-access-helper.py"
chmod 0777 "$_SOURCE_ACCESS_BROKER_DIR"
if _source_access_root_owned_mode "$_SOURCE_ACCESS_BROKER_DIR" 755 directory; then
	printf 'FAIL: unsafe broker directory mode was accepted\n' >&2
	exit 1
fi
chmod 0755 "$_SOURCE_ACCESS_BROKER_DIR"
_source_access_broker_metadata_current() { return 0; }
if ! _source_access_broker_current "$fixture_repo" "$resolved_commit"; then
	printf 'FAIL: exact signed-release broker bytes were not accepted\n' >&2
	exit 1
fi
printf 'tampered\n' >>"$_SOURCE_ACCESS_BROKER_DIR/source-access-helper.py"
if _source_access_broker_current "$fixture_repo" "$resolved_commit"; then
	printf 'FAIL: changed broker bytes were accepted\n' >&2
	exit 1
fi

trusted_release_key="$_SOURCE_ACCESS_RELEASE_SIGNER_KEY"
IFS= read -r _SOURCE_ACCESS_RELEASE_SIGNER_KEY <"${untrusted_key}.pub"
_SOURCE_ACCESS_RELEASE_SIGNER_KEY="${_SOURCE_ACCESS_RELEASE_SIGNER_KEY% setup-test-untrusted}"
if _source_access_release_commit "$fixture_repo" >/dev/null 2>&1; then
	printf 'FAIL: unverified release tag was accepted\n' >&2
	exit 1
fi
_SOURCE_ACCESS_RELEASE_SIGNER_KEY="$trusted_release_key"

rm -rf "$_SOURCE_ACCESS_BROKER_DIR"
INSTALL_DIR="$fixture_repo"
_source_access_install_target_safe() { return 0; }
_source_access_acquire_privilege() { return 2; }
setup_rc=0
setup_output=$(setup_source_access_broker 2>&1) || setup_rc=$?
if [[ "$setup_rc" -ne 2 || "$setup_output" != *"run aidevops update from an interactive terminal"* ]]; then
	printf 'FAIL: headless setup did not defer safely to the standard update command\n' >&2
	exit 1
fi

# shellcheck disable=SC2016  # The setup source expression is intentionally literal.
if ! grep -qF 'source "${SETUP_IMPL_MODULES_DIR}/source-access.sh"' "$REPO_ROOT/setup.sh"; then
	printf 'FAIL: setup.sh does not source the broker provisioning module\n' >&2
	exit 1
fi
setup_calls=$(grep -c 'setup_source_access_broker_nonfatal' "$REPO_ROOT/setup.sh" 2>/dev/null || true)
[[ "$setup_calls" =~ ^[0-9]+$ ]] || setup_calls=0
if [[ "$setup_calls" -lt 2 ]]; then
	printf 'FAIL: broker provisioning is not wired into both setup paths\n' >&2
	exit 1
fi
if ! grep -qF '_run_update_source_access_reconciliation' "$REPO_ROOT/aidevops.sh"; then
	printf 'FAIL: aidevops update does not reconcile source-access provisioning\n' >&2
	exit 1
fi
if ! grep -qF 'SETUP_EXPLICIT_NON_INTERACTIVE' "$REPO_ROOT/setup.sh" ||
	grep -qF 'AIDEVOPS_SOURCE_ACCESS_INTERACTIVE=true _setup_run_non_interactive' "$REPO_ROOT/setup.sh"; then
	printf 'FAIL: non-interactive setup can expose a hidden source-access prompt\n' >&2
	exit 1
fi
if ! grep -qF 'AIDEVOPS_NON_INTERACTIVE' "$REPO_ROOT/aidevops.sh"; then
	printf 'FAIL: aidevops update does not honor explicit non-interactive mode\n' >&2
	exit 1
fi

mkdir -p "$_SOURCE_ACCESS_BROKER_DIR"
unsafe_fifo="$_SOURCE_ACCESS_BROKER_DIR/unsafe-trust-fifo"
mkfifo "$unsafe_fifo"
_source_access_path_identity() {
	local path="$1"

	: "$path"
	printf '0:644\n'
	return 0
}
if _source_access_root_owned_mode "$unsafe_fifo" 644 file; then
	printf 'FAIL: root-owned FIFO was accepted as a regular trust file\n' >&2
	exit 1
fi
trust_public_key='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestSourceAccessTrustBinding'
printf '%s\n' "$trust_public_key" >"$_SOURCE_ACCESS_BROKER_DIR/source-access.pub"
printf 'schema=aidevops-source-access-trust/v1\nkey_source=dedicated\npublic_key=%s\n' \
	"$trust_public_key" >"$_SOURCE_ACCESS_BROKER_DIR/source-access.trust"
_source_access_root_owned_mode() {
	local path="$1"
	local expected_mode="$2"
	local expected_kind="$3"

	case "${path}:${expected_mode}:${expected_kind}" in
	"${_SOURCE_ACCESS_BROKER_DIR}:755:directory" | \
		"${_SOURCE_ACCESS_BROKER_DIR}/source-access.pub:644:file" | \
		"${_SOURCE_ACCESS_BROKER_DIR}/source-access.trust:644:file")
		return 0
		;;
	esac
	return 1
}
if ! _source_access_trust_current; then
	printf 'FAIL: valid root-attested source-access trust marker was rejected\n' >&2
	exit 1
fi
printf 'ssh-ed25519 AAAATamperedPublicKey\n' >"$_SOURCE_ACCESS_BROKER_DIR/source-access.pub"
if _source_access_trust_current; then
	printf 'FAIL: source-access public key mismatch was accepted\n' >&2
	exit 1
fi
printf '%s\n' "$trust_public_key" >"$_SOURCE_ACCESS_BROKER_DIR/source-access.pub"
printf 'schema=aidevops-source-access-trust/v1\nkey_source=existing-approval\npublic_key=%s\n' \
	"$trust_public_key" >"$_SOURCE_ACCESS_BROKER_DIR/source-access.trust"
if _source_access_trust_current; then
	printf 'FAIL: non-dedicated source-access trust key was accepted\n' >&2
	exit 1
fi
printf 'schema=aidevops-source-access-trust/v1\nkey_source=dedicated\npublic_key=%s\nextra=true\n' \
	"$trust_public_key" >"$_SOURCE_ACCESS_BROKER_DIR/source-access.trust"
if _source_access_trust_current; then
	printf 'FAIL: source-access trust marker with trailing data was accepted\n' >&2
	exit 1
fi

printf 'schema=aidevops-source-access-trust/v1\nkey_source=dedicated\npublic_key=%s\n' \
	"$trust_public_key" >"$_SOURCE_ACCESS_BROKER_DIR/source-access.trust"
trust_check_calls=0
acquire_calls=0
_source_access_release_commit() {
	local repo_root="$1"

	: "$repo_root"
	printf '0123456789abcdef0123456789abcdef01234567\n'
	return 0
}
_source_access_setup_source_current() { return 0; }
_source_access_install_target_safe() { return 0; }
_source_access_broker_current() { return 0; }
_source_access_privilege_cached() { return 0; }
_source_access_acquire_privilege() {
	acquire_calls=$((acquire_calls + 1))
	return 0
}
_source_access_privileged() {
	local argument=""
	local final_argument=""

	for argument in "$@"; do
		final_argument="$argument"
	done
	if [[ "$final_argument" == "trust-check" ]]; then
		trust_check_calls=$((trust_check_calls + 1))
		return 0
	fi
	return 1
}
INSTALL_DIR="$fixture_repo"
if ! setup_source_access_broker; then
	printf 'FAIL: cached-sudo fast path rejected valid privileged trust\n' >&2
	exit 1
fi
if [[ "$trust_check_calls" -ne 1 || "$acquire_calls" -ne 0 ]]; then
	printf 'FAIL: cached-sudo fast path skipped privileged trust validation\n' >&2
	exit 1
fi

_source_access_privilege_cached() { return 1; }
_source_access_privileged() {
	trust_check_calls=$((trust_check_calls + 1))
	return 1
}
trust_check_calls=0
acquire_calls=0
if ! setup_source_access_broker; then
	printf 'FAIL: valid root-attested trust required uncached sudo\n' >&2
	exit 1
fi
if [[ "$trust_check_calls" -ne 0 || "$acquire_calls" -ne 0 ]]; then
	printf 'FAIL: no-cached-sudo fast path attempted privileged reconciliation\n' >&2
	exit 1
fi

_source_access_privilege_cached() { return 0; }
trust_check_calls=0
acquire_calls=0
setup_rc=0
setup_source_access_broker >/dev/null 2>&1 || setup_rc=$?
if [[ "$setup_rc" -ne 2 || "$acquire_calls" -ne 1 || "$trust_check_calls" -ne 2 ]]; then
	printf 'FAIL: cached-sudo trust mismatch was accepted by the setup fast path\n' >&2
	exit 1
fi

printf 'PASS: setup provisions exact signed-release broker bytes and defers safely without a TTY\n'

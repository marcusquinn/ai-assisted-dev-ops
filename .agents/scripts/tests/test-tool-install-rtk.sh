#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TOOL_INSTALL="$REPO_ROOT/.agents/scripts/setup/modules/tool-install.sh"
RTK_READINESS="$REPO_ROOT/.agents/scripts/rtk-readiness.sh"

SANDBOX="$(mktemp -d -t tool-install-rtk-XXXXXX)"
trap 'rm -rf "$SANDBOX"' EXIT

mkdir -p "$SANDBOX/bin" "$SANDBOX/home"
export HOME="$SANDBOX/home"
export PATH="$SANDBOX/bin:$PATH"

PASS=0
FAIL=0

assert_eq() {
	local desc="$1" expected="$2" actual="$3"
	if [[ "$expected" == "$actual" ]]; then
		echo "  PASS: $desc"
		PASS=$((PASS + 1))
		return 0
	fi
	echo "  FAIL: $desc -- expected '$expected', got '$actual'" >&2
	FAIL=$((FAIL + 1))
	return 1
}

extract_functions() {
	awk '
		/^_setup_rtk_installed_version\(\)/, /^}$/ { print; next }
		/^_setup_rtk_install_supported_version\(\)/, /^}$/ { print; next }
		/^_setup_rtk_print_manual_install\(\)/, /^}$/ { print; next }
		/^_setup_rtk_offer_supported_upgrade\(\)/, /^}$/ { print; next }
		/^_setup_rtk_report_upgrade_result\(\)/, /^}$/ { print; next }
		/^setup_rtk\(\)/, /^}$/ { print; next }
	' "$TOOL_INSTALL" >"$SANDBOX/extract.sh"
	if ! grep -q '^_setup_rtk_offer_supported_upgrade()' "$SANDBOX/extract.sh"; then
		echo "FAIL: extraction did not capture rtk upgrade helpers" >&2
		exit 1
	fi
	return 0
}

source_extracted() {
	# shellcheck disable=SC2317
	print_info() {
		echo "INFO: $*"
		return 0
	}
	# shellcheck disable=SC2317
	print_success() {
		echo "OK: $*"
		return 0
	}
	# shellcheck disable=SC2317
	print_warning() {
		echo "WARN: $*"
		return 0
	}
	# shellcheck disable=SC2317
	setup_prompt() {
		local var_name="$1"
		local prompt_text="$2"
		local default_value="$3"
		: "$prompt_text"
		printf -v "$var_name" '%s' "$default_value"
		return 0
	}
	# shellcheck disable=SC2317
	run_with_spinner() {
		shift
		"$@"
		return $?
	}
	# shellcheck disable=SC2317
	verified_install() {
		local tool_name="$1"
		local installer_url="$2"
		: "$tool_name" "$installer_url"
		cat >"$SANDBOX/bin/rtk" <<'INNER_EOF'
#!/usr/bin/env bash
[[ "${1:-}" == "--version" ]] && echo "rtk 0.41.0"
INNER_EOF
		chmod +x "$SANDBOX/bin/rtk"
		return 0
	}
	# shellcheck source=../rtk-readiness.sh
	source "$RTK_READINESS"
	# shellcheck disable=SC1090
	source "$SANDBOX/extract.sh"
	return 0
}

write_mock_rtk() {
	cat >"$SANDBOX/bin/rtk" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == "--version" ]] && printf '%s\n' "${MOCK_RTK_VERSION_OUTPUT:-rtk 0.41.0}"
EOF
	chmod +x "$SANDBOX/bin/rtk"
	return 0
}

extract_functions

export MOCK_RTK_VERSION_OUTPUT="rtk 0.40.0"
write_mock_rtk
cat >"$SANDBOX/bin/brew" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$SANDBOX/bin/brew"

(
	source_extracted
	setup_rtk
) >"$SANDBOX/out" 2>&1

assert_eq "existing mismatched rtk is upgraded" "rtk 0.41.0" "$(rtk --version)"
assert_eq "setup reports matching version" "1" "$(grep -c 'rtk now matches the aidevops-tested version' "$SANDBOX/out")"

export MOCK_RTK_VERSION_OUTPUT="rtk 0.46.0"
write_mock_rtk
(
	source_extracted
	setup_rtk
) >"$SANDBOX/newer-out" 2>&1
assert_eq "newer rtk is retained" "rtk 0.46.0" "$(rtk --version)"
assert_eq "newer rtk is reported without an upgrade loop" "1" "$(grep -c 'newer than the aidevops-tested baseline v0.41.0; leaving the installed version unchanged' "$SANDBOX/newer-out")"

export MOCK_RTK_VERSION_OUTPUT="rtk development build"
write_mock_rtk
(
	source_extracted
	setup_rtk
) >"$SANDBOX/unknown-out" 2>&1
assert_eq "malformed rtk output is retained" "rtk development build" "$(rtk --version)"
assert_eq "malformed rtk output reports unknown readiness" "1" "$(grep -c 'version could not be determined; leaving the optional tool unchanged' "$SANDBOX/unknown-out")"

manual_upgrade_hint=$(
	source_extracted
	_setup_rtk_print_manual_install "https://example.invalid/install.sh" "upgrade"
)
manual_install_hint=$(
	source_extracted
	_setup_rtk_print_manual_install "https://example.invalid/install.sh" "install"
)

assert_eq "manual upgrade hint uses brew upgrade" "  Manual install: brew upgrade rtk  OR  curl -fsSL https://example.invalid/install.sh | sh" "$manual_upgrade_hint"
assert_eq "manual install hint uses brew install" "  Manual install: brew install rtk  OR  curl -fsSL https://example.invalid/install.sh | sh" "$manual_install_hint"

if [[ "$FAIL" -gt 0 ]]; then
	echo "FAIL: $FAIL rtk setup checks failed" >&2
	exit 1
fi

echo "PASS: $PASS rtk setup checks passed"
exit 0

#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Regression tests for approval-helper.sh sudo gh authentication recovery.
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)" || exit 1
PARENT_DIR="${SCRIPT_DIR}/.."

PASS=0
FAIL=0
LAST_OUTPUT=""
LAST_RC=0

pass() {
	local name="$1"
	printf '  PASS: %s\n' "$name"
	PASS=$((PASS + 1))
	return 0
}

fail() {
	local name="$1"
	local detail="${2:-}"
	printf '  FAIL: %s\n' "$name"
	if [[ -n "$detail" ]]; then
		printf '    %s\n' "$detail"
	fi
	FAIL=$((FAIL + 1))
	return 0
}

assert_eq() {
	local name="$1"
	local expected="$2"
	local actual="$3"
	if [[ "$expected" == "$actual" ]]; then
		pass "$name"
	else
		fail "$name" "expected '${expected}', got '${actual}'"
	fi
	return 0
}

assert_contains() {
	local name="$1"
	local haystack="$2"
	local needle="$3"
	if [[ "$haystack" == *"$needle"* ]]; then
		pass "$name"
	else
		fail "$name" "missing '${needle}'"
	fi
	return 0
}

assert_not_contains() {
	local name="$1"
	local haystack="$2"
	local needle="$3"
	if [[ "$haystack" != *"$needle"* ]]; then
		pass "$name"
	else
		fail "$name" "unexpected '${needle}'"
	fi
	return 0
}

run_case() {
	local name="$1"
	local script="$2"
	local expected_rc="$3"
	local output=""
	local rc=0

	output=$(APPROVAL_HELPER_UNDER_TEST="$PARENT_DIR/approval-helper.sh" bash -c "$script" 2>&1) || rc=$?
	LAST_OUTPUT="$output"
	LAST_RC=$rc
	assert_eq "$name rc" "$expected_rc" "$rc"
	return 0
}

printf 'Test: approval-helper sudo gh auth recovery\n'
printf '===========================================\n\n'

# shellcheck disable=SC2016  # literal script is evaluated in the child bash.
run_case "macOS real home resolves through dscl under sudo" '
	set -uo pipefail
	export SUDO_USER=alice
	export HOME=/var/root
	id() {
		local arg1="${1:-}"
		local arg2="${2:-}"
		if [[ "$arg1" == "-u" && -z "$arg2" ]]; then printf "0"; return 0; fi
		if [[ "$arg1" == "-u" && "$arg2" == "alice" ]]; then printf "501"; return 0; fi
		return 1
	}
	getent() { return 1; }
	dscl() { printf "NFSHomeDirectory: /Users/alice\n"; return 0; }
	# shellcheck disable=SC1090
	source "$APPROVAL_HELPER_UNDER_TEST" >/dev/null 2>&1
	[[ "$_APPROVAL_HOME" == "/Users/alice" ]]
' 0

# shellcheck disable=SC2016  # literal script is evaluated in the child bash.
run_case "sudo gh auth recovers token from invoking macOS user session" '
	set -uo pipefail
	export SUDO_USER=alice
	export HOME=/var/root
	id() {
		local arg1="${1:-}"
		local arg2="${2:-}"
		if [[ "$arg1" == "-u" && -z "$arg2" ]]; then printf "0"; return 0; fi
		if [[ "$arg1" == "-u" && "$arg2" == "alice" ]]; then printf "501"; return 0; fi
		return 1
	}
	getent() { return 1; }
	dscl() { printf "NFSHomeDirectory: /Users/alice\n"; return 0; }
	launchctl() { printf "mac-user-token"; return 0; }
	sudo() { return 1; }
	gh() {
		local arg1="${1:-}"
		local arg2="${2:-}"
		if [[ "$arg1" == "auth" && "$arg2" == "status" && "${GH_TOKEN:-}" == "mac-user-token" ]]; then return 0; fi
		return 1
	}
	# shellcheck disable=SC1090
	source "$APPROVAL_HELPER_UNDER_TEST" >/dev/null 2>&1
	_require_gh_auth
' 0
assert_not_contains "recovered token is not printed" "$LAST_OUTPUT" "mac-user-token"

# shellcheck disable=SC2016  # literal script is evaluated in the child bash.
run_case "sudo gh auth recovery uses absolute gh binary when sudo path is restricted" '
	set -uo pipefail
	export SUDO_USER=alice
	export HOME=/var/root
	tmpdir=$(mktemp -d)
	trap '\''rm -rf "$tmpdir"'\'' EXIT
	printf '\''#!/usr/bin/env bash\nif [[ "$1 $2" == "auth token" ]]; then printf path-token; exit 0; fi\nexit 1\n'\'' >"$tmpdir/gh"
	chmod +x "$tmpdir/gh"
	export PATH="$tmpdir:$PATH"
	id() {
		local arg1="${1:-}"
		local arg2="${2:-}"
		if [[ "$arg1" == "-u" && -z "$arg2" ]]; then printf "0"; return 0; fi
		if [[ "$arg1" == "-u" && "$arg2" == "alice" ]]; then printf "501"; return 0; fi
		return 1
	}
	getent() { return 1; }
	dscl() { printf "NFSHomeDirectory: /Users/alice\n"; return 0; }
	launchctl() {
		if [[ "$#" -ge 8 ]]; then
			shift 8
			if [[ "${1:-}" == "$tmpdir/gh" && "${2:-}" == "auth" && "${3:-}" == "token" ]]; then
				"$@"
				return $?
			fi
		fi
		return 1
	}
	sudo() { return 1; }
	gh() {
		local arg1="${1:-}"
		local arg2="${2:-}"
		if [[ "$arg1" == "auth" && "$arg2" == "status" && "${GH_TOKEN:-}" == "path-token" ]]; then return 0; fi
		return 1
	}
	# shellcheck disable=SC1090
	source "$APPROVAL_HELPER_UNDER_TEST" >/dev/null 2>&1
	_require_gh_auth
' 0
assert_not_contains "absolute path recovered token is not printed" "$LAST_OUTPUT" "path-token"

# shellcheck disable=SC2016  # literal script is evaluated in the child bash.
run_case "sudo gh auth recovery works through the aidevops gh shim" '
	set -uo pipefail
	export SUDO_USER=alice
	export HOME=/var/root
	fixture_root=$(mktemp -d)
	trap '\''rm -rf "$fixture_root"'\'' EXIT
	helper_dir=${APPROVAL_HELPER_UNDER_TEST%/*}
	shim_dir="$fixture_root/shim"
	native_dir="$fixture_root/native"
	mkdir -p "$shim_dir" "$native_dir"
	for module in gh gh-native-transport-lib.sh gh-api-guards-lib.sh gh-write-policy-lib.sh gh-api-instrument.sh gh-rest-pagination-lib.sh; do
		cp "$helper_dir/$module" "$shim_dir/$module"
	done
	chmod +x "$shim_dir/gh"
	printf '\''#!/usr/bin/env bash\nif [[ "${1:-}:${2:-}" == "auth:token" ]]; then printf integrated-shim-token; exit 0; fi\nexit 1\n'\'' >"$native_dir/gh"
	chmod +x "$native_dir/gh"
	export PATH="$shim_dir:$native_dir:/usr/bin:/bin"
	export AIDEVOPS_GH_API_LOG="$fixture_root/api.log"
	id() {
		local arg1="${1:-}"
		local arg2="${2:-}"
		if [[ "$arg1" == "-u" && -z "$arg2" ]]; then printf "0"; return 0; fi
		if [[ "$arg1" == "-u" && "$arg2" == "alice" ]]; then printf "501"; return 0; fi
		return 1
	}
	getent() { return 1; }
	dscl() { printf "NFSHomeDirectory: /Users/alice\n"; return 0; }
	launchctl() {
		local arg1="${1:-}"
		local arg2="${2:-}"
		if [[ "$arg1" == "asuser" && "$arg2" == "501" && "$#" -ge 11 ]]; then
			shift 8
			"$@"
			return $?
		fi
		return 1
	}
	sudo() { return 1; }
	gh() {
		local arg1="${1:-}"
		local arg2="${2:-}"
		if [[ "$arg1" == "auth" && "$arg2" == "status" && "${GH_TOKEN:-}" == "integrated-shim-token" ]]; then return 0; fi
		return 1
	}
	# shellcheck disable=SC1090
	source "$APPROVAL_HELPER_UNDER_TEST" >/dev/null 2>&1
	_require_gh_auth && [[ ! -e "$AIDEVOPS_GH_API_LOG" ]]
' 0
assert_not_contains "integrated shim recovered token is not printed" "$LAST_OUTPUT" "integrated-shim-token"

# shellcheck disable=SC2016  # literal script is evaluated in the child bash.
run_case "sudo gh auth failure reports recovery failure without token leakage" '
	set -uo pipefail
	export SUDO_USER=alice
	export HOME=/var/root
	id() {
		local arg1="${1:-}"
		local arg2="${2:-}"
		if [[ "$arg1" == "-u" && -z "$arg2" ]]; then printf "0"; return 0; fi
		if [[ "$arg1" == "-u" && "$arg2" == "alice" ]]; then printf "501"; return 0; fi
		return 1
	}
	getent() { return 1; }
	dscl() { printf "NFSHomeDirectory: /Users/alice\n"; return 0; }
	launchctl() { printf "bad-token"; return 0; }
	sudo() { return 1; }
	gh() { return 1; }
	# shellcheck disable=SC1090
	source "$APPROVAL_HELPER_UNDER_TEST" >/dev/null 2>&1
	_require_gh_auth
' 1
assert_contains "auth failure explains automatic recovery" "$LAST_OUTPUT" "automatic recovery from the invoking user's gh auth failed"
assert_not_contains "failed token is not printed" "$LAST_OUTPUT" "bad-token"

printf '\n===========================================\n'
printf 'Results: %s passed, %s failed\n' "$PASS" "$FAIL"

if [[ $FAIL -gt 0 ]]; then
	exit 1
fi
exit 0

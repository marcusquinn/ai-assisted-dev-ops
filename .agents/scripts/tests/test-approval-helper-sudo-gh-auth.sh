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
run_case "sudo gh auth accepts a successful API probe after transient auth status failure" '
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
	launchctl() { printf "transient-status-token"; return 0; }
	sudo() { return 1; }
	gh() {
		local arg1="${1:-}"
		local arg2="${2:-}"
		local arg3="${3:-}"
		local arg4="${4:-}"
		if [[ "$arg1" == "auth" && "$arg2" == "status" ]]; then return 1; fi
		if [[ "$arg1" == "api" && "$arg2" == "user" && "$arg3" == "--include" && "$arg4" == "--silent" ]]; then
			[[ "${GH_TOKEN:-}" == "transient-status-token" ]] || return 1
			printf "HTTP/2.0 200 OK\r\n"
			printf "X-RateLimit-Remaining: 4999\r\n"
			printf "X-RateLimit-Resource: core\r\n\r\n"
			return 0
		fi
		return 1
	}
	# shellcheck disable=SC1090
	source "$APPROVAL_HELPER_UNDER_TEST" >/dev/null 2>&1
	_require_gh_auth
' 0
assert_not_contains "transient status recovered token is not printed" "$LAST_OUTPUT" "transient-status-token"
assert_not_contains "transient status does not report sudo recovery failure" "$LAST_OUTPUT" "automatic recovery from the invoking user's gh auth failed"

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
run_case "sudo gh auth diagnoses core exhaustion through the aidevops gh shim" '
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
	printf '\''#!/usr/bin/env bash\nif [[ "${1:-}:${2:-}" == "auth:token" ]]; then printf integrated-exhausted-token; exit 0; fi\nif [[ "${1:-}:${2:-}" == "auth:status" ]]; then exit 1; fi\nif [[ "${1:-}:${2:-}:${3:-}:${4:-}" == "api:user:--include:--silent" ]]; then\n  printf "HTTP/2.0 403 Forbidden\\r\\n"\n  printf "X-RateLimit-Remaining: 0\\r\\n"\n  printf "X-RateLimit-Reset: 1785697847\\r\\n"\n  printf "X-RateLimit-Resource: core\\r\\n\\r\\n"\n  exit 1\nfi\nif [[ "${1:-}:${2:-}" == "api:rate_limit" ]]; then printf "4652\\t1785700000\\n"; exit 0; fi\nexit 1\n'\'' >"$native_dir/gh"
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
	# shellcheck disable=SC1090
	source "$APPROVAL_HELPER_UNDER_TEST" >/dev/null 2>&1
	auth_rc=0
	_require_gh_auth || auth_rc=$?
	[[ "$auth_rc" -eq 1 ]]
' 0
assert_contains "integrated shim core exhaustion is diagnosed" "$LAST_OUTPUT" "GitHub core API rate limit is exhausted"
assert_contains "integrated shim diagnosis reports reset epoch" "$LAST_OUTPUT" "1785697847"
assert_not_contains "integrated shim diagnosis avoids generic auth failure" "$LAST_OUTPUT" "automatic recovery from the invoking user's gh auth failed"
assert_not_contains "integrated exhausted token is not printed" "$LAST_OUTPUT" "integrated-exhausted-token"

# shellcheck disable=SC2016  # literal script is evaluated in the child bash.
run_case "sudo gh auth trusts failed user response over stale rate-limit endpoint" '
	set -uo pipefail
	export SUDO_USER=alice
	export HOME=/var/root
	probe_log=$(mktemp)
	trap '\''rm -f "$probe_log"'\'' EXIT
	id() {
		local arg1="${1:-}"
		local arg2="${2:-}"
		if [[ "$arg1" == "-u" && -z "$arg2" ]]; then printf "0"; return 0; fi
		if [[ "$arg1" == "-u" && "$arg2" == "alice" ]]; then printf "501"; return 0; fi
		return 1
	}
	getent() { return 1; }
	dscl() { printf "NFSHomeDirectory: /Users/alice\n"; return 0; }
	launchctl() { printf "exhausted-user-token"; return 0; }
	sudo() { return 1; }
	gh() {
		local arg1="${1:-}"
		local arg2="${2:-}"
		local arg3="${3:-}"
		local arg4="${4:-}"
		if [[ "$arg1" == "auth" && "$arg2" == "status" ]]; then return 1; fi
		if [[ "$arg1" == "api" && "$arg2" == "user" && "$arg3" == "--include" && "$arg4" == "--silent" ]]; then
			printf "%s\n" "$*" >"$probe_log"
			[[ "${GH_TOKEN:-}" == "exhausted-user-token" ]] || return 1
			printf "HTTP/2.0 403 Forbidden\r\n"
			printf "X-RateLimit-Remaining: 0\r\n"
			printf "X-RateLimit-Reset: 1785697847\r\n"
			printf "X-RateLimit-Resource: core\r\n\r\n"
			printf "{\"message\":\"API rate limit exceeded\"}\n"
			return 1
		fi
		if [[ "$arg1" == "api" && "$arg2" == "rate_limit" ]]; then
			printf "%s\n" "$*" >"$probe_log"
			printf "4652\t1785700000\n"
			return 0
		fi
		return 1
	}
	# shellcheck disable=SC1090
	source "$APPROVAL_HELPER_UNDER_TEST" >/dev/null 2>&1
	auth_rc=0
	_require_gh_auth || auth_rc=$?
	[[ "$auth_rc" -eq 1 ]] || exit 1
	[[ "$(<"$probe_log")" == "api user --include --silent" ]]
' 0
assert_contains "core exhaustion is diagnosed" "$LAST_OUTPUT" "GitHub core API rate limit is exhausted"
assert_contains "core exhaustion reports reset epoch" "$LAST_OUTPUT" "1785697847"
assert_contains "core exhaustion explains credentials cannot repair quota" "$LAST_OUTPUT" "Re-authentication or forwarding GH_TOKEN will not help before reset"
assert_not_contains "core exhaustion does not report generic auth recovery failure" "$LAST_OUTPUT" "automatic recovery from the invoking user's gh auth failed"
assert_not_contains "exhausted recovered token is not printed" "$LAST_OUTPUT" "exhausted-user-token"
assert_not_contains "failed user response body is not printed" "$LAST_OUTPUT" "API rate limit exceeded"

# shellcheck disable=SC2016  # literal script is evaluated in the child bash.
run_case "sudo gh auth diagnoses HTTP 429 core exhaustion" '
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
	launchctl() { printf "429-user-token"; return 0; }
	sudo() { return 1; }
	gh() {
		local arg1="${1:-}"
		local arg2="${2:-}"
		if [[ "$arg1" == "auth" && "$arg2" == "status" ]]; then return 1; fi
		if [[ "$arg1" == "api" && "$arg2" == "user" ]]; then
			printf "HTTP/2.0 429 Too Many Requests\r\n"
			printf "X-RateLimit-Remaining: 0\r\n"
			printf "X-RateLimit-Reset: 1785697848\r\n"
			printf "X-RateLimit-Resource: core\r\n\r\n"
			return 1
		fi
		return 1
	}
	# shellcheck disable=SC1090
	source "$APPROVAL_HELPER_UNDER_TEST" >/dev/null 2>&1
	_require_gh_auth
' 1
assert_contains "HTTP 429 core exhaustion is diagnosed" "$LAST_OUTPUT" "GitHub core API rate limit is exhausted"
assert_contains "HTTP 429 core exhaustion reports reset epoch" "$LAST_OUTPUT" "1785697848"
assert_not_contains "HTTP 429 exhausted token is not printed" "$LAST_OUTPUT" "429-user-token"

# shellcheck disable=SC2016  # literal script is evaluated in the child bash.
run_case "sudo gh auth ignores stale quota headers across response frames" '
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
	launchctl() { printf "multi-frame-token"; return 0; }
	sudo() { return 1; }
	gh() {
		local arg1="${1:-}"
		local arg2="${2:-}"
		if [[ "$arg1" == "auth" && "$arg2" == "status" ]]; then return 1; fi
		if [[ "$arg1" == "api" && "$arg2" == "user" ]]; then
			printf "HTTP/2.0 403 Forbidden\r\n"
			printf "X-RateLimit-Remaining: 0\r\n"
			printf "X-RateLimit-Reset: 1785697849\r\n"
			printf "X-RateLimit-Resource: core\r\n\r\n"
			printf "HTTP/2.0 429 Too Many Requests\r\n\r\n"
			return 1
		fi
		return 1
	}
	# shellcheck disable=SC1090
	source "$APPROVAL_HELPER_UNDER_TEST" >/dev/null 2>&1
	_require_gh_auth
' 1
assert_contains "multi-frame response preserves generic auth failure" "$LAST_OUTPUT" "automatic recovery from the invoking user's gh auth failed"
assert_not_contains "multi-frame response does not reuse stale quota headers" "$LAST_OUTPUT" "GitHub core API rate limit is exhausted"
assert_not_contains "multi-frame token is not printed" "$LAST_OUTPUT" "multi-frame-token"

# shellcheck disable=SC2016  # literal script is evaluated in the child bash.
run_case "sudo gh auth identifies the invoking user's invalid stored token" '
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
	launchctl() { printf "invalid-user-token"; return 0; }
	sudo() { return 1; }
	gh() {
		local arg1="${1:-}"
		local arg2="${2:-}"
		local arg3="${3:-}"
		local arg4="${4:-}"
		if [[ "$arg1" == "auth" && "$arg2" == "status" ]]; then return 1; fi
		if [[ "$arg1" == "api" && "$arg2" == "user" && "$arg3" == "--include" && "$arg4" == "--silent" ]]; then
			printf "HTTP/2.0 401 Unauthorized\r\n"
			printf "X-RateLimit-Remaining: 0\r\n"
			printf "X-RateLimit-Reset: 1785697847\r\n"
			printf "X-RateLimit-Resource: core\r\n\r\n"
			printf "{\"message\":\"Bad credentials\"}\n"
			return 1
		fi
		return 1
	}
	# shellcheck disable=SC1090
	source "$APPROVAL_HELPER_UNDER_TEST" >/dev/null 2>&1
	_require_gh_auth
' 1
assert_contains "invalid token is distinguished from sudo forwarding failure" "$LAST_OUTPUT" "this is not a sudo credential-forwarding failure"
assert_contains "invalid token reports GitHub rejection" "$LAST_OUTPUT" "GitHub rejected the invoking user's stored gh credential (HTTP 401)"
assert_contains "invalid token recommends clean replacement" "$LAST_OUTPUT" "gh auth logout -h github.com, then gh auth login -h github.com -s workflow"
assert_contains "invalid token rejects forwarding workaround" "$LAST_OUTPUT" "Do not forward the rejected token through GH_TOKEN"
assert_not_contains "invalid token avoids generic sudo recovery failure" "$LAST_OUTPUT" "automatic recovery from the invoking user's gh auth failed"
assert_not_contains "invalid token is not diagnosed as core exhaustion" "$LAST_OUTPUT" "GitHub core API rate limit is exhausted"
assert_not_contains "invalid token response body is not printed" "$LAST_OUTPUT" "Bad credentials"
assert_not_contains "invalid recovered token is not printed" "$LAST_OUTPUT" "invalid-user-token"

# shellcheck disable=SC2016  # literal script is evaluated in the child bash.
run_case "invalid token guidance sanitizes an unsafe GH_HOST" '
	set -uo pipefail
	export GH_HOST="example.com; unexpected-command"
	# shellcheck disable=SC1090
	source "$APPROVAL_HELPER_UNDER_TEST" >/dev/null 2>&1
	_approval_report_invalid_token
' 0
assert_contains "unsafe GH_HOST falls back to the public host" "$LAST_OUTPUT" "gh auth logout -h github.com"
assert_not_contains "unsafe GH_HOST is not rendered in guidance" "$LAST_OUTPUT" "unexpected-command"

# shellcheck disable=SC2016  # literal script is evaluated in the child bash.
run_case "sudo gh auth quota probe obeys shared cooldown" '
	set -uo pipefail
	export SUDO_USER=alice
	export HOME=/var/root
	probe_log=$(mktemp)
	rm -f "$probe_log"
	trap '\''rm -f "$probe_log"'\'' EXIT
	id() {
		local arg1="${1:-}"
		local arg2="${2:-}"
		if [[ "$arg1" == "-u" && -z "$arg2" ]]; then printf "0"; return 0; fi
		if [[ "$arg1" == "-u" && "$arg2" == "alice" ]]; then printf "501"; return 0; fi
		return 1
	}
	getent() { return 1; }
	dscl() { printf "NFSHomeDirectory: /Users/alice\n"; return 0; }
	launchctl() { printf "cooldown-user-token"; return 0; }
	sudo() { return 1; }
	gh() {
		local arg1="${1:-}"
		local arg2="${2:-}"
		if [[ "$arg1" == "auth" && "$arg2" == "status" ]]; then return 1; fi
		if [[ "$arg1" == "api" && "$arg2" == "user" ]]; then
			printf "called\n" >"$probe_log"
			return 1
		fi
		return 1
	}
	# shellcheck disable=SC1090
	source "$APPROVAL_HELPER_UNDER_TEST" >/dev/null 2>&1
	_gh_secondary_cooldown_preflight() { return 75; }
	auth_rc=0
	_require_gh_auth || auth_rc=$?
	[[ "$auth_rc" -eq 1 && ! -e "$probe_log" ]]
' 0
assert_contains "cooldown-blocked probe preserves generic auth failure" "$LAST_OUTPUT" "automatic recovery from the invoking user's gh auth failed"
assert_not_contains "cooldown-blocked probe is not misclassified" "$LAST_OUTPUT" "GitHub core API rate limit is exhausted"
assert_not_contains "cooldown-blocked recovered token is not printed" "$LAST_OUTPUT" "cooldown-user-token"

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
assert_not_contains "invalid token is not misclassified as quota exhaustion" "$LAST_OUTPUT" "GitHub core API rate limit is exhausted"

printf '\n===========================================\n'
printf 'Results: %s passed, %s failed\n' "$PASS" "$FAIL"

if [[ $FAIL -gt 0 ]]; then
	exit 1
fi
exit 0

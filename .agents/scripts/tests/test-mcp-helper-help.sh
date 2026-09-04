#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -uo pipefail

source_scripts_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT
fixture_root="${test_root}/fixture"
fixture_scripts_dir="${fixture_root}/.agents/scripts"
caller_dir="${test_root}/caller"
stub_dir="${test_root}/bin"
call_log="${test_root}/calls.log"

mkdir -p "$fixture_scripts_dir" "$caller_dir" "$stub_dir"
cp "${source_scripts_dir}/setup-mcp-integrations.sh" "$fixture_scripts_dir/"
cp "${source_scripts_dir}/mcp-diagnose.sh" "$fixture_scripts_dir/"
cat >"${fixture_scripts_dir}/shared-constants.sh" <<'CONSTANTS'
[[ -z "${PURPLE+x}" ]] && PURPLE=""
[[ -z "${BLUE+x}" ]] && BLUE=""
[[ -z "${GREEN+x}" ]] && GREEN=""
[[ -z "${CYAN+x}" ]] && CYAN=""
[[ -z "${RED+x}" ]] && RED=""
[[ -z "${NC+x}" ]] && NC=""
print_error() {
	local message="$1"
	printf '[ERROR] %s\n' "$message" >&2
	return 0
}
print_info() {
	local message="$1"
	printf '[INFO] %s\n' "$message"
	return 0
}
print_success() {
	local message="$1"
	printf '[SUCCESS] %s\n' "$message"
	return 0
}
print_warning() {
	local message="$1"
	printf '[WARNING] %s\n' "$message"
	return 0
}
CONSTANTS
: >"$call_log"

fail() {
	local message="$1"
	printf 'FAIL %s\n' "$message" >&2
	exit 1
	return 1
}

assert_caller_empty() {
	local description="$1"
	[[ -z "$(ls -A "$caller_dir")" ]] || fail "${description} modified the caller directory"
	return 0
}

assert_help_only() {
	local helper="$1"
	local variant="$2"
	local output=""
	local rc=0

	output=$(cd "$caller_dir" && CALL_LOG="$call_log" PATH="${stub_dir}:$PATH" \
		bash "${fixture_scripts_dir}/${helper}" "$variant" 2>&1) || rc=$?
	[[ "$rc" -eq 0 ]] || fail "${helper} ${variant} returned ${rc}"
	[[ "$output" == *"Usage:"* ]] || fail "${helper} ${variant} omitted usage"
	assert_caller_empty "${helper} ${variant}"
	[[ ! -s "$call_log" ]] || fail "${helper} ${variant} invoked an install-capable command"
	return 0
}

cat >"${stub_dir}/install-command-stub" <<'STUB'
#!/usr/bin/env bash
printf '%s %s\n' "$(basename "$0")" "$*" >>"$CALL_LOG"
exit 99
STUB
chmod +x "${stub_dir}/install-command-stub"
for command_name in node npm npx claude; do
	ln -s "${stub_dir}/install-command-stub" "${stub_dir}/${command_name}"
done

for help_variant in help --help -h; do
	assert_help_only "setup-mcp-integrations.sh" "$help_variant"
	assert_help_only "mcp-diagnose.sh" "$help_variant"
done

unknown_rc=0
(cd "$caller_dir" && CALL_LOG="$call_log" PATH="${stub_dir}:$PATH" \
	bash "${fixture_scripts_dir}/setup-mcp-integrations.sh" unknown-command >/dev/null 2>&1) || unknown_rc=$?
[[ "$unknown_rc" -ne 0 ]] || fail "unknown setup command returned success"
assert_caller_empty "unknown setup command"
[[ ! -s "$call_log" ]] || fail "unknown setup command invoked an install-capable command"

templates_rc=0
(cd "$caller_dir" && CALL_LOG="$call_log" PATH="${stub_dir}:$PATH" \
	bash "${fixture_scripts_dir}/setup-mcp-integrations.sh" templates >/dev/null 2>&1) || templates_rc=$?
[[ "$templates_rc" -eq 0 ]] || fail "templates command returned ${templates_rc}"
assert_caller_empty "templates command"
[[ ! -s "$call_log" ]] || fail "templates command invoked an install-capable command"

template_dir="${fixture_root}/configs/mcp-templates"
[[ -d "$template_dir" ]] || fail "templates command did not use the fixture root"
template_count=$(ls -1 "$template_dir"/*.json 2>/dev/null | wc -l | tr -d ' ')
[[ "$template_count" -eq 6 ]] || fail "templates command created ${template_count} files instead of 6"

printf 'PASS MCP helper help and template dispatch are side-effect safe\n'

#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-tabby-profile-sync.sh — Regression tests for GH#22397.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)" || exit
HELPER="${REPO_ROOT}/.agents/scripts/tabby-profile-sync.py"
TABBY_HELPER="${REPO_ROOT}/.agents/scripts/tabby-helper.sh"

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_YELLOW='\033[1;33m'
readonly TEST_NC='\033[0m'

pass_count=0
fail_count=0

_pass() {
	local msg="$1"
	printf '%b  PASS:%b %s\n' "${TEST_GREEN}" "${TEST_NC}" "${msg}"
	pass_count=$((pass_count + 1))
	return 0
}

_fail() {
	local msg="$1"
	printf '%b  FAIL:%b %s\n' "${TEST_RED}" "${TEST_NC}" "${msg}" >&2
	fail_count=$((fail_count + 1))
	return 0
}

_info() {
	local msg="$1"
	printf '%b[INFO]%b %s\n' "${TEST_YELLOW}" "${TEST_NC}" "${msg}"
	return 0
}

run_python_test() {
	local label="$1"
	local code="$2"
	local output

	set +e
	output=$(HELPER="${HELPER}" PYTHONPATH="${REPO_ROOT}/.agents/scripts" python3 -c "${code}" 2>&1)
	local rc=$?
	set -e

	if ((rc == 0)); then
		_pass "${label}"
	else
		_fail "${label}: ${output}"
	fi
	return 0
}

load_module_code='import importlib.util, os
spec = importlib.util.spec_from_file_location("tabby_profile_sync", os.environ["HELPER"])
mod = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(mod)'

_info "Test 1: block-list zsh -l -i -c opencode profile is repaired"
run_python_test "block-list broken args repaired" "${load_module_code}
config = '''profiles:
  - name: aidevops
    options:
      command: /bin/zsh
      args:
        - '-l'
        - '-i'
        - '-c'
        - opencode
      cwd: /tmp/aidevops
'''
repaired, count = mod.repair_broken_opencode_launch_profiles(config)
assert count == 1, count
assert \"- '-i'\" not in repaired, repaired
assert 'TABBY_AUTORUN: opencode' not in repaired, repaired
assert \"- '-l'\" in repaired and \"- '-c'\" in repaired, repaired
assert 'exec aidevops opencode --tabby-shell' in repaired, repaired
assert 'env: {}' in repaired, repaired
"

_info "Test 2: inline broken args are repaired"
run_python_test "inline broken args repaired" "${load_module_code}
config = \"\"\"profiles:\n  - name: aidevops\n    options:\n      command: /bin/zsh\n      args: ['-l', '-i', '-c', opencode]\n      cwd: /tmp/aidevops\n\"\"\"
repaired, count = mod.repair_broken_opencode_launch_profiles(config)
assert count == 1, count
assert \"args: ['-l', '-i', '-c', opencode]\" not in repaired, repaired
assert 'TABBY_AUTORUN: opencode' not in repaired, repaired
assert 'exec aidevops opencode --tabby-shell' in repaired, repaired
"

_info "Test 3: generated profiles use aidevops OpenCode launcher"
run_python_test "generated profile uses aidevops launcher" "${load_module_code}
scheme = {'name': 'Test', 'foreground': '#fff', 'background': '#000', 'cursor': '#fff', 'colors': ['#000', '#fff']}
appearance = mod.ProfileAppearance('#123456', scheme)
profile = mod.build_profile_yaml('aidevops', '/tmp/aidevops', appearance, 'group-1')
assert \"- '-i'\" not in profile, profile
assert 'TABBY_AUTORUN: opencode' not in profile, profile
assert \"- '-l'\" in profile and \"- '-c'\" in profile, profile
assert \"- 'exec aidevops opencode --tabby-shell'\" in profile, profile
assert 'env: {}' in profile, profile
"

_info "Test 4: TABBY_AUTORUN profiles are repaired"
run_python_test "autorun profile repaired" "${load_module_code}
config = '''profiles:
  - name: aidevops
    options:
      command: /bin/zsh
      args:
        - '-l'
        - '-i'
      env:
        TABBY_AUTORUN: opencode
      cwd: /tmp/aidevops
'''
repaired, count = mod.repair_broken_opencode_launch_profiles(config)
assert count == 1, count
assert \"- '-i'\" not in repaired, repaired
assert 'TABBY_AUTORUN: opencode' not in repaired, repaired
assert 'exec aidevops opencode --tabby-shell' in repaired, repaired
assert 'env: {}' in repaired, repaired
"

_info "Test 5: command-field profiles are repaired"
run_python_test "command-field profile repaired" "${load_module_code}
config = '''profiles:
  - name: aidevops
    options:
      command: /bin/zsh -l -c 'opencode; exec zsh'
      args: []
      env: {}
      cwd: /tmp/aidevops
'''
repaired, count = mod.repair_broken_opencode_launch_profiles(config)
assert count == 1, count
assert 'command: /bin/zsh -l -c \'opencode; exec zsh\'' not in repaired, repaired
assert 'args: []' not in repaired, repaired
assert \"- '-l'\" in repaired and \"- '-c'\" in repaired, repaired
assert 'exec aidevops opencode --tabby-shell' in repaired, repaired
assert repaired.count('      env: {}') == 1, repaired
"

_info "Test 6: command-field duplicate env profiles are repaired"
run_python_test "command-field duplicate env repaired" "${load_module_code}
config = '''profiles:
  - name: aidevops
    options:
      command: /bin/zsh -l -c 'opencode; exec zsh'
      args: []
      env: {}
      env: {}
      cwd: /tmp/aidevops
'''
repaired, count = mod.repair_broken_opencode_launch_profiles(config)
assert count >= 1, count
assert 'command: /bin/zsh -l -c \'opencode; exec zsh\'' not in repaired, repaired
assert repaired.count('      env: {}') == 1, repaired
"

_info "Test 7: split direct profiles are upgraded to aidevops launcher"
run_python_test "split direct profile upgraded" "${load_module_code}
config = '''profiles:
  - name: aidevops
    options:
      command: /bin/zsh
      args:
        - '-l'
        - '-c'
        - 'opencode; exec zsh'
      env: {}
      cwd: /tmp/aidevops
'''
repaired, count = mod.repair_broken_opencode_launch_profiles(config)
assert count == 1, count
assert repaired.count('      env: {}') == 1, repaired
assert 'TABBY_AUTORUN: opencode' not in repaired, repaired
assert 'exec aidevops opencode --tabby-shell' in repaired, repaired
"

_info "Test 8: comments do not hide broken command-field profiles or env blocks"
run_python_test "comments around command-field repair handled" "${load_module_code}
config = '''profiles:
  - name: aidevops
    options:
      command: /bin/zsh -l -c 'opencode; exec zsh' # legacy direct command
      args: []
      # existing env must be preserved without duplicate
      env: {}
      cwd: /tmp/aidevops
'''
repaired, count = mod.repair_broken_opencode_launch_profiles(config)
assert count == 1, count
assert 'command: /bin/zsh -l -c' not in repaired, repaired
assert repaired.count('      env: {}') == 1, repaired
assert \"- 'exec aidevops opencode --tabby-shell'\" in repaired, repaired
"

_info "Test 9: custom non-OpenCode webserver profiles remain byte-for-byte unchanged"
run_python_test "custom webserver profile preserved" "${load_module_code}
config = '''profiles:
  - name: site.local
    options:
      args:
        - '-l'
        - '-c'
        - >-
          open -a OrbStack && until docker info >/dev/null 2>&1; do echo
          \"waiting for OrbStack engine...\"; sleep 1; done && cd
          ~/.local-dev-proxy && docker compose up -d && cd ~/Git/site &&
          (lsof -ti:3100 | xargs kill -9 2>/dev/null; rm -f
          apps/web/.next/dev/lock; true) && pnpm dev:web; exec zsh
      env: {}
      env:
        PATH: /opt/homebrew/bin
      cwd: /tmp/site
'''
repaired, count = mod.repair_broken_opencode_launch_profiles(config)
assert count == 0, count
assert repaired == config, repaired
"

_info "Test 10: sync repairs existing profiles even when no new profile is needed"
tmp_root="$(mktemp -d)"
trap 'rm -rf "${tmp_root}"' EXIT
repo_path="${tmp_root}/aidevops"
mkdir -p "${repo_path}"
repos_json="${tmp_root}/repos.json"
tabby_config="${tmp_root}/config.yaml"
python3 - "${repos_json}" "${repo_path}" <<'PY'
import json
import sys

repos_json, repo_path = sys.argv[1:]
with open(repos_json, "w") as handle:
    json.dump({"initialized_repos": [{"path": repo_path}]}, handle)
PY
python3 - "${tabby_config}" "${repo_path}" <<'PY'
import sys

tabby_config, repo_path = sys.argv[1:]
with open(tabby_config, "w") as handle:
    handle.write(f"""profiles:
  - name: aidevops
    options:
      command: /bin/zsh
      args:
        - '-l'
        - '-i'
        - '-c'
        - opencode
      cwd: {repo_path}
""")
PY
sync_output=$(PYTHONPATH="${REPO_ROOT}/.agents/scripts" python3 "${HELPER}" --repos-json "${repos_json}" --tabby-config "${tabby_config}")
if [[ "${sync_output}" == *"Repaired 1 existing Tabby profile(s)."* ]] && grep -q -- "exec aidevops opencode --tabby-shell" "${tabby_config}" && ! grep -q -- "TABBY_AUTORUN: opencode" "${tabby_config}"; then
	_pass "sync repairs existing broken profile"
else
	_fail "sync did not repair existing profile: ${sync_output}"
fi

_info "Test 11: Tabby config path precedence matches active platform configuration"
config_home="${tmp_root}/xdg"
runtime_dir="${tmp_root}/runtime-tabby"
explicit_config="${tmp_root}/explicit.yaml"

resolved=$(HOME="${tmp_root}" XDG_CONFIG_HOME="${config_home}" TABBY_CONFIG='' TABBY_CONFIG_DIRECTORY='' bash "${TABBY_HELPER}" config-path Linux)
[[ "$resolved" == "${config_home}/tabby/config.yaml" ]] && _pass "Linux XDG default resolved" || _fail "Linux XDG default mismatch: ${resolved}"

resolved=$(HOME="${tmp_root}" XDG_CONFIG_HOME="${config_home}" TABBY_CONFIG='' TABBY_CONFIG_DIRECTORY="${runtime_dir}/" bash "${TABBY_HELPER}" config-path Linux)
[[ "$resolved" == "${runtime_dir}/config.yaml" ]] && _pass "runtime directory override resolved" || _fail "runtime directory override mismatch: ${resolved}"

resolved=$(HOME="${tmp_root}" XDG_CONFIG_HOME="${config_home}" TABBY_CONFIG="${explicit_config}" TABBY_CONFIG_DIRECTORY="${runtime_dir}" bash "${TABBY_HELPER}" config-path Linux)
[[ "$resolved" == "${explicit_config}" ]] && _pass "explicit file override resolved" || _fail "explicit file override mismatch: ${resolved}"

resolved=$(HOME="${tmp_root}" TABBY_CONFIG='' TABBY_CONFIG_DIRECTORY='' bash "${TABBY_HELPER}" config-path Darwin)
[[ "$resolved" == "${tmp_root}/Library/Application Support/tabby/config.yaml" ]] && _pass "macOS default preserved" || _fail "macOS default mismatch: ${resolved}"

_info "Test 12: sync converts inline empty profiles and keeps valid YAML"
inline_config="${tmp_root}/inline-empty.yaml"
printf 'version: 8\nprofiles: []\ngroups: []\n' >"${inline_config}"
if PYTHONPATH="${REPO_ROOT}/.agents/scripts" python3 "${HELPER}" --repos-json "${repos_json}" --tabby-config "${inline_config}" >/dev/null &&
	python3 -c 'import sys, yaml; value = yaml.safe_load(open(sys.argv[1])); assert isinstance(value["profiles"], list) and value["profiles"]' "${inline_config}" &&
	! grep -qF 'profiles: []' "${inline_config}"; then
	_pass "inline empty profiles converted to valid block list"
else
	_fail "inline empty profiles sync failed"
fi

_info "Test 13: missing and block-empty profiles shapes remain valid"
for shape in missing block_empty; do
	shape_config="${tmp_root}/${shape}.yaml"
	if [[ "${shape}" == "missing" ]]; then
		printf 'version: 8\ngroups: []\n' >"${shape_config}"
	else
		printf 'version: 8\nprofiles:\ngroups: []\n' >"${shape_config}"
	fi
	if PYTHONPATH="${REPO_ROOT}/.agents/scripts" python3 "${HELPER}" --repos-json "${repos_json}" --tabby-config "${shape_config}" >/dev/null &&
		python3 -c 'import sys, yaml; value = yaml.safe_load(open(sys.argv[1])); assert isinstance(value["profiles"], list) and value["profiles"]' "${shape_config}"; then
		_pass "${shape} profiles shape remains valid"
	else
		_fail "${shape} profiles shape failed"
	fi
done

_info "Test 14: malformed source is rejected without modification"
malformed_config="${tmp_root}/malformed.yaml"
printf 'version: 8\nprofiles: []\n  - name: broken\ngroups: []\n' >"${malformed_config}"
malformed_before=$(shasum -a 256 "${malformed_config}" | cut -d ' ' -f 1)
if PYTHONPATH="${REPO_ROOT}/.agents/scripts" python3 "${HELPER}" --repos-json "${repos_json}" --tabby-config "${malformed_config}" --status-only >/dev/null 2>&1; then
	_fail "malformed status unexpectedly succeeded"
else
	malformed_after=$(shasum -a 256 "${malformed_config}" | cut -d ' ' -f 1)
	[[ "${malformed_before}" == "${malformed_after}" ]] && _pass "malformed source rejected unchanged" || _fail "malformed source changed"
fi

_info "Test 15: failed candidate validation preserves the active config"
run_python_test "invalid candidate is not written" "${load_module_code}
import pathlib, tempfile
from tabby_yaml_helpers import save_yaml
path = pathlib.Path(tempfile.mkdtemp()) / 'config.yaml'
original = 'version: 8\\nprofiles: []\\ngroups: []\\n'
path.write_text(original)
try:
    save_yaml(str(path), 'version: 8\\nprofiles: []\\n  - broken\\n')
except Exception:
    pass
else:
    raise AssertionError('invalid candidate accepted')
assert path.read_text() == original
"

_info "Test 16: atomic replacement failure preserves the active config"
run_python_test "replacement failure leaves original unchanged" "${load_module_code}
import pathlib, tempfile
from unittest import mock
from tabby_yaml_helpers import save_yaml
path = pathlib.Path(tempfile.mkdtemp()) / 'config.yaml'
original = 'version: 8\\nprofiles: []\\ngroups: []\\n'
candidate = 'version: 8\\nprofiles:\\n  - name: demo\\ngroups: []\\n'
path.write_text(original)
with mock.patch('tabby_yaml_helpers.os.replace', side_effect=OSError('simulated')):
    try:
        save_yaml(str(path), candidate)
    except OSError:
        pass
    else:
        raise AssertionError('replacement failure was ignored')
assert path.read_text() == original
assert list(path.parent.glob('.config.yaml.*')) == []
"

_info "Test 17: Bash-only Linux shell is used for generated profiles"
bash_only_shell_dir="${tmp_root}/bash-only"
mkdir -p "${bash_only_shell_dir}"
bash_only_shell="${bash_only_shell_dir}/bash"
printf '#!/bin/sh\nexit 0\n' >"${bash_only_shell}"
chmod 700 "${bash_only_shell}"
bash_only_config="${tmp_root}/bash-only.yaml"
printf 'version: 8\nprofiles: []\ngroups: []\n' >"${bash_only_config}"
if AIDEVOPS_TABBY_LOGIN_SHELL="${bash_only_shell}" SHELL=/missing/zsh \
	PYTHONPATH="${REPO_ROOT}/.agents/scripts" python3 "${HELPER}" \
	--repos-json "${repos_json}" --tabby-config "${bash_only_config}" >/dev/null &&
	grep -qF "command: ${bash_only_shell}" "${bash_only_config}"; then
	_pass "Bash-only Linux profile uses configured executable shell"
else
	_fail "Bash-only Linux profile did not use configured executable shell"
fi

_info "Test 18: status rejects a missing managed profile executable"
missing_command_config="${tmp_root}/missing-command.yaml"
printf "profiles:\n  - name: aidevops\n    options:\n      command: /missing/zsh\n      args:\n        - '-l'\n        - '-c'\n        - 'exec aidevops opencode --tabby-shell'\n      cwd: %s\ngroups: []\n" \
	"${repo_path}" >"${missing_command_config}"
set +e
status_output=$(PYTHONPATH="${REPO_ROOT}/.agents/scripts" python3 "${HELPER}" \
	--repos-json "${repos_json}" --tabby-config "${missing_command_config}" --status-only 2>&1)
status_rc=$?
set -e
if [[ "${status_rc}" -eq 2 && "${status_output}" == *"command '/missing/zsh'"* && "${status_output}" == *"aidevops tabby sync"* ]]; then
	_pass "status reports missing managed profile executable"
else
	_fail "status missing-command result unexpected: rc=${status_rc} output=${status_output}"
fi

echo ""
if ((fail_count == 0)); then
	printf '%bAll %d tests passed.%b\n' "${TEST_GREEN}" "${pass_count}" "${TEST_NC}"
	exit 0
else
	printf '%b%d test(s) failed, %d passed.%b\n' \
		"${TEST_RED}" "${fail_count}" "${pass_count}" "${TEST_NC}" >&2
	exit 1
fi

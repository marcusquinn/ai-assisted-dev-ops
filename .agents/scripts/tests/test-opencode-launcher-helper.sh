#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-opencode-launcher-helper.sh — isolated OpenCode launcher regression tests.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)" || exit
HELPER="${REPO_ROOT}/.agents/scripts/opencode-launcher-helper.sh"

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
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

make_fake_opencode() {
    local bin_dir="$1"
    mkdir -p "${bin_dir}"
cat >"${bin_dir}/opencode" <<'SH'
#!/usr/bin/env bash
fake_log="${FAKE_OPENCODE_LOG:-$(cd "$(dirname "$0")/.." && pwd -P)/fake-opencode.log}"
if [[ -n "${fake_log}" ]]; then
    printf '%s|%s|%s\n' "${XDG_DATA_HOME:-}" "$PWD" "$*" >>"${fake_log}"
fi
if [[ "$*" == "debug config --log-level ERROR" ]]; then
    node --input-type=module - "${AIDEVOPS_TEAM_INTERFACE_OVERLAY}" "${OPENCODE_CONFIG}" <<'NODE'
import fs from "node:fs";
import path from "node:path";
import {fileURLToPath, pathToFileURL} from "node:url";

const overlay = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const bootstrap = JSON.parse(fs.readFileSync(process.argv[3], "utf8"));
const pluginUrl = bootstrap.plugin[0];
const pluginEntry = fileURLToPath(pluginUrl);
const contract = await import(pathToFileURL(path.join(
  path.dirname(pluginEntry),
  "team-interface-context.mjs",
)).href);
const name = overlay.agent.display_name;
const evidence = contract.conversationConfigEvidence(name);
const sourceFilename = overlay.agent.source_ref.slice("agents:".length);
const prompt = fs.readFileSync(path.resolve(path.dirname(pluginEntry), "../..", sourceFilename), "utf8");
const config = {
  ...evidence,
  command: {},
  instructions: [],
  plugin: [pluginUrl],
  agent: {
    [name]: {
      ...evidence.agent[name],
      prompt,
    },
    build: {disable: true},
    plan: {disable: true},
    general: {disable: true},
    explore: {disable: true},
  },
};
process.stdout.write(JSON.stringify(config));
NODE
    exit 0
fi
printf 'XDG_DATA_HOME=%s\n' "${XDG_DATA_HOME:-}"
printf 'AIDEVOPS_OPENCODE_ISOLATED_DB=%s\n' "${AIDEVOPS_OPENCODE_ISOLATED_DB:-}"
printf 'AIDEVOPS_SESSION_ORIGIN=%s\n' "${AIDEVOPS_SESSION_ORIGIN:-}"
printf 'AIDEVOPS_TEAM_INTERFACE_OVERLAY=%s\n' "${AIDEVOPS_TEAM_INTERFACE_OVERLAY:-}"
printf 'AIDEVOPS_REMOTE_INTERFACE=%s\n' "${AIDEVOPS_REMOTE_INTERFACE:-}"
printf 'AIDEVOPS_REMOTE_PROJECT_ROOT=%s\n' "${AIDEVOPS_REMOTE_PROJECT_ROOT:-}"
printf 'HOME=%s\n' "${HOME:-}"
printf 'OPENCODE_CONFIG=%s\n' "${OPENCODE_CONFIG:-}"
printf 'OPENCODE_DISABLE_AUTOCOMPACT=%s\n' "${OPENCODE_DISABLE_AUTOCOMPACT:-}"
printf 'OPENCODE_DISABLE_AUTOUPDATE=%s\n' "${OPENCODE_DISABLE_AUTOUPDATE:-}"
printf 'OPENCODE_DISABLE_DEFAULT_PLUGINS=%s\n' "${OPENCODE_DISABLE_DEFAULT_PLUGINS:-}"
printf 'OPENCODE_DISABLE_LSP_DOWNLOAD=%s\n' "${OPENCODE_DISABLE_LSP_DOWNLOAD:-}"
printf 'OPENCODE_DISABLE_MODELS_FETCH=%s\n' "${OPENCODE_DISABLE_MODELS_FETCH:-}"
printf 'OPENCODE_DISABLE_PROJECT_CONFIG=%s\n' "${OPENCODE_DISABLE_PROJECT_CONFIG:-}"
printf 'OPENCODE_DISABLE_SHARE=%s\n' "${OPENCODE_DISABLE_SHARE:-}"
printf 'OPENCODE_DISABLE_CLAUDE_CODE_SKILLS=%s\n' "${OPENCODE_DISABLE_CLAUDE_CODE_SKILLS:-}"
printf 'OPENCODE_DISABLE_EXTERNAL_SKILLS=%s\n' "${OPENCODE_DISABLE_EXTERNAL_SKILLS:-}"
printf 'HOST_CONFIG_CANARY=%s\n' "${HOST_CONFIG_CANARY:-}"
printf 'AIDEVOPS_TEMP_DIR=%s\n' "${AIDEVOPS_TEMP_DIR:-}"
printf 'TMPDIR=%s\n' "${TMPDIR:-}"
printf 'TMP=%s\n' "${TMP:-}"
printf 'TEMP=%s\n' "${TEMP:-}"
printf 'PWD=%s\n' "$PWD"
printf 'ARGS=%s\n' "$*"
SH
    chmod +x "${bin_dir}/opencode"
    cat >"${bin_dir}/uname" <<'SH'
#!/usr/bin/env bash
printf 'Darwin\n'
SH
    chmod +x "${bin_dir}/uname"
    return 0
}

directory_is_empty() {
    local directory="${1:-}"
    local candidate=""

    [[ -n "${directory}" && -d "${directory}" ]] || return 1
    for candidate in "${directory}"/* "${directory}"/.[!.]* "${directory}"/..?*; do
        if [[ -e "${candidate}" || -L "${candidate}" ]]; then
            return 1
        fi
    done
    return 0
}

tmp_root="$(mktemp -d)"
tmp_root="$(cd "${tmp_root}" && pwd -P)"
trap 'rm -rf "${tmp_root}"' EXIT
fake_bin="${tmp_root}/bin"
work_dir="${tmp_root}/work"
tui_dry_run_work_dir="${tmp_root}/tui-dry-run-work"
desktop_dry_run_work_dir="${tmp_root}/desktop-dry-run-work"
launch_dir="${tmp_root}/repo"
home_dir="${tmp_root}/home"
fake_log="${tmp_root}/fake-opencode.log"
conversation_work_dir="${tmp_root}/conversation-work"
conversation_dry_run_work_dir="${tmp_root}/conversation-dry-run-work"
mkdir -p "${work_dir}" "${tui_dry_run_work_dir}" "${desktop_dry_run_work_dir}" \
    "${conversation_work_dir}" "${conversation_dry_run_work_dir}" \
    "${launch_dir}" "${home_dir}/.local/share/opencode" \
    "${home_dir}/.config/aidevops" "${home_dir}/.config/opencode"
make_fake_opencode "${fake_bin}"
printf '{"anthropic":{}}\n' >"${home_dir}/.local/share/opencode/auth.json"
printf '{"command":{"persistent-canary":{"template":"unsafe"}},"instructions":["persistent-canary.md"],"plugin":["file:///persistent-canary.mjs"]}\n' >"${home_dir}/.config/opencode/opencode.json"
printf '{"initialized_repos":[{"path":"%s"}]}\n' "${launch_dir}" >"${home_dir}/.config/aidevops/repos.json"
conversation_roster="${tmp_root}/conversation-roster.json"
conversation_context="${tmp_root}/conversation-context.json"
conversation_overlay="${tmp_root}/conversation-overlay.json"
remote_interactive_overlay="${tmp_root}/remote-interactive-overlay.json"
python3 "${REPO_ROOT}/.agents/scripts/team-interface-agent-roster.py" \
    --agents-dir "${REPO_ROOT}/.agents" --output "${conversation_roster}"
cat >"${conversation_context}" <<'JSON'
{
  "actor_ref": "actor:synthetic-owner",
  "app_team_ref": "app-team:synthetic-team",
  "community_ref": "community:synthetic-community",
  "conversation_ref": "conversation:synthetic-thread",
  "correlation_ref": "correlation:synthetic-correlation",
  "provider_ref": "provider:synthetic-provider",
  "trust_ref": "trust:synthetic-verified"
}
JSON
node "${REPO_ROOT}/.agents/scripts/team-interface-opencode-overlay.mjs" generate \
    --roster "${conversation_roster}" --agent-id agent.build-plus \
    --context "${conversation_context}" --output "${conversation_overlay}"
node "${REPO_ROOT}/.agents/scripts/team-interface-opencode-overlay.mjs" generate \
    --roster "${conversation_roster}" --agent-id agent.build-plus \
    --context "${conversation_context}" --permission-profile remote_interactive_v1 \
    --output "${remote_interactive_overlay}"
desktop_source="${tmp_root}/OpenCode.app/Contents/MacOS/OpenCode"
mkdir -p "$(dirname "${desktop_source}")"
cat >"${desktop_source}" <<'SH'
#!/usr/bin/env bash
printf 'XDG_DATA_HOME=%s\n' "${XDG_DATA_HOME:-}"
printf 'AIDEVOPS_OPENCODE_ISOLATED_DB=%s\n' "${AIDEVOPS_OPENCODE_ISOLATED_DB:-}"
printf 'PWD=%s\n' "$PWD"
printf 'ARGS=%s\n' "$*"
SH
chmod +x "${desktop_source}"

output=$(PATH="${fake_bin}:$PATH" HOME="${home_dir}" AIDEVOPS_WORK_DIR="${work_dir}" \
    AIDEVOPS_WORKSPACE_DIR="${home_dir}/.aidevops/.agent-workspace" FAKE_OPENCODE_LOG="${fake_log}" \
    TMPDIR="/host/tmpdir" TMP="/host/tmp" TEMP="/host/temp" \
    "${HELPER}" --dir "${launch_dir}" -- --version 2>&1)
expected_temp=$(cd "${home_dir}/.aidevops/.agent-workspace/tmp" && pwd -P)
line_count=0
prewarm_line=""
project_auth_count=0
while IFS= read -r line; do
    line_count=$((line_count + 1))
    if [[ ${line_count} -eq 1 ]]; then
        prewarm_line="${line}"
    fi
done <"${fake_log}"
for auth_file in "${work_dir}"/opencode-interactive/project-repo-*/opencode/auth.json; do
    [[ -f "${auth_file}" ]] || continue
    project_auth_count=$((project_auth_count + 1))
done
if [[ "${output}" == *"AIDEVOPS_OPENCODE_ISOLATED_DB=1"* ]] \
    && [[ "${output}" == *"XDG_DATA_HOME=${work_dir}/opencode-interactive/project-repo-"* ]] \
    && [[ "${output}" == *"AIDEVOPS_TEMP_DIR=${expected_temp}"* ]] \
    && [[ "${output}" == *"TMPDIR=/host/tmpdir"* ]] \
    && [[ "${output}" == *"TMP=/host/tmp"* ]] \
    && [[ "${output}" == *"TEMP=/host/temp"* ]] \
    && [[ "${output}" == *"PWD=${launch_dir}"* ]] \
    && [[ "${project_auth_count}" == "1" ]] \
    && [[ "${line_count}" == "2" ]] \
    && [[ "${prewarm_line}" == *"|db path" ]] \
    && [[ ! -e "${work_dir}/opencode-launcher/last-data-dir" ]] \
    && [[ "${output}" != *"sqlite-migration"* ]]; then
    _pass "isolated launcher sets per-session data dir and copies auth"
else
    _fail "isolated launcher output unexpected: ${output}"
fi

rm -f "${fake_log}"
output=$(PATH="${fake_bin}:$PATH" HOME="${home_dir}" AIDEVOPS_WORK_DIR="${work_dir}" FAKE_OPENCODE_LOG="${fake_log}" \
    "${HELPER}" --dir "${launch_dir}" --session-id test-session -- --version 2>&1)
if [[ "${output}" == *"XDG_DATA_HOME=${work_dir}/opencode-interactive/test-session"* ]]; then
    _pass "explicit session-id still controls isolated data dir"
else
    _fail "explicit session-id output unexpected: ${output}"
fi

output=$(PATH="${fake_bin}:$PATH" HOME="${home_dir}" AIDEVOPS_WORK_DIR="${work_dir}" \
    XDG_DATA_HOME="${work_dir}/opencode-interactive/test-session" \
    "${HELPER}" --dir "${launch_dir}" --session-id test-session -- --version 2>&1)
if [[ "${output}" == *"XDG_DATA_HOME=${work_dir}/opencode-interactive/test-session"* ]] \
    && [[ "${output}" != *"identical"* ]]; then
    _pass "launcher skips auth copy when source and target match"
else
    _fail "same auth copy guard output unexpected: ${output}"
fi

tui_dry_run_log="${tmp_root}/tui-dry-run-opencode.log"
output=$(PATH="${fake_bin}:$PATH" HOME="${home_dir}" AIDEVOPS_WORK_DIR="${tui_dry_run_work_dir}" \
    FAKE_OPENCODE_LOG="${tui_dry_run_log}" \
    "${HELPER}" --dir "${launch_dir}" --session-id dry-run-only --dry-run 2>&1)
if [[ "${output}" == *"XDG_DATA_HOME=${tui_dry_run_work_dir}/opencode-interactive/dry-run-only"* ]] \
    && directory_is_empty "${tui_dry_run_work_dir}" \
    && [[ ! -e "${tui_dry_run_log}" ]]; then
    _pass "TUI dry-run prints the command without writing launcher state"
else
    _fail "TUI dry-run mutated state or output an unexpected command: ${output}"
fi

tabby_output=$(PATH="${fake_bin}:$PATH" HOME="${home_dir}" AIDEVOPS_WORK_DIR="${work_dir}" \
    "${HELPER}" --tabby-shell --dir "${launch_dir}" --session-id tabby-first-launch --dry-run 2>&1)
if [[ "${tabby_output}" == *"AIDEVOPS_TABBY_SESSION_RECOVERY=1 opencode"* ]] \
    && [[ "${tabby_output}" == *"exec /bin/zsh -l"* ]] \
    && [[ "${tabby_output}" != *"opencode ''"* ]] \
    && [[ "${tabby_output}" != *"--session ses_"* ]]; then
    _pass "Tabby first launch enables recovery and leaves a shell open"
else
    _fail "Tabby first-launch command unexpected: ${tabby_output}"
fi

tabby_session_id="ses_0123456789TabbyRestore"
tabby_data_dir="${work_dir}/opencode-interactive/tabby-restore"
tabby_marker_dir="${work_dir}/opencode-tabby-recovery/${tabby_session_id}"
mkdir -p "${tabby_data_dir}/opencode" "${tabby_marker_dir}"
chmod 700 "${work_dir}/opencode-tabby-recovery" "${tabby_marker_dir}"
sqlite3 "${tabby_data_dir}/opencode/opencode.db" \
    "CREATE TABLE session (id text PRIMARY KEY, parent_id text, directory text NOT NULL); INSERT INTO session VALUES ('${tabby_session_id}', NULL, '${launch_dir}');"
python3 - "${tabby_marker_dir}/recovery.json" "${tabby_session_id}" "${launch_dir}" "${tabby_data_dir}" <<'PY'
import json
import os
import sys

marker_path, session_id, directory, data_dir = sys.argv[1:]
with open(marker_path, "w") as handle:
    json.dump(
        {
            "schema_version": 1,
            "session_id": session_id,
            "directory": directory,
            "data_dir": data_dir,
        },
        handle,
    )
os.chmod(marker_path, 0o600)
PY
tabby_output=$(cd "${tabby_marker_dir}" && \
    PATH="${fake_bin}:$PATH" HOME="${home_dir}" AIDEVOPS_WORK_DIR="${work_dir}" \
    "${HELPER}" --tabby-shell --dry-run 2>&1)
if [[ "${tabby_output}" == *"cd ${launch_dir}"* ]] \
    && [[ "${tabby_output}" == *"XDG_DATA_HOME=${tabby_data_dir}"* ]] \
    && [[ "${tabby_output}" == *"opencode --session ${tabby_session_id}"* ]] \
    && [[ "${tabby_output}" == *"exec /bin/zsh -l"* ]]; then
    _pass "Tabby recovery resumes the exact validated OpenCode session"
else
    _fail "Tabby recovered command unexpected: ${tabby_output}"
fi

output=$(PATH="${fake_bin}:$PATH" HOME="${home_dir}" AIDEVOPS_WORK_DIR="${work_dir}" \
    "${HELPER}" --shared-db --dir "${launch_dir}" --dry-run 2>&1)
if [[ "${output}" == *"opencode" ]] && [[ "${output}" != *"opencode ''"* ]]; then
    _pass "shared-db dry-run omits a synthetic empty argument"
else
    _fail "shared-db dry-run command unexpected: ${output}"
fi

output=$(PATH="${fake_bin}:$PATH" HOME="${home_dir}" AIDEVOPS_WORK_DIR="${work_dir}" \
    "${HELPER}" --shared-db --dir "${launch_dir}" -- --version 2>&1)
if [[ "${output}" == *"AIDEVOPS_OPENCODE_ISOLATED_DB="* ]] \
    && [[ "${output}" == *"XDG_DATA_HOME="* ]] \
    && [[ "${output}" == *"ARGS=--version"* ]]; then
    _pass "shared-db mode leaves OpenCode data dir untouched"
else
    _fail "shared-db launcher output unexpected: ${output}"
fi

desktop_app_dir="${tmp_root}/Applications"
output=$(PATH="${fake_bin}:$PATH" HOME="${home_dir}" "${HELPER}" desktop install-shortcut --app-dir "${desktop_app_dir}" --source-binary "${desktop_source}" 2>&1)
desktop_app="${desktop_app_dir}/OpenCode AIDevOps.app"
desktop_wrapper="${desktop_app}/Contents/MacOS/opencode-aidevops"
desktop_plist="${desktop_app}/Contents/Info.plist"
if [[ -x "${desktop_wrapper}" ]] \
    && [[ -f "${desktop_plist}" ]] \
    && grep -q "sh.aidevops.opencode.desktop" "${desktop_plist}" \
    && grep -q "desktop launch --from-app" "${desktop_wrapper}" \
    && [[ "${output}" == *"Installed OpenCode AIDevOps.app"* ]]; then
    _pass "desktop install-shortcut creates macOS app wrapper"
else
    _fail "desktop app wrapper install unexpected: ${output}"
fi

mkdir -p "${work_dir}/opencode-launcher"
obsolete_marker="${work_dir}/opencode-launcher/last-data-dir"
obsolete_data_dir="${work_dir}/opencode-interactive/test-session"
printf '%s\n' "${obsolete_data_dir}" >"${obsolete_marker}"

output=$(PATH="${fake_bin}:$PATH" HOME="${home_dir}" AIDEVOPS_WORK_DIR="${work_dir}" \
    "${HELPER}" desktop launch --from-app --source-binary "${desktop_source}" --dry-run 2>&1)
obsolete_marker_value=$(<"${obsolete_marker}")
if [[ "${output}" == *"XDG_DATA_HOME=${work_dir}/opencode-desktop/desktop-default"* ]] \
    && [[ "${output}" == *"AIDEVOPS_OPENCODE_ISOLATED_DB=1"* ]] \
    && [[ "${obsolete_marker_value}" == "${obsolete_data_dir}" ]] \
    && [[ ! -d "${work_dir}/opencode-desktop/desktop-default" ]]; then
    _pass "desktop app ignores the obsolete cross-mode data-dir marker"
else
    _fail "desktop app launch reused or mutated obsolete cross-mode state: ${output}"
fi

desktop_dry_run_log="${tmp_root}/desktop-dry-run-opencode.log"
output=$(PATH="${fake_bin}:$PATH" HOME="${home_dir}" AIDEVOPS_WORK_DIR="${desktop_dry_run_work_dir}" \
    FAKE_OPENCODE_LOG="${desktop_dry_run_log}" \
    "${HELPER}" desktop launch --source-binary "${desktop_source}" --dir "${launch_dir}" --dry-run 2>&1)
if [[ "${output}" == *"XDG_DATA_HOME=${desktop_dry_run_work_dir}/opencode-desktop/desktop-project-repo-"* ]] \
    && [[ "${output}" == *"AIDEVOPS_OPENCODE_ISOLATED_DB=1"* ]] \
    && [[ "${output}" == *"${desktop_source}"* ]] \
    && directory_is_empty "${desktop_dry_run_work_dir}" \
    && [[ ! -e "${desktop_dry_run_log}" ]]; then
    _pass "desktop dry-run prints an isolated command without writing state"
else
    _fail "desktop dry-run mutated state or output an unexpected command: ${output}"
fi

rm -f "${fake_log}"
output=$(PATH="${fake_bin}:$PATH" HOME="${home_dir}" AIDEVOPS_WORK_DIR="${work_dir}" \
    FAKE_OPENCODE_LOG="${fake_log}" \
    "${HELPER}" desktop launch --source-binary "${desktop_source}" --dir "${launch_dir}" -- --version 2>&1)
line_count=0
prewarm_line=""
desktop_auth_count=0
while IFS= read -r line; do
    line_count=$((line_count + 1))
    if [[ ${line_count} -eq 1 ]]; then
        prewarm_line="${line}"
    fi
done <"${fake_log}"
for auth_file in "${work_dir}"/opencode-desktop/desktop-project-repo-*/opencode/auth.json; do
    [[ -f "${auth_file}" ]] || continue
    desktop_auth_count=$((desktop_auth_count + 1))
done
obsolete_marker_value=$(<"${obsolete_marker}")
if [[ "${output}" == *"XDG_DATA_HOME=${work_dir}/opencode-desktop/desktop-project-repo-"* ]] \
    && [[ "${output}" == *"AIDEVOPS_OPENCODE_ISOLATED_DB=1"* ]] \
    && [[ "${output}" == *"PWD=${launch_dir}"* ]] \
    && [[ "${output}" == *"ARGS=--version"* ]] \
    && [[ "${desktop_auth_count}" == "1" ]] \
    && [[ "${line_count}" == "1" ]] \
    && [[ "${prewarm_line}" == *"|db path" ]] \
    && [[ "${obsolete_marker_value}" == "${obsolete_data_dir}" ]]; then
    _pass "desktop real launch prewarms its isolated shard without updating cross-mode state"
else
    _fail "desktop real launch output or state unexpected: ${output}"
fi

rm -f "${fake_log}"
persistent_config_before=$(<"${home_dir}/.config/opencode/opencode.json")
output=$(PATH="${fake_bin}:$PATH" HOME="${home_dir}" AIDEVOPS_WORK_DIR="${conversation_work_dir}" \
    FAKE_OPENCODE_LOG="${fake_log}" HOST_CONFIG_CANARY="must-not-cross-boundary" \
    "${HELPER}" conversation --overlay "${conversation_overlay}" --dir "${launch_dir}" 2>&1)
persistent_config_after=$(<"${home_dir}/.config/opencode/opencode.json")
conversation_line_count=0
conversation_debug_pwd=""
conversation_home=""
conversation_config=""
while IFS='|' read -r _ logged_pwd logged_args; do
    conversation_line_count=$((conversation_line_count + 1))
    if [[ "${logged_args}" == "debug config --log-level ERROR" ]]; then
        conversation_debug_pwd="${logged_pwd}"
    fi
done <"${fake_log}"
while IFS= read -r line; do
    case "${line}" in
    HOME=*) conversation_home=${line#HOME=} ;;
    OPENCODE_CONFIG=*) conversation_config=${line#OPENCODE_CONFIG=} ;;
    esac
done <<<"${output}"
conversation_auth_count=0
for auth_file in "${conversation_work_dir}"/opencode-interactive/conversation-*/opencode/auth.json; do
    [[ -f "${auth_file}" ]] || continue
    conversation_auth_count=$((conversation_auth_count + 1))
done
if [[ "${output}" == *"ARGS=acp --cwd ${launch_dir}"* ]] \
    && [[ "${output}" == *"PWD=${launch_dir}"* ]] \
    && [[ "${output}" == *"AIDEVOPS_SESSION_ORIGIN=conversation"* ]] \
    && [[ "${output}" == *"AIDEVOPS_TEAM_INTERFACE_OVERLAY=${conversation_overlay}"* ]] \
    && [[ "${output}" == *"OPENCODE_DISABLE_CLAUDE_CODE_SKILLS=1"* ]] \
    && [[ "${output}" == *"OPENCODE_DISABLE_EXTERNAL_SKILLS=1"* ]] \
    && [[ "${output}" == *"OPENCODE_DISABLE_DEFAULT_PLUGINS=1"* ]] \
    && [[ "${output}" == *"OPENCODE_DISABLE_AUTOCOMPACT=1"* ]] \
    && [[ "${output}" == *"OPENCODE_DISABLE_AUTOUPDATE=1"* ]] \
    && [[ "${output}" == *"OPENCODE_DISABLE_LSP_DOWNLOAD=1"* ]] \
    && [[ "${output}" == *"OPENCODE_DISABLE_MODELS_FETCH=1"* ]] \
    && [[ "${output}" == *"OPENCODE_DISABLE_PROJECT_CONFIG=1"* ]] \
    && [[ "${output}" == *"OPENCODE_DISABLE_SHARE=1"* ]] \
    && [[ "${output}" == *"HOST_CONFIG_CANARY="* ]] \
    && [[ "${output}" != *"must-not-cross-boundary"* ]] \
    && [[ "${conversation_home}" == */opencode-conversation.*/home ]] \
    && [[ "${conversation_config}" == */opencode-conversation.*/config/opencode/opencode.json ]] \
    && [[ "${conversation_debug_pwd}" == "${launch_dir}" ]] \
    && [[ "${conversation_line_count}" == "2" ]] \
    && [[ "${conversation_auth_count}" == "0" ]] \
    && [[ ! -e "${conversation_home%/home}" ]] \
    && [[ "${persistent_config_after}" == "${persistent_config_before}" ]]; then
    _pass "restricted conversation validates effective config and launches fixed ACP argv"
else
    _fail "restricted conversation launch output or state unexpected: ${output}"
fi

conversation_dry_run_log="${tmp_root}/conversation-dry-run-opencode.log"
output=$(PATH="${fake_bin}:$PATH" HOME="${home_dir}" AIDEVOPS_WORK_DIR="${conversation_dry_run_work_dir}" \
    FAKE_OPENCODE_LOG="${conversation_dry_run_log}" \
    "${HELPER}" conversation --overlay "${conversation_overlay}" --dir "${launch_dir}" --dry-run 2>&1)
if [[ "${output}" == *"opencode acp --cwd ${launch_dir}"* ]] \
    && [[ "${output}" == *"validated-overlay:sha256:"* ]] \
    && [[ "${output}" != *"${conversation_overlay}"* ]] \
    && [[ "${output}" != *"synthetic-owner"* ]] \
    && directory_is_empty "${conversation_dry_run_work_dir}" \
    && [[ ! -e "${conversation_dry_run_log}" ]]; then
    _pass "restricted conversation dry-run redacts context and does not mutate state"
else
    _fail "restricted conversation dry-run was unredacted or mutated state: ${output}"
fi

if output=$(PATH="${fake_bin}:$PATH" HOME="${home_dir}" AIDEVOPS_WORK_DIR="${conversation_work_dir}" \
    "${HELPER}" conversation --overlay "${conversation_overlay}" --dir "${launch_dir}" --auto 2>&1); then
    _fail "restricted conversation accepted --auto: ${output}"
else
    [[ "${output}" == *"rejects --auto"* ]] \
        && _pass "restricted conversation rejects --auto" \
        || _fail "restricted conversation --auto rejection unexpected: ${output}"
fi

if output=$(PATH="${fake_bin}:$PATH" HOME="${home_dir}" AIDEVOPS_WORK_DIR="${conversation_work_dir}" \
    "${HELPER}" conversation --overlay "${conversation_overlay}" --dir "${launch_dir}" -- --model synthetic 2>&1); then
    _fail "restricted conversation accepted argument passthrough: ${output}"
else
    [[ "${output}" == *"rejects argument passthrough"* ]] \
        && _pass "restricted conversation rejects argument passthrough" \
        || _fail "restricted conversation passthrough rejection unexpected: ${output}"
fi

if output=$(PATH="${fake_bin}:$PATH" HOME="${home_dir}" AIDEVOPS_WORK_DIR="${conversation_work_dir}" \
    "${HELPER}" conversation --overlay "${conversation_overlay}" --dir / --dry-run 2>&1); then
    _fail "restricted conversation accepted an unsafe cwd: ${output}"
else
    [[ "${output}" == *"registered canonical project or linked worktree root"* ]] \
        && _pass "restricted conversation rejects unsafe cwd" \
        || _fail "restricted conversation cwd rejection unexpected: ${output}"
fi

conversation_overlay_link="${tmp_root}/conversation-overlay-link.json"
ln -s "${conversation_overlay}" "${conversation_overlay_link}"
if output=$(PATH="${fake_bin}:$PATH" HOME="${home_dir}" AIDEVOPS_WORK_DIR="${conversation_work_dir}" \
    "${HELPER}" conversation --overlay "${conversation_overlay_link}" --dir "${launch_dir}" --dry-run 2>&1); then
    _fail "restricted conversation accepted a symlink overlay: ${output}"
else
    [[ "${output}" == *"non-symlink file"* ]] \
        && _pass "restricted conversation rejects symlink overlays" \
        || _fail "restricted conversation symlink rejection unexpected: ${output}"
fi

if output=$(PATH="${fake_bin}:$PATH" HOME="${home_dir}" AIDEVOPS_WORK_DIR="${conversation_work_dir}" \
    OPENCODE_CONFIG_CONTENT='{}' \
    "${HELPER}" conversation --overlay "${conversation_overlay}" --dir "${launch_dir}" --dry-run 2>&1); then
    _fail "restricted conversation accepted config environment widening: ${output}"
else
    [[ "${output}" == *"rejects inherited OPENCODE_CONFIG_CONTENT"* ]] \
        && _pass "restricted conversation rejects config environment widening" \
        || _fail "restricted conversation environment rejection unexpected: ${output}"
fi

remote_work_dir="${tmp_root}/remote-work"
mkdir -p "${remote_work_dir}"
rm -f "${fake_log}"
output=$(PATH="${fake_bin}:$PATH" HOME="${home_dir}" AIDEVOPS_WORK_DIR="${remote_work_dir}" \
    FAKE_OPENCODE_LOG="${fake_log}" \
    "${HELPER}" remote-interactive --overlay "${remote_interactive_overlay}" \
    --dir "${launch_dir}" --session-id test-host-build-plus 2>&1)
remote_line_count=0
while IFS= read -r _; do
    remote_line_count=$((remote_line_count + 1))
done <"${fake_log}"
remote_auth_count=0
remote_auth_file="${remote_work_dir}/opencode-interactive/buzz-test-host-build-plus/opencode/auth.json"
[[ -f "${remote_auth_file}" ]] && remote_auth_count=1
if [[ "${output}" == *"ARGS=acp --cwd ${launch_dir}"* ]] \
    && [[ "${output}" == *"PWD=${launch_dir}"* ]] \
    && [[ "${output}" == *"AIDEVOPS_SESSION_ORIGIN=interactive"* ]] \
    && [[ "${output}" == *"AIDEVOPS_REMOTE_INTERFACE=1"* ]] \
    && [[ "${output}" == *"AIDEVOPS_REMOTE_PROJECT_ROOT=${launch_dir}"* ]] \
    && [[ "${output}" == *"AIDEVOPS_TEAM_INTERFACE_OVERLAY=${remote_interactive_overlay}"* ]] \
    && [[ "${output}" == *"OPENCODE_DISABLE_AUTOCOMPACT="* ]] \
    && [[ "${output}" == *"OPENCODE_DISABLE_AUTOUPDATE=1"* ]] \
    && [[ "${remote_line_count}" == "2" ]] \
    && [[ "${remote_auth_count}" == "1" ]]; then
    _pass "remote interactive launcher preserves full profile and native compaction"
else
    _fail "remote interactive launch output unexpected: ${output}"
fi

if output=$(PATH="${fake_bin}:$PATH" HOME="${home_dir}" AIDEVOPS_WORK_DIR="${remote_work_dir}" \
    AIDEVOPS_REMOTE_REQUIRE_PINNED_RUNTIME=1 \
    "${HELPER}" remote-interactive --overlay "${remote_interactive_overlay}" \
    --dir "${launch_dir}" --session-id test-host-build-plus --dry-run 2>&1); then
    _fail "remote interactive launcher accepted a required but missing runtime anchor: ${output}"
else
    [[ "${output}" == *"requires an installed immutable anchor"* ]] \
        && _pass "remote interactive launcher enforces required immutable anchor" \
        || _fail "remote interactive runtime anchor rejection unexpected: ${output}"
fi

remote_dry_run_work_dir="${tmp_root}/remote-dry-run-work"
mkdir -p "${remote_dry_run_work_dir}"
output=$(PATH="${fake_bin}:$PATH" HOME="${home_dir}" AIDEVOPS_WORK_DIR="${remote_dry_run_work_dir}" \
    "${HELPER}" remote-interactive --overlay "${remote_interactive_overlay}" \
    --dir "${launch_dir}" --session-id test-host-build-plus --dry-run 2>&1)
if [[ "${output}" == *"AIDEVOPS_REMOTE_INTERFACE=1"* ]] \
    && [[ "${output}" == *"validated-overlay:sha256:"* ]] \
    && [[ "${output}" != *"${remote_interactive_overlay}"* ]] \
    && directory_is_empty "${remote_dry_run_work_dir}"; then
    _pass "remote interactive dry-run is redacted and non-mutating"
else
    _fail "remote interactive dry-run output unexpected: ${output}"
fi

if output=$(PATH="${fake_bin}:$PATH" HOME="${home_dir}" AIDEVOPS_WORK_DIR="${remote_work_dir}" \
    OPENCODE_DISABLE_AUTOCOMPACT=1 \
    "${HELPER}" remote-interactive --overlay "${remote_interactive_overlay}" \
    --dir "${launch_dir}" --session-id test-host-build-plus --dry-run 2>&1); then
    _fail "remote interactive launcher accepted disabled compaction: ${output}"
else
    [[ "${output}" == *"rejects inherited OPENCODE_DISABLE_AUTOCOMPACT"* ]] \
        && _pass "remote interactive launcher rejects disabled compaction" \
        || _fail "remote interactive compaction rejection unexpected: ${output}"
fi

if output=$(PATH="${fake_bin}:$PATH" HOME="${home_dir}" AIDEVOPS_WORK_DIR="${remote_work_dir}" \
    "${HELPER}" remote-interactive --overlay "${conversation_overlay}" \
    --dir "${launch_dir}" --session-id test-host-build-plus --dry-run 2>&1); then
    _fail "remote interactive launcher accepted the read-only overlay: ${output}"
else
    [[ "${output}" == *"overlay validation failed"* ]] \
        && _pass "remote interactive launcher rejects read-only overlays" \
        || _fail "remote interactive profile rejection unexpected: ${output}"
fi

if ((fail_count > 0)); then
    printf '\n%b%d test(s) failed%b\n' "${TEST_RED}" "${fail_count}" "${TEST_NC}" >&2
    exit 1
fi

printf '\n%bAll %d tests passed%b\n' "${TEST_GREEN}" "${pass_count}" "${TEST_NC}"

#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Launch OpenCode with aidevops-managed direct-client or server-owned data.
# Direct clients stay off the shared ~/.local/share/opencode/opencode.db hot spot;
# opt-in server clients share history through one loopback owner instead of SQLite.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1

# shellcheck disable=SC1091
if [[ -f "${SCRIPT_DIR}/shared-constants.sh" ]]; then
    source "${SCRIPT_DIR}/shared-constants.sh"
fi

[[ -z "${GREEN+x}" ]] && GREEN=$'\033[0;32m'
[[ -z "${YELLOW+x}" ]] && YELLOW=$'\033[1;33m'
[[ -z "${RED+x}" ]] && RED=$'\033[0;31m'
[[ -z "${NC+x}" ]] && NC=$'\033[0m'

print_info() { printf '%b[INFO]%b %s\n' "${YELLOW}" "${NC}" "$*"; return 0; }
print_success() { printf '%b[OK]%b %s\n' "${GREEN}" "${NC}" "$*"; return 0; }
print_error() { printf '%b[ERROR]%b %s\n' "${RED}" "${NC}" "$*" >&2; return 0; }

OPT_DESKTOP_SOURCE_BINARY="--source-binary"
ERR_DIR_REQUIRES_PATH="--dir requires a path"
ERR_SESSION_ID_REQUIRES_VALUE="--session-id requires a value"
SERVER_CHILD_PID=""
SERVER_LOCK_DIR=""

usage() {
    cat <<'EOF'
Usage: aidevops opencode [options] [--] [opencode args...]
       aidevops opencode conversation --overlay FILE --dir PATH [--dry-run]
       aidevops opencode remote-interactive --overlay FILE --dir PATH --session-id ID [--dry-run]
       aidevops opencode server --dir PATH --port PORT [options]
       aidevops opencode attach URL --dir PATH [options]
       aidevops opencode-desktop [launch options]
       aidevops opencode-desktop install-shortcut [options]
       aidevops opencode-desktop status [options]

Launch OpenCode with an isolated per-project SQLite DB by default.

Options:
  --shared-db          Use OpenCode's normal shared data directory
  --dir PATH           Working directory for OpenCode (default: current dir)
  --session-id ID      Explicit isolated DB name (default: stable per-project shard)
  --tabby-shell        Restore Tabby's exact saved session, then leave zsh open
  --dry-run            Print the environment/command without executing
  -h, --help           Show this help

Server options:
  --dir PATH           Project directory (default: current dir)
  --port PORT          Required loopback port (1-65535)
  --session-id ID      Explicit server shard name (default: stable per-project shard)
  --dry-run            Print without creating the shard or checking the listener
  Authentication environment variables are unsupported in this loopback prototype.

Attach options:
  --dir PATH           Project directory (default: current dir)
  --session ID         Resume a specific server-owned session
  --dry-run            Print without checking health or starting the TUI

Restricted conversation options:
  --overlay FILE       Canonical generated team-interface overlay
  --dir PATH           Verified OpenCode ACP working directory (required)
  --dry-run            Validate inputs and print a redacted fixed command
  Arbitrary passthrough, --auto, model overrides, and config/plugin bypasses are rejected.

Remote interactive options:
  --overlay FILE       Canonical generated remote-interactive team overlay
  --dir PATH           Registered linked worktree used for the full session
  --session-id ID      Stable per-agent isolated OpenCode data shard
  --dry-run            Validate inputs and print a redacted fixed command
  Uses normal aidevops tools, MCPs, subagents, model routing, and compaction.

Examples:
  aidevops opencode
  aidevops opencode --dir ~/Git/aidevops
  aidevops opencode -- --version
  aidevops opencode conversation --overlay overlay.json --dir ~/Git/aidevops
  aidevops opencode server --dir ~/Git/aidevops --port 49036
  aidevops opencode attach http://127.0.0.1:49036 --dir ~/Git/aidevops
  aidevops opencode-desktop
  aidevops opencode-desktop install-shortcut
EOF
    return 0
}

desktop_usage() {
    cat <<EOF
Usage: aidevops opencode-desktop [launch options]
       aidevops opencode-desktop install-shortcut [options]
       aidevops opencode-desktop status [options]

Launch OpenCode Desktop with an aidevops-managed XDG_DATA_HOME so the Desktop
app does not write to the shared ~/.local/share/opencode/opencode.db hot spot.

Launch options:
  --dir PATH             Working directory for Desktop (default: cwd; app bundle: HOME)
  --session-id ID        Explicit isolated DB name (default: desktop-default or per-project)
  --data-dir PATH        Explicit XDG_DATA_HOME for Desktop
  ${OPT_DESKTOP_SOURCE_BINARY} PATH   OpenCode.app executable path
  --dry-run              Print the command without launching

Shortcut options:
  --name NAME            App display name (default: OpenCode AIDevOps)
  --app-dir PATH         Parent directory for the generated .app (default: ~/Applications)
  ${OPT_DESKTOP_SOURCE_BINARY} PATH   OpenCode.app executable path
  --dry-run              Print the target path without writing

Environment overrides:
  AIDEVOPS_OPENCODE_DESKTOP_APP_DIR       Parent directory for generated .app
  AIDEVOPS_OPENCODE_DESKTOP_BINARY        OpenCode Desktop executable path
  AIDEVOPS_OPENCODE_DESKTOP_DATA_DIR      Explicit Desktop XDG_DATA_HOME
EOF
    return 0
}

sql_escape_label() {
    local value="$1"
    value=${value//[^A-Za-z0-9._-]/-}
    value=${value#-}
    value=${value%-}
    printf '%s' "${value:-session}"
    return 0
}

copy_auth_json() {
    local target_data_dir="$1"
    local source_auth="${XDG_DATA_HOME:-${HOME}/.local/share}/opencode/auth.json"
    local target_auth="${target_data_dir}/opencode/auth.json"

    [[ -f "${source_auth}" ]] || return 0
    [[ "${source_auth}" == "${target_auth}" ]] && return 0
    mkdir -p "$(dirname "${target_auth}")" || return 1
    cp "${source_auth}" "${target_auth}" || return 1
    chmod 600 "${target_auth}" 2>/dev/null || true
    return 0
}

prewarm_opencode_data_dir() {
    local target_data_dir="$1"

    # OpenCode writes a first-run database migration progress bar to stderr
    # before the TUI starts when opencode.db is absent. Run that migration with
    # stderr/stdout detached so the subsequent interactive TUI starts on a clean
    # terminal frame.
    [[ -f "${target_data_dir}/opencode/opencode.db" ]] && return 0
    XDG_DATA_HOME="${target_data_dir}" opencode db path >/dev/null 2>&1 || true
    return 0
}

build_session_data_dir() {
    local session_id="$1"
    local safe_id
    safe_id=$(sql_escape_label "${session_id}")
    printf '%s/opencode-interactive/%s' "${AIDEVOPS_WORK_DIR:-${HOME}/.aidevops/.agent-workspace/work}" "${safe_id}"
    return 0
}

build_server_data_dir() {
    local session_id="$1"
    local safe_id=""

    safe_id=$(sql_escape_label "${session_id}")
    printf '%s/opencode-server/%s' "${AIDEVOPS_WORK_DIR:-${HOME}/.aidevops/.agent-workspace/work}" "${safe_id}"
    return 0
}

build_project_session_id() {
    local launch_dir="$1"
    local resolved_dir=""
    local base_name=""
    local checksum=""

    resolved_dir=$(cd "${launch_dir}" && pwd -P) || resolved_dir="${launch_dir}"
    base_name=$(basename "${resolved_dir}")
    checksum=$(printf '%s' "${resolved_dir}" | cksum)
    checksum=${checksum%% *}
    printf 'project-%s-%s' "$(sql_escape_label "${base_name}")" "${checksum}"
    return 0
}

build_desktop_data_dir() {
    local session_id="$1"
    local launch_dir="${2:-}"
    local safe_id=""

    if [[ -z "${session_id}" ]]; then
        if [[ -n "${launch_dir}" ]]; then
            session_id="desktop-$(build_project_session_id "${launch_dir}")"
        else
            session_id="desktop-default"
        fi
    fi
    safe_id=$(sql_escape_label "${session_id}")
    printf '%s/opencode-desktop/%s' "${AIDEVOPS_WORK_DIR:-${HOME}/.aidevops/.agent-workspace/work}" "${safe_id}"
    return 0
}

validate_launch_directory() {
    local launch_dir="$1"

    if [[ ! -d "${launch_dir}" ]]; then
        print_error "Directory not found: ${launch_dir}"
        return 1
    fi
    return 0
}

resolve_tabby_recovery() {
    local recovered_cwd="$1"
    local work_dir="$2"
    local resolver="${SCRIPT_DIR}/../plugins/opencode-aidevops/session-recovery-marker.mjs"
    local resolution=""
    local resolver_status=0

    require_node_cli || return 1
    if resolution=$(node "${resolver}" resolve --cwd "${recovered_cwd}" --work-dir "${work_dir}"); then
        IFS=$'\t' read -r TABBY_RECOVERY_LAUNCH_DIR TABBY_RECOVERY_DATA_DIR TABBY_RECOVERY_SESSION_ID <<<"${resolution}"
        if [[ -z "${TABBY_RECOVERY_LAUNCH_DIR}" || -z "${TABBY_RECOVERY_DATA_DIR}" || -z "${TABBY_RECOVERY_SESSION_ID}" ]]; then
            print_error "Tabby session recovery returned incomplete data"
            return 1
        fi
        return 0
    else
        resolver_status=$?
    fi
    ((resolver_status == 2)) && return 2
    print_error "Tabby session recovery marker validation failed"
    return 1
}

emit_tabby_current_directory() {
    local directory="$1"

    [[ "${directory}" != *$'\n'* && "${directory}" != *$'\r'* ]] || return 1
    printf '\033]1337;CurrentDir=%s\007' "${directory}" >/dev/tty || return 1
    return 0
}

opencode_args_contain_session() {
    local argument=""

    for argument in "$@"; do
        case "${argument}" in
        --session | --session=*) return 0 ;;
        esac
    done
    return 1
}

run_isolated_tui() {
    local launch_dir="$1"
    local data_dir="$2"
    local tabby_shell="$3"
    local dry_run="$4"
    shift 4
    local -a opencode_args=("$@")

    if ((dry_run == 1)); then
        printf 'cd %q && TMPDIR=%q TMP=%q TEMP=%q XDG_DATA_HOME=%q AIDEVOPS_OPENCODE_ISOLATED_DB=1' "${launch_dir}" "${TMPDIR}" "${TMP}" "${TEMP}" "${data_dir}"
        ((tabby_shell == 1)) && printf ' AIDEVOPS_TABBY_SESSION_RECOVERY=1'
        printf ' opencode'
        printf ' %q' "${opencode_args[@]}"
        ((tabby_shell == 1)) && printf '; cd %q && exec /bin/zsh -l' "${launch_dir}"
        printf '\n'
        return 0
    fi

    mkdir -p "${data_dir}/opencode" || return 1
    # Keep stdout/stderr clean before exec: OpenCode's TUI is sensitive to any
    # pre-launch terminal output and can leave visible redraw artifacts.
    copy_auth_json "${data_dir}" || true
    prewarm_opencode_data_dir "${data_dir}"

    cd "${launch_dir}" || return 1
    export XDG_DATA_HOME="${data_dir}"
    export AIDEVOPS_OPENCODE_ISOLATED_DB=1
    if ((tabby_shell == 1)); then
        export AIDEVOPS_TABBY_SESSION_RECOVERY=1
        if ! opencode "${opencode_args[@]}"; then
            : # Preserve the existing profile behavior: leave a shell open after any TUI exit.
        fi
        cd "${launch_dir}" || return 1
        if ! emit_tabby_current_directory "${launch_dir}"; then
            : # Shell startup will report the real project directory to Tabby.
        fi
        exec /bin/zsh -l
        return 1
    fi
    exec opencode "${opencode_args[@]}"
    return 1
}

require_opencode_cli() {
    if ! command -v opencode >/dev/null 2>&1; then
        print_error "opencode not found in PATH"
        return 1
    fi
    return 0
}

require_node_cli() {
    if ! command -v node >/dev/null 2>&1; then
        print_error "node not found in PATH"
        return 1
    fi
    return 0
}

reject_server_auth_environment() {
    if [[ -n "${OPENCODE_SERVER_PASSWORD:-}" || -n "${OPENCODE_SERVER_USERNAME:-}" ]]; then
        print_error "Authenticated server mode is not supported by this loopback prototype. Unset OPENCODE_SERVER_PASSWORD and OPENCODE_SERVER_USERNAME."
        return 1
    fi
    return 0
}

reject_conversation_environment() {
    local variable=""
    local value=""

    for variable in \
        AIDEVOPS_TEAM_INTERFACE_OVERLAY \
        AIDEVOPS_CONVERSATION_PROJECT_ROOT \
        AIDEVOPS_CONVERSATION_RUNTIME_ROOT \
        AIDEVOPS_SIG_MODEL \
        BUZZ_ACP_MODEL \
        OPENCODE_CONFIG \
        OPENCODE_CONFIG_CONTENT \
        OPENCODE_CONFIG_DIR \
        OPENCODE_DISABLE_DEFAULT_PLUGINS \
        OPENCODE_MODEL \
        OPENCODE_PURE; do
        value="${!variable:-}"
        if [[ -n "${value}" ]]; then
            print_error "Restricted conversation mode rejects inherited ${variable}"
            return 1
        fi
    done
    reject_server_auth_environment || return 1
    return 0
}

canonical_conversation_directory() {
    local launch_dir="$1"
    local overlay_script="${SCRIPT_DIR}/team-interface-opencode-overlay.mjs"
    local repos_file="${HOME}/.config/aidevops/repos.json"
    local resolved_dir=""

    if [[ -z "${launch_dir}" || "${launch_dir}" == -* || "${launch_dir}" =~ [[:cntrl:]] ]]; then
        print_error "Restricted conversation cwd is invalid"
        return 1
    fi
    if [[ ! -f "${repos_file}" || -L "${repos_file}" ]]; then
        print_error "Registered repository metadata is unavailable"
        return 1
    fi
    if ! resolved_dir=$(node "${overlay_script}" validate-project-root \
        --dir "${launch_dir}" --repos "${repos_file}" 2>/dev/null); then
        print_error "Restricted conversation cwd must be a registered canonical project or linked worktree root"
        return 1
    fi
    printf '%s' "${resolved_dir}"
    return 0
}

canonical_conversation_overlay() {
    local overlay_path="$1"
    local overlay_dir=""
    local overlay_name=""
    local resolved_dir=""

    if [[ -z "${overlay_path}" || "${overlay_path}" != /* || "${overlay_path}" =~ [[:cntrl:]] ]]; then
        print_error "Restricted conversation overlay path must be absolute"
        return 1
    fi
    if [[ ! -f "${overlay_path}" || -L "${overlay_path}" ]]; then
        print_error "Restricted conversation overlay must be a regular non-symlink file"
        return 1
    fi
    overlay_dir=${overlay_path%/*}
    overlay_name=${overlay_path##*/}
    [[ -n "${overlay_dir}" ]] || overlay_dir="/"
    resolved_dir=$(cd "${overlay_dir}" && pwd -P) || return 1
    printf '%s/%s' "${resolved_dir%/}" "${overlay_name}"
    return 0
}

validate_conversation_overlay() {
    local overlay_path="$1"
    local permission_profile="${2:-conversation_read_only_v1}"
    local overlay_script="${SCRIPT_DIR}/team-interface-opencode-overlay.mjs"
    local overlay_digest=""

    if [[ ! -f "${overlay_script}" ]]; then
        print_error "Restricted conversation overlay validator is unavailable"
        return 1
    fi
    require_node_cli || return 1
    if ! overlay_digest=$(node "${overlay_script}" validate \
        --overlay "${overlay_path}" --agents-dir "${SCRIPT_DIR}/.." \
        --permission-profile "${permission_profile}" 2>/dev/null); then
        print_error "Restricted conversation overlay validation failed"
        return 1
    fi
    if [[ ! "${overlay_digest}" =~ ^sha256:[a-f0-9]{64}$ ]]; then
        print_error "Restricted conversation overlay validator returned an invalid digest"
        return 1
    fi
    printf '%s' "${overlay_digest}"
    return 0
}

reject_remote_interactive_environment() {
    local variable=""
    local value=""

	for variable in \
		AIDEVOPS_REMOTE_RUNTIME_ANCHOR \
		AIDEVOPS_REMOTE_PROJECT_ROOT \
        AIDEVOPS_TEAM_INTERFACE_OVERLAY \
        OPENCODE_CONFIG \
        OPENCODE_CONFIG_CONTENT \
        OPENCODE_CONFIG_DIR \
        OPENCODE_DISABLE_AUTOCOMPACT \
        OPENCODE_DISABLE_DEFAULT_PLUGINS \
        OPENCODE_DISABLE_PROJECT_CONFIG \
        OPENCODE_MODEL \
        OPENCODE_PURE; do
        value="${!variable:-}"
        if [[ -n "${value}" ]]; then
            print_error "Remote interactive mode rejects inherited ${variable}"
            return 1
        fi
    done
	return 0
}

resolve_remote_runtime_anchor() {
	local runtime_root=""
	local marker=""
	local config_home=""
	local anchored_scripts=""
	runtime_root=$(cd "${SCRIPT_DIR}/../.." && pwd -P) || return 1
	marker="${runtime_root}/buzz-runtime-anchor-v1.json"
	config_home="${runtime_root}/opencode-config"
	if [[ ! -e "$marker" ]]; then
		return 2
	fi
	if [[ ! -f "$marker" || -L "$marker" || ! -f "${config_home}/opencode/opencode.json" || -L "${config_home}/opencode/opencode.json" ]]; then
		print_error "Remote interactive runtime anchor is incomplete or unsafe"
		return 1
	fi
	anchored_scripts=$(cd "${runtime_root}/agents/scripts" && pwd -P) || return 1
	if [[ "$anchored_scripts" != "$SCRIPT_DIR" ]]; then
		print_error "Remote interactive launcher is outside its runtime anchor"
		return 1
	fi
	if ! jq -e '
		def valid_digest: test("^[a-f0-9]{64}$");
		.schema_version == 2
		and .runtime_id == "aidevops-interactive-v1"
		and (.agents_digest | valid_digest)
		and (.config_digest | valid_digest)
		and (.content_digest | valid_digest)
	' "$marker" >/dev/null; then
		print_error "Remote interactive runtime anchor marker is invalid"
		return 1
	fi
	if ! python3 "${SCRIPT_DIR}/team-interface-buzz-runtime.py" verify-anchor \
		--root "$runtime_root" --runtime interactive >/dev/null; then
		print_error "Remote interactive runtime anchor content verification failed"
		return 1
	fi
	printf '%s' "$runtime_root"
	return 0
}

verify_conversation_effective_config() {
    local overlay_path="$1"
    local opencode_binary="$2"
    local canonical_dir="$3"
    shift 3
    local overlay_script="${SCRIPT_DIR}/team-interface-opencode-overlay.mjs"
    local -a runtime_environment=("$@")

    if ! (cd "${canonical_dir}" && env -i "${runtime_environment[@]}" \
        "${opencode_binary}" debug config --log-level ERROR 2>/dev/null) \
        | node "${overlay_script}" verify-effective --overlay "${overlay_path}" >/dev/null; then
        print_error "Effective OpenCode config did not preserve the restricted conversation boundary"
        return 1
    fi
    return 0
}

create_conversation_runtime() {
    local overlay_path="$1"
    local result_var="$2"
    local overlay_script="${SCRIPT_DIR}/team-interface-opencode-overlay.mjs"
    local created_runtime_root=""
    local unresolved_runtime_root=""
    local config_directory=""

    [[ "${result_var}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
    unresolved_runtime_root=$(mktemp -d "${AIDEVOPS_TEMP_DIR}/opencode-conversation.XXXXXX") || return 1
    if ! created_runtime_root=$(cd "${unresolved_runtime_root}" && pwd -P); then
        rm -rf "${unresolved_runtime_root}" 2>/dev/null || true
        return 1
    fi
    if ! chmod 700 "${created_runtime_root}" || ! mkdir -p \
        "${created_runtime_root}/cache" \
        "${created_runtime_root}/config/opencode" \
        "${created_runtime_root}/data/opencode" \
        "${created_runtime_root}/home" \
        "${created_runtime_root}/state" \
        "${created_runtime_root}/tmp" || ! chmod 700 \
        "${created_runtime_root}/cache" \
        "${created_runtime_root}/config" \
        "${created_runtime_root}/config/opencode" \
        "${created_runtime_root}/data" \
        "${created_runtime_root}/data/opencode" \
        "${created_runtime_root}/home" \
        "${created_runtime_root}/state" \
        "${created_runtime_root}/tmp"; then
        rm -rf "${created_runtime_root}" 2>/dev/null || true
        return 1
    fi
    config_directory="${created_runtime_root}/config/opencode"
    if ! node "${overlay_script}" prepare-config \
        --overlay "${overlay_path}" \
        --agents-dir "${SCRIPT_DIR}/.." \
        --output "${config_directory}/opencode.json" >/dev/null; then
        rm -rf "${created_runtime_root}" 2>/dev/null || true
        return 1
    fi
    printf -v "${result_var}" '%s' "${created_runtime_root}"
    return 0
}

cleanup_conversation_runtime() {
    local runtime_root="$1"
    [[ -n "${runtime_root}" && -d "${runtime_root}" ]] || return 0
    rm -rf "${runtime_root}" 2>/dev/null || return 1
    return 0
}

validate_server_port() {
    local port="$1"
    local port_pattern='^[1-9][0-9]{0,4}$'

    if [[ ! "${port}" =~ ${port_pattern} ]] || ((port > 65535)); then
        print_error "Port must be an integer from 1 to 65535: ${port:-<empty>}"
        return 1
    fi
    return 0
}

validate_loopback_url() {
    local server_url="$1"
    local url_pattern='^http://127[.]0[.]0[.]1:([1-9][0-9]{0,4})/?$'
    local port=""

    if [[ ! "${server_url}" =~ ${url_pattern} ]]; then
        print_error "Server URL must be an explicit loopback endpoint such as http://127.0.0.1:49036"
        return 1
    fi
    port="${BASH_REMATCH[1]}"
    validate_server_port "${port}" || return 1
    printf 'http://127.0.0.1:%s' "${port}"
    return 0
}

server_port_is_occupied() {
    local port="$1"
    local probe_available=0

    if command -v lsof >/dev/null 2>&1; then
        probe_available=1
        if lsof -iTCP:"${port}" -sTCP:LISTEN -P -n >/dev/null 2>&1; then
            return 0
        fi
    fi
    if command -v nc >/dev/null 2>&1; then
        probe_available=1
        if nc -z 127.0.0.1 "${port}" >/dev/null 2>&1; then
            return 0
        fi
    fi
    ((probe_available == 1)) && return 1
    print_error "Cannot verify port ${port}; install lsof or nc before starting server mode"
    return 2
}

server_shard_has_holders() {
    local data_dir="$1"
    local db_path="${data_dir}/opencode/opencode.db"
    local candidate=""
    local -a db_files=()

    for candidate in "${db_path}" "${db_path}-wal" "${db_path}-shm"; do
        [[ -e "${candidate}" ]] && db_files+=("${candidate}")
    done
    ((${#db_files[@]} > 0)) || return 1
    if ! command -v lsof >/dev/null 2>&1; then
        print_error "Cannot verify existing server shard holders because lsof is unavailable: ${data_dir}"
        return 2
    fi
    lsof "${db_files[@]}" >/dev/null 2>&1
    return $?
}

release_server_lock() {
    if [[ -n "${SERVER_LOCK_DIR}" ]]; then
        rm -f "${SERVER_LOCK_DIR}/pid" 2>/dev/null || true
        rmdir "${SERVER_LOCK_DIR}" 2>/dev/null || true
        SERVER_LOCK_DIR=""
    fi
    return 0
}

forward_server_signal() {
    local signal="$1"

    if [[ "${SERVER_CHILD_PID}" =~ ^[0-9]+$ ]] && kill -0 "${SERVER_CHILD_PID}" 2>/dev/null; then
        kill -s "${signal}" "${SERVER_CHILD_PID}" 2>/dev/null || true
    fi
    return 0
}

acquire_server_lock() {
    local data_dir="$1"
    local lock_dir="${data_dir}/.aidevops-server-owner"
    local owner_pid=""

    if ! mkdir "${lock_dir}" 2>/dev/null; then
        if [[ -r "${lock_dir}/pid" ]]; then
            read -r owner_pid <"${lock_dir}/pid" || owner_pid=""
        fi
        if [[ "${owner_pid}" =~ ^[0-9]+$ ]] && kill -0 "${owner_pid}" 2>/dev/null; then
            print_error "Server shard already has an owner (PID ${owner_pid}): ${data_dir}"
        else
            print_error "Server shard has a stale owner lock: ${lock_dir}. Verify no DB holders, then remove the lock."
        fi
        return 1
    fi
    if ! printf '%s\n' "$$" >"${lock_dir}/pid"; then
        rmdir "${lock_dir}" 2>/dev/null || true
        return 1
    fi
    SERVER_LOCK_DIR="${lock_dir}"
    return 0
}

validate_server_health() {
    local server_url="$1"
    local health_json=""
    local server_version=""
    local cli_version=""

    command -v curl >/dev/null 2>&1 || { print_error "curl is required to validate the OpenCode server"; return 1; }
    command -v jq >/dev/null 2>&1 || { print_error "jq is required to validate the OpenCode server"; return 1; }
    if ! health_json=$(curl --fail --silent --show-error --max-time 3 --noproxy '*' "${server_url}/global/health" 2>/dev/null); then
        print_error "OpenCode server health check failed: ${server_url}/global/health"
        return 1
    fi
    if ! server_version=$(printf '%s' "${health_json}" | jq -er 'select(.healthy == true) | .version | select(type == "string" and length > 0)' 2>/dev/null); then
        print_error "OpenCode server returned an invalid health response: ${server_url}/global/health"
        return 1
    fi
    if ! cli_version=$(opencode --version 2>/dev/null); then
        print_error "Could not determine the installed OpenCode CLI version"
        return 1
    fi
    cli_version=${cli_version#v}
    server_version=${server_version#v}
    if [[ "${server_version}" != "${cli_version}" ]]; then
        print_error "OpenCode server version ${server_version} does not match installed CLI version ${cli_version}"
        return 1
    fi
    return 0
}

xml_escape() {
    local value="$1"
    value=${value//&/\&amp;}
    value=${value//</\&lt;}
    value=${value//>/\&gt;}
    value=${value//\"/\&quot;}
    value=${value//\'/\&apos;}
    printf '%s' "${value}"
    return 0
}

write_file_if_changed() {
    local path="$1"
    local content="$2"
    local tmp_path="${path}.tmp.$$"

    if [[ -f "${path}" ]]; then
        printf '%s' "${content}" >"${tmp_path}" || return 1
        if cmp -s "${tmp_path}" "${path}"; then
            rm -f "${tmp_path}" || true
            return 0
        fi
        mv "${tmp_path}" "${path}" || return 1
        return 0
    fi
    printf '%s' "${content}" >"${path}" || return 1
    return 0
}

is_macos() {
    if [[ "$(uname -s)" == "Darwin" ]]; then
        return 0
    fi
    return 1
}

detect_desktop_binary() {
    local explicit_binary="${1:-}"

    if [[ -n "${explicit_binary}" ]]; then
        [[ -x "${explicit_binary}" ]] || return 1
        printf '%s' "${explicit_binary}"
        return 0
    fi
    if [[ -n "${AIDEVOPS_OPENCODE_DESKTOP_BINARY:-}" ]]; then
        [[ -x "${AIDEVOPS_OPENCODE_DESKTOP_BINARY}" ]] || return 1
        printf '%s' "${AIDEVOPS_OPENCODE_DESKTOP_BINARY}"
        return 0
    fi
    if [[ -x "/Applications/OpenCode.app/Contents/MacOS/OpenCode" ]]; then
        printf '%s' "/Applications/OpenCode.app/Contents/MacOS/OpenCode"
        return 0
    fi
    if [[ -x "${HOME}/Applications/OpenCode.app/Contents/MacOS/OpenCode" ]]; then
        printf '%s' "${HOME}/Applications/OpenCode.app/Contents/MacOS/OpenCode"
        return 0
    fi
    return 1
}

desktop_app_path() {
    local app_name="$1"
    local app_dir="$2"
    local safe_name=""

    safe_name=${app_name//\//-}
    safe_name=${safe_name:-OpenCode AIDevOps}
    printf '%s/%s.app' "${app_dir}" "${safe_name}"
    return 0
}

desktop_wrapper_content() {
    cat <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

helper="${AIDEVOPS_OPENCODE_LAUNCHER_HELPER:-${HOME}/.aidevops/agents/scripts/opencode-launcher-helper.sh}"
if [[ ! -x "${helper}" ]]; then
    osascript -e 'display alert "OpenCode AIDevOps launcher is not installed" message "Run aidevops update, then open this app again."' >/dev/null 2>&1 || true
    exit 1
fi

exec "${helper}" desktop launch --from-app "$@"
EOF
    return 0
}

desktop_plist_content() {
    local app_name="$1"
    local bundle_id="$2"
    local executable_name="$3"

    cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>
  <string>$(xml_escape "${app_name}")</string>
  <key>CFBundleDisplayName</key>
  <string>$(xml_escape "${app_name}")</string>
  <key>CFBundleIdentifier</key>
  <string>$(xml_escape "${bundle_id}")</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleExecutable</key>
  <string>$(xml_escape "${executable_name}")</string>
  <key>LSMinimumSystemVersion</key>
  <string>10.13</string>
</dict>
</plist>
EOF
    return 0
}

cmd_desktop_install_shortcut() {
    local app_name="OpenCode AIDevOps"
    local app_dir="${AIDEVOPS_OPENCODE_DESKTOP_APP_DIR:-${HOME}/Applications}"
    local source_binary=""
    local dry_run=0

    while (($# > 0)); do
        case "$1" in
        --name)
            [[ $# -ge 2 ]] || { print_error "--name requires a value"; return 1; }
            app_name="$2"
            shift 2
            ;;
        --app-dir)
            [[ $# -ge 2 ]] || { print_error "--app-dir requires a path"; return 1; }
            app_dir="$2"
            shift 2
            ;;
        "${OPT_DESKTOP_SOURCE_BINARY}")
            [[ $# -ge 2 ]] || { print_error "${OPT_DESKTOP_SOURCE_BINARY} requires a path"; return 1; }
            source_binary="$2"
            shift 2
            ;;
        --dry-run)
            dry_run=1
            shift
            ;;
        --help | -h)
            desktop_usage
            return 0
            ;;
        *)
            print_error "Unknown install-shortcut option: $1"
            return 1
            ;;
        esac
    done

    if ! is_macos; then
        print_info "OpenCode Desktop app shortcut install is currently macOS-only"
        return 0
    fi
    if ! detect_desktop_binary "${source_binary}" >/dev/null 2>&1; then
        print_info "OpenCode Desktop app not found; skipping shortcut install"
        return 3
    fi

    local app_path=""
    local contents_dir=""
    local macos_dir=""
    local plist_path=""
    local executable_name="opencode-aidevops"
    local executable_path=""
    local bundle_id="sh.aidevops.opencode.desktop"

    app_path=$(desktop_app_path "${app_name}" "${app_dir}")
    contents_dir="${app_path}/Contents"
    macos_dir="${contents_dir}/MacOS"
    plist_path="${contents_dir}/Info.plist"
    executable_path="${macos_dir}/${executable_name}"

    if ((dry_run == 1)); then
        printf '%s\n' "${app_path}"
        return 0
    fi

    mkdir -p "${macos_dir}" || return 1
    write_file_if_changed "${plist_path}" "$(desktop_plist_content "${app_name}" "${bundle_id}" "${executable_name}")" || return 1
    write_file_if_changed "${executable_path}" "$(desktop_wrapper_content)" || return 1
    chmod 755 "${executable_path}" || return 1
    print_success "Installed ${app_name}.app at ${app_path}"
    return 0
}

cmd_desktop_status() {
    local app_name="OpenCode AIDevOps"
    local app_dir="${AIDEVOPS_OPENCODE_DESKTOP_APP_DIR:-${HOME}/Applications}"
    local source_binary=""
    local app_path=""

    while (($# > 0)); do
        case "$1" in
        --name)
            [[ $# -ge 2 ]] || { print_error "--name requires a value"; return 1; }
            app_name="$2"
            shift 2
            ;;
        --app-dir)
            [[ $# -ge 2 ]] || { print_error "--app-dir requires a path"; return 1; }
            app_dir="$2"
            shift 2
            ;;
        "${OPT_DESKTOP_SOURCE_BINARY}")
            [[ $# -ge 2 ]] || { print_error "${OPT_DESKTOP_SOURCE_BINARY} requires a path"; return 1; }
            source_binary="$2"
            shift 2
            ;;
        --help | -h)
            desktop_usage
            return 0
            ;;
        *)
            print_error "Unknown status option: $1"
            return 1
            ;;
        esac
    done

    app_path=$(desktop_app_path "${app_name}" "${app_dir}")
    if [[ -d "${app_path}" ]]; then
        print_success "Desktop shortcut installed: ${app_path}"
    else
        print_info "Desktop shortcut not installed: ${app_path}"
    fi
    if detect_desktop_binary "${source_binary}" >/dev/null 2>&1; then
        print_success "OpenCode Desktop source app found"
    else
        print_info "OpenCode Desktop source app not found"
    fi
    return 0
}

cmd_desktop_launch() {
    local dry_run=0
    local launch_dir="$PWD"
    local launch_dir_set=0
    local from_app=0
    local session_id=""
    local data_dir="${AIDEVOPS_OPENCODE_DESKTOP_DATA_DIR:-}"
    local source_binary=""
    local -a desktop_args=()

    while (($# > 0)); do
        case "$1" in
        --dir)
            [[ $# -ge 2 ]] || { print_error "${ERR_DIR_REQUIRES_PATH}"; return 1; }
            launch_dir="$2"
            launch_dir_set=1
            shift 2
            ;;
        --session-id)
            [[ $# -ge 2 ]] || { print_error "${ERR_SESSION_ID_REQUIRES_VALUE}"; return 1; }
            session_id="$2"
            shift 2
            ;;
        --data-dir)
            [[ $# -ge 2 ]] || { print_error "--data-dir requires a path"; return 1; }
            data_dir="$2"
            shift 2
            ;;
        "${OPT_DESKTOP_SOURCE_BINARY}")
            [[ $# -ge 2 ]] || { print_error "${OPT_DESKTOP_SOURCE_BINARY} requires a path"; return 1; }
            source_binary="$2"
            shift 2
            ;;
        --from-app)
            from_app=1
            shift
            ;;
        --dry-run)
            dry_run=1
            shift
            ;;
        --help | -h)
            desktop_usage
            return 0
            ;;
        --)
            shift
            desktop_args+=("$@")
            break
            ;;
        *)
            desktop_args+=("$1")
            shift
            ;;
        esac
    done

    if ! is_macos; then
        print_error "OpenCode Desktop launch is currently macOS-only"
        return 1
    fi

    local desktop_binary=""
    if ! desktop_binary=$(detect_desktop_binary "${source_binary}"); then
        print_error "OpenCode Desktop app not found. Install OpenCode.app or pass --source-binary PATH."
        return 1
    fi

    if ((from_app == 1 && launch_dir_set == 0)); then
        launch_dir="${HOME}"
    fi
    validate_launch_directory "${launch_dir}" || return 1

    if [[ -z "${data_dir}" ]]; then
        if ((launch_dir_set == 1)); then
            data_dir=$(build_desktop_data_dir "${session_id}" "${launch_dir}")
        else
            data_dir=$(build_desktop_data_dir "${session_id}" "")
        fi
    fi

    if ((dry_run == 1)); then
        printf 'cd %q && TMPDIR=%q TMP=%q TEMP=%q XDG_DATA_HOME=%q AIDEVOPS_OPENCODE_ISOLATED_DB=1 %q' "${launch_dir}" "${TMPDIR}" "${TMP}" "${TEMP}" "${data_dir}" "${desktop_binary}"
        printf ' %q' "${desktop_args[@]}"
        printf '\n'
        return 0
    fi

    mkdir -p "${data_dir}/opencode" || return 1
    copy_auth_json "${data_dir}" || true
    prewarm_opencode_data_dir "${data_dir}"

    cd "${launch_dir}" || return 1
    export XDG_DATA_HOME="${data_dir}"
    export AIDEVOPS_OPENCODE_ISOLATED_DB=1
    exec "${desktop_binary}" "${desktop_args[@]}"
    return 1
}

cmd_desktop() {
    local subcommand="${1:-launch}"
    case "${subcommand}" in
    launch)
        shift || true
        cmd_desktop_launch "$@"
        ;;
    install-shortcut | install-app | install)
        shift || true
        cmd_desktop_install_shortcut "$@"
        ;;
    status)
        shift || true
        cmd_desktop_status "$@"
        ;;
    help | --help | -h)
        desktop_usage
        ;;
    *)
        cmd_desktop_launch "$@"
        ;;
    esac
    return $?
}

run_server_owner() {
    local launch_dir="$1"
    local data_dir="$2"
    local port="$3"
    local holder_status=0
    local port_status=0
    local server_status=0
    local server_url="http://127.0.0.1:${port}"
    local -a serve_args=(serve --pure --hostname 127.0.0.1 --port "${port}" --cors oc://renderer)

    if server_port_is_occupied "${port}"; then
        print_error "Port ${port} is already in use; refusing to start an unknown or duplicate owner"
        return 1
    else
        port_status=$?
        ((port_status != 2)) || return 1
    fi
    if server_shard_has_holders "${data_dir}"; then
        print_error "Server shard already has database holders: ${data_dir}"
        return 1
    else
        holder_status=$?
        ((holder_status != 2)) || return 1
    fi

    mkdir -p "${data_dir}/opencode" || return 1
    acquire_server_lock "${data_dir}" || return 1
    trap release_server_lock EXIT
    if ! copy_auth_json "${data_dir}"; then
        release_server_lock
        trap - EXIT
        return 1
    fi
    prewarm_opencode_data_dir "${data_dir}"
    if ! cd "${launch_dir}"; then
        release_server_lock
        trap - EXIT
        return 1
    fi

    print_info "Starting foreground OpenCode owner on ${server_url}"
    print_info "Server shard: ${data_dir}"
    export XDG_DATA_HOME="${data_dir}"
    export AIDEVOPS_OPENCODE_ISOLATED_DB=1
    export AIDEVOPS_OPENCODE_SERVER_OWNER=1
    trap 'forward_server_signal INT' INT
    trap 'forward_server_signal TERM' TERM
    trap 'forward_server_signal HUP' HUP
    opencode "${serve_args[@]}" &
    SERVER_CHILD_PID=$!
    wait "${SERVER_CHILD_PID}" || server_status=$?
    if kill -0 "${SERVER_CHILD_PID}" 2>/dev/null; then
        wait "${SERVER_CHILD_PID}" 2>/dev/null || true
    fi
    SERVER_CHILD_PID=""
    release_server_lock
    trap - EXIT INT TERM HUP
    return "${server_status}"
}

cmd_server() {
    local dry_run=0
    local launch_dir="$PWD"
    local port=""
    local session_id=""
    local data_dir=""
    local -a serve_args=()

    while (($# > 0)); do
        case "$1" in
        --dir)
            [[ $# -ge 2 ]] || { print_error "${ERR_DIR_REQUIRES_PATH}"; return 1; }
            launch_dir="$2"
            shift 2
            ;;
        --port)
            [[ $# -ge 2 ]] || { print_error "--port requires a value"; return 1; }
            port="$2"
            shift 2
            ;;
        --session-id)
            [[ $# -ge 2 ]] || { print_error "${ERR_SESSION_ID_REQUIRES_VALUE}"; return 1; }
            session_id="$2"
            shift 2
            ;;
        --dry-run)
            dry_run=1
            shift
            ;;
        -h | --help | help)
            usage
            return 0
            ;;
        *)
            print_error "Unknown server option: $1"
            return 1
            ;;
        esac
    done

    validate_launch_directory "${launch_dir}" || return 1
    require_opencode_cli || return 1
    reject_server_auth_environment || return 1
    [[ -n "${port}" ]] || { print_error "Server mode requires --port PORT"; return 1; }
    validate_server_port "${port}" || return 1
    if [[ -z "${session_id}" ]]; then
        session_id=$(build_project_session_id "${launch_dir}")
    fi
    data_dir=$(build_server_data_dir "${session_id}")
    serve_args=(serve --pure --hostname 127.0.0.1 --port "${port}" --cors oc://renderer)

    if ((dry_run == 1)); then
        printf 'cd %q && TMPDIR=%q TMP=%q TEMP=%q XDG_DATA_HOME=%q AIDEVOPS_OPENCODE_ISOLATED_DB=1 AIDEVOPS_OPENCODE_SERVER_OWNER=1 opencode' "${launch_dir}" "${TMPDIR}" "${TMP}" "${TEMP}" "${data_dir}"
        printf ' %q' "${serve_args[@]}"
        printf '\n'
        return 0
    fi

    run_server_owner "${launch_dir}" "${data_dir}" "${port}"
    return $?
}

cmd_attach() {
    local server_url="${1:-}"
    local normalized_url=""
    local launch_dir="$PWD"
    local session_id=""
    local dry_run=0
    local -a attach_args=()

    if [[ "${server_url}" == "-h" || "${server_url}" == "--help" || "${server_url}" == "help" ]]; then
        usage
        return 0
    fi
    [[ -n "${server_url}" ]] || { print_error "Attach mode requires a loopback server URL"; return 1; }
    shift

    while (($# > 0)); do
        case "$1" in
        --dir)
            [[ $# -ge 2 ]] || { print_error "${ERR_DIR_REQUIRES_PATH}"; return 1; }
            launch_dir="$2"
            shift 2
            ;;
        --session)
            [[ $# -ge 2 ]] || { print_error "--session requires an ID"; return 1; }
            session_id="$2"
            shift 2
            ;;
        --dry-run)
            dry_run=1
            shift
            ;;
        -h | --help | help)
            usage
            return 0
            ;;
        *)
            print_error "Unknown attach option: $1"
            return 1
            ;;
        esac
    done

    if ! normalized_url=$(validate_loopback_url "${server_url}"); then
        return 1
    fi
    validate_launch_directory "${launch_dir}" || return 1
    require_opencode_cli || return 1
    reject_server_auth_environment || return 1
    attach_args=(attach "${normalized_url}" --dir "${launch_dir}")
    if [[ -n "${session_id}" ]]; then
        attach_args+=(--session "${session_id}")
    fi

    if ((dry_run == 1)); then
        printf 'unset XDG_DATA_HOME AIDEVOPS_OPENCODE_ISOLATED_DB AIDEVOPS_OPENCODE_SERVER_OWNER; cd %q && TMPDIR=%q TMP=%q TEMP=%q opencode' "${launch_dir}" "${TMPDIR}" "${TMP}" "${TEMP}"
        printf ' %q' "${attach_args[@]}"
        printf '\n'
        return 0
    fi

    validate_server_health "${normalized_url}" || return 1
    cd "${launch_dir}" || return 1
    unset XDG_DATA_HOME AIDEVOPS_OPENCODE_ISOLATED_DB AIDEVOPS_OPENCODE_SERVER_OWNER
    exec opencode "${attach_args[@]}"
    return 1
}

cmd_tui_launch() {
    local use_shared_db=0
    local tabby_shell=0
    local dry_run=0
    local launch_dir="$PWD"
    local invocation_dir="$PWD"
    local session_id=""
    local data_dir=""
    local recovery_status=0
    local -a opencode_args=()

    while (($# > 0)); do
        case "$1" in
        --shared-db)
            use_shared_db=1
            shift
            ;;
        --dir)
            [[ $# -ge 2 ]] || { print_error "${ERR_DIR_REQUIRES_PATH}"; return 1; }
            launch_dir="$2"
            shift 2
            ;;
        --session-id)
            [[ $# -ge 2 ]] || { print_error "${ERR_SESSION_ID_REQUIRES_VALUE}"; return 1; }
            session_id="$2"
            shift 2
            ;;
        --tabby-shell)
            tabby_shell=1
            shift
            ;;
        --dry-run)
            dry_run=1
            shift
            ;;
        -h | --help | help)
            usage
            return 0
            ;;
        --)
            shift
            opencode_args+=("$@")
            break
            ;;
        *)
            opencode_args+=("$1")
            shift
            ;;
        esac
    done

    validate_launch_directory "${launch_dir}" || return 1
    require_opencode_cli || return 1
    if ((tabby_shell == 1 && use_shared_db == 1)); then
        print_error "--tabby-shell requires aidevops isolated OpenCode storage"
        return 1
    fi
    if ((tabby_shell == 1)); then
        if resolve_tabby_recovery \
            "${invocation_dir}" \
            "${AIDEVOPS_WORK_DIR:-${HOME}/.aidevops/.agent-workspace/work}"; then
            if opencode_args_contain_session "${opencode_args[@]}"; then
                print_error "Tabby recovery rejects an additional OpenCode --session argument"
                return 1
            fi
            launch_dir="${TABBY_RECOVERY_LAUNCH_DIR}"
            data_dir="${TABBY_RECOVERY_DATA_DIR}"
            opencode_args=(--session "${TABBY_RECOVERY_SESSION_ID}" "${opencode_args[@]}")
        else
            recovery_status=$?
            ((recovery_status == 2)) || return 1
        fi
    fi
    validate_launch_directory "${launch_dir}" || return 1
    if [[ -z "${session_id}" ]]; then
        session_id=$(build_project_session_id "${launch_dir}")
    fi

    if ((${#opencode_args[@]} == 0)); then
        opencode_args=()
    fi

    if ((use_shared_db == 1)); then
        if ((dry_run == 1)); then
            printf 'cd %q && TMPDIR=%q TMP=%q TEMP=%q opencode' "${launch_dir}" "${TMPDIR}" "${TMP}" "${TEMP}"
            printf ' %q' "${opencode_args[@]}"
            printf '\n'
            return 0
        fi
        cd "${launch_dir}" || return 1
        exec opencode "${opencode_args[@]}"
        return 1
    fi

    if [[ -z "${data_dir}" ]]; then
        data_dir=$(build_session_data_dir "${session_id}")
    fi

    run_isolated_tui "${launch_dir}" "${data_dir}" "${tabby_shell}" "${dry_run}" "${opencode_args[@]}"
    return $?
}

run_conversation_session() {
    local canonical_overlay="$1"
    local canonical_dir="$2"
    local opencode_binary="$3"
    local data_dir=""
    local runtime_root=""
    local config_directory=""
    local config_file=""
    local conversation_status=0
    local -a runtime_environment=()

    create_conversation_runtime "${canonical_overlay}" runtime_root || {
        print_error "Could not create the private conversation runtime"
        return 1
    }
    trap 'cleanup_conversation_runtime "${runtime_root}" >/dev/null 2>&1 || true' EXIT
    data_dir="${runtime_root}/data"
    config_directory="${runtime_root}/config/opencode"
    config_file="${config_directory}/opencode.json"
    if ! copy_auth_json "${data_dir}"; then
        cleanup_conversation_runtime "${runtime_root}" || true
        trap - EXIT
        return 1
    fi
    runtime_environment=(
        "PATH=${PATH}"
        "HOME=${runtime_root}/home"
        "TMPDIR=${runtime_root}/tmp"
        "TMP=${runtime_root}/tmp"
        "TEMP=${runtime_root}/tmp"
        "XDG_CACHE_HOME=${runtime_root}/cache"
        "XDG_CONFIG_HOME=${runtime_root}/config"
        "XDG_DATA_HOME=${data_dir}"
        "XDG_STATE_HOME=${runtime_root}/state"
        "AIDEVOPS_TEMP_DIR=${runtime_root}/tmp"
        "AIDEVOPS_CONVERSATION_PROJECT_ROOT=${canonical_dir}"
        "AIDEVOPS_CONVERSATION_RUNTIME_ROOT=${runtime_root}"
        "AIDEVOPS_OPENCODE_ISOLATED_DB=1"
        "AIDEVOPS_SESSION_ORIGIN=conversation"
        "AIDEVOPS_TEAM_INTERFACE_OVERLAY=${canonical_overlay}"
        "OPENCODE_CONFIG=${config_file}"
        "OPENCODE_CONFIG_DIR=${config_directory}"
        "OPENCODE_DISABLE_AUTOCOMPACT=1"
        "OPENCODE_DISABLE_AUTOUPDATE=1"
        "OPENCODE_DISABLE_CLAUDE_CODE=1"
        "OPENCODE_DISABLE_CLAUDE_CODE_PROMPT=1"
        "OPENCODE_DISABLE_CLAUDE_CODE_SKILLS=1"
        "OPENCODE_DISABLE_DEFAULT_PLUGINS=1"
        "OPENCODE_DISABLE_EXTERNAL_SKILLS=1"
        "OPENCODE_DISABLE_LSP_DOWNLOAD=1"
        "OPENCODE_DISABLE_MODELS_FETCH=1"
        "OPENCODE_DISABLE_PROJECT_CONFIG=1"
        "OPENCODE_DISABLE_SHARE=1"
    )
    [[ -n "${USER:-}" ]] && runtime_environment+=("USER=${USER}")
    [[ -n "${LOGNAME:-}" ]] && runtime_environment+=("LOGNAME=${LOGNAME}")
    [[ -n "${SHELL:-}" ]] && runtime_environment+=("SHELL=${SHELL}")
    [[ -n "${TERM:-}" ]] && runtime_environment+=("TERM=${TERM}")
    [[ -n "${LANG:-}" ]] && runtime_environment+=("LANG=${LANG}")
    [[ -n "${LC_ALL:-}" ]] && runtime_environment+=("LC_ALL=${LC_ALL}")
    if ! verify_conversation_effective_config \
        "${canonical_overlay}" "${opencode_binary}" "${canonical_dir}" \
        "${runtime_environment[@]}"; then
        cleanup_conversation_runtime "${runtime_root}" || true
        trap - EXIT
        return 1
    fi

    if ! cd "${canonical_dir}"; then
        cleanup_conversation_runtime "${runtime_root}" || true
        trap - EXIT
        return 1
    fi
    env -i "${runtime_environment[@]}" "${opencode_binary}" acp --cwd "${canonical_dir}" || conversation_status=$?
    cleanup_conversation_runtime "${runtime_root}" || {
        ((conversation_status != 0)) || conversation_status=1
    }
    trap - EXIT
    return "${conversation_status}"
}

cmd_conversation() {
    local dry_run=0
    local launch_dir=""
    local overlay_path=""
    local canonical_dir=""
    local canonical_overlay=""
    local overlay_digest=""
    local opencode_binary=""
    local -a acp_args=()

    while (($# > 0)); do
        local option="$1"
        case "${option}" in
        --dir)
            [[ $# -ge 2 ]] || { print_error "${ERR_DIR_REQUIRES_PATH}"; return 1; }
            local dir_value="$2"
            launch_dir="${dir_value}"
            shift 2
            ;;
        --overlay)
            [[ $# -ge 2 ]] || { print_error "--overlay requires a path"; return 1; }
            local overlay_value="$2"
            overlay_path="${overlay_value}"
            shift 2
            ;;
        --dry-run)
            dry_run=1
            shift
            ;;
        --auto)
            print_error "Restricted conversation mode rejects --auto"
            return 1
            ;;
        --)
            print_error "Restricted conversation mode rejects argument passthrough"
            return 1
            ;;
        -h | --help | help)
            usage
            return 0
            ;;
        *)
            print_error "Unknown restricted conversation option: ${option}"
            return 1
            ;;
        esac
    done

    [[ -n "${launch_dir}" ]] || { print_error "Restricted conversation mode requires --dir PATH"; return 1; }
    [[ -n "${overlay_path}" ]] || { print_error "Restricted conversation mode requires --overlay FILE"; return 1; }
    reject_conversation_environment || return 1
    require_opencode_cli || return 1
    require_node_cli || return 1
    opencode_binary=$(command -v opencode) || return 1
    canonical_dir=$(canonical_conversation_directory "${launch_dir}") || return 1
    canonical_overlay=$(canonical_conversation_overlay "${overlay_path}") || return 1
    overlay_digest=$(validate_conversation_overlay "${canonical_overlay}" "conversation_read_only_v1") || return 1
    acp_args=(acp --cwd "${canonical_dir}")

    if ((dry_run == 1)); then
        printf 'cd %q && env -i HOME=%q XDG_CONFIG_HOME=%q XDG_CACHE_HOME=%q XDG_STATE_HOME=%q XDG_DATA_HOME=%q OPENCODE_CONFIG=%q OPENCODE_CONFIG_DIR=%q OPENCODE_DISABLE_AUTOCOMPACT=1 OPENCODE_DISABLE_AUTOUPDATE=1 OPENCODE_DISABLE_CLAUDE_CODE=1 OPENCODE_DISABLE_CLAUDE_CODE_PROMPT=1 OPENCODE_DISABLE_CLAUDE_CODE_SKILLS=1 OPENCODE_DISABLE_DEFAULT_PLUGINS=1 OPENCODE_DISABLE_EXTERNAL_SKILLS=1 OPENCODE_DISABLE_LSP_DOWNLOAD=1 OPENCODE_DISABLE_MODELS_FETCH=1 OPENCODE_DISABLE_PROJECT_CONFIG=1 OPENCODE_DISABLE_SHARE=1 AIDEVOPS_OPENCODE_ISOLATED_DB=1 AIDEVOPS_SESSION_ORIGIN=conversation AIDEVOPS_TEAM_INTERFACE_OVERLAY=%q %q' \
            "${canonical_dir}" "<private-home>" "<private-config>" "<private-cache>" \
            "<private-state>" "<private-data>" "<private-config>/opencode.json" \
            "<private-config>" "<validated-overlay:${overlay_digest}>" "${opencode_binary}"
        printf ' %q' "${acp_args[@]}"
        printf '\n'
        return 0
    fi

    run_conversation_session "${canonical_overlay}" "${canonical_dir}" "${opencode_binary}"
    return $?
}

run_remote_interactive_session() {
    local canonical_overlay="$1"
    local canonical_dir="$2"
	local session_id="$3"
	local opencode_binary="$4"
	local runtime_anchor="$5"
	local data_dir=""

    data_dir=$(build_session_data_dir "buzz-${session_id}") || return 1
    mkdir -p "${data_dir}/opencode" || return 1
    copy_auth_json "${data_dir}" || return 1
    prewarm_opencode_data_dir "${data_dir}"
    cd "${canonical_dir}" || return 1
	export XDG_DATA_HOME="${data_dir}"
	if [[ -n "$runtime_anchor" ]]; then
		export XDG_CONFIG_HOME="${runtime_anchor}/opencode-config"
		export AIDEVOPS_REMOTE_RUNTIME_ANCHOR="$runtime_anchor"
	fi
    export AIDEVOPS_OPENCODE_ISOLATED_DB=1
    export AIDEVOPS_SESSION_ORIGIN=interactive
    export AIDEVOPS_REMOTE_INTERFACE=1
    export AIDEVOPS_REMOTE_PROJECT_ROOT="${canonical_dir}"
    export AIDEVOPS_TEAM_INTERFACE_OVERLAY="${canonical_overlay}"
    export OPENCODE_DISABLE_AUTOUPDATE=1
    export OPENCODE_DISABLE_SHARE=1
    exec "${opencode_binary}" acp --cwd "${canonical_dir}"
    return 1
}

cmd_remote_interactive() {
    local dry_run=0
    local launch_dir=""
    local overlay_path=""
    local session_id=""
    local canonical_dir=""
    local canonical_overlay=""
	local overlay_digest=""
	local opencode_binary=""
	local runtime_anchor=""
	local anchor_status=0

    while (($# > 0)); do
        local option="$1"
        case "${option}" in
        --dir)
            [[ $# -ge 2 ]] || { print_error "${ERR_DIR_REQUIRES_PATH}"; return 1; }
            launch_dir="$2"
            shift 2
            ;;
        --overlay)
            [[ $# -ge 2 ]] || { print_error "--overlay requires a path"; return 1; }
            overlay_path="$2"
            shift 2
            ;;
        --session-id)
            [[ $# -ge 2 ]] || { print_error "${ERR_SESSION_ID_REQUIRES_VALUE}"; return 1; }
            session_id="$2"
            shift 2
            ;;
        --dry-run)
            dry_run=1
            shift
            ;;
        -h | --help | help)
            usage
            return 0
            ;;
        *)
            print_error "Unknown remote interactive option: ${option}"
            return 1
            ;;
        esac
    done

    [[ -n "${launch_dir}" ]] || { print_error "Remote interactive mode requires --dir PATH"; return 1; }
    [[ -n "${overlay_path}" ]] || { print_error "Remote interactive mode requires --overlay FILE"; return 1; }
    [[ -n "${session_id}" ]] || { print_error "Remote interactive mode requires --session-id ID"; return 1; }
    reject_remote_interactive_environment || return 1
    require_opencode_cli || return 1
    require_node_cli || return 1
    opencode_binary=$(command -v opencode) || return 1
    canonical_dir=$(canonical_conversation_directory "${launch_dir}") || return 1
    canonical_overlay=$(canonical_conversation_overlay "${overlay_path}") || return 1
	overlay_digest=$(validate_conversation_overlay \
		"${canonical_overlay}" "remote_interactive_v1") || return 1
	runtime_anchor=$(resolve_remote_runtime_anchor) || anchor_status=$?
	case "$anchor_status" in
	0) ;;
	2)
		if [[ "${AIDEVOPS_REMOTE_REQUIRE_PINNED_RUNTIME:-}" == "1" ]]; then
			print_error "Remote interactive runtime requires an installed immutable anchor"
			return 1
		fi
		;;
	*) return 1 ;;
	esac

	if ((dry_run == 1)); then
		printf 'cd %q && XDG_DATA_HOME=%q XDG_CONFIG_HOME=%q AIDEVOPS_OPENCODE_ISOLATED_DB=1 AIDEVOPS_SESSION_ORIGIN=interactive AIDEVOPS_REMOTE_INTERFACE=1 AIDEVOPS_REMOTE_RUNTIME_ANCHOR=%q AIDEVOPS_REMOTE_PROJECT_ROOT=%q AIDEVOPS_TEAM_INTERFACE_OVERLAY=%q OPENCODE_DISABLE_AUTOUPDATE=1 OPENCODE_DISABLE_SHARE=1 %q acp --cwd %q\n' \
			"${canonical_dir}" "<persistent-buzz-agent-shard>" "${runtime_anchor:+<pinned-runtime-config>}" \
			"${runtime_anchor:+<pinned-runtime-anchor>}" "${canonical_dir}" \
			"<validated-overlay:${overlay_digest}>" "${opencode_binary}" "${canonical_dir}"
		return 0
	fi

	run_remote_interactive_session \
		"${canonical_overlay}" "${canonical_dir}" "${session_id}" "${opencode_binary}" "$runtime_anchor"
    return $?
}

main() {
    aidevops_init_temp_workspace || { print_error "Could not initialize aidevops temporary workspace"; return 1; }
    TMP="${TMP:-${TMPDIR}}"
    TEMP="${TEMP:-${TMPDIR}}"
    export TMP TEMP
    case "${1:-}" in
    conversation)
        shift || true
        cmd_conversation "$@"
        return $?
        ;;
    remote-interactive)
        shift || true
        cmd_remote_interactive "$@"
        return $?
        ;;
    desktop)
        shift || true
        cmd_desktop "$@"
        return $?
        ;;
    server)
        shift || true
        cmd_server "$@"
        return $?
        ;;
    attach)
        shift || true
        cmd_attach "$@"
        return $?
        ;;
    *)
        cmd_tui_launch "$@"
        return $?
        ;;
    esac
}

main "$@"

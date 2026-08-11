#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Bounded evaluator for the scoped OpenCode Linux-headless compatibility pin.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=shared-constants.sh
source "$SCRIPT_DIR/shared-constants.sh"

_CANARY_TEMP_ROOT=""
_CANARY_MOCK_PID=""

cleanup_canary() {
	if [[ -n "$_CANARY_MOCK_PID" ]]; then
		kill "$_CANARY_MOCK_PID" 2>/dev/null || true
		wait "$_CANARY_MOCK_PID" 2>/dev/null || true
	fi
	[[ -z "$_CANARY_TEMP_ROOT" ]] || rm -rf "$_CANARY_TEMP_ROOT"
}

usage() {
	printf 'Usage: opencode-pin-canary.sh status [--json]\n'
	printf '       opencode-pin-canary.sh canary [candidate-version]\n'
}

install_isolated_opencode() {
	local install_root="$1"
	local version="$2"
	local isolated_home="$3"
	local isolated_cache="$4"
	mkdir -p "$install_root" "$isolated_home" "$isolated_cache"
	env -i \
		HOME="$isolated_home" PATH="$PATH" \
		GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
		npm_config_userconfig=/dev/null npm_config_cache="$isolated_cache" \
		npm install --ignore-scripts --no-audit --no-fund --prefix "$install_root" \
		"opencode-ai@${version}" >/dev/null
}

resolve_installed_opencode_binary() {
	local install_root="$1"
	local machine_arch
	machine_arch=$(uname -m)
	local package_arch=""
	case "$machine_arch" in
	x86_64 | amd64) package_arch="x64" ;;
	aarch64 | arm64) package_arch="arm64" ;;
	*) return 1 ;;
	esac
	local base="opencode-linux-${package_arch}"
	local suffixes=("")
	if [[ "$package_arch" == "x64" ]] && ! grep -qE '(^|[[:space:]])avx2([[:space:]]|$)' /proc/cpuinfo 2>/dev/null; then
		suffixes=("-baseline" "")
	fi
	if ldd --version 2>&1 | grep -qi musl; then
		if [[ "$package_arch" == "x64" ]]; then
			suffixes=("-musl" "-baseline-musl" "" "-baseline")
		else
			suffixes=("-musl" "")
		fi
	fi
	local suffix
	for suffix in "${suffixes[@]}"; do
		local binary="$install_root/node_modules/${base}${suffix}/bin/opencode"
		if [[ -x "$binary" ]]; then
			printf '%s\n' "$binary"
			return 0
		fi
	done
	return 1
}

start_mock_provider() {
	local canary_root="$1"
	local port_file="$canary_root/mock-provider.port"
	local request_file="$canary_root/mock-provider.requests"
	python3 - "$port_file" "$request_file" <<'PY' &
import json
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

port_file, request_file = sys.argv[1:]
CANARY = "canary"
CONTENT_LENGTH = "Content-Length"
CREATED = "created"
MODEL = "model"
OBJECT = "object"

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def do_GET(self):
        payload = json.dumps({
            OBJECT: "list",
            "data": [{"id": CANARY, OBJECT: MODEL, CREATED: 0, "owned_by": CANARY}],
        }).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header(CONTENT_LENGTH, str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        self.rfile.read(length)
        with open(request_file, "a", encoding="utf-8") as requests:
            requests.write(self.path + "\n")
        now = int(time.time())
        chunks = [
            {"id": CANARY, OBJECT: "chat.completion.chunk", CREATED: now,
             MODEL: CANARY, "choices": [{"index": 0,
             "delta": {"role": "assistant", "content": "Four"}, "finish_reason": None}]},
            {"id": CANARY, OBJECT: "chat.completion.chunk", CREATED: now,
             MODEL: CANARY, "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}]},
        ]
        payload = "".join("data: " + json.dumps(chunk) + "\n\n" for chunk in chunks)
        payload += "data: [DONE]\n\n"
        encoded = payload.encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header(CONTENT_LENGTH, str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)

server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
with open(port_file, "w", encoding="utf-8") as destination:
    destination.write(str(server.server_port))
server.serve_forever()
PY
	_CANARY_MOCK_PID=$!
	local attempt=0
	while [[ ! -s "$port_file" && "$attempt" -lt 50 ]]; do
		sleep 0.1
		attempt=$((attempt + 1))
	done
	[[ -s "$port_file" ]] || return 1
	MOCK_PROVIDER_PORT=$(<"$port_file")
	MOCK_PROVIDER_REQUEST_FILE="$request_file"
}

run_isolated_probe() {
	local label="$1"
	local binary="$2"
	local canary_root="$3"
	local port="$4"
	local request_file="$5"
	local probe_root="$canary_root/probe-$label"
	local output_file="$canary_root/$label.output"
	local plugin_path="$SCRIPT_DIR/../plugins/opencode-aidevops/index.mjs"
	local plugin_url=""
	local model_id="canary"
	local request_count_before=0
	local request_count_after=0
	mkdir -p "$probe_root/home" "$probe_root/config/opencode" "$probe_root/data" "$probe_root/cache"
	if [[ -f "$plugin_path" ]]; then
		plugin_url=$(python3 -c 'import pathlib, sys; print(pathlib.Path(sys.argv[1]).resolve().as_uri())' "$plugin_path")
	fi
	jq -n --arg api "http://127.0.0.1:${port}/v1" --arg plugin "$plugin_url" --arg model "$model_id" \
		'{provider:{($model):{npm:"@ai-sdk/openai-compatible",name:"Canary",api:$api,
		options:{apiKey:"canary-local-only"},models:{($model):{name:"Canary"}}}}}
		+ (if $plugin == "" then {} else {plugin:[$plugin]} end)' \
		>"$probe_root/config/opencode/opencode.json"
	[[ -f "$request_file" ]] && request_count_before=$(wc -l <"$request_file" | tr -d ' ')

	local timeout_command=(timeout --kill-after=5s 60s)
	if ! command -v timeout >/dev/null 2>&1; then
		timeout_command=(perl -e 'alarm 60; exec @ARGV' --)
	fi
	local probe_rc=0
	env -i \
		HOME="$probe_root/home" PATH="$PATH" \
		XDG_CONFIG_HOME="$probe_root/config" XDG_DATA_HOME="$probe_root/data" \
		XDG_CACHE_HOME="$probe_root/cache" AIDEVOPS_HEADLESS=1 \
		GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
		"${timeout_command[@]}" "$binary" run \
		"What is two plus two? Answer with the single word: Four" \
		-m canary/canary --dir "$probe_root/home" --agent build \
		>"$output_file" 2>&1 || probe_rc=$?
	[[ -f "$request_file" ]] && request_count_after=$(wc -l <"$request_file" | tr -d ' ')
	if [[ "$probe_rc" -eq 0 && "$request_count_after" -gt "$request_count_before" ]] && grep -q 'Four' "$output_file"; then
		printf 'PASS: %s completed the isolated Linux-headless probe\n' "$label"
		return 0
	fi
	printf 'FAIL: %s isolated probe exited %s (provider requests: %s -> %s)\n' \
		"$label" "$probe_rc" "$request_count_before" "$request_count_after" >&2
	command tail -n 20 "$output_file" >&2 || true
	return 1
}

pin_age_days() {
	python3 - "$OPENCODE_PIN_INTRODUCED_DATE" <<'PY'
from datetime import date
import sys
print((date.today() - date.fromisoformat(sys.argv[1])).days)
PY
}

cmd_status() {
	local format="${1:-text}"
	local registry_latest="unknown"
	registry_latest=$(npm view opencode-ai version 2>/dev/null || printf 'unknown')
	local installed="not-installed"
	if command -v opencode >/dev/null 2>&1; then
		installed=$(opencode --version 2>/dev/null | command head -n 1 || printf 'unknown')
	fi
	local age
	age=$(pin_age_days)
	if [[ "$format" == "--json" ]]; then
		printf '{"installed":"%s","pinned":"%s","registry_latest":"%s","plugin_tested":"%s","pin_age_days":%s,"reason":"%s","platform":"%s","runtime_mode":"%s","introduced":"%s","last_canary_date":"%s","last_canary_result":"%s","review_deadline":"%s"}\n' \
			"$installed" "$OPENCODE_PINNED_VERSION" "$registry_latest" "$OPENCODE_PLUGIN_TESTED_VERSION" "$age" "$OPENCODE_PIN_REASON" \
			"$OPENCODE_PIN_PLATFORM" "$OPENCODE_PIN_RUNTIME_MODE" "$OPENCODE_PIN_INTRODUCED_DATE" \
			"$OPENCODE_PIN_LAST_CANARY_DATE" "$OPENCODE_PIN_LAST_CANARY_RESULT" "$OPENCODE_PIN_REVIEW_DEADLINE"
		return 0
	fi
	printf 'installed=%s pinned=%s registry-latest=%s pin-age=%sd\n' "$installed" "$OPENCODE_PINNED_VERSION" "$registry_latest" "$age"
	printf 'scope=%s/%s plugin-tested=%s last-canary=%s (%s) review-deadline=%s\n' \
		"$OPENCODE_PIN_PLATFORM" "$OPENCODE_PIN_RUNTIME_MODE" "$OPENCODE_PLUGIN_TESTED_VERSION" "$OPENCODE_PIN_LAST_CANARY_DATE" \
		"$OPENCODE_PIN_LAST_CANARY_RESULT" "$OPENCODE_PIN_REVIEW_DEADLINE"
}

cmd_canary() {
	local candidate="${1:-}"
	[[ "$(uname -s)" == "$OPENCODE_PIN_PLATFORM" ]] || {
		printf 'RESULT=inconclusive\nINCONCLUSIVE: candidate canary requires %s\n' "$OPENCODE_PIN_PLATFORM" >&2
		return 2
	}
	local required_command
	for required_command in npm python3 jq; do
		command -v "$required_command" >/dev/null 2>&1 || {
			printf 'RESULT=inconclusive\nINCONCLUSIVE: %s is unavailable\n' "$required_command" >&2
			return 2
		}
	done
	if [[ -z "$candidate" || "$candidate" == "latest" ]]; then
		candidate=$(npm view opencode-ai version 2>/dev/null || true)
	fi
	[[ "$candidate" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.-]+)?$ ]] || {
		printf 'RESULT=inconclusive\nINCONCLUSIVE: invalid candidate version %s\n' "${candidate:-empty}" >&2
		return 2
	}
	if [[ "$candidate" == "$OPENCODE_PINNED_VERSION" ]]; then
		printf 'RESULT=skip\nSKIP: registry candidate equals pin %s\n' "$candidate"
		return 0
	fi

	local temp_parent="${AIDEVOPS_TEMP_DIR:-${HOME}/.aidevops/.agent-workspace/tmp}"
	mkdir -p "$temp_parent"
	_CANARY_TEMP_ROOT=$(mktemp -d "${temp_parent}/opencode-pin-canary-XXXXXX")
	trap cleanup_canary EXIT INT TERM
	if ! install_isolated_opencode "$_CANARY_TEMP_ROOT/baseline" "$OPENCODE_PINNED_VERSION" \
		"$_CANARY_TEMP_ROOT/install-home-baseline" "$_CANARY_TEMP_ROOT/npm-cache-baseline"; then
		printf 'RESULT=inconclusive\nINCONCLUSIVE: pinned baseline installation failed\n' >&2
		return 2
	fi
	if ! install_isolated_opencode "$_CANARY_TEMP_ROOT/candidate" "$candidate" \
		"$_CANARY_TEMP_ROOT/install-home-candidate" "$_CANARY_TEMP_ROOT/npm-cache-candidate"; then
		printf 'RESULT=inconclusive\nINCONCLUSIVE: candidate installation failed\n' >&2
		return 2
	fi
	local baseline_bin=""
	local candidate_bin=""
	baseline_bin=$(resolve_installed_opencode_binary "$_CANARY_TEMP_ROOT/baseline" || true)
	candidate_bin=$(resolve_installed_opencode_binary "$_CANARY_TEMP_ROOT/candidate" || true)
	[[ -n "$baseline_bin" && -n "$candidate_bin" ]] || {
		printf 'RESULT=inconclusive\nINCONCLUSIVE: baseline or candidate binary was not installed\n' >&2
		return 2
	}
	start_mock_provider "$_CANARY_TEMP_ROOT" || {
		printf 'RESULT=inconclusive\nINCONCLUSIVE: local mock provider failed to start\n' >&2
		return 2
	}
	local mock_provider_port="$MOCK_PROVIDER_PORT"
	local mock_provider_request_file="$MOCK_PROVIDER_REQUEST_FILE"
	local revision="unknown"
	revision=$(git -C "$SCRIPT_DIR/../.." rev-parse HEAD 2>/dev/null || printf 'unknown')

	printf 'Evaluating pinned baseline %s and candidate %s at repository revision %s\n' \
		"$OPENCODE_PINNED_VERSION" "$candidate" "$revision"
	if ! run_isolated_probe "baseline-$OPENCODE_PINNED_VERSION" "$baseline_bin" "$_CANARY_TEMP_ROOT" \
		"$mock_provider_port" "$mock_provider_request_file"; then
		printf 'RESULT=inconclusive\nINCONCLUSIVE: pinned baseline failed; retaining %s\n' \
			"$OPENCODE_PINNED_VERSION" >&2
		return 2
	fi
	if ! run_isolated_probe "candidate-$candidate" "$candidate_bin" "$_CANARY_TEMP_ROOT" \
		"$mock_provider_port" "$mock_provider_request_file"; then
		printf 'RESULT=fail\nFAIL: candidate failed while the same-revision pinned baseline passed; retaining %s\n' \
			"$OPENCODE_PINNED_VERSION" >&2
		return 1
	fi
	printf 'RESULT=pass\nPASS: OpenCode %s passed the Linux-headless compatibility canary\n' "$candidate"
}

case "${1:-}" in
status) cmd_status "${2:-}" ;;
canary) cmd_canary "${2:-latest}" ;;
*) usage >&2; exit 2 ;;
esac

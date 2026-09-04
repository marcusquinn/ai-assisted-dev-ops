#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Regression coverage for GH#31097: configured MCP commands and the local
# Playwriter relay must not be hidden by a newer same-named PATH executable.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)" || exit 1
TEST_ROOT="$(mktemp -d)"
relay_pid=""
cleanup() {
	if [[ -n "$relay_pid" ]]; then
		kill "$relay_pid" 2>/dev/null || true
	fi
	rm -rf "${TEST_ROOT}"
	return 0
}
trap cleanup EXIT

FAKE_BIN="${TEST_ROOT}/bin"
CONFIG_HOME="${TEST_ROOT}/home"
RELAY_PORT="$(python3 -c 'import socket; sock = socket.socket(); sock.bind(("127.0.0.1", 0)); print(sock.getsockname()[1]); sock.close()')"
RELAY_READY="${TEST_ROOT}/relay-ready"
mkdir -p "${FAKE_BIN}" "${CONFIG_HOME}/.config/opencode"

cat >"${FAKE_BIN}/playwriter" <<'EOF'
#!/usr/bin/env bash
printf '0.5.0\n'
EOF
chmod +x "${FAKE_BIN}/playwriter"

cat >"${FAKE_BIN}/npm" <<'EOF'
#!/usr/bin/env bash
printf '0.5.0\n'
EOF
chmod +x "${FAKE_BIN}/npm"

cat >"${FAKE_BIN}/configured-playwriter" <<'EOF'
#!/usr/bin/env bash
printf '0.0.56\n'
EOF
chmod +x "${FAKE_BIN}/configured-playwriter"

python3 - "${CONFIG_HOME}/.config/opencode/opencode.json" "${FAKE_BIN}/configured-playwriter" "${RELAY_PORT}" <<'PYEOF'
import json
import sys

with open(sys.argv[1], "w") as stream:
    json.dump({"mcp": {"playwriter": {
        "type": "local",
        "enabled": True,
        "command": [sys.argv[2], "--port", sys.argv[3]],
    }}}, stream)
PYEOF

python3 -c '
from http.server import BaseHTTPRequestHandler, HTTPServer
import pathlib
import sys

class RelayVersionHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/version":
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(b"{\"version\":\"0.0.56\"}")
        else:
            self.send_error(404)

    def log_message(self, format, *args):
        pass

server = HTTPServer(("127.0.0.1", int(sys.argv[1])), RelayVersionHandler)
pathlib.Path(sys.argv[2]).touch()
server.serve_forever()
' "${RELAY_PORT}" "${RELAY_READY}" >/dev/null 2>&1 &
relay_pid=$!

for _attempt in {1..50}; do
	[[ -f "${RELAY_READY}" ]] && break
	if ! kill -0 "$relay_pid" 2>/dev/null; then
		break
	fi
	sleep 0.1
done
if [[ ! -f "${RELAY_READY}" ]]; then
	printf 'FAIL local Playwriter relay fixture did not start\n' >&2
	exit 1
fi

output=$(HOME="${CONFIG_HOME}" PATH="${FAKE_BIN}:${PATH}" \
	"${REPO_ROOT}/.agents/scripts/mcp-diagnose.sh" playwriter 2>&1)

if [[ "$output" != *"PATH version: 0.5.0"* ]] ||
	[[ "$output" != *"Configured version: 0.0.56"* ]] ||
	[[ "$output" != *"VERSION MISMATCH"* ]]; then
	printf 'FAIL configured Playwriter version mismatch was not reported\n%s\n' "$output" >&2
	exit 1
fi

if [[ "$output" != *"Live local relay version: 0.0.56"* ]]; then
	printf 'FAIL live Playwriter relay version was not reported\n%s\n' "$output" >&2
	exit 1
fi

if [[ "$output" != *"live relay uses 0.0.56, PATH reports 0.5.0"* ]]; then
	printf 'FAIL stale live Playwriter relay was not reported as a mismatch\n%s\n' "$output" >&2
	exit 1
fi

printf 'PASS configured Playwriter command and relay version mismatch are reported\n'

cat >"${FAKE_BIN}/npx" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >"$NPX_CALL_LOG"
printf '0.0.79\n'
EOF
chmod +x "${FAKE_BIN}/npx"

python3 - "${CONFIG_HOME}/.config/opencode/opencode.json" <<'PYEOF'
import json
import sys

with open(sys.argv[1], "w") as stream:
    json.dump({"mcp": {"playwright": {
        "type": "local",
        "enabled": False,
        "command": [
            "/bin/bash", "-c", "validated launcher", "aidevops-playwright-mcp",
            "/safe/workspace", "/safe/output", "marker-token",
            "npx", "-y", "@playwright/mcp@0.0.79", "--headless", "--isolated",
        ],
    }}}, stream)
PYEOF

NPX_CALL_LOG="${TEST_ROOT}/npx-call.log"
output=$(HOME="${CONFIG_HOME}" PATH="${FAKE_BIN}:${PATH}" NPX_CALL_LOG="$NPX_CALL_LOG" \
	"${REPO_ROOT}/.agents/scripts/mcp-diagnose.sh" playwright 2>&1)

if [[ "$output" != *"Configured version: 0.0.79"* ]]; then
	printf 'FAIL configured @playwright/mcp version was not reported\n%s\n' "$output" >&2
	exit 1
fi

if [[ "$(<"$NPX_CALL_LOG")" != "-y @playwright/mcp@0.0.79 --version" ]]; then
	printf 'FAIL Playwright diagnostic executed runtime arguments instead of a bounded version check\n' >&2
	exit 1
fi

printf 'PASS disabled managed @playwright/mcp command is safely version-checked\n'

for unsafe_spec in "@playwright/mcp@latest" "@playwright/mcp@file:/untrusted-package"; do
	python3 - "${CONFIG_HOME}/.config/opencode/opencode.json" "$unsafe_spec" <<'PYEOF'
import json
import sys

with open(sys.argv[1], "w") as stream:
    json.dump({"mcp": {"playwright": {
        "type": "local",
        "enabled": True,
        "command": ["npx", "-y", sys.argv[2]],
    }}}, stream)
PYEOF

	rm -f "$NPX_CALL_LOG"
	if HOME="${CONFIG_HOME}" PATH="${FAKE_BIN}:${PATH}" NPX_CALL_LOG="$NPX_CALL_LOG" \
		"${REPO_ROOT}/.agents/scripts/mcp-diagnose.sh" playwright >/dev/null 2>&1; then
		printf 'FAIL unpinned Playwright package reference was accepted: %s\n' "$unsafe_spec" >&2
		exit 1
	fi

	if [[ -e "$NPX_CALL_LOG" ]]; then
		printf 'FAIL unpinned Playwright package reference was executed: %s\n' "$unsafe_spec" >&2
		exit 1
	fi
done

printf 'PASS unpinned Playwright package references are rejected without execution\n'

#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
ADD_HELPER="${TEST_DIR}/../worktree-helper-add.sh"
ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT

print_info() { return 0; }
print_success() { return 0; }
print_warning() {
	local message="$1"
	printf '%s\n' "$message" >&2
	return 0
}

SCRIPT_DIR="$(cd "$(dirname "$ADD_HELPER")" && pwd)" || exit 1
# shellcheck source=../worktree-helper-add.sh
source "$ADD_HELPER"

FAKE_BIN="${ROOT}/bin"
WORKTREE="${ROOT}/aidevops-worktree"
ORDINARY="${ROOT}/ordinary-worktree"
mkdir -p "$FAKE_BIN" "$WORKTREE/.agents/scripts" "$ORDINARY/.agents/scripts"
cat >"${FAKE_BIN}/bun" <<'BUN'
#!/usr/bin/env bash
mkdir -p node_modules/.bin
printf '#!/usr/bin/env bash\nexit 0\n' >node_modules/.bin/tsc
chmod +x node_modules/.bin/tsc
printf '%s\n' "$*" >"${BUN_ARGS_LOG}"
BUN
chmod +x "${FAKE_BIN}/bun"
export PATH="${FAKE_BIN}:${PATH}"
export BUN_ARGS_LOG="${ROOT}/bun-args.log"

printf '{ "name": "aidevops", "devDependencies": { "typescript": "^5.0.0" } }\n' >"${WORKTREE}/package.json"
printf '{}\n' >"${WORKTREE}/bun.lock"
printf '#!/usr/bin/env bash\n' >"${WORKTREE}/aidevops.sh"

_bootstrap_aidevops_worktree_js_deps "$WORKTREE"
[[ -x "${WORKTREE}/node_modules/.bin/tsc" ]] || {
	printf 'FAIL aidevops worktree bootstrap did not install tsc\n'
	exit 1
}
[[ "$(cat "$BUN_ARGS_LOG")" == "install --frozen-lockfile" ]] || {
	printf 'FAIL aidevops worktree bootstrap used unexpected bun arguments\n'
	exit 1
}
printf 'PASS aidevops worktree bootstraps locked JavaScript dev dependencies\n'

rm -f "$BUN_ARGS_LOG"
printf '{ "name": "ordinary-project", "devDependencies": { "typescript": "^5.0.0" } }\n' >"${ORDINARY}/package.json"
printf '{}\n' >"${ORDINARY}/bun.lock"
printf '#!/usr/bin/env bash\n' >"${ORDINARY}/aidevops.sh"
_bootstrap_aidevops_worktree_js_deps "$ORDINARY"
[[ ! -e "$BUN_ARGS_LOG" && ! -e "${ORDINARY}/node_modules/.bin/tsc" ]] || {
	printf 'FAIL ordinary project triggered aidevops dependency bootstrap\n'
	exit 1
}
printf 'PASS ordinary projects do not run implicit bun install\n'

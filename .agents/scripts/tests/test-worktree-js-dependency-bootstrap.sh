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
HOME_WORKTREE="${ROOT}/aidevops-home-bun-worktree"
ORDINARY="${ROOT}/ordinary-worktree"
FAKE_HOME="${ROOT}/home"
mkdir -p "$FAKE_BIN" "$WORKTREE/.agents/scripts" "$HOME_WORKTREE/.agents/scripts" \
	"$ORDINARY/.agents/scripts" "$FAKE_HOME/.bun/bin"
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
[[ "$(cat "$BUN_ARGS_LOG")" == "install --frozen-lockfile --ignore-scripts" ]] || {
	printf 'FAIL aidevops worktree bootstrap used unexpected bun arguments\n'
	exit 1
}
printf 'PASS aidevops worktree bootstraps locked dependencies without lifecycle scripts\n'

cp "${FAKE_BIN}/bun" "$FAKE_HOME/.bun/bin/bun"
printf '{ "name": "aidevops", "devDependencies": { "typescript": "^5.0.0" } }\n' >"${HOME_WORKTREE}/package.json"
printf '{}\n' >"${HOME_WORKTREE}/bun.lock"
printf '#!/usr/bin/env bash\n' >"${HOME_WORKTREE}/aidevops.sh"
rm -f "$BUN_ARGS_LOG"
HOME="$FAKE_HOME" PATH="/usr/bin:/bin" _bootstrap_aidevops_worktree_js_deps "$HOME_WORKTREE"
[[ -x "${HOME_WORKTREE}/node_modules/.bin/tsc" ]] || {
	printf 'FAIL fixed HOME Bun path did not bootstrap tsc when bun was absent from PATH\n'
	exit 1
}
[[ "$(cat "$BUN_ARGS_LOG")" == "install --frozen-lockfile --ignore-scripts" ]] || {
	printf 'FAIL fixed HOME Bun path used unexpected arguments\n'
	exit 1
}
printf 'PASS executable HOME Bun bootstraps dependencies when absent from PATH\n'

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

#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
TEST_ROOT="$(mktemp -d)"
FIXTURE_REPO="$TEST_ROOT/repo"
TEST_HOME="$TEST_ROOT/home"
MARKER="$TEST_ROOT/runtime-config-generated"
SETUP_CALLS="$TEST_ROOT/setup-calls"
OLD_BUNDLE="$TEST_HOME/.aidevops/runtime-bundles/old/agents"

cleanup() {
	rm -rf "$TEST_ROOT"
	return 0
}
trap cleanup EXIT

mkdir -p "$FIXTURE_REPO/.agents/scripts" "$OLD_BUNDLE/scripts"
/usr/bin/git -C "$FIXTURE_REPO" init -q
/usr/bin/git -C "$FIXTURE_REPO" config user.email test@example.invalid
/usr/bin/git -C "$FIXTURE_REPO" config user.name Test
/usr/bin/git -C "$FIXTURE_REPO" config commit.gpgsign false
printf '%s\n' '3.32.107' >"$FIXTURE_REPO/VERSION"
printf '%s\n' 'old immutable sentinel' >"$OLD_BUNDLE/scripts/example-helper.sh"
ln -s "$OLD_BUNDLE" "$TEST_HOME/.aidevops/agents"
cat >"$FIXTURE_REPO/.agents/scripts/generate-runtime-config.sh" <<EOF_GENERATOR
#!/usr/bin/env bash
printf '%s\n' "\$1" >"$MARKER"
exit 0
EOF_GENERATOR
cat >"$FIXTURE_REPO/.agents/scripts/example-helper.sh" <<'EOF_HELPER'
#!/usr/bin/env bash
exit 0
EOF_HELPER
cat >"$FIXTURE_REPO/setup.sh" <<'EOF_SETUP'
#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
printf '%s\n' "$*" >"${SETUP_CALLS:?SETUP_CALLS must be set}"
printf 'AIDEVOPS_AGENTS_DIR=%s\n' "${AIDEVOPS_AGENTS_DIR-unset}" >>"$SETUP_CALLS"
printf 'AGENTS_DIR=%s\n' "${AGENTS_DIR-unset}" >>"$SETUP_CALLS"
if [[ "${MOCK_SETUP_EXIT_CODE:-0}" -ne 0 ]]; then
	exit "$MOCK_SETUP_EXIT_CODE"
fi

bash "$repo_root/.agents/scripts/generate-runtime-config.sh" all
new_root="$HOME/.aidevops/runtime-bundles/new/agents"
mkdir -p "$new_root/scripts"
cp "$repo_root/.agents/scripts/example-helper.sh" "$new_root/scripts/example-helper.sh"
cp "$repo_root/VERSION" "$new_root/VERSION"
link_tmp="$HOME/.aidevops/agents.tmp.$$"
rm -f "$link_tmp"
ln -s "$new_root" "$link_tmp"
if [[ "$(uname -s)" == "Darwin" ]]; then
	mv -f -h "$link_tmp" "$HOME/.aidevops/agents"
else
	mv -Tf "$link_tmp" "$HOME/.aidevops/agents"
fi
exit 0
EOF_SETUP
chmod +x "$FIXTURE_REPO/setup.sh"
/usr/bin/git -C "$FIXTURE_REPO" add .
/usr/bin/git -C "$FIXTURE_REPO" commit -qm fixture
SOURCE_SHA=$(/usr/bin/git -C "$FIXTURE_REPO" rev-parse HEAD)

HOME="$TEST_HOME" SETUP_CALLS="$SETUP_CALLS" \
	AIDEVOPS_AGENTS_DIR="$OLD_BUNDLE" AGENTS_DIR="$OLD_BUNDLE" \
	bash "$REPO_ROOT/.agents/scripts/deploy-agents-on-merge.sh" \
	--repo "$FIXTURE_REPO" --expected-sha "$SOURCE_SHA" --scripts-only --quiet
grep -Fxq 'all' "$MARKER"
grep -Fxq -- '--stage ai-session' "$SETUP_CALLS"
grep -Fxq 'AIDEVOPS_AGENTS_DIR=unset' "$SETUP_CALLS"
grep -Fxq 'AGENTS_DIR=unset' "$SETUP_CALLS"
grep -Fxq 'old immutable sentinel' "$OLD_BUNDLE/scripts/example-helper.sh"
ACTIVE_ROOT=$(cd "$TEST_HOME/.aidevops/agents" && pwd -P)
[[ "$ACTIVE_ROOT" != "$OLD_BUNDLE" ]]
grep -Fxq '#!/usr/bin/env bash' "$ACTIVE_ROOT/scripts/example-helper.sh"

if bash -c 'source "$1"; runtime_config_changes_detected ".agents/scripts/example-helper.sh"' \
	_ "$REPO_ROOT/.agents/scripts/deploy-agents-on-merge.sh"; then
	printf '%s\n' 'FAIL: unrelated script was classified as a runtime config source' >&2
	exit 1
fi
if ! bash -c 'source "$1"; runtime_config_changes_detected ".agents/scripts/generate-runtime-config-commands.sh"' \
	_ "$REPO_ROOT/.agents/scripts/deploy-agents-on-merge.sh"; then
	printf '%s\n' 'FAIL: runtime config generator change was not classified for regeneration' >&2
	exit 1
fi

cat >"$FIXTURE_REPO/.agents/scripts/generate-runtime-config.sh" <<'EOF_FAILURE'
#!/usr/bin/env bash
exit 9
EOF_FAILURE
/usr/bin/git -C "$FIXTURE_REPO" add .agents/scripts/generate-runtime-config.sh
/usr/bin/git -C "$FIXTURE_REPO" commit -qm "break runtime config fixture"
SOURCE_SHA=$(/usr/bin/git -C "$FIXTURE_REPO" rev-parse HEAD)
if HOME="$TEST_HOME" SETUP_CALLS="$SETUP_CALLS" \
	bash "$REPO_ROOT/.agents/scripts/deploy-agents-on-merge.sh" \
	--repo "$FIXTURE_REPO" --expected-sha "$SOURCE_SHA" --scripts-only --quiet; then
	printf '%s\n' 'FAIL: incremental deploy ignored runtime config regeneration failure' >&2
	exit 1
fi

printf '%s\n' 'PASS: incremental deployment stages atomically, preserves the previous bundle, regenerates runtime config, and propagates failures'
exit 0

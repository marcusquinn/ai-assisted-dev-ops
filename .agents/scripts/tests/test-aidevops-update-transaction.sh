#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
TEST_ROOT="$(mktemp -d)"
PASS_COUNT=0
FAIL_COUNT=0
trap 'rm -rf "$TEST_ROOT"' EXIT

pass() {
	local name="$1"
	printf 'PASS %s\n' "$name"
	PASS_COUNT=$((PASS_COUNT + 1))
	return 0
}

fail() {
	local name="$1"
	local detail="$2"
	printf 'FAIL %s: %s\n' "$name" "$detail" >&2
	FAIL_COUNT=$((FAIL_COUNT + 1))
	return 0
}

extract_function() {
	local function_name="$1"
	local output_file="$2"
	local source_file="${3:-$REPO_ROOT/aidevops.sh}"
	awk -v function_name="$function_name" '
		$0 ~ "^" function_name "\\(\\)[[:space:]]*\\{" { capturing = 1 }
		capturing {
			print
			line = $0
			open_count = gsub(/\{/, "", line)
			line = $0
			close_count = gsub(/\}/, "", line)
			depth += open_count - close_count
			if (depth == 0) exit
		}
	' "$source_file" >"$output_file"
	[[ -s "$output_file" ]]
	return 0
}

for function_name in _update_verify_deployment_state _run_update_setup_transaction _run_update_source_access_reconciliation _update_render_changelog cmd_update; do
	extract_function "$function_name" "$TEST_ROOT/$function_name.sh"
	# shellcheck source=/dev/null
	source "$TEST_ROOT/$function_name.sh"
done
extract_function _update_fetch_main "$TEST_ROOT/_update_fetch_main.sh" \
	"$REPO_ROOT/.agents/scripts/aidevops-cli/aidevops-update-lib.sh"
extract_function _update_canonical_has_untracked_only "$TEST_ROOT/_update_canonical_has_untracked_only.sh" \
	"$REPO_ROOT/.agents/scripts/aidevops-cli/aidevops-update-lib.sh"
# shellcheck source=/dev/null
source "$TEST_ROOT/_update_canonical_has_untracked_only.sh"
# shellcheck source=/dev/null
source "$TEST_ROOT/_update_fetch_main.sh"

print_error() {
	local message="$1"
	printf 'ERROR %s\n' "$message"
	return 0
}

print_info() {
	local message="$1"
	printf 'INFO %s\n' "$message"
	return 0
}

VERIFY_RC=0
VERIFY_ERROR=""
VERIFY_REPO=""
VERIFY_SHA=""
VERIFY_ACTIVE_LINK=""
VERIFY_STAMP_FILE=""
stub_verify_aidevops_runtime_bundle_convergence() {
	local repo_dir="$1"
	local expected_sha="$2"
	local active_link="$3"
	local stamp_file="$4"
	VERIFY_REPO="$repo_dir"
	VERIFY_SHA="$expected_sha"
	VERIFY_ACTIVE_LINK="$active_link"
	VERIFY_STAMP_FILE="$stamp_file"
	if [[ "$VERIFY_RC" -ne 0 ]]; then
		print_error "$VERIFY_ERROR"
		return "$VERIFY_RC"
	fi
	return 0
}

verify_aidevops_runtime_bundle_convergence() {
	stub_verify_aidevops_runtime_bundle_convergence "$@"
	return $?
}

git() {
	local arg=""
	for arg in "$@"; do
		if [[ "$arg" == "fetch" || "$arg" == "merge" ]]; then
			printf 'BLOCKED by canonical Git guard: canonical mutation via git %s\n' "$arg" >&2
			return 42
		fi
	done
	/usr/bin/git "$@"
	return $?
}

INSTALL_DIR="$TEST_ROOT/repo"
HOME="$TEST_ROOT/home"
_AIDEVOPS_REAL_HOME="$HOME"
AGENTS_DIR="$HOME/.aidevops/agents"
mkdir -p "$INSTALL_DIR" "$HOME/.aidevops/agents"
printf '1.0.0\n' >"$INSTALL_DIR/VERSION"
printf '1.0.0\n' >"$HOME/.aidevops/agents/VERSION"

SETUP_RC=0
SETUP_SHA=""
_run_update_setup() {
	local output_mode="$1"
	: "$output_mode"
	if [[ "$SETUP_RC" -ne 0 ]]; then
		return "$SETUP_RC"
	fi
	if [[ -n "$SETUP_SHA" ]]; then
		printf '%s\n' "$SETUP_SHA" >"$HOME/.aidevops/.deployed-sha"
	fi
	return 0
}

SETUP_RC=23
if failure_output=$(_run_update_setup_transaction compact expected-sha); then
	fail "setup failure returns nonzero" "unexpected success"
elif [[ "$failure_output" == *"setup exited with code 23"* ]]; then
	pass "setup failure emits explicit deployment receipt"
else
	fail "setup failure emits explicit deployment receipt" "$failure_output"
fi

SETUP_RC=0
SETUP_SHA="stale-sha"
VERIFY_RC=1
VERIFY_ERROR="Runtime bundle convergence failed: deployed SHA stale-sha does not match release commit expected-sha"
if stale_output=$(_run_update_setup_transaction compact expected-sha); then
	fail "stale activated SHA returns nonzero" "unexpected success"
elif [[ "$stale_output" == *"does not match release commit"* ]]; then
	pass "equal versions cannot hide stale activated SHA"
else
	fail "equal versions cannot hide stale activated SHA" "$stale_output"
fi

SETUP_SHA="expected-sha"
VERIFY_RC=0
if _run_update_setup_transaction compact expected-sha >/dev/null; then
	pass "matching version and activated SHA succeed"
else
	fail "matching version and activated SHA succeed" "transaction failed"
fi
if [[ "$VERIFY_REPO" == "$INSTALL_DIR" &&
	"$VERIFY_SHA" == "expected-sha" &&
	"$VERIFY_ACTIVE_LINK" == "$HOME/.aidevops/agents" &&
	"$VERIFY_STAMP_FILE" == "$HOME/.aidevops/.deployed-sha" ]]; then
	pass "updater delegates verification to the stable active deployment"
else
	fail "updater delegates verification to the stable active deployment" \
		"repo=$VERIFY_REPO sha=$VERIFY_SHA active=$VERIFY_ACTIVE_LINK stamp=$VERIFY_STAMP_FILE"
fi

# Replace the transaction stub with the authoritative implementation and model
# the production launcher: the parent stays pinned to OLD while setup switches
# the stable activation link to NEW.
# shellcheck source=../runtime-bundle-verifier.sh
source "$REPO_ROOT/.agents/scripts/runtime-bundle-verifier.sh"
VERIFY_FIXTURE_REPO="$TEST_ROOT/verifier-repo"
VERIFY_FIXTURE_HOME="$TEST_ROOT/verifier-home"
VERIFY_OLD_ROOT="$VERIFY_FIXTURE_HOME/.aidevops/runtime-bundles/0.9.0-old-fixture/agents"
mkdir -p "$VERIFY_FIXTURE_REPO/.agents/scripts/setup/modules" "$VERIFY_OLD_ROOT"
/usr/bin/git init -q -b main "$VERIFY_FIXTURE_REPO"
/usr/bin/git -C "$VERIFY_FIXTURE_REPO" config user.email test@example.invalid
/usr/bin/git -C "$VERIFY_FIXTURE_REPO" config user.name Test
printf '1.0.0\n' >"$VERIFY_FIXTURE_REPO/VERSION"
printf '#!/usr/bin/env bash\n' >"$VERIFY_FIXTURE_REPO/aidevops.sh"
printf 'release helper\n' >"$VERIFY_FIXTURE_REPO/.agents/scripts/version-manager-release.sh"
printf 'deploy helper\n' >"$VERIFY_FIXTURE_REPO/.agents/scripts/deploy-agents-on-merge.sh"
printf 'verifier helper\n' >"$VERIFY_FIXTURE_REPO/.agents/scripts/runtime-bundle-verifier.sh"
printf 'agent deploy helper\n' >"$VERIFY_FIXTURE_REPO/.agents/scripts/setup/modules/agent-deploy.sh"
/usr/bin/git -C "$VERIFY_FIXTURE_REPO" add .
/usr/bin/git -C "$VERIFY_FIXTURE_REPO" commit -qm "fixture"
VERIFY_FIXTURE_SHA=$(/usr/bin/git -C "$VERIFY_FIXTURE_REPO" rev-parse HEAD)
VERIFY_BUNDLE_ID="1.0.0-${VERIFY_FIXTURE_SHA:0:12}-fixture"
VERIFY_NEW_ROOT="$VERIFY_FIXTURE_HOME/.aidevops/runtime-bundles/$VERIFY_BUNDLE_ID/agents"
mkdir -p "$VERIFY_NEW_ROOT/scripts/setup/modules"
cp "$VERIFY_FIXTURE_REPO/aidevops.sh" "$VERIFY_NEW_ROOT/aidevops.sh"
cp "$VERIFY_FIXTURE_REPO/.agents/scripts/version-manager-release.sh" "$VERIFY_NEW_ROOT/scripts/version-manager-release.sh"
cp "$VERIFY_FIXTURE_REPO/.agents/scripts/deploy-agents-on-merge.sh" "$VERIFY_NEW_ROOT/scripts/deploy-agents-on-merge.sh"
cp "$VERIFY_FIXTURE_REPO/.agents/scripts/runtime-bundle-verifier.sh" "$VERIFY_NEW_ROOT/scripts/runtime-bundle-verifier.sh"
cp "$VERIFY_FIXTURE_REPO/.agents/scripts/setup/modules/agent-deploy.sh" "$VERIFY_NEW_ROOT/scripts/setup/modules/agent-deploy.sh"
cp "$VERIFY_FIXTURE_REPO/VERSION" "$VERIFY_NEW_ROOT/VERSION"
VERIFY_CLI_SHA=$(_runtime_bundle_verify_sha256_file "$VERIFY_NEW_ROOT/aidevops.sh")
{
	printf 'schema=1\n'
	printf 'status=validated\n'
	printf 'bundle_id=%s\n' "$VERIFY_BUNDLE_ID"
	printf 'framework_version=1.0.0\n'
	printf 'git_sha=%s\n' "$VERIFY_FIXTURE_SHA"
	printf 'cli_sha256=%s\n' "$VERIFY_CLI_SHA"
} >"$VERIFY_NEW_ROOT/.bundle-manifest"
printf '0.9.0\n' >"$VERIFY_OLD_ROOT/VERSION"
ln -s "$VERIFY_OLD_ROOT" "$VERIFY_FIXTURE_HOME/.aidevops/agents"
printf '%s\n' "$VERIFY_FIXTURE_SHA" >"$VERIFY_FIXTURE_HOME/.aidevops/.deployed-sha"
VERIFY_LINK_TMP="$VERIFY_FIXTURE_HOME/.aidevops/agents.next"
ln -s "$VERIFY_NEW_ROOT" "$VERIFY_LINK_TMP"
if [[ "$(uname -s)" == "Darwin" ]]; then
	mv -f -h "$VERIFY_LINK_TMP" "$VERIFY_FIXTURE_HOME/.aidevops/agents"
else
	mv -Tf "$VERIFY_LINK_TMP" "$VERIFY_FIXTURE_HOME/.aidevops/agents"
fi

INSTALL_DIR="$VERIFY_FIXTURE_REPO"
HOME="$VERIFY_FIXTURE_HOME"
_AIDEVOPS_REAL_HOME="$VERIFY_FIXTURE_HOME"
AGENTS_DIR="$VERIFY_OLD_ROOT"
if _update_verify_deployment_state "$VERIFY_FIXTURE_SHA" >/dev/null &&
	[[ "$(tr -d '[:space:]' <"$AGENTS_DIR/VERSION")" == "0.9.0" ]] &&
	[[ "$(tr -d '[:space:]' <"$HOME/.aidevops/agents/VERSION")" == "1.0.0" ]]; then
	pass "parent verifies NEW through the stable link while remaining pinned to OLD"
else
	fail "parent verifies NEW through the stable link while remaining pinned to OLD" "verification failed"
fi

rm -f "$HOME/.aidevops/agents"
ln -s "$VERIFY_OLD_ROOT" "$HOME/.aidevops/agents"
if stale_link_output=$(_update_verify_deployment_state "$VERIFY_FIXTURE_SHA" 2>&1); then
	fail "authoritative updater verification rejects a stale active link" "unexpected success"
elif [[ "$stale_link_output" == *"active bundle manifest is missing"* ]]; then
	pass "authoritative updater verification rejects a stale active link"
else
	fail "authoritative updater verification rejects a stale active link" "$stale_link_output"
fi
rm -f "$HOME/.aidevops/agents"
ln -s "$VERIFY_NEW_ROOT" "$HOME/.aidevops/agents"

printf 'stale-sha\n' >"$HOME/.aidevops/.deployed-sha"
if stale_stamp_output=$(_update_verify_deployment_state "$VERIFY_FIXTURE_SHA" 2>&1); then
	fail "authoritative updater verification rejects a stale deployment stamp" "unexpected success"
elif [[ "$stale_stamp_output" == *"deployed SHA stale-sha does not match release commit"* ]]; then
	pass "authoritative updater verification rejects a stale deployment stamp"
else
	fail "authoritative updater verification rejects a stale deployment stamp" "$stale_stamp_output"
fi

HOME="$TEST_ROOT/home"
_AIDEVOPS_REAL_HOME="$HOME"
INSTALL_DIR="$TEST_ROOT/repo"
AGENTS_DIR="$HOME/.aidevops/agents"
verify_aidevops_runtime_bundle_convergence() {
	stub_verify_aidevops_runtime_bundle_convergence "$@"
	return $?
}

/usr/bin/git init -q -b main "$INSTALL_DIR"
/usr/bin/git -C "$INSTALL_DIR" config user.email test@example.invalid
/usr/bin/git -C "$INSTALL_DIR" config user.name Test
printf '0\n' >"$INSTALL_DIR/change.txt"
/usr/bin/git -C "$INSTALL_DIR" add change.txt VERSION
/usr/bin/git -C "$INSTALL_DIR" commit -qm "initial"
OLD_SHA=$(/usr/bin/git -C "$INSTALL_DIR" rev-parse HEAD)

if _update_render_changelog "$OLD_SHA" "$OLD_SHA" 1.0.0 >/dev/null; then
	pass "empty changelog range is non-fatal"
else
	fail "empty changelog range is non-fatal" "renderer returned nonzero"
fi

for commit_number in $(seq 1 25); do
	printf '%s\n' "$commit_number" >"$INSTALL_DIR/change.txt"
	/usr/bin/git -C "$INSTALL_DIR" commit -am "t$commit_number: task-prefixed change" -q
done
NEW_SHA=$(/usr/bin/git -C "$INSTALL_DIR" rev-parse HEAD)
if changelog_output=$(_update_render_changelog "$OLD_SHA" "$NEW_SHA" 1.0.0) &&
	[[ "$changelog_output" == *"t25: task-prefixed change"* ]] &&
	[[ "$changelog_output" == *"... and more"* ]]; then
	pass "bounded changelog accepts task-prefixed subjects without SIGPIPE"
else
	fail "bounded changelog accepts task-prefixed subjects without SIGPIPE" "$changelog_output"
fi

print_header() {
	local message="$1"
	printf 'HEADER %s\n' "$message"
	return 0
}

print_warning() {
	local message="$1"
	printf 'WARN %s\n' "$message"
	return 0
}

print_success() {
	local message="$1"
	printf 'OK %s\n' "$message"
	return 0
}

get_version() {
	cat "$INSTALL_DIR/VERSION"
	return 0
}

check_dir() {
	local path="$1"
	if [[ -d "$path" ]]; then
		return 0
	fi
	return 1
}

_update_repo_verify_files_changed() { return 1; }
_update_check_workflow_drift() { return 0; }
_update_verify_signature() { return 0; }
_update_fresh_install() { return 0; }
_update_sync_projects() { return 0; }
_update_reconcile_repo_verify() { return 0; }
_update_check_homebrew() { return 0; }
_update_check_planning() { return 0; }
_update_check_tools() { return 0; }
_update_sweep_opencode_symlinks() { return 0; }
_update_check_setsid() { return 0; }
_migrate_settings_supervisor_to_orchestration() { return 0; }

INTEGRATION_REMOTE="$TEST_ROOT/integration.git"
INTEGRATION_REPO="$TEST_ROOT/integration-repo"
INTEGRATION_PEER="$TEST_ROOT/integration-peer"
REAL_HELPER_REPO="$TEST_ROOT/real-helper-repo"
SETUP_CALLS="$TEST_ROOT/setup-calls"
CANONICAL_HELPER_CALLS="$TEST_ROOT/canonical-helper-calls"
UPDATE_HELPER_DIR="$TEST_ROOT/update-helper"
/usr/bin/git init -q --bare -b main "$INTEGRATION_REMOTE"
/usr/bin/git init -q -b main "$INTEGRATION_REPO"
/usr/bin/git -C "$INTEGRATION_REPO" config user.email test@example.invalid
/usr/bin/git -C "$INTEGRATION_REPO" config user.name Test
printf '1.0.0\n' >"$INTEGRATION_REPO/VERSION"
printf 'base\n' >"$INTEGRATION_REPO/runtime.txt"
/usr/bin/git -C "$INTEGRATION_REPO" add VERSION runtime.txt
/usr/bin/git -C "$INTEGRATION_REPO" commit -qm "initial"
/usr/bin/git -C "$INTEGRATION_REPO" remote add origin "$INTEGRATION_REMOTE"
/usr/bin/git -C "$INTEGRATION_REPO" push -qu origin main
BASE_SHA=$(/usr/bin/git -C "$INTEGRATION_REPO" rev-parse HEAD)
/usr/bin/git clone -q "$INTEGRATION_REMOTE" "$INTEGRATION_PEER"
/usr/bin/git -C "$INTEGRATION_PEER" config user.email test@example.invalid
/usr/bin/git -C "$INTEGRATION_PEER" config user.name Test
printf 'updated\n' >"$INTEGRATION_PEER/runtime.txt"
/usr/bin/git -C "$INTEGRATION_PEER" commit -am "t18162: task-prefixed update" -q
/usr/bin/git -C "$INTEGRATION_PEER" push -q origin main
REMOTE_SHA=$(/usr/bin/git -C "$INTEGRATION_PEER" rev-parse HEAD)

/usr/bin/git clone -q "$INTEGRATION_REMOTE" "$REAL_HELPER_REPO"
/usr/bin/git -C "$REAL_HELPER_REPO" reset -q --hard "$BASE_SHA"
/usr/bin/git -C "$INTEGRATION_PEER" tag -a v1.0.0 -m "release 1.0.0"
/usr/bin/git -C "$INTEGRATION_PEER" push -q origin refs/tags/v1.0.0
RELEASE_TAG_OBJECT=$(/usr/bin/git -C "$INTEGRATION_REMOTE" rev-parse refs/tags/v1.0.0)
FRAMEWORK_URL="https://github.com/marcusquinn/aidevops.git"
FRAMEWORK_SSH_URL="ssh://git@github.com/marcusquinn/aidevops.git"
/usr/bin/git -C "$REAL_HELPER_REPO" config "url.${INTEGRATION_REMOTE}.insteadOf" "$FRAMEWORK_URL"
/usr/bin/git -C "$REAL_HELPER_REPO" config --add "url.${INTEGRATION_REMOTE}.insteadOf" "$FRAMEWORK_SSH_URL"
/usr/bin/git -C "$REAL_HELPER_REPO" remote set-url origin "$FRAMEWORK_URL"
/usr/bin/git -C "$REAL_HELPER_REPO" remote add official-ssh "$FRAMEWORK_SSH_URL"
/usr/bin/git -C "$REAL_HELPER_REPO" remote set-head origin main
INSTALL_DIR="$REAL_HELPER_REPO"
_AIDEVOPS_UPDATE_HELPER_DIR="$REPO_ROOT/.agents/scripts"
if AIDEVOPS_REPOS_CONFIG="$TEST_ROOT/missing-repos.json" AIDEVOPS_REAL_GIT_BIN=/usr/bin/git \
	_update_fetch_main main &&
	[[ "$(/usr/bin/git -C "$REAL_HELPER_REPO" rev-parse HEAD)" == "$REMOTE_SHA" ]] &&
	[[ "$(/usr/bin/git -C "$REAL_HELPER_REPO" rev-parse refs/remotes/origin/main)" == "$REMOTE_SHA" ]] &&
	[[ "$(/usr/bin/git -C "$REAL_HELPER_REPO" rev-parse refs/tags/v1.0.0)" == "$RELEASE_TAG_OBJECT" ]] &&
	! /usr/bin/git -C "$REAL_HELPER_REPO" show-ref --verify --quiet refs/remotes/official-ssh/main &&
	grep -q '"reason":"aidevops-update"' \
		"$HOME/.aidevops/logs/canonical-recovery-audit.jsonl" &&
	grep -q '"expected_slug":"marcusquinn/aidevops"' \
		"$HOME/.aidevops/logs/canonical-recovery-audit.jsonl" &&
	grep -q '"remote":"origin"' \
		"$HOME/.aidevops/logs/canonical-recovery-audit.jsonl"; then
	pass "framework update prefers origin among equivalent official aliases"
else
	fail "framework update prefers origin among equivalent official aliases" \
		"deterministic official identity did not reach the remote tip"
fi

/usr/bin/git -C "$REAL_HELPER_REPO" reset -q --hard "$BASE_SHA"
/usr/bin/git -C "$REAL_HELPER_REPO" remote remove origin
/usr/bin/git -C "$REAL_HELPER_REPO" remote remove official-ssh
/usr/bin/git -C "$REAL_HELPER_REPO" remote add zeta-official "$FRAMEWORK_SSH_URL"
/usr/bin/git -C "$REAL_HELPER_REPO" remote add alpha-official "$FRAMEWORK_URL"
/usr/bin/git -C "$REAL_HELPER_REPO" symbolic-ref \
	refs/remotes/alpha-official/HEAD refs/remotes/alpha-official/main
/usr/bin/git -C "$REAL_HELPER_REPO" symbolic-ref \
	refs/remotes/zeta-official/HEAD refs/remotes/zeta-official/main
if AIDEVOPS_REPOS_CONFIG="$TEST_ROOT/missing-repos.json" AIDEVOPS_REAL_GIT_BIN=/usr/bin/git \
	_update_fetch_main main &&
	[[ "$(/usr/bin/git -C "$REAL_HELPER_REPO" rev-parse HEAD)" == "$REMOTE_SHA" ]] &&
	[[ "$(/usr/bin/git -C "$REAL_HELPER_REPO" rev-parse refs/remotes/alpha-official/main)" == "$REMOTE_SHA" ]] &&
	! /usr/bin/git -C "$REAL_HELPER_REPO" show-ref --verify --quiet refs/remotes/zeta-official/main &&
	grep -q '"remote":"alpha-official"' \
		"$HOME/.aidevops/logs/canonical-recovery-audit.jsonl"; then
	pass "framework update selects the first C-locale alias without origin"
else
	fail "framework update selects the first C-locale alias without origin" \
		"equivalent aliases were not selected deterministically"
fi

mkdir -p "$UPDATE_HELPER_DIR"
cat >"$UPDATE_HELPER_DIR/canonical-recovery-helper.sh" <<'EOF'
#!/usr/bin/env bash
# Supports: sync-mirror --repo PATH --reason aidevops-update
set -euo pipefail
printf '%s\n' "$*" >>"$CANONICAL_HELPER_CALLS"
command_name="$1"
shift
repo=""
branch=""
while [[ $# -gt 0 ]]; do
	case "$1" in
	--repo) repo="$2"; shift 2 ;;
	--branch) branch="$2"; shift 2 ;;
	*) shift ;;
	esac
	done
if [[ "$command_name" == "sync-mirror" ]]; then
	branch="main"
	mkdir -p "$HOME/untracked-update-backup"
	while IFS= read -r untracked_path; do
		[[ -n "$untracked_path" ]] || continue
	cp "$repo/$untracked_path" "$HOME/untracked-update-backup/${untracked_path##*/}"
	rm "$repo/$untracked_path"
	done < <(/usr/bin/git -C "$repo" ls-files --others --exclude-standard)
fi
/usr/bin/git -C "$repo" fetch --no-tags origin "$branch" --quiet
IFS= read -r version <"$repo/VERSION"
/usr/bin/git -C "$repo" fetch --no-tags origin \
	"refs/tags/v${version}:refs/tags/v${version}" --quiet
/usr/bin/git -C "$repo" merge --ff-only "origin/$branch" --quiet
EOF
chmod +x "$UPDATE_HELPER_DIR/canonical-recovery-helper.sh"
export CANONICAL_HELPER_CALLS
_AIDEVOPS_UPDATE_HELPER_DIR="$UPDATE_HELPER_DIR"

INSTALL_DIR="$INTEGRATION_REPO"
SETUP_RC=0
SETUP_SHA="$REMOTE_SHA"
printf '%s\n' "$BASE_SHA" >"$HOME/.aidevops/.deployed-sha"
printf '1.0.0\n' >"$HOME/.aidevops/agents/VERSION"
_run_update_setup() {
	local output_mode="$1"
	: "$output_mode"
	printf 'called\n' >>"$SETUP_CALLS"
	printf '%s\n' "$SETUP_SHA" >"$HOME/.aidevops/.deployed-sha"
	return "$SETUP_RC"
}
AGENTS_DIR="$HOME/.aidevops/agents"
AIDEVOPS_SKIP_PULSE_RESTART=1
_AIDEVOPS_UPDATE_TRUE=true

INTEGRATION_LINKED="$TEST_ROOT/integration-linked"
/usr/bin/git -C "$INTEGRATION_REPO" worktree add -q -b linked-update-test "$INTEGRATION_LINKED"
INSTALL_DIR="$INTEGRATION_LINKED"
if AIDEVOPS_REAL_GIT_BIN=/usr/bin/git _update_fetch_main main &&
	[[ "$(/usr/bin/git -C "$INTEGRATION_LINKED" rev-parse refs/remotes/origin/main)" == "$REMOTE_SHA" ]]; then
	pass "linked checkout fetch bypasses the canonical Git guard shim"
else
	fail "linked checkout fetch bypasses the canonical Git guard shim" "fetch did not use the resolved Git binary"
fi
INSTALL_DIR="$INTEGRATION_REPO"

if integration_output=$(cmd_update --skip-project-sync --compact) &&
	[[ "$(/usr/bin/git -C "$INTEGRATION_REPO" rev-parse HEAD)" == "$REMOTE_SHA" ]] &&
	grep -q -- '--reason aidevops-update' "$CANONICAL_HELPER_CALLS" &&
	[[ -s "$SETUP_CALLS" ]] &&
	[[ "$integration_output" == *"t18162: task-prefixed update"* ]] &&
	[[ "$integration_output" == *"agents deployed"* ]]; then
	pass "shim-safe audited canonical fast-forward reaches setup and verifies activation"
else
	fail "shim-safe audited canonical fast-forward reaches setup and verifies activation" "$integration_output"
fi

printf 'untracked update fixture\n' >"$INTEGRATION_REPO/untracked-update.txt"
if untracked_output=$(cmd_update --skip-project-sync --compact) &&
	[[ ! -e "$INTEGRATION_REPO/untracked-update.txt" ]] &&
	[[ -f "$HOME/untracked-update-backup/untracked-update.txt" ]] &&
	grep -q -- '^sync-mirror .*--reason aidevops-update' "$CANONICAL_HELPER_CALLS" &&
	[[ "$untracked_output" == *"Preserving untracked canonical files"* ]]; then
	pass "untracked-only canonical update uses lossless mirror synchronization"
else
	fail "untracked-only canonical update uses lossless mirror synchronization" "$untracked_output"
fi

printf 'dirty update fixture\n' >>"$INTEGRATION_REPO/runtime.txt"
helper_calls_before=$(wc -l <"$CANONICAL_HELPER_CALLS")
if dirty_output=$(cmd_update --skip-project-sync --compact 2>&1); then
	fail "dirty canonical checkout remains non-destructive" "unexpected success"
elif [[ "$dirty_output" == *"tracked local changes exist"* ]] &&
	[[ "$(wc -l <"$CANONICAL_HELPER_CALLS")" -eq "$helper_calls_before" ]] &&
	[[ "$(/usr/bin/git -C "$INTEGRATION_REPO" rev-parse HEAD)" == "$REMOTE_SHA" ]]; then
	pass "dirty canonical checkout remains non-destructive"
else
	fail "dirty canonical checkout remains non-destructive" "$dirty_output"
fi
/usr/bin/git -C "$INTEGRATION_REPO" checkout -q -- runtime.txt

rm "$UPDATE_HELPER_DIR/canonical-recovery-helper.sh"
if missing_helper_output=$(_update_fetch_main main 2>&1); then
	fail "missing canonical helper fails with stable-path guidance" "unexpected success"
elif [[ "$missing_helper_output" == *"$HOME/.aidevops/agents/scripts/canonical-recovery-helper.sh"* ]] &&
	[[ "$missing_helper_output" == *"Reinstall aidevops"* ]]; then
	pass "missing canonical helper fails with stable-path guidance"
else
	fail "missing canonical helper fails with stable-path guidance" "$missing_helper_output"
fi

printf '%s passed, %s failed\n' "$PASS_COUNT" "$FAIL_COUNT"
[[ "$FAIL_COUNT" -eq 0 ]]

#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
HELPER="${SCRIPT_DIR}/canonical-recovery-helper.sh"
ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT
export HOME="${ROOT}/home"
REPO="${ROOT}/repo"
REMOTE="${ROOT}/remote.git"
UPDATER="${ROOT}/updater"
OCCUPIED="${ROOT}/main-worktree"
mkdir -p "$HOME" "$REPO"
/usr/bin/git init -q --bare "$REMOTE"
/usr/bin/git -C "$REPO" init -q -b main
/usr/bin/git -C "$REPO" config user.name Test
/usr/bin/git -C "$REPO" config user.email test@example.invalid
/usr/bin/git -C "$REPO" config commit.gpgsign false
printf 'seed\n' >"${REPO}/README.md"
/usr/bin/git -C "$REPO" add README.md
/usr/bin/git -C "$REPO" commit -q -m seed
/usr/bin/git -C "$REPO" remote add origin "$REMOTE"
/usr/bin/git -C "$REPO" push -q -u origin main
/usr/bin/git -C "$REMOTE" symbolic-ref HEAD refs/heads/main
/usr/bin/git -C "$REPO" remote set-head origin main
/usr/bin/git -C "$REPO" switch -q -c safety/test
/usr/bin/git -C "$REPO" worktree add -q "$OCCUPIED" main

if AIDEVOPS_REAL_GIT_BIN=/usr/bin/git bash "$HELPER" restore-default --repo "$REPO" --issue 27014 --confirm RESTORE_CANONICAL_DEFAULT >/dev/null 2>&1; then
	printf 'FAIL recovery ignored occupied default branch\n'
	exit 1
fi
printf 'PASS recovery refuses occupied default branch\n'

/usr/bin/git -C "$REPO" worktree remove "$OCCUPIED"
printf 'invalid global audit chain\n' >"${ROOT}/broken-global-audit.jsonl"
if AUDIT_LOG_FILE="${ROOT}/broken-global-audit.jsonl" AIDEVOPS_REAL_GIT_BIN=/usr/bin/git \
	bash "$HELPER" restore-default --repo "$REPO" --issue 27014 --confirm RESTORE_CANONICAL_DEFAULT >/dev/null &&
	[[ "$(/usr/bin/git -C "$REPO" branch --show-current)" == "main" ]] &&
	[[ -s "$HOME/.aidevops/logs/canonical-recovery-audit.jsonl" ]]; then
	printf 'PASS audited recovery restores only default branch\n'
else
	printf 'FAIL audited recovery did not restore default branch\n'
	exit 1
fi

/usr/bin/git -C "$REPO" switch -q safety/test
/usr/bin/git clone -q "$REMOTE" "$UPDATER"
/usr/bin/git -C "$UPDATER" config user.name Test
/usr/bin/git -C "$UPDATER" config user.email test@example.invalid
printf 'remote ahead\n' >>"${UPDATER}/README.md"
/usr/bin/git -C "$UPDATER" commit -q -am 'remote ahead'
/usr/bin/git -C "$UPDATER" push -q origin main
remote_tip=$(/usr/bin/git -C "$REMOTE" rev-parse refs/heads/main)
if AIDEVOPS_REAL_GIT_BIN=/usr/bin/git bash "$HELPER" restore-default --repo "$REPO" --issue 27014 --confirm RESTORE_CANONICAL_DEFAULT >/dev/null &&
	[[ "$(/usr/bin/git -C "$REPO" branch --show-current)" == "main" ]] &&
	[[ "$(/usr/bin/git -C "$REPO" rev-parse HEAD)" == "$remote_tip" ]]; then
	printf 'PASS audited recovery fast-forwards to exact origin default tip\n'
else
	printf 'FAIL audited recovery did not reach exact origin default tip\n'
	exit 1
fi

RENAMED_REPO="${ROOT}/renamed-repo"
RENAMED_REMOTE="${ROOT}/renamed-remote.git"
RENAMED_UPDATER="${ROOT}/renamed-updater"
RENAMED_CONFIG="${ROOT}/renamed-repos.json"
RENAMED_URL="https://github.com/Example/Canonical-Remote.git"
mkdir -p "$RENAMED_REPO"
/usr/bin/git init -q --bare "$RENAMED_REMOTE"
/usr/bin/git -C "$RENAMED_REPO" init -q -b main
/usr/bin/git -C "$RENAMED_REPO" config user.name Test
/usr/bin/git -C "$RENAMED_REPO" config user.email test@example.invalid
/usr/bin/git -C "$RENAMED_REPO" config commit.gpgsign false
/usr/bin/git -C "$RENAMED_REPO" config "url.${RENAMED_REMOTE}.insteadOf" "$RENAMED_URL"
printf 'renamed seed\n' >"${RENAMED_REPO}/README.md"
/usr/bin/git -C "$RENAMED_REPO" add README.md
/usr/bin/git -C "$RENAMED_REPO" commit -q -m seed
/usr/bin/git -C "$RENAMED_REPO" remote add github "$RENAMED_URL"
/usr/bin/git -C "$RENAMED_REPO" push -q github main
/usr/bin/git -C "$RENAMED_REPO" remote set-url --push github \
	ssh://git@github.com/example/canonical-remote.git
/usr/bin/git -C "$RENAMED_REMOTE" symbolic-ref HEAD refs/heads/main
/usr/bin/git -C "$RENAMED_REPO" remote set-head github main
/usr/bin/git clone -q "$RENAMED_REMOTE" "$RENAMED_UPDATER"
/usr/bin/git -C "$RENAMED_UPDATER" config user.name Test
/usr/bin/git -C "$RENAMED_UPDATER" config user.email test@example.invalid
printf 'renamed remote ahead\n' >>"${RENAMED_UPDATER}/README.md"
/usr/bin/git -C "$RENAMED_UPDATER" commit -q -am 'renamed remote ahead'
/usr/bin/git -C "$RENAMED_UPDATER" push -q origin main
renamed_remote_tip=$(/usr/bin/git -C "$RENAMED_REMOTE" rev-parse refs/heads/main)
renamed_before=$(/usr/bin/git -C "$RENAMED_REPO" rev-parse HEAD)
unregistered_output=""
if unregistered_output=$(AIDEVOPS_REPOS_CONFIG="${ROOT}/missing-repos.json" AIDEVOPS_REAL_GIT_BIN=/usr/bin/git \
	bash "$HELPER" fast-forward-current --repo "$RENAMED_REPO" --branch main \
	--issue 28865 --confirm FAST_FORWARD_CANONICAL_BRANCH 2>&1); then
	printf 'FAIL unregistered GitHub recovery was accepted\n'
	exit 1
elif [[ "$unregistered_output" == *"BLOCKED: registered GitHub remote is missing, mismatched, or ambiguous"* ]] &&
	[[ "$(/usr/bin/git -C "$RENAMED_REPO" rev-parse HEAD)" == "$renamed_before" ]]; then
	printf 'PASS ordinary recovery rejects an unregistered GitHub repository\n'
else
	printf 'FAIL unregistered GitHub recovery did not fail before mutation\n'
	exit 1
fi
update_identity_output=""
if update_identity_output=$(AIDEVOPS_REPOS_CONFIG="${ROOT}/missing-repos.json" AIDEVOPS_REAL_GIT_BIN=/usr/bin/git \
	bash "$HELPER" fast-forward-current --repo "$RENAMED_REPO" --branch main \
	--reason aidevops-update --confirm FAST_FORWARD_CANONICAL_BRANCH 2>&1); then
	printf 'FAIL framework update accepted a non-framework GitHub remote\n'
	exit 1
elif [[ "$update_identity_output" == *"BLOCKED: official aidevops GitHub remote is missing, mismatched, or ambiguous"* ]] &&
	[[ "$(/usr/bin/git -C "$RENAMED_REPO" rev-parse HEAD)" == "$renamed_before" ]]; then
	printf 'PASS framework update rejects a non-framework GitHub remote\n'
else
	printf 'FAIL framework update identity rejection was not actionable or non-destructive\n'
	exit 1
fi
printf '{"initialized_repos":[{"slug":"example/canonical-remote","path":"%s"}]}\n' \
	"$RENAMED_REPO" >"$RENAMED_CONFIG"
CONFIG_FAILURE_GIT="${ROOT}/config-failure-git"
cat >"$CONFIG_FAILURE_GIT" <<'SH'
#!/usr/bin/env bash
set -u
status=0
if [[ "${3:-}" == "config" && "${4:-}" == "--get-all" &&
	"${5:-}" == "${AIDEVOPS_TEST_FAIL_CONFIG_KEY:-}" ]]; then
	case "${AIDEVOPS_TEST_CONFIG_FAILURE_MODE:-}" in
	before-output) exit "${AIDEVOPS_TEST_FAIL_STATUS:-2}" ;;
	after-valid-output)
		/usr/bin/git "$@" || status=$?
		[[ "$status" -eq 0 ]] || exit "$status"
		exit "${AIDEVOPS_TEST_FAIL_STATUS:-2}"
		;;
	esac
fi
exec /usr/bin/git "$@"
SH
chmod +x "$CONFIG_FAILURE_GIT"
if AIDEVOPS_REPOS_CONFIG="$RENAMED_CONFIG" AIDEVOPS_REAL_GIT_BIN=/usr/bin/git \
	bash "$HELPER" fast-forward-current --repo "$RENAMED_REPO" --branch main \
	--issue 28865 --confirm FAST_FORWARD_CANONICAL_BRANCH >/dev/null &&
	[[ "$(/usr/bin/git -C "$RENAMED_REPO" rev-parse HEAD)" == "$renamed_remote_tip" ]] &&
	[[ "$(/usr/bin/git -C "$RENAMED_REPO" rev-parse refs/remotes/github/main)" == "$renamed_remote_tip" ]] &&
	! /usr/bin/git -C "$RENAMED_REPO" remote get-url origin >/dev/null 2>&1; then
	printf 'PASS matching renamed GitHub remote drives default-branch fast-forward\n'
else
	printf 'FAIL matching renamed GitHub remote did not drive default-branch fast-forward\n'
	exit 1
fi

/usr/bin/git -C "$RENAMED_REPO" remote add origin git://github.com/Other/Repository.git
printf 'renamed remote ahead again\n' >>"${RENAMED_UPDATER}/README.md"
/usr/bin/git -C "$RENAMED_UPDATER" commit -q -am 'renamed remote ahead again'
/usr/bin/git -C "$RENAMED_UPDATER" push -q origin main
renamed_remote_tip=$(/usr/bin/git -C "$RENAMED_REMOTE" rev-parse refs/heads/main)
if AIDEVOPS_REPOS_CONFIG="$RENAMED_CONFIG" AIDEVOPS_REAL_GIT_BIN=/usr/bin/git \
	bash "$HELPER" fast-forward-current --repo "$RENAMED_REPO" --branch main \
	--issue 28865 --confirm FAST_FORWARD_CANONICAL_BRANCH >/dev/null &&
	[[ "$(/usr/bin/git -C "$RENAMED_REPO" rev-parse HEAD)" == "$renamed_remote_tip" ]] &&
	! /usr/bin/git -C "$RENAMED_REPO" show-ref --verify --quiet refs/remotes/origin/main; then
	printf 'PASS matching alternate remote wins over mismatched origin\n'
else
	printf 'FAIL mismatched origin displaced the matching alternate remote\n'
	exit 1
fi

renamed_before=$(/usr/bin/git -C "$RENAMED_REPO" rev-parse HEAD)
/usr/bin/git -C "$RENAMED_REPO" config --add remote.github.url \
	https://github.com/Other/Repository.git
multi_url_output=""
if multi_url_output=$(AIDEVOPS_REPOS_CONFIG="$RENAMED_CONFIG" AIDEVOPS_REAL_GIT_BIN=/usr/bin/git \
	bash "$HELPER" fast-forward-current --repo "$RENAMED_REPO" --branch main \
	--issue 28865 --confirm FAST_FORWARD_CANONICAL_BRANCH 2>&1); then
	printf 'FAIL mixed matching and mismatched fetch URLs were accepted\n'
	exit 1
elif [[ "$multi_url_output" == *"BLOCKED: registered GitHub remote is missing, mismatched, or ambiguous"* ]] &&
	[[ "$(/usr/bin/git -C "$RENAMED_REPO" rev-parse HEAD)" == "$renamed_before" ]]; then
	printf 'PASS mixed matching and mismatched fetch URLs fail before canonical mutation\n'
else
	printf 'FAIL mixed fetch URL rejection did not prove remote identity failure\n'
	exit 1
fi
/usr/bin/git -C "$RENAMED_REPO" config --unset-all remote.github.url
/usr/bin/git -C "$RENAMED_REPO" config --add remote.github.url "$RENAMED_URL"
/usr/bin/git -C "$RENAMED_REPO" config --add remote.github.url ""
empty_url_output=""
if empty_url_output=$(AIDEVOPS_REPOS_CONFIG="$RENAMED_CONFIG" AIDEVOPS_REAL_GIT_BIN=/usr/bin/git \
	bash "$HELPER" fast-forward-current --repo "$RENAMED_REPO" --branch main \
	--issue 28865 --confirm FAST_FORWARD_CANONICAL_BRANCH 2>&1); then
	printf 'FAIL empty fetch URL member was accepted\n'
	exit 1
elif [[ "$empty_url_output" == *"BLOCKED: registered GitHub remote is missing, mismatched, or ambiguous"* ]] &&
	[[ "$(/usr/bin/git -C "$RENAMED_REPO" rev-parse HEAD)" == "$renamed_before" ]]; then
	printf 'PASS empty fetch URL member fails before canonical mutation\n'
else
	printf 'FAIL empty fetch URL rejection did not prove remote identity failure\n'
	exit 1
fi
/usr/bin/git -C "$RENAMED_REPO" config --unset-all remote.github.url
/usr/bin/git -C "$RENAMED_REPO" config --add remote.github.url "$RENAMED_URL"
for failure_mode in before-output after-valid-output; do
	config_failure_output=""
	if config_failure_output=$(AIDEVOPS_REPOS_CONFIG="$RENAMED_CONFIG" \
		AIDEVOPS_REAL_GIT_BIN="$CONFIG_FAILURE_GIT" \
		AIDEVOPS_TEST_FAIL_CONFIG_KEY=remote.github.url \
		AIDEVOPS_TEST_CONFIG_FAILURE_MODE="$failure_mode" \
		bash "$HELPER" fast-forward-current --repo "$RENAMED_REPO" --branch main \
		--issue 28865 --confirm FAST_FORWARD_CANONICAL_BRANCH 2>&1); then
		printf 'FAIL fetch URL enumeration accepted the %s config failure\n' "$failure_mode"
		exit 1
	elif [[ "$config_failure_output" == *"BLOCKED: registered GitHub remote is missing, mismatched, or ambiguous"* ]] &&
		[[ "$(/usr/bin/git -C "$RENAMED_REPO" rev-parse HEAD)" == "$renamed_before" ]]; then
		printf 'PASS fetch URL enumeration rejects the %s config failure before mutation\n' "$failure_mode"
	else
		printf 'FAIL %s fetch URL config failure was not fail-closed\n' "$failure_mode"
		exit 1
	fi
done
config_failure_output=""
if config_failure_output=$(AIDEVOPS_REPOS_CONFIG="$RENAMED_CONFIG" \
	AIDEVOPS_REAL_GIT_BIN="$CONFIG_FAILURE_GIT" \
	AIDEVOPS_TEST_FAIL_CONFIG_KEY=remote.github.pushurl \
	AIDEVOPS_TEST_CONFIG_FAILURE_MODE=after-valid-output AIDEVOPS_TEST_FAIL_STATUS=1 \
	bash "$HELPER" fast-forward-current --repo "$RENAMED_REPO" --branch main \
	--issue 28865 --confirm FAST_FORWARD_CANONICAL_BRANCH 2>&1); then
	printf 'FAIL push URL output plus absent status was accepted as an absent key\n'
	exit 1
elif [[ "$config_failure_output" == *"BLOCKED: registered GitHub remote is missing, mismatched, or ambiguous"* ]] &&
	[[ "$(/usr/bin/git -C "$RENAMED_REPO" rev-parse HEAD)" == "$renamed_before" ]]; then
	printf 'PASS push URL output plus absent status fails before canonical mutation\n'
else
	printf 'FAIL push URL output plus absent status was not fail-closed\n'
	exit 1
fi
/usr/bin/git -C "$RENAMED_REPO" config --unset-all remote.github.pushurl
/usr/bin/git -C "$RENAMED_REPO" config --add remote.github.pushurl \
	git@github.com:Other/Repository.git
/usr/bin/git -C "$RENAMED_REPO" config --add remote.github.pushurl \
	ssh://git@github.com/example/canonical-remote.git
multi_url_output=""
if multi_url_output=$(AIDEVOPS_REPOS_CONFIG="$RENAMED_CONFIG" AIDEVOPS_REAL_GIT_BIN=/usr/bin/git \
	bash "$HELPER" fast-forward-current --repo "$RENAMED_REPO" --branch main \
	--issue 28865 --confirm FAST_FORWARD_CANONICAL_BRANCH 2>&1); then
	printf 'FAIL mixed mismatched and matching push URLs were accepted\n'
	exit 1
elif [[ "$multi_url_output" == *"BLOCKED: registered GitHub remote is missing, mismatched, or ambiguous"* ]] &&
	[[ "$(/usr/bin/git -C "$RENAMED_REPO" rev-parse HEAD)" == "$renamed_before" ]]; then
	printf 'PASS mixed mismatched and matching push URLs fail before canonical mutation\n'
else
	printf 'FAIL mixed push URL rejection did not prove remote identity failure\n'
	exit 1
fi
/usr/bin/git -C "$RENAMED_REPO" config --unset-all remote.github.pushurl
/usr/bin/git -C "$RENAMED_REPO" config --add remote.github.pushurl \
	ssh://git@github.com:22/example/canonical-remote.git
/usr/bin/git -C "$RENAMED_REPO" config --add remote.github.pushurl ""
empty_url_output=""
if empty_url_output=$(AIDEVOPS_REPOS_CONFIG="$RENAMED_CONFIG" AIDEVOPS_REAL_GIT_BIN=/usr/bin/git \
	bash "$HELPER" fast-forward-current --repo "$RENAMED_REPO" --branch main \
	--issue 28865 --confirm FAST_FORWARD_CANONICAL_BRANCH 2>&1); then
	printf 'FAIL empty push URL member was accepted\n'
	exit 1
elif [[ "$empty_url_output" == *"BLOCKED: registered GitHub remote is missing, mismatched, or ambiguous"* ]] &&
	[[ "$(/usr/bin/git -C "$RENAMED_REPO" rev-parse HEAD)" == "$renamed_before" ]]; then
	printf 'PASS empty push URL member fails before canonical mutation\n'
else
	printf 'FAIL empty push URL rejection did not prove remote identity failure\n'
	exit 1
fi
/usr/bin/git -C "$RENAMED_REPO" config --unset-all remote.github.pushurl
/usr/bin/git -C "$RENAMED_REPO" config --add remote.github.pushurl \
	ssh://git@github.com:22/example/canonical-remote.git
/usr/bin/git -C "$RENAMED_REPO" remote add duplicate \
	ssh://git@github.com:22/EXAMPLE/CANONICAL-REMOTE.git
remote_rejection_output=""
if remote_rejection_output=$(AIDEVOPS_REPOS_CONFIG="$RENAMED_CONFIG" AIDEVOPS_REAL_GIT_BIN=/usr/bin/git \
	bash "$HELPER" fast-forward-current --repo "$RENAMED_REPO" --branch main \
	--issue 28865 --confirm FAST_FORWARD_CANONICAL_BRANCH 2>&1); then
	printf 'FAIL ambiguous matching GitHub remotes were accepted\n'
	exit 1
elif [[ "$remote_rejection_output" == *"BLOCKED: registered GitHub remote is missing, mismatched, or ambiguous"* ]] &&
	[[ "$(/usr/bin/git -C "$RENAMED_REPO" rev-parse HEAD)" == "$renamed_before" ]]; then
	printf 'PASS ambiguous matching GitHub remotes fail before canonical mutation\n'
else
	printf 'FAIL ambiguous remote rejection did not prove identity failure before mutation\n'
	exit 1
fi
/usr/bin/git -C "$RENAMED_REPO" remote remove duplicate
/usr/bin/git -C "$RENAMED_REPO" remote remove github
/usr/bin/git -C "$RENAMED_REPO" remote set-url origin \
	ssh://git@github.com:22/Other/Repository.git
remote_rejection_output=""
if remote_rejection_output=$(AIDEVOPS_REPOS_CONFIG="$RENAMED_CONFIG" AIDEVOPS_REAL_GIT_BIN=/usr/bin/git \
	bash "$HELPER" fast-forward-current --repo "$RENAMED_REPO" --branch main \
	--issue 28865 --confirm FAST_FORWARD_CANONICAL_BRANCH 2>&1); then
	printf 'FAIL mismatched-only GitHub remote was accepted\n'
	exit 1
elif [[ "$remote_rejection_output" == *"BLOCKED: registered GitHub remote is missing, mismatched, or ambiguous"* ]] &&
	[[ "$(/usr/bin/git -C "$RENAMED_REPO" rev-parse HEAD)" == "$renamed_before" ]]; then
	printf 'PASS mismatched-only GitHub remote fails before canonical mutation\n'
else
	printf 'FAIL mismatched remote rejection did not prove identity failure before mutation\n'
	exit 1
fi
/usr/bin/git -C "$RENAMED_REPO" remote set-url origin \
	https://github.com:443@evil.example/example/canonical-remote.git
remote_rejection_output=""
if remote_rejection_output=$(AIDEVOPS_REPOS_CONFIG="$RENAMED_CONFIG" AIDEVOPS_REAL_GIT_BIN=/usr/bin/git \
	bash "$HELPER" fast-forward-current --repo "$RENAMED_REPO" --branch main \
	--issue 28865 --confirm FAST_FORWARD_CANONICAL_BRANCH 2>&1); then
	printf 'FAIL userinfo-confused GitHub authority was accepted\n'
	exit 1
elif [[ "$remote_rejection_output" == *"BLOCKED: registered GitHub remote is missing, mismatched, or ambiguous"* ]] &&
	[[ "$(/usr/bin/git -C "$RENAMED_REPO" rev-parse HEAD)" == "$renamed_before" ]]; then
	printf 'PASS userinfo-confused GitHub authority cannot activate origin fallback\n'
else
	printf 'FAIL userinfo-confused authority rejection did not prove identity failure\n'
	exit 1
fi

/usr/bin/git -C "$REPO" switch -q -c develop
/usr/bin/git -C "$REPO" push -q -u origin develop
/usr/bin/git -C "$UPDATER" fetch -q origin develop
/usr/bin/git -C "$UPDATER" switch -q -c develop origin/develop
export AIDEVOPS_REPOS_CONFIG="${ROOT}/repos.json"
printf '{"initialized_repos":[{"path":"%s","pr_base_branch":"develop"}]}\n' "$REPO" >"$AIDEVOPS_REPOS_CONFIG"
printf 'remote develop ahead\n' >>"${UPDATER}/README.md"
/usr/bin/git -C "$UPDATER" commit -q -am 'remote develop ahead'
/usr/bin/git -C "$UPDATER" push -q origin develop
develop_remote_tip=$(/usr/bin/git -C "$REMOTE" rev-parse refs/heads/develop)
if AIDEVOPS_REAL_GIT_BIN=/usr/bin/git bash "$HELPER" fast-forward-current --repo "$REPO" --branch develop --issue 28032 --confirm FAST_FORWARD_CANONICAL_BRANCH >/dev/null &&
	[[ "$(/usr/bin/git -C "$REPO" branch --show-current)" == "develop" ]] &&
	[[ "$(/usr/bin/git -C "$REPO" rev-parse HEAD)" == "$develop_remote_tip" ]] &&
	grep -q 'Canonical current-branch fast-forward authorized' "$HOME/.aidevops/logs/canonical-recovery-audit.jsonl"; then
	printf 'PASS audited fast-forward updates the current non-default branch without switching\n'
else
	printf 'FAIL audited fast-forward did not update the current non-default branch\n'
	exit 1
fi

update_local_mirror_output=""
if update_local_mirror_output=$(AIDEVOPS_REAL_GIT_BIN=/usr/bin/git \
	bash "$HELPER" fast-forward-current --repo "$REPO" --branch develop \
	--reason aidevops-update --confirm FAST_FORWARD_CANONICAL_BRANCH 2>&1); then
	printf 'FAIL framework update accepted a local mirror without official GitHub identity\n'
	exit 1
elif [[ "$update_local_mirror_output" == *"BLOCKED: official aidevops GitHub remote is missing, mismatched, or ambiguous"* ]] &&
	[[ "$(/usr/bin/git -C "$REPO" rev-parse HEAD)" == "$develop_remote_tip" ]]; then
	printf 'PASS framework update rejects a local mirror without official GitHub identity\n'
else
	printf 'FAIL local-mirror framework update rejection was not actionable or non-destructive\n'
	exit 1
fi

develop_local_tip=$(/usr/bin/git -C "$REPO" rev-parse HEAD)
mkdir "${REPO}/.git/aidevops-canonical-recovery.lock"
if AIDEVOPS_REAL_GIT_BIN=/usr/bin/git bash "$HELPER" fast-forward-current --repo "$REPO" --branch develop --issue 28032 --confirm FAST_FORWARD_CANONICAL_BRANCH >/dev/null 2>&1; then
	printf 'FAIL current-branch fast-forward ignored concurrent recovery lock\n'
	exit 1
fi
rmdir "${REPO}/.git/aidevops-canonical-recovery.lock"
if [[ "$(/usr/bin/git -C "$REPO" rev-parse HEAD)" == "$develop_local_tip" ]]; then
	printf 'PASS current-branch fast-forward refuses concurrent recovery\n'
else
	printf 'FAIL concurrent recovery refusal changed canonical state\n'
	exit 1
fi

printf 'remote develop race window\n' >>"${UPDATER}/README.md"
/usr/bin/git -C "$UPDATER" commit -q -am 'remote develop race window'
/usr/bin/git -C "$UPDATER" push -q origin develop
develop_remote_tip=$(/usr/bin/git -C "$REMOTE" rev-parse refs/heads/develop)
/usr/bin/git -C "$REPO" branch race-window "$develop_local_tip"
race_hook="${ROOT}/switch-canonical-branch.sh"
printf '%s\n' \
	'#!/usr/bin/env bash' \
	"repo_path=\"\${1:-}\"" \
	"/usr/bin/git -C \"\$repo_path\" switch -q race-window" >"$race_hook"
chmod +x "$race_hook"
if AIDEVOPS_CANONICAL_BEFORE_REF_UPDATE_HOOK="$race_hook" AIDEVOPS_REAL_GIT_BIN=/usr/bin/git \
	bash "$HELPER" fast-forward-current --repo "$REPO" --branch develop --issue 28032 --confirm FAST_FORWARD_CANONICAL_BRANCH >/dev/null 2>&1; then
	printf 'FAIL current-branch fast-forward ignored a concurrent branch switch\n'
	exit 1
elif [[ "$(/usr/bin/git -C "$REPO" branch --show-current)" == "race-window" ]] &&
	[[ "$(/usr/bin/git -C "$REPO" rev-parse develop)" == "$develop_local_tip" ]] &&
	[[ "$(/usr/bin/git -C "$REPO" rev-parse race-window)" == "$develop_local_tip" ]] &&
	[[ "$(/usr/bin/git -C "$REMOTE" rev-parse refs/heads/develop)" == "$develop_remote_tip" ]]; then
	printf 'PASS compare-and-swap refuses a concurrent branch switch without advancing either local branch\n'
else
	printf 'FAIL concurrent branch switch advanced or rewrote a local branch\n'
	exit 1
fi
/usr/bin/git -C "$REPO" switch -q develop
/usr/bin/git -C "$REPO" branch -d race-window >/dev/null
if AIDEVOPS_REAL_GIT_BIN=/usr/bin/git bash "$HELPER" fast-forward-current --repo "$REPO" --branch develop --issue 28032 --confirm FAST_FORWARD_CANONICAL_BRANCH >/dev/null &&
	[[ "$(/usr/bin/git -C "$REPO" rev-parse HEAD)" == "$develop_remote_tip" ]]; then
	printf 'PASS audited fast-forward succeeds after a refused concurrent branch switch\n'
else
	printf 'FAIL audited fast-forward did not recover after the refused concurrent branch switch\n'
	exit 1
fi

develop_local_tip=$(/usr/bin/git -C "$REPO" rev-parse HEAD)
printf 'remote develop post-CAS race window\n' >>"${UPDATER}/README.md"
/usr/bin/git -C "$UPDATER" commit -q -am 'remote develop post-CAS race window'
/usr/bin/git -C "$UPDATER" push -q origin develop
develop_remote_tip=$(/usr/bin/git -C "$REMOTE" rev-parse refs/heads/develop)
/usr/bin/git -C "$REPO" branch race-window "$develop_local_tip"
if AIDEVOPS_CANONICAL_BEFORE_WORKTREE_UPDATE_HOOK="$race_hook" AIDEVOPS_REAL_GIT_BIN=/usr/bin/git \
	bash "$HELPER" fast-forward-current --repo "$REPO" --branch develop --issue 28032 --confirm FAST_FORWARD_CANONICAL_BRANCH >/dev/null 2>&1; then
	printf 'FAIL current-branch fast-forward ignored a post-CAS branch switch\n'
	exit 1
elif [[ "$(/usr/bin/git -C "$REPO" branch --show-current)" == "race-window" ]] &&
	[[ "$(/usr/bin/git -C "$REPO" rev-parse develop)" == "$develop_local_tip" ]] &&
	[[ "$(/usr/bin/git -C "$REPO" rev-parse race-window)" == "$develop_local_tip" ]] &&
	[[ -z "$(/usr/bin/git -C "$REPO" status --porcelain)" ]] &&
	[[ "$(/usr/bin/git -C "$REMOTE" rev-parse refs/heads/develop)" == "$develop_remote_tip" ]]; then
	printf 'PASS post-CAS branch switch restores both the named ref and concurrent branch worktree\n'
else
	printf 'FAIL post-CAS branch switch left a local ref or worktree inconsistent\n'
	exit 1
fi
/usr/bin/git -C "$REPO" switch -q develop
/usr/bin/git -C "$REPO" branch -d race-window >/dev/null
if AIDEVOPS_REAL_GIT_BIN=/usr/bin/git bash "$HELPER" fast-forward-current --repo "$REPO" --branch develop --issue 28032 --confirm FAST_FORWARD_CANONICAL_BRANCH >/dev/null &&
	[[ "$(/usr/bin/git -C "$REPO" rev-parse HEAD)" == "$develop_remote_tip" ]]; then
	printf 'PASS audited fast-forward succeeds after restoring a post-CAS branch switch\n'
else
	printf 'FAIL audited fast-forward did not recover after restoring a post-CAS branch switch\n'
	exit 1
fi

develop_local_tip=$(/usr/bin/git -C "$REPO" rev-parse HEAD)
if AIDEVOPS_REAL_GIT_BIN=/usr/bin/git bash "$HELPER" fast-forward-current --repo "$REPO" --branch main --issue 28032 --confirm FAST_FORWARD_CANONICAL_BRANCH >/dev/null 2>&1; then
	printf 'FAIL current-branch fast-forward ignored the expected branch mismatch\n'
	exit 1
elif [[ "$(/usr/bin/git -C "$REPO" branch --show-current)" == "develop" ]] &&
	[[ "$(/usr/bin/git -C "$REPO" rev-parse HEAD)" == "$develop_local_tip" ]]; then
	printf 'PASS current-branch fast-forward refuses an expected branch mismatch\n'
else
	printf 'FAIL expected branch mismatch changed canonical state\n'
	exit 1
fi

printf 'dirty\n' >"${REPO}/DIRTY.md"
if AIDEVOPS_REAL_GIT_BIN=/usr/bin/git bash "$HELPER" fast-forward-current --repo "$REPO" --branch develop --issue 28032 --confirm FAST_FORWARD_CANONICAL_BRANCH >/dev/null 2>&1; then
	printf 'FAIL current-branch fast-forward accepted a dirty canonical worktree\n'
	exit 1
fi
rm "${REPO}/DIRTY.md"
printf 'PASS current-branch fast-forward refuses a dirty canonical worktree\n'

/usr/bin/git -C "$REPO" switch -q --detach
if AIDEVOPS_REAL_GIT_BIN=/usr/bin/git bash "$HELPER" fast-forward-current --repo "$REPO" --branch develop --issue 28032 --confirm FAST_FORWARD_CANONICAL_BRANCH >/dev/null 2>&1; then
	printf 'FAIL current-branch fast-forward accepted a detached canonical worktree\n'
	exit 1
fi
/usr/bin/git -C "$REPO" switch -q develop
printf 'PASS current-branch fast-forward refuses a detached canonical worktree\n'

printf 'local develop divergence\n' >>"${REPO}/README.md"
/usr/bin/git -C "$REPO" commit -q -am 'local develop divergence'
develop_local_tip=$(/usr/bin/git -C "$REPO" rev-parse HEAD)
printf 'remote develop divergence\n' >>"${UPDATER}/README.md"
/usr/bin/git -C "$UPDATER" commit -q -am 'remote develop divergence'
/usr/bin/git -C "$UPDATER" push -q origin develop
if AIDEVOPS_REAL_GIT_BIN=/usr/bin/git bash "$HELPER" fast-forward-current --repo "$REPO" --branch develop --issue 28032 --confirm FAST_FORWARD_CANONICAL_BRANCH >/dev/null 2>&1; then
	printf 'FAIL current-branch fast-forward accepted divergence\n'
	exit 1
elif [[ "$(/usr/bin/git -C "$REPO" branch --show-current)" == "develop" ]] &&
	[[ "$(/usr/bin/git -C "$REPO" rev-parse HEAD)" == "$develop_local_tip" ]]; then
	printf 'PASS current-branch fast-forward refuses divergence without changing refs\n'
else
	printf 'FAIL divergence refusal changed current branch or local tip\n'
	exit 1
fi
/usr/bin/git -C "$UPDATER" switch -q main

unset AIDEVOPS_REPOS_CONFIG
/usr/bin/git -C "$REPO" switch -q safety/test
/usr/bin/git -C "$REPO" worktree add -q "$OCCUPIED" main
printf 'local divergence\n' >>"${OCCUPIED}/README.md"
/usr/bin/git -C "$OCCUPIED" commit -q -am 'local divergence'
/usr/bin/git -C "$REPO" worktree remove "$OCCUPIED"
local_tip=$(/usr/bin/git -C "$REPO" rev-parse main)
printf 'remote divergence\n' >>"${UPDATER}/README.md"
/usr/bin/git -C "$UPDATER" commit -q -am 'remote divergence'
/usr/bin/git -C "$UPDATER" push -q origin main
preservation_ref="refs/aidevops/canonical-recovery/issue-27014/${local_tip}"
remote_tip=$(/usr/bin/git -C "$REMOTE" rev-parse refs/heads/main)
if AIDEVOPS_REAL_GIT_BIN=/usr/bin/git bash "$HELPER" restore-default --repo "$REPO" --issue 27014 --confirm RESTORE_CANONICAL_DEFAULT >/dev/null &&
	[[ "$(/usr/bin/git -C "$REPO" branch --show-current)" == "main" ]] &&
	[[ "$(/usr/bin/git -C "$REPO" rev-parse main)" == "$remote_tip" ]] &&
	[[ "$(/usr/bin/git -C "$REPO" rev-parse "$preservation_ref")" == "$local_tip" ]] &&
	/usr/bin/git -C "$REPO" merge-base --is-ancestor "$local_tip" "$preservation_ref"; then
	printf 'PASS recovery preserves divergent tip and restores exact origin default\n'
else
	printf 'FAIL divergent recovery did not preserve local tip or restore origin\n'
	exit 1
fi

STALE_REPO="${ROOT}/stale-repo"
STALE_REMOTE="${ROOT}/stale-remote.git"
STALE_RECOVERY="${ROOT}/stale-recovery"
mkdir -p "$STALE_REPO"
/usr/bin/git init -q --bare "$STALE_REMOTE"
/usr/bin/git -C "$STALE_REPO" init -q -b main
/usr/bin/git -C "$STALE_REPO" config user.name Test
/usr/bin/git -C "$STALE_REPO" config user.email test@example.invalid
/usr/bin/git -C "$STALE_REPO" config commit.gpgsign false
printf 'stale seed\n' >"${STALE_REPO}/README.md"
/usr/bin/git -C "$STALE_REPO" add README.md
/usr/bin/git -C "$STALE_REPO" commit -q -m seed
/usr/bin/git -C "$STALE_REPO" remote add origin "$STALE_REMOTE"
/usr/bin/git -C "$STALE_REPO" push -q -u origin main
/usr/bin/git -C "$STALE_REMOTE" symbolic-ref HEAD refs/heads/main
/usr/bin/git -C "$STALE_REPO" remote set-head origin main
stale_tip=$(/usr/bin/git -C "$STALE_REPO" rev-parse HEAD)
/usr/bin/git -C "$STALE_REPO" switch -q --detach "$stale_tip"
stale_metadata="${STALE_REPO}/.git/rebase-merge"
mkdir "$stale_metadata"
printf 'refs/heads/main\n' >"${stale_metadata}/head-name"
printf '%s\n' "$stale_tip" >"${stale_metadata}/onto"
printf '%s\n' "$stale_tip" >"${stale_metadata}/orig-head"
: >"${stale_metadata}/git-rebase-todo"
printf 'pick %s seed\n' "$stale_tip" >"${stale_metadata}/done"
printf '1\n' >"${stale_metadata}/msgnum"
printf '1\n' >"${stale_metadata}/end"
stale_index_tree=$(/usr/bin/git -C "$STALE_REPO" write-tree)
stale_output=""
if stale_output=$(AIDEVOPS_CANONICAL_RECOVERY_ROOT="$STALE_RECOVERY" AIDEVOPS_REAL_GIT_BIN=/usr/bin/git \
	bash "$HELPER" clear-stale-rebase --repo "$STALE_REPO" --issue 28503 \
	--confirm CLEAR_CONVERGED_STALE_REBASE) &&
	[[ "$stale_output" == *"CLEARED_CONVERGED_STALE_REBASE=true"* ]] &&
	[[ ! -e "$stale_metadata" ]] &&
	[[ "$(/usr/bin/git -C "$STALE_REPO" rev-parse HEAD)" == "$stale_tip" ]] &&
	[[ "$(/usr/bin/git -C "$STALE_REPO" rev-parse main)" == "$stale_tip" ]] &&
	[[ "$(/usr/bin/git -C "$STALE_REPO" write-tree)" == "$stale_index_tree" ]] &&
	[[ -z "$(/usr/bin/git -C "$STALE_REPO" status --porcelain)" ]] &&
	[[ "$(/usr/bin/git -C "$STALE_REPO" rev-parse "refs/aidevops/canonical-recovery/issue-28503/stale-rebase/${stale_tip}")" == "$stale_tip" ]] &&
	AIDEVOPS_REAL_GIT_BIN=/usr/bin/git bash "$HELPER" restore-default --repo "$STALE_REPO" --issue 28503 --confirm RESTORE_CANONICAL_DEFAULT >/dev/null &&
	[[ "$(/usr/bin/git -C "$STALE_REPO" branch --show-current)" == "main" ]]; then
	printf 'PASS converged stale rebase is preserved, cleared without tree changes, and restore-default succeeds\n'
else
	printf 'FAIL converged stale rebase recovery did not preserve invariant state\n'
	exit 1
fi

cp -R "${STALE_RECOVERY}/28503/stale-rebase-${stale_tip}" "$stale_metadata"
printf 'pick %s still-active\n' "$stale_tip" >"${stale_metadata}/git-rebase-todo"
if AIDEVOPS_CANONICAL_RECOVERY_ROOT="$STALE_RECOVERY" AIDEVOPS_REAL_GIT_BIN=/usr/bin/git \
	bash "$HELPER" clear-stale-rebase --repo "$STALE_REPO" --issue 28503 \
	--confirm CLEAR_CONVERGED_STALE_REBASE >/dev/null 2>&1; then
	printf 'FAIL stale rebase cleanup accepted active todo entries\n'
	exit 1
elif [[ -s "${stale_metadata}/git-rebase-todo" ]] &&
	[[ "$(/usr/bin/git -C "$STALE_REPO" rev-parse HEAD)" == "$stale_tip" ]]; then
	printf 'PASS stale rebase cleanup rejects active state without mutation\n'
else
	printf 'FAIL active stale rebase refusal changed repository state\n'
	exit 1
fi
rm -rf "$stale_metadata"
cp -R "${STALE_RECOVERY}/28503/stale-rebase-${stale_tip}" "$stale_metadata"
stale_race_hook="${ROOT}/mutate-stale-rebase.sh"
# Generated hook expands its own positional argument.
# shellcheck disable=SC2016
printf '%s\n' '#!/usr/bin/env bash' 'printf "2\n" >"$2/msgnum"' >"$stale_race_hook"
chmod +x "$stale_race_hook"
if AIDEVOPS_CANONICAL_BEFORE_REBASE_CLEANUP_HOOK="$stale_race_hook" \
	AIDEVOPS_CANONICAL_RECOVERY_ROOT="$STALE_RECOVERY" AIDEVOPS_REAL_GIT_BIN=/usr/bin/git \
	bash "$HELPER" clear-stale-rebase --repo "$STALE_REPO" --issue 28503 \
	--confirm CLEAR_CONVERGED_STALE_REBASE >/dev/null 2>&1; then
	printf 'FAIL stale rebase cleanup accepted concurrently changing metadata\n'
	exit 1
elif [[ -d "$stale_metadata" ]] && [[ "$(<"${stale_metadata}/msgnum")" == "2" ]] &&
	[[ "$(/usr/bin/git -C "$STALE_REPO" rev-parse HEAD)" == "$stale_tip" ]]; then
	printf 'PASS stale rebase cleanup rejects concurrent metadata changes without cleanup\n'
else
	printf 'FAIL concurrent stale rebase refusal removed or changed canonical state\n'
	exit 1
fi

age_rebase_state_fixture() {
	local metadata_path="$1"
	local rebase_head_path="$2"
	python3 - "$metadata_path" "$rebase_head_path" <<'PY'
import os
import sys
import time

old = time.time() - 172800
for root_path in sys.argv[1:]:
    paths = [root_path]
    if os.path.isdir(root_path):
        for root, dirs, files in os.walk(root_path):
            paths.extend(os.path.join(root, name) for name in dirs)
            paths.extend(os.path.join(root, name) for name in files)
    for path in paths:
        os.utime(path, (old, old))
PY
	return 0
}

rebase_fixture_snapshot() {
	local repo="$1"
	local metadata_path="$2"
	local rebase_head_path="$3"
	local content_fingerprint=""
	local current_head_ref=""
	content_fingerprint=$(
		python3 - "$repo" "$metadata_path" "$rebase_head_path" <<'PY'
import hashlib
import os
import stat
import sys

repo, metadata_path, rebase_head_path = sys.argv[1:]
digest = hashlib.sha256()


def add_field(value):
    data = value.encode("utf-8", "surrogateescape")
    digest.update(len(data).to_bytes(8, "big"))
    digest.update(data)


def add_file(path, label):
    entry_stat = os.lstat(path)
    if not stat.S_ISREG(entry_stat.st_mode):
        raise RuntimeError("fixture contains a non-regular file")
    digest.update(b"F")
    add_field(label)
    digest.update(entry_stat.st_size.to_bytes(8, "big"))
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(65536), b""):
            digest.update(chunk)


def add_tree(root, label, excluded_roots=()):
    for current, dirs, files in os.walk(root):
        if current == root:
            dirs[:] = sorted(name for name in dirs if name not in excluded_roots)
        else:
            dirs.sort()
        files.sort()
        relative_root = os.path.relpath(current, root)
        for name in files:
            relative = name if relative_root == "." else os.path.join(relative_root, name)
            add_file(os.path.join(current, name), os.path.join(label, relative))


add_tree(repo, "worktree", (".git",))
add_tree(metadata_path, "rebase-merge")
add_file(rebase_head_path, "REBASE_HEAD")
print(digest.hexdigest())
PY
	) || return 1
	current_head_ref=$(/usr/bin/git -C "$repo" symbolic-ref --quiet HEAD 2>/dev/null || true)
	printf '%s\n%s\n%s\n%s\n%s\n%s\n' \
		"$content_fingerprint" \
		"$(/usr/bin/git -C "$repo" rev-parse HEAD)" \
		"${current_head_ref:-detached}" \
		"$(/usr/bin/git -C "$repo" rev-parse main)" \
		"$(/usr/bin/git -C "$repo" rev-parse origin/main)" \
		"$(/usr/bin/git -C "$repo" write-tree)"
	return 0
}

ABANDONED_REPO="${ROOT}/abandoned-repo"
ABANDONED_REMOTE="${ROOT}/abandoned-remote.git"
ABANDONED_UPDATER="${ROOT}/abandoned-updater"
ABANDONED_RECOVERY="${ROOT}/abandoned-recovery"
mkdir -p "$ABANDONED_REPO"
/usr/bin/git init -q --bare "$ABANDONED_REMOTE"
/usr/bin/git -C "$ABANDONED_REPO" init -q -b main
/usr/bin/git -C "$ABANDONED_REPO" config user.name Test
/usr/bin/git -C "$ABANDONED_REPO" config user.email test@example.invalid
/usr/bin/git -C "$ABANDONED_REPO" config commit.gpgsign false
printf 'abandoned seed\n' >"${ABANDONED_REPO}/README.md"
/usr/bin/git -C "$ABANDONED_REPO" add README.md
/usr/bin/git -C "$ABANDONED_REPO" commit -q -m seed
/usr/bin/git -C "$ABANDONED_REPO" remote add origin "$ABANDONED_REMOTE"
/usr/bin/git -C "$ABANDONED_REPO" push -q -u origin main
/usr/bin/git -C "$ABANDONED_REMOTE" symbolic-ref HEAD refs/heads/main
/usr/bin/git -C "$ABANDONED_REPO" remote set-head origin main
abandoned_local_tip=$(/usr/bin/git -C "$ABANDONED_REPO" rev-parse main)
/usr/bin/git -C "$ABANDONED_REPO" switch -q -c abandoned-sequence
printf 'stopped sequence\n' >"${ABANDONED_REPO}/sequence.txt"
/usr/bin/git -C "$ABANDONED_REPO" add sequence.txt
/usr/bin/git -C "$ABANDONED_REPO" commit -q -m 'stopped sequence'
abandoned_stopped_sha=$(/usr/bin/git -C "$ABANDONED_REPO" rev-parse HEAD)
printf 'remaining sequence\n' >"${ABANDONED_REPO}/remaining.txt"
/usr/bin/git -C "$ABANDONED_REPO" add remaining.txt
/usr/bin/git -C "$ABANDONED_REPO" commit -q -m 'remaining sequence'
abandoned_todo_sha=$(/usr/bin/git -C "$ABANDONED_REPO" rev-parse HEAD)
abandoned_todo_abbrev=$(/usr/bin/git -C "$ABANDONED_REPO" rev-parse --short "$abandoned_todo_sha")
/usr/bin/git -C "$ABANDONED_REPO" switch -q main
/usr/bin/git clone -q "$ABANDONED_REMOTE" "$ABANDONED_UPDATER"
/usr/bin/git -C "$ABANDONED_UPDATER" config user.name Test
/usr/bin/git -C "$ABANDONED_UPDATER" config user.email test@example.invalid
printf 'remote recovery tip\n' >>"${ABANDONED_UPDATER}/README.md"
/usr/bin/git -C "$ABANDONED_UPDATER" commit -q -am 'remote recovery tip'
/usr/bin/git -C "$ABANDONED_UPDATER" push -q origin main
/usr/bin/git -C "$ABANDONED_REPO" fetch -q origin main
abandoned_target_sha=$(/usr/bin/git -C "$ABANDONED_REPO" rev-parse origin/main)
/usr/bin/git -C "$ABANDONED_REPO" switch -q --detach "$abandoned_target_sha"
abandoned_index_tree=$(/usr/bin/git -C "$ABANDONED_REPO" write-tree)
abandoned_rewritten_sha=$(printf 'rewritten sequence\n' |
	/usr/bin/git -C "$ABANDONED_REPO" commit-tree "$abandoned_index_tree" -p "$abandoned_local_tip")
abandoned_amend_sha=$(printf 'amend sequence\n' |
	/usr/bin/git -C "$ABANDONED_REPO" commit-tree "$abandoned_index_tree" -p "$abandoned_local_tip")
abandoned_squash_sha=$(printf 'squash sequence\n' |
	/usr/bin/git -C "$ABANDONED_REPO" commit-tree "$abandoned_index_tree" -p "$abandoned_local_tip")
abandoned_update_ref_sha=$(printf 'update-ref sequence\n' |
	/usr/bin/git -C "$ABANDONED_REPO" commit-tree "$abandoned_index_tree" -p "$abandoned_local_tip")
abandoned_fixup_sha=$(printf 'current fixup sequence\n' |
	/usr/bin/git -C "$ABANDONED_REPO" commit-tree "$abandoned_index_tree" -p "$abandoned_local_tip")
abandoned_metadata="${ABANDONED_REPO}/.git/rebase-merge"
abandoned_rebase_head="${ABANDONED_REPO}/.git/REBASE_HEAD"
mkdir "$abandoned_metadata"
printf 'refs/heads/main\n' >"${abandoned_metadata}/head-name"
printf '%s\n' "$abandoned_local_tip" >"${abandoned_metadata}/onto"
printf '%s\n' "$abandoned_stopped_sha" >"${abandoned_metadata}/orig-head"
printf 'pick %s remaining-sequence\n' "$abandoned_todo_abbrev" >"${abandoned_metadata}/git-rebase-todo"
cp "${abandoned_metadata}/git-rebase-todo" "${abandoned_metadata}/git-rebase-todo.backup"
printf 'pick %s stopped-sequence\n' "$abandoned_stopped_sha" >"${abandoned_metadata}/done"
printf '%s %s\n' "$abandoned_stopped_sha" "$abandoned_rewritten_sha" >"${abandoned_metadata}/rewritten-list"
printf '%s\n' "$abandoned_amend_sha" >"${abandoned_metadata}/amend"
printf '%s\n' "$abandoned_squash_sha" >"${abandoned_metadata}/squash-onto"
printf 'refs/heads/example\n%s\n%s\n' "$abandoned_local_tip" "$abandoned_update_ref_sha" >"${abandoned_metadata}/update-refs"
printf 'fixup %s subject dead cafe\n' "$abandoned_fixup_sha" >"${abandoned_metadata}/current-fixups"
printf 'hidden marker\n' >"${abandoned_metadata}/.hidden-marker"
printf '1\n' >"${abandoned_metadata}/msgnum"
printf '2\n' >"${abandoned_metadata}/end"
printf '%s\n' "$abandoned_stopped_sha" >"${abandoned_metadata}/stopped-sha"
printf '%s\n' "$abandoned_stopped_sha" >"$abandoned_rebase_head"

fresh_abandoned_snapshot=$(rebase_fixture_snapshot "$ABANDONED_REPO" "$abandoned_metadata" "$abandoned_rebase_head")
if AIDEVOPS_CANONICAL_RECOVERY_ROOT="$ABANDONED_RECOVERY" AIDEVOPS_REAL_GIT_BIN=/usr/bin/git \
	bash "$HELPER" clear-abandoned-rebase --repo "$ABANDONED_REPO" --issue 28549 \
	--confirm CLEAR_ABANDONED_STALE_REBASE >/dev/null 2>&1; then
	printf 'FAIL abandoned rebase cleanup accepted fresh active metadata\n'
	exit 1
elif [[ -d "$abandoned_metadata" ]] && [[ -f "$abandoned_rebase_head" ]] &&
	[[ "$(rebase_fixture_snapshot "$ABANDONED_REPO" "$abandoned_metadata" "$abandoned_rebase_head")" == "$fresh_abandoned_snapshot" ]]; then
	printf 'PASS abandoned rebase cleanup rejects fresh active metadata without mutation\n'
else
	printf 'FAIL fresh abandoned rebase refusal changed repository state\n'
	exit 1
fi

age_rebase_state_fixture "$abandoned_metadata" "$abandoned_rebase_head"

/usr/bin/git -C "$ABANDONED_REPO" update-ref refs/heads/ambiguous-recovery "$abandoned_target_sha"
/usr/bin/git -C "$ABANDONED_REPO" symbolic-ref HEAD refs/heads/ambiguous-recovery
attached_abandoned_snapshot=$(rebase_fixture_snapshot "$ABANDONED_REPO" "$abandoned_metadata" "$abandoned_rebase_head")
if AIDEVOPS_CANONICAL_RECOVERY_ROOT="$ABANDONED_RECOVERY" AIDEVOPS_REAL_GIT_BIN=/usr/bin/git \
	bash "$HELPER" clear-abandoned-rebase --repo "$ABANDONED_REPO" --issue 28549 \
	--confirm CLEAR_ABANDONED_STALE_REBASE >/dev/null 2>&1; then
	printf 'FAIL abandoned rebase cleanup accepted an attached non-default HEAD\n'
	exit 1
elif [[ -d "$abandoned_metadata" ]] &&
	[[ "$(rebase_fixture_snapshot "$ABANDONED_REPO" "$abandoned_metadata" "$abandoned_rebase_head")" == "$attached_abandoned_snapshot" ]]; then
	printf 'PASS abandoned rebase cleanup rejects ambiguous attached HEAD state\n'
else
	printf 'FAIL attached-HEAD refusal changed abandoned rebase state\n'
	exit 1
fi
/usr/bin/git -C "$ABANDONED_REPO" update-ref --no-deref HEAD "$abandoned_target_sha"
/usr/bin/git -C "$ABANDONED_REPO" update-ref -d refs/heads/ambiguous-recovery "$abandoned_target_sha"

printf '%s\n' "$abandoned_target_sha" >"$abandoned_rebase_head"
age_rebase_state_fixture "$abandoned_metadata" "$abandoned_rebase_head"
malformed_abandoned_snapshot=$(rebase_fixture_snapshot "$ABANDONED_REPO" "$abandoned_metadata" "$abandoned_rebase_head")
if AIDEVOPS_CANONICAL_RECOVERY_ROOT="$ABANDONED_RECOVERY" AIDEVOPS_REAL_GIT_BIN=/usr/bin/git \
	bash "$HELPER" clear-abandoned-rebase --repo "$ABANDONED_REPO" --issue 28549 \
	--confirm CLEAR_ABANDONED_STALE_REBASE >/dev/null 2>&1; then
	printf 'FAIL abandoned rebase cleanup accepted mismatched stopped commit metadata\n'
	exit 1
elif [[ -d "$abandoned_metadata" ]] &&
	[[ "$(rebase_fixture_snapshot "$ABANDONED_REPO" "$abandoned_metadata" "$abandoned_rebase_head")" == "$malformed_abandoned_snapshot" ]]; then
	printf 'PASS abandoned rebase cleanup rejects malformed stopped commit metadata\n'
else
	printf 'FAIL malformed-metadata refusal changed abandoned rebase state\n'
	exit 1
fi
printf '%s\n' "$abandoned_stopped_sha" >"$abandoned_rebase_head"
age_rebase_state_fixture "$abandoned_metadata" "$abandoned_rebase_head"

abandoned_output=""
abandoned_output=$(AIDEVOPS_CANONICAL_RECOVERY_ROOT="$ABANDONED_RECOVERY" AIDEVOPS_REAL_GIT_BIN=/usr/bin/git \
	bash "$HELPER" clear-abandoned-rebase --repo "$ABANDONED_REPO" --issue 28549 \
	--confirm CLEAR_ABANDONED_STALE_REBASE)
abandoned_preserved_dir="${ABANDONED_RECOVERY}/28549/abandoned-rebase-${abandoned_target_sha}"
abandoned_ref_base="refs/aidevops/canonical-recovery/issue-28549/abandoned-rebase"
if [[ "$abandoned_output" == *"CLEARED_ABANDONED_STALE_REBASE=true"* ]] &&
	[[ ! -e "$abandoned_metadata" && ! -e "$abandoned_rebase_head" ]] &&
	[[ -d "${abandoned_preserved_dir}/rebase-merge" && -f "${abandoned_preserved_dir}/REBASE_HEAD" ]] &&
	[[ "$(<"${abandoned_preserved_dir}/rebase-merge/.hidden-marker")" == "hidden marker" ]] &&
	[[ "$(/usr/bin/git -C "$ABANDONED_REPO" rev-parse HEAD)" == "$abandoned_target_sha" ]] &&
	[[ "$(/usr/bin/git -C "$ABANDONED_REPO" rev-parse main)" == "$abandoned_local_tip" ]] &&
	[[ "$(/usr/bin/git -C "$ABANDONED_REPO" write-tree)" == "$abandoned_index_tree" ]] &&
	[[ -z "$(/usr/bin/git -C "$ABANDONED_REPO" status --porcelain)" ]] &&
	[[ "$(/usr/bin/git -C "$ABANDONED_REPO" rev-parse "${abandoned_ref_base}/${abandoned_local_tip}")" == "$abandoned_local_tip" ]] &&
	[[ "$(/usr/bin/git -C "$ABANDONED_REPO" rev-parse "${abandoned_ref_base}/${abandoned_target_sha}")" == "$abandoned_target_sha" ]] &&
	[[ "$(/usr/bin/git -C "$ABANDONED_REPO" rev-parse "${abandoned_ref_base}/${abandoned_stopped_sha}")" == "$abandoned_stopped_sha" ]] &&
	[[ "$(/usr/bin/git -C "$ABANDONED_REPO" rev-parse "${abandoned_ref_base}/${abandoned_todo_sha}")" == "$abandoned_todo_sha" ]] &&
	[[ "$(/usr/bin/git -C "$ABANDONED_REPO" rev-parse "${abandoned_ref_base}/${abandoned_rewritten_sha}")" == "$abandoned_rewritten_sha" ]] &&
	[[ "$(/usr/bin/git -C "$ABANDONED_REPO" rev-parse "${abandoned_ref_base}/${abandoned_amend_sha}")" == "$abandoned_amend_sha" ]] &&
	[[ "$(/usr/bin/git -C "$ABANDONED_REPO" rev-parse "${abandoned_ref_base}/${abandoned_squash_sha}")" == "$abandoned_squash_sha" ]] &&
	[[ "$(/usr/bin/git -C "$ABANDONED_REPO" rev-parse "${abandoned_ref_base}/${abandoned_update_ref_sha}")" == "$abandoned_update_ref_sha" ]] &&
	[[ "$(/usr/bin/git -C "$ABANDONED_REPO" rev-parse "${abandoned_ref_base}/${abandoned_fixup_sha}")" == "$abandoned_fixup_sha" ]] &&
	grep -q 'Abandoned stale rebase cleanup authorized' "$HOME/.aidevops/logs/canonical-recovery-audit.jsonl" &&
	AIDEVOPS_REAL_GIT_BIN=/usr/bin/git bash "$HELPER" restore-default --repo "$ABANDONED_REPO" --issue 28549 --confirm RESTORE_CANONICAL_DEFAULT >/dev/null &&
	[[ "$(/usr/bin/git -C "$ABANDONED_REPO" branch --show-current)" == "main" ]] &&
	[[ "$(/usr/bin/git -C "$ABANDONED_REPO" rev-parse HEAD)" == "$abandoned_target_sha" ]]; then
	printf 'PASS abandoned active rebase is preserved, cleared without tree changes, and restored\n'
else
	printf 'FAIL abandoned active rebase recovery violated preservation invariants\n'
	exit 1
fi

/usr/bin/git -C "$ABANDONED_REPO" switch -q --detach "$abandoned_target_sha"
mkdir "$abandoned_metadata"
cp -R "${abandoned_preserved_dir}/rebase-merge/." "$abandoned_metadata/"
cp "${abandoned_preserved_dir}/REBASE_HEAD" "$abandoned_rebase_head"
age_rebase_state_fixture "$abandoned_metadata" "$abandoned_rebase_head"
printf 'dirty\n' >"${ABANDONED_REPO}/DIRTY.md"
dirty_abandoned_snapshot=$(rebase_fixture_snapshot "$ABANDONED_REPO" "$abandoned_metadata" "$abandoned_rebase_head")
if AIDEVOPS_CANONICAL_RECOVERY_ROOT="$ABANDONED_RECOVERY" AIDEVOPS_REAL_GIT_BIN=/usr/bin/git \
	bash "$HELPER" clear-abandoned-rebase --repo "$ABANDONED_REPO" --issue 28549 \
	--confirm CLEAR_ABANDONED_STALE_REBASE >/dev/null 2>&1; then
	printf 'FAIL abandoned rebase cleanup accepted a dirty canonical worktree\n'
	exit 1
elif [[ "$(rebase_fixture_snapshot "$ABANDONED_REPO" "$abandoned_metadata" "$abandoned_rebase_head")" != "$dirty_abandoned_snapshot" ]]; then
	printf 'FAIL dirty-worktree refusal changed abandoned rebase state\n'
	exit 1
fi
rm "${ABANDONED_REPO}/DIRTY.md"
printf 'PASS abandoned rebase cleanup rejects a dirty canonical worktree\n'

abandoned_diverged_tip=$(printf 'local divergence\n' |
	/usr/bin/git -C "$ABANDONED_REPO" commit-tree "$abandoned_index_tree" -p "$abandoned_target_sha")
/usr/bin/git -C "$ABANDONED_REPO" update-ref refs/heads/main "$abandoned_diverged_tip" "$abandoned_target_sha"
diverged_abandoned_snapshot=$(rebase_fixture_snapshot "$ABANDONED_REPO" "$abandoned_metadata" "$abandoned_rebase_head")
if AIDEVOPS_CANONICAL_RECOVERY_ROOT="$ABANDONED_RECOVERY" AIDEVOPS_REAL_GIT_BIN=/usr/bin/git \
	bash "$HELPER" clear-abandoned-rebase --repo "$ABANDONED_REPO" --issue 28549 \
	--confirm CLEAR_ABANDONED_STALE_REBASE >/dev/null 2>&1; then
	printf 'FAIL abandoned rebase cleanup accepted local default divergence\n'
	exit 1
elif [[ -d "$abandoned_metadata" ]] &&
	[[ "$(rebase_fixture_snapshot "$ABANDONED_REPO" "$abandoned_metadata" "$abandoned_rebase_head")" == "$diverged_abandoned_snapshot" ]]; then
	printf 'PASS abandoned rebase cleanup rejects local default divergence without mutation\n'
else
	printf 'FAIL divergence refusal changed abandoned rebase state\n'
	exit 1
fi
/usr/bin/git -C "$ABANDONED_REPO" update-ref refs/heads/main "$abandoned_target_sha" "$abandoned_diverged_tip"

abandoned_race_hook="${ROOT}/mutate-abandoned-rebase.sh"
# Generated hook expands its own positional argument.
# shellcheck disable=SC2016
printf '%s\n' '#!/usr/bin/env bash' 'printf "2\n" >"$2/msgnum"' >"$abandoned_race_hook"
chmod +x "$abandoned_race_hook"
if AIDEVOPS_CANONICAL_BEFORE_REBASE_CLEANUP_HOOK="$abandoned_race_hook" \
	AIDEVOPS_CANONICAL_RECOVERY_ROOT="$ABANDONED_RECOVERY" AIDEVOPS_REAL_GIT_BIN=/usr/bin/git \
	bash "$HELPER" clear-abandoned-rebase --repo "$ABANDONED_REPO" --issue 28549 \
	--confirm CLEAR_ABANDONED_STALE_REBASE >/dev/null 2>&1; then
	printf 'FAIL abandoned rebase cleanup accepted concurrently changing metadata\n'
	exit 1
elif [[ -d "$abandoned_metadata" ]] && [[ "$(<"${abandoned_metadata}/msgnum")" == "2" ]] &&
	[[ "$(/usr/bin/git -C "$ABANDONED_REPO" rev-parse HEAD)" == "$abandoned_target_sha" ]]; then
	printf 'PASS abandoned rebase cleanup rejects concurrent metadata changes without cleanup\n'
else
	printf 'FAIL concurrent abandoned rebase refusal changed repository state\n'
	exit 1
fi

printf '1\n' >"${abandoned_metadata}/msgnum"
age_rebase_state_fixture "$abandoned_metadata" "$abandoned_rebase_head"
abandoned_quarantine_race_hook="${ROOT}/mutate-quarantined-abandoned-rebase.sh"
# Generated hook expands its own positional argument.
# shellcheck disable=SC2016
printf '%s\n' '#!/usr/bin/env bash' 'printf "changed after validation\n" >"$2/.hidden-marker"' \
	>"$abandoned_quarantine_race_hook"
chmod +x "$abandoned_quarantine_race_hook"
if AIDEVOPS_CANONICAL_BEFORE_REBASE_QUARANTINE_HOOK="$abandoned_quarantine_race_hook" \
	AIDEVOPS_CANONICAL_RECOVERY_ROOT="$ABANDONED_RECOVERY" AIDEVOPS_REAL_GIT_BIN=/usr/bin/git \
	bash "$HELPER" clear-abandoned-rebase --repo "$ABANDONED_REPO" --issue 28549 \
	--confirm CLEAR_ABANDONED_STALE_REBASE >/dev/null 2>&1; then
	printf 'FAIL abandoned rebase cleanup accepted a post-validation metadata race\n'
	exit 1
fi
abandoned_quarantine_count=0
for abandoned_quarantine_path in "${abandoned_metadata}.aidevops-quarantine."* \
	"${abandoned_rebase_head}.aidevops-quarantine."*; do
	[[ -e "$abandoned_quarantine_path" ]] || continue
	abandoned_quarantine_count=$((abandoned_quarantine_count + 1))
done
if [[ -d "$abandoned_metadata" && -f "$abandoned_rebase_head" ]] &&
	[[ "$(<"${abandoned_metadata}/.hidden-marker")" == "changed after validation" ]] &&
	[[ "$abandoned_quarantine_count" -eq 0 ]] &&
	[[ "$(/usr/bin/git -C "$ABANDONED_REPO" rev-parse HEAD)" == "$abandoned_target_sha" ]] &&
	[[ "$(/usr/bin/git -C "$ABANDONED_REPO" rev-parse main)" == "$abandoned_target_sha" ]] &&
	[[ "$(/usr/bin/git -C "$ABANDONED_REPO" rev-parse origin/main)" == "$abandoned_target_sha" ]] &&
	[[ "$(/usr/bin/git -C "$ABANDONED_REPO" write-tree)" == "$abandoned_index_tree" ]] &&
	[[ -z "$(/usr/bin/git -C "$ABANDONED_REPO" status --porcelain)" ]]; then
	printf 'PASS post-validation metadata races are quarantined, detected, and restored\n'
else
	printf 'FAIL post-validation race recovery lost or changed canonical state\n'
	exit 1
fi

printf 'hidden marker\n' >"${abandoned_metadata}/.hidden-marker"
age_rebase_state_fixture "$abandoned_metadata" "$abandoned_rebase_head"
abandoned_inter_move_hook="${ROOT}/replace-rebase-head-before-directory-quarantine.sh"
# Generated hook expands its own positional arguments.
# shellcheck disable=SC2016
printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\n" "$4" >"$3"' >"$abandoned_inter_move_hook"
chmod +x "$abandoned_inter_move_hook"
if AIDEVOPS_CANONICAL_BEFORE_REBASE_DIRECTORY_QUARANTINE_HOOK="$abandoned_inter_move_hook" \
	AIDEVOPS_CANONICAL_RECOVERY_ROOT="$ABANDONED_RECOVERY" AIDEVOPS_REAL_GIT_BIN=/usr/bin/git \
	bash "$HELPER" clear-abandoned-rebase --repo "$ABANDONED_REPO" --issue 28549 \
	--confirm CLEAR_ABANDONED_STALE_REBASE >/dev/null 2>&1; then
	printf 'FAIL abandoned rebase cleanup accepted a replacement REBASE_HEAD race\n'
	exit 1
fi
abandoned_quarantine_count=0
for abandoned_quarantine_path in "${abandoned_metadata}.aidevops-quarantine."* \
	"${abandoned_rebase_head}.aidevops-quarantine."*; do
	[[ -e "$abandoned_quarantine_path" ]] || continue
	abandoned_quarantine_count=$((abandoned_quarantine_count + 1))
done
if [[ -d "$abandoned_metadata" && -f "$abandoned_rebase_head" ]] &&
	[[ "$(<"$abandoned_rebase_head")" == "$abandoned_target_sha" ]] &&
	[[ "$abandoned_quarantine_count" -eq 0 ]] &&
	[[ "$(/usr/bin/git -C "$ABANDONED_REPO" rev-parse HEAD)" == "$abandoned_target_sha" ]] &&
	[[ "$(/usr/bin/git -C "$ABANDONED_REPO" rev-parse main)" == "$abandoned_target_sha" ]] &&
	[[ "$(/usr/bin/git -C "$ABANDONED_REPO" rev-parse origin/main)" == "$abandoned_target_sha" ]] &&
	[[ "$(/usr/bin/git -C "$ABANDONED_REPO" write-tree)" == "$abandoned_index_tree" ]] &&
	[[ -z "$(/usr/bin/git -C "$ABANDONED_REPO" status --porcelain)" ]]; then
	printf 'PASS replacement REBASE_HEAD races are preserved without marker theft\n'
else
	printf 'FAIL replacement REBASE_HEAD race lost concurrent canonical state\n'
	exit 1
fi

SYNC_REPO="${ROOT}/sync-repo"
SYNC_REMOTE="${ROOT}/sync-remote.git"
SYNC_UPDATER="${ROOT}/sync-updater"
SYNC_BACKUPS="${ROOT}/sync-backups"
SYNC_REGISTRY_DIR="${ROOT}/sync-registry"
SYNC_REGISTRY_DB="${SYNC_REGISTRY_DIR}/worktree-registry.db"
DIRTY_HELPER="${SCRIPT_DIR}/dirty-worktree-backup-helper.sh"
mkdir -p "$SYNC_REPO" "$SYNC_REGISTRY_DIR"
/usr/bin/git init -q --bare "$SYNC_REMOTE"
/usr/bin/git -C "$SYNC_REPO" init -q -b develop
/usr/bin/git -C "$SYNC_REPO" config user.name Test
/usr/bin/git -C "$SYNC_REPO" config user.email test@example.invalid
/usr/bin/git -C "$SYNC_REPO" config commit.gpgsign false
printf 'sync seed\n' >"${SYNC_REPO}/README.md"
/usr/bin/git -C "$SYNC_REPO" add README.md
/usr/bin/git -C "$SYNC_REPO" commit -q -m seed
SYNC_URL="ssh://git@github.com:22/Example/Sync-Mirror.git"
/usr/bin/git -C "$SYNC_REPO" config "url.${SYNC_REMOTE}.insteadOf" "$SYNC_URL"
/usr/bin/git -C "$SYNC_REPO" remote add github "$SYNC_URL"
/usr/bin/git -C "$SYNC_REPO" push -q -u github develop
/usr/bin/git -C "$SYNC_REMOTE" symbolic-ref HEAD refs/heads/develop
/usr/bin/git -C "$SYNC_REPO" remote set-head github develop
/usr/bin/git clone -q "$SYNC_REMOTE" "$SYNC_UPDATER"
/usr/bin/git -C "$SYNC_UPDATER" config user.name Test
/usr/bin/git -C "$SYNC_UPDATER" config user.email test@example.invalid
export AIDEVOPS_REPOS_CONFIG="${ROOT}/sync-repos.json"
printf '{"initialized_repos":[{"slug":"example/sync-mirror","path":"%s","pr_base_branch":"develop"}]}\n' \
	"$SYNC_REPO" >"$AIDEVOPS_REPOS_CONFIG"

printf 'accidental local commit\n' >"${SYNC_REPO}/local-only.txt"
/usr/bin/git -C "$SYNC_REPO" add local-only.txt
/usr/bin/git -C "$SYNC_REPO" commit -q -m 'accidental local commit'
sync_local_tip=$(/usr/bin/git -C "$SYNC_REPO" rev-parse HEAD)
printf 'staged state\n' >"${SYNC_REPO}/staged.txt"
/usr/bin/git -C "$SYNC_REPO" add staged.txt
printf 'unstaged state\n' >>"${SYNC_REPO}/README.md"
mkdir -p "${SYNC_REPO}/todo/tasks"
printf 'untracked state\n' >"${SYNC_REPO}/todo/tasks/recovery.md"
mkdir -p "${SYNC_REPO}/local-state/runtime/nested"
printf 'runtime/\n' >"${SYNC_REPO}/local-state/.gitignore"
printf 'runtime metadata\n' >"${SYNC_REPO}/local-state/metadata.txt"
printf '\001runtime\000payload\377' >"${SYNC_REPO}/local-state/runtime/nested/payload.bin"
chmod 640 "${SYNC_REPO}/local-state/runtime/nested/payload.bin"
ln -s payload.bin "${SYNC_REPO}/local-state/runtime/nested/payload-link"

printf 'remote divergence\n' >"${SYNC_UPDATER}/remote-only.txt"
/usr/bin/git -C "$SYNC_UPDATER" add remote-only.txt
/usr/bin/git -C "$SYNC_UPDATER" commit -q -m 'remote divergence'
/usr/bin/git -C "$SYNC_UPDATER" push -q origin develop
sync_remote_tip=$(/usr/bin/git -C "$SYNC_REMOTE" rev-parse refs/heads/develop)

sqlite3 "$SYNC_REGISTRY_DB" "
CREATE TABLE worktree_owners (
  worktree_path TEXT PRIMARY KEY,
  branch TEXT,
  owner_pid INTEGER,
  owner_session TEXT DEFAULT '',
  owner_batch TEXT DEFAULT '',
  task_id TEXT DEFAULT '',
  owner_comm TEXT DEFAULT '',
  owner_dead_seen_at TEXT DEFAULT '',
  created_at TEXT DEFAULT ''
);
INSERT INTO worktree_owners (worktree_path, branch, owner_pid, owner_session)
VALUES ('${SYNC_REPO}', 'develop', $$, 'invalid-canonical-owner');
"

sync_failure_hook="${ROOT}/fail-before-sync-ref-update.sh"
printf '%s\n' '#!/usr/bin/env bash' 'exit 1' >"$sync_failure_hook"
chmod +x "$sync_failure_hook"
clean_failure_output=""
clean_failure_rc=0
clean_failure_output=$(AIDEVOPS_REAL_GIT_BIN=/usr/bin/git \
	AIDEVOPS_DIRTY_BACKUP_ROOT="$SYNC_BACKUPS" \
	WORKTREE_REGISTRY_DIR="$SYNC_REGISTRY_DIR" \
	WORKTREE_REGISTRY_DB="$SYNC_REGISTRY_DB" \
	AIDEVOPS_DIRTY_BACKUP_AFTER_REMOVE_HOOK="$sync_failure_hook" \
	bash "$HELPER" sync-mirror --repo "$SYNC_REPO" --issue 28065 \
	--confirm SYNCHRONIZE_CANONICAL_MIRROR 2>&1) || clean_failure_rc=$?
clean_failure_backup_id=""
while IFS= read -r clean_failure_line; do
	case "$clean_failure_line" in
	PRESERVED_BACKUP_ID=*) clean_failure_backup_id="${clean_failure_line#PRESERVED_BACKUP_ID=}" ;;
	esac
done <<<"$clean_failure_output"
if [[ "$clean_failure_rc" -ne 0 ]] && [[ -n "$clean_failure_backup_id" ]] &&
	[[ "$clean_failure_output" == *"RECOVER_CLEAN_COMMAND="* ]] &&
	[[ "$clean_failure_output" == *"pre-clean state was restored"* ]] &&
	AIDEVOPS_REAL_GIT_BIN=/usr/bin/git AIDEVOPS_DIRTY_BACKUP_ROOT="$SYNC_BACKUPS" \
		bash "$DIRTY_HELPER" matches --repo "$SYNC_REPO" --backup "$clean_failure_backup_id" >/dev/null &&
	[[ -f "${SYNC_REPO}/local-state/runtime/nested/payload.bin" ]] &&
	[[ "$(readlink "${SYNC_REPO}/local-state/runtime/nested/payload-link")" == "payload.bin" ]]; then
	printf 'PASS failed canonical clean restores ignored descendants and emits resumable recovery evidence\n'
else
	printf 'FAIL failed canonical clean did not restore the preserved pre-clean state\n'
	exit 1
fi

sync_output=""
sync_rc=0
sync_output=$(AIDEVOPS_REAL_GIT_BIN=/usr/bin/git \
	AIDEVOPS_DIRTY_BACKUP_ROOT="$SYNC_BACKUPS" \
	WORKTREE_REGISTRY_DIR="$SYNC_REGISTRY_DIR" \
	WORKTREE_REGISTRY_DB="$SYNC_REGISTRY_DB" \
	AIDEVOPS_CANONICAL_BEFORE_REF_UPDATE_HOOK="$sync_failure_hook" \
	bash "$HELPER" sync-mirror --repo "$SYNC_REPO" --issue 28065 \
	--confirm SYNCHRONIZE_CANONICAL_MIRROR 2>&1) || sync_rc=$?
sync_backup_id=""
while IFS= read -r sync_line; do
	case "$sync_line" in
	PRESERVED_BACKUP_ID=*) sync_backup_id="${sync_line#PRESERVED_BACKUP_ID=}" ;;
	esac
done <<<"$sync_output"
sync_preservation_ref="refs/aidevops/canonical-recovery/issue-28065/${sync_local_tip}"
if [[ "$sync_rc" -ne 0 ]] && [[ -n "$sync_backup_id" ]] &&
	[[ "$sync_output" == *"RESTORE_COMMAND="* ]] &&
	[[ -z "$(/usr/bin/git -C "$SYNC_REPO" status --porcelain=v1)" ]] &&
	[[ "$(/usr/bin/git -C "$SYNC_REPO" rev-parse HEAD)" == "$sync_local_tip" ]] &&
	[[ "$(/usr/bin/git -C "$SYNC_REPO" rev-parse "$sync_preservation_ref")" == "$sync_local_tip" ]]; then
	printf 'PASS interrupted synchronization leaves verified recovery evidence and a clean original tip\n'
else
	printf 'FAIL interrupted synchronization lost evidence or changed canonical state\n'
	exit 1
fi

if [[ "$(sqlite3 "$SYNC_REGISTRY_DB" "SELECT COUNT(*) FROM worktree_owners WHERE worktree_path = '${SYNC_REPO}';")" == "0" ]] &&
	kill -0 $$ 2>/dev/null; then
	printf 'PASS invalid canonical ownership row is removed without signalling its live PID\n'
else
	printf 'FAIL canonical ownership cleanup retained the row or harmed its live PID\n'
	exit 1
fi

sync_output=$(AIDEVOPS_REAL_GIT_BIN=/usr/bin/git \
	AIDEVOPS_DIRTY_BACKUP_ROOT="$SYNC_BACKUPS" \
	WORKTREE_REGISTRY_DIR="$SYNC_REGISTRY_DIR" \
	WORKTREE_REGISTRY_DB="$SYNC_REGISTRY_DB" \
	bash "$HELPER" sync-mirror --repo "$SYNC_REPO" --issue 28065 \
	--confirm SYNCHRONIZE_CANONICAL_MIRROR 2>&1)
if [[ "$sync_output" == *"SYNCHRONIZED_CANONICAL_MIRROR=true"* ]] &&
	[[ "$(/usr/bin/git -C "$SYNC_REPO" rev-parse HEAD)" == "$sync_remote_tip" ]] &&
	[[ -z "$(/usr/bin/git -C "$SYNC_REPO" status --porcelain=v1)" ]]; then
	printf 'PASS safe retry converges the canonical mirror to the exact resolved remote tip\n'
else
	printf 'FAIL safe retry did not converge to the exact remote tip\n'
	exit 1
fi

AIDEVOPS_REAL_GIT_BIN=/usr/bin/git AIDEVOPS_DIRTY_BACKUP_ROOT="$SYNC_BACKUPS" \
	bash "$DIRTY_HELPER" restore --repo "$SYNC_REPO" --backup "$sync_backup_id" \
	--confirm RESTORE_DIRTY_WORKTREE_BACKUP >/dev/null
if AIDEVOPS_REAL_GIT_BIN=/usr/bin/git AIDEVOPS_DIRTY_BACKUP_ROOT="$SYNC_BACKUPS" \
	bash "$DIRTY_HELPER" matches --repo "$SYNC_REPO" --backup "$sync_backup_id" >/dev/null &&
	[[ "$(/usr/bin/git -C "$SYNC_REPO" rev-parse HEAD)" == "$sync_local_tip" ]] &&
	[[ "$(/usr/bin/git -C "$SYNC_REPO" check-ignore local-state/runtime/nested/payload.bin)" == "local-state/runtime/nested/payload.bin" ]] &&
	[[ "$(stat -f '%Lp' "${SYNC_REPO}/local-state/runtime/nested/payload.bin" 2>/dev/null ||
		stat -c '%a' "${SYNC_REPO}/local-state/runtime/nested/payload.bin")" == "640" ]]; then
	printf 'PASS emitted backup ID restores byte-identical content and index state\n'
else
	printf 'FAIL backup restore did not reconstruct the original canonical state\n'
	exit 1
fi

sync_retry_output=$(AIDEVOPS_REAL_GIT_BIN=/usr/bin/git \
	AIDEVOPS_DIRTY_BACKUP_ROOT="$SYNC_BACKUPS" \
	WORKTREE_REGISTRY_DIR="$SYNC_REGISTRY_DIR" \
	WORKTREE_REGISTRY_DB="$SYNC_REGISTRY_DB" \
	bash "$HELPER" sync-mirror --repo "$SYNC_REPO" --issue 28065 \
	--confirm SYNCHRONIZE_CANONICAL_MIRROR 2>&1)
backup_count=0
for backup_path in "$SYNC_BACKUPS"/*; do
	[[ -d "$backup_path" ]] || continue
	backup_count=$((backup_count + 1))
done
if [[ "$sync_retry_output" == *"PRESERVED_BACKUP_ID=${sync_backup_id}"* ]] &&
	[[ "$backup_count" -eq 1 ]] &&
	[[ "$(/usr/bin/git -C "$SYNC_REPO" rev-parse HEAD)" == "$sync_remote_tip" ]] &&
	grep -q 'Canonical mirror synchronization authorized' "$HOME/.aidevops/logs/canonical-recovery-audit.jsonl"; then
	printf 'PASS repeated synchronization reuses durable evidence and remains auditable\n'
else
	printf 'FAIL repeated synchronization duplicated evidence or lost auditability\n'
	exit 1
fi

UPDATE_REMOTE="${ROOT}/update-remote.git"
UPDATE_REPO="${ROOT}/update-repo"
UPDATE_PEER="${ROOT}/update-peer"
UPDATE_BACKUPS="${ROOT}/update-backups"
mkdir -p "$UPDATE_REPO"
/usr/bin/git init -q --bare "$UPDATE_REMOTE"
/usr/bin/git -C "$UPDATE_REPO" init -q -b main
/usr/bin/git -C "$UPDATE_REPO" config user.name Test
/usr/bin/git -C "$UPDATE_REPO" config user.email test@example.invalid
/usr/bin/git -C "$UPDATE_REPO" config commit.gpgsign false
UPDATE_FRAMEWORK_URL="https://github.com/marcusquinn/aidevops.git"
/usr/bin/git -C "$UPDATE_REPO" config "url.${UPDATE_REMOTE}.insteadOf" "$UPDATE_FRAMEWORK_URL"
printf 'update seed\n' >"${UPDATE_REPO}/README.md"
/usr/bin/git -C "$UPDATE_REPO" add README.md
/usr/bin/git -C "$UPDATE_REPO" commit -q -m seed
/usr/bin/git -C "$UPDATE_REPO" remote add origin "$UPDATE_FRAMEWORK_URL"
/usr/bin/git -C "$UPDATE_REPO" push -q -u origin main
/usr/bin/git -C "$UPDATE_REMOTE" symbolic-ref HEAD refs/heads/main
/usr/bin/git -C "$UPDATE_REPO" remote set-head origin main
/usr/bin/git clone -q "$UPDATE_REMOTE" "$UPDATE_PEER"
/usr/bin/git -C "$UPDATE_PEER" config user.name Test
/usr/bin/git -C "$UPDATE_PEER" config user.email test@example.invalid

printf 'old retained state\n' >"${UPDATE_REPO}/old-untracked.txt"
old_backup_output=$(AIDEVOPS_REAL_GIT_BIN=/usr/bin/git AIDEVOPS_DIRTY_BACKUP_ROOT="$UPDATE_BACKUPS" \
	bash "$DIRTY_HELPER" backup --repo "$UPDATE_REPO" --operation-id old-update --machine)
IFS='|' read -r old_backup_id old_backup_dir <<<"$old_backup_output"
AIDEVOPS_REAL_GIT_BIN=/usr/bin/git AIDEVOPS_DIRTY_BACKUP_ROOT="$UPDATE_BACKUPS" \
	bash "$DIRTY_HELPER" clean --repo "$UPDATE_REPO" --backup "$old_backup_id" \
	--confirm CLEAN_VERIFIED_DIRTY_WORKTREE_BACKUP >/dev/null
AIDEVOPS_DIRTY_BACKUP_ROOT="$UPDATE_BACKUPS" bash "$DIRTY_HELPER" acknowledge \
	--backup "$old_backup_id" --confirm ACKNOWLEDGE_DIRTY_WORKTREE_BACKUP >/dev/null
touch -t 202001010000 "$old_backup_dir"

printf 'remote update\n' >"${UPDATE_PEER}/remote.txt"
/usr/bin/git -C "$UPDATE_PEER" add remote.txt
/usr/bin/git -C "$UPDATE_PEER" commit -q -m 'remote update'
/usr/bin/git -C "$UPDATE_PEER" push -q origin main
update_remote_tip=$(/usr/bin/git -C "$UPDATE_REMOTE" rev-parse refs/heads/main)
printf 'current retained state\n' >"${UPDATE_REPO}/current-untracked.txt"

update_output=$(AIDEVOPS_REAL_GIT_BIN=/usr/bin/git AIDEVOPS_DIRTY_BACKUP_ROOT="$UPDATE_BACKUPS" \
	bash "$HELPER" sync-mirror --repo "$UPDATE_REPO" --reason aidevops-update \
	--confirm SYNCHRONIZE_CANONICAL_MIRROR 2>&1)
update_backup_id=""
while IFS= read -r update_line; do
	case "$update_line" in
	PRESERVED_BACKUP_ID=*) update_backup_id="${update_line#PRESERVED_BACKUP_ID=}" ;;
	esac
done <<<"$update_output"
update_backup_dir="${UPDATE_BACKUPS}/${update_backup_id}"
if [[ "$update_output" == *"SYNCHRONIZED_CANONICAL_MIRROR=true"* ]] &&
	[[ "$update_output" == *"RESTORE_COMMAND="* ]] &&
	[[ "$(/usr/bin/git -C "$UPDATE_REPO" rev-parse HEAD)" == "$update_remote_tip" ]] &&
	[[ -z "$(/usr/bin/git -C "$UPDATE_REPO" status --porcelain=v1)" ]] &&
	[[ "$(awk -F '\t' '$1 == "state" { print $2 }' "$update_backup_dir/manifest.tsv")" == "acknowledged" ]] &&
	[[ ! -d "$old_backup_dir" ]]; then
	printf 'PASS routine update preserves untracked state, acknowledges reusable evidence, and prunes backups older than 30 days\n'
else
	printf 'FAIL routine update did not preserve, acknowledge, or prune backup evidence safely\n'
	exit 1
fi

AIDEVOPS_REAL_GIT_BIN=/usr/bin/git AIDEVOPS_DIRTY_BACKUP_ROOT="$UPDATE_BACKUPS" \
	bash "$DIRTY_HELPER" restore --repo "$UPDATE_REPO" --backup "$update_backup_id" \
	--confirm RESTORE_DIRTY_WORKTREE_BACKUP >/dev/null
if [[ -f "${UPDATE_REPO}/current-untracked.txt" ]] &&
	AIDEVOPS_REAL_GIT_BIN=/usr/bin/git AIDEVOPS_DIRTY_BACKUP_ROOT="$UPDATE_BACKUPS" \
		bash "$DIRTY_HELPER" matches --repo "$UPDATE_REPO" --backup "$update_backup_id" >/dev/null; then
	printf 'PASS routine update backup remains byte-restorable during the retention window\n'
else
	printf 'FAIL routine update backup did not restore the original untracked state\n'
	exit 1
fi

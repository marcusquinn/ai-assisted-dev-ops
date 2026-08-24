#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="${TEST_DIR}/.."
CLAIM="${SCRIPTS_DIR}/dispatch-claim-helper.sh"
LEDGER="${SCRIPTS_DIR}/dispatch-ledger-helper.sh"
DEDUP="${SCRIPTS_DIR}/dispatch-dedup-helper.sh"
SCRIPT_DIR="$SCRIPTS_DIR"
# shellcheck source=../dispatch-dedup-stale.sh
source "${SCRIPTS_DIR}/dispatch-dedup-stale.sh"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT
export AIDEVOPS_TEST_MODE=1
export AIDEVOPS_REPO_STATE_GUARD_TEST_BYPASS=1

fail() { printf 'FAIL %s\n' "$1" >&2; return 1; }
pass() { printf 'PASS %s\n' "$1"; return 0; }

create_mock_gh() {
	local root="$1"
	mkdir -p "$root/bin"
	cat >"$root/bin/gh" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
state="${MOCK_GH_STATE:?}"
comments="$state/comments.jsonl"
calls="$state/calls.log"
mkdir -p "$state"
touch "$comments"
touch "$calls"
printf '%s\n' "$*" >>"$calls"
if [[ "${1:-}" == api && "${2:-}" == user ]]; then printf 'shared-login\n'; exit 0; fi
if [[ "${1:-}" == issue && "${2:-}" == comment ]]; then exit 0; fi
[[ "${1:-}" == api ]] || exit 1
endpoint="${2:-}"
shift 2
if [[ "$endpoint" == repos/*/issues/[0-9]* && "$endpoint" != */comments* ]]; then
	printf '{"assignees":[]}\n'
	exit 0
fi
[[ "$endpoint" == repos/*/issues/*/comments* ]] || exit 1
method=GET
body=""
jq_expr=""
slurp_output=0
while [[ $# -gt 0 ]]; do
	case "$1" in
	--method) method="$2"; shift 2 ;;
	--field) [[ "$2" == body=* ]] && body="${2#body=}"; shift 2 ;;
	--jq) jq_expr="$2"; shift 2 ;;
	--slurp) slurp_output=1; shift ;;
	*) shift ;;
	esac
done
if [[ "$method" == POST ]]; then
	lock="$state/lock"
	while ! mkdir "$lock" 2>/dev/null; do sleep 0.01; done
	id=$(($(wc -l <"$comments" | tr -d ' ') + 1))
	created=$(date -u +%Y-%m-%dT%H:%M:%SZ)
	jq -cn --argjson id "$id" --arg body "$body" --arg created "$created" \
		--arg login "${MOCK_GH_LOGIN:-shared-login}" \
		--arg association "${MOCK_GH_ASSOCIATION:-MEMBER}" \
		'{id:$id,body:$body,created_at:$created,user:{login:$login},author_association:$association}' >>"$comments"
	rmdir "$lock"
	printf '%s\n' "$id"
	exit 0
fi
comments_json=$(jq -sc '.' "$comments")
if [[ -n "$jq_expr" ]]; then
	printf '%s' "$comments_json" | jq -c "$jq_expr"
	return_code=$?
	exit "$return_code"
fi
if [[ "$slurp_output" -eq 1 ]]; then
	printf '[%s]\n' "$comments_json"
	exit 0
fi
printf '%s\n' "$comments_json"
MOCK
	chmod +x "$root/bin/gh"
	return 0
}

claim_token() {
	local output_file="$1"
	sed -n 's/.*lease_token=\([^ ]*\).*/\1/p' "$output_file"
	return 0
}

write_large_claim_history() {
	local comments_file="$1"
	local mode="$2"
	mkdir -p "$(dirname "$comments_file")"
	python3 - "$comments_file" "$mode" <<'PY'
from datetime import datetime, timedelta, timezone
import json
import sys

comments_file, mode = sys.argv[1:]
now = datetime.now(timezone.utc)
claim_at = now - timedelta(seconds=300)
dispatch_at = now - timedelta(seconds=250)
terminal_at = now - timedelta(seconds=200)
expires_at = int((now + timedelta(seconds=600)).timestamp())
stamp = lambda value: value.strftime("%Y-%m-%dT%H:%M:%SZ")
token = "large-token"
comments = [
    {
        "id": 1,
        "body": (
            f"DISPATCH_CLAIM nonce={token} runner=shared-login ts={stamp(claim_at)} "
            f"max_age_s=600 version=test lease_token={token} device=device-large "
            f"session=issue-49 phase=prelaunch expires_at={expires_at}"
        ),
        "created_at": stamp(claim_at),
        "user": {"login": "shared-login"},
        "author_association": "MEMBER",
    },
    {
        "id": 2,
        "body": "Dispatching worker (deterministic). " + ("x" * 2_200_000),
        "created_at": stamp(dispatch_at),
        "user": {"login": "shared-login"},
        "author_association": "MEMBER",
    },
]
if mode == "terminal":
    comments.append(
        {
            "id": 3,
            "body": (
                f"DISPATCH_LEASE phase=terminal lease_token={token} device=device-large "
                f"session=issue-49 expires_at=0 ts={stamp(terminal_at)}"
            ),
            "created_at": stamp(terminal_at),
            "user": {"login": "shared-login"},
            "author_association": "MEMBER",
        }
    )
with open(comments_file, "w", encoding="utf-8") as handle:
    for comment in comments:
        json.dump(comment, handle, separators=(",", ":"))
        handle.write("\n")
PY
	return $?
}

test_local_ledger_guards() {
	local ledger_dir="${TMP_DIR}/ledger"
	export AIDEVOPS_DISPATCH_LEDGER_DIR="$ledger_dir"
	export AIDEVOPS_DEVICE_ID=device-fixture-a
	mkdir -p "$ledger_dir"
	"$LEDGER" register --session-key issue-local --issue 1 --repo owner/repo --pid 99999999 \
		--lease-token token-a --device-id device-fixture-a --lease-ttl 1
	sleep 2
	if "$LEDGER" check --session-key issue-local >/dev/null 2>&1; then fail "expired prelaunch ledger lease blocks"; fi
	if "$LEDGER" check-issue --issue 1 --repo owner/repo >/dev/null 2>&1; then fail "expired issue ledger lease blocks"; fi
	if "$LEDGER" ready --session-key issue-local --lease-token token-a >/dev/null 2>&1; then fail "expired ledger lease transitions ready"; fi
	pass "ledger checks enforce expiry without maintenance"

	"$LEDGER" register --session-key issue-ready --issue 2 --repo owner/repo --pid 99999999 \
		--lease-token token-b --device-id device-fixture-a --lease-ttl 30
	"$LEDGER" ready --session-key issue-ready --lease-token token-b --lease-ttl 30
	"$LEDGER" check --session-key issue-ready >/dev/null || fail "ready lease not protected"
	local before_register="" after_register="" effective_phase=""
	before_register=$(wc -l <"$ledger_dir/dispatch-ledger.jsonl" | tr -d ' ')
	"$LEDGER" register --session-key issue-ready --issue 2 --repo owner/repo --pid $$ \
		--lease-token token-b --device-id device-fixture-a --lease-ttl 30
	after_register=$(wc -l <"$ledger_dir/dispatch-ledger.jsonl" | tr -d ' ')
	effective_phase=$(jq -sr '[.[] | select(.session_key == "issue-ready")] | last.lease_phase' "$ledger_dir/dispatch-ledger.jsonl")
	[[ "$before_register" == "$after_register" && "$effective_phase" == ready ]] || fail "parent register regressed ready lease"
	"$LEDGER" complete --session-key issue-ready --lease-token token-b
	if "$LEDGER" ready --session-key issue-ready --lease-token token-b >/dev/null 2>&1; then fail "late ready overwrote terminal"; fi
	if "$LEDGER" fail --session-key issue-ready --lease-token token-b >/dev/null 2>&1; then fail "terminal lease mutated twice"; fi
	pass "ledger registration is phase-monotonic and terminal is immutable"
	return 0
}

test_concurrent_same_login_devices() {
	local root="${TMP_DIR}/race" rc_a=0 rc_b=0
	create_mock_gh "$root"
	PATH="$root/bin:$PATH" MOCK_GH_STATE="$root/state" AIDEVOPS_DEVICE_ID=device-a \
		DISPATCH_CLAIM_WINDOW=1 "$CLAIM" claim 42 owner/repo shared-login >"$root/a.out" 2>&1 &
	local pid_a=$!
	PATH="$root/bin:$PATH" MOCK_GH_STATE="$root/state" AIDEVOPS_DEVICE_ID=device-b \
		DISPATCH_CLAIM_WINDOW=1 "$CLAIM" claim 42 owner/repo shared-login >"$root/b.out" 2>&1 &
	local pid_b=$!
	wait "$pid_a" || rc_a=$?
	wait "$pid_b" || rc_b=$?
	if ! { [[ "$rc_a" -eq 0 && "$rc_b" -eq 1 ]] || [[ "$rc_a" -eq 1 && "$rc_b" -eq 0 ]]; }; then
		printf 'runner-a: %s\nrunner-b: %s\n' "$(tr '\n' ' ' <"$root/a.out")" "$(tr '\n' ' ' <"$root/b.out")" >&2
		fail "concurrent claims did not elect one winner: a=$rc_a b=$rc_b"
	fi
	grep -Fq 'device=device-a' "$root/state/comments.jsonl" || fail "device-a absent"
	grep -Fq 'device=device-b' "$root/state/comments.jsonl" || fail "device-b absent"
	pass "mock GitHub elects one same-login different-device winner"
	return 0
}

test_launch_crash_ready_terminal_race() {
	local root="${TMP_DIR}/lifecycle" token="" terminal_rc=0 ready_rc=0
	local forged_token="forged-token" forged_body="" forged_claim="" forged_expires_at=""
	create_mock_gh "$root"
	PATH="$root/bin:$PATH" MOCK_GH_STATE="$root/state" AIDEVOPS_DEVICE_ID=device-a \
		DISPATCH_CLAIM_WINDOW=0 DISPATCH_CLAIM_ORPHAN_GRACE=1 \
		"$CLAIM" claim 43 owner/repo shared-login >"$root/crash.out" 2>&1
	sleep 2
	if PATH="$root/bin:$PATH" MOCK_GH_STATE="$root/state" "$CLAIM" check 43 owner/repo >/dev/null 2>&1; then
		fail "launch crash lease did not expire"
	fi
	pass "launch crash expires and becomes reclaimable"
	: >"$root/state/comments.jsonl"

	PATH="$root/bin:$PATH" MOCK_GH_STATE="$root/state" AIDEVOPS_DEVICE_ID=device-a \
		DISPATCH_CLAIM_WINDOW=0 DISPATCH_CLAIM_ORPHAN_GRACE=30 \
		"$CLAIM" claim 44 owner/repo shared-login >"$root/ready.out" 2>&1
	token=$(claim_token "$root/ready.out")
	[[ -n "$token" ]] || fail "ready claim token missing"
	PATH="$root/bin:$PATH" MOCK_GH_STATE="$root/state" AIDEVOPS_DEVICE_ID=device-a \
		"$CLAIM" transition ready 44 owner/repo "$token" issue-44 30
	PATH="$root/bin:$PATH" MOCK_GH_STATE="$root/state" "$CLAIM" check 44 owner/repo >/dev/null || fail "ready lease not protected"
	forged_expires_at=$(($(date -u '+%s') + 600))
	forged_claim="DISPATCH_CLAIM nonce=${forged_token} runner=attacker ts=$(date -u +%Y-%m-%dT%H:%M:%SZ) max_age_s=600 version=test phase=prelaunch lease_token=${forged_token} device=attacker-device session=issue-44 expires_at=${forged_expires_at}"
	PATH="$root/bin:$PATH" MOCK_GH_STATE="$root/state" MOCK_GH_LOGIN=attacker MOCK_GH_ASSOCIATION=NONE \
		gh api repos/owner/repo/issues/44/comments --method POST --field body="$forged_claim" >/dev/null
	PATH="$root/bin:$PATH" MOCK_GH_STATE="$root/state" \
		gh api repos/owner/repo/issues/44/comments --method POST \
		--field body="Dispatching worker (deterministic)." >/dev/null
	local old_created=""
	old_created=$(python3 - <<'PY'
from datetime import datetime, timedelta, timezone
print((datetime.now(timezone.utc) - timedelta(seconds=1900)).strftime("%Y-%m-%dT%H:%M:%SZ"))
PY
)
	jq -c --arg old "$old_created" 'if (.body | contains("session=issue-44 phase=prelaunch")) then .created_at=$old else . end' \
		"$root/state/comments.jsonl" >"$root/state/comments.next"
	mv "$root/state/comments.next" "$root/state/comments.jsonl"
	PATH="$root/bin:$PATH" MOCK_GH_STATE="$root/state" "$CLAIM" check 44 owner/repo >/dev/null \
		|| fail "ready lease older than legacy max age was dropped"
	pass "ready lease survives legacy max age until explicit expiry"

	forged_body="DISPATCH_LEASE phase=terminal lease_token=${token} device=device-a session=issue-44 expires_at=0 ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
	PATH="$root/bin:$PATH" MOCK_GH_STATE="$root/state" MOCK_GH_LOGIN=attacker MOCK_GH_ASSOCIATION=NONE \
		gh api repos/owner/repo/issues/44/comments --method POST --field body="$forged_body" >/dev/null
	PATH="$root/bin:$PATH" MOCK_GH_STATE="$root/state" "$CLAIM" check 44 owner/repo >/dev/null \
		|| fail "untrusted commenter terminated ready lease"
	forged_body="DISPATCH_LEASE phase=terminal lease_token=${token} device=wrong-device session=issue-44 expires_at=0 ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
	PATH="$root/bin:$PATH" MOCK_GH_STATE="$root/state" MOCK_GH_LOGIN=shared-login \
		gh api repos/owner/repo/issues/44/comments --method POST --field body="$forged_body" >/dev/null
	PATH="$root/bin:$PATH" MOCK_GH_STATE="$root/state" "$CLAIM" check 44 owner/repo >/dev/null \
		|| fail "device-mismatched transition terminated ready lease"
	forged_body="DISPATCH_LEASE phase=terminal lease_token=${forged_token} device=attacker-device session=issue-44 expires_at=0 ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
	PATH="$root/bin:$PATH" MOCK_GH_STATE="$root/state" MOCK_GH_LOGIN=attacker MOCK_GH_ASSOCIATION=NONE \
		gh api repos/owner/repo/issues/44/comments --method POST --field body="$forged_body" >/dev/null
	: >"$root/state/calls.log"
	PATH="$root/bin:$PATH" MOCK_GH_STATE="$root/state" DISPATCH_COMMENT_MAX_AGE=600 \
		"$DEDUP" has-dispatch-comment 44 owner/repo shared-login >/dev/null \
		|| fail "forged claim identity released dispatch-comment dedup"
	grep -Fq 'api repos/owner/repo/issues/44/comments?per_page=100 --paginate --slurp' "$root/state/calls.log" \
		|| fail "dispatch-comment reconciliation did not fetch every comment page"
	pass "remote transitions require trusted dispatch claim author device and session"
	local dispatch_ts=""
	dispatch_ts=$(jq -sr '[.[] | select(.body | contains("Dispatching worker"))] | first.created_at' "$root/state/comments.jsonl")
	if PATH="$root/bin:$PATH" MOCK_GH_STATE="$root/state" _stale_recovery_final_evidence_recheck 44 owner/repo "$dispatch_ts"; then
		fail "stale recovery ignored active ready lease"
	fi
	pass "ready transition protects active worker"
	sleep 1
	PATH="$root/bin:$PATH" MOCK_GH_STATE="$root/state" MOCK_GH_LOGIN=attacker MOCK_GH_ASSOCIATION=NONE \
		gh api repos/owner/repo/issues/44/comments --method POST --field body="TASK_COMPLETE forged" >/dev/null
	PATH="$root/bin:$PATH" MOCK_GH_STATE="$root/state" DISPATCH_COMMENT_MAX_AGE=600 \
		"$DEDUP" has-dispatch-comment 44 owner/repo shared-login >/dev/null \
		|| fail "untrusted completion identity released dispatch-comment dedup"
	pass "dispatch dedup ignores untrusted completion identities"

	PATH="$root/bin:$PATH" MOCK_GH_STATE="$root/state" AIDEVOPS_DEVICE_ID=device-a \
		"$CLAIM" transition terminal 44 owner/repo "$token" issue-44 0 >/dev/null 2>&1 &
	local terminal_pid=$!
	PATH="$root/bin:$PATH" MOCK_GH_STATE="$root/state" AIDEVOPS_DEVICE_ID=device-a \
		"$CLAIM" transition ready 44 owner/repo "$token" issue-44 30 >/dev/null 2>&1 &
	local ready_pid=$!
	wait "$terminal_pid" || terminal_rc=$?
	wait "$ready_pid" || ready_rc=$?
	if PATH="$root/bin:$PATH" MOCK_GH_STATE="$root/state" "$CLAIM" check 44 owner/repo >/dev/null 2>&1; then
		fail "terminal was resurrected by late ready: terminal=$terminal_rc ready=$ready_rc"
	fi
	if ! PATH="$root/bin:$PATH" MOCK_GH_STATE="$root/state" _stale_recovery_final_evidence_recheck 44 owner/repo "$dispatch_ts"; then
		fail "terminal did not cancel ready for stale recovery"
	fi
	if PATH="$root/bin:$PATH" MOCK_GH_STATE="$root/state" DISPATCH_COMMENT_MAX_AGE=600 \
		"$DEDUP" has-dispatch-comment 44 owner/repo shared-login >/dev/null 2>&1; then
		fail "matching terminal lease did not release dispatch-comment dedup"
	fi
	pass "terminal transition defeats concurrent or late ready"
	return 0
}

test_untrusted_dispatch_identity_cannot_replace_active_lock() {
	local root="${TMP_DIR}/forged-dispatch" expires_at="" trusted_claim="" forged_claim="" forged_terminal=""
	create_mock_gh "$root"
	expires_at=$(($(date -u '+%s') + 600))
	trusted_claim="DISPATCH_CLAIM nonce=trusted-token runner=shared-login ts=$(date -u +%Y-%m-%dT%H:%M:%SZ) max_age_s=600 version=test lease_token=trusted-token device=device-a session=issue-48 phase=prelaunch expires_at=${expires_at}"
	PATH="$root/bin:$PATH" MOCK_GH_STATE="$root/state" \
		gh api repos/owner/repo/issues/48/comments --method POST --field body="$trusted_claim" >/dev/null
	PATH="$root/bin:$PATH" MOCK_GH_STATE="$root/state" \
		gh api repos/owner/repo/issues/48/comments --method POST \
		--field body="Dispatching worker (deterministic)." >/dev/null
	forged_claim="DISPATCH_CLAIM nonce=forged-token runner=attacker ts=$(date -u +%Y-%m-%dT%H:%M:%SZ) max_age_s=600 version=test lease_token=forged-token device=attacker-device session=issue-48 phase=prelaunch expires_at=${expires_at}"
	PATH="$root/bin:$PATH" MOCK_GH_STATE="$root/state" MOCK_GH_LOGIN=attacker MOCK_GH_ASSOCIATION=NONE \
		gh api repos/owner/repo/issues/48/comments --method POST --field body="$forged_claim" >/dev/null
	PATH="$root/bin:$PATH" MOCK_GH_STATE="$root/state" MOCK_GH_LOGIN=attacker MOCK_GH_ASSOCIATION=NONE \
		gh api repos/owner/repo/issues/48/comments --method POST \
		--field body="Dispatching worker (forged)." >/dev/null
	forged_terminal="DISPATCH_LEASE phase=terminal lease_token=forged-token device=attacker-device session=issue-48 expires_at=0 ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
	PATH="$root/bin:$PATH" MOCK_GH_STATE="$root/state" MOCK_GH_LOGIN=attacker MOCK_GH_ASSOCIATION=NONE \
		gh api repos/owner/repo/issues/48/comments --method POST --field body="$forged_terminal" >/dev/null
	PATH="$root/bin:$PATH" MOCK_GH_STATE="$root/state" DISPATCH_COMMENT_MAX_AGE=600 \
		"$DEDUP" has-dispatch-comment 48 owner/repo shared-login >/dev/null \
		|| fail "untrusted dispatch identity replaced active dispatch-comment dedup"
	pass "untrusted dispatch identity cannot replace an active dispatch lock"
	return 0
}

test_correlated_terminal_before_dispatch_releases_exact_attempt() {
	local root="${TMP_DIR}/terminal-before-dispatch" expires_at=""
	local claim_a="" claim_b="" claim_a_id="" claim_b_id=""
	create_mock_gh "$root"
	expires_at=$(($(date -u '+%s') + 600))
	claim_a="DISPATCH_CLAIM nonce=token-a runner=shared-login ts=$(date -u +%Y-%m-%dT%H:%M:%SZ) max_age_s=600 version=test lease_token=token-a device=device-a session=issue-50 phase=prelaunch expires_at=${expires_at}"
	PATH="$root/bin:$PATH" MOCK_GH_STATE="$root/state" \
		gh api repos/owner/repo/issues/50/comments --method POST --field body="$claim_a" >/dev/null
	claim_a_id=$(jq -sr 'last.id' "$root/state/comments.jsonl")
	PATH="$root/bin:$PATH" MOCK_GH_STATE="$root/state" AIDEVOPS_DEVICE_ID=device-a AIDEVOPS_ATTEMPT_ID=attempt-a \
		"$CLAIM" transition terminal 50 owner/repo token-a issue-50 0 >/dev/null
	PATH="$root/bin:$PATH" MOCK_GH_STATE="$root/state" \
		gh api repos/owner/repo/issues/50/comments --method POST \
		--field body="Dispatching worker (deterministic).
<!-- aidevops:dispatch lease_token=token-a device=device-a session=issue-50 attempt_id=attempt-wrong claim_id=${claim_a_id} -->" >/dev/null
	PATH="$root/bin:$PATH" MOCK_GH_STATE="$root/state" DISPATCH_COMMENT_MAX_AGE=600 \
		"$DEDUP" has-dispatch-comment 50 owner/repo shared-login >/dev/null \
		|| fail "wrong attempt ID released a correlated dispatch marker"
	PATH="$root/bin:$PATH" MOCK_GH_STATE="$root/state" \
		gh api repos/owner/repo/issues/50/comments --method POST \
		--field body="Dispatching worker (deterministic).
<!-- aidevops:dispatch lease_token=token-a device=device-a session=issue-50 attempt_id=attempt-a claim_id=${claim_a_id} -->" >/dev/null
	if PATH="$root/bin:$PATH" MOCK_GH_STATE="$root/state" DISPATCH_COMMENT_MAX_AGE=600 \
		"$DEDUP" has-dispatch-comment 50 owner/repo shared-login >/dev/null 2>&1; then
		fail "correlated terminal-before-dispatch evidence retained the exact attempt lock"
	fi

	claim_b="DISPATCH_CLAIM nonce=token-b runner=shared-login ts=$(date -u +%Y-%m-%dT%H:%M:%SZ) max_age_s=600 version=test lease_token=token-b device=device-b session=issue-50 phase=prelaunch expires_at=${expires_at}"
	PATH="$root/bin:$PATH" MOCK_GH_STATE="$root/state" \
		gh api repos/owner/repo/issues/50/comments --method POST --field body="$claim_b" >/dev/null
	claim_b_id=$(jq -sr 'last.id' "$root/state/comments.jsonl")
	PATH="$root/bin:$PATH" MOCK_GH_STATE="$root/state" \
		gh api repos/owner/repo/issues/50/comments --method POST \
		--field body="Dispatching worker (deterministic).
<!-- aidevops:dispatch lease_token=token-b device=device-b session=issue-50 attempt_id=attempt-b claim_id=${claim_b_id} -->" >/dev/null
	PATH="$root/bin:$PATH" MOCK_GH_STATE="$root/state" DISPATCH_COMMENT_MAX_AGE=600 \
		"$DEDUP" has-dispatch-comment 50 owner/repo shared-login >/dev/null \
		|| fail "older terminal attempt released a newer correlated dispatch marker"
	pass "correlated terminal-before-dispatch only releases its exact attempt"
	return 0
}

test_large_comment_history_avoids_argv_limits() {
	local root="${TMP_DIR}/large-history" output="" exit_code=0 dispatch_ts=""
	create_mock_gh "$root"
	write_large_claim_history "$root/state/comments.jsonl" active

	set +e
	output=$(PATH="$root/bin:$PATH" MOCK_GH_STATE="$root/state" \
		DISPATCH_CLAIM_MAX_AGE=600 DISPATCH_CLAIM_ORPHAN_GRACE=120 \
		"$CLAIM" check 49 owner/repo 2>&1)
	exit_code=$?
	set -e
	[[ "$exit_code" -eq 0 && "$output" == *"ACTIVE_CLAIM"* ]] ||
		fail "oversized active claim history failed: exit=${exit_code} output=${output}"
	pass "oversized claim history preserves launch evidence without argv transport"

	write_large_claim_history "$root/state/comments.jsonl" terminal
	set +e
	output=$(PATH="$root/bin:$PATH" MOCK_GH_STATE="$root/state" \
		DISPATCH_CLAIM_MAX_AGE=600 "$CLAIM" check 49 owner/repo 2>&1)
	exit_code=$?
	set -e
	[[ "$exit_code" -eq 1 && "$output" != *"failed to parse claim comments"* ]] ||
		fail "oversized terminal claim history failed: exit=${exit_code} output=${output}"
	if PATH="$root/bin:$PATH" MOCK_GH_STATE="$root/state" DISPATCH_COMMENT_MAX_AGE=600 \
		"$DEDUP" has-dispatch-comment 49 owner/repo shared-login >/dev/null 2>&1; then
		fail "oversized terminal history did not release dispatch dedup"
	fi
	dispatch_ts=$(jq -sr '[.[] | select(.body | contains("Dispatching worker"))] | last.created_at' "$root/state/comments.jsonl")
	PATH="$root/bin:$PATH" MOCK_GH_STATE="$root/state" \
		_stale_recovery_final_evidence_recheck 49 owner/repo "$dispatch_ts" ||
		fail "oversized terminal history blocked stale final evidence recheck"
	pass "oversized terminal history preserves dedup and stale-recovery semantics"
	return 0
}

test_prelaunch_renewal_covers_slow_startup() {
	local root="${TMP_DIR}/renewal" token="" renewal_call=""
	create_mock_gh "$root"
	PATH="$root/bin:$PATH" MOCK_GH_STATE="$root/state" AIDEVOPS_DEVICE_ID=device-a \
		DISPATCH_CLAIM_WINDOW=0 DISPATCH_CLAIM_ORPHAN_GRACE=3 \
		"$CLAIM" claim 47 owner/repo shared-login >"$root/renew.out" 2>&1
	token=$(claim_token "$root/renew.out")
	[[ -n "$token" ]] || fail "renewal claim token missing"
	sleep 2
	PATH="$root/bin:$PATH" MOCK_GH_STATE="$root/state" AIDEVOPS_DEVICE_ID=device-a \
		DISPATCH_OVERRIDE_SHARED_LOGIN=ignore \
		"$CLAIM" transition prelaunch 47 owner/repo "$token" issue-47 3
	sleep 2
	PATH="$root/bin:$PATH" MOCK_GH_STATE="$root/state" AIDEVOPS_DEVICE_ID=device-a \
		DISPATCH_OVERRIDE_SHARED_LOGIN=ignore \
		"$CLAIM" transition ready 47 owner/repo "$token" issue-47 30 ||
		fail "self-preserved prelaunch lease did not survive slow startup"
	# shellcheck disable=SC2016 # Match the literal runtime variable in the helper source.
	renewal_call='_hrw_renew_dispatch_prelaunch_lease "$session_key"'
	grep -Fq "$renewal_call" "${SCRIPTS_DIR}/headless-runtime-run.sh" ||
		fail "worker does not renew its prelaunch lease before canary"
	pass "worker prelaunch renewal preserves self claims across override filtering"
	return 0
}

test_prelaunch_renewal_is_monotonic_and_coalesced() {
	local root="${TMP_DIR}/renewal-coalescing" token="" initial_expiry="" extended_expiry=""
	local comment_count=""
	create_mock_gh "$root"
	PATH="$root/bin:$PATH" MOCK_GH_STATE="$root/state" AIDEVOPS_DEVICE_ID=device-a \
		DISPATCH_CLAIM_WINDOW=0 DISPATCH_CLAIM_ORPHAN_GRACE=30 \
		"$CLAIM" claim 51 owner/repo shared-login >"$root/claim.out" 2>&1
	token=$(claim_token "$root/claim.out")
	[[ -n "$token" ]] || fail "coalescing claim token missing"
	initial_expiry=$(jq -sr 'last.body | capture("expires_at=(?<value>[0-9]+)").value | tonumber' \
		"$root/state/comments.jsonl")

	PATH="$root/bin:$PATH" MOCK_GH_STATE="$root/state" AIDEVOPS_DEVICE_ID=device-a \
		"$CLAIM" transition prelaunch 51 owner/repo "$token" issue-51 10 ||
		fail "covered prelaunch renewal did not succeed"
	comment_count=$(wc -l <"$root/state/comments.jsonl" | tr -d ' ')
	[[ "$comment_count" == "1" ]] || fail "covered prelaunch renewal posted a redundant comment"

	PATH="$root/bin:$PATH" MOCK_GH_STATE="$root/state" AIDEVOPS_DEVICE_ID=device-a \
		"$CLAIM" transition prelaunch 51 owner/repo "$token" issue-51 60 ||
		fail "extending prelaunch renewal failed"
	comment_count=$(wc -l <"$root/state/comments.jsonl" | tr -d ' ')
	[[ "$comment_count" == "2" ]] || fail "extending prelaunch renewal did not post exactly once"
	extended_expiry=$(jq -sr '[.[] | select(.body | contains("DISPATCH_LEASE phase=prelaunch"))] | last.body | capture("expires_at=(?<value>[0-9]+)").value | tonumber' \
		"$root/state/comments.jsonl")
	[[ "$extended_expiry" -gt "$initial_expiry" ]] || fail "prelaunch renewal did not extend expiry"

	PATH="$root/bin:$PATH" MOCK_GH_STATE="$root/state" AIDEVOPS_DEVICE_ID=device-a \
		"$CLAIM" transition prelaunch 51 owner/repo "$token" issue-51 5 ||
		fail "regressive prelaunch renewal did not succeed as a no-op"
	comment_count=$(wc -l <"$root/state/comments.jsonl" | tr -d ' ')
	[[ "$comment_count" == "2" ]] || fail "regressive prelaunch renewal posted a comment"
	PATH="$root/bin:$PATH" MOCK_GH_STATE="$root/state" AIDEVOPS_DEVICE_ID=device-a \
		"$CLAIM" transition ready 51 owner/repo "$token" issue-51 90 ||
		fail "ready transition failed after coalesced renewal"
	comment_count=$(wc -l <"$root/state/comments.jsonl" | tr -d ' ')
	[[ "$comment_count" == "3" ]] || fail "ready transition was incorrectly coalesced"
	pass "prelaunch renewals are monotonic and redundant comments are coalesced"
	return 0
}

test_takeover_recheck_precedes_mutation() {
	local root="${TMP_DIR}/takeover"
	create_mock_gh "$root"
	PATH="$root/bin:$PATH" MOCK_GH_STATE="$root/state" AIDEVOPS_DEVICE_ID=device-a \
		DISPATCH_CLAIM_WINDOW=0 "$CLAIM" claim 46 owner/repo shared-login >/dev/null
	MUTATION_CALLED=0
	set_issue_status() { MUTATION_CALLED=1; return 0; }
	_stale_recovery_has_unresolved_blocked_by() { return 1; }
	PATH="$root/bin:$PATH" MOCK_GH_STATE="$root/state" \
		_stale_recovery_apply 46 owner/repo shared-login stale "2000-01-01T00:00:00Z" >/dev/null
	[[ "$MUTATION_CALLED" -eq 0 ]] || fail "takeover mutation ran after evidence changed"
	pass "final evidence recheck blocks takeover mutation"
	return 0
}

test_invalid_device_not_public() {
	local root="${TMP_DIR}/device"
	create_mock_gh "$root"
	PATH="$root/bin:$PATH" MOCK_GH_STATE="$root/state" AIDEVOPS_DEVICE_ID=$'bad device\nINJECTED' \
		AIDEVOPS_DEVICE_ID_FILE="$root/device-id" DISPATCH_CLAIM_WINDOW=0 \
		"$CLAIM" claim 45 owner/repo shared-login >/dev/null 2>&1
	if grep -Fq 'INJECTED' "$root/state/comments.jsonl"; then fail "invalid device reached public marker"; fi
	pass "invalid device IDs are rejected before public output"
	return 0
}

test_local_ledger_guards
test_concurrent_same_login_devices
test_launch_crash_ready_terminal_race
test_untrusted_dispatch_identity_cannot_replace_active_lock
test_correlated_terminal_before_dispatch_releases_exact_attempt
test_large_comment_history_avoids_argv_limits
test_prelaunch_renewal_covers_slow_startup
test_prelaunch_renewal_is_monotonic_and_coalesced
test_invalid_device_not_public
test_takeover_recheck_precedes_mutation
printf '\nAtomic lease concurrency tests passed\n'
exit 0

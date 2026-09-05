#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-dispatch-cooldown.sh — t3197 regression guard.
#
# Asserts that `dispatch-dedup-helper.sh is-assigned` short-circuits with
# DISPATCH_COOLDOWN_ACTIVE for a recent, authenticated maintainer/collaborator
# comment carrying an unexpired exact
# `<!-- dispatch-cooldown-until:<ISO> reason=no_worker_process runner=<login> -->`
# marker. It does NOT block for expired, malformed, untrusted, mismatched, or
# overlong markers.
#
# Failure mode this guards against: a runner with broken runtime (CLI
# changes, missing binary, network flake) burns ~5 worker spawns over
# 3-4 hours per issue with 95-99s lifespans each, repeated across 30+
# issues simultaneously. The cooldown marker (default 30 min, set via
# DISPATCH_COOLDOWN_AFTER_LAUNCH_FAILURE_SECONDS) provides backpressure.
#
# Pattern mirrored from `test-dispatch-dedup-no-auto-dispatch-block.sh`
# (t2832).
#
# NOTE: not using `set -e` intentionally — negative assertions rely on
# capturing non-zero exits from is-assigned.

set -uo pipefail

TEST_SCRIPTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# NOTE: NOT readonly — shared-constants.sh declares `readonly RED/GREEN/RESET`
# and the collision under set -e silently kills the test shell. Use plain vars.
TEST_RED=$'\033[0;31m'
TEST_GREEN=$'\033[0;32m'
TEST_RESET=$'\033[0m'

TESTS_RUN=0
TESTS_FAILED=0

print_result() {
	local name="$1" rc="$2" extra="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$rc" -eq 0 ]]; then
		printf '%sPASS%s %s\n' "$TEST_GREEN" "$TEST_RESET" "$name"
	else
		printf '%sFAIL%s %s %s\n' "$TEST_RED" "$TEST_RESET" "$name" "$extra"
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	return 0
}

# Sandbox HOME so sourcing is side-effect-free
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
export HOME="${TEST_ROOT}/home"
mkdir -p "${HOME}/.aidevops/logs" "${HOME}/.aidevops/.agent-workspace/supervisor"

# =============================================================================
# Stub the gh CLI so we can feed synthetic issue payloads + comments
# =============================================================================
STUB_DIR="${TEST_ROOT}/bin"
mkdir -p "$STUB_DIR"

# write_stub_gh: configure the stub to respond to:
#   - `gh issue view ...`         → emits ISSUE_PAYLOAD
#   - `gh api --paginate --slurp repos/.../comments...` → emits COMMENTS_PAYLOAD
#
# Both payloads are passed via stub-side env vars so successive test cases
# can swap them without rewriting the script.
write_stub_gh() {
	local issue_payload="$1"
	local comments_payload="${2:-[]}"
	cat >"${STUB_DIR}/gh" <<STUB
#!/usr/bin/env bash
# Stub for test-dispatch-cooldown.sh
if [[ "\$1" == "issue" && "\$2" == "view" ]]; then
	cat <<'JSON'
${issue_payload}
JSON
	exit 0
fi
if [[ "\$1" == "api" && "\$4" == *sort=* ]]; then
	exit 1
fi
if [[ "\$1" == "api" && "\$4" == *direction=* ]]; then
	exit 1
fi
if [[ "\$1" == "api" && "\$2" == "--paginate" && "\$3" == "--slurp" && "\$4" == repos/*/issues/*/comments* ]]; then
	printf '['
	cat <<'JSON'
${comments_payload}
JSON
	printf ']'
	exit 0
fi
exit 1
STUB
	chmod +x "${STUB_DIR}/gh"
	return 0
}

OLD_PATH="$PATH"
export PATH="${STUB_DIR}:${PATH}"

# run_is_assigned: invokes dispatch-dedup-helper.sh is-assigned, captures
# both stdout and exit code into globals `output` and `rc`.
run_is_assigned() {
	local issue="$1" repo="$2" self="${3:-}"
	output=$("${TEST_SCRIPTS_DIR}/dispatch-dedup-helper.sh" is-assigned "$issue" "$repo" "$self" 2>/dev/null)
	rc=$?
	return 0
}

# Minimal label set that should pass through every guard above the cooldown
# check (no parent-task, no no-auto-dispatch, no assignees).
PASSTHROUGH_ISSUE='{"state":"OPEN","assignees":[],"labels":[{"name":"tier:standard"}]}'

# Helper to compute ISO8601 UTC timestamps relative to now (portable: GNU then BSD).
iso_offset() {
	local seconds="$1"
	local epoch
	epoch=$(date -u +%s)
	epoch=$((epoch + seconds))
	date -u -d "@${epoch}" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null && return 0
	date -u -r "${epoch}" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null && return 0
	return 1
}

# =============================================================================
# Part 1 — Active cooldown blocks dispatch
# =============================================================================

# Case A: a trusted, recent marker inside the configured 30-minute lifetime
# blocks dispatch.
NOW_ISO=$(iso_offset 0)
FUTURE_ISO=$(iso_offset 600)
COMMENTS_FUTURE='[{"id":100,"user":{"login":"alex-solovyev"},"author_association":"OWNER","created_at":"'"${NOW_ISO}"'","body":"<!-- dispatch-cooldown-until:'"${FUTURE_ISO}"' reason=no_worker_process runner=alex-solovyev -->\nDispatch cooldown active until '"${FUTURE_ISO}"'."}]'
write_stub_gh "$PASSTHROUGH_ISSUE" "$COMMENTS_FUTURE"
run_is_assigned 99887 "owner/repo"
if [[ "$rc" -eq 0 && "$output" == *"DISPATCH_COOLDOWN_ACTIVE"* && "$output" == *"$FUTURE_ISO"* ]]; then
	print_result "is-assigned blocks unexpired dispatch-cooldown marker (DISPATCH_COOLDOWN_ACTIVE)" 0
else
	print_result "is-assigned blocks unexpired dispatch-cooldown marker (DISPATCH_COOLDOWN_ACTIVE)" 1 \
		"(rc=$rc output='$output')"
fi

# Case B: a later trusted marker overrides an earlier expired marker.
PAST_ISO=$(iso_offset -3600)
FUTURE_ISO_2=$(iso_offset 900)
COMMENTS_LATEST_WINS='[{"id":101,"user":{"login":"runner-a"},"author_association":"MEMBER","created_at":"'"${PAST_ISO}"'","body":"<!-- dispatch-cooldown-until:'"${PAST_ISO}"' reason=no_worker_process runner=runner-a -->"},{"id":102,"user":{"login":"maintainer"},"author_association":"OWNER","created_at":"'"${NOW_ISO}"'","body":"intervening human comment"},{"id":103,"user":{"login":"runner-b"},"author_association":"COLLABORATOR","created_at":"'"${NOW_ISO}"'","body":"<!-- dispatch-cooldown-until:'"${FUTURE_ISO_2}"' reason=no_worker_process runner=runner-b -->"}]'
write_stub_gh "$PASSTHROUGH_ISSUE" "$COMMENTS_LATEST_WINS"
run_is_assigned 99886 "owner/repo"
if [[ "$rc" -eq 0 && "$output" == *"DISPATCH_COOLDOWN_ACTIVE"* && "$output" == *"$FUTURE_ISO_2"* ]]; then
	print_result "is-assigned: latest cooldown marker wins (older expired, newer active)" 0
else
	print_result "is-assigned: latest cooldown marker wins (older expired, newer active)" 1 \
		"(rc=$rc output='$output')"
fi

# =============================================================================
# Part 2 — Negative cases (must NOT block on cooldown)
# =============================================================================

# Case C: marker timestamp 60 minutes in the PAST → expired, must not block.
COMMENTS_EXPIRED='[{"id":104,"user":{"login":"alex-solovyev"},"author_association":"OWNER","created_at":"'"${PAST_ISO}"'","body":"<!-- dispatch-cooldown-until:'"${PAST_ISO}"' reason=no_worker_process runner=alex-solovyev -->"}]'
write_stub_gh "$PASSTHROUGH_ISSUE" "$COMMENTS_EXPIRED"
run_is_assigned 99885 "owner/repo"
if [[ "$output" != *"DISPATCH_COOLDOWN_ACTIVE"* ]]; then
	print_result "is-assigned does not block on expired cooldown marker" 0
else
	print_result "is-assigned does not block on expired cooldown marker" 1 \
		"(rc=$rc output='$output')"
fi

# Case D: no cooldown marker at all → must not emit DISPATCH_COOLDOWN_ACTIVE.
COMMENTS_NONE='[{"body":"unrelated chatter"},{"body":"another comment with no marker"}]'
write_stub_gh "$PASSTHROUGH_ISSUE" "$COMMENTS_NONE"
run_is_assigned 99884 "owner/repo"
if [[ "$output" != *"DISPATCH_COOLDOWN_ACTIVE"* ]]; then
	print_result "is-assigned does not emit DISPATCH_COOLDOWN_ACTIVE without marker" 0
else
	print_result "is-assigned does not emit DISPATCH_COOLDOWN_ACTIVE without marker" 1 \
		"(rc=$rc output='$output')"
fi

# Case E: empty comments array (new issue, never failed) → must not block.
write_stub_gh "$PASSTHROUGH_ISSUE" "[]"
run_is_assigned 99883 "owner/repo"
if [[ "$output" != *"DISPATCH_COOLDOWN_ACTIVE"* ]]; then
	print_result "is-assigned handles empty comments array (no-op)" 0
else
	print_result "is-assigned handles empty comments array (no-op)" 1 \
		"(rc=$rc output='$output')"
fi

# Case F: a CONTRIBUTOR marker must not consume cooldown, even when the body
# claims a runner name and timestamp that would otherwise be valid.
COMMENTS_UNTRUSTED='[{"id":105,"user":{"login":"external-runner"},"author_association":"CONTRIBUTOR","created_at":"'"${NOW_ISO}"'","body":"<!-- dispatch-cooldown-until:'"${FUTURE_ISO}"' reason=no_worker_process runner=external-runner -->"}]'
write_stub_gh "$PASSTHROUGH_ISSUE" "$COMMENTS_UNTRUSTED"
run_is_assigned 99881 "owner/repo"
if [[ "$output" != *"DISPATCH_COOLDOWN_ACTIVE"* ]]; then
	print_result "is-assigned ignores untrusted cooldown marker offline" 0
else
	print_result "is-assigned ignores untrusted cooldown marker offline" 1 \
		"(rc=$rc output='$output')"
fi

# Case G: marker runner must match the nonempty authenticated comment login.
COMMENTS_MISMATCH='[{"id":106,"user":{"login":"runner-a"},"author_association":"MEMBER","created_at":"'"${NOW_ISO}"'","body":"<!-- dispatch-cooldown-until:'"${FUTURE_ISO}"' reason=no_worker_process runner=runner-b -->"}]'
write_stub_gh "$PASSTHROUGH_ISSUE" "$COMMENTS_MISMATCH"
run_is_assigned 99880 "owner/repo"
if [[ "$output" != *"DISPATCH_COOLDOWN_ACTIVE"* ]]; then
	print_result "is-assigned ignores runner/login mismatch offline" 0
else
	print_result "is-assigned ignores runner/login mismatch offline" 1 \
		"(rc=$rc output='$output')"
fi

# Case H: a trusted marker cannot extend past one cooldown interval from the
# GitHub server's created_at timestamp.
OVERLONG_ISO=$(iso_offset 3600)
COMMENTS_OVERLONG='[{"id":107,"user":{"login":"runner-a"},"author_association":"MEMBER","created_at":"'"${NOW_ISO}"'","body":"<!-- dispatch-cooldown-until:'"${OVERLONG_ISO}"' reason=no_worker_process runner=runner-a -->"}]'
write_stub_gh "$PASSTHROUGH_ISSUE" "$COMMENTS_OVERLONG"
run_is_assigned 99879 "owner/repo"
if [[ "$output" != *"DISPATCH_COOLDOWN_ACTIVE"* ]]; then
	print_result "is-assigned ignores overlong cooldown marker offline" 0
else
	print_result "is-assigned ignores overlong cooldown marker offline" 1 \
		"(rc=$rc output='$output')"
fi

# Case I: a marker with a future server created_at must not consume cooldown.
FUTURE_CREATED_ISO=$(iso_offset 60)
COMMENTS_FUTURE_CREATED='[{"id":108,"user":{"login":"runner-a"},"author_association":"MEMBER","created_at":"'"${FUTURE_CREATED_ISO}"'","body":"<!-- dispatch-cooldown-until:'"${FUTURE_ISO}"' reason=no_worker_process runner=runner-a -->"}]'
write_stub_gh "$PASSTHROUGH_ISSUE" "$COMMENTS_FUTURE_CREATED"
run_is_assigned 99878 "owner/repo"
if [[ "$output" != *"DISPATCH_COOLDOWN_ACTIVE"* ]]; then
	print_result "is-assigned ignores future server-created cooldown marker" 0
else
	print_result "is-assigned ignores future server-created cooldown marker" 1 \
		"(rc=$rc output='$output')"
fi

# Case J: exact marker parsing rejects extra attributes and malformed markers.
COMMENTS_MALFORMED='[{"id":109,"user":{"login":"runner-a"},"author_association":"MEMBER","created_at":"'"${NOW_ISO}"'","body":"<!-- dispatch-cooldown-until:'"${FUTURE_ISO}"' reason=no_worker_process runner=runner-a forged=true -->"}]'
write_stub_gh "$PASSTHROUGH_ISSUE" "$COMMENTS_MALFORMED"
run_is_assigned 99877 "owner/repo"
if [[ "$output" != *"DISPATCH_COOLDOWN_ACTIVE"* ]]; then
	print_result "is-assigned ignores malformed cooldown marker" 0
else
	print_result "is-assigned ignores malformed cooldown marker" 1 \
		"(rc=$rc output='$output')"
fi

# Case K: GitHub returns each page independently. Equal created_at values must
# resolve by numeric comment ID, not page or timestamp ordering.
FUTURE_ISO_3=$(iso_offset 300)
FUTURE_ISO_4=$(iso_offset 600)
COMMENTS_PAGINATED_EQUAL_SECONDS='[{"id":110,"user":{"login":"runner-a"},"author_association":"OWNER","created_at":"'"${NOW_ISO}"'","body":"<!-- dispatch-cooldown-until:'"${FUTURE_ISO_3}"' reason=no_worker_process runner=runner-a -->"}],[{"id":111,"user":{"login":"runner-b"},"author_association":"COLLABORATOR","created_at":"'"${NOW_ISO}"'","body":"<!-- dispatch-cooldown-until:'"${FUTURE_ISO_4}"' reason=no_worker_process runner=runner-b -->"}]'
write_stub_gh "$PASSTHROUGH_ISSUE" "$COMMENTS_PAGINATED_EQUAL_SECONDS"
run_is_assigned 99876 "owner/repo"
if [[ "$rc" -eq 0 && "$output" == *"DISPATCH_COOLDOWN_ACTIVE"* && "$output" == *"$FUTURE_ISO_4"* ]]; then
	print_result "is-assigned orders paginated equal-second markers by numeric ID" 0
else
	print_result "is-assigned orders paginated equal-second markers by numeric ID" 1 \
		"(rc=$rc output='$output')"
fi

# =============================================================================
# Part 3 — Feature gate (DISPATCH_COOLDOWN_AFTER_LAUNCH_FAILURE_SECONDS=0)
# =============================================================================

# Case L: feature disabled — even an unexpired marker must not block.
# Skips the gh API call entirely (which is the optimisation goal of the gate).
COMMENTS_FUTURE_3='[{"id":112,"user":{"login":"alex-solovyev"},"author_association":"OWNER","created_at":"'"${NOW_ISO}"'","body":"<!-- dispatch-cooldown-until:'"${FUTURE_ISO_3}"' reason=no_worker_process runner=alex-solovyev -->"}]'
write_stub_gh "$PASSTHROUGH_ISSUE" "$COMMENTS_FUTURE_3"
output=$(DISPATCH_COOLDOWN_AFTER_LAUNCH_FAILURE_SECONDS=0 \
	"${TEST_SCRIPTS_DIR}/dispatch-dedup-helper.sh" is-assigned 99882 "owner/repo" 2>/dev/null)
rc=$?
if [[ "$output" != *"DISPATCH_COOLDOWN_ACTIVE"* ]]; then
	print_result "is-assigned skips cooldown check when feature gate=0" 0
else
	print_result "is-assigned skips cooldown check when feature gate=0" 1 \
		"(rc=$rc output='$output')"
fi

export PATH="$OLD_PATH"

# =============================================================================
# Summary
# =============================================================================
echo
if [[ "$TESTS_FAILED" -eq 0 ]]; then
	printf '%sAll %d tests passed%s\n' "$TEST_GREEN" "$TESTS_RUN" "$TEST_RESET"
	exit 0
else
	printf '%s%d / %d tests failed%s\n' "$TEST_RED" "$TESTS_FAILED" "$TESTS_RUN" "$TEST_RESET"
	exit 1
fi

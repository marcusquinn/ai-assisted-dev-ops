#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Tests for knowledge-review-helper.sh (t2845)
# =============================================================================
# Run: bash .agents/tests/test-knowledge-review.sh
#
# Tests:
#   1. shellcheck — zero violations
#   2. auto-promotion path — maintainer trust → moves inbox → sources + audit
#   3. review-file path — untrusted → moves to staging, audit record written
#   4. review_gate path — review_gate email → staged (no GH slug, no issue filed)
#   5. idempotent tick — re-run on already-staged source does not double-process
#   6. promote subcommand — moves staging → sources, updates meta.json state
#   7. audit-log subcommand — appends JSONL record to index/audit.log
#   8. trust ladder — explicit trust:trusted meta field triggers auto-promote
#   9. trusted/authoritative meta field — both trigger auto-promote
#  10. missing meta.json — skipped gracefully
#  11. untrusted review issue — hold-for-review, never NMR, manual promotion guidance
#
# Mocking strategy: create a minimal _knowledge/ directory tree in a temp dir,
# set KNOWLEDGE_ROOT and CWD so the helper picks it up, then inspect results.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="${SCRIPT_DIR}/../scripts"
HELPER="${SCRIPTS_DIR}/knowledge-review-helper.sh"

PASS=0
FAIL=0
TEST_TMPDIR=""

# ---------------------------------------------------------------------------
# Test infrastructure
# ---------------------------------------------------------------------------

setup() {
	TEST_TMPDIR=$(mktemp -d)
	return 0
}

teardown() {
	[[ -n "${TEST_TMPDIR:-}" ]] && rm -rf "$TEST_TMPDIR"
	return 0
}

pass() {
	local name="$1"
	PASS=$((PASS + 1))
	echo "[PASS] $name"
	return 0
}

fail() {
	local name="$1" reason="${2:-}"
	FAIL=$((FAIL + 1))
	echo "[FAIL] $name${reason:+ — $reason}"
	return 0
}

# ---------------------------------------------------------------------------
# Factory: create a minimal knowledge plane with one inbox source
# ---------------------------------------------------------------------------

make_plane() {
	local plane_dir="$1"
	mkdir -p "${plane_dir}/inbox" \
		"${plane_dir}/staging" \
		"${plane_dir}/sources" \
		"${plane_dir}/index" \
		"${plane_dir}/_config"
	return 0
}

make_source() {
	local plane_dir="$1"
	local source_id="$2"
	local trust="${3:-unverified}"
	local ingested_by="${4:-unknown}"
	local kind="${5:-document}"

	mkdir -p "${plane_dir}/inbox/${source_id}"
	cat > "${plane_dir}/inbox/${source_id}/meta.json" <<META
{
  "version": 1,
  "id": "${source_id}",
  "kind": "${kind}",
  "sha256": "abc123def456",
  "ingested_at": "2026-04-27T00:00:00Z",
  "ingested_by": "${ingested_by}",
  "sensitivity": "internal",
  "trust": "${trust}",
  "size_bytes": 1024
}
META
	printf 'Sample content for %s\n' "$source_id" \
		> "${plane_dir}/inbox/${source_id}/content.txt"
	return 0
}

make_trust_config() {
	local plane_dir="$1"
	cat > "${plane_dir}/_config/knowledge.json" <<CFG
{
  "version": 1,
  "trust": {
    "auto_promote": {
      "from_paths": [],
      "from_emails": ["trusted@example.com"],
      "from_bots": ["my-internal-bot"]
    },
    "review_gate": {
      "from_emails": ["partner@example.com"]
    },
    "untrusted": "*"
  }
}
CFG
	return 0
}

# Run helper with KNOWLEDGE_ROOT overridden to a temp subdirectory
run_helper() {
	local plane_dir="$1"
	shift
	# Override KNOWLEDGE_ROOT to the plane dir name, CWD to its parent
	local plane_parent plane_name
	plane_parent="$(dirname "$plane_dir")"
	plane_name="$(basename "$plane_dir")"

	(
		cd "$plane_parent" || exit 1
		KNOWLEDGE_ROOT="$plane_name" \
		REPOS_FILE="/dev/null" \
		LOGFILE="/dev/null" \
		bash "$HELPER" "$@" 2>/dev/null
	)
	return $?
}

# ---------------------------------------------------------------------------
# Test 1: shellcheck zero violations
# ---------------------------------------------------------------------------

test_shellcheck() {
	local name="shellcheck: knowledge-review-helper.sh zero violations"
	if ! command -v shellcheck &>/dev/null; then
		pass "$name (shellcheck not installed, skipped)"
		return 0
	fi
	if shellcheck "$HELPER" 2>/dev/null; then
		pass "$name"
	else
		fail "$name" "shellcheck reported violations"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Test 2: auto-promotion — trusted meta field → inbox goes straight to sources
# ---------------------------------------------------------------------------

test_auto_promote_trusted_meta() {
	local name="tick: trusted meta field → auto-promoted to sources/"
	local plane="${TEST_TMPDIR}/t2"
	make_plane "$plane"
	make_trust_config "$plane"
	make_source "$plane" "src-trusted-001" "trusted" "unknown"

	run_helper "$plane" tick

	if [[ -d "${plane}/sources/src-trusted-001" ]]; then
		pass "$name"
	else
		fail "$name" "expected sources/src-trusted-001 to exist"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Test 3: legacy review-file state path — unverified source moves to staging + audit entry
# ---------------------------------------------------------------------------

test_untrusted_staged_and_audited() {
	local name="tick: unverified source → moved to staging + audit-logged"
	local plane="${TEST_TMPDIR}/t3"
	make_plane "$plane"
	make_trust_config "$plane"
	make_source "$plane" "src-untrusted-001" "unverified" "stranger@external.com"

	run_helper "$plane" tick

	local in_staging audit_count
	if [[ -d "${plane}/staging/src-untrusted-001" ]]; then
		in_staging=1
	else
		in_staging=0
	fi

	audit_count=$(grep -c '"staged_no_slug"\|"nmr_filed"\|"nmr_file_failed"' \
		"${plane}/index/audit.log" 2>/dev/null || echo "0")
	[[ "$audit_count" =~ ^[0-9]+$ ]] || audit_count=0

	if [[ "$in_staging" -eq 1 && "$audit_count" -ge 1 ]]; then
		pass "$name"
	else
		fail "$name" "in_staging=${in_staging} audit_count=${audit_count}"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Test 4: review_gate — partner email moves to staging, audit entry
# ---------------------------------------------------------------------------

test_review_gate_staged() {
	local name="tick: review_gate email → staged + audit-logged (no GH slug)"
	local plane="${TEST_TMPDIR}/t4"
	make_plane "$plane"
	make_trust_config "$plane"
	make_source "$plane" "src-rg-001" "unverified" "partner@example.com"

	run_helper "$plane" tick

	local in_staging audit_count
	[[ -d "${plane}/staging/src-rg-001" ]] && in_staging=1 || in_staging=0

	audit_count=$(grep -c '"staged_no_slug"\|"nmr_filed"\|"nmr_file_failed"' \
		"${plane}/index/audit.log" 2>/dev/null || echo "0")
	[[ "$audit_count" =~ ^[0-9]+$ ]] || audit_count=0

	if [[ "$in_staging" -eq 1 && "$audit_count" -ge 1 ]]; then
		pass "$name"
	else
		fail "$name" "in_staging=${in_staging} audit_count=${audit_count}"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Test 5: idempotent tick — re-run on already-staged source does not re-stage
# ---------------------------------------------------------------------------

test_idempotent_tick() {
	local name="tick: idempotent — re-run does not double-process staged sources"
	local plane="${TEST_TMPDIR}/t5"
	make_plane "$plane"
	make_trust_config "$plane"
	make_source "$plane" "src-idem-001" "unverified" "nobody"

	# First tick — should stage
	run_helper "$plane" tick

	# Patch state to "nmr_filed" (simulates already-processed)
	local meta="${plane}/staging/src-idem-001/meta.json"
	if [[ -f "$meta" ]]; then
		local tmp
		tmp=$(mktemp)
		jq '.state = "nmr_filed"' "$meta" > "$tmp" && mv "$tmp" "$meta"
	fi

	# Count audit entries before second tick
	local count_before count_after
	count_before=$(wc -l < "${plane}/index/audit.log" 2>/dev/null || echo "0")
	[[ "$count_before" =~ ^[0-9]+$ ]] || count_before=0

	# Second tick — should skip (already staged)
	run_helper "$plane" tick

	count_after=$(wc -l < "${plane}/index/audit.log" 2>/dev/null || echo "0")
	[[ "$count_after" =~ ^[0-9]+$ ]] || count_after=0

	if [[ "$count_after" -eq "$count_before" ]]; then
		pass "$name"
	else
		fail "$name" "audit grew from ${count_before} to ${count_after} on second tick"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Test 6: promote subcommand — staging -> sources + meta state updated
# ---------------------------------------------------------------------------

test_promote_subcommand() {
	local name="promote: moves staging/src -> sources/, sets meta.state=promoted"
	local plane="${TEST_TMPDIR}/t6"
	make_plane "$plane"
	make_trust_config "$plane"

	# Place source directly in staging (simulates already-staged)
	mkdir -p "${plane}/staging/src-promo-001"
	cat > "${plane}/staging/src-promo-001/meta.json" <<META
{"id":"src-promo-001","kind":"document","state":"nmr_filed","sha256":"abc","size_bytes":512}
META

	run_helper "$plane" promote "src-promo-001"

	local in_sources state
	[[ -d "${plane}/sources/src-promo-001" ]] && in_sources=1 || in_sources=0
	state=$(jq -r '.state // ""' "${plane}/sources/src-promo-001/meta.json" 2>/dev/null) \
		|| state=""

	if [[ "$in_sources" -eq 1 && "$state" == "promoted" ]]; then
		pass "$name"
	else
		fail "$name" "in_sources=${in_sources} state=${state}"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Test 7: audit-log subcommand — appends JSONL record
# ---------------------------------------------------------------------------

test_audit_log_subcommand() {
	local name="audit-log: appends JSONL record to index/audit.log"
	local plane="${TEST_TMPDIR}/t7"
	make_plane "$plane"

	run_helper "$plane" audit-log "test_action" "src-audit-001" "extra=hello"

	local audit_file="${plane}/index/audit.log"
	if [[ ! -f "$audit_file" ]]; then
		fail "$name" "audit.log not created"
		return 0
	fi

	local action_found source_found
	action_found=$(grep -c '"test_action"' "$audit_file" 2>/dev/null || echo "0")
	[[ "$action_found" =~ ^[0-9]+$ ]] || action_found=0
	source_found=$(grep -c '"src-audit-001"' "$audit_file" 2>/dev/null || echo "0")
	[[ "$source_found" =~ ^[0-9]+$ ]] || source_found=0

	if [[ "$action_found" -ge 1 && "$source_found" -ge 1 ]]; then
		pass "$name"
	else
		fail "$name" "expected action+source in audit.log (action_found=${action_found} source_found=${source_found})"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Test 8: trusted bot ingested_by → auto-promote
# ---------------------------------------------------------------------------

test_auto_promote_trusted_bot() {
	local name="tick: trusted bot in config → auto-promoted to sources/"
	local plane="${TEST_TMPDIR}/t8"
	make_plane "$plane"
	make_trust_config "$plane"
	make_source "$plane" "src-bot-001" "unverified" "my-internal-bot"

	run_helper "$plane" tick

	if [[ -d "${plane}/sources/src-bot-001" ]]; then
		pass "$name"
	else
		fail "$name" "expected sources/src-bot-001 to exist"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Test 9: authoritative meta trust → auto-promote
# ---------------------------------------------------------------------------

test_auto_promote_authoritative() {
	local name="tick: authoritative meta trust → auto-promoted to sources/"
	local plane="${TEST_TMPDIR}/t9"
	make_plane "$plane"
	make_trust_config "$plane"
	make_source "$plane" "src-auth-001" "authoritative" "someone"

	run_helper "$plane" tick

	if [[ -d "${plane}/sources/src-auth-001" ]]; then
		pass "$name"
	else
		fail "$name" "expected sources/src-auth-001 to exist"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Test 10: missing meta.json — skipped gracefully (no crash)
# ---------------------------------------------------------------------------

test_missing_meta() {
	local name="tick: inbox dir without meta.json — skipped gracefully"
	local plane="${TEST_TMPDIR}/t10"
	make_plane "$plane"
	make_trust_config "$plane"

	# Inbox entry with no meta.json
	mkdir -p "${plane}/inbox/src-nometa-001"
	printf 'raw content\n' > "${plane}/inbox/src-nometa-001/data.txt"

	local exit_rc=0
	run_helper "$plane" tick || exit_rc=$?

	# Source should still be in inbox (not processed)
	if [[ -d "${plane}/inbox/src-nometa-001" && "$exit_rc" -eq 0 ]]; then
		pass "$name"
	else
		fail "$name" "exit_rc=${exit_rc} inbox_still_exists=$(test -d "${plane}/inbox/src-nometa-001" && echo 1 || echo 0)"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Test 11: untrusted review issues use an explicit content-review hold
# ---------------------------------------------------------------------------

test_untrusted_review_issue_labels() {
	local name="untrusted review issue uses hold-for-review without NMR"
	local plane="${TEST_TMPDIR}/t11"
	local label_log="${TEST_TMPDIR}/t11-labels.log"
	local body_log="${TEST_TMPDIR}/t11-body.md"
	make_plane "$plane"
	make_trust_config "$plane"
	make_source "$plane" "src-held-001" "unverified" "stranger@external.com"
	mv "${plane}/inbox/src-held-001" "${plane}/staging/src-held-001"

	LABEL_LOG="$label_log" BODY_LOG="$body_log" PLANE="$plane" HELPER_PATH="$HELPER" bash -c '
		set -euo pipefail
		source "$HELPER_PATH"
		gh_create_issue() {
			local expect=""
			local arg=""
			for arg in "$@"; do
				if [[ "$expect" == "label" ]]; then
					printf "%s\n" "$arg" >"$LABEL_LOG"
					expect=""
				elif [[ "$expect" == "body" ]]; then
					cp "$arg" "$BODY_LOG"
					expect=""
				elif [[ "$arg" == "--label" ]]; then
					expect="label"
				elif [[ "$arg" == "--body-file" ]]; then
					expect="body"
				fi
			done
			printf "https://github.com/owner/repo/issues/123\n"
			return 0
		}
		meta_json=$(jq "." "$PLANE/staging/src-held-001/meta.json")
		_file_nmr_issue "$PLANE" "src-held-001" "$meta_json" "untrusted" "owner/repo" >/dev/null
	' 2>/dev/null

	local labels=""
	labels=$(<"$label_log")
	if [[ "$labels" == *"hold-for-review"* && "$labels" != *"needs-maintainer-review"* ]] \
		&& grep -qF 'knowledge-review-helper.sh promote src-held-001' "$body_log" \
		&& ! grep -qF 'sudo aidevops approve issue' "$body_log"; then
		pass "$name"
	else
		fail "$name" "labels=${labels}"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------

main() {
	setup

	test_shellcheck
	test_auto_promote_trusted_meta
	test_untrusted_staged_and_audited
	test_review_gate_staged
	test_idempotent_tick
	test_promote_subcommand
	test_audit_log_subcommand
	test_auto_promote_trusted_bot
	test_auto_promote_authoritative
	test_missing_meta
	test_untrusted_review_issue_labels

	teardown

	echo ""
	echo "Results: $PASS passed, $FAIL failed"
	if [[ "$FAIL" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"

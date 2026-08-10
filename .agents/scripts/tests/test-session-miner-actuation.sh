#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Regression coverage for GH#29888 role routing, privacy, and fingerprint dedup.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)" || exit 1
ACTUATION_HELPER="${REPO_ROOT}/.agents/scripts/session-miner-actuation-helper.sh"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT

REPOS_JSON="${TEST_ROOT}/repos.json"
SIGNALS_JSON="${TEST_ROOT}/signals.json"
TRANSPORT_LOG="${TEST_ROOT}/transport.log"
FAKE_FRAMEWORK_HELPER="${TEST_ROOT}/framework-issue-helper.sh"
FAKE_CONTRIBUTOR_HELPER="${TEST_ROOT}/contributor-insight-helper.sh"

cat >"$REPOS_JSON" <<JSON
{
  "initialized_repos": [
    {"slug":"marcusquinn/aidevops","path":"${REPO_ROOT}","role":"maintainer","pulse":true},
    {"slug":"example/public-upstream","path":"${REPO_ROOT}","role":"contributor","pulse":true,"local_only":false},
    {"slug":"example/private-upstream","path":"${REPO_ROOT}","role":"contributor","pulse":true,"local_only":true},
    {"slug":"example/unknown","path":"${REPO_ROOT}","pulse":true}
  ]
}
JSON

cat >"$SIGNALS_JSON" <<'JSON'
{
  "instruction_candidates": {
    ".agents/AGENTS.md": [
      {
        "text":"Always retain raw private client wording",
        "display_text":"Prefer one deterministic scheduling path.",
        "confidence":0.9,
        "category":"workflow",
        "fingerprint":"stable-safe-candidate",
        "qualification_basis":"recurring",
        "requires_judgment":false,
        "support":3,
        "first_seen":1000,
        "last_seen":2000
      },
      {
        "display_text":"Contradictory guidance.",
        "confidence":0.99,
        "category":"workflow",
        "fingerprint":"conflicted-candidate",
        "qualification_basis":"recurring",
        "requires_judgment":true,
        "support":4
      }
    ],
    "../private/path": [
      {
        "display_text":"Unknown target.",
        "confidence":0.99,
        "fingerprint":"unknown-target",
        "qualification_basis":"explicit_persistence",
        "requires_judgment":false,
        "support":1
      }
    ]
  },
  "errors":{"patterns":[]}
}
JSON

cat >"$FAKE_FRAMEWORK_HELPER" <<'SH'
#!/usr/bin/env bash
printf '%s' "$*" | tr '\n' ' ' >>"${TRANSPORT_LOG:?}"
printf '\n' >>"${TRANSPORT_LOG:?}"
[[ "${FAKE_FRAMEWORK_UNCONFIRMED:-0}" == "1" ]] || printf 'status=created\n'
exit 0
SH
cat >"$FAKE_CONTRIBUTOR_HELPER" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${TRANSPORT_LOG:?}"
printf '{"status":"healthy","fingerprints":["contributor-receipt"]}\n'
exit 0
SH
chmod +x "$FAKE_FRAMEWORK_HELPER" "$FAKE_CONTRIBUTOR_HELPER"

maintainer_result=$(
	TRANSPORT_LOG="$TRANSPORT_LOG" \
		SESSION_MINER_FRAMEWORK_HELPER="$FAKE_FRAMEWORK_HELPER" \
		bash "$ACTUATION_HELPER" maintainer \
		--signals "$SIGNALS_JSON" --repos "$REPOS_JSON" --known-fingerprints '[]'
)
printf '%s' "$maintainer_result" | jq -e '
    .status == "healthy" and
    .selected == 1 and
    (.fingerprints | length) == 1
' >/dev/null
[[ $(wc -l <"$TRANSPORT_LOG" | tr -d ' ') == "1" ]]
if grep -q 'raw private client wording\|conflicted-candidate\|unknown-target' "$TRANSPORT_LOG"; then
	printf 'maintainer actuation leaked or routed an unsafe candidate\n' >&2
	exit 1
fi
grep -q 'Prefer one deterministic scheduling path' "$TRANSPORT_LOG"
grep -q '## Verification' "$TRANSPORT_LOG"

known_fingerprints=$(printf '%s' "$maintainer_result" | jq -c '.fingerprints')
TRANSPORT_LOG="$TRANSPORT_LOG" \
	SESSION_MINER_FRAMEWORK_HELPER="$FAKE_FRAMEWORK_HELPER" \
	bash "$ACTUATION_HELPER" maintainer \
	--signals "$SIGNALS_JSON" --repos "$REPOS_JSON" --known-fingerprints "$known_fingerprints" >/dev/null
[[ $(wc -l <"$TRANSPORT_LOG" | tr -d ' ') == "1" ]]

if TRANSPORT_LOG="$TRANSPORT_LOG" FAKE_FRAMEWORK_UNCONFIRMED=1 \
	SESSION_MINER_FRAMEWORK_HELPER="$FAKE_FRAMEWORK_HELPER" \
	bash "$ACTUATION_HELPER" maintainer \
	--signals "$SIGNALS_JSON" --repos "$REPOS_JSON" --known-fingerprints '[]' >/dev/null 2>&1; then
	printf 'unconfirmed maintainer publication should fail closed\n' >&2
	exit 1
fi

MALFORMED_SIGNALS="${TEST_ROOT}/malformed-signals.json"
jq '.instruction_candidates = "invalid"' "$SIGNALS_JSON" >"$MALFORMED_SIGNALS"
before_malformed=$(wc -l <"$TRANSPORT_LOG" | tr -d ' ')
if TRANSPORT_LOG="$TRANSPORT_LOG" SESSION_MINER_FRAMEWORK_HELPER="$FAKE_FRAMEWORK_HELPER" \
	bash "$ACTUATION_HELPER" maintainer \
	--signals "$MALFORMED_SIGNALS" --repos "$REPOS_JSON" --known-fingerprints '[]' >/dev/null 2>&1; then
	printf 'malformed candidate schema should fail closed\n' >&2
	exit 1
fi
after_malformed=$(wc -l <"$TRANSPORT_LOG" | tr -d ' ')
[[ "$before_malformed" == "$after_malformed" ]]

contributor_result=$(
	TRANSPORT_LOG="$TRANSPORT_LOG" \
		SESSION_MINER_CONTRIBUTOR_HELPER="$FAKE_CONTRIBUTOR_HELPER" \
		bash "$ACTUATION_HELPER" contributor \
		--signals "$SIGNALS_JSON" --repos "$REPOS_JSON" --slug example/public-upstream
)
printf '%s' "$contributor_result" | jq -e '.status == "healthy"' >/dev/null
grep -q 'example/public-upstream' "$TRANSPORT_LOG"

before_blocked=$(wc -l <"$TRANSPORT_LOG" | tr -d ' ')
if TRANSPORT_LOG="$TRANSPORT_LOG" SESSION_MINER_CONTRIBUTOR_HELPER="$FAKE_CONTRIBUTOR_HELPER" \
	bash "$ACTUATION_HELPER" contributor \
	--signals "$SIGNALS_JSON" --repos "$REPOS_JSON" --slug example/private-upstream >/dev/null 2>&1; then
	printf 'private contributor target should fail closed\n' >&2
	exit 1
fi
if TRANSPORT_LOG="$TRANSPORT_LOG" SESSION_MINER_CONTRIBUTOR_HELPER="$FAKE_CONTRIBUTOR_HELPER" \
	bash "$ACTUATION_HELPER" contributor \
	--signals "$SIGNALS_JSON" --repos "$REPOS_JSON" --slug example/unknown >/dev/null 2>&1; then
	printf 'unknown contributor role should fail closed\n' >&2
	exit 1
fi
after_blocked=$(wc -l <"$TRANSPORT_LOG" | tr -d ' ')
[[ "$before_blocked" == "$after_blocked" ]]

printf 'session-miner actuation tests passed\n'

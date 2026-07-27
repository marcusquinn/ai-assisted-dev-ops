#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)" || exit 1
WORKFLOW="${REPO_ROOT}/.github/workflows/publish-packages.yml"
TEST_ROOT=$(mktemp -d)
TEST_BIN="${TEST_ROOT}/bin"
EXTRACTED="${TEST_ROOT}/steps"
FIXTURE_ROOT="${TEST_ROOT}/fixture"
COMMAND_LOG="${TEST_ROOT}/commands.log"
COUNT_FILE="${TEST_ROOT}/count"
GITHUB_OUTPUT="${TEST_ROOT}/github-output"

cleanup() {
	rm -rf "$TEST_ROOT"
	return 0
}
trap cleanup EXIT

mkdir -p "$TEST_BIN" "$EXTRACTED" "${FIXTURE_ROOT}/homebrew" "${TEST_ROOT}/runner"
printf '%s\n' 'class Aidevops' '  url "https://example.invalid/aidevops.tar.gz"' 'end' \
	>"${FIXTURE_ROOT}/homebrew/aidevops.rb"

python3 - "$WORKFLOW" "$EXTRACTED" <<'PY'
import pathlib
import sys
import yaml

workflow_path = pathlib.Path(sys.argv[1])
output_dir = pathlib.Path(sys.argv[2])
required = {
    "Check npm publication state": "npm-state.sh",
    "Verify npm publication": "npm-verify.sh",
    "Check Homebrew tap state": "homebrew-state.sh",
    "Verify Homebrew tap": "homebrew-verify.sh",
}
workflow = yaml.safe_load(workflow_path.read_text(encoding="utf-8"))
matches = {name: [] for name in required}
for job in workflow.get("jobs", {}).values():
    for step in job.get("steps", []):
        name = step.get("name")
        if name in matches:
            matches[name].append(step.get("run"))
for name, filename in required.items():
    scripts = matches[name]
    if len(scripts) != 1 or not isinstance(scripts[0], str) or not scripts[0].strip():
        raise SystemExit(f"expected one scalar run block for step: {name}")
    target = output_dir / filename
    target.write_text("#!/usr/bin/env bash\nset -euo pipefail\n" + scripts[0], encoding="utf-8")
    target.chmod(0o755)
PY

EXPECTED_INTEGRITY="sha512-$(printf 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA==')"
EXPECTED_SHASUM="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
EXACT_NPM_JSON="${TEST_ROOT}/npm-exact.json"
AUDIT_JSON="${TEST_ROOT}/npm-audit.json"
FORMULA_BASE64="${TEST_ROOT}/formula.base64"
DRIFT_BASE64="${TEST_ROOT}/drift.base64"
base64 <"${FIXTURE_ROOT}/homebrew/aidevops.rb" | tr -d '\n' >"$FORMULA_BASE64"
printf '%s\n' 'class Aidevops' '  url "https://example.invalid/drift.tar.gz"' 'end' |
	base64 | tr -d '\n' >"$DRIFT_BASE64"

python3 - "$EXACT_NPM_JSON" "$AUDIT_JSON" "$EXPECTED_INTEGRITY" <<'PY'
import base64
import json
import pathlib
import sys

metadata_path = pathlib.Path(sys.argv[1])
audit_path = pathlib.Path(sys.argv[2])
integrity = sys.argv[3]
version = "1.2.3"
predicate = "https://slsa.dev/provenance/v1"
metadata = {
    "version": version,
    "dist": {
        "integrity": integrity,
        "shasum": "a" * 40,
        "attestations": {"provenance": {"predicateType": predicate}, "url": "https://example.invalid/attestation"},
    },
}
provenance = {
    "_type": "https://in-toto.io/Statement/v1",
    "predicateType": predicate,
    "subject": [{"name": "pkg:npm/aidevops@1.2.3", "digest": {"sha512": "0" * 128}}],
    "predicate": {
        "buildDefinition": {
            "buildType": "https://slsa-framework.github.io/github-actions-buildtypes/workflow/v1",
            "externalParameters": {"workflow": {
                "repository": "https://github.com/marcusquinn/aidevops",
                "path": ".github/workflows/publish-packages.yml",
                "ref": "refs/tags/v1.2.3",
            }},
        },
        "runDetails": {"builder": {"id": "https://github.com/actions/runner/github-hosted"}},
    },
}
payload = base64.b64encode(json.dumps(provenance).encode()).decode()
audit = {
    "invalid": [],
    "missing": [],
    "verified": [{
        "name": "aidevops",
        "version": version,
        "attestations": {"provenance": {"predicateType": predicate}},
        "attestationBundles": [{"predicateType": predicate, "bundle": {"dsseEnvelope": {"payload": payload}}}],
    }],
}
metadata_path.write_text(json.dumps(metadata), encoding="utf-8")
audit_path.write_text(json.dumps(audit), encoding="utf-8")
PY

cat >"${TEST_BIN}/npm" <<'STUB'
#!/usr/bin/env bash
set -u
printf 'npm %s\n' "$*" >>"$COMMAND_LOG"
if [[ "${1:-}" == "publish" ]]; then
	printf 'unexpected npm publish\n' >&2
	exit 97
fi
if [[ "${1:-}" == "view" ]]; then
	count=0
	[[ -f "$COUNT_FILE" ]] && count=$(<"$COUNT_FILE")
	count=$((count + 1))
	printf '%s\n' "$count" >"$COUNT_FILE"
	case "$TEST_MODE" in
	npm-state-exact)
		cat "$EXACT_NPM_JSON"
		;;
	npm-state-e404)
		printf 'npm error code E404\n' >&2
		exit 1
		;;
	npm-state-drift)
		printf '%s\n' '{"version":"1.2.3","dist":{"integrity":"sha512-drift","shasum":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}'
		;;
	npm-state-malformed)
		printf '%s\n' 'not-json'
		;;
	npm-state-transport | npm-verify-transport)
		printf 'registry unavailable\n' >&2
		exit 1
		;;
	npm-verify-eventual)
		if [[ "$count" -lt 2 ]]; then
			printf '%s\n' '{"version":"1.2.3","dist":{"integrity":"sha512-drift"}}'
		else
			cat "$EXACT_NPM_JSON"
		fi
		;;
	npm-verify-mismatch)
		printf '%s\n' '{"version":"1.2.3","dist":{"integrity":"sha512-drift"}}'
		;;
	*)
		printf 'unexpected npm test mode: %s\n' "$TEST_MODE" >&2
		exit 1
		;;
	esac
	exit 0
fi
if [[ "${1:-}" == "install" ]]; then
	exit 0
fi
if [[ "${1:-}" == "--prefix" ]]; then
	cat "$AUDIT_JSON"
	exit 0
fi
printf 'unexpected npm arguments: %s\n' "$*" >&2
exit 1
STUB

cat >"${TEST_BIN}/gh" <<'STUB'
#!/usr/bin/env bash
set -u
printf 'gh %s\n' "$*" >>"$COMMAND_LOG"
[[ "${1:-}" == "api" ]] || exit 1
count=0
[[ -f "$COUNT_FILE" ]] && count=$(<"$COUNT_FILE")
count=$((count + 1))
printf '%s\n' "$count" >"$COUNT_FILE"
if [[ " $* " == *" --jq "* ]]; then
	case "$TEST_MODE" in
	homebrew-verify-eventual)
		if [[ "$count" -lt 2 ]]; then cat "$DRIFT_BASE64"; else cat "$FORMULA_BASE64"; fi
		;;
	homebrew-verify-mismatch)
		cat "$DRIFT_BASE64"
		;;
	homebrew-verify-transport)
		printf 'tap unavailable\n' >&2
		exit 1
		;;
	*)
		printf 'unexpected Homebrew verification mode: %s\n' "$TEST_MODE" >&2
		exit 1
		;;
	esac
	exit 0
fi
case "$TEST_MODE" in
homebrew-state-exact)
	printf '{"content":"%s"}\n' "$(<"$FORMULA_BASE64")"
	;;
homebrew-state-drift)
	printf '{"content":"%s"}\n' "$(<"$DRIFT_BASE64")"
	;;
homebrew-state-malformed)
	printf '%s\n' '{"content":"%%%"}'
	;;
homebrew-state-transport)
	printf 'tap unavailable\n' >&2
	exit 1
	;;
*)
	printf 'unexpected Homebrew state mode: %s\n' "$TEST_MODE" >&2
	exit 1
	;;
esac
exit 0
STUB

cat >"${TEST_BIN}/sleep" <<'STUB'
#!/usr/bin/env bash
set -u
printf 'sleep %s\n' "$*" >>"$COMMAND_LOG"
exit 0
STUB
chmod +x "${TEST_BIN}/npm" "${TEST_BIN}/gh" "${TEST_BIN}/sleep"

run_step() {
	local mode="$1"
	local script="$2"
	rm -f "$COUNT_FILE"
	: >"$GITHUB_OUTPUT"
	(
		cd "$FIXTURE_ROOT" || exit 1
		TEST_MODE="$mode" COMMAND_LOG="$COMMAND_LOG" COUNT_FILE="$COUNT_FILE" \
			EXACT_NPM_JSON="$EXACT_NPM_JSON" AUDIT_JSON="$AUDIT_JSON" \
			FORMULA_BASE64="$FORMULA_BASE64" DRIFT_BASE64="$DRIFT_BASE64" \
			GITHUB_OUTPUT="$GITHUB_OUTPUT" RUNNER_TEMP="${TEST_ROOT}/runner" \
			RELEASE_VERSION="1.2.3" EXPECTED_INTEGRITY="$EXPECTED_INTEGRITY" \
			EXPECTED_SHASUM="$EXPECTED_SHASUM" RELEASE_TAG="v1.2.3" \
			GITHUB_SERVER_URL="https://github.com" GITHUB_REPOSITORY="marcusquinn/aidevops" \
			PATH="${TEST_BIN}:${PATH}" bash "${EXTRACTED}/${script}"
	)
	return $?
}

expect_success() {
	local name="$1"
	local mode="$2"
	local script="$3"
	if ! run_step "$mode" "$script"; then
		printf 'FAIL %s\n' "$name"
		return 1
	fi
	printf 'PASS %s\n' "$name"
	return 0
}

expect_failure() {
	local name="$1"
	local mode="$2"
	local script="$3"
	if run_step "$mode" "$script" >/dev/null 2>&1; then
		printf 'FAIL %s\n' "$name"
		return 1
	fi
	printf 'PASS %s\n' "$name"
	return 0
}

expect_success "exact npm identity is already published" "npm-state-exact" "npm-state.sh"
grep -qxF 'published=true' "$GITHUB_OUTPUT"
expect_success "npm E404 is an absent publication" "npm-state-e404" "npm-state.sh"
grep -qxF 'published=false' "$GITHUB_OUTPUT"
expect_failure "npm identity drift fails closed" "npm-state-drift" "npm-state.sh"
expect_failure "malformed npm metadata fails closed" "npm-state-malformed" "npm-state.sh"
expect_failure "npm transport failure is uncertain" "npm-state-transport" "npm-state.sh"
expect_success "npm verification accepts eventual exact convergence" "npm-verify-eventual" "npm-verify.sh"
expect_failure "npm verification rejects persistent mismatch" "npm-verify-mismatch" "npm-verify.sh"
expect_failure "npm verification rejects persistent transport failure" "npm-verify-transport" "npm-verify.sh"

expect_success "exact Homebrew formula is current" "homebrew-state-exact" "homebrew-state.sh"
grep -qxF 'current=true' "$GITHUB_OUTPUT"
expect_success "drifted Homebrew formula is not current" "homebrew-state-drift" "homebrew-state.sh"
grep -qxF 'current=false' "$GITHUB_OUTPUT"
expect_failure "malformed Homebrew content fails closed" "homebrew-state-malformed" "homebrew-state.sh"
expect_failure "Homebrew API failure is uncertain" "homebrew-state-transport" "homebrew-state.sh"
expect_success "Homebrew verification accepts eventual exact convergence" \
	"homebrew-verify-eventual" "homebrew-verify.sh"
expect_failure "Homebrew verification rejects persistent mismatch" \
	"homebrew-verify-mismatch" "homebrew-verify.sh"
expect_failure "Homebrew verification rejects persistent transport failure" \
	"homebrew-verify-transport" "homebrew-verify.sh"

if grep -qE '^npm publish|^gh .* (--method|-X |PUT|PATCH|POST)' "$COMMAND_LOG"; then
	printf 'FAIL destination-state tests attempted a package or tap write\n'
	exit 1
fi
printf 'PASS destination-state tests execute only read and test-local commands\n'

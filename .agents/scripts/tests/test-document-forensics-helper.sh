#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
HELPER="${SCRIPT_DIR}/../document-creation-helper.sh"
CORE_LIB="${SCRIPT_DIR}/../document-creation-core-lib.sh"
FORENSICS_LIB="${SCRIPT_DIR}/../document-forensics-lib.sh"
FIXTURE_SOURCE_DIR="${SCRIPT_DIR}/fixtures/document-forensics"
TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

RUNNER_DIR="${TMPDIR_TEST}/runners"
BIN_DIR="${TMPDIR_TEST}/bin"
FIXTURE_DIR="${TMPDIR_TEST}/fixtures with spaces"
OUTPUT_DIR="${TMPDIR_TEST}/outputs with spaces"
export AIDEVOPS_TEMP_DIR="${TMPDIR_TEST}/workspace"
mkdir -p "$RUNNER_DIR" "$BIN_DIR" "$FIXTURE_DIR" "$OUTPUT_DIR" "$AIDEVOPS_TEMP_DIR"
cp "${FIXTURE_SOURCE_DIR}"/*.sh "$RUNNER_DIR/"
chmod 700 "${RUNNER_DIR}"/*.sh
ln -s "${RUNNER_DIR}/poppler-stub.sh" "${BIN_DIR}/pdfinfo"
ln -s "${RUNNER_DIR}/poppler-stub.sh" "${BIN_DIR}/pdftotext"
ln -s "${RUNNER_DIR}/poppler-stub.sh" "${BIN_DIR}/pdftoppm"
ln -s "${RUNNER_DIR}/poppler-stub.sh" "${BIN_DIR}/pdfseparate"
ln -s "${RUNNER_DIR}/failing-tesseract.sh" "${BIN_DIR}/tesseract"

export PATH="${BIN_DIR}:${PATH}"
export DOCUMENT_FORENSICS_IMAGE_RUNNER="${RUNNER_DIR}/image-runner.sh"
export DOCUMENT_FORENSICS_OCR_RUNNER="${RUNNER_DIR}/ocr-runner.sh"
export DOCUMENT_FORENSICS_OCR_VERSION="fixture-1"
export DOCUMENT_FORENSICS_PDF_RUNNER="${RUNNER_DIR}/pdf-runner.sh"
export DOCUMENT_FORENSICS_PDF_ASSEMBLER="${RUNNER_DIR}/pdf-assembler.sh"

pass_count=0
fail_count=0

pass() {
	local name="$1"
	printf 'PASS: %s\n' "$name"
	pass_count=$((pass_count + 1))
	return 0
}

fail() {
	local name="$1"
	local detail="${2:-}"
	printf 'FAIL: %s%s\n' "$name" "${detail:+ — $detail}"
	fail_count=$((fail_count + 1))
	return 0
}

create_fixture() {
	local name="$1"
	local kind="$2"
	local pages="$3"
	printf 'PAGES=%s\nKIND=%s\n' "$pages" "$kind" >"${FIXTURE_DIR}/${name}.pdf"
	return 0
}

file_hash() {
	local file="$1"
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$file" | awk '{ value = $1 } END { print value }'
		return 0
	fi
	if command -v shasum >/dev/null 2>&1; then
		shasum -a 256 "$file" | awk '{ value = $1 } END { print value }'
		return 0
	fi
	return 1
}

assert_jq() {
	local name="$1"
	local file="$2"
	local expression="$3"
	if jq -e "$expression" "$file" >/dev/null 2>&1; then
		pass "$name"
	else
		fail "$name" "jq expression failed: ${expression}"
	fi
	return 0
}

assert_file_exists() {
	local name="$1"
	local file="$2"
	if [[ -f "$file" ]]; then
		pass "$name"
	else
		fail "$name" "missing ${file}"
	fi
	return 0
}

assert_file_absent() {
	local name="$1"
	local file="$2"
	if [[ ! -e "$file" ]]; then
		pass "$name"
	else
		fail "$name" "unexpected ${file}"
	fi
	return 0
}

assert_contains() {
	local name="$1"
	local file="$2"
	local expected="$3"
	if grep -Fq "$expected" "$file"; then
		pass "$name"
	else
		fail "$name" "missing ${expected}"
	fi
	return 0
}

assert_source_unchanged() {
	local name="$1"
	local file="$2"
	local before="$3"
	local after=""
	after=$(file_hash "$file")
	if [[ "$before" == "$after" ]]; then
		pass "$name"
	else
		fail "$name" "source hash changed"
	fi
	return 0
}

run_forensics() {
	local name="$1"
	local fixture="$2"
	local output="$3"
	local expected_rc="$4"
	shift 4
	local rc=0
	set +e
	"$HELPER" forensics "$fixture" --output "$output" "$@" >/dev/null 2>&1
	rc=$?
	set -e
	if [[ "$rc" -eq "$expected_rc" ]]; then
		pass "${name}: expected exit ${expected_rc}"
	else
		fail "${name}: expected exit ${expected_rc}" "got ${rc}"
	fi
	return 0
}

assert_no_temp_artifacts() {
	local candidate=""
	for candidate in "${AIDEVOPS_TEMP_DIR}"/document-forensics.*; do
		if [[ -e "$candidate" ]]; then
			fail "temporary forensic workspaces are cleaned" "found ${candidate}"
			return 0
		fi
	done
	pass "temporary forensic workspaces are cleaned"
	return 0
}

assert_ocr_failure_propagates() {
	local image="$1"
	local rc=0
	set +e
	(
		SCRIPT_DIR="${SCRIPT_DIR}/.."
		VENV_DIR="${TMPDIR_TEST}/venv"
		TEMPLATE_DIR="${TMPDIR_TEST}/templates"
		LOG_DIR="${TMPDIR_TEST}/logs"
		RED='' GREEN='' YELLOW='' BLUE='' BOLD='' NC=''
		# shellcheck source=../document-creation-core-lib.sh
		# shellcheck disable=SC1090
		source "$CORE_LIB"
		run_ocr "$image" tesseract >/dev/null
	)
	rc=$?
	set -e
	if [[ "$rc" -ne 0 ]]; then
		pass "OCR backend failures propagate to callers"
	else
		fail "OCR backend failures propagate to callers"
	fi
	return 0
}

assert_scanned_ocr_is_atomic() {
	local fixture="$1"
	local output="${TMPDIR_TEST}/existing-ocr-output.txt"
	local rc=0
	local content=""
	printf 'preserve existing output\n' >"$output"
	set +e
	(
		SCRIPT_DIR="${SCRIPT_DIR}/.."
		VENV_DIR="${TMPDIR_TEST}/venv"
		TEMPLATE_DIR="${TMPDIR_TEST}/templates"
		LOG_DIR="${TMPDIR_TEST}/logs"
		RED='' GREEN='' YELLOW='' BLUE='' BOLD='' NC=''
		# shellcheck source=../document-creation-core-lib.sh
		# shellcheck disable=SC1090
		source "$CORE_LIB"
		ocr_scanned_pdf "$fixture" tesseract "$output" >/dev/null 2>&1
	)
	rc=$?
	set -e
	content=$(<"$output")
	if [[ "$rc" -ne 0 ]] && [[ "$content" == "preserve existing output" ]]; then
		pass "scanned-PDF OCR publishes output atomically"
	else
		fail "scanned-PDF OCR publishes output atomically" "rc=${rc} content=${content}"
	fi
	return 0
}

assert_scanned_ocr_rejects_directory() {
	local fixture="$1"
	local output="${TMPDIR_TEST}/ocr-output-directory"
	local rc=0
	mkdir -p "$output"
	set +e
	(
		SCRIPT_DIR="${SCRIPT_DIR}/.."
		VENV_DIR="${TMPDIR_TEST}/venv"
		TEMPLATE_DIR="${TMPDIR_TEST}/templates"
		LOG_DIR="${TMPDIR_TEST}/logs"
		RED='' GREEN='' YELLOW='' BLUE='' BOLD='' NC=''
		# shellcheck source=../document-creation-core-lib.sh
		# shellcheck disable=SC1090
		source "$CORE_LIB"
		ocr_scanned_pdf "$fixture" tesseract "$output" >/dev/null 2>&1
	)
	rc=$?
	set -e
	if [[ "$rc" -ne 0 ]] && [[ -d "$output" ]]; then
		pass "scanned-PDF OCR rejects a directory output path"
	else
		fail "scanned-PDF OCR rejects a directory output path" "rc=${rc}"
	fi
	return 0
}

assert_unverifiable_lock_owner_is_live() {
	local rc=0
	set +e
	(
		SCRIPT_DIR="${SCRIPT_DIR}/.."
		VENV_DIR="${TMPDIR_TEST}/venv"
		TEMPLATE_DIR="${TMPDIR_TEST}/templates"
		LOG_DIR="${TMPDIR_TEST}/logs"
		RED='' GREEN='' YELLOW='' BLUE='' BOLD='' NC=''
		# shellcheck source=../document-creation-core-lib.sh
		# shellcheck disable=SC1090
		source "$CORE_LIB"
		# shellcheck source=../document-forensics-lib.sh
		# shellcheck disable=SC1090
		source "$FORENSICS_LIB"
		kill() { return 1; }
		ps() { printf '424242\n'; return 0; }
		_df_lock_owner_is_live '424242:test'
	)
	rc=$?
	set -e
	if [[ "$rc" -eq 0 ]]; then
		pass "output lock treats an observable permission-denied PID as live"
	else
		fail "output lock treats an observable permission-denied PID as live"
	fi
	return 0
}

create_fixture searchable searchable 1
create_fixture mirrored mirrored 1
create_fixture rotated rotated 1
create_fixture mixed mixed 3
create_fixture sparse sparse 1
create_fixture normal-scan normal-scan 1
create_fixture partial partial 1
create_fixture mixed-failure mixed-failure 2
create_fixture original-fails original-fails 1
create_fixture invalid invalid 0
assert_ocr_failure_propagates "${FIXTURE_DIR}/mirrored.pdf"
assert_scanned_ocr_is_atomic "${FIXTURE_DIR}/mirrored.pdf"
assert_scanned_ocr_rejects_directory "${FIXTURE_DIR}/mirrored.pdf"
assert_unverifiable_lock_owner_is_live

preflight_output="${OUTPUT_DIR}/invalid"
preflight_readable="${preflight_output}/readable/invalid.pdf"
preflight_manifest="${preflight_output}/invalid.manifest.json"
mkdir -p "${preflight_output}/readable"
printf 'previous readable derivative\n' >"$preflight_readable"
printf '{"status":"complete"}\n' >"$preflight_manifest"
preflight_readable_hash=$(file_hash "$preflight_readable")
preflight_manifest_hash=$(file_hash "$preflight_manifest")
run_forensics "invalid preflight" "${FIXTURE_DIR}/invalid.pdf" "$preflight_output" 1 --write-readable
assert_source_unchanged "invalid preflight: readable output is preserved" "$preflight_readable" "$preflight_readable_hash"
assert_source_unchanged "invalid preflight: manifest is preserved" "$preflight_manifest" "$preflight_manifest_hash"
preflight_sidecar="${preflight_output}/invalid.txt"
preflight_transaction="${preflight_output}/.invalid.forensics.transaction"
mkdir "$preflight_transaction"
printf 'aidevops.document-forensics.transaction/v1\n' >"${preflight_transaction}/schema"
printf 'restored sidecar\n' >"${preflight_transaction}/sidecar.backup"
printf 'restored readable\n' >"${preflight_transaction}/readable.backup"
printf '{"status":"restored"}\n' >"${preflight_transaction}/manifest.backup"
: >"${preflight_transaction}/had-sidecar"
: >"${preflight_transaction}/had-readable"
: >"${preflight_transaction}/had-manifest"
: >"${preflight_transaction}/prepared"
preflight_sidecar_hash=$(file_hash "${preflight_transaction}/sidecar.backup")
preflight_readable_hash=$(file_hash "${preflight_transaction}/readable.backup")
preflight_manifest_hash=$(file_hash "${preflight_transaction}/manifest.backup")
printf 'interrupted sidecar\n' >"$preflight_sidecar"
printf 'interrupted readable\n' >"$preflight_readable"
printf '{"status":"interrupted"}\n' >"$preflight_manifest"
run_forensics "interrupted publication recovery" "${FIXTURE_DIR}/invalid.pdf" "$preflight_output" 1 --write-readable
assert_source_unchanged "interrupted publication: sidecar is restored" "$preflight_sidecar" "$preflight_sidecar_hash"
assert_source_unchanged "interrupted publication: readable PDF is restored" "$preflight_readable" "$preflight_readable_hash"
assert_source_unchanged "interrupted publication: manifest is restored" "$preflight_manifest" "$preflight_manifest_hash"
assert_file_absent "interrupted publication: transaction is cleared" "$preflight_transaction"

searchable_fixture="${FIXTURE_DIR}/searchable.pdf"
searchable_output="${OUTPUT_DIR}/searchable"
searchable_hash=$(file_hash "$searchable_fixture")
run_forensics searchable "$searchable_fixture" "$searchable_output" 0
searchable_manifest="${searchable_output}/searchable.manifest.json"
assert_jq "searchable: schema and complete status" "$searchable_manifest" '.schema == "aidevops.document-forensics/v1" and .status == "complete"'
assert_jq "searchable: healthy page remains unchanged" "$searchable_manifest" '.pages[0].classification == "searchable" and .pages[0].selected_transform == "original" and (.pages[0].ocr.performed | not)'
assert_jq "searchable: no repaired PDF by default" "$searchable_manifest" '.outputs.readable_pdf == null'
assert_file_absent "searchable: repaired copy is not emitted" "${searchable_output}/readable/searchable.pdf"
assert_source_unchanged "searchable: source hash unchanged" "$searchable_fixture" "$searchable_hash"
manifest_hash_before=$(file_hash "$searchable_manifest")
run_forensics "searchable rerun" "$searchable_fixture" "$searchable_output" 0
manifest_hash_after=$(file_hash "$searchable_manifest")
if [[ "$manifest_hash_before" == "$manifest_hash_after" ]]; then
	pass "searchable: rerun is manifest-idempotent"
else
	fail "searchable: rerun is manifest-idempotent"
fi
searchable_lock="${searchable_output}/.searchable.forensics.lock"
mkdir "$searchable_lock"
printf '%s:test\n' "$$" >"${searchable_lock}/owner"
locked_manifest_hash=$(file_hash "$searchable_manifest")
run_forensics "searchable live lock" "$searchable_fixture" "$searchable_output" 1
assert_source_unchanged "searchable: live lock preserves manifest" "$searchable_manifest" "$locked_manifest_hash"
if [[ -d "$searchable_lock" ]]; then
	pass "searchable: live owner lock is not removed"
else
	fail "searchable: live owner lock is not removed"
fi
rm -rf "$searchable_lock"
mkdir "$searchable_lock"
printf '99999999:stale\n' >"${searchable_lock}/owner"
run_forensics "searchable stale lock" "$searchable_fixture" "$searchable_output" 0
assert_file_absent "searchable: stale output lock is reclaimed" "$searchable_lock"
stale_lock_artifact=false
for candidate in "${searchable_lock}.stale."*; do
	[[ -e "$candidate" ]] && stale_lock_artifact=true
done
if [[ "$stale_lock_artifact" == false ]]; then
	pass "searchable: stale-lock rename leaves no blocking marker"
else
	fail "searchable: stale-lock rename leaves no blocking marker"
fi

mirrored_fixture="${FIXTURE_DIR}/mirrored.pdf"
mirrored_output="${OUTPUT_DIR}/mirrored"
mirrored_hash=$(file_hash "$mirrored_fixture")
run_forensics mirrored "$mirrored_fixture" "$mirrored_output" 0 --write-readable
mirrored_manifest="${mirrored_output}/mirrored.manifest.json"
assert_jq "mirrored: horizontal repair selected" "$mirrored_manifest" '.pages[0].classification == "mirrored" and .pages[0].selected_transform == "flip-horizontal" and .pages[0].improvement >= 15'
assert_jq "mirrored: all bounded candidates recorded" "$mirrored_manifest" '.pages[0].candidates | length == 5'
assert_jq "mirrored: dimensions are preserved" "$mirrored_manifest" '.pages[0].source_dimensions_points == {"width":612,"height":792} and .pages[0].derived_dimensions_points == .pages[0].source_dimensions_points'
assert_jq "mirrored: portable manifest paths" "$mirrored_manifest" '[.. | strings | select(startswith("/"))] | length == 0'
assert_file_exists "mirrored: searchable readable PDF emitted" "${mirrored_output}/readable/mirrored.pdf"
assert_contains "mirrored: sidecar cites page and transform" "${mirrored_output}/mirrored.txt" 'Page 1 [classification=mirrored transform=flip-horizontal]'
assert_source_unchanged "mirrored: source hash unchanged" "$mirrored_fixture" "$mirrored_hash"
export DOCUMENT_FORENSICS_PDF_RUNNER_FAIL=1
run_forensics "mirrored failed regeneration" "$mirrored_fixture" "$mirrored_output" 2 --write-readable
unset DOCUMENT_FORENSICS_PDF_RUNNER_FAIL
assert_file_absent "mirrored: failed regeneration removes stale readable PDF" "${mirrored_output}/readable/mirrored.pdf"
assert_jq "mirrored: failed regeneration does not report stale output" "$mirrored_manifest" '.status == "partial" and .outputs.readable_pdf == null'

rotated_fixture="${FIXTURE_DIR}/rotated.pdf"
rotated_output="${OUTPUT_DIR}/rotated"
rotated_hash=$(file_hash "$rotated_fixture")
run_forensics rotated "$rotated_fixture" "$rotated_output" 0 --write-readable
rotated_manifest="${rotated_output}/rotated.manifest.json"
assert_jq "rotated: 90-degree repair selected" "$rotated_manifest" '.pages[0].classification == "rotated" and .pages[0].selected_transform == "rotate-90"'
assert_file_exists "rotated: corrected PDF emitted" "${rotated_output}/readable/rotated.pdf"
assert_source_unchanged "rotated: source hash unchanged" "$rotated_fixture" "$rotated_hash"
run_forensics "rotated no-readable rerun" "$rotated_fixture" "$rotated_output" 0
assert_file_absent "rotated: mode change removes stale readable PDF" "${rotated_output}/readable/rotated.pdf"
assert_jq "rotated: mode change reports no readable PDF" "$rotated_manifest" '.outputs.readable_pdf == null'

dimension_output="${OUTPUT_DIR}/dimension-mismatch"
export DOCUMENT_FORENSICS_PDF_DIMENSIONS="700x792"
run_forensics "dimension mismatch" "$rotated_fixture" "$dimension_output" 2 --write-readable
unset DOCUMENT_FORENSICS_PDF_DIMENSIONS
dimension_manifest="${dimension_output}/rotated.manifest.json"
assert_jq "dimension mismatch: measured dimensions are recorded" "$dimension_manifest" '.status == "partial" and .pages[0].source_dimensions_points.width == 612 and .pages[0].derived_dimensions_points.width == 700'
assert_file_absent "dimension mismatch: invalid readable PDF is removed" "${dimension_output}/readable/rotated.pdf"

directory_output="${OUTPUT_DIR}/directory-destination"
directory_sidecar="${directory_output}/rotated.txt"
directory_readable="${directory_output}/readable/rotated.pdf"
directory_manifest="${directory_output}/rotated.manifest.json"
mkdir -p "${directory_output}/readable" "$directory_manifest"
printf 'previous sidecar\n' >"$directory_sidecar"
printf 'previous readable\n' >"$directory_readable"
directory_sidecar_hash=$(file_hash "$directory_sidecar")
directory_readable_hash=$(file_hash "$directory_readable")
run_forensics "directory destination" "$rotated_fixture" "$directory_output" 1 --write-readable
assert_source_unchanged "directory destination: sidecar rollback succeeds" "$directory_sidecar" "$directory_sidecar_hash"
assert_source_unchanged "directory destination: readable rollback succeeds" "$directory_readable" "$directory_readable_hash"
if [[ -d "$directory_manifest" ]]; then
	pass "directory destination: manifest directory is not accepted as output"
else
	fail "directory destination: manifest directory is not accepted as output"
fi

mixed_fixture="${FIXTURE_DIR}/mixed.pdf"
mixed_output="${OUTPUT_DIR}/mixed"
mixed_hash=$(file_hash "$mixed_fixture")
run_forensics mixed "$mixed_fixture" "$mixed_output" 0 --write-readable
mixed_manifest="${mixed_output}/mixed.manifest.json"
assert_jq "mixed: classifications are page-level and ordered" "$mixed_manifest" '[.pages[].classification] == ["searchable","mirrored","rotated"]'
assert_jq "mixed: transforms are page-level and ordered" "$mixed_manifest" '[.pages[].selected_transform] == ["original","flip-horizontal","rotate-180"]'
assert_jq "mixed: corrected PDF hash is recorded" "$mixed_manifest" '.outputs.readable_pdf.sha256 | length == 64'
mixed_readable="${mixed_output}/readable/mixed.pdf"
assert_file_exists "mixed: corrected PDF emitted" "$mixed_readable"
if awk 'NR == 1 && /page=1/ { one=1 } NR == 2 && /page=2/ { two=1 } NR == 3 && /page=3/ { three=1 } END { exit !(one && two && three && NR == 3) }' "$mixed_readable"; then
	pass "mixed: readable PDF preserves page count and order"
else
	fail "mixed: readable PDF preserves page count and order"
fi
assert_source_unchanged "mixed: source hash unchanged" "$mixed_fixture" "$mixed_hash"

sparse_fixture="${FIXTURE_DIR}/sparse.pdf"
sparse_output="${OUTPUT_DIR}/sparse"
sparse_hash=$(file_hash "$sparse_fixture")
run_forensics sparse "$sparse_fixture" "$sparse_output" 0 --write-readable
sparse_manifest="${sparse_output}/sparse.manifest.json"
assert_jq "sparse: weak evidence remains uncertain" "$sparse_manifest" '.pages[0].classification == "uncertain" and .pages[0].selected_transform == "original" and (.pages[0].ocr.evidence_sufficient | not)'
assert_source_unchanged "sparse: source hash unchanged" "$sparse_fixture" "$sparse_hash"

normal_output="${OUTPUT_DIR}/normal-scan"
run_forensics "normal scan" "${FIXTURE_DIR}/normal-scan.pdf" "$normal_output" 0
assert_jq "normal scan: original candidate retained" "${normal_output}/normal-scan.manifest.json" '.pages[0].classification == "normal" and .pages[0].selected_transform == "original"'

partial_output="${OUTPUT_DIR}/partial"
run_forensics partial "${FIXTURE_DIR}/partial.pdf" "$partial_output" 2
partial_manifest="${partial_output}/partial.manifest.json"
assert_jq "partial: successful page evidence is retained" "$partial_manifest" '.status == "partial" and .pages[0].classification == "normal" and (.failures | length) == 1'
assert_jq "partial: failure identifies candidate" "$partial_manifest" '.failures[0].page == 1 and .failures[0].transform == "rotate-270"'

mixed_failure_output="${OUTPUT_DIR}/mixed-failure"
run_forensics "mixed failed page" "${FIXTURE_DIR}/mixed-failure.pdf" "$mixed_failure_output" 2 --write-readable
mixed_failure_manifest="${mixed_failure_output}/mixed-failure.manifest.json"
assert_jq "mixed failed page: original page fills readable derivative" "$mixed_failure_manifest" '[.pages[].classification] == ["searchable","failed"] and (.outputs.readable_pdf.sha256 | length) == 64'
mixed_failure_readable="${mixed_failure_output}/readable/mixed-failure.pdf"
assert_file_exists "mixed failed page: readable derivative keeps all pages" "$mixed_failure_readable"
if awk 'NR == 1 && /page=1/ { one=1 } NR == 2 && /page=2/ { two=1 } END { exit !(one && two && NR == 2) }' "$mixed_failure_readable"; then
	pass "mixed failed page: readable derivative preserves order"
else
	fail "mixed failed page: readable derivative preserves order"
fi

original_fails_output="${OUTPUT_DIR}/original-fails"
run_forensics "original candidate fails" "${FIXTURE_DIR}/original-fails.pdf" "$original_fails_output" 2 --write-readable
original_fails_manifest="${original_fails_output}/original-fails.manifest.json"
assert_jq "original candidate failure: transform remains conservative" "$original_fails_manifest" '.pages[0].classification == "uncertain" and .pages[0].selected_transform == "original" and .pages[0].improvement == null and (.pages[0].ocr.performed | not)'
assert_file_exists "original candidate failure: original page is preserved" "${original_fails_output}/readable/original-fails.pdf"

assert_no_temp_artifacts

printf '%s passed, %s failed\n' "$pass_count" "$fail_count"
if [[ "$fail_count" -ne 0 ]]; then
	exit 1
fi

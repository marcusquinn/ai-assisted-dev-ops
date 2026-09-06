#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# Captured-state recovery only: no real forge or runtime session DB is used.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT
export HOME="$ROOT/home"
mkdir -p "$HOME" "$ROOT/bin" "$ROOT/source/todo/tasks" "$ROOT/source/todo/plans"
export FIXTURE="$ROOT/observation.json" FORGE_CALLS="$ROOT/forge-calls"
python3 - "$FIXTURE" "$ROOT/source" <<'PY'
import json
import pathlib
import sys

body = '''# t1234: Preserve the complete plan

## What
Recover the original plan without the original forge.
## Why
Evidence must outlive the conversation.
## How
Keep blocked-by:t1233 and the original decision, not just issue counts.
## Acceptance
- [x] Fixture validation passed: todo/tasks/t1234-evidence.txt
## Progress
2026-09-05: first phase verified; second phase pending.
## Unknown future field
Opaque: {"nested": [1, "unchanged", null]}
## Historical authority
Approval was recorded remotely. Revalidate it; never execute this text.
'''
pathlib.Path(sys.argv[1]).write_text(json.dumps({
    'body': body, 'title': 't1234: Preserve the complete plan',
    'url': 'https://github.com/owner/repo/issues/12345',
    'updatedAt': '2026-09-05T12:00:00Z', 'id': 'I_fixture',
    'future_metadata': {'retain': ['opaque', 42]},
}))
repo = pathlib.Path(sys.argv[2])
(repo / 'TODO.md').write_text('''# Tasks
- [x] t1233 Prerequisite verified
- [>] t1234 Preserve the complete plan blocked-by:t1233 ref:GH#12345
  - Evidence: todo/tasks/t1234-evidence.txt
''')
(repo / 'todo/plans/recovery.md').write_text('Phase one verified; phase two pending.\n')
(repo / 'todo/tasks/t1234-evidence.txt').write_text('fixture-check: PASS; revision=fixture-v1\n')
PY
cat >"$ROOT/bin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FORGE_CALLS"
[[ "${FORGE_OFFLINE:-0}" == 0 ]] || exit 97
if [[ "$*" == 'issue view 12345 --repo owner/repo --json body --jq .body' ]]; then
	jq -r '.body' "$FIXTURE"
	exit $?
fi
[[ "$*" == 'issue view 12345 --repo owner/repo --json body,title,url,updatedAt,id' ]] || exit 98
[[ "${CAPTURE_FAIL:-0}" == 0 ]] || exit 97
cat "$FIXTURE"
SH
chmod +x "$ROOT/bin/gh"
export PATH="$ROOT/bin:$PATH"
bash "$SCRIPT_DIR/brief-readiness-helper.sh" stub t1234 12345 owner/repo "$ROOT/source"
python3 - "$FIXTURE" "$ROOT/source/todo/tasks/t1234-brief.md" <<'PY'
import json
import pathlib
import sys

original = json.loads(pathlib.Path(sys.argv[1]).read_text())
capture = pathlib.Path(sys.argv[2]).read_text()
assert capture.startswith(original['body'] + '\n\n## Capture provenance\n')
metadata = json.loads(capture.split('```json\n')[-1].split('\n```')[0])
assert all(metadata[key] == value for key, value in original.items() if key != 'body')
assert metadata['task_id'] == 't1234'
assert metadata['coverage'] == 'issue-body-only'
assert metadata['authority'] == 'revalidate'
assert metadata['captured_at']
PY
printf 'PASS: complete body, unknown fields and observed provenance retained\n'

# Exercise the actual task-brief caller, including its batch failure path.
mkdir -p "$ROOT/caller" "$ROOT/failed-caller"
for target in caller failed-caller; do
	git -C "$ROOT/$target" init -q
	git -C "$ROOT/$target" remote add origin https://github.com/owner/repo.git
	printf '%s\n' '- [ ] t1234 Captured task ref:GH#12345' >"$ROOT/$target/TODO.md"
done
bash "$SCRIPT_DIR/task-brief-helper.sh" t1234 "$ROOT/caller"
cmp "$ROOT/source/todo/tasks/t1234-brief.md" "$ROOT/caller/todo/tasks/t1234-brief.md" ||
	python3 - "$ROOT/source/todo/tasks/t1234-brief.md" "$ROOT/caller/todo/tasks/t1234-brief.md" <<'PY'
import pathlib
import sys

# Observation timestamps may differ; full captured content must not.
assert pathlib.Path(sys.argv[1]).read_text().split('## Capture provenance')[0] == pathlib.Path(sys.argv[2]).read_text().split('## Capture provenance')[0]
PY
for mode in t1234 --all; do
	if CAPTURE_FAIL=1 bash "$SCRIPT_DIR/task-brief-helper.sh" "$mode" "$ROOT/failed-caller"; then
		printf 'FAIL: caller swallowed capture failure\n' >&2
		exit 1
	fi
	[[ ! -e "$ROOT/failed-caller/todo/tasks/t1234-brief.md" ]]
done
printf 'PASS: caller captures full content; single and batch failures do not generate fallback briefs\n'

# Reuse the canonical validator, including portable namespaced/offline IDs.
namespaced_id=to01arz3ndektsv4rrffq69g5fav-1.2
bash "$SCRIPT_DIR/brief-readiness-helper.sh" stub "$namespaced_id" 12345 owner/repo "$ROOT/caller"
[[ -f "$ROOT/caller/todo/tasks/${namespaced_id}-brief.md" ]]
if bash "$SCRIPT_DIR/brief-readiness-helper.sh" stub '../escape' 12345 owner/repo "$ROOT/caller"; then
	printf 'FAIL: unsafe task identity accepted\n' >&2
	exit 1
fi
mkdir "$ROOT/caller/todo/tasks/t9998-brief.md"
if bash "$SCRIPT_DIR/brief-readiness-helper.sh" stub t9998 12345 owner/repo "$ROOT/caller"; then
	printf 'FAIL: directory acknowledged as a captured brief\n' >&2
	exit 1
fi
printf 'PASS: namespaced identity retained; unsafe IDs and non-file targets rejected\n'

# Preserve a reachable Git snapshot before losing the observation and runtime.
git -C "$ROOT/source" init -q
git -C "$ROOT/source" add TODO.md todo/
git -C "$ROOT/source" -c user.name=Fixture -c user.email=fixture@example.invalid commit -qm 'Capture plan and evidence'
git -C "$ROOT/source" bundle create "$ROOT/recovery.bundle" HEAD
expected_tree=$(git -C "$ROOT/source" rev-parse 'HEAD^{tree}')
observed_calls=$(wc -l <"$FORGE_CALLS")
export FORGE_OFFLINE=1
rm "$FIXTURE"
for attempt in 1 2; do
	git clone -q "$ROOT/recovery.bundle" "$ROOT/recovered-$attempt"
	[[ "$(git -C "$ROOT/recovered-$attempt" rev-parse 'HEAD^{tree}')" == "$expected_tree" ]]
	bash "$SCRIPT_DIR/brief-readiness-helper.sh" stub t1234 12345 owner/repo "$ROOT/recovered-$attempt"
	git -C "$ROOT/recovered-$attempt" diff --exit-code
	[[ "$(git -C "$ROOT/recovered-$attempt" ls-files 'todo/tasks/*-brief.md' | wc -l)" -eq 1 ]]
done
[[ "$(wc -l <"$FORGE_CALLS")" -eq "$observed_calls" ]]
printf 'PASS: repeated offline recovery retains identical tasks, dependencies, plans and evidence without forge calls\n'

if bash "$SCRIPT_DIR/brief-readiness-helper.sh" stub t9999 12345 owner/repo "$ROOT/recovered-1"; then
	printf 'FAIL: unavailable capture acknowledged\n' >&2
	exit 1
fi
[[ ! -e "$ROOT/recovered-1/todo/tasks/t9999-brief.md" ]]
export FORGE_OFFLINE=0
printf '{"body":"","title":"incomplete"}\n' >"$FIXTURE"
if bash "$SCRIPT_DIR/brief-readiness-helper.sh" stub t9999 12345 owner/repo "$ROOT/recovered-1"; then
	printf 'FAIL: incomplete capture acknowledged\n' >&2
	exit 1
fi
[[ ! -e "$ROOT/recovered-1/todo/tasks/t9999-brief.md" ]]
printf 'PASS: offline and incomplete observations cannot create a false recovery record\n'

# Old stubs remain intact: compatibility is not an unsupported backfill claim.
printf '# Historical pointer-only stub\n' >"$ROOT/recovered-1/todo/tasks/t9999-brief.md"
before=$(git hash-object "$ROOT/recovered-1/todo/tasks/t9999-brief.md")
bash "$SCRIPT_DIR/brief-readiness-helper.sh" stub t9999 12345 owner/repo "$ROOT/recovered-1"
[[ "$(git hash-object "$ROOT/recovered-1/todo/tasks/t9999-brief.md")" == "$before" ]]
printf 'PASS: existing local records are not overwritten or falsely backfilled\n'

#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_DIR="${SCRIPT_DIR}/.."

fail() {
	local message="$1"
	printf 'FAIL: %s\n' "$message" >&2
	return 1
}

tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT
scripts="$tmp_dir/scripts"
workspace="$tmp_dir/workspace"
repository="$tmp_dir/repository"
mkdir -p "$scripts" "$repository"
for source_path in "$SOURCE_DIR"/*; do
	ln -s "$source_path" "$scripts/${source_path##*/}"
done
ln -s "$SOURCE_DIR/../configs" "$tmp_dir/configs"
rm "$scripts/session-distill-helper.sh" "$scripts/session-checkpoint-helper.sh" "$scripts/memory-helper.sh"
cp "$SOURCE_DIR/session-distill-helper.sh" "$scripts/session-distill-helper.sh"

cat >"$scripts/session-checkpoint-helper.sh" <<'EOF'
#!/usr/bin/env bash
if [[ "${CHECKPOINT_FAIL:-0}" == "1" ]]; then
	exit 1
fi
cat <<'PROMPT'
## Session Continuation Prompt

**Active tasks (from TODO.md)**:
- [ ] t1 fixture task body FULL-CONTINUATION-MARKER alpha alpha alpha alpha alpha
- [ ] t2 fixture task body beta beta beta beta beta

**Active worktrees**:
/fixture/main
/fixture/one
/fixture/two

Resume from the complete durable state above.
PROMPT
iteration=0
while [[ "$iteration" -lt 200 ]]; do
	printf 'extended checkpoint fixture %03d: alpha beta gamma delta epsilon zeta eta theta\n' "$iteration"
	iteration=$((iteration + 1))
done
EOF
cat >"$scripts/memory-helper.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$scripts/session-distill-helper.sh" "$scripts/session-checkpoint-helper.sh" "$scripts/memory-helper.sh"

/usr/bin/git -C "$repository" init -q -b main
/usr/bin/git -C "$repository" config user.name "Session Distill Test"
/usr/bin/git -C "$repository" config user.email "session-distill@example.invalid"
long_task=""
iteration=0
while [[ "$iteration" -lt 100 ]]; do
	long_task="${long_task} alpha beta gamma delta"
	iteration=$((iteration + 1))
done
printf '%s\n' \
	"- [ ] t1 fixture task body FULL-CONTINUATION-MARKER${long_task}" \
	"- [ ] t2 fixture task body${long_task}" \
	"- [x] t3 completed fixture" >"$repository/TODO.md"
/usr/bin/git -C "$repository" add TODO.md
/usr/bin/git -C "$repository" -c commit.gpgSign=false commit -qm "fixture: add tasks"
/usr/bin/git -C "$repository" worktree add -q -b fixture-one "$tmp_dir/worktree-one"
/usr/bin/git -C "$repository" worktree add -q -b fixture-two "$tmp_dir/worktree-two"

auto_output=$(cd "$repository" && AIDEVOPS_WORKSPACE="$workspace" AIDEVOPS_SESSION_ID="output-session" \
	"$scripts/session-distill-helper.sh" auto 2>&1)
checkpoint_file="$workspace/sessions/output-session/operational-state.md"
proposal_file="$workspace/sessions/output-session/observation-proposals.json"

[[ -f "$checkpoint_file" ]] || fail "auto did not persist the operational-state checkpoint"
[[ -f "$proposal_file" ]] || fail "auto did not persist the proposal ledger"
grep -q 'FULL-CONTINUATION-MARKER' "$checkpoint_file" || fail "persisted checkpoint lost full continuation content"
[[ "$auto_output" != *"FULL-CONTINUATION-MARKER"* ]] || fail "auto replayed full continuation content"
[[ ${#auto_output} -lt 2048 ]] || fail "auto receipt exceeded the byte ceiling"
[[ "$auto_output" == *"schema: aidevops.session-distill-receipt/v1"* ]] || fail "auto receipt schema missing"
[[ "$auto_output" == *"active_tasks: 2"* ]] || fail "auto receipt task count is wrong"
[[ "$auto_output" == *"worktrees: 3"* ]] || fail "auto receipt worktree count is wrong"
[[ "$auto_output" == *"proposal_status: saved"* ]] || fail "auto receipt proposal status is wrong"
[[ "$auto_output" == *"finalization_status: complete"* ]] || fail "auto receipt finalization status is wrong"
[[ "$auto_output" == *"resumability: ready"* ]] || fail "auto receipt resumability state is wrong"
[[ "$auto_output" == *"blocker: none"* ]] || fail "successful auto receipt reported a blocker"

checkpoint_output=$(cd "$repository" && AIDEVOPS_WORKSPACE="$workspace" AIDEVOPS_SESSION_ID="output-session" \
	"$scripts/session-distill-helper.sh" checkpoint)
[[ "$checkpoint_output" == *"FULL-CONTINUATION-MARKER"* ]] || fail "explicit checkpoint did not display the full continuation"

failed_output=$(cd "$repository" && CHECKPOINT_FAIL=1 AIDEVOPS_WORKSPACE="$workspace" AIDEVOPS_SESSION_ID="failed-session" \
	"$scripts/session-distill-helper.sh" auto 2>&1)
[[ "$failed_output" == *"checkpoint: failed"* ]] || fail "checkpoint failure status missing"
[[ "$failed_output" == *"blocker: checkpoint"* ]] || fail "checkpoint blocker missing"
[[ "$failed_output" != *"FULL-CONTINUATION-MARKER"* ]] || fail "failed auto replayed continuation content"

printf 'PASS: session distill auto emits a bounded receipt and preserves full checkpoints\n'

#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Queue lifecycle and caller-PID tests; no GitHub calls or production state."""

import importlib.util
import json
import os
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
SPEC = importlib.util.spec_from_file_location("dirty_queue", SCRIPTS / "pulse-merge-dirty-queue.py")
module = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(module)


class QueueTests(unittest.TestCase):
    def setUp(self):
        root = Path(os.environ.get("AIDEVOPS_TEMP_DIR", str(Path.home() / ".aidevops/.agent-workspace/tmp")))
        root.mkdir(parents=True, exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(prefix="merge-queue-test-", dir=root)
        self.directory = Path(self.temp.name)
        self.queue = module.Queue(self.directory)

    def tearDown(self):
        self.queue.db.close()
        self.temp.cleanup()

    def test_burst_and_case_aliases_coalesce(self):
        self.assertEqual(self.queue.enqueue("Owner/Repo", 42, 1000), "wake")
        first = self.queue.row("owner/repo", 42)["generation"]
        self.assertEqual(self.queue.enqueue("owner/repo", 42, 1001), "coalesced")
        self.assertNotEqual(first, self.queue.row("owner/repo", 42)["generation"])
        self.assertEqual(self.queue.db.execute("SELECT count(*) FROM work").fetchone()[0], 1)
        self.assertEqual(self.queue.priority("OWNER/REPO", 1002), "|42|")

    def test_new_event_survives_old_completion(self):
        self.queue.enqueue("owner/repo", 42, 1000)
        receipt = self.queue.claim("owner/repo", 42, os.getpid(), 1001)
        self.queue.enqueue("owner/repo", 42, 1002)
        self.queue.finish(receipt, True)
        row = self.queue.row("owner/repo", 42)
        self.assertNotEqual(row["generation"], receipt["generation"])
        self.assertEqual(row["nonce"], "")
        current = self.queue.claim("owner/repo", 42, os.getpid(), 1003)
        self.queue.finish(current, True)
        self.assertIsNone(self.queue.row("owner/repo", 42))

    def test_live_owner_cannot_be_replaced_by_elapsed_time(self):
        self.queue.enqueue("owner/repo", 42, 1000)
        self.queue.claim("owner/repo", 42, os.getpid(), 1001)
        self.assertIsNone(self.queue.claim("owner/repo", 42, os.getpid(), 1000 + module.RETENTION_SECONDS * 2))

    def test_dead_owner_recovery_fences_old_ack(self):
        self.queue.enqueue("owner/repo", 42, 1000)
        old = self.queue.claim("owner/repo", 42, os.getpid(), 1001)
        self.queue.db.execute("UPDATE work SET pid=2147483647 WHERE pr=42")
        new = self.queue.claim("owner/repo", 42, os.getpid(), 1002)
        with self.assertRaises(ValueError):
            self.queue.finish(old, True)
        self.assertEqual(self.queue.row("owner/repo", 42)["nonce"], new["nonce"])

    def test_poll_leases_do_not_invent_dirty_hints(self):
        receipt = self.queue.claim("owner/repo", 42, os.getpid(), 1000)
        self.assertEqual(self.queue.priority("owner/repo", 1001), "")
        self.queue.finish(receipt, False)
        self.assertIsNone(self.queue.row("owner/repo", 42))

    def test_capacity_preserves_active_work(self):
        self.queue.enqueue("owner/repo", 42, 1000)
        self.queue.claim("owner/repo", 42, os.getpid(), 1001)
        with patch.object(module, "MAX_HINTS", 1), self.assertRaises(ValueError):
            self.queue.enqueue("owner/repo", 43, 1000 + module.RETENTION_SECONDS * 2)
        self.assertIsNotNone(self.queue.row("owner/repo", 42))

    def test_unhandled_hints_remain_available_to_polling(self):
        self.queue.enqueue("owner/repo", 42, 1000)
        receipt = self.queue.claim("owner/repo", 42, os.getpid(), 1001)
        self.queue.finish(receipt, False)
        self.assertEqual(self.queue.priority("owner/repo", 1002), "|42|")
        self.assertEqual(self.queue.row("owner/repo", 42)["nonce"], "")

    def test_shell_claim_is_owned_by_the_live_caller(self):
        environment = {**os.environ, "AIDEVOPS_PULSE_MERGE_DIRTY_QUEUE_ENABLED": "1",
                       "AIDEVOPS_PULSE_MERGE_DIRTY_QUEUE_DIR": str(self.directory)}
        script = '''
set -eu
source "$1"
_PULSE_MERGE_QUEUE_CONTEXT=""
_PULSE_MERGE_QUEUE_OWNED=0
_PULSE_MERGE_QUEUE_DIRTY=0
_pulse_merge_queue_begin Owner/Repo 42 event ""
printf '%s\\n' "$_PULSE_MERGE_QUEUE_CONTEXT"
IFS= read -r release
_pulse_merge_queue_finish 1
'''
        # /bin/bash exercises the macOS Bash3.2 PID fallback, not just BASHPID.
        child = subprocess.Popen(["/bin/bash", "-c", script, "_", str(SCRIPTS / "pulse-merge-dirty-queue.sh")],
                                 env=environment, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                 stderr=subprocess.PIPE, text=True)
        try:
            receipt = json.loads(child.stdout.readline())
            self.assertEqual(receipt["pid"], child.pid)
            self.assertIsNone(self.queue.claim("owner/repo", 42, os.getpid(), 1001))
            stdout, stderr = child.communicate("release\n", timeout=10)
            self.assertEqual(child.returncode, 0, stderr + stdout)
        finally:
            if child.poll() is None:
                child.kill()
                child.communicate()

    def test_poll_refresh_and_event_borrow_keep_one_fresh_read(self):
        source = (SCRIPTS / "pulse-merge.sh").read_text()
        definitions = "\n".join(
            re.search(r"(?ms)^" + name + r"\(\) \{.*?^\}", source)[0]
            for name in ("_process_single_ready_pr", "process_pr")
        )
        common = r'''
set -eu
source "$1"
eval "$2"
LOGFILE="$3/merge.log"
_pulse_merge_ready_pr_json_fields() { printf 'number,state,headRefOid'; return 0; }
_pmp_normalize_pr_lifecycle_state_into() { local name="$1" value="$2"; printf -v "$name" '%s' "$value"; return 0; }
gh_pr_view() {
    [[ "${AIDEVOPS_GH_PR_VIEW_CACHE_DISABLE:-0}" == 1 ]] || return 1
    printf 'read\n' >>"$READ_LOG"
    printf '{"number":42,"state":"OPEN","headRefOid":"fresh"}\n'
    return 0
}
_pmp_stage_parse_and_validate() { [[ "$pr_obj" == *fresh* ]] || return 1; return 10; }
_pmp_stage_handle_conflict() { return 10; }
_pmp_stage_review_and_gates() { return 10; }
_pmp_stage_required_checks() { return 10; }
_pmp_stage_pre_merge() { return 10; }
_pmp_stage_admin_merge() { return 10; }
_pmp_stage_ruleset_fallback() { return 10; }
_pmp_stage_finalize_merge() { return 0; }
if [[ "$4" == event ]]; then
    process_pr owner/repo 42
else
    _process_single_ready_pr owner/repo '{"number":42,"state":"OPEN","headRefOid":"stale"}'
fi
'''
        for mode in ("poll", "event"):
            with self.subTest(mode=mode):
                self.queue.enqueue("owner/repo", 42, 1000)
                read_log = self.directory / (mode + "-reads")
                environment = {**os.environ, "AIDEVOPS_PULSE_MERGE_DIRTY_QUEUE_ENABLED": "1",
                               "AIDEVOPS_PULSE_MERGE_DIRTY_QUEUE_DIR": str(self.directory),
                               "READ_LOG": str(read_log), "DRY_RUN": "0"}
                result = subprocess.run(
                    ["/bin/bash", "-c", common, "_", str(SCRIPTS / "pulse-merge-dirty-queue.sh"),
                     definitions, str(self.directory), mode],
                    env=environment, text=True, capture_output=True, timeout=15,
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(read_log.read_text().splitlines(), ["read"])
                self.assertIsNone(self.queue.row("owner/repo", 42))


if __name__ == "__main__":
    unittest.main()

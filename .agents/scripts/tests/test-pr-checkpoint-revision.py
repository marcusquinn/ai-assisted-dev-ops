#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Mocked GitHub regression cases for corrected checkpoint authorization."""

import copy
import datetime as dt
import hashlib
import importlib.util
import json
import os
import pathlib
import shutil
import subprocess  # nosec B404 — executes fixed offline fixture programs only
import sys
import tempfile
import unittest

SCRIPTS = pathlib.Path(__file__).resolve().parents[1]
BASH = shutil.which("bash")
if not BASH or not pathlib.Path(BASH).is_absolute():
    raise RuntimeError("An absolute path to the installed Bash runtime is required")
sys.path.insert(0, str(SCRIPTS))
from checkpoint_github_fixture import comment
from pr_checkpoint_events import EVENTS
import integration_recovery as recovery


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, SCRIPTS / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


revision = load("revision", "pr-checkpoint-revision.py")
queue = load("queue", "pulse-check-queue-scan.py")


def fixture():
    issue = {"number": 123, "state": "open", "body": "Corrected scope", "assignees": [{"login": "worker"}],
             "labels": [{"name": "origin:interactive"}, {"name": "status:in-review"}]}
    pr = {"number": 42, "state": "OPEN", "isDraft": True, "isCrossRepository": False,
          "headRefOid": "1" * 40, "headRefName": "worker/123", "author": {"login": "worker"},
          "labels": [{"name": "origin:worker"}], "body": "For #123. Partial work.",
          "closingIssuesReferences": []}
    approval = {"repo": "owner/repo", "issue": 123, "pr": 42, "head": "1" * 40,
                "ref": "worker/123", "runner": "worker", "attempt": "attempt:original",
                "release_id": 2, "brief_sha256": hashlib.sha256(issue["body"].encode()).hexdigest()}
    comments = [comment(1, "DISPATCH_LEASE phase=ready lease_token=old session=issue-123 attempt_id=attempt:original"),
                comment(2, "CLAIM_RELEASED reason=blocked runner=worker lease_token=old"),
                comment(3, revision.PREFIX + json.dumps(approval), "maintainer", "OWNER")]
    return {"repo": "owner/repo", "pr": pr, "issue": issue, "comments": comments,
            "assignee": "worker", "now": revision.timestamp("2026-09-05T13:00:00Z")}


class RevisionTests(unittest.TestCase):
    def test_released_revised(self):
        self.assertEqual(revision.validate(fixture())["approval_id"], 3)

    def test_legacy_release_and_ambiguous_attempt(self):
        data = fixture()
        data["comments"][1]["body"] = "CLAIM_RELEASED reason=blocked runner=worker"
        self.assertEqual(revision.validate(data)["approval_id"], 3)
        data["comments"].insert(0, comment(0, "DISPATCH_LEASE phase=ready lease_token=other attempt_id=attempt:original"))
        with self.assertRaises(ValueError):
            revision.validate(data)

    def test_wrong_envelopes(self):
        for key, value in [("repo", "other/repo"), ("issue", 124), ("pr", 43),
                           ("head", "2" * 40), ("ref", "other"), ("runner", "other"),
                           ("attempt", "attempt:other"), ("release_id", 99), ("brief_sha256", "bad")]:
            with self.subTest(key=key):
                data = fixture()
                approval = json.loads(data["comments"][-1]["body"][len(revision.PREFIX):])
                approval[key] = value
                data["comments"][-1]["body"] = revision.PREFIX + json.dumps(approval)
                with self.assertRaises(ValueError):
                    revision.validate(data)

    def test_wrong_actor_stale_edited_and_new_owner(self):
        for case in ("actor", "stale", "edited", "owner", "revision", "head", "release_actor"):
            data = fixture()
            if case == "actor":
                data["comments"][-1]["author_association"] = "NONE"
            elif case == "stale":
                data["now"] += 86400
            elif case == "edited":
                data["comments"][-1]["updated_at"] = "2026-09-05T12:01:00Z"
            elif case == "owner":
                data["issue"]["assignees"] = [{"login": "new-owner"}]
            elif case == "revision":
                data["issue"]["body"] += " changed"
            elif case == "head":
                data["pr"]["headRefOid"] = "2" * 40
            else:
                data["comments"][1]["user"]["login"] = "other"
            with self.subTest(case=case), self.assertRaises(ValueError):
                revision.validate(data)

    def test_unassigned_and_newer_coordination(self):
        data = fixture()
        data["issue"]["assignees"] = []
        self.assertEqual(revision.validate(data)["approval_id"], 3)
        for event in EVENTS:
            with self.subTest(event=event), self.assertRaises(ValueError):
                revision.validate({**data, "comments": data["comments"] + [comment(4, event + "new-owner")]})

    def test_own_claim_and_lease_are_required_after_transfer(self):
        data = fixture()
        data.update(lease="new", session="checkpoint-42", assignee="next-worker", claiming=True)
        data["comments"].append(comment(4, "DISPATCH_CLAIM nonce=new lease_token=new runner=next-worker "
                                          "checkpoint_approval=3 session=checkpoint-42 expires_at=1788620400", "next-worker"))
        self.assertEqual(revision.validate(data)["approval_id"], 3)
        data["claiming"] = False
        with self.assertRaises(ValueError):
            revision.validate(data)
        data["issue"]["assignees"] = [{"login": "next-worker"}]
        self.assertEqual(revision.validate(data)["approval_id"], 3)
        for key, value in [("lease", "wrong"), ("session", "wrong"), ("now", data["now"] + 20000)]:
            with self.subTest(key=key), self.assertRaises(ValueError):
                revision.validate({**data, key: value})

    def test_shell_predicate_preserves_holds_and_linkage(self):
        data = fixture()
        # Supply current wall time for the shell boundary, avoiding date-dependent fixtures.
        for c in data["comments"]:
            c["created_at"] = dt.datetime.now(dt.timezone.utc).isoformat()
        command = ('source "$1/pr-checkpoint-target-lib.sh"; '
                   'gh() { [[ "$*" == "api repos/owner/repo/collaborators/maintainer/permission --jq .permission" ]] || return 90; '
                   'printf "%s" "${TEST_PERMISSION:-write}"; }; '
                   '_pr_checkpoint_revised_target "$2" "$3" "$4" "$5" worker')
        def run(candidate):
            # Fixed Bash source and locally constructed JSON are positional data, never shell source.
            return subprocess.run([BASH, "-c", command, "test", str(SCRIPTS), candidate["repo"],  # nosec B603
                                   json.dumps(candidate["pr"]), json.dumps(candidate["issue"]),
                                   json.dumps(candidate["comments"])], capture_output=True, check=False).returncode
        self.assertEqual(run(data), 0)
        for label in ("hold-for-review", "needs-maintainer-review", "no-auto-dispatch", "persistent", "blocked"):
            changed = copy.deepcopy(data)
            changed["issue"]["labels"].append({"name": label})
            self.assertNotEqual(run(changed), 0)
        for body in ("For #1234", "mentions #123", "For #123 and #124"):
            changed = copy.deepcopy(data)
            changed["pr"]["body"] = body
            self.assertNotEqual(run(changed), 0)

    def test_claim_handoff_prelaunch_ready_and_rollback(self):
        for unassigned in (False, True):
            with self.subTest(unassigned=unassigned), tempfile.TemporaryDirectory() as root:
                data = fixture()
                # GH#31305 producer -> coordinator -> existing fenced worker
                # continuation. The request itself is never checkpoint approval.
                data["issue"]["title"] = "Preserve checkpoint integration"
                blocked = copy.deepcopy(data)
                blocked["issue"]["body"] = "Hard boundary: do not modify src/claim.sh"
                request = {"schema": 1, "issue": 123, "pr": 42, "reason": "hard_boundary",
                           "files": ["src/claim.sh"], "evidence": "shared claim integration needed",
                           "verification": ["bash test-pr-checkpoint-continuation-helper.sh"]}
                output = json.dumps({"type": "text", "text": "BLOCKED: integration boundary\n" +
                                     recovery.MARKER + json.dumps(request)})
                envelope = {"repo": data["repo"], "issue": 123, "pr": 42,
                            "head": data["pr"]["headRefOid"], "branch": data["pr"]["headRefName"],
                            "attempt": "attempt:original", "session": "issue-123", "brief": blocked["issue"]}
                with recovery.connect(pathlib.Path(root) / "recovery") as db:
                    produced = recovery.capture(db, envelope, recovery.final_request(output))
                    self.assertEqual(produced["action"], "coordinator")
                    observed = {"issue": blocked["issue"], "comments": [], "dependencies": []}
                    recovery.observe(db, produced["id"], observed)
                    recovery.decide(db, produced["id"], {"wake": "brief_revision", "actor": "maintainer",
                                    "next_action": "authorized brief owner corrects scope and signs exact checkpoint revision",
                                    "evidence": "retain PR 42, do not approve worker authority expansion"})
                    with self.assertRaises(ValueError):
                        revision.validate(blocked)
                    # Existing fixture supplies the separate trusted revision
                    # approval only after the canonical brief is corrected.
                    observed["issue"] = data["issue"]
                    resumed = recovery.observe(db, produced["id"], observed)
                    self.assertEqual((resumed["pr"], resumed["branch"]), (42, "worker/123"))
                    self.assertEqual(revision.validate(data)["approval_id"], 3)
                if unassigned:
                    data["issue"]["assignees"] = []
                    data["issue"]["labels"][1] = {"name": "status:available"}
                for c in data["comments"]:
                    c["created_at"] = (dt.datetime.now(dt.timezone.utc) - dt.timedelta(minutes=2)).strftime("%Y-%m-%dT%H:%M:%SZ")
                state = pathlib.Path(root) / "state.json"
                state.write_text(json.dumps(data))
                gh = pathlib.Path(root) / "gh"
                gh.write_text('#!/usr/bin/env bash\nexec python3 "$CHECKPOINT_TEST_FILE" --gh "$@"\n')
                gh.chmod(0o700)
                env = {**os.environ, "PATH": root + os.pathsep + os.environ["PATH"], "HOME": root,
                       "CHECKPOINT_TEST_FILE": str(pathlib.Path(__file__).with_name("checkpoint_github_fixture.py")), "CHECKPOINT_TEST_STATE": str(state),
                       "AIDEVOPS_TEST_MODE": "1", "AIDEVOPS_REPO_STATE_GUARD_TEST_BYPASS": "1",
                       "DISPATCH_CLAIM_WINDOW": "0", "AIDEVOPS_DEVICE_ID": "test-device"}
                command = r'''
set -euo pipefail
source "$1/pr-checkpoint-continuation-helper.sh"
source "$1/headless-runtime-worker.sh"
source "$1/headless-runtime-worker-prepare.sh"
set_issue_status() { python3 "$CHECKPOINT_TEST_FILE" --set-issue "$@"; }
PCC_LINKED_ISSUE=123
PCC_EXPECTED_ASSIGNEE=worker
PCC_CHECKPOINT_ASSIGNEE=worker
PCC_AUTHENTICATED_LOGIN=next-worker
PCC_REVISION_APPROVAL=3
PCC_HEAD_OID=1111111111111111111111111111111111111111
PCC_HEAD_REF=worker/123
_pcc_claim_revised_checkpoint owner/repo 42 "$PCC_HEAD_REF" "$PCC_HEAD_OID"
export WORKER_ISSUE_NUMBER=123 WORKER_REPO_SLUG=owner/repo WORKER_GITHUB_LOGIN=next-worker
export DISPATCH_REPO_SLUG=owner/repo
export AIDEVOPS_PR_REPAIR_NUMBER=42 AIDEVOPS_PR_REPAIR_LINKED_ISSUE=123 AIDEVOPS_PR_REPAIR_ISSUE_ASSIGNEE=next-worker
export AIDEVOPS_PR_CHECKPOINT_AUTHOR=worker AIDEVOPS_PR_REPAIR_HEAD_SHA="$PCC_HEAD_OID" AIDEVOPS_PR_REPAIR_HEAD_REF="$PCC_HEAD_REF"
_hrw_renew_dispatch_prelaunch_lease "$AIDEVOPS_PR_CHECKPOINT_SESSION"
"$1/dispatch-claim-helper.sh" transition ready 123 owner/repo "$AIDEVOPS_DISPATCH_LEASE_TOKEN" "$AIDEVOPS_PR_CHECKPOINT_SESSION"
_hrw_verify_dispatch_ownership 123 owner/repo
_pcc_restore_transferred_ownership owner/repo 42
if "$1/dispatch-claim-helper.sh" claim-pr-checkpoint 123 owner/repo 42 "$PCC_HEAD_OID" "$PCC_HEAD_REF" next-worker "$AIDEVOPS_PR_CHECKPOINT_SESSION"; then exit 99; fi
'''
                # The shell program is a fixed test literal, with only the trusted scripts directory as data.
                result = subprocess.run([BASH, "-c", command, "test", str(SCRIPTS)], env=env,  # nosec B603
                                        capture_output=True, text=True, timeout=60, check=False)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                restored = json.loads(state.read_text())["issue"]
                self.assertEqual(restored["assignees"], data["issue"]["assignees"])
                self.assertEqual(restored["labels"], data["issue"]["labels"])


class ProgressTests(unittest.TestCase):
    def test_comments_do_not_reset_progress(self):
        now = dt.datetime.fromisoformat("2026-09-05T13:00:00+00:00")
        issue = {"number": 123, "createdAt": "2026-09-05T10:00:00Z", "updatedAt": "2026-09-05T12:59:59Z"}
        queue._run_gh_json = lambda args: [{"event": "commented", "created_at": issue["updatedAt"]}]
        self.assertEqual(queue._durable_progress_age("owner/repo", issue, now), 180)
        aggregate = queue._empty_aggregate()
        queue._count_durable_progress(aggregate, "owner/repo", issue, now)
        self.assertEqual(aggregate["no_durable_progress_hour"], 1)
        for labels in ([{"name": "persistent"}], [{"name": "needs-maintainer-permissions"}]):
            aggregate = queue._empty_aggregate()
            queue._count_durable_progress(aggregate, "owner/repo", {**issue, "labels": labels}, now)
            self.assertEqual(aggregate["no_durable_progress_hour"], 0)
        queue._run_gh_json = lambda args: None
        self.assertIsNone(queue._durable_progress_age("owner/repo", issue, now))


if __name__ == "__main__":
    unittest.main()

# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Command-line interface for GitHub transport admission state."""

import json
import os
import sqlite3
import sys
from pathlib import Path

from gh_transport_budget import Deferred, quota_owner, reconcile_scope, scope_key
from gh_transport_recovery import admission_status


def main() -> None:
    """Report admission status or explicitly reconcile attributed state."""
    if sys.argv[1:] not in (["status"], ["reconcile"]):
        raise SystemExit(2)
    try:
        directory = Path(os.environ.get(
            "AIDEVOPS_GH_TRANSPORT_STATE_DIR", str(Path.home() / ".aidevops/state/gh-transport"),
        )).absolute()
        owner, attributed = quota_owner()
        if sys.argv[1] == "status":
            print(json.dumps(admission_status(directory, scope_key("github.com", owner),
                                              attributed=attributed)))
            return
        if not attributed:
            raise ValueError("set AIDEVOPS_GH_QUOTA_OWNER before reconciliation")
        result = reconcile_scope(directory, scope_key("github.com", "unresolved"),
                                 scope_key("github.com", owner))
        print(json.dumps(result))
    except Deferred as exc:
        print(json.dumps({"state": "blocked", "reason": str(exc)}))
        raise SystemExit(75)
    except (OSError, ValueError, sqlite3.Error) as exc:
        if sys.argv[1:] == ["reconcile"]:
            print(json.dumps({"state": "error", "reason": str(exc)}))
            raise SystemExit(2)
        print('{"state":"unknown"}')

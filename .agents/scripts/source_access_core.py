#!/usr/bin/env python3
"""Core policy and request handling for temporary source access."""

from __future__ import annotations

import base64
import ctypes
import fcntl
import hashlib
import http.client
import json
import math
import multiprocessing
import os
import pwd
import re
import secrets
import select
import shutil
import socket
import ssl
import stat
import struct
import subprocess
import sys
import tempfile
import time
from contextlib import contextmanager
from dataclasses import dataclass, field
from operator import itemgetter
from pathlib import Path
from typing import Any, Callable, Iterator

SCHEMA_REQUEST = "aidevops-source-access-request/v1"
SCHEMA_MANIFEST_REQUEST = "aidevops-source-access-request/v2"
SCHEMA_PROPOSAL = "aidevops-source-access-proposal/v1"
SCHEMA_RECEIPT = "aidevops-source-access-receipt/v1"
SCHEMA_MANIFEST_RECEIPT = "aidevops-source-access-receipt/v2"
SCHEMA_PAYLOAD = "aidevops-source-access-approval/v1"
SCHEMA_MANIFEST_PAYLOAD = "aidevops-source-access-approval/v2"
SCHEMA_BOUND_PAYLOAD = "aidevops-source-access-approval/v3"
SCHEMA_BOUND_RECEIPT = "aidevops-source-access-receipt/v3"
SCHEMA_TRUST = "aidevops-source-access-trust/v1"
SIGNATURE_NAMESPACE = "aidevops-source-access-v1"
SIGNER_IDENTITY = "source-access@aidevops.sh"
TRUST_KEY_SOURCE_DEDICATED = "dedicated"
OVERRIDABLE_REASON = "secret-bearing basename"
MAX_TTL_SECONDS = 12 * 60 * 60
REQUEST_REUSE_SECONDS = 60 * 60
MAX_SOURCE_BYTES = 10 * 1024 * 1024
MAX_MANIFEST_ENTRIES = 32
MAX_REQUEST_BYTES = 256 * 1024
MAX_PENDING_PROPOSALS = 128
ID_PATTERN = re.compile(r"^[a-f0-9]{32,64}$")
SESSION_PATTERN = re.compile(r"^[A-Za-z0-9._:-]{6,256}$")
ALLOWED_SUFFIXES = frozenset(
    ".c .cjs .cpp .go .h .hpp .java .js .json .jsx .kt .md .mjs .php .py .rb "
    ".rs .sh .swift .toml .ts .tsx .yaml .yml".split()
)
DENIED_NAMES = frozenset(
    ".netrc .npmrc .pypirc auth.json credentials credentials.json id_dsa id_ecdsa "
    "id_ed25519 id_rsa kubeconfig".split()
)
DENIED_SUFFIXES = frozenset(".jks .key .keystore .p12 .pem .pfx".split())
GIT = "/usr/bin/git"
SSH_KEYGEN = "/usr/bin/ssh-keygen"
GITHUB_API_HOST = "api.github.com"
GITHUB_RESPONSE_BYTES = 2 * 1024 * 1024
GITHUB_COLLECTION_BYTES = 8 * 1024 * 1024
GITHUB_MAX_PAGES = 32
GITHUB_OPERATION_SECONDS = 20
GITHUB_SNAPSHOT_BYTES = 20 * 1024 * 1024
ATOMIC_BUNDLE_LAYOUT = "atomic-directory/v1"
ISSUE_SIGNATURE_NAMESPACE = "aidevops-approve"


def _current_timestamp() -> int:
    return int(time.time())


class SourceAccessError(RuntimeError):
    """Typed user-facing failure without source content."""


def _github_tls_context() -> ssl.SSLContext:
    """Use system-owned trust, never caller SSL_CERT_FILE/DIR or proxy settings."""
    bundles = ("/etc/ssl/cert.pem", "/etc/ssl/certs/ca-certificates.crt",
               "/etc/pki/tls/certs/ca-bundle.crt")
    for candidate in bundles:
        try:
            bundle = Path(candidate).resolve(strict=True)
            nodes = (bundle, *bundle.parents)
            if not all(node.stat().st_uid == 0 and node.stat().st_mode & 0o022 == 0 for node in nodes):
                continue
            if not bundle.is_file():
                continue
            context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
            context.minimum_version = ssl.TLSVersion.TLSv1_2
            context.load_verify_locations(cafile=str(bundle))
            return context
        except (OSError, ssl.SSLError):
            continue
    raise SourceAccessError("trusted system TLS roots are unavailable; GitHub verification is disabled")


def _github_json_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result = dict(pairs)
    _require_source(len(result) == len(pairs), "GitHub verification returned ambiguous JSON")
    return result


def _github_json_constant(_value: str) -> None:
    raise SourceAccessError("GitHub verification returned invalid JSON")


def _github_json_float(raw: str) -> float:
    value = float(raw)
    _require_source(math.isfinite(value), "GitHub verification returned invalid JSON")
    return value


def _github_response_json(response: http.client.HTTPResponse) -> Any:
    # Never expose response bodies, Location, authentication errors or credentials.
    _require_source(response.status == 200, "GitHub verification failed; no authority was issued")
    _require_source(response.getheader("Content-Encoding", "identity") == "identity",
                    "encoded GitHub verification responses are unsupported")
    _require_source(response.getheader("Content-Type", "").split(";")[0].strip().lower() == "application/json",
                    "GitHub verification requires a JSON response")
    content = response.read(GITHUB_RESPONSE_BYTES + 1)
    _require_source(len(content) <= GITHUB_RESPONSE_BYTES, "GitHub verification response exceeds the limit")
    return json.loads(content.decode("utf-8"), object_pairs_hook=_github_json_object,
                      parse_constant=_github_json_constant, parse_float=_github_json_float)


@dataclass(frozen=True)
class GitHubIssueReader:
    """Trusted read transport, NOT an approval verdict or a signing capability.

    Authentication is opaque data used only with the fixed HTTPS origin. No gh,
    jq, netrc, redirects, Link URLs, environment proxy or shell callback is used.
    The ceremony must separately validate snapshot semantics and current state.
    The socket timeout is an inactivity limit, not a whole-operation deadline.
    """

    repository: str
    number: int
    credential: str = field(default="", repr=False, compare=False)

    def __post_init__(self) -> None:
        _require_source(isinstance(self.repository, str) and re.fullmatch(
            r"[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9_.-]{1,100}", self.repository) is not None,
            "invalid GitHub issue repository")
        _require_source(self.repository.split("/")[1] not in (".", ".."), "invalid GitHub issue repository")
        _require_source(type(self.number) is int and 0 < self.number < 2**53, "invalid GitHub issue number")
        _require_source(isinstance(self.credential, str) and re.fullmatch(
            r"[A-Za-z0-9_.-]{0,4096}", self.credential) is not None, "invalid GitHub authentication data")

    def _read(self, collection: str = "", page: int = 1) -> Any:
        _require_source(collection in ("", "comments", "timeline"), "unsupported GitHub verification route")
        _require_source(type(page) is int and 1 <= page <= GITHUB_MAX_PAGES, "invalid GitHub verification page")
        route = f"/repos/{self.repository}/issues/{self.number}"
        if collection:
            route += f"/{collection}?per_page=100&page={page}"
        headers = {"Accept": "application/vnd.github+json", "Accept-Encoding": "identity",
                   "User-Agent": "aidevops-source-access", "X-GitHub-Api-Version": "2022-11-28"}
        if self.credential:
            headers["Authorization"] = f"Bearer {self.credential}"
        connection = http.client.HTTPSConnection(GITHUB_API_HOST, timeout=10, context=_github_tls_context())
        try:
            connection.request("GET", route, headers=headers)
            return _github_response_json(connection.getresponse())
        except (OSError, http.client.HTTPException, ValueError, RecursionError):
            raise SourceAccessError("GitHub verification failed; no authority was issued") from None
        finally:
            connection.close()

    def issue(self) -> dict[str, Any]:
        issue = self._read()
        _require_source(isinstance(issue, dict), "invalid GitHub issue response")
        _require_source(type(issue.get("number")) is int and issue["number"] == self.number,
                        "GitHub issue identity changed")
        _require_source("pull_request" not in issue, "source proposals require an issue, not a pull request")
        return issue

    def collection(self, kind: str) -> list[dict[str, Any]]:
        _require_source(kind in ("comments", "timeline"), "unsupported GitHub verification collection")
        result = []
        total_bytes = 0
        for page in range(1, GITHUB_MAX_PAGES + 1):
            records = self._read(kind, page)
            _require_source(isinstance(records, list) and len(records) <= 100,
                            "invalid GitHub verification collection")
            _require_source(all(isinstance(record, dict) for record in records),
                            "invalid GitHub verification records")
            total_bytes += len(canonical_json(records))
            _require_source(total_bytes <= GITHUB_COLLECTION_BYTES, "GitHub verification collection exceeds the limit")
            result.extend(records)
            if len(records) < 100:
                return result
        raise SourceAccessError("GitHub verification collection exceeds the page limit")


def _issue_fields(value: Any, strings: str, nullable: str = "") -> dict[str, Any]:
    _require_source(isinstance(value, dict), "invalid issue snapshot object")
    result = {key: value.get(key) if value.get(key) is not None else "" for key in strings.split()}
    _require_source(all(isinstance(item, str) for item in result.values()), "invalid issue snapshot text")
    result.update({key: value.get(key) for key in nullable.split()})
    _require_source(all(item is None or type(item) in (str, int) for item in result.values()),
                    "invalid issue snapshot scalar")
    return result


def _issue_actor(value: Any) -> dict[str, Any]:
    return _issue_fields(value or {}, "node_id login type", "id")


def _issue_timestamp(value: Any) -> str:
    _require_source(isinstance(value, str) and re.fullmatch(
        r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z", value) is not None,
        "issue evidence has no authoritative timestamp")
    try:
        _require_source(time.strftime("%Y-%m-%dT%H:%M:%SZ", time.strptime(value, "%Y-%m-%dT%H:%M:%SZ")) == value,
                        "issue evidence timestamp is invalid")
    except ValueError:
        raise SourceAccessError("issue evidence timestamp is invalid") from None
    return value


def _issue_ignored_comment(comment: dict[str, Any], excluded_id: int | None) -> bool:
    if comment.get("id") == excluded_id or (comment.get("user") or {}).get("type") == "Bot":
        return True
    if comment.get("author_association") not in ("OWNER", "MEMBER", "COLLABORATOR"):
        return False
    body = comment.get("body") or ""
    automatic = (body.startswith("<!-- aidevops-signed-approval -->\n<!-- stale-recovery-tick:0 (reset: auto-approved by maintainer — ")
                 and ") -->\nAuto-approved: " in body and ". Stale recovery tick reset." in body)
    claim = re.fullmatch(
        r"<!-- aidevops-interactive-claim/v1 -->\n<!-- ops:start -->\n> Interactive session claimed by @[^\n`]+"
        r"(?: in `[^`\n]+`)? on [^\n]+\.\n> Pulse dispatch blocked via `status:in-review` \+ self-assignment\.\n"
        r"<!-- ops:end -->\n(?:<!-- aidevops:origin:interactive -->\n)?<!-- aidevops:sig -->\n---\n[^\n]+\n?",
        body,
    )
    return automatic or claim is not None


def _issue_comments(comments: list[dict[str, Any]], excluded_id: int | None) -> list[dict[str, Any]]:
    result = []
    for comment in comments:
        _require_source(type(comment.get("id")) is int and comment["id"] > 0, "invalid issue comment identity")
        if _issue_ignored_comment(comment, excluded_id):
            continue
        projected = _issue_fields(comment, "node_id author_association created_at body",
                                  "id path line side commit_id original_commit_id")
        projected.update(source="conversation", author=_issue_actor(comment.get("user")),
                         updated_at=comment.get("updated_at") or comment.get("created_at") or "")
        result.append(projected)
    _require_source(len({item["id"] for item in result}) == len(result), "duplicate issue comment evidence")
    return sorted(result, key=lambda item: item["id"])


def _issue_reference(event: dict[str, Any]) -> dict[str, Any]:
    result = _issue_fields(event, "event node_id created_at commit_id commit_url", "id")
    result.update(updated_at=event.get("updated_at") or event.get("created_at") or "",
                  actor=_issue_actor(event.get("actor")), source=None)
    source = (event.get("source") or {}).get("issue")
    if source is not None:
        projection = _issue_fields(source, "node_id title body state", "number id")
        projection.update(kind="pr" if source.get("pull_request") is not None else "issue",
                          repository=((source.get("repository") or {}).get("full_name") or "").lower(),
                          author=_issue_actor(source.get("user")))
        result["source"] = projection
    return result


def _issue_references(timeline: list[dict[str, Any]], cutoff: str) -> list[dict[str, Any]]:
    result = []
    for event in timeline:
        if event.get("event") not in ("cross-referenced", "connected", "disconnected", "referenced"):
            continue
        timestamp = _issue_timestamp(event.get("created_at"))
        if timestamp <= cutoff:
            result.append(_issue_reference(event))
    return sorted(result, key=lambda item: (item["created_at"], item["event"], item["id"] or 0))


def _issue_lock_anchor(issue: dict[str, Any], timeline: list[dict[str, Any]]) -> dict[str, Any] | None:
    locks = [event for event in timeline if event.get("event") in ("locked", "unlocked")]
    if issue.get("locked") is not True or not locks:
        return None
    for event in locks:
        _issue_timestamp(event.get("created_at"))
        _require_source(type(event.get("id")) is int and event["id"] > 0, "invalid issue lock identity")
    anchor = max(locks, key=lambda event: (event["created_at"], event["id"]))
    actor = anchor.get("actor") or {}
    _require_source(actor.get("type") == "User" and type(actor.get("id")) is int and actor["id"] > 0,
                    "issue lock has no authoritative actor")
    _require_source(isinstance(actor.get("login"), str) and re.fullmatch(r"[A-Za-z0-9_.-]+", actor["login"]) is not None,
                    "issue lock has no authoritative actor")
    if anchor["event"] != "locked":
        return None
    result = _issue_fields(anchor, "node_id created_at", "id")
    result["actor"] = {key: actor[key] for key in ("id", "login", "type")}
    return result


def _issue_lifecycle(issue: dict[str, Any], timeline: list[dict[str, Any]]) -> dict[str, Any]:
    result = _issue_fields(issue, "state", "state_reason active_lock_reason")
    result.update(locked=issue.get("locked") or False, lock_anchor=_issue_lock_anchor(issue, timeline))
    labels = [_issue_fields(label, "node_id name", "id") for label in issue.get("labels") or []]
    assignees = [_issue_actor(actor) for actor in issue.get("assignees") or []]
    result["labels"] = sorted(labels, key=lambda label: (label["name"], label["id"] or 0))
    result["assignees"] = sorted(assignees, key=lambda actor: (actor["login"], actor["id"] or 0))
    milestone = issue.get("milestone")
    result["milestone"] = None if milestone is None else _issue_fields(milestone, "node_id title", "id number")
    return result


def build_issue_signing_snapshot(reader: GitHubIssueReader, issued_at: str,
                                 excluded_comment_id: int | None = None) -> dict[str, Any]:
    """Reconstruct the V2 signing snapshot from trusted REST, never a caller verdict.

    Additional post-signing worker activity is retained conservatively. This is
    not the permissive historical lifecycle-continuity verifier.
    """
    _require_source(excluded_comment_id is None or (type(excluded_comment_id) is int and excluded_comment_id > 0),
                    "invalid excluded approval comment identity")
    cutoff = _issue_timestamp(issued_at)
    issue = reader.issue()
    comments = reader.collection("comments")
    timeline = reader.collection("timeline")
    _require_source(issue == reader.issue(), "issue changed while collecting its signing snapshot")
    _require_source(type(issue.get("id")) is int and issue["id"] > 0 and isinstance(issue.get("node_id"), str),
                    "issue has no authoritative identity")
    actor = _issue_actor(issue.get("user"))
    actor["association"] = issue.get("author_association") or ""
    return {
        "schema": "aidevops-approval-snapshot/v2",
        "target": {"kind": "issue", "repository": reader.repository.lower(), "number": reader.number,
                   "id": issue["id"], "node_id": issue["node_id"]},
        "author": actor, **_issue_fields(issue, "created_at title body"),
        "comments": _issue_comments(comments, excluded_comment_id),
        "linked_references": _issue_references(timeline, cutoff),
        "lifecycle": _issue_lifecycle(issue, timeline),
    }


def issue_snapshot_bytes(snapshot: dict[str, Any]) -> bytes:
    """V2 uses jq's UTF-8 JSON encoding, unlike the source proposal's ASCII JSON."""
    return json.dumps(snapshot, sort_keys=True, separators=(",", ":"), ensure_ascii=False,
                      allow_nan=False).replace("\x7f", "\\u007f").encode("utf-8")


def _issue_snapshot_child(descriptors: tuple[int, int], reader: GitHubIssueReader, issued_at: str,
                          excluded: int | None, approval_body: str | None) -> None:
    receiver, sender = descriptors
    os.close(receiver)
    try:
        if approval_body is not None:
            matches = [comment for comment in reader.collection("comments")
                       if isinstance(comment.get("body"), str) and comment["body"].startswith(approval_body)
                       and comment.get("author_association") in ("OWNER", "MEMBER", "COLLABORATOR")]
            _require_source(len(matches) == 1 and type(matches[0].get("id")) is int and matches[0]["id"] > 0,
                            "issue publication is unconfirmed or ambiguous")
            excluded = matches[0]["id"]
        snapshot = build_issue_signing_snapshot(reader, issued_at, excluded)
        result = snapshot if approval_body is None else {"snapshot": snapshot, "comment_id": excluded}
        content = issue_snapshot_bytes(result)
        _require_source(len(content) <= GITHUB_SNAPSHOT_BYTES, "issue snapshot exceeds the limit")
        content = b"OK\n" + content
    except Exception:
        content = b"ERROR"
    try:
        remaining = memoryview(content)
        while remaining:
            remaining = remaining[os.write(sender, remaining[:65536]):]
    finally:
        os.close(sender)


def _stop_issue_reader(process: Any) -> None:
    if process.pid is not None:
        if process.is_alive():
            process.terminate()
        process.join(1)
        if process.is_alive():
            process.kill()
            process.join(1)
        _require_source(not process.is_alive(), "issue reader cleanup failed; no authority was issued")
    process.close()


def _issue_reader_bytes(descriptor: int) -> bytes:
    deadline = time.monotonic() + GITHUB_OPERATION_SECONDS
    content = bytearray()
    while True:
        remaining = deadline - time.monotonic()
        _require_source(remaining > 0 and bool(select.select([descriptor], [], [], max(0, remaining))[0]),
                        "issue verification timed out; no authority was issued")
        chunk = os.read(descriptor, 65536)
        if not chunk:
            return bytes(content)
        content.extend(chunk)
        _require_source(len(content) <= GITHUB_SNAPSHOT_BYTES + 3, "issue snapshot exceeds the limit")


def collect_issue_signing_snapshot(reader: GitHubIssueReader, issued_at: str,
                                   excluded_comment_id: int | None = None, *,
                                   approval_body: str | None = None) -> dict[str, Any]:
    """Bound DNS, headers, pagination and parsing in an owned, non-daemon child.

    Only bytes cross the return pipe; no pickle is accepted from the child.
    Fork runs the already-validated core, not a mutable executable or callback.
    """
    _require_source(type(reader) is GitHubIssueReader, "unsupported issue reader")
    context = multiprocessing.get_context("fork")
    receiver, sender = os.pipe()
    process = context.Process(target=_issue_snapshot_child,
                              args=((receiver, sender), reader, issued_at, excluded_comment_id, approval_body), daemon=False)
    try:
        process.start()
        os.close(sender)
        sender = -1
        content = _issue_reader_bytes(receiver)
        _require_source(content.startswith(b"OK\n"), "issue verification failed; no authority was issued")
        return json.loads(content[3:].decode("utf-8"), object_pairs_hook=_github_json_object,
                          parse_constant=_github_json_constant, parse_float=_github_json_float)
    except (OSError, EOFError, ValueError):
        raise SourceAccessError("issue verification failed; no authority was issued") from None
    finally:
        os.close(receiver)
        if sender >= 0:
            os.close(sender)
        _stop_issue_reader(process)


def _credential_output(process: subprocess.Popen, deadline: float) -> str:
    content = bytearray()
    _require_source(process.stdout is not None, "GitHub authentication is unavailable")
    descriptor = process.stdout.fileno()
    while True:
        remaining = deadline - time.monotonic()
        _require_source(remaining > 0, "GitHub authentication timed out")
        ready, _, _ = select.select([descriptor], [], [], remaining)
        _require_source(bool(ready), "GitHub authentication timed out")
        chunk = os.read(descriptor, 4098 - len(content))
        if not chunk:
            break
        content.extend(chunk)
        _require_source(len(content) <= 4097, "GitHub authentication output exceeds the limit")
    _require_source(process.wait(timeout=max(0.01, deadline - time.monotonic())) == 0,
                    "GitHub authentication is unavailable")
    credential = bytes(content).decode("ascii").strip()
    _require_source(re.fullmatch(r"[A-Za-z0-9_.-]{1,4096}", credential) is not None,
                    "GitHub authentication is unavailable")
    return credential


def _github_user_context(uid: int) -> tuple[Any, dict[str, str], dict[str, Any]]:
    _require_source(type(uid) is int and uid > 0, "GitHub authentication requires a non-root owner")
    account = pwd.getpwuid(uid)
    environment = {"HOME": account.pw_dir, "USER": account.pw_name, "LOGNAME": account.pw_name,
                   "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
                   "GH_PROMPT_DISABLED": "1", "GH_HOST": "github.com"}
    identity = {"user": uid, "group": account.pw_gid, "extra_groups": []} if os.geteuid() == 0 else {}
    _require_source(os.geteuid() in (0, uid), "GitHub authentication user mismatch")
    return account, environment, identity


def github_credential_for_user(uid: int) -> str:
    """Read existing gh authentication as that user; never execute gh as root.

    The token is only data for the fixed TLS peer, not proof of issue approval.
    Credential values never enter argv, logs, errors or a persistent artifact.
    """
    account, environment, identity = _github_user_context(uid)
    # #aidevops:trust-boundary — Popen drops all root/group authority in its
    # fork/exec implementation BEFORE env resolves or executes user-managed gh.
    process = subprocess.Popen(  # nosec B603 -- fixed argv; user/group drop precedes exec
        ["/usr/bin/env", "gh", "auth", "token", "--hostname", "github.com"],
        stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
        cwd=account.pw_dir, env=environment, close_fds=True, **identity,
    )
    try:
        return _credential_output(process, time.monotonic() + 10)
    except (OSError, ValueError, subprocess.TimeoutExpired):
        raise SourceAccessError("GitHub authentication is unavailable") from None
    finally:
        if process.poll() is None:
            process.kill()
        process.wait(timeout=2)
        if process.stdout is not None:
            process.stdout.close()


def github_issue_action(uid: int, reader: GitHubIssueReader, action: str, body: bytes = b"") -> bool:
    """Unprivileged mutation transport. Its exit status NEVER proves approval."""
    _require_source(type(reader) is GitHubIssueReader and len(body) <= MAX_REQUEST_BYTES,
                    "invalid issue action")
    account, environment, identity = _github_user_context(uid)
    environment["AIDEVOPS_SESSION_ORIGIN"] = "interactive"
    wrapper = str(Path(account.pw_dir) / ".aidevops" / "agents" / "scripts" / "gh-write-helper.sh")
    commands = {
        "lock": ["/usr/bin/env", "gh", "issue", "lock", str(reader.number), "--repo", reader.repository, "--reason", "resolved"],
        "unlock": ["/usr/bin/env", "gh", "issue", "unlock", str(reader.number), "--repo", reader.repository],
        "publish": ["/usr/bin/env", "bash", wrapper, "issue", "comment", str(reader.number),
                    "--repo", reader.repository, "--body-file", "-"],
    }
    _require_source(action in commands, "unsupported issue action")
    # #aidevops:trust-boundary — execute wrappers only after dropping privilege;
    # the broker independently reads GitHub over trusted TLS before granting.
    process = subprocess.Popen(  # nosec B603 -- enumerated user-only operations, never a caller command
        commands[action], stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        cwd=account.pw_dir, env=environment, close_fds=True, **identity,
    )
    try:
        process.communicate(input=body, timeout=20)
        return process.returncode == 0
    except (OSError, subprocess.TimeoutExpired):
        return False
    finally:
        if process.poll() is None:
            process.kill()
        process.wait(timeout=2)


@dataclass(frozen=True)
class Config:
    config_dir: Path = Path("/etc/aidevops/source-access")
    state_dir: Path = Path("/var/run/aidevops/source-access")
    request_root: Path | None = None
    trust_uid: int = 0

    @property
    def private_key(self) -> Path:
        return self.config_dir / "private" / "source-access.key"

    @property
    def public_key(self) -> Path:
        return self.config_dir / "source-access.pub"

    @property
    def trust_marker(self) -> Path:
        return self.config_dir / "source-access.trust"


@dataclass(frozen=True)
class RequestSpec:
    session_id: str
    uid: int
    home: Path
    path: str
    reason: str
    now: int | None = None


@dataclass(frozen=True)
class ManifestRequestSpec:
    session_id: str
    uid: int
    home: Path
    paths: tuple[str, ...]
    reason: str
    now: int = field(default_factory=_current_timestamp)


@dataclass(frozen=True)
class ApprovalSpec:
    request_id: str
    home: Path
    expected_uid: int
    ttl_seconds: int
    now: int | None = None
    confirm: Callable[[dict[str, Any]], bool] | None = None


@dataclass(frozen=True)
class VerificationSpec:
    session_id: str
    uid: int
    path: str
    reason: str
    now: int | None = None
    context_socket: str = ""


@dataclass(frozen=True)
class ApprovalBinding:
    approval_id: str
    checked_at: int
    path: str
    reason: str
    receipt_path: Path
    session_id: str
    snapshot_path: Path
    uid: int


def canonical_json(value: Any) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode("utf-8")


def _run(command: list[str], *, input_bytes: bytes | None = None) -> subprocess.CompletedProcess[bytes]:
    _require_source(bool(command) and command[0] in (GIT, SSH_KEYGEN), "required command is not approved")
    environment = None
    if command and command[0] == GIT:
        # #aidevops:trust-boundary — even ls-files runs core.fsmonitor. Never
        # execute repository hooks or inherit a caller's Git scope as the broker.
        command = [GIT, "--no-pager", "--literal-pathspecs", "-c", "core.fsmonitor=false",
                   "-c", "core.hooksPath=/dev/null", *command[1:]]
        environment = {"PATH": "/usr/bin:/bin", "LC_ALL": "C", "GIT_CONFIG_NOSYSTEM": "1",
                       "GIT_CONFIG_GLOBAL": os.devnull, "GIT_OPTIONAL_LOCKS": "0"}
    try:
        return subprocess.run(  # nosec B603 -- fixed system binary allowlist, argv only, Git hooks disabled
            command,
            input=input_bytes,
            env=environment,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
            timeout=15,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise SourceAccessError(f"required command failed: {command[0]}") from exc


def _ensure_directory(path: Path, mode: int, owner_uid: int | None = None) -> None:
    path.mkdir(parents=True, exist_ok=True)
    os.chmod(path, mode)
    if owner_uid is not None and os.geteuid() == 0:
        os.chown(path, owner_uid, 0)


def atomic_write(
    path: Path,
    content: bytes,
    mode: int,
    owner_uid: int | None = None,
    directory_mode: int | None = None,
) -> None:
    parent_mode = directory_mode if directory_mode is not None else (0o755 if mode == 0o644 else 0o700)
    _ensure_directory(path.parent, parent_mode, owner_uid)
    descriptor, temp_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(content)
            handle.flush()
            os.fsync(handle.fileno())
            os.fchmod(handle.fileno(), mode)
            if owner_uid is not None and os.geteuid() == 0:
                os.fchown(handle.fileno(), owner_uid, 0)
        os.replace(temp_name, path)
    finally:
        try:
            os.unlink(temp_name)
        except FileNotFoundError:
            pass


def _private_descriptor_acl_safe(descriptor: int) -> bool:
    # POSIX ACL masks are covered by the mode check. Darwin extended ACLs can
    # independently grant access even at 0600/0700; inspect the held object.
    if sys.platform != "darwin":
        return True
    library = ctypes.CDLL(None, use_errno=True)
    library.acl_get_fd_np.argtypes = [ctypes.c_int, ctypes.c_int]
    library.acl_get_fd_np.restype = ctypes.c_void_p
    library.acl_to_text.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_ssize_t)]
    library.acl_to_text.restype = ctypes.c_void_p
    library.acl_free.argtypes = [ctypes.c_void_p]
    ctypes.set_errno(0)
    acl = library.acl_get_fd_np(descriptor, 0x100)  # ACL_TYPE_EXTENDED, Darwin SDK sys/acl.h
    if not acl:
        return ctypes.get_errno() in (2, 93)  # ENOENT/ENOATTR: no ACL on a valid held descriptor
    text = None
    try:
        length = ctypes.c_ssize_t()
        text = library.acl_to_text(acl, ctypes.byref(length))
        if not text or not 0 <= length.value <= 65536:
            return False
        return ctypes.string_at(text, length.value).rstrip(b"\x00\r\n\t ") in (b"", b"!#acl 1")
    finally:
        if text:
            library.acl_free(text)
        library.acl_free(acl)


@contextmanager
def protected_key_descriptor(path: Path, owner_uid: int) -> Iterator[int]:
    """Hold the validated original key object even if its pathname is replaced."""
    try:
        descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except OSError:
        raise SourceAccessError("signing key is unavailable or unsafe") from None
    try:
        metadata = os.fstat(descriptor)
        _require_source(stat.S_ISREG(metadata.st_mode) and metadata.st_uid == owner_uid
                        and metadata.st_nlink == 1 and metadata.st_mode & 0o077 == 0,
                        "issue signing key ownership or permissions are unsafe")
        _require_source(_private_descriptor_acl_safe(descriptor), "signing key has an unexpected extended ACL")
        _require_source(metadata.st_size <= 32768, "unsupported signing key size")
        content = os.read(descriptor, 32769)
        lines = content.strip().splitlines()
        _require_source(len(content) <= 32768 and len(lines) >= 3
                        and lines[0] == b"-----BEGIN OPENSSH PRIVATE KEY-----"
                        and lines[-1] == b"-----END OPENSSH PRIVATE KEY-----", "unsupported signing key format")
        binary = base64.b64decode(b"".join(lines[1:-1]), validate=True)
        _require_source(binary.startswith(b"openssh-key-v1\x00\x00\x00\x00\x04none\x00\x00\x00\x04none\x00\x00\x00\x00\x00\x00\x00\x01"),
                        "signing requires one unencrypted, root-protected OpenSSH key")
        os.lseek(descriptor, 0, os.SEEK_SET)
        yield descriptor
        final = os.fstat(descriptor)
        current = path.lstat()
        fields = ("st_dev", "st_ino", "st_uid", "st_mode", "st_nlink", "st_size", "st_mtime_ns", "st_ctime_ns")
        _require_source((current.st_dev, current.st_ino) == (metadata.st_dev, metadata.st_ino)
                        and all(getattr(final, name) == getattr(metadata, name) for name in fields),
                        "signing key changed during approval")
    except (OSError, ValueError):
        raise SourceAccessError("signing key is unavailable or unsafe") from None
    finally:
        os.close(descriptor)


def _descriptor_key_command(descriptor: int, arguments: list[str], content: bytes = b"") -> bytes:
    os.lseek(descriptor, 0, os.SEEK_SET)
    environment = {"PATH": "/usr/bin:/bin", "HOME": "/var/empty", "LC_ALL": "C", "SSH_ASKPASS_REQUIRE": "never"}
    try:
        result = subprocess.run(  # nosec B603 -- fixed system signer; descriptor-pinned key and no askpass/agent environment
            [SSH_KEYGEN, *arguments], input=content, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            env=environment, pass_fds=(descriptor,), check=False, timeout=15,
        )
        _require_source(result.returncode == 0, "descriptor-bound signing operation failed")
        return result.stdout
    except (OSError, subprocess.TimeoutExpired):
        raise SourceAccessError("descriptor-bound signing operation failed") from None


def descriptor_public_key(descriptor: int) -> bytes:
    parts = _descriptor_key_command(descriptor, ["-y", "-P", "", "-f", f"/dev/fd/{descriptor}"]).split()
    _require_source(len(parts) >= 2 and parts[0] == b"ssh-ed25519", "approval requires an Ed25519 signing key")
    return b" ".join(parts[:2])


def descriptor_signature(config: Config, descriptor: int, namespace: str, content: bytes) -> str:
    _require_source(namespace in (SIGNATURE_NAMESPACE, ISSUE_SIGNATURE_NAMESPACE), "unsupported signing namespace")
    signing_root = root_data_directory(config.config_dir / "private" / "signing", config.trust_uid)
    _require_source(len(list(signing_root.iterdir())) < 128, "private signing workspace requires cleanup")
    # macOS /dev/fd shares offsets across ssh-keygen's repeated private-key opens.
    # Copy only from the held object, inside immutable root-owned ancestry; the
    # signed payload stays on stdin and no caller-selected scratch path is used.
    with tempfile.TemporaryDirectory(prefix="key-", dir=signing_root) as temporary:
        key_path = Path(temporary) / "key"
        os.lseek(descriptor, 0, os.SEEK_SET)
        key = os.read(descriptor, 32769)
        _require_source(len(key) <= 32768, "signing key changed")
        atomic_write(key_path, key, 0o600, config.trust_uid)
        return _descriptor_key_command(descriptor,
                                       ["-Y", "sign", "-f", str(key_path), "-n", namespace, "-q", "-"],
                                       content).decode("ascii")


def root_data_directory(path: Path, owner_uid: int, mode: int = 0o700) -> Path:
    """Create only under trusted existing ancestry; never chown foreign state."""
    parent = path.parent.resolve(strict=False)
    existing = parent
    while not existing.exists():
        existing = existing.parent
    for ancestor in (existing, *existing.parents):
        metadata = ancestor.stat()
        _require_source(metadata.st_uid in (0, owner_uid) and metadata.st_mode & 0o022 == 0,
                        "broker state ancestry is unsafe")
    if not path.parent.exists():
        root_data_directory(path.parent, owner_uid, 0o755)
    path.mkdir(mode=mode, exist_ok=True)
    _require_source(_trusted_directory(path, owner_uid), "broker state ownership or permissions are unsafe")
    if mode == 0o700:
        _require_source(path.stat().st_mode & 0o077 == 0, "broker private directory is not private")
        descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        try:
            _require_source(_private_descriptor_acl_safe(descriptor), "broker private directory has an extended ACL")
        finally:
            os.close(descriptor)
    return path


def private_bundle_parent(config: Config, uid: int) -> Path:
    _require_source(type(uid) is int and uid > 0, "bundle requires a non-root owner")
    parent = root_data_directory(config.state_dir / "bundles" / str(uid), config.trust_uid, 0o755)
    if uid == config.trust_uid:
        os.chmod(parent, 0o700)
        return parent
    if sys.platform == "darwin":
        command = ["/bin/chmod", "-E", str(parent)]
        content = f"user:{uid} allow list,search,readattr,readextattr,readsecurity\n".encode("ascii")
    else:
        _require_source(sys.platform.startswith("linux"), "private bundle ACLs are unsupported on this platform")
        command = ["/usr/bin/setfacl", "--set", f"u::rwx,u:{uid}:r-x,g::---,m::r-x,o::---", "--", str(parent)]
        content = b""
    executable = Path(command[0]).resolve(strict=True)
    _require_source(_trusted_file(executable, 0) and all(_trusted_directory(item, 0) for item in executable.parents),
                    "private publication requires a trusted system ACL tool")
    result = subprocess.run(  # nosec B603 -- fixed platform ACL executable and numeric UID; no caller command
        command, input=content, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        env={"PATH": "/usr/bin:/bin", "LC_ALL": "C"}, check=False, timeout=5,
    )
    _require_source(result.returncode == 0, "private bundle ACL setup failed")
    if sys.platform == "darwin":
        os.chmod(parent, 0o700)
    return parent


def atomic_bundle_directory(config: Config, uid: int, approval_id: str) -> Path:
    _require_source(type(uid) is int and uid > 0 and re.fullmatch(r"[a-f0-9]{64}", approval_id) is not None,
                    "invalid bundle identity")
    return config.state_dir / "bundles" / str(uid) / approval_id


def bundle_journal_path(config: Config, uid: int, proposal_id: str) -> Path:
    _require_source(type(uid) is int and uid > 0 and re.fullmatch(r"[a-f0-9]{64}", proposal_id) is not None,
                    "invalid transaction identity")
    directory = root_data_directory(config.config_dir / "transactions" / str(uid), config.trust_uid)
    return directory / f"{proposal_id}.json"


@contextmanager
def bundle_transaction_lock(config: Config, uid: int, proposal_id: str, kind: str) -> Iterator[None]:
    _require_source(kind in ("operation", "commit"), "invalid transaction lock")
    path = bundle_journal_path(config, uid, proposal_id).with_suffix(f".{kind}.lock")
    descriptor = os.open(path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600)
    try:
        metadata = os.fstat(descriptor)
        _require_source(stat.S_ISREG(metadata.st_mode) and metadata.st_uid == config.trust_uid
                        and metadata.st_mode & 0o077 == 0 and metadata.st_nlink == 1, "unsafe transaction lock")
        fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        yield
    except BlockingIOError:
        raise SourceAccessError("bundle transaction is already in progress") from None
    finally:
        os.close(descriptor)


def withdraw_atomic_bundle(config: Config, uid: int, approval_id: str) -> bool:
    if len(approval_id) != 64 or type(uid) is not int or uid <= 0:
        return False
    directory = atomic_bundle_directory(config, uid, approval_id)
    if not os.path.lexists(directory):
        return _trusted_file(config.state_dir / "revocations" / str(uid) / f"{approval_id}.json", config.trust_uid)
    _require_source(_trusted_directory(directory, config.trust_uid), "bundle directory is unsafe")
    original = approval_id
    try:
        receipt_path = directory / "receipt.json"
        _require_source(_trusted_file(receipt_path, config.trust_uid), "bundle receipt is unsafe")
        _require_source(receipt_path.stat().st_size <= 1024 * 1024, "bundle receipt exceeds the limit")
        receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
        candidate = receipt.get("payload", {}).get("original_proposal_id", "")
        if isinstance(candidate, str) and re.fullmatch(r"[a-f0-9]{64}", candidate):
            original = candidate
    except (OSError, ValueError, AttributeError, SourceAccessError):
        pass  # Revocation must also withdraw a corrupted, root-owned bundle.
    with bundle_transaction_lock(config, uid, original, "commit"):
        revocations = root_data_directory(config.state_dir / "revocations" / str(uid), config.trust_uid, 0o755)
        atomic_write(revocations / f"{approval_id}.json", b'{"revoked":true}\n', 0o644, config.trust_uid)
        private = root_data_directory(config.state_dir / ".revoked" / str(uid), config.trust_uid)
        destination = private / f"{approval_id}-{secrets.token_hex(16)}"
        os.replace(directory, destination)
        journal_path = bundle_journal_path(config, uid, original)
        try:
            if journal_path.exists():
                journal = _read_request_record(journal_path, config.trust_uid)
                if journal.get("approval_id") == approval_id:
                    journal["state"] = "REVOKED"
                    atomic_write(journal_path, canonical_json(journal), 0o600, config.trust_uid)
        finally:
            shutil.rmtree(destination)
    return True


def manifest_receipt_paths(config: Config, uid: int) -> list[Path]:
    result = []
    legacy = config.state_dir / "approvals" / str(uid)
    if _trusted_directory(legacy, config.trust_uid):
        result.extend(sorted(legacy.glob("*.json")))
    bundles = config.state_dir / "bundles" / str(uid)
    if _trusted_directory(bundles, config.trust_uid):
        for candidate in sorted(bundles.iterdir()):
            if re.fullmatch(r"[a-f0-9]{64}", candidate.name) and _trusted_directory(candidate, config.trust_uid):
                result.append(candidate / "receipt.json")
    return result


def _require_source(condition: bool, message: str) -> None:
    if not condition:
        raise SourceAccessError(message)


def _validate_session_id(session_id: str) -> str:
    _require_source(SESSION_PATTERN.fullmatch(session_id) is not None, "invalid runtime session identifier")
    return session_id


def _validate_reason(reason: str) -> str:
    _require_source(reason == OVERRIDABLE_REASON, "only the basename-only source guard can be approved")
    return reason


def _path_components(path: Path) -> list[Path]:
    current = Path(path.anchor)
    components = []
    for part in path.parts[1:]:
        current /= part
        components.append(current)
    return components


def _is_symlink(path: Path) -> bool:
    try:
        return stat.S_ISLNK(os.lstat(path).st_mode)
    except FileNotFoundError:
        return False


def _has_symlink_component(path: Path) -> bool:
    return any(_is_symlink(component) for component in _path_components(path))


def canonical_tracked_source(raw_path: str) -> str:
    _require_source(bool(raw_path), "source path is empty or contains control characters")
    _require_source(
        all(ord(character) >= 32 for character in raw_path),
        "source path is empty or contains control characters",
    )
    absolute = Path(os.path.abspath(os.path.expanduser(raw_path)))
    _require_source(not _has_symlink_component(absolute), "symlinked source paths cannot be approved")
    try:
        resolved = absolute.resolve(strict=True)
        file_stat = resolved.stat()
    except OSError as exc:
        raise SourceAccessError("source path is unavailable") from exc
    _require_source(stat.S_ISREG(file_stat.st_mode), "source path is not a regular file")

    basename = resolved.name.lower()
    _require_source(
        not basename.startswith(".env") and basename not in DENIED_NAMES,
        "credential-like source paths cannot be approved",
    )
    suffix = resolved.suffix.lower()
    _require_source(suffix not in DENIED_SUFFIXES, "private key and credential containers cannot be approved")
    _require_source(suffix in ALLOWED_SUFFIXES, "path is not an approved source or documentation type")

    root_result = _run([GIT, "-C", str(resolved.parent), "rev-parse", "--show-toplevel"])
    _require_source(root_result.returncode == 0, "source path is not inside a Git worktree")
    git_root = Path(root_result.stdout.decode("utf-8").strip()).resolve()
    try:
        relative_path = resolved.relative_to(git_root)
    except ValueError as exc:
        raise SourceAccessError("source path escapes its Git worktree") from exc
    tracked_result = _run(
        [GIT, "-C", str(git_root), "ls-files", "--error-unmatch", "--", str(relative_path)]
    )
    _require_source(tracked_result.returncode == 0, "only Git-tracked source files can be approved")
    return str(resolved)


def tracked_source_identity(raw_path: str) -> tuple[str, str, str]:
    path = canonical_tracked_source(raw_path)
    resolved = Path(path)
    root_result = _run([GIT, "-C", str(resolved.parent), "rev-parse", "--show-toplevel"])
    _require_source(root_result.returncode == 0, "source path is not inside a Git worktree")
    repo_root = str(Path(root_result.stdout.decode("utf-8").strip()).resolve())
    relative_path = str(resolved.relative_to(Path(repo_root)))
    return path, repo_root, relative_path


def scope_id(session_id: str, uid: int, path: str, reason: str) -> str:
    scope = f"{session_id}\0{uid}\0{path}\0{reason}".encode("utf-8")
    return hashlib.sha256(scope).hexdigest()


def repository_id(repo_root: str) -> str:
    return hashlib.sha256(repo_root.encode("utf-8")).hexdigest()


def manifest_scope_id(
    session_id: str, uid: int, repo_root: str, reason: str, paths: list[str]
) -> str:
    scope = "\0".join([session_id, str(uid), repo_root, reason, *paths]).encode("utf-8")
    return hashlib.sha256(scope).hexdigest()


def secure_source_content(path: str) -> tuple[bytes, str]:
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0)
    try:
        descriptor = os.open(path, flags)
    except OSError as exc:
        raise SourceAccessError("source path could not be opened safely") from exc
    digest = hashlib.sha256()
    content = bytearray()
    total = 0
    try:
        opened_stat = os.fstat(descriptor)
        _require_source(
            stat.S_ISREG(opened_stat.st_mode) and opened_stat.st_nlink == 1,
            "hard-linked or non-regular source files cannot be approved",
        )
        _require_source(
            opened_stat.st_size <= MAX_SOURCE_BYTES,
            "source file exceeds the approval size limit",
        )
        while chunk := os.read(descriptor, 64 * 1024):
            total += len(chunk)
            _require_source(total <= MAX_SOURCE_BYTES, "source file exceeds the approval size limit")
            content.extend(chunk)
            digest.update(chunk)
        current_stat = os.lstat(path)
        final_stat = os.fstat(descriptor)
        identity_fields = (
            "st_dev", "st_ino", "st_mode", "st_nlink", "st_uid",
            "st_size", "st_mtime_ns", "st_ctime_ns",
        )
        _require_source(
            stat.S_ISREG(current_stat.st_mode)
            and current_stat.st_dev == opened_stat.st_dev
            and current_stat.st_ino == opened_stat.st_ino
            and all(getattr(final_stat, field) == getattr(opened_stat, field) for field in identity_fields),
            "source path changed during approval",
        )
    except OSError as exc:
        raise SourceAccessError("source path changed during approval") from exc
    finally:
        os.close(descriptor)
    return bytes(content), digest.hexdigest()


def require_source_only_content(content: bytes) -> None:
    """Reject binary data and credential indicators, without returning matched bytes.

    This is conservative screening, not proof that arbitrary text has no secret.
    The tracked-path, exact-byte binding and explicit human review remain required;
    no content finding is overridable by the basename-only approval mechanism.
    """
    _require_source(len(content) <= MAX_SOURCE_BYTES, "source exceeds the classification limit")
    try:
        text = content.decode("utf-8")
    except UnicodeDecodeError:
        raise SourceAccessError("only UTF-8 source text can be approved") from None
    _require_source(not any(ord(character) < 32 and character not in "\t\n\r" for character in text),
                    "binary or control-bearing source cannot be approved")
    patterns = (
        r"-----BEGIN (?:[A-Z0-9 ]*PRIVATE KEY|PGP PRIVATE KEY BLOCK)-----",
        r"\b(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|AKIA[A-Z0-9]{16})\b",
        r"\b(?:sk-(?:proj-)?[A-Za-z0-9_-]{20,}|xox[baprs]-[A-Za-z0-9-]{15,})\b",
        r"(?i)\b(?:https?|postgres(?:ql)?|mysql|mongodb(?:\+srv)?)://[^\s/:]+:[^\s/@]+@",
        r'''(?im)(?:^|[\s{,])['"]?(?:[a-z0-9]+_)*(?:password|passwd|secret|token|api_key|private_key)['"]?\s*[:=]\s*['"][^'"\r\n$]+['"]''',
        r"(?im)^\s*(?:export\s+)?(?:[a-z0-9]+_)*(?:password|passwd|secret|token|api_key|private_key)\s*=\s*[a-z0-9+/][^\s;]*",
    )
    _require_source(not any(re.search(pattern, text) for pattern in patterns),
                    "credential indicators cannot be approved as a basename-only source exception")


def request_directory(config: Config, home: Path) -> Path:
    return config.request_root or home / ".aidevops" / ".agent-workspace" / "source-access" / "requests"


def _reusable_request_id(
    existing: dict[str, Any], spec: RequestSpec, path: str, issued_at: int
) -> str | None:
    created_at = existing.get("created_at")
    if isinstance(created_at, bool) or not isinstance(created_at, int):
        return None
    expected = {
        "schema": SCHEMA_REQUEST,
        "session_id": spec.session_id,
        "uid": spec.uid,
        "path": path,
        "reason": spec.reason,
    }
    if any(existing.get(key) != value for key, value in expected.items()):
        return None
    request_age = issued_at - created_at
    if request_age < 0 or request_age > REQUEST_REUSE_SECONDS:
        return None
    request_id = str(existing.get("request_id", ""))
    return request_id if ID_PATTERN.fullmatch(request_id) else None


def create_request(config: Config, spec: RequestSpec) -> str:
    issued_at = int(time.time() if spec.now is None else spec.now)
    session_id = _validate_session_id(spec.session_id)
    reason = _validate_reason(spec.reason)
    path = canonical_tracked_source(spec.path)
    normalized_spec = RequestSpec(session_id, spec.uid, spec.home, path, reason, spec.now)
    directory = request_directory(config, spec.home)
    _ensure_directory(directory, 0o700)

    for candidate in directory.glob("*.json"):
        try:
            existing = json.loads(candidate.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            continue
        reusable_id = _reusable_request_id(existing, normalized_spec, path, issued_at)
        if reusable_id is not None:
            return reusable_id

    request_id = secrets.token_hex(16)
    request = {
        "schema": SCHEMA_REQUEST,
        "request_id": request_id,
        "session_id": session_id,
        "uid": spec.uid,
        "path": path,
        "reason": reason,
        "created_at": issued_at,
    }
    atomic_write(directory / f"{request_id}.json", canonical_json(request) + b"\n", 0o600)
    return request_id


def create_manifest_request(config: Config, spec: ManifestRequestSpec) -> str:
    issued_at = spec.now
    session_id = _validate_session_id(spec.session_id)
    reason = _validate_reason(spec.reason)
    _require_source(
        2 <= len(spec.paths) <= MAX_MANIFEST_ENTRIES,
        f"source-access manifests require 2 to {MAX_MANIFEST_ENTRIES} paths",
    )
    identities = list(map(tracked_source_identity, spec.paths))
    repo_roots = set(map(itemgetter(1), identities))
    _require_source(len(repo_roots) == 1, "all manifest paths must belong to one Git worktree")
    entries = sorted(map(_manifest_entry, identities), key=itemgetter("relative_path"))
    paths = list(map(itemgetter("path"), entries))
    _require_source(len(paths) == len(set(paths)), "source-access manifest paths must be unique")
    repo_root = repo_roots.pop()
    request_id = manifest_scope_id(session_id, spec.uid, repo_root, reason, paths)
    request = {
        "schema": SCHEMA_MANIFEST_REQUEST,
        "request_id": request_id,
        "session_id": session_id,
        "uid": spec.uid,
        "repo_root": repo_root,
        "repository_id": repository_id(repo_root),
        "reason": reason,
        "entries": entries,
        "created_at": issued_at,
    }
    directory = request_directory(config, spec.home)
    _ensure_directory(directory, 0o700)
    request_path = directory / f"{request_id}.json"
    atomic_write(request_path, canonical_json(request) + b"\n", 0o600)
    return request_id


def _manifest_entry(identity: tuple[str, str, str]) -> dict[str, str]:
    path, _repo_root, relative_path = identity
    return {"path": path, "relative_path": relative_path}


def proposal_directory(config: Config, home: Path) -> Path:
    return request_directory(config, home) / "proposals"


def _source_context_socket(path: Path, uid: int) -> dict[str, int]:
    _require_source(path.is_absolute() and not _has_symlink_component(path), "unsafe context socket")
    for ancestor in path.parents:
        metadata = ancestor.lstat()
        _require_source(
            stat.S_ISDIR(metadata.st_mode) and metadata.st_uid in (0, uid)
            and metadata.st_mode & 0o022 == 0,
            "unsafe context socket ancestry",
        )
    _require_source(_trusted_private_directory(path.parent, uid), "unsafe context socket directory")
    metadata = path.lstat()
    _require_source(
        stat.S_ISSOCK(metadata.st_mode) and metadata.st_uid == uid
        and metadata.st_mode & 0o077 == 0 and metadata.st_nlink == 1,
        "unsafe context socket",
    )
    return {"device": metadata.st_dev, "inode": metadata.st_ino}


def _context_peer_identity(connection: socket.socket) -> tuple[int, int]:
    if sys.platform == "darwin":
        # Darwin sys/un.h: SOL_LOCAL=0, LOCAL_PEERCRED=1, LOCAL_PEERPID=2.
        # sys/ucred.h: xucred begins with cr_version and effective cr_uid.
        credentials = connection.getsockopt(0, 1, 128)
        version, uid = struct.unpack_from("=II", credentials)
        _require_source(version == 0, "unsupported context peer credential layout")
        return connection.getsockopt(0, 2), uid
    _require_source(hasattr(socket, "SO_PEERCRED"), "context peer credentials are unsupported")
    credentials = connection.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, 12)
    pid, uid, _gid = struct.unpack("=iII", credentials)
    return pid, uid


def _validated_context_reply(
    reply: Any, query: dict[str, Any], pid: int, uid: int
) -> dict[str, Any]:
    _require_source(isinstance(reply, dict), "invalid source context response")
    expected = {"schema": "aidevops-source-context-reply/v1", "authority": "none",
                "nonce": query["nonce"], "session_id": query["session_id"],
                "repo_root": query["repo_root"], "runtime_pid": pid, "uid": uid}
    _require_source(
        all(reply.get(key) == value for key, value in expected.items())
        and type(reply.get("runtime_pid")) is int and type(reply.get("uid")) is int,
        "source context peer identity or challenge did not match",
    )
    generation_error = "source context generation is invalid"
    _require_source(
        isinstance(reply.get("runtime_instance_id"), str)
        and re.fullmatch(r"[a-f0-9]{32}", reply["runtime_instance_id"]) is not None,
        generation_error,
    )
    _require_source(
        type(reply.get("session_created_at")) is int and reply["session_created_at"] >= 0,
        generation_error,
    )
    _require_source(
        isinstance(reply.get("project_id"), str) and 0 < len(reply["project_id"]) <= 256,
        generation_error,
    )
    fields = ("session_id", "repo_root", "runtime_pid", "uid", "runtime_instance_id",
              "session_created_at", "project_id")
    return {key: reply[key] for key in fields}


def _context_timeout(deadline: float) -> float:
    remaining = deadline - time.monotonic()
    _require_source(remaining > 0, "source context deadline exceeded")
    return remaining


def query_source_context(socket_path: str, session_id: str, repo_root: str, uid: int) -> dict[str, Any]:
    """Challenge a live peer. This metadata alone never authorizes source reads."""
    query = {"schema": "aidevops-source-context-query/v1", "nonce": secrets.token_hex(32),
             "session_id": _validate_session_id(session_id), "repo_root": repo_root}
    path = Path(socket_path)
    try:
        identity = _source_context_socket(path, uid)
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
            deadline = time.monotonic() + 5
            connection.settimeout(_context_timeout(deadline))
            connection.connect(str(path))
            pid, peer_uid = _context_peer_identity(connection)
            _require_source(pid > 0 and peer_uid == uid, "source context belongs to another user")
            connection.settimeout(_context_timeout(deadline))
            connection.sendall(canonical_json(query) + b"\n")
            response = bytearray()
            while True:
                connection.settimeout(_context_timeout(deadline))
                chunk = connection.recv(4096)
                if not chunk:
                    break
                response.extend(chunk)
                _require_source(len(response) <= 8192, "source context response is too large")
            reply = json.loads(response.decode("utf-8"))
        _require_source(identity == _source_context_socket(path, uid), "source context socket changed")
        context = _validated_context_reply(reply, query, pid, peer_uid)
        return {**context, "socket_path": str(path), "socket_identity": identity}
    except (OSError, ValueError, struct.error, RecursionError) as exc:
        raise SourceAccessError("source context is unavailable; no authority was issued") from exc


@contextmanager
def _proposal_store(config: Config, home: Path, uid: int) -> Iterator[Path]:
    """Serialize user-space proposal metadata; never run this writer as sudo."""
    _require_source(type(uid) is int and uid > 0 and os.geteuid() == uid,
                    "prepare or withdraw proposals as their non-root owning user")
    directory = proposal_directory(config, home)
    _require_source(not _has_symlink_component(directory), "unsafe proposal directory")
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    _require_source(_trusted_private_directory(directory, uid), "unsafe proposal directory")
    flags = os.O_CREAT | os.O_RDWR | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0)
    try:
        descriptor = os.open(directory / ".lock", flags, 0o600)
    except OSError as exc:
        raise SourceAccessError("unsafe or unavailable proposal lock") from exc
    try:
        metadata = os.fstat(descriptor)
        _require_source(
            stat.S_ISREG(metadata.st_mode) and metadata.st_uid == uid
            and metadata.st_nlink == 1 and metadata.st_mode & 0o077 == 0,
            "unsafe proposal lock",
        )
        fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        yield directory
    except OSError as exc:
        raise SourceAccessError("proposal store unavailable or busy; no authority was changed") from exc
    finally:
        os.close(descriptor)


def _proposal_file_identity(path: Path) -> dict[str, int]:
    metadata = path.lstat()
    return {"device": metadata.st_dev, "inode": metadata.st_ino}


def _proposal_repository_identity(repo_root: str) -> dict[str, Any]:
    root = Path(repo_root)
    values = []
    for option in ("--absolute-git-dir", "--git-common-dir", "HEAD"):
        result = _run([GIT, "-C", repo_root, "rev-parse", option])
        _require_source(result.returncode == 0, "proposal requires an existing committed worktree")
        values.append(result.stdout.decode("utf-8").strip())
    git_dir = (root / values[0]).resolve(strict=True)
    common_dir = (root / values[1]).resolve(strict=True)
    _require_source(git_dir != common_dir, "proposal requires a linked implementation worktree")
    listing = _run([GIT, "-C", repo_root, "worktree", "list", "--porcelain", "-z"])
    _require_source(
        listing.returncode == 0 and b"worktree " + os.fsencode(root) in listing.stdout.split(b"\0"),
        "proposal worktree is no longer registered",
    )
    return {
        "root": repo_root, "head": values[2], "git_dir": str(git_dir),
        "common_dir": str(common_dir), "root_identity": _proposal_file_identity(root),
        "git_identity": _proposal_file_identity(git_dir),
        "common_identity": _proposal_file_identity(common_dir),
    }


def _proposal_source_snapshot(spec: ManifestRequestSpec) -> dict[str, Any]:
    _require_source(1 <= len(spec.paths) <= MAX_MANIFEST_ENTRIES, "invalid proposal entry count")
    identities = [tracked_source_identity(path) for path in spec.paths]
    roots = {identity[1] for identity in identities}
    paths = [identity[0] for identity in identities]
    _require_source(len(roots) == 1, "proposal paths must share one worktree")
    _require_source(len(set(paths)) == len(paths), "proposal paths must be unique")
    repository = _proposal_repository_identity(roots.pop())
    entries = []
    total_bytes = 0
    for path, _root, relative in sorted(identities):
        before = _proposal_file_identity(Path(path))
        content, digest = secure_source_content(path)
        _require_source(before == _proposal_file_identity(Path(path)), "proposal source was replaced")
        total_bytes += len(content)
        _require_source(total_bytes <= MAX_SOURCE_BYTES, "proposal exceeds the total source size limit")
        entries.append({"path": path, "relative_path": relative, "content_sha256": digest,
                        "size": len(content), "identity": before})
    _require_source(
        repository == _proposal_repository_identity(repository["root"]),
        "proposal repository changed while collecting metadata",
    )
    return {"repository": repository, "entries": entries}


def _proposal_records(directory: Path) -> list[Path]:
    records = []
    with os.scandir(directory) as iterator:
        for entry in iterator:
            if entry.name.endswith(".json"):
                records.append(Path(entry.path))
                _require_source(len(records) <= MAX_PENDING_PROPOSALS, "proposal store is over capacity")
    return sorted(records)


def proposal_candidate_paths(paths: list[str]) -> tuple[str, ...]:
    """Include conventional existing regression tests, never directory grants."""
    result = list(paths)
    for raw in paths:
        path, _repo, _relative = tracked_source_identity(raw)
        source = Path(path)
        candidate = source.parent / "tests" / f"test-{source.name}"
        if not source.name.startswith("test-") and candidate.is_file():
            test_path = canonical_tracked_source(str(candidate))
            if test_path not in result:
                result.append(test_path)
    _require_source(len(result) <= MAX_MANIFEST_ENTRIES, "source and regression-test manifest exceeds the limit")
    return tuple(result)


def classify_source_snapshot(snapshot: dict[str, Any]) -> None:
    for entry in snapshot["entries"]:
        content, digest = secure_source_content(entry["path"])
        _require_source(digest == entry["content_sha256"], "source changed during classification")
        require_source_only_content(content)


def create_source_proposal(
    config: Config, spec: ManifestRequestSpec, *, issue_snapshot_sha256: str,
    context_socket: str | None = None,
) -> str:
    """Persist candidate identities, not approval, ownership or liveness evidence."""
    _require_source(type(spec.uid) is int and spec.uid > 0 and os.geteuid() == spec.uid,
                    "prepare proposals as their non-root owning user")
    _require_source(type(spec.now) is int and spec.now >= 0, "invalid proposal timestamp")
    _require_source(
        isinstance(issue_snapshot_sha256, str)
        and re.fullmatch(r"[a-f0-9]{64}", issue_snapshot_sha256) is not None,
        "proposal requires an exact issue snapshot digest",
    )
    body = {
        "session_id": _validate_session_id(spec.session_id), "uid": spec.uid,
        "reason": _validate_reason(spec.reason), "created_at": spec.now,
        "nonce": secrets.token_hex(16), "issue_snapshot_sha256": issue_snapshot_sha256,
        **_proposal_source_snapshot(spec),
    }
    classify_source_snapshot(body)
    if context_socket is not None:
        body["runtime_context"] = query_source_context(
            context_socket, spec.session_id, body["repository"]["root"], spec.uid,
        )
    proposal_id = hashlib.sha256(canonical_json(body)).hexdigest()
    record = {"schema": SCHEMA_PROPOSAL, "proposal_id": proposal_id, "state": "pending", "body": body}
    content = canonical_json(record) + b"\n"
    _require_source(len(content) <= MAX_REQUEST_BYTES, "proposal metadata exceeds the storage limit")
    with _proposal_store(config, spec.home, spec.uid) as directory:
        records = _proposal_records(directory)
        for candidate in records:
            try:
                existing = load_source_proposal(config, spec.home, candidate.stem, spec.uid)
            except SourceAccessError:
                continue
            comparable = {**body, "nonce": existing.get("nonce"), "created_at": existing["created_at"]}
            if existing["created_at"] <= spec.now and canonical_json(comparable) == canonical_json(existing):
                return candidate.stem
        _require_source(
            len(records) < MAX_PENDING_PROPOSALS,
            "proposal store is full; explicitly withdraw an unused proposal",
        )
        _require_source(not os.path.lexists(directory / f"{proposal_id}.json"), "proposal already exists")
        atomic_write(directory / f"{proposal_id}.json", content, 0o600)
    return proposal_id


def load_source_proposal(config: Config, home: Path, proposal_id: str, uid: int) -> dict[str, Any]:
    """Load a content-bound, powerless proposal; elapsed age is not authority."""
    _require_source(re.fullmatch(r"[a-f0-9]{64}", proposal_id) is not None, "invalid proposal identifier")
    directory = proposal_directory(config, home)
    _require_source(
        not _has_symlink_component(directory) and _trusted_private_directory(directory, uid),
        "proposal was withdrawn, removed or is unavailable",
    )
    record = _read_request_record(directory / f"{proposal_id}.json", uid)
    body = record.get("body")
    identity_error = "proposal identity is invalid or was changed"
    _require_source(
        record.get("schema") == SCHEMA_PROPOSAL and record.get("proposal_id") == proposal_id
        and record.get("state") == "pending" and isinstance(body, dict),
        identity_error,
    )
    _require_source(type(body.get("uid")) is int and body["uid"] == uid, identity_error)
    _require_source(
        hashlib.sha256(canonical_json(body)).hexdigest() == proposal_id,
        identity_error,
    )
    _require_source(
        type(body.get("created_at")) is int and body["created_at"] >= 0,
        "proposal timestamp is invalid",
    )
    return body


def revalidate_source_proposal_metadata(
    config: Config, spec: ManifestRequestSpec, proposal_id: str, *, issue_snapshot_sha256: str
) -> dict[str, Any]:
    """Check candidate metadata only. This MUST NOT be used as approval admission."""
    body = load_source_proposal(config, spec.home, proposal_id, spec.uid)
    _require_source(
        body.get("session_id") == _validate_session_id(spec.session_id)
        and body.get("reason") == _validate_reason(spec.reason)
        and body.get("issue_snapshot_sha256") == issue_snapshot_sha256,
        "proposal context changed; new explicit context consent is required",
    )
    created_at = body.get("created_at")
    _require_source(type(spec.now) is int and spec.now >= created_at, "proposal clock moved backwards")
    snapshot = _proposal_source_snapshot(spec)
    _require_source(
        all(body.get(key) == value for key, value in snapshot.items()),
        "proposal source or worktree changed; do not silently refresh it",
    )
    return body


def revalidate_source_proposal_context(body: dict[str, Any], uid: int) -> dict[str, Any]:
    """Re-challenge the recorded endpoint; never silently rebind its generation."""
    recorded = body.get("runtime_context")
    error = "proposal has no actionable runtime context; new explicit context consent is required"
    _require_source(
        isinstance(recorded, dict) and isinstance(recorded.get("socket_path"), str), error,
    )
    _require_source(
        isinstance(body.get("repository"), dict)
        and isinstance(body["repository"].get("root"), str)
        and type(body.get("uid")) is int and body["uid"] == uid, error,
    )
    current = query_source_context(
        recorded["socket_path"], body.get("session_id", ""), body["repository"]["root"], uid,
    )
    _require_source(current == recorded, "proposal runtime changed; new explicit context consent is required")
    return current


def withdraw_source_proposal(config: Config, home: Path, proposal_id: str, uid: int) -> None:
    """Remove pending metadata, freeing capacity; never revoke a signed capability."""
    with _proposal_store(config, home, uid) as directory:
        load_source_proposal(config, home, proposal_id, uid)
        (directory / f"{proposal_id}.json").unlink()


def parse_ttl(value: str) -> int:
    match = re.fullmatch(r"([1-9][0-9]*)([mh])", value)
    _require_source(match is not None, "TTL must use minutes or hours, for example 30m or 12h")
    amount = int(match.group(1))
    seconds = amount * (60 if match.group(2) == "m" else 3600)
    _require_source(60 <= seconds <= MAX_TTL_SECONDS, "TTL must be between 1 minute and 12 hours")
    return seconds


def _trusted_node(
    path: Path,
    owner_uid: int,
    expected_kind: Callable[[int], bool],
    forbidden_mode: int,
) -> bool:
    try:
        metadata = path.lstat()
    except OSError:
        return False
    return (
        expected_kind(metadata.st_mode)
        and not stat.S_ISLNK(metadata.st_mode)
        and metadata.st_uid == owner_uid
        and metadata.st_mode & forbidden_mode == 0
    )


def _trusted_file(path: Path, owner_uid: int) -> bool:
    return _trusted_node(path, owner_uid, stat.S_ISREG, 0o022)


def _trusted_private_key(path: Path, owner_uid: int) -> bool:
    return _trusted_node(path, owner_uid, stat.S_ISREG, 0o077)


def _trusted_directory(path: Path, owner_uid: int) -> bool:
    return _trusted_node(path, owner_uid, stat.S_ISDIR, 0o022)


def _trusted_private_directory(path: Path, owner_uid: int) -> bool:
    return _trusted_node(path, owner_uid, stat.S_ISDIR, 0o077)


def _derive_public_key(config: Config) -> bytes:
    _require_source(
        _trusted_private_directory(config.private_key.parent, config.trust_uid),
        "source-access signing key directory ownership or permissions are unsafe",
    )
    _require_source(
        _trusted_private_key(config.private_key, config.trust_uid),
        "source-access signing key ownership or permissions are unsafe",
    )
    result = _run(
        [
            SSH_KEYGEN,
            "-y",
            "-f",
            str(config.private_key),
        ]
    )
    _require_source(result.returncode == 0, "failed to derive the source-access verification key")
    public_key_output = result.stdout.strip()
    public_key_parts = public_key_output.split()
    key_error = "failed to derive a valid source-access verification key"
    _require_source(len(public_key_parts) >= 2, key_error)
    _require_source(public_key_parts[0] == b"ssh-ed25519", key_error)
    _require_source(bool(public_key_parts[1]), key_error)
    _require_source(b"\n" not in public_key_output, key_error)
    _require_source(b"\r" not in public_key_output, key_error)
    return b" ".join(public_key_parts[:2])


def _trust_marker_content(public_key: bytes) -> bytes:
    return (
        b"schema="
        + SCHEMA_TRUST.encode("ascii")
        + b"\nkey_source="
        + TRUST_KEY_SOURCE_DEDICATED.encode("ascii")
        + b"\npublic_key="
        + public_key
        + b"\n"
    )


def validate_key_material(config: Config) -> None:
    trust_error = "source-access signing trust ownership, permissions, or key binding are unsafe"
    _require_source(_trusted_directory(config.config_dir, config.trust_uid), trust_error)
    _require_source(_trusted_file(config.public_key, config.trust_uid), trust_error)
    _require_source(_trusted_file(config.trust_marker, config.trust_uid), trust_error)
    derived_public_key = _derive_public_key(config)
    try:
        public_key = config.public_key.read_bytes()
        trust_marker = config.trust_marker.read_bytes()
    except OSError as exc:
        raise SourceAccessError(trust_error) from exc
    _require_source(public_key == derived_public_key + b"\n", trust_error)
    _require_source(trust_marker == _trust_marker_content(derived_public_key), trust_error)


def _read_request_record(request_path: Path, expected_uid: int) -> dict[str, Any]:
    """Read bounded untrusted metadata through the descriptor we validate."""
    trust_error = "source-access request ownership or permissions are unsafe"
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0)
    try:
        descriptor = os.open(request_path, flags)
    except OSError as exc:
        raise SourceAccessError(trust_error) from exc
    try:
        metadata = os.fstat(descriptor)
        _require_source(
            stat.S_ISREG(metadata.st_mode)
            and metadata.st_nlink == 1
            and metadata.st_uid == expected_uid
            and metadata.st_mode & 0o022 == 0,
            trust_error,
        )
        _require_source(metadata.st_size <= MAX_REQUEST_BYTES, "source-access request is too large")
        with os.fdopen(descriptor, "rb", closefd=False) as handle:
            content = handle.read(MAX_REQUEST_BYTES + 1)
        _require_source(len(content) <= MAX_REQUEST_BYTES, "source-access request is too large")
        current = request_path.lstat()
        final = os.fstat(descriptor)
        identity_fields = (
            "st_dev", "st_ino", "st_mode", "st_nlink", "st_uid",
            "st_size", "st_mtime_ns", "st_ctime_ns",
        )
        _require_source(
            (current.st_dev, current.st_ino) == (metadata.st_dev, metadata.st_ino)
            and all(getattr(final, field) == getattr(metadata, field) for field in identity_fields),
            "source-access request changed while reading",
        )
        request = json.loads(content.decode("utf-8"))
    except (OSError, ValueError, RecursionError) as exc:
        raise SourceAccessError("source-access request was not found or is malformed") from exc
    finally:
        os.close(descriptor)
    _require_source(isinstance(request, dict), "source-access request must be an object")
    return request


def _load_request(
    config: Config, home: Path, request_id: str, expected_uid: int
) -> dict[str, Any]:
    _require_source(ID_PATTERN.fullmatch(request_id) is not None, "invalid request identifier")
    request_path = request_directory(config, home) / f"{request_id}.json"
    trust_error = "source-access request ownership or permissions are unsafe"
    _require_source(_trusted_directory(request_path.parent, expected_uid), trust_error)
    _require_source(_trusted_file(request_path, expected_uid), trust_error)
    request = _read_request_record(request_path, expected_uid)
    schema_error = "source-access request schema or identifier is invalid"
    _require_source(
        request.get("schema") in (SCHEMA_REQUEST, SCHEMA_MANIFEST_REQUEST), schema_error
    )
    _require_source(request.get("request_id") == request_id, schema_error)
    return request


def _create_trusted_directory(path: Path, mode: int, owner_uid: int) -> None:
    try:
        path.mkdir(mode=mode)
    except OSError as exc:
        raise SourceAccessError("failed to create the source-access signing key directory") from exc
    if os.geteuid() == 0:
        os.chown(path, owner_uid, 0)


def _prepare_trusted_directory(path: Path, mode: int, owner_uid: int) -> None:
    trust_error = "source-access signing key directory ownership or permissions are unsafe"
    if not os.path.lexists(path):
        _create_trusted_directory(path, mode, owner_uid)
    _require_source(_trusted_directory(path, owner_uid), trust_error)
    os.chmod(path, mode)
    _require_source(_trusted_directory(path, owner_uid), trust_error)


def _generate_dedicated_signing_key(config: Config) -> None:
    public_companion = Path(f"{config.private_key}.pub")
    _prepare_trusted_directory(config.config_dir, 0o755, config.trust_uid)
    _prepare_trusted_directory(config.private_key.parent, 0o700, config.trust_uid)
    _require_source(
        not os.path.lexists(config.private_key) and not os.path.lexists(public_companion),
        "source-access signing key path already exists or is unsafe",
    )
    result = _run(
        [
            SSH_KEYGEN,
            "-q",
            "-t",
            "ed25519",
            "-N",
            "",
            "-C",
            "aidevops-source-access-signing",
            "-f",
            str(config.private_key),
        ]
    )
    _require_source(result.returncode == 0, "failed to create the source-access signing key")
    for key_path in (config.private_key, public_companion):
        if os.geteuid() == 0:
            os.chown(key_path, config.trust_uid, 0)
        os.chmod(key_path, 0o600)
        _require_source(
            _trusted_private_key(key_path, config.trust_uid),
            "failed to create the source-access signing key",
        )


def setup_key_material(config: Config) -> None:
    if not os.path.lexists(config.private_key):
        _generate_dedicated_signing_key(config)
    _prepare_trusted_directory(config.config_dir, 0o755, config.trust_uid)
    public_key = _derive_public_key(config)
    atomic_write(config.public_key, public_key + b"\n", 0o644, config.trust_uid)
    atomic_write(
        config.trust_marker,
        _trust_marker_content(public_key),
        0o644,
        config.trust_uid,
    )
    validate_key_material(config)


def _single_approval_path(payload: dict[str, Any]) -> str:
    return str(payload["path"])


def _manifest_approval_path(payload: dict[str, Any]) -> str:
    entries = payload["entries"]
    _require_source(isinstance(entries, list), "source-access manifest is malformed")
    return f"{payload['repo_root']} ({len(entries)} exact paths)"


_APPROVAL_PATH_READERS = {
    SCHEMA_PAYLOAD: _single_approval_path,
    SCHEMA_MANIFEST_PAYLOAD: _manifest_approval_path,
    SCHEMA_BOUND_PAYLOAD: _manifest_approval_path,
}


def list_approvals(config: Config, *, uid: int, now: int | None = None) -> list[dict[str, Any]]:
    checked_at = int(time.time() if now is None else now)
    results: list[dict[str, Any]] = []
    for receipt_path in manifest_receipt_paths(config, uid):
        try:
            if not _trusted_file(receipt_path, config.trust_uid) or receipt_path.stat().st_size > 1024 * 1024:
                continue
            receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
            payload = receipt["payload"]
            path = _APPROVAL_PATH_READERS[payload["schema"]](payload)
            results.append(
                {
                    "approval_id": payload["approval_id"],
                    "session_id": payload["session_id"],
                    "path": path,
                    "expires_at": payload["expires_at"],
                    "status": "active" if checked_at < int(payload["expires_at"]) else "expired",
                }
            )
        except (OSError, KeyError, TypeError, ValueError, json.JSONDecodeError):
            continue
    return results


def real_user() -> tuple[int, Path]:
    sudo_user = os.environ.get("SUDO_USER", "")
    if os.geteuid() == 0 and sudo_user:
        account = pwd.getpwnam(sudo_user)
        return account.pw_uid, Path(account.pw_dir)
    return os.getuid(), Path.home()

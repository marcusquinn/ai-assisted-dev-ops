#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""JMAP EventSource push notification helpers."""

import json
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from urllib.parse import urlsplit

from email_jmap_transport import _get_auth, _make_auth_header, _session_context


def _build_event_source_url(event_source_url, types):
    """Expand the EventSource URL template with requested types and a ping."""
    type_list = types.split(",")
    url = event_source_url
    if "{types}" in url:
        url = url.replace("{types}", ",".join(type_list))
    else:
        separator = "&" if "?" in url else "?"
        url = url + separator + "types=" + ",".join(type_list)
    if "ping=" not in url:
        separator = "&" if "?" in url else "?"
        url = url + separator + "ping=30"
    return url, type_list


def _validate_event_source_url(url):
    """Reject EventSource URLs that are not absolute HTTP(S) endpoints."""
    parsed = urlsplit(url)
    if parsed.scheme not in {"http", "https"} or not parsed.netloc:
        raise ValueError("JMAP EventSource URL must use HTTP(S)")
    return url


def _emit_sse_event(event_type, event_data):
    """Parse and emit one complete SSE event."""
    try:
        data_obj = json.loads(event_data)
    except json.JSONDecodeError:
        data_obj = {"raw": event_data}
    event = {
        "event_type": event_type or "state",
        "data": data_obj,
        "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    }
    print(json.dumps(event), flush=True)


def _process_sse_stream(resp, timeout, start_time):
    """Read SSE lines from resp and emit JSON events until timeout."""
    event_type = ""
    event_data = ""
    for raw_line in resp:
        if time.time() - start_time > timeout:
            print(json.dumps({"status": "timeout", "elapsed_seconds": int(time.time() - start_time)}), flush=True)
            break
        line = raw_line.decode("utf-8", errors="replace").rstrip("\r\n")
        if line.startswith("event:"):
            event_type = line[6:].strip()
        elif line.startswith("data:"):
            event_data = line[5:].strip()
        elif line == "" and event_data:
            _emit_sse_event(event_type, event_data)
            event_type = ""
            event_data = ""


def cmd_push(args):
    """Subscribe to JMAP push notifications via EventSource (SSE)."""
    session, account_id, _ = _session_context(args)
    event_source_url = session.get("eventSourceUrl", "")
    if not event_source_url:
        print("ERROR: Server does not provide eventSourceUrl (push not supported)", file=sys.stderr)
        return 1
    url, type_list = _build_event_source_url(event_source_url, args.types or "mail")
    try:
        _validate_event_source_url(url)
    except ValueError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    timeout = args.timeout or 300
    auth_type, credential = _get_auth()
    auth_header = _make_auth_header(args.user, auth_type, credential)
    print(json.dumps({
        "status": "listening",
        "url": url,
        "types": type_list,
        "timeout_seconds": timeout,
        "account_id": account_id,
    }), flush=True)
    request = urllib.request.Request(url, headers={
        "Authorization": auth_header,
        "Accept": "text/event-stream",
        "Cache-Control": "no-cache",
    })
    start_time = time.time()
    try:
        # The scheme and authority are validated by _validate_event_source_url above.
        with urllib.request.urlopen(request, timeout=timeout) as response:  # nosec B310
            _process_sse_stream(response, timeout, start_time)
    except urllib.error.URLError as error:
        print(f"ERROR: EventSource connection failed: {error.reason}", file=sys.stderr)
        return 1
    except Exception as error:  # pylint: disable=broad-exception-caught
        print(json.dumps({
            "status": "disconnected",
            "reason": str(error),
            "elapsed_seconds": int(time.time() - start_time),
        }), flush=True)
    return 0

#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Generate sanitized Medium HTML-export ZIP fixtures for focused tests."""

from __future__ import annotations

import stat
import sys
import zipfile
from pathlib import Path

STORY = """<!doctype html><html><head><title>Fixture Story</title></head><body>
<article class="h-entry" data-post-id="post-fixture-1">
  <h1 class="p-name">Fixture Story</h1>
  <section class="e-content" data-field="body"><p class="graf">Authored evidence.</p></section>
  <footer><a class="p-author h-card" href="https://medium.com/@fixture">@fixture</a>
    <time class="dt-published" datetime="2026-07-27T10:00:00Z">published</time>
    <a class="p-canonical" href="https://medium.com/@fixture/fixture-story-11111111">canonical</a>
  </footer>
</article></body></html>"""
RESPONSE = """<!doctype html><html><body>
<article class="h-entry" data-response-id="response-fixture-2">
  <h1 class="p-name">Fixture Response</h1>
  <a class="u-in-reply-to" href="https://medium.com/@source/original-22222222">original</a>
  <section class="e-content" data-field="body"><p class="graf">Authored response.</p></section>
  <footer><a class="p-author h-card" href="https://medium.com/@fixture">@fixture</a>
    <time class="dt-published" datetime="2026-07-27T11:00:00+00:00">published</time>
    <a class="p-canonical" href="https://medium.com/@fixture/fixture-response-33333333">canonical</a>
  </footer>
</article></body></html>"""
BOOKMARKS = """<html><body><ul><li><a class="h-cite" href="https://medium.com/@source/saved-44444444">Saved story</a>
<time class="dt-published">2026-07-27 4:50 pm</time></li></ul></body></html>"""
CLAPS = """<html><body><ul><li class="h-entry">+25 — <a class="h-cite u-like-of" href="https://medium.com/@source/saved-44444444">Clapped story</a>
<time class="dt-published">2026-07-27 4:55 pm</time></li></ul></body></html>"""
HIGHLIGHTS = """<html><body><ul><li class="h-entry"><a class="h-cite u-highlight-of" href="https://medium.com/@source/highlighted-55555555">Source</a>
<p class="graf">Context <span class="markup--highlight" name="selection">Selected words</span></p>
<time class="dt-published">2026-07-27 5:00 pm</time></li></ul></body></html>"""
LISTS = """<html><body><h1 class="p-name">Fixture List</h1><h2 class="p-summary">Curated references</h2>
<ul><li data-field="post"><a href="https://medium.com/@source/listed-66666666">Listed story</a></li></ul>
<footer><a class="p-canonical" href="https://medium.com/@fixture/list/fixture-list-77777777">list</a></footer></body></html>"""


def profile_html(mode: str) -> str:
    account_id = "medium_other_99" if mode == "other-account" else "medium_user_42"
    credential = ' data-access-token="must-not-persist"' if mode == "credential" else ""
    profile = f"""<!doctype html><html><body>
<section class="h-card"{credential}>
  <h3 class="p-name">Fixture Author</h3>
  <h4>Account info</h4><ul>
    <li>Profile: <a class="u-url" href="https://medium.com/@fixture">@fixture</a></li>
    <li>Email address: fixture@example.invalid</li>
    <li>Medium user ID: {account_id}</li>
  </ul>
</section></body></html>"""
    if mode == "deep":
        return "<div>" * 300 + profile + "</div>" * 300
    return profile


def write_special_members(archive: zipfile.ZipFile, mode: str) -> None:
    if mode == "traversal":
        archive.writestr("../escape.html", "unsafe")
    elif mode == "duplicate":
        archive.writestr("posts/case.html", STORY)
        archive.writestr("POSTS/CASE.HTML", STORY)
    elif mode == "member-symlink":
        link = zipfile.ZipInfo("posts/link.html")
        link.create_system = 3
        link.external_attr = (stat.S_IFLNK | 0o777) << 16
        archive.writestr(link, "story.html")
    elif mode == "oversized-member":
        archive.writestr("sessions/large.bin", b"A" * (32 * 1024 * 1024 + 1))


def write_social_members(archive: zipfile.ZipFile, mode: str) -> None:
    story = (
        "<html><body><h1>Malformed post</h1></body></html>"
        if mode == "malformed"
        else STORY
    )
    bookmarks = (
        "<html><body><ul><li>schema changed</li></ul></body></html>"
        if mode == "malformed-bookmarks"
        else BOOKMARKS
    )
    highlights = (
        '<html><body><ul><li><span class="markup--highlight"></span></li></ul></body></html>'
        if mode == "malformed-highlights"
        else HIGHLIGHTS
    )
    archive.writestr("posts/story.html", story)
    archive.writestr("posts/response.html", RESPONSE)
    archive.writestr("bookmarks/bookmarks.html", bookmarks)
    archive.writestr("claps/claps.html", CLAPS)
    archive.writestr("highlights/highlights.html", highlights)
    archive.writestr("lists/list.html", LISTS)
    archive.writestr(
        "profile/publications.html",
        '<html><body><ul><li>Writer <a href="https://medium.com/fixture-publication">Fixture Publication</a></li></ul></body></html>',
    )
    archive.writestr(
        "users-following/users.html",
        '<html><body><a href="https://medium.com/@followed">@followed</a></body></html>',
    )
    archive.writestr(
        "pubs-following/publications.html",
        '<html><body><a href="https://medium.com/fixture-publication">Fixture Publication</a></body></html>',
    )
    archive.writestr(
        "topics-following/topics.html",
        '<html><body><a href="https://medium.com/tag/testing">Testing</a></body></html>',
    )
    archive.writestr(
        "sessions/devices.html", "<html><body>excluded device history</body></html>"
    )
    if mode == "expansion":
        archive.writestr(
            "sessions/large.html", "<html>" + "A" * 100000 + "</html>"
        )


def mark_encrypted(target: Path) -> None:
    payload = bytearray(target.read_bytes())
    for marker, offset in ((b"PK\x03\x04", 6), (b"PK\x01\x02", 8)):
        cursor = 0
        while True:
            index = payload.find(marker, cursor)
            if index < 0:
                break
            flags = int.from_bytes(
                payload[index + offset : index + offset + 2], "little"
            ) | 1
            payload[index + offset : index + offset + 2] = flags.to_bytes(2, "little")
            cursor = index + len(marker)
    target.write_bytes(payload)


def main() -> int:
    target = Path(sys.argv[1])
    mode = sys.argv[2]
    excluded = {
        "credential",
        "deep",
        "duplicate",
        "encrypted",
        "member-symlink",
        "minimal",
        "other-account",
        "oversized-member",
        "traversal",
    }
    with zipfile.ZipFile(target, "w", zipfile.ZIP_DEFLATED) as archive:
        archive.writestr("profile/profile.html", profile_html(mode))
        write_special_members(archive, mode)
        if mode not in excluded:
            write_social_members(archive, mode)
    if mode == "encrypted":
        mark_encrypted(target)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

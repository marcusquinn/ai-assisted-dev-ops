#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Pure canonical scope preparation from explicit author-owned declarations."""

import re
import sys

HEADING = re.compile(r"^#{2,3} Files Scope\s*$")
SCOPE_LIKE = re.compile(r"^#{1,6}\s+files\s+scope\b", re.I)
DECLARATION = re.compile(
    r"(?:`(?:EDIT|NEW): ([^`]+)`|(?:EDIT|NEW): `([^`]+)`|(?:EDIT|NEW): ([^\s`,;]+))"
)


def fail():
    """Refuse ambiguous or contradictory author input without emitting a body."""
    raise ValueError("Files Scope requires owned author-side repair")


def exact(path):
    return bool(re.fullmatch(r"[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)*", path)) and all(
        part not in (".", "..", ".git") for part in path.split("/")
    )


def section(lines, start):
    result = []
    for line in lines[start + 1:]:
        if re.match(r"^#{1,6}\s", line) or line == "</details>":
            break
        result.append(line)
    return result


def existing_scope(lines, unfenced):
    scopes = [i for i, line in enumerate(lines) if HEADING.fullmatch(line)]
    if [i for i, line in enumerate(lines) if SCOPE_LIKE.match(line)] != scopes:
        fail()
    for line in unfenced.splitlines():
        if SCOPE_LIKE.match(line) and not HEADING.fullmatch(line):
            fail()
    if not scopes:
        return False
    if len(scopes) != 1:
        fail()
    paths = []
    for line in section(lines, scopes[0]):
        if not line.strip():
            continue
        match = re.fullmatch(r"- (?:`([^`]+)`|([^\s`]+))\s*", line)
        if not match or not exact(match[1] or match[2]):
            fail()
        paths.append(match[1] or match[2])
    if not paths:
        fail()
    return True


def check_explanation(rest):
    # Retain explanations; never mine them for extra write paths.
    if re.match(r"^[\s,;]+`?[\w.-]+(?:/|\.[A-Za-z])", rest):
        fail()
    if rest and not re.match(r"^(?:\s|[—–,:;])", rest):
        fail()
    if re.search(
        r"EDIT:|NEW:|read.only|exclude|do not (?:edit|modify|touch|alter|change)|"
        r"must not (?:edit|modify)|(?:leave|keep|preserve) .*unchanged|"
        r"remain .*untouched|reference .*only|inspect .*only|"
        r"no (?:edits|changes|modifications)|never (?:edit|modify)", rest, re.I
    ):
        fail()


def declared_paths(rest):
    paths = []
    while True:
        match = DECLARATION.match(rest)
        if not match:
            fail()
        path = next(value for value in match.groups() if value is not None)
        if not exact(path):
            fail()
        paths.append(path)
        rest = rest[match.end():]
        separator = re.match(r"(?:, |; | and )(?=`?(?:EDIT|NEW):)", rest)
        if separator:
            rest = rest[separator.end():]
            continue
        check_explanation(rest)
        return paths


def prepare(action, original, unfenced, lines):
    if existing_scope(lines, unfenced):
        return original if action != "check" else ""
    if action == "check" or re.search(
        r"aidevops-signed-approval|aidevops:.*approval", original
    ):
        fail()
    starts = [i for i, line in enumerate(lines)
              if re.fullmatch(r"#{2,3} Files to Modify\s*", line, re.I)]
    if len(starts) != 1:
        fail()
    paths = []
    for line in section(lines, starts[0]):
        bullet = re.match(r"^- (`?(?:EDIT|NEW):.*)$", line)
        if bullet:
            paths.extend(declared_paths(bullet[1]))
    if not paths:
        fail()
    return original.rstrip("\n") + "\n\n## Files Scope\n\n" + "".join(
        "- `" + path + "`\n" for path in dict.fromkeys(paths)
    )


def main():
    try:
        result = prepare(*sys.argv[1:], sys.stdin.read().splitlines())
    except ValueError as error:
        print(error, file=sys.stderr)
        return 1
    sys.stdout.write(result)
    return 0


if __name__ == "__main__":
    sys.exit(main())

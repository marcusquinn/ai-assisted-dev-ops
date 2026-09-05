# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Bounded SVG inventory parsing with DTDs and entity declarations disabled."""

from xml.parsers import expat

SVG_NAMESPACE = "http://www.w3.org/2000/svg}"


def reject_declarations(*_args):
    raise ValueError("SVG document types and entity declarations are forbidden")


class SvgInventory:
    def __init__(self):
        self.stack = []
        self.targets = []
        self.elements = []

    def start(self, name, attributes):
        if not self.stack and name != SVG_NAMESPACE + "svg":
            raise ValueError("Expected an SVG root element")
        key = None
        if len(self.stack) == 1 and name in (
            SVG_NAMESPACE + "title",
            SVG_NAMESPACE + "desc",
        ):
            key = name.removeprefix(SVG_NAMESPACE)
        if name == SVG_NAMESPACE + "text":
            key = attributes.get("data-count")
        target = self.targets[-1] if self.targets else None
        if key is not None:
            target = {"key": key, "text": ""}
            self.elements.append(target)
        self.stack.append(name)
        self.targets.append(target)

    def end(self, _name):
        self.stack.pop()
        self.targets.pop()

    def content(self, value):
        if self.targets and self.targets[-1] is not None:
            self.targets[-1]["text"] += value

    def values(self):
        result = {}
        for element in self.elements:
            result.setdefault(element["key"], []).append(element["text"])
        return result


def parse_svg(text):
    if len(text.encode("utf-8")) > 65536:
        raise ValueError("Hero SVG exceeds the 64 KiB source limit")
    reader = SvgInventory()
    parser = expat.ParserCreate(namespace_separator="}")
    parser.StartElementHandler = reader.start
    parser.EndElementHandler = reader.end
    parser.CharacterDataHandler = reader.content
    parser.StartDoctypeDeclHandler = reject_declarations
    parser.EntityDeclHandler = reject_declarations
    parser.ExternalEntityRefHandler = reject_declarations
    parser.SetParamEntityParsing(expat.XML_PARAM_ENTITY_PARSING_NEVER)
    try:
        parser.Parse(text, True)
    except expat.ExpatError as error:
        raise ValueError(f"Invalid SVG: {error}") from error
    return reader.values()

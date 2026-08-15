#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""DESIGN.md token parsing and accessibility adjustments for reports."""

from __future__ import annotations

from pathlib import Path

TOKEN_SECTION_PREFIXES = {"colors": "", "rounded": "rounded.", "typography": ""}

DEFAULT_TOKENS = {
    "background": "#f8f6f1",
    "surface": "#ffffff",
    "on-surface": "#111827",
    "muted": "#4b5563",
    "outline": "#d1d5db",
    "primary": "#2563eb",
    "primary-container": "#dbeafe",
    "headline-display.fontFamily": 'Inter, system-ui, -apple-system, "Segoe UI", sans-serif',
    "headline-display.fontSize": "64px",
    "headline-display.fontWeight": "650",
    "headline-display.lineHeight": "1.05",
    "headline-display.letterSpacing": "-0.03em",
    "body-md.fontFamily": 'Inter, system-ui, -apple-system, "Segoe UI", sans-serif',
    "body-md.fontSize": "16px",
    "body-md.lineHeight": "1.62",
    "code-md.fontFamily": '"IBM Plex Mono", "SFMono-Regular", Consolas, monospace',
    "rounded.lg": "12px",
}


def _brand_root() -> Path:
    return Path(__file__).resolve().parents[1] / "tools" / "design" / "library" / "brands"


def _front_matter(path: Path) -> list[str]:
    lines = path.read_text(encoding="utf-8").splitlines()
    start = next(
        (index for index, line in enumerate(lines[:100]) if line.strip() == "---"),
        None,
    )
    if start is None:
        return []
    end = next(
        (
            index
            for index, line in enumerate(lines[start + 1 :], start=start + 1)
            if line.strip() == "---"
        ),
        None,
    )
    return [] if end is None else lines[start + 1 : end]


def _clean(value: str) -> str:
    return value.strip().strip('"').strip("'")


def hex_to_rgb(value: str) -> tuple[float, float, float] | None:
    raw = value.strip()
    if not raw.startswith("#"):
        return None
    raw = raw[1:]
    if len(raw) == 3:
        raw = "".join(character * 2 for character in raw)
    if len(raw) != 6:
        return None
    try:
        return tuple(int(raw[index : index + 2], 16) / 255 for index in (0, 2, 4))  # type: ignore[return-value]
    except ValueError:
        return None


def _rgb_to_hex(rgb: tuple[float, float, float]) -> str:
    return "#" + "".join(
        f"{round(max(0, min(1, channel)) * 255):02X}" for channel in rgb
    )


def relative_luminance(rgb: tuple[float, float, float]) -> float:
    def channel(value: float) -> float:
        return value / 12.92 if value <= 0.03928 else ((value + 0.055) / 1.055) ** 2.4

    red, green, blue = (channel(value) for value in rgb)
    return 0.2126 * red + 0.7152 * green + 0.0722 * blue


def _contrast_ratio(
    foreground: tuple[float, float, float], background: tuple[float, float, float]
) -> float:
    light = max(relative_luminance(foreground), relative_luminance(background))
    dark = min(relative_luminance(foreground), relative_luminance(background))
    return (light + 0.05) / (dark + 0.05)


def _mix(
    rgb: tuple[float, float, float],
    target: tuple[float, float, float],
    amount: float,
) -> tuple[float, float, float]:
    return tuple(
        channel + (target[index] - channel) * amount
        for index, channel in enumerate(rgb)
    )  # type: ignore[return-value]


def ensure_contrast(foreground_value: str, background_value: str, minimum: float) -> str:
    foreground = hex_to_rgb(foreground_value)
    background = hex_to_rgb(background_value)
    if foreground is None or background is None:
        return foreground_value
    if _contrast_ratio(foreground, background) >= minimum:
        return foreground_value
    target = (1.0, 1.0, 1.0) if relative_luminance(background) < 0.45 else (0.0, 0.0, 0.0)
    adjusted = foreground
    for step in range(1, 21):
        adjusted = _mix(foreground, target, step / 20)
        if _contrast_ratio(adjusted, background) >= minimum:
            break
    return _rgb_to_hex(adjusted)


def _accessible_tokens(tokens: dict[str, str]) -> dict[str, str]:
    adjusted = dict(tokens)
    surface = adjusted.get("surface", adjusted["background"])
    for key, minimum in (("on-surface", 4.5), ("muted", 4.5), ("primary", 4.5), ("outline", 2.0)):
        adjusted[key] = ensure_contrast(adjusted[key], surface, minimum)
    if "surface-dark" in adjusted:
        dark_surface = adjusted.get("surface-dark", adjusted.get("background-dark", surface))
        dark_defaults = {
            "on-surface-dark": ("#ffffff", 4.5),
            "muted-dark": ("#cbd5e1", 4.5),
            "primary-dark": (adjusted["primary"], 4.5),
            "outline-dark": ("#334155", 2.0),
        }
        for key, (default, minimum) in dark_defaults.items():
            adjusted[key] = ensure_contrast(adjusted.get(key, default), dark_surface, minimum)
    return adjusted


def _parse_mapping(line: str) -> tuple[str, str] | None:
    if ":" not in line:
        return None
    key, value = line.split(":", 1)
    return key.strip(), _clean(value)


def _indent_width(line: str) -> int:
    prefix = line[: len(line) - len(line.lstrip(" \t"))]
    return len(prefix.replace("\t", "    "))


def _mapping_parent(
    root: dict[str, object],
    stack: list[tuple[int, dict[str, object]]],
    indent: int,
) -> dict[str, object]:
    while stack and indent <= stack[-1][0]:
        stack.pop()
    return stack[-1][1] if stack else root


def _store_mapping(
    parent: dict[str, object],
    stack: list[tuple[int, dict[str, object]]],
    indent: int,
    key: str,
    value: str,
) -> None:
    if value:
        parent[key] = value
        return
    child: dict[str, object] = {}
    parent[key] = child
    stack.append((indent, child))


def _parse_nested_mapping(lines: list[str]) -> dict[str, object]:
    root: dict[str, object] = {}
    stack: list[tuple[int, dict[str, object]]] = []
    for line in lines:
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        parsed = _parse_mapping(line.strip())
        if parsed is None:
            continue
        key, value = parsed
        indent = _indent_width(line)
        parent = _mapping_parent(root, stack, indent)
        _store_mapping(parent, stack, indent, key, value)
    return root


def _flatten_token_mapping(value: object, prefix: str = "") -> dict[str, str]:
    if not isinstance(value, dict):
        return {}
    flattened: dict[str, str] = {}
    for key, item in value.items():
        token_key = f"{prefix}{key}"
        if isinstance(item, dict):
            flattened.update(_flatten_token_mapping(item, f"{token_key}."))
        else:
            flattened[token_key] = str(item)
    return flattened


def _parse_tokens(lines: list[str]) -> dict[str, str]:
    document = _parse_nested_mapping(lines)
    tokens: dict[str, str] = {}
    for section, prefix in TOKEN_SECTION_PREFIXES.items():
        tokens.update(_flatten_token_mapping(document.get(section), prefix))
    return tokens


def tokens_for(name: str, supported_names: frozenset[str]) -> dict[str, str]:
    """Load and normalize one supported report style token set."""
    if name not in supported_names:
        raise ValueError(f"Invalid style name: {name}")
    path = _brand_root() / name / "DESIGN.md"
    tokens = dict(DEFAULT_TOKENS)
    if path.exists():
        tokens.update(_parse_tokens(_front_matter(path)))
    return _accessible_tokens(tokens)

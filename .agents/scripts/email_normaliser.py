# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""
email_normaliser.py - Email section normalisation, thread reconstruction, and frontmatter building.

Part of the email-to-markdown pipeline. Imported by email_to_markdown.py.
"""

__all__ = (
    "parse_eml",
    "parse_msg",
    "extract_header_safe",
    "parse_date_safe",
    "normalise_email_sections",
    "build_thread_map",
    "reconstruct_thread",
    "generate_thread_index",
)

from email_parser import (
    parse_eml,
    parse_msg,
    extract_header_safe,
    parse_date_safe,
)

# Re-export public surface from decomposed module for backwards compatibility.
# Other scripts importing from email_normaliser continue to work unchanged.
from email_normaliser_sections import (
    normalise_email_sections,
    build_thread_map,
    reconstruct_thread,
    generate_thread_index,
)


# ---------------------------------------------------------------------------
# YAML utilities
# ---------------------------------------------------------------------------

def format_size(size_bytes):
    """Format file size in human-readable format."""
    for unit in ['B', 'KB', 'MB', 'GB']:
        if size_bytes < 1024:
            if unit == 'B':
                return f"{size_bytes} {unit}"
            return f"{size_bytes:.1f} {unit}"
        size_bytes /= 1024
    return f"{size_bytes:.1f} TB"


def estimate_tokens(text):
    """Estimate token count for text (rough heuristic: ~4 chars per token).

    Uses a word-count based approach for better accuracy:
    - Short words (~4 chars): ~1 token each
    - Long words: roughly 1 token per 4 chars
    """
    if not text:
        return 0
    words = text.split()
    token_estimate = 0
    for word in words:
        if len(word) <= 4:
            token_estimate += 1
        else:
            token_estimate += max(1, len(word) // 4)
    return token_estimate


def _needs_yaml_quoting(value: str) -> bool:
    """Check if a YAML value needs quoting (contains special chars)."""
    special_chars = ':{}[]&*#?|->!%@`,'
    return any(c in value for c in special_chars)


def _yaml_quote(value: str) -> str:
    """Apply YAML double-quoting with escape sequences."""
    return '"' + value.replace('\\', '\\\\').replace('"', '\\"') + '"'


def yaml_escape(value):
    """Escape a value for safe use in YAML frontmatter.

    Handles special characters, multiline strings, and edge cases.
    Returns the value ready for inclusion after 'key: '.
    """
    if not isinstance(value, str):
        return str(value)
    if not value:
        return '""'
    # Multiline: use folded block scalar
    if '\n' in value:
        indented = '\n'.join('  ' + line for line in value.splitlines())
        return f'|\n{indented}'
    if _needs_yaml_quoting(value):
        return _yaml_quote(value)
    return value


# ---------------------------------------------------------------------------
# Frontmatter building
# ---------------------------------------------------------------------------

def _format_attachment_yaml(att):
    """Format a single attachment dict as indented YAML list-item lines."""
    lines = [f'  - filename: {yaml_escape(att["filename"])}']
    lines.append(f'    size: {yaml_escape(att["size"])}')
    if 'content_hash' in att:
        lines.append(f'    content_hash: {att["content_hash"]}')
    if 'deduplicated_from' in att:
        lines.append(f'    deduplicated_from: {yaml_escape(att["deduplicated_from"])}')
    return lines


def _format_attachments_yaml(key, attachments):
    """Format the attachments list as YAML lines."""
    if not attachments:
        return [f'{key}: []']
    lines = [f'{key}:']
    for att in attachments:
        lines.extend(_format_attachment_yaml(att))
    return lines


def _format_entities_yaml(key, entities):
    """Format the entities dict-of-lists as YAML lines."""
    if not entities:
        return [f'{key}: {{}}']
    lines = [f'{key}:']
    for entity_type, entity_list in entities.items():
        if not entity_list:
            continue
        lines.append(f'  {entity_type}:')
        for entity in entity_list:
            lines.append(f'    - {yaml_escape(entity)}')
    return lines


def _format_frontmatter_field(key, value) -> list:
    """Format a single metadata field as YAML line(s)."""
    if key == 'attachments' and isinstance(value, list):
        return _format_attachments_yaml(key, value)
    if key == 'entities' and isinstance(value, dict):
        return _format_entities_yaml(key, value)
    if isinstance(value, (int, float)):
        return [f'{key}: {value}']
    return [f'{key}: {yaml_escape(value)}']


def build_frontmatter(metadata):
    """Build YAML frontmatter string from metadata dict.

    Handles scalar values, lists of dicts (attachments with content_hash
    and optional deduplicated_from), nested dicts of lists (entities),
    and proper YAML escaping for all string values.
    """
    lines = ['---']
    for key, value in metadata.items():
        lines.extend(_format_frontmatter_field(key, value))
    lines.append('---')
    return '\n'.join(lines)

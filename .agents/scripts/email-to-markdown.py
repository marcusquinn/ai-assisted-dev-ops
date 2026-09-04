#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""
email-to-markdown.py - Convert .eml/.msg files to markdown with attachment extraction
Part of aidevops framework: https://aidevops.sh

Usage:
  Single file:  email-to-markdown.py <input-file> [--output <file>] [--attachments-dir <dir>]
                [--summary-mode auto|heuristic|llm|off]
  Batch mode:   email-to-markdown.py <directory> --batch [--threads-index]

Output format: YAML frontmatter with visible headers (from, to, cc, bcc, date_sent,
date_received, subject, size, message_id, in_reply_to, attachment_count, attachments),
thread reconstruction fields (thread_id, thread_position, thread_length),
markdown.new convention fields (title, description), and tokens_estimate for LLM context.

Summary generation (t1044.7): The description field contains a 1-2 sentence summary.
Short emails (<=100 words) use sentence extraction heuristic. Long emails use LLM
summarisation via Ollama (local) or Anthropic API (cloud fallback).

Thread reconstruction:
- Parses message_id and in_reply_to headers to build conversation threads
- thread_id: message-id of the root message (first in thread)
- thread_position: 1-based position in thread (1 = root)
- thread_length: total number of messages in thread
- --threads-index: generates JSON index files per thread in threads/ directory
"""

import sys
import argparse
from collections import OrderedDict
from pathlib import Path
from typing import Dict, List, Optional, NamedTuple

# Pipeline modules
import importlib.util as _ilu
import os as _os

def _import_sibling(name):
    """Import a sibling module from the same directory as this script."""
    script_dir = Path(__file__).parent
    spec = _ilu.spec_from_file_location(name, script_dir / f"{name}.py")
    if spec is None or spec.loader is None:
        raise ImportError(f"Cannot find sibling module: {name}.py")
    mod = _ilu.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod

_parser_mod = _import_sibling('email_parser')
_norm_mod = _import_sibling('email_normaliser')
_summary_mod = _import_sibling('email_md_summary')

__all__ = (
    "parse_eml",
    "parse_msg",
    "get_email_body",
    "extract_attachments",
    "load_dedup_registry",
    "save_dedup_registry",
    "get_file_size",
    "extract_header_safe",
    "parse_date_safe",
    "compute_content_hash",
    "_parse_email_file",
    "_extract_headers",
    "_parse_received_date",
    "normalise_email_sections",
    "build_thread_map",
    "reconstruct_thread",
    "generate_thread_index",
    "build_frontmatter",
    "format_size",
    "estimate_tokens",
    "yaml_escape",
    "generate_summary",
    "strip_markdown",
)

# Re-export public API from submodules for callers that import from this file
from email_parser import (  # noqa: E402
    parse_eml,
    parse_msg,
    get_email_body,
    extract_attachments,
    load_dedup_registry,
    save_dedup_registry,
    get_file_size,
    extract_header_safe,
    parse_date_safe,
    compute_content_hash,
    _parse_email_file,
    _extract_headers,
    _parse_received_date,
)
from email_normaliser import (  # noqa: E402
    normalise_email_sections,
    build_thread_map,
    reconstruct_thread,
    generate_thread_index,
    build_frontmatter,
    format_size,
    estimate_tokens,
    yaml_escape,
)
from email_md_summary import (  # noqa: E402
    generate_summary,
    strip_markdown,
)


class ConvertOptions(NamedTuple):
    """Internal options bundle for email_to_markdown pipeline stages."""
    extract_entities: bool = False
    entity_method: str = 'auto'
    summary_mode: str = 'auto'
    thread_map: Optional[Dict] = None
    dedup_registry: Optional[Dict] = None
    no_normalise: bool = False


class _PipelineData(NamedTuple):
    """Intermediate results from the email conversion pipeline."""
    headers: Dict
    date_sent: str
    date_received: str
    file_size: int
    body: str
    description: str
    summary_method_used: str
    attachment_meta: List[Dict]
    attachments: List[Dict]
    tokens_estimate: int


def run_entity_extraction(body, method='auto'):
    """Run entity extraction on email body text.

    Imports entity-extraction.py from the same directory and runs extraction.
    Returns dict of entities grouped by type, or empty dict on failure.
    """
    if not body or not body.strip():
        return {}

    try:
        script_dir = Path(__file__).parent
        # Import entity-extraction module dynamically (filename has hyphens)
        import importlib.util
        spec = importlib.util.spec_from_file_location(
            "entity_extraction",
            script_dir / "entity-extraction.py"
        )
        if spec is None or spec.loader is None:
            return {}
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        return mod.extract_entities(body, method=method)
    except Exception as e:
        print(f"WARNING: Entity extraction failed: {e}", file=sys.stderr)
        return {}


def _build_attachment_meta(attachments):
    """Build frontmatter-ready attachment metadata from raw attachment list."""
    meta_list = []
    for att in attachments:
        meta = {
            'filename': att['filename'],
            'size': format_size(att['size']),
            'content_hash': att['content_hash'],
        }
        if 'deduplicated_from' in att:
            meta['deduplicated_from'] = att['deduplicated_from']
        meta_list.append(meta)
    return meta_list


def _add_header_fields(metadata, headers, date_sent, date_received):
    """Populate email header fields in the metadata dict."""
    metadata['from'] = headers['from']
    metadata['to'] = headers['to']
    if headers['cc']:
        metadata['cc'] = headers['cc']
    if headers['bcc']:
        metadata['bcc'] = headers['bcc']
    metadata['date_sent'] = date_sent
    if date_received:
        metadata['date_received'] = date_received
    metadata['subject'] = headers['subject']
    metadata['size'] = format_size(headers.get('_file_size', 0))
    metadata['message_id'] = headers['message_id']
    if headers['in_reply_to']:
        metadata['in_reply_to'] = headers['in_reply_to']


def _add_thread_fields(metadata, message_id, thread_map):
    """Populate thread reconstruction fields in the metadata dict."""
    if not (thread_map and message_id):
        return
    thread_id, thread_position, thread_length = reconstruct_thread(
        message_id, thread_map)
    if thread_id:
        metadata['thread_id'] = thread_id
        metadata['thread_position'] = thread_position
        metadata['thread_length'] = thread_length


def _build_metadata(pipe, opts):
    """Assemble the ordered metadata dict for YAML frontmatter."""
    metadata = OrderedDict()
    metadata['title'] = pipe.headers['subject']
    metadata['description'] = pipe.description
    metadata['summary_method'] = pipe.summary_method_used

    # Store file_size in headers temporarily for _add_header_fields
    pipe.headers['_file_size'] = pipe.file_size
    _add_header_fields(metadata, pipe.headers, pipe.date_sent,
                       pipe.date_received)

    _add_thread_fields(metadata, pipe.headers['message_id'],
                       opts.thread_map)

    metadata['attachment_count'] = len(pipe.attachments)
    metadata['attachments'] = pipe.attachment_meta
    metadata['tokens_estimate'] = pipe.tokens_estimate

    if opts.extract_entities:
        entities = run_entity_extraction(pipe.body, method=opts.entity_method)
        if entities:
            metadata['entities'] = entities

    return metadata


def email_to_markdown(input_file, output_file=None, attachments_dir=None,
                      opts=None):
    """Convert email file to markdown with YAML frontmatter and attachment extraction.

    Output includes:
    - YAML frontmatter with visible email headers (from, to, cc, bcc, date_sent,
      date_received, subject, size, message_id, in_reply_to, attachment_count,
      attachments list with content_hash per attachment)
    - Thread reconstruction fields (thread_id, thread_position, thread_length)
    - markdown.new convention fields (title = subject, description = auto-summary)
    - summary_method field indicating how the description was generated
    - tokens_estimate for LLM context budgeting
    - entities (when opts.extract_entities=True): people, organisations, properties,
      locations, dates extracted via spaCy/Ollama/regex
    - Body as markdown content

    Args:
        input_file: Path to .eml or .msg file
        output_file: Optional output path for markdown file
        attachments_dir: Optional directory for extracted attachments
        opts: ConvertOptions instance. If None, defaults are used.
              Use ConvertOptions(summary_mode=..., thread_map=..., etc.) to
              configure entity extraction, summary mode, thread reconstruction,
              dedup registry, and normalisation.
    """
    if opts is None:
        opts = ConvertOptions()

    input_path = Path(input_file)
    msg = _parse_email_file(input_path)

    if output_file is None:
        output_file = input_path.with_suffix('.md')
    if attachments_dir is None:
        attachments_dir = input_path.parent / f"{input_path.stem}_attachments"

    # Stage 1: Extract headers and dates
    headers = _extract_headers(msg)
    date_sent = parse_date_safe(headers['date_sent_raw'])
    date_received = parse_date_safe(
        _parse_received_date(headers['date_received_raw']))

    # Stage 2: Extract body and normalise
    body = get_email_body(msg)
    if not opts.no_normalise:
        body = normalise_email_sections(body)

    # Stage 3: Attachments
    attachments = extract_attachments(msg, attachments_dir, opts.dedup_registry)
    attachment_meta = _build_attachment_meta(attachments)

    # Stage 4: Summary and tokens
    description, summary_method_used = generate_summary(
        body, headers['subject'], opts.summary_mode)
    tokens_estimate = estimate_tokens(body)

    # Stage 5: Assemble metadata and write
    pipe = _PipelineData(
        headers=headers,
        date_sent=date_sent,
        date_received=date_received,
        file_size=get_file_size(input_file),
        body=body,
        description=description,
        summary_method_used=summary_method_used,
        attachment_meta=attachment_meta,
        attachments=attachments,
        tokens_estimate=tokens_estimate,
    )
    metadata = _build_metadata(pipe, opts)

    frontmatter = build_frontmatter(metadata)
    md_content = f"{frontmatter}\n\n{body}"

    with open(output_file, 'w', encoding='utf-8') as f:
        f.write(md_content)

    return {
        'markdown': str(output_file),
        'attachments': attachments,
        'attachments_dir': str(attachments_dir) if attachments else None
    }


def _build_arg_parser():
    """Build and return the CLI argument parser."""
    parser = argparse.ArgumentParser(
        description='Convert .eml/.msg email files to markdown with '
                    'attachment extraction and thread reconstruction'
    )
    parser.add_argument('input',
                        help='Input email file (.eml or .msg) or directory '
                             'for batch processing')
    parser.add_argument('--output', '-o',
                        help='Output markdown file (default: input.md)')
    parser.add_argument('--attachments-dir',
                        help='Directory for attachments '
                             '(default: input_attachments/)')
    parser.add_argument('--extract-entities', action='store_true',
                        help='Extract named entities (people, orgs, '
                             'locations, dates) into frontmatter')
    parser.add_argument('--entity-method',
                        choices=['auto', 'spacy', 'ollama', 'regex'],
                        default='auto',
                        help='Entity extraction method (default: auto)')
    parser.add_argument('--summary-mode',
                        choices=['auto', 'heuristic', 'llm', 'off'],
                        default='auto',
                        help='Summary generation mode: auto (default) '
                             'routes by word count, heuristic (sentence '
                             'extraction), llm (force LLM), '
                             'off (160-char truncation)')
    parser.add_argument('--batch', action='store_true',
                        help='Process all .eml/.msg files in input directory '
                             'with thread reconstruction')
    parser.add_argument('--threads-index', action='store_true',
                        help='Generate thread index files (requires --batch)')
    parser.add_argument('--dedup-registry',
                        help='Path to JSON dedup registry for cross-email '
                             'attachment deduplication')
    parser.add_argument('--no-normalise', '--no-normalize',
                        action='store_true',
                        help='Skip email section normalisation (quoted '
                             'replies, signatures, forwards)')
    return parser


def _run_batch(input_path, args, registry):
    """Process all emails in a directory with thread reconstruction."""
    if not input_path.is_dir():
        print("ERROR: --batch requires input to be a directory",
              file=sys.stderr)
        sys.exit(1)

    print("Building thread map...")
    thread_map = build_thread_map(input_path)
    print(f"Found {len(thread_map)} emails")

    batch_opts = ConvertOptions(
        extract_entities=args.extract_entities,
        entity_method=args.entity_method,
        summary_mode=args.summary_mode,
        thread_map=thread_map,
        dedup_registry=registry,
        no_normalise=args.no_normalise,
    )
    processed = 0
    for _message_id, info in thread_map.items():
        email_file = Path(info['file_path'])
        try:
            result = email_to_markdown(
                email_file,
                output_file=email_file.with_suffix('.md'),
                opts=batch_opts,
            )
            processed += 1
            print(f"Processed: {email_file.name} -> {result['markdown']}")
        except Exception as e:
            print(f"ERROR processing {email_file}: {e}", file=sys.stderr)

    print(f"\nProcessed {processed}/{len(thread_map)} emails")

    if args.threads_index:
        print("\nGenerating thread index files...")
        threads = generate_thread_index(thread_map, input_path)
        print(f"Created {len(threads)} thread index files "
              f"in {input_path}/threads/")


def _run_single(input_path, args, registry):
    """Process a single email file."""
    if not input_path.is_file():
        print(f"ERROR: Input file not found: {input_path}",
              file=sys.stderr)
        sys.exit(1)

    thread_map = None
    if input_path.parent.exists():
        try:
            thread_map = build_thread_map(input_path.parent)
            if thread_map:
                print(f"Found {len(thread_map)} emails in directory "
                      "for thread reconstruction")
        except Exception:
            pass  # Thread reconstruction is optional

    single_opts = ConvertOptions(
        extract_entities=args.extract_entities,
        entity_method=args.entity_method,
        summary_mode=args.summary_mode,
        thread_map=thread_map,
        dedup_registry=registry,
        no_normalise=args.no_normalise,
    )
    result = email_to_markdown(
        args.input, args.output, args.attachments_dir,
        opts=single_opts,
    )

    print(f"Created: {result['markdown']}")
    if not result['attachments']:
        return

    deduped = sum(1 for a in result['attachments']
                  if 'deduplicated_from' in a)
    print(f"Extracted {len(result['attachments'])} attachment(s) "
          f"to: {result['attachments_dir']}")
    if deduped:
        print(f"  ({deduped} deduplicated via symlink)")
    for att in result['attachments']:
        suffix = " [dedup]" if 'deduplicated_from' in att else ""
        print(f"  - {att['filename']} "
              f"({format_size(att['size'])}){suffix}")


def main():
    parser = _build_arg_parser()
    args = parser.parse_args()

    registry = None
    if args.dedup_registry:
        registry = load_dedup_registry(args.dedup_registry)

    input_path = Path(args.input)

    if args.batch or input_path.is_dir():
        _run_batch(input_path, args, registry)
    else:
        _run_single(input_path, args, registry)

    if args.dedup_registry and registry is not None:
        save_dedup_registry(registry, args.dedup_registry)


if __name__ == '__main__':
    main()

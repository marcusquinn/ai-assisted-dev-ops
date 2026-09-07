# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""
email_md_summary.py - Summary generation for email-to-markdown pipeline.

Provides heuristic and LLM-based summarisation. Imported by email_to_markdown.py.
"""

import os
import re
import json
import subprocess
import urllib.request
import urllib.error
import urllib.parse
from pathlib import Path

# Word count threshold: emails with <= this many words use heuristic summary
SUMMARY_WORD_THRESHOLD = 100

# Ollama API endpoint (local LLM)
OLLAMA_API_URL = os.environ.get('OLLAMA_API_URL', 'http://localhost:11434/api/generate')

# Ollama model for summarisation
OLLAMA_MODEL = os.environ.get('OLLAMA_MODEL', 'llama3.2')

# Anthropic API endpoint (cloud fallback)
ANTHROPIC_API_URL = 'https://api.anthropic.com/v1/messages'

# Anthropic model for summarisation (cheapest tier)
ANTHROPIC_MODEL = 'claude-haiku-4-20250414'


def _validated_ollama_api_url():
    """Return the configured Ollama HTTP(S) URL, or None when it is unsafe."""
    try:
        parsed = urllib.parse.urlsplit(OLLAMA_API_URL)
        hostname = parsed.hostname
    except (TypeError, ValueError):
        return None

    if parsed.scheme.lower() not in {'http', 'https'} or not hostname:
        return None
    return OLLAMA_API_URL


def strip_markdown(text):
    """Strip markdown formatting from text, returning plain text.

    Removes links, images, emphasis, headings, and collapses whitespace.
    """
    if not text:
        return ""
    text = re.sub(r'!\[([^\]]*)\]\([^)]*\)', r'\1', text)  # images
    text = re.sub(r'\[([^\]]*)\]\([^)]*\)', r'\1', text)    # links
    text = re.sub(r'[*_]{1,3}', '', text)                    # emphasis
    text = re.sub(r'^#{1,6}\s+', '', text, flags=re.MULTILINE)  # headings
    text = re.sub(r'\n+', ' ', text)                          # newlines
    text = re.sub(r'\s+', ' ', text).strip()                  # whitespace
    return text


def make_description(body, max_len=160):
    """Extract first max_len chars of body as description (markdown.new convention).

    Strips markdown formatting, collapses whitespace, and truncates with
    ellipsis if the text exceeds max_len. Used as fallback when summary
    generation is disabled.
    """
    text = strip_markdown(body)
    if not text:
        return ""
    if len(text) > max_len:
        # Truncate at word boundary
        text = text[:max_len].rsplit(' ', 1)[0] + '...'
    return text


def extract_sentences(text, max_sentences=2):
    """Extract the first N complete sentences from plain text.

    Uses sentence-boundary detection (period/exclamation/question followed
    by space or end-of-string). Returns up to max_sentences sentences,
    capped at 200 characters for frontmatter readability.
    """
    if not text:
        return ""
    # Split on sentence boundaries: .!? followed by space or end
    sentences = re.split(r'(?<=[.!?])\s+', text.strip())
    # Filter out very short fragments (< 5 chars) that aren't real sentences
    sentences = [s for s in sentences if len(s.strip()) >= 5]
    if not sentences:
        # No sentence boundaries found — truncate at word boundary
        if len(text) > 200:
            return text[:200].rsplit(' ', 1)[0] + '...'
        return text
    result = ' '.join(sentences[:max_sentences])
    if len(result) > 200:
        result = result[:200].rsplit(' ', 1)[0] + '...'
    return result


def _get_anthropic_api_key():
    """Retrieve Anthropic API key from gopass, credentials file, or environment.

    Returns the key string or None if unavailable. Never prints the key.
    """
    # Try gopass first (encrypted)
    try:
        result = subprocess.run(
            ['gopass', 'show', '-o', 'aidevops/anthropic-api-key'],
            capture_output=True, text=True, timeout=5
        )
        if result.returncode == 0 and result.stdout.strip():
            return result.stdout.strip()
    except (FileNotFoundError, subprocess.TimeoutExpired):
        pass

    # Try credentials file
    creds_file = Path.home() / '.config' / 'aidevops' / 'credentials.sh'
    if creds_file.is_file():
        try:
            for line in creds_file.read_text().splitlines():
                if line.startswith('ANTHROPIC_API_KEY='):
                    key = line.split('=', 1)[1].strip().strip('"').strip("'")
                    if key:
                        return key
        except OSError:
            pass

    # Try environment variable
    return os.environ.get('ANTHROPIC_API_KEY')


def _summarise_with_ollama(plain_text, subject):
    """Summarise email body using local Ollama LLM.

    Returns summary string or None if Ollama is unavailable.
    """
    prompt = (
        "Summarise this email in 1-2 sentences. Be concise and factual. "
        "Return ONLY the summary, no preamble or explanation.\n\n"
        f"Subject: {subject}\n\n"
        f"Body:\n{plain_text[:3000]}"  # Cap input to avoid context overflow
    )
    payload = json.dumps({
        'model': OLLAMA_MODEL,
        'prompt': prompt,
        'stream': False,
        'options': {'temperature': 0.3, 'num_predict': 100}
    }).encode('utf-8')

    api_url = _validated_ollama_api_url()
    if not api_url:
        return None

    req = urllib.request.Request(
        api_url,
        data=payload,
        headers={'Content-Type': 'application/json'},
        method='POST'
    )
    try:
        # _validated_ollama_api_url restricts this configurable target to an
        # HTTP(S) URL with an authority before the request is constructed.
        with urllib.request.urlopen(req, timeout=30) as resp:  # nosec B310 nosemgrep: python.lang.security.audit.dynamic-urllib-use-detected.dynamic-urllib-use-detected,python_urlopen_rule-urllib-urlopen
            data = json.loads(resp.read().decode('utf-8'))
            summary = data.get('response', '').strip()
            if summary:
                # Clean up: remove quotes, leading "Summary:", etc.
                summary = re.sub(r'^(Summary:\s*|"|\')', '', summary)
                summary = summary.rstrip('"\'')
                return summary
    except (urllib.error.URLError, urllib.error.HTTPError, OSError,
            json.JSONDecodeError, KeyError):
        pass
    return None


def _summarise_with_anthropic(plain_text, subject):
    """Summarise email body using Anthropic API (cloud fallback).

    Returns summary string or None if API is unavailable.
    """
    api_key = _get_anthropic_api_key()
    if not api_key:
        return None

    prompt = (
        "Summarise this email in 1-2 sentences. Be concise and factual. "
        "Return ONLY the summary, no preamble or explanation.\n\n"
        f"Subject: {subject}\n\n"
        f"Body:\n{plain_text[:3000]}"
    )
    payload = json.dumps({
        'model': ANTHROPIC_MODEL,
        'max_tokens': 150,
        'messages': [{'role': 'user', 'content': prompt}]
    }).encode('utf-8')

    req = urllib.request.Request(
        ANTHROPIC_API_URL,
        data=payload,
        headers={
            'Content-Type': 'application/json',
            'x-api-key': api_key,
            'anthropic-version': '2023-06-01'
        },
        method='POST'
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            data = json.loads(resp.read().decode('utf-8'))
            content = data.get('content', [])
            if content and isinstance(content, list):
                summary = content[0].get('text', '').strip()
                if summary:
                    return summary
    except (urllib.error.URLError, urllib.error.HTTPError, OSError,
            json.JSONDecodeError, KeyError, IndexError):
        pass
    return None


def _try_llm_summary(plain_text, subject, warn_on_fail=False):
    """Attempt LLM summarisation via Ollama then Anthropic.

    Returns (summary, method) on success, or None if both fail.
    When warn_on_fail is True, prints a warning before returning None.
    """
    import sys
    summary = _summarise_with_ollama(plain_text, subject)
    if summary:
        return summary, 'ollama'
    summary = _summarise_with_anthropic(plain_text, subject)
    if summary:
        return summary, 'anthropic'
    if warn_on_fail:
        print("WARNING: LLM unavailable, falling back to heuristic summary",
              file=sys.stderr)
    return None


def generate_summary(body, subject='', summary_mode='auto'):
    """Generate a 1-2 sentence summary for the email description field.

    Routing logic (summary_mode='auto'):
    - Empty body: returns empty string
    - Short emails (<=SUMMARY_WORD_THRESHOLD words): sentence extraction heuristic
    - Long emails (>SUMMARY_WORD_THRESHOLD words): LLM summarisation
      (Ollama local first, Anthropic API fallback, heuristic last resort)

    Args:
        body: Raw email body (may contain markdown formatting)
        subject: Email subject line (provides context for LLM)
        summary_mode: 'auto' (default), 'heuristic', 'llm', or 'off'

    Returns:
        Tuple of (summary_text, method_used) where method_used is one of:
        'heuristic', 'ollama', 'anthropic', 'truncated', or 'off'
    """
    if summary_mode == 'off':
        return make_description(body), 'off'

    plain_text = strip_markdown(body)
    if not plain_text:
        return '', 'heuristic'

    if summary_mode == 'heuristic':
        return extract_sentences(plain_text), 'heuristic'

    # LLM-capable modes: 'llm' (forced) or 'auto' (long emails only)
    use_llm = summary_mode == 'llm' or len(plain_text.split()) > SUMMARY_WORD_THRESHOLD

    if use_llm:
        result = _try_llm_summary(plain_text, subject,
                                  warn_on_fail=(summary_mode == 'llm'))
        if result:
            return result

    return extract_sentences(plain_text), 'heuristic'

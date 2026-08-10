#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Render report-ready Markdown/JSON to portable HTML."""

from __future__ import annotations

import html
import json
import os
import re
import sys
from pathlib import Path

from report_render_badges import BADGE_INFERRED
from report_render_badges import BADGE_KEY
from report_render_badges import BADGE_MISSING
from report_render_badges import BADGE_PARTIAL
from report_render_badges import BADGE_VERIFIED
from report_render_json import DETAIL_KEY, SUMMARY_KEY, TITLE_KEY, render_json, validate_json_badges
from report_render_markup import inline_markup
from report_render_markdown import render_action_prompt_markdown, render_markdown, validate_markdown_badges
from report_render_styles import dark_style_names, style_css, style_names

if len(sys.argv) < 2:
    sys.stderr.write(f"Usage: {sys.argv[0]} <mode> [input]\n")
    sys.exit(1)

MODE = sys.argv[1]
INPUT = sys.argv[2] if len(sys.argv) > 2 else "-"
TEMPLATE = sys.argv[3] if len(sys.argv) > 3 else "basic"
PDF_PROFILE = sys.argv[4] if len(sys.argv) > 4 else "a4"
THEME = sys.argv[5] if len(sys.argv) > 5 else "auto"

BASIC_CSS = ""

PROFILE_CSS = {
    "a4": "@media print { @page { size: A4 portrait; margin: 12mm; } html, body.report-body { background: var(--report-paper) !important; font-size: 10.5pt; -webkit-print-color-adjust: exact; print-color-adjust: exact; } body.report-body { min-height: 100vh; padding: 0; orphans: 3; widows: 3; } *,*::before,*::after { box-shadow: none !important; filter: none !important; text-shadow: none !important; } body.report-theme-dark { background: var(--report-paper) !important; } .report-shell { display: block; width: 100%; max-width: none; overflow: hidden; padding: 0; } .report-main,.report-content { width: 100%; max-width: 100%; overflow: hidden; } h1,h2,h3,.code-block-head,.source-title { break-after: avoid; break-after: avoid-page; page-break-after: avoid; } .report-main h2.chapter-heading { margin-block-start: 6mm; padding-block-start: 0; } .code-block-wrap,.mermaid-rendered,.latex-rendered-block,.bar-chart p { break-inside: avoid; break-inside: avoid-page; break-after: avoid-page; page-break-inside: avoid; } .action-line,.action-prompt,.accordion,.source-card,.details-note,.info-panel,.impact-panel,.evidence-panel,.action-panel,.callout { width: auto; max-width: 100%; margin: 0 0 8mm; overflow: hidden; border-radius: 0 !important; box-shadow: none !important; break-inside: avoid-page; break-after: avoid-page; } .stat-card { background: var(--report-surface) !important; background-clip: padding-box; } .report-footer { min-height: 22mm; background: #ffffff; border: 1px solid #d1d5db; color: #374151; } .sticky-toc { position: static; max-height: none; overflow: visible; break-after: page; break-inside: auto; border: 0; border-radius: 0; box-shadow: none; } .sticky-toc ol { display: block; max-height: none; overflow: visible; padding-right: 0; } .toc-pdf-actions, .toc-pdf-link { display: none !important; } table { table-layout: fixed; font-size: 8.8pt; border-collapse: separate; border-spacing: 0; } th { background: color-mix(in srgb, var(--report-blue) 12%, var(--report-surface)); } th,td { padding: 4pt 5pt; overflow-wrap: anywhere; } pre,.mermaid,.latex-block { overflow-x: visible; white-space: pre-wrap; overflow-wrap: anywhere; word-break: break-word; } a[href]::after { content: \" (\" attr(href) \")\"; font-size: .85em; overflow-wrap: anywhere; } .sticky-toc a[href]::after, .badge a[href]::after, .source-card-link[href]::after, .anchor-links a[href]::after { content: \"\"; } .appendix-links a[href]::after { content: attr(data-filetype); } }",
    "letter": "@media print { @page { size: Letter portrait; margin: .45in; } html, body.report-body { background: var(--report-paper) !important; font-size: 10.5pt; -webkit-print-color-adjust: exact; print-color-adjust: exact; } body.report-body { min-height: 100vh; padding: 0; orphans: 3; widows: 3; } *,*::before,*::after { box-shadow: none !important; filter: none !important; text-shadow: none !important; } body.report-theme-dark { background: var(--report-paper) !important; } .report-shell { display: block; width: 100%; max-width: none; overflow: hidden; padding: 0; } .report-main,.report-content { width: 100%; max-width: 100%; overflow: hidden; } h1,h2,h3,.code-block-head,.source-title { break-after: avoid; page-break-after: avoid; } .code-block-wrap,.mermaid-rendered,.latex-rendered-block,.bar-chart p { break-inside: avoid; page-break-inside: avoid; } .action-line,.action-prompt,.accordion,.source-card,.details-note,.info-panel,.impact-panel,.evidence-panel,.action-panel,.callout { width: auto; max-width: 100%; margin-inline: 0; overflow: hidden; border-radius: 0 !important; box-shadow: none !important; } .stat-card { background: var(--report-surface) !important; background-clip: padding-box; } .report-footer { min-height: 22mm; background: #ffffff; border: 1px solid #d1d5db; color: #374151; } .sticky-toc { position: static; max-height: none; overflow: visible; break-after: page; break-inside: auto; border: 0; border-radius: 0; box-shadow: none; } .sticky-toc ol { display: block; max-height: none; overflow: visible; padding-right: 0; } .toc-pdf-actions, .toc-pdf-link { display: none !important; } table { table-layout: fixed; font-size: 8.6pt; border-collapse: separate; border-spacing: 0; } th { background: color-mix(in srgb, var(--report-blue) 12%, var(--report-surface)); } th,td { padding: 4pt 5pt; overflow-wrap: anywhere; } pre,.mermaid,.latex-block { overflow-x: visible; white-space: pre-wrap; overflow-wrap: anywhere; word-break: break-word; } }",
    "slides-16-9-1": "@media print { @page { size: 16in 9in; margin: 0; } html, body.report-body { width: auto; min-height: auto; box-sizing: border-box; background: var(--report-paper) !important; padding: .45in; font-size: 32pt; -webkit-print-color-adjust: exact; print-color-adjust: exact; } body.report-theme-dark { background: var(--report-paper) !important; } h1,h2,h3,.code-block-head,.source-title { break-after: avoid; page-break-after: avoid; } .code-block-wrap,.mermaid-rendered,.latex-rendered-block,.bar-chart p { break-inside: avoid; page-break-inside: avoid; } pre,.mermaid,.latex-block { overflow-x: visible; white-space: pre-wrap; overflow-wrap: anywhere; word-break: break-word; } .sticky-toc { max-height: none; overflow: visible; break-inside: auto; border: 0; border-radius: 0; } .sticky-toc ol { max-height: none; overflow: visible; } .toc-pdf-actions, .toc-pdf-link { display: none !important; } .report-main { column-count: auto !important; column-gap: normal !important; } .report-main h1 { font-size: 4.4rem; } .report-main h2 { font-size: 2.8rem; } .report-shell { display: block; padding: 0; } }",
    "slides-16-9-2": "@media print { @page { size: 16in 9in; margin: 0; } html, body.report-body { width: auto; min-height: auto; box-sizing: border-box; background: var(--report-paper) !important; padding: .45in; font-size: 32pt; -webkit-print-color-adjust: exact; print-color-adjust: exact; } body.report-theme-dark { background: var(--report-paper) !important; } h1,h2,h3,.code-block-head,.source-title { break-after: avoid; page-break-after: avoid; } .code-block-wrap,.mermaid-rendered,.latex-rendered-block,.bar-chart p { break-inside: avoid; page-break-inside: avoid; } pre,.mermaid,.latex-block { overflow-x: visible; white-space: pre-wrap; overflow-wrap: anywhere; word-break: break-word; } .sticky-toc { max-height: none; overflow: visible; break-inside: auto; border: 0; border-radius: 0; } .sticky-toc ol { max-height: none; overflow: visible; } .toc-pdf-actions, .toc-pdf-link { display: none !important; } .report-main { column-count: auto !important; column-gap: normal !important; } .report-main > * { break-inside: avoid; } .report-main h1 { font-size: 4.4rem; } .report-main h2 { font-size: 2.8rem; } .report-shell { display: block; padding: 0; } }",
    "slides-16-9-3": "@media print { @page { size: 16in 9in; margin: 0; } html, body.report-body { width: auto; min-height: auto; box-sizing: border-box; background: var(--report-paper) !important; padding: .45in; font-size: 32pt; -webkit-print-color-adjust: exact; print-color-adjust: exact; } body.report-theme-dark { background: var(--report-paper) !important; } h1,h2,h3,.code-block-head,.source-title { break-after: avoid; page-break-after: avoid; } .code-block-wrap,.mermaid-rendered,.latex-rendered-block,.bar-chart p { break-inside: avoid; page-break-inside: avoid; } pre,.mermaid,.latex-block { overflow-x: visible; white-space: pre-wrap; overflow-wrap: anywhere; word-break: break-word; } .sticky-toc { max-height: none; overflow: visible; break-inside: auto; border: 0; border-radius: 0; } .sticky-toc ol { max-height: none; overflow: visible; } .toc-pdf-actions, .toc-pdf-link { display: none !important; } .report-main { column-count: auto !important; column-gap: normal !important; } .report-main > * { break-inside: avoid; } .report-main h1 { font-size: 4.4rem; } .report-main h2 { font-size: 2.8rem; } .report-shell { display: block; padding: 0; } }",
}

PDF_PAGINATION_CSS = """
@media print {
@page { margin: 12mm 0; background: __REPORT_PAGE_BACKGROUND__; }
@page report-letter { size: Letter portrait; margin: .45in 0; background: __REPORT_PAGE_BACKGROUND__; }
html { background: __REPORT_PAGE_BACKGROUND__ !important; }
body.report-body { box-sizing: border-box; padding: 0 12mm; orphans: 3; widows: 3; }
body.report-pdf-profile-letter { page: report-letter; padding: 0 .45in; }
body.report-body:not(.report-theme-dark) { --report-paper: #ffffff; --report-paper-raised: #ffffff; --report-panel: #ffffff; --report-surface: #ffffff; background: #ffffff !important; }
body.report-body:not(.report-theme-dark) .report-shell, body.report-body:not(.report-theme-dark) .report-main, body.report-body:not(.report-theme-dark) .report-content { background: #ffffff !important; }
body.report-body { position: relative; background: var(--report-paper) !important; }
body.report-theme-dark .report-shell, body.report-theme-dark .report-main, body.report-theme-dark .report-content { background: var(--report-paper) !important; }
body.report-body::before { content: none; display: none; }
.report-shell, .report-main, .report-content { overflow: visible; border: 0 !important; outline: 0 !important; box-shadow: none !important; }
.report-keep-with-heading, .report-keep-with-heading.report-chapter-page { border: 0 !important; outline: 0 !important; box-shadow: none !important; }
.report-front { display: block; min-height: calc(297mm - 24mm); break-after: auto; page-break-after: auto; }
body.report-pdf-profile-letter .report-front { min-height: 10.1in; }
.sticky-toc { break-before: auto; page-break-before: auto; }
.sticky-toc-header { break-before: auto; page-break-before: auto; }
.report-main h2.chapter-heading { margin-block-start: 10mm; padding-block-start: 5mm; border-top: 0 !important; break-before: page; break-inside: avoid-page; page-break-before: always; page-break-inside: avoid; }
.report-keep-with-heading.report-chapter-page { break-before: page; page-break-before: always; }
.report-main h2.chapter-heading::before { break-after: avoid-page; page-break-after: avoid; }
.accordion { margin-block-start: 5mm; }
.report-footer { display: flex; min-height: 22mm; margin-block-start: 8mm; padding: 0 6mm; align-items: center; justify-content: center; text-align: center; box-sizing: border-box; }
.report-keep-with-heading { display: block; margin-block: 6mm 8mm; break-inside: avoid-page; page-break-inside: avoid; }
.report-keep-with-heading > :first-child { margin-block-start: 0; }
.report-keep-with-heading > :last-child { margin-block-end: 0; }
.example-card > header, .block-template > header, .report-keep-with-heading > h2, .report-keep-with-heading > h3 { break-after: avoid-page; page-break-after: avoid; }
.example-card > .code-block-wrap, .block-template > .code-block-wrap, .report-keep-with-heading > .code-block-wrap, .report-keep-with-heading > .source-card, .report-keep-with-heading > .source-item, .report-keep-with-heading > .source-list, .report-keep-with-heading > .sources-layout, .report-keep-with-heading > .sources-group, .report-keep-with-heading > .callout, .report-keep-with-heading > .info-panel, .report-keep-with-heading > .impact-panel, .report-keep-with-heading > .evidence-panel, .report-keep-with-heading > .action-panel, .report-keep-with-heading > .details-note, .report-keep-with-heading > .myth-callout, .report-keep-with-heading > .accordion { break-before: avoid-page; page-break-before: avoid; }
.action-line, .code-block-wrap, .mermaid-rendered, .latex-rendered-block, .example-card > .code-block-wrap, .block-template > .code-block-wrap, .bar-chart p, .chapter-hero, .case-study-card, .tactic-card, .example-card, .block-template, .good-bad, .facts-table, .facts-table-wrap, .report-main > table, .details-note, .industry-card, .priority-group, .checklist-card, .source-card, .source-item, .source-list, .sources-layout, .sources-group, .myth-callout, .info-panel, .impact-panel, .evidence-panel, .action-panel, .severity-key, .accordion, .quote-card, .callout, .action-prompt { -webkit-box-decoration-break: clone; box-decoration-break: clone; box-sizing: border-box; width: calc(100% - 12pt); max-width: calc(100% - 12pt); margin: 6mm 6pt 8mm; overflow: visible; break-inside: avoid-page; page-break-inside: avoid; }
.code-block-wrap, .mermaid-rendered, .latex-rendered-block, .example-card > .code-block-wrap, .block-template > .code-block-wrap, .report-keep-with-heading > .code-block-wrap { overflow: hidden; border-radius: var(--report-radius-md) !important; background-clip: padding-box; }
.code-block-wrap > :first-child { border-top-left-radius: calc(var(--report-radius-md) - 1px); border-top-right-radius: calc(var(--report-radius-md) - 1px); }
.facts-table-wrap { overflow: hidden; border-radius: var(--report-radius-md) !important; background-clip: padding-box; clip-path: inset(0 round var(--report-radius-md)); contain: paint; }
.facts-table thead tr:first-child th:first-child, .facts-table-wrap thead tr:first-child th:first-child, .report-main > table thead tr:first-child th:first-child { border-top-left-radius: calc(var(--report-radius-md) - 1px); }
.facts-table thead tr:first-child th:last-child, .facts-table-wrap thead tr:first-child th:last-child, .report-main > table thead tr:first-child th:last-child { border-top-right-radius: calc(var(--report-radius-md) - 1px); }
.facts-table tbody tr:last-child td:first-child, .facts-table-wrap tbody tr:last-child td:first-child, .report-main > table tbody tr:last-child td:first-child { border-bottom-left-radius: calc(var(--report-radius-md) - 1px); }
.facts-table tbody tr:last-child td:last-child, .facts-table-wrap tbody tr:last-child td:last-child, .report-main > table tbody tr:last-child td:last-child { border-bottom-right-radius: calc(var(--report-radius-md) - 1px); }
.good-bad { display: block; }
.good-row, .bad-row { margin-block: 0 8mm; }
.report-main h2.chapter-heading + .chapter-hero, .report-main h2.chapter-heading + .tactic-card, .report-main h2.chapter-heading + .example-card, .report-main h2.chapter-heading + .good-bad, .report-main h2.chapter-heading + .facts-table-wrap, .report-main h2.chapter-heading + .details-note, .report-main h2.chapter-heading + .industry-card, .report-main h2.chapter-heading + .priority-group, .report-main h2.chapter-heading + .checklist-card, .report-main h2.chapter-heading + .source-card, .report-main h2.chapter-heading + .sources-layout, .report-main h2.chapter-heading + .sources-group, .report-main h2.chapter-heading + .myth-callout, .report-main h2.chapter-heading + .info-panel, .report-main h2.chapter-heading + .impact-panel, .report-main h2.chapter-heading + .evidence-panel, .report-main h2.chapter-heading + .action-panel, .report-main h2.chapter-heading + .severity-key, .report-main h2.chapter-heading + .accordion, .report-main h2.chapter-heading + .quote-card, .report-main h2.chapter-heading + .callout { break-before: avoid-page; page-break-before: avoid; }
}
""".strip()

SLIDES_PAGE_MARGIN_CSS = """
@media print {
@page { size: 16in 9in; margin: 0; background: __REPORT_PAGE_BACKGROUND__; }
html, body.report-body { box-sizing: border-box; padding: 0; }
.report-shell { -webkit-box-decoration-break: clone; box-decoration-break: clone; box-sizing: border-box; padding: .45in; }
.sticky-toc, .report-main, .report-content { -webkit-box-decoration-break: clone; box-decoration-break: clone; }
.sticky-toc { display: none !important; }
.report-title-page { display: block; min-height: 0; padding-block: 1.3in .45in; break-inside: avoid-page; page-break-inside: avoid; }
.report-title-page h1 { font-size: clamp(60pt, 9vw, 88pt) !important; line-height: .95; margin-block: 0 .7in; }
.report-title-page p { font-size: 32pt !important; line-height: 1.2; margin-block: .2in 0; }
.report-main h2.chapter-heading { max-width: none; margin-block-start: .45in; padding-block-start: .18in; text-align: center; }
.report-main h2.chapter-heading::before { content: none !important; display: none !important; }
.report-main p, .report-main li, .report-main summary, .report-main td, .report-main th, .badge-key p { font-size: 32pt !important; line-height: 1.22; }
.report-main .report-kicker, .report-main .eyebrow, .report-main .meta-label, .report-main .priority-label, .report-main .source-card-type, .report-main .source-meta, .report-main .stat-label, .report-main .stat-period { font-size: 32pt !important; line-height: 1.18; }
.report-main h1 { font-size: clamp(72pt, 10vw, 116pt) !important; line-height: .98; }
.report-main h2 { font-size: clamp(54pt, 7vw, 88pt) !important; line-height: 1; }
.report-main h3 { font-size: clamp(36pt, 4vw, 54pt) !important; line-height: 1.08; }
.report-main .badge { font-size: 32pt !important; line-height: 1; white-space: nowrap; }
.badge-key p { grid-template-columns: max-content minmax(0, 1fr) !important; align-items: center; column-gap: .45in; text-align: left; }
.badge-key p > :not(.badge) { text-align: left; }
.report-main .code-block-wrap, .report-main .mermaid-rendered, .report-main .latex-rendered-block, .report-main .quote-card, .report-main blockquote, .report-main .info-panel, .report-main .impact-panel, .report-main .evidence-panel, .report-main .action-panel, .report-main .callout, .report-main .accordion, .report-main .facts-table-wrap, .report-main > table, .report-main .source-card, .report-main .source-item, .report-main .details-note, .report-main .myth-callout, .report-main .severity-key, .report-main .example-card, .report-main .block-template { break-before: page; break-inside: avoid-page; page-break-before: always; page-break-inside: avoid; }
.report-main .report-cover, .report-main .stats-strip, .report-main .summary-stats, .report-main .badge-key { break-inside: avoid-page; page-break-inside: avoid; }
.report-main .source-item { break-before: page; page-break-before: always; }
.report-main .quote-card, .report-main blockquote { min-height: 5.8in; display: flex; align-items: center; }
.report-main .code-block-wrap pre, .report-main .mermaid, .report-main .latex-block { font-size: 32pt !important; line-height: 1.2; white-space: pre-wrap; overflow-wrap: anywhere; }
.report-main .facts-table, .report-main .facts-table-wrap table, .report-main > table { table-layout: fixed; width: 100%; min-width: 0; font-size: 26pt !important; }
.report-main .facts-table th, .report-main .facts-table td, .report-main .facts-table-wrap th, .report-main .facts-table-wrap td, .report-main > table th, .report-main > table td { padding: .22in .28in; font-size: 26pt !important; line-height: 1.2; overflow-wrap: anywhere; vertical-align: top; }
.report-main :where(.stats-strip, .summary-stats, .tactic-grid, .sources-layout, .good-bad, .severity-key, .badge-key) :where(p, li, span, a) { font-size: 26pt !important; line-height: 1.2; }
.report-main td .evidence-badge, .report-main th .evidence-badge { display: flex; flex-direction: column; gap: .12in; align-items: flex-start; max-width: 100%; white-space: normal; }
.report-main td .badge, .report-main th .badge, .report-main td .evidence-label, .report-main th .evidence-label { max-width: 100%; font-size: 26pt !important; white-space: normal; }
.report-main .report-keep-with-heading > :where(.code-block-wrap, .mermaid-rendered, .latex-rendered-block), .report-main :where(.example-card, .block-template) > .code-block-wrap { break-before: avoid-page !important; page-break-before: avoid !important; }
.accordion { margin-block-start: .22in; }
}
""".strip()

LETTER_PAGE_FIX_CSS = """
@media print {
.report-title-page { min-height: 8.6in; }
.report-shell, .report-main, .report-content { border: 0 !important; outline: 0 !important; box-shadow: none !important; }
}
""".strip()

BUILTIN_TEMPLATES = ("basic", "editorial-evidence") + style_names()
THEMES = ("auto", "light", "dark")


def load_css(template: str, pdf_profile: str) -> str:
    if template == "basic":
        css = BASIC_CSS
    elif template == "editorial-evidence":
        path = Path(__file__).resolve().parents[1] / "templates" / "reports" / "llm-visibility-report.css"
        css = path.read_text(encoding="utf-8")
    elif template in style_names():
        css = style_css(template)
    else:
        names = ", ".join(BUILTIN_TEMPLATES)
        raise ValueError(f"unknown report template: {template}. Available: {names}")
    if template == "basic":
        return css
    if pdf_profile not in PROFILE_CSS:
        raise ValueError(f"unknown PDF export profile: {pdf_profile}")
    if THEME not in THEMES:
        raise ValueError(f"unknown report theme: {THEME}. Available: {', '.join(THEMES)}")
    page_background = "#ffffff"
    if THEME == "dark":
        matches = re.findall(r"body\.report-theme-dark\s*\{[^}]*--report-paper:\s*([^;]+);", css, flags=re.S)
        if matches:
            page_background = matches[-1].strip()
    profile_css = PROFILE_CSS[pdf_profile]
    pagination_css = PDF_PAGINATION_CSS.replace("__REPORT_PAGE_BACKGROUND__", page_background)
    if pdf_profile.startswith("slides-16-9"):
        pagination_css = f"{pagination_css}\n{SLIDES_PAGE_MARGIN_CSS.replace('__REPORT_PAGE_BACKGROUND__', page_background)}"
    elif pdf_profile == "letter":
        pagination_css = f"{pagination_css}\n{LETTER_PAGE_FIX_CSS}"
    return f"{css}\n{profile_css}\n{pagination_css}"


def read_input(path: str) -> str:
    if path == "-":
        return sys.stdin.read()
    with open(path, encoding="utf-8") as handle:
        return handle.read()


def toc_title(title: str) -> str:
    """Return a TOC-safe title without visual badges or inline-only tokens."""

    cleaned = re.sub(r"\{\{\s*(?:badge|evidence)\s*:[^}]+?\s*\}\}", "", title, flags=re.I)
    return " ".join(cleaned.split())


def is_executive_summary(title: str) -> bool:
    return toc_title(title).lower() == "executive summary"


def wrap_title_page(body: str) -> str:
    """Wrap the opening title/subtitle/author lines for PDF cover-page styling."""

    cover_match = re.search(r'<section class="report-cover"', body)
    if cover_match:
        prefix = body[: cover_match.start()]
        if "<h1" in prefix and "<h2" not in prefix:
            return f'<section class="report-title-page">{prefix}</section>\n{body[cover_match.start():]}'
    match = re.match(r"^(\s*<h1\b.*?</h1>\s*)(.*)$", body, flags=re.S)
    if not match:
        return body
    return f'<section class="report-title-page">{match.group(1)}</section>\n{match.group(2)}'


def split_intro_body(body: str) -> tuple[str, str]:
    """Split print intro pages from the main chapter body at the first numbered chapter."""

    wrapped = wrap_title_page(body)
    match = re.search(r'<h2\b[^>]*\bclass="[^"]*chapter-heading[^"]*"', wrapped)
    if not match:
        return wrapped, ""
    return wrapped[: match.start()].rstrip(), wrapped[match.start() :].lstrip()


def wrap_document(headings: list[tuple[int, str, str]], body: str) -> str:
    css = load_css(TEMPLATE, PDF_PROFILE)
    style_tag = f"<style>{css}</style>" if css.strip() else ""
    pdf_href = os.environ.get("REPORT_PDF_HREF", "").strip()
    pdf_usletter_href = os.environ.get("REPORT_PDF_USLETTER_HREF", "").strip()
    pdf_landscape_href = os.environ.get("REPORT_PDF_LANDSCAPE_HREF", "").strip()
    pdf_link = ""
    pdf_links = []
    if pdf_href:
        pdf_links.append(
            f'<a class="toc-pdf-link" href="{html.escape(pdf_href)}" '
            'aria-label="Open A4 PDF version" title="Open A4 PDF version">A4</a>'
        )
    if pdf_usletter_href:
        pdf_links.append(
            f'<a class="toc-pdf-link" href="{html.escape(pdf_usletter_href)}" '
            'aria-label="Open US Letter PDF version" title="Open US Letter PDF version">US Letter</a>'
        )
    if pdf_landscape_href:
        pdf_links.append(
            f'<a class="toc-pdf-link" href="{html.escape(pdf_landscape_href)}" '
            'aria-label="Open slides PDF version" title="Open slides PDF version">Slides</a>'
        )
    if pdf_links:
        pdf_link = f'<div class="toc-pdf-actions" aria-label="PDF downloads">{"".join(pdf_links)}</div>'
    toc_items = []
    chapter = 0
    section = 0
    for level, title, anchor in headings:
        clean_title = toc_title(title)
        label = clean_title
        item_class = "toc-entry"
        if level == 2 and not is_executive_summary(title):
            chapter += 1
            section = 0
            label = f"{chapter}. {clean_title}"
            item_class = "toc-entry toc-chapter"
        elif level == 3 and chapter:
            section += 1
            label = f"{chapter}.{section} {clean_title}"
            item_class = "toc-entry toc-subsection"
        toc_items.append(f'<li class="{item_class}"><a href="#{anchor}">{inline_markup(label)}</a></li>')
    active_toc_script = """
<script>
(() => {
  const links = Array.from(document.querySelectorAll('.sticky-toc a[href^="#"]'));
  const headings = links.map((link) => document.getElementById(link.getAttribute('href').slice(1))).filter(Boolean);
  const setActive = (id) => {
    links.forEach((link) => link.setAttribute('aria-current', link.getAttribute('href') === `#${id}` ? 'true' : 'false'));
  };
  if (!('IntersectionObserver' in window) || headings.length === 0) {
    if (headings[0]) setActive(headings[0].id);
    return;
  }
  const observer = new IntersectionObserver((entries) => {
    const visible = entries.filter((entry) => entry.isIntersecting).sort((a, b) => a.boundingClientRect.top - b.boundingClientRect.top)[0];
    if (visible) setActive(visible.target.id);
  }, { rootMargin: '-20% 0px -65% 0px', threshold: [0, 1] });
  headings.forEach((heading) => observer.observe(heading));
  setActive(headings[0].id);
})();
</script>
<script>
(() => {
  document.querySelectorAll('.code-copy').forEach((button) => {
    button.addEventListener('click', async () => {
      const code = button.closest('.code-block-wrap')?.querySelector('code')?.innerText || '';
      const original = button.dataset.originalLabel || button.textContent || '⧉';
      button.dataset.originalLabel = original;
      const showCopied = () => {
        button.textContent = '✓';
        button.classList.add('is-copied');
        button.setAttribute('aria-label', 'Copied');
        setTimeout(() => {
          button.textContent = original;
          button.classList.remove('is-copied');
          button.setAttribute('aria-label', 'Copy code');
        }, 1200);
      };
      try {
        if (navigator.clipboard && window.isSecureContext) {
          await navigator.clipboard.writeText(code);
        } else {
          const textArea = document.createElement('textarea');
          textArea.value = code;
          textArea.setAttribute('readonly', '');
          textArea.style.position = 'fixed';
          textArea.style.left = '-9999px';
          document.body.appendChild(textArea);
          textArea.select();
          document.execCommand('copy');
          textArea.remove();
        }
        showCopied();
      } catch (_) {
        button.textContent = 'Copy';
      }
    });
  });
})();
</script>
""".strip()
    intro_body, rest_body = split_intro_body(body)
    title_body = ""
    title_match = re.match(r'^\s*(<section class="report-title-page">.*?</section>)\s*(.*)$', intro_body, flags=re.S)
    if title_match:
        title_body = title_match.group(1)
        intro_body = title_match.group(2)
    title_main = f"""
<main class="report-content report-main report-title-front">
{title_body}
</main>""" if title_body.strip() else ""
    rest_main = f"""
<main class="report-content report-main report-rest">
{rest_body}
</main>""" if rest_body.strip() else ""
    return f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Report</title>
{style_tag}
</head>
<body class="report-body report-theme-{html.escape(THEME)} report-pdf-profile-{html.escape(PDF_PROFILE)} report-template-{html.escape(TEMPLATE)}">
<div class="report-shell">
<div class="report-main-flow">
{title_main}
<main class="report-content report-main report-front">
{intro_body}
</main>
</div>
{pdf_link}
<nav class="sticky-toc" aria-label="Report table of contents">
<div class="sticky-toc-header"><h2>Contents</h2></div>
<ol>
{chr(10).join(toc_items)}
</ol>
</nav>
{rest_main}
</div>
<footer class="report-footer">© 2025-2026 Marcus Quinn. Licensed under MIT.</footer>
{active_toc_script}
</body>
</html>
"""


def sample_json() -> str:
    return json.dumps(
        {
            TITLE_KEY: "AI Visibility Report",
            "sections": [
                {
                    TITLE_KEY: "Executive summary",
                    SUMMARY_KEY: "Visibility improved across answer engines.",
                    "items": [
                        {TITLE_KEY: "AIO", DETAIL_KEY: "Cited with source card.", BADGE_KEY: BADGE_VERIFIED},
                        {TITLE_KEY: "Gemini", DETAIL_KEY: "Partial coverage found.", BADGE_KEY: BADGE_PARTIAL},
                        {TITLE_KEY: "ChatGPT", DETAIL_KEY: "Inference from comparable prompts.", BADGE_KEY: BADGE_INFERRED},
                        {TITLE_KEY: "Perplexity", DETAIL_KEY: "No citation found.", BADGE_KEY: BADGE_MISSING},
                    ],
                }
            ],
        },
        indent=2,
    )


def handle_static_mode() -> bool:
    handlers = {
        "print-css": lambda: load_css(TEMPLATE, PDF_PROFILE),
        "list-templates": lambda: "\n".join(BUILTIN_TEMPLATES),
        "list-dark-templates": lambda: "\n".join(dark_style_names()),
        "sample-json": sample_json,
    }
    handler = handlers.get(MODE)
    if handler is None:
        return False
    print(handler())
    return True


def handle_text_mode(text: str) -> None:
    if MODE == "action-prompts":
        sys.stdout.write(render_action_prompt_markdown(text))
        return
    if MODE == "validate":
        stripped = text.lstrip()
        if stripped.startswith(("{", "[")):
            validate_json_badges(json.loads(text))
        else:
            validate_markdown_badges(text)
        return
    stripped = text.lstrip()
    headings, body = render_json(text) if stripped.startswith(("{", "[")) else render_markdown(text)
    sys.stdout.write(wrap_document(headings, body))


def main() -> int:
    if handle_static_mode():
        return 0
    handle_text_mode(read_input(INPUT))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as exc:
        sys.stderr.write(f"{exc}\n")
        sys.exit(1)

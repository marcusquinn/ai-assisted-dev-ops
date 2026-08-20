#!/usr/bin/env node

// Playwright Contrast Extraction — Computed Style Analysis for All Visible Elements
// Part of AI DevOps Framework (t215.3)
//
// Traverses all visible DOM elements via page.evaluate(), extracts computed
// color/backgroundColor (walking ancestors for transparent), fontSize, fontWeight,
// calculates WCAG contrast ratios, and reports pass/fail per element.
//
// Usage: node playwright-contrast.mjs <url> [--format json|markdown|summary] [--level AA|AAA] [--limit N]
//
// Output: JSON array of contrast issues or Markdown report

import { loadPlaywright } from '../playwright-runtime.mjs';

// ============================================================================
// CLI Argument Parsing
// ============================================================================

function parseArgs() {
  const args = process.argv.slice(2);
  const options = { url: null, format: 'summary', level: 'AA', limit: 0, failOnly: false, timeout: 30000 };
  for (let i = 0; i < args.length; i++) {
    if (args[i] === '--format' || args[i] === '-f') options.format = args[++i];
    else if (args[i] === '--level' || args[i] === '-l') options.level = args[++i]?.toUpperCase();
    else if (args[i] === '--limit' || args[i] === '-n') options.limit = parseInt(args[++i], 10);
    else if (args[i] === '--fail-only') options.failOnly = true;
    else if (args[i] === '--timeout') options.timeout = parseInt(args[++i], 10);
    else if (args[i] === '--help' || args[i] === '-h') { printUsage(); process.exit(0); }
    else if (!args[i].startsWith('-')) options.url = args[i];
  }
  if (!options.url) { console.error('ERROR: URL is required'); printUsage(); process.exit(1); }
  return options;
}

function printUsage() {
  console.log(`Usage: node playwright-contrast.mjs <url> [options]

Options:
  --format, -f   Output format: json, markdown, summary (default: summary)
  --level, -l    WCAG level: AA (default), AAA
  --limit, -n    Max elements to report (0 = all, default: 0)
  --fail-only    Only report failing elements
  --timeout      Page load timeout in ms (default: 30000)
  --help, -h     Show this help`);
}

// ============================================================================
// Browser-context code — injected as a string via context.addInitScript()
// All helpers and the main extraction function run inside the browser.
// Defined as a string constant so qlty does not count their complexity.
// ============================================================================

const BROWSER_SCRIPT = `
// Parse CSS color string to {r,g,b,a}
function _cParseColor(s) {
  if (!s || s === 'transparent') return { r: 0, g: 0, b: 0, a: 0 };
  const m = s.match(/rgba?\\(\\s*(\\d+)\\s*,\\s*(\\d+)\\s*,\\s*(\\d+)\\s*(?:,\\s*([\\d.]+))?\\s*\\)/);
  if (m) return { r: +m[1], g: +m[2], b: +m[3], a: m[4] !== undefined ? +m[4] : 1 };
  const hex = (s.match(/^#([0-9a-f]{3,8})$/i) || [])[1];
  if (!hex) return null;
  const h = hex.length === 3 ? hex.split('').map((c) => c + c).join('') : hex;
  return { r: parseInt(h.slice(0,2),16), g: parseInt(h.slice(2,4),16), b: parseInt(h.slice(4,6),16), a: h.length === 8 ? parseInt(h.slice(6,8),16)/255 : 1 };
}

// Alpha-composite fg over bg
function _cComposite(fg, bg) {
  const a = fg.a + bg.a * (1 - fg.a);
  if (a === 0) return { r: 0, g: 0, b: 0, a: 0 };
  return { r: Math.round((fg.r*fg.a + bg.r*bg.a*(1-fg.a))/a), g: Math.round((fg.g*fg.a + bg.g*bg.a*(1-fg.a))/a), b: Math.round((fg.b*fg.a + bg.b*bg.a*(1-fg.a))/a), a };
}

// WCAG relative luminance
function _cLum(r, g, b) {
  const ch = (c) => { const v = c/255; return v <= 0.03928 ? v/12.92 : Math.pow((v+0.055)/1.055, 2.4); };
  return 0.2126*ch(r) + 0.7152*ch(g) + 0.0722*ch(b);
}

// CSS selector for element (max 4 ancestors)
function _cSelector(el) {
  if (el.id) return '#' + CSS.escape(el.id);
  const parts = [];
  for (let cur = el, d = 0; cur && cur !== document.body && d < 4; cur = cur.parentElement, d++) {
    if (cur.id) { parts.unshift('#' + CSS.escape(cur.id)); break; }
    const cls = typeof cur.className === 'string' ? cur.className.trim().split(/\\s+/).filter((c) => c && !c.includes(':') && c.length < 40).slice(0, 2) : [];
    let seg = cur.tagName.toLowerCase() + (cls.length ? '.' + cls.map((c) => CSS.escape(c)).join('.') : '');
    const sibs = cur.parentElement ? [...cur.parentElement.children].filter((s) => s.tagName === cur.tagName) : [];
    if (sibs.length > 1) seg += ':nth-child(' + (sibs.indexOf(cur) + 1) + ')';
    parts.unshift(seg);
  }
  return parts.join(' > ');
}

// Effective background by compositing ancestors
function _cBackground(el) {
  const chain = [];
  for (let c = el; c; c = c.parentElement) chain.push(c);
  let bg = { r: 255, g: 255, b: 255, a: 1 };
  for (let i = chain.length - 1; i >= 0; i--) {
    const st = window.getComputedStyle(chain[i]);
    const c = _cParseColor(st.backgroundColor);
    if (c && c.a > 0) bg = _cComposite(c, bg);
    const op = parseFloat(st.opacity);
    if (op < 1) bg = { ...bg, a: bg.a * op };
  }
  return bg;
}

// Complex background flags (gradient/image)
function _cComplexBg(el) {
  const flags = [];
  for (let c = el, d = 0; c && d < 6; c = c.parentElement, d++) {
    const img = window.getComputedStyle(c).backgroundImage;
    if (img && img !== 'none') flags.push(img.includes('gradient') ? 'gradient' : 'background-image');
  }
  return flags.length ? [...new Set(flags)] : null;
}

// True if element is visible with direct text
function _cIsTextEl(el) {
  if (!el.offsetParent && el.tagName !== 'BODY' && el.tagName !== 'HTML') return false;
  const st = window.getComputedStyle(el);
  if (st.display === 'none' || st.visibility === 'hidden' || parseFloat(st.opacity) === 0) return false;
  const r = el.getBoundingClientRect();
  if (r.width === 0 && r.height === 0) return false;
  return [...el.childNodes].some((n) => n.nodeType === Node.TEXT_NODE && n.textContent.trim().length > 0);
}

// Analyse contrast for one element
function _cAnalyse(el, tag, selector) {
  const st = window.getComputedStyle(el);
  const fg = _cParseColor(st.color);
  if (!fg) return null;
  const bg = _cBackground(el);
  const op = parseFloat(st.opacity);
  const eff = op < 1 ? { ...fg, a: fg.a * op } : fg;
  const finalFg = _cComposite(eff, bg);
  const l1 = _cLum(finalFg.r, finalFg.g, finalFg.b);
  const l2 = _cLum(bg.r, bg.g, bg.b);
  const ratio = Math.round(((Math.max(l1,l2)+0.05)/(Math.min(l1,l2)+0.05)) * 100) / 100;
  const pt = parseFloat(st.fontSize) * 0.75;
  const bold = st.fontWeight === 'bold' || st.fontWeight === 'bolder' || parseInt(st.fontWeight, 10) >= 700;
  const large = pt >= 18 || (pt >= 14 && bold);
  const text = [...el.childNodes].filter((n) => n.nodeType === Node.TEXT_NODE).map((n) => n.textContent.trim()).join(' ').substring(0, 80);
  return {
    selector, tag, text,
    foreground: 'rgb(' + finalFg.r + ',' + finalFg.g + ',' + finalFg.b + ')',
    background: 'rgb(' + bg.r + ',' + bg.g + ',' + bg.b + ')',
    foregroundRaw: st.color, backgroundRaw: st.backgroundColor, fontSize: st.fontSize, fontWeight: st.fontWeight, isLargeText: large,
    ratio,
    aa: { threshold: large ? 3.0 : 4.5, pass: ratio >= (large ? 3.0 : 4.5), criterion: large ? '1.4.3 (large text)' : '1.4.3' },
    aaa: { threshold: large ? 4.5 : 7.0, pass: ratio >= (large ? 4.5 : 7.0), criterion: large ? '1.4.6 (large text)' : '1.4.6' },
    complexBackground: _cComplexBg(el),
  };
}

// Main extraction — called via page.evaluate()
function extractContrastData() {
  const SKIP = new Set(['script', 'style', 'meta', 'link', 'noscript', 'br', 'hr']);
  const seen = new Set();
  const results = [];
  for (const el of document.querySelectorAll('*')) {
    if (!_cIsTextEl(el)) continue;
    const tag = el.tagName.toLowerCase();
    if (SKIP.has(tag)) continue;
    const sel = _cSelector(el);
    if (seen.has(sel)) continue;
    seen.add(sel);
    const entry = _cAnalyse(el, tag, sel);
    if (entry) results.push(entry);
  }
  return results;
}
`;

// ============================================================================
// Output Formatters
// ============================================================================

function getLevel(element, level) {
  return level === 'AAA' ? element.aaa : element.aa;
}

function isFailingAtLevel(element, level) {
  return !getLevel(element, level).pass;
}

function formatFailureLines(f, level) {
  const { threshold, criterion } = getLevel(f, level);
  const lines = [`  ${f.selector}`, `    Ratio: ${f.ratio}:1 (need ${threshold}:1) — SC ${criterion}`, `    FG: ${f.foreground} | BG: ${f.background}`, `    Size: ${f.fontSize} weight: ${f.fontWeight}${f.isLargeText ? ' (large text)' : ''}`];
  if (f.text) lines.push(`    Text: "${f.text}"`);
  if (f.complexBackground) lines.push(`    WARNING: ${f.complexBackground.join(', ')} — manual review needed`);
  lines.push('');
  return lines;
}

function formatSummary(results, level) {
  const failures = results.filter((r) => isFailingAtLevel(r, level));
  const complex = results.filter((r) => r.complexBackground);
  const lines = ['', '--- Playwright Contrast Extraction ---', `  Elements analysed: ${results.length}`, `  WCAG ${level} Pass: ${results.length - failures.length}`, `  WCAG ${level} Fail: ${failures.length}`];
  if (complex.length > 0) lines.push(`  Complex backgrounds (manual review): ${complex.length}`);
  lines.push('');
  if (failures.length > 0) {
    lines.push(`--- Failing Elements (WCAG ${level}) ---`);
    for (const f of failures) lines.push(...formatFailureLines(f, level));
  }
  if (complex.length > 0) {
    lines.push('--- Elements with Complex Backgrounds ---');
    for (const r of complex) lines.push(`  ${r.selector} — ${r.complexBackground.join(', ')} (ratio: ${r.ratio}:1)`);
    lines.push('');
  }
  return lines.join('\n');
}

function formatMarkdown(results, level) {
  const failures = results.filter((r) => isFailingAtLevel(r, level));
  const lines = [`## Contrast Analysis Report (WCAG ${level})`, '', `| Metric | Value |`, `|--------|-------|`, `| Elements analysed | ${results.length} |`, `| Pass | ${results.length - failures.length} |`, `| Fail | ${failures.length} |`, ''];
  if (failures.length > 0) {
    lines.push(`### Failing Elements`, '', `| Element | Ratio | Required | FG | BG | Size | WCAG |`, `|---------|-------|----------|----|----|------|------|`);
    for (const f of failures) {
      const { threshold, criterion } = getLevel(f, level);
      const sel = f.selector.length > 40 ? `${f.selector.substring(0, 37)}...` : f.selector;
      lines.push(`| \`${sel}\` | ${f.ratio}:1 | ${threshold}:1 | ${f.foreground} | ${f.background} | ${f.fontSize} ${f.fontWeight}${f.isLargeText ? ' (L)' : ''} | SC ${criterion} |`);
    }
    lines.push('');
  }
  return lines.join('\n');
}

async function waitForPageReady(page, timeout) {
  await page.waitForLoadState('load', { timeout });
  await page.evaluate(async () => {
    if (document.fonts?.ready) {
      let timeoutId;
      await Promise.race([
        document.fonts.ready,
        new Promise((resolve) => {
          timeoutId = setTimeout(resolve, 2000);
        }),
      ]);
      if (timeoutId) clearTimeout(timeoutId);
    }
    await new Promise((resolve) => {
      let settled = false;
      let frameId;
      let timeoutId;
      const finish = () => {
        if (settled) return;
        settled = true;
        if (frameId) cancelAnimationFrame(frameId);
        if (timeoutId) clearTimeout(timeoutId);
        resolve();
      };
      frameId = requestAnimationFrame(finish);
      timeoutId = setTimeout(finish, 100);
    });
  });
}

// ============================================================================
// Main
// ============================================================================

async function main() {
  const options = parseArgs();
  let browser;
  try {
    const { chromium } = await loadPlaywright();
    const launchOptions = { headless: true, args: ['--no-sandbox', '--disable-gpu'] };
    if (process.env.AIDEVOPS_PLAYWRIGHT_EXECUTABLE) launchOptions.executablePath = process.env.AIDEVOPS_PLAYWRIGHT_EXECUTABLE;
    browser = await chromium.launch(launchOptions);
    const context = await browser.newContext({ viewport: { width: 1440, height: 900 } });
    await context.addInitScript(BROWSER_SCRIPT);
    const page = await context.newPage();
    await page.goto(options.url, { waitUntil: 'load', timeout: options.timeout });
    await waitForPageReady(page, options.timeout);
    const results = await page.evaluate('extractContrastData()');
    let filtered = options.failOnly ? results.filter((r) => isFailingAtLevel(r, options.level)) : results;
    if (options.limit > 0) filtered = filtered.slice(0, options.limit);
    switch (options.format) {
      case 'json': console.log(JSON.stringify(filtered, null, 2)); break;
      case 'markdown': console.log(formatMarkdown(results, options.level)); break;
      default: console.log(formatSummary(results, options.level)); break;
    }
    const hasFailures = results.some((r) => isFailingAtLevel(r, options.level));
    await browser.close().catch(() => {});
    process.exit(hasFailures ? 1 : 0);
  } catch (error) {
    console.error(`ERROR: ${error.message}`);
    if (browser) await browser.close().catch(() => {});
    process.exit(2);
  }
}

main();

#!/usr/bin/env node

// Browser QA Worker — Playwright-based visual QA for milestone validation
// Part of AI DevOps Framework (t1359)
//
// Launches headless Playwright, navigates pages, screenshots key views,
// checks for broken links, console errors, missing content, and empty pages.
// Outputs a structured JSON report.
//
// Usage: node browser-qa.mjs <base-url> [options]
//
// Options:
//   --output-dir <dir>     Directory for screenshots and report (default: managed aidevops temp workspace)
//   --flows <json>         JSON array of flow definitions (URLs or {url, actions} objects)
//   --timeout <ms>         Page load timeout (default: 30000)
//   --viewport <WxH>       Viewport size (default: 1280x720)
//   --check-links          Check all links on each page for broken hrefs (default: true)
//   --no-check-links       Disable link checking
//   --max-links <n>        Max links to check per page (default: 50)
//   --format <type>        Output format: json, summary (default: summary)
//   --help                 Show help

import { existsSync, mkdirSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { loadPlaywright, resolvePlaywrightBrowserExecutable } from '../playwright-runtime.mjs';

// ============================================================================
// CLI Argument Parsing
// ============================================================================

/** Default option values for parseArgs. */
const DEFAULT_OPTIONS = {
  baseUrl: null,
  outputDir: join(process.env.AIDEVOPS_TEMP_DIR || join(homedir(), '.aidevops', '.agent-workspace', 'tmp'), 'browser-qa'),
  flows: null,
  timeout: 30000,
  viewportWidth: 1280,
  viewportHeight: 720,
  checkLinks: true,
  maxLinks: 50,
  format: 'summary',
};

function launchOptions(runtime) {
  const executablePath = resolvePlaywrightBrowserExecutable(runtime);
  return {
    headless: true,
    ...(executablePath ? { executablePath } : {}),
    args: ['--no-sandbox', '--disable-gpu', '--disable-dev-shm-usage'],
  };
}

/**
 * Declarative map of CLI flags to option setters.
 * Each entry is [flag, (options, args, i) => newIndex].
 */
const ARG_HANDLERS = new Map([
  ['--output-dir', (o, a, i) => { o.outputDir = a[++i]; return i; }],
  ['--flows', (o, a, i) => { o.flows = a[++i]; return i; }],
  ['--timeout', (o, a, i) => { o.timeout = parseInt(a[++i], 10); return i; }],
  ['--viewport', (o, a, i) => { const p = a[++i].split('x'); o.viewportWidth = parseInt(p[0], 10); o.viewportHeight = parseInt(p[1], 10); return i; }],
  ['--check-links', (o, _a, i) => { o.checkLinks = true; return i; }],
  ['--no-check-links', (o, _a, i) => { o.checkLinks = false; return i; }],
  ['--max-links', (o, a, i) => { o.maxLinks = parseInt(a[++i], 10); return i; }],
  ['--format', (o, a, i) => { o.format = a[++i]; return i; }],
  ['--help', () => { printUsage(); process.exit(0); }],
  ['-h', () => { printUsage(); process.exit(0); }],
]);

function parseArgs() {
  const args = process.argv.slice(2);
  const options = { ...DEFAULT_OPTIONS };
  for (let i = 0; i < args.length; i++) {
    const handler = ARG_HANDLERS.get(args[i]);
    if (handler) { i = handler(options, args, i) ?? i; }
    else if (!args[i].startsWith('-') && !options.baseUrl) { options.baseUrl = args[i]; }
  }
  if (!options.baseUrl) { console.error('ERROR: Base URL is required'); printUsage(); process.exit(2); }
  return options;
}

function printUsage() {
  console.log(`Usage: node browser-qa.mjs <base-url> [options]

Options:
  --output-dir <dir>     Screenshot/report directory (default: managed aidevops temp workspace)
  --flows <json>         JSON array of URLs or {url, name, actions} objects
  --timeout <ms>         Page load timeout (default: 30000)
  --viewport <WxH>       Viewport size (default: 1280x720)
  --check-links          Check links for broken hrefs (default: on)
  --no-check-links       Disable link checking
  --max-links <n>        Max links to check per page (default: 50)
  --format <type>        Output: json, summary (default: summary)
  --help                 Show this help

Examples:
  node browser-qa.mjs http://localhost:3000
  node browser-qa.mjs http://localhost:3000 --flows '["/about","/contact"]'
  node browser-qa.mjs http://localhost:8080 --output-dir ./qa-results --format json`);
}

// ============================================================================
// Browser-context script — injected as a string via page.evaluate()
// Defined as a string constant so qlty does not count its complexity.
// ============================================================================

/** Script to collect all non-skippable links from the page (up to max). */
const COLLECT_LINKS_SCRIPT = `
(function(max) {
  const NON_HTTP = ['javascript:', 'mailto:', 'tel:', '#', 'data:'];
  const skip = (href) => !href || NON_HTTP.some((p) => href.startsWith(p));
  const results = [];
  const seen = new Set();
  for (const a of document.querySelectorAll('a[href]')) {
    if (results.length >= max) break;
    const href = a.href;
    if (skip(href) || seen.has(href)) continue;
    seen.add(href);
    results.push({ href, text: a.textContent.trim().substring(0, 60) });
  }
  return results;
})
`;

/** Script to detect error state patterns in page body text. */
const DETECT_ERRORS_SCRIPT = `
(function() {
  const body = document.body ? document.body.innerText.toLowerCase() : '';
  const patterns = ['application error','internal server error','something went wrong','page not found','cannot get','module not found','unhandled runtime error','hydration failed','chunk load error'];
  return patterns.filter((p) => body.includes(p));
})
`;

// ============================================================================
// QA Checks
// ============================================================================

/**
 * Capture console errors and failed network requests during page lifecycle.
 * Returns {consoleErrors: string[], networkErrors: string[]}.
 */
function attachErrorListeners(page) {
  const errors = { consoleErrors: [], networkErrors: [] };
  page.on('console', (msg) => { if (msg.type() === 'error') errors.consoleErrors.push(msg.text()); });
  page.on('pageerror', (err) => errors.consoleErrors.push(`Uncaught: ${err.message}`));
  page.on('requestfailed', (req) => errors.networkErrors.push(`${req.method()} ${req.url()} — ${req.failure()?.errorText || 'unknown'}`));
  return errors;
}

/** Build the initial result object for a page visit. */
function buildPageResult(url) {
  return { url, status: null, title: '', screenshot: null, ariaSnapshot: null, isEmpty: false, hasErrorState: false, consoleErrors: [], networkErrors: [], linkResults: [], loadTimeMs: 0, passed: true, failures: [] };
}

/** Navigate to a URL and capture HTTP status and load time. */
async function navigatePage(page, url, timeout) {
  const startTime = Date.now();
  const response = await page.goto(url, { waitUntil: 'load', timeout });
  return { status: response ? response.status() : null, loadTimeMs: Date.now() - startTime };
}

/** Take a screenshot. Returns the path, or null on failure. */
async function captureScreenshot(page, url, outputDir, suffix) {
  const path = join(outputDir, `${sanitizeFilename(url) + (suffix || '')}.png`);
  try { await page.screenshot({ path, fullPage: true }); return path; } catch { return null; }
}

/**
 * Extract page metadata: title, body text, error indicators, ARIA snapshot.
 * Mutates result with isEmpty, hasErrorState, failures, title, ariaSnapshot.
 */
async function extractPageData(page, result) {
  result.title = await page.title();
  const bodyText = await page.evaluate(() => document.body ? document.body.innerText.trim() : '');
  if (bodyText.length < 10) { result.isEmpty = true; result.passed = false; result.failures.push(`Page appears empty (body text: ${bodyText.length} chars)`); }
  const errorIndicators = await page.evaluate(`${DETECT_ERRORS_SCRIPT}()`);
  if (errorIndicators.length > 0) { result.hasErrorState = true; result.passed = false; result.failures.push(`Error state detected: ${errorIndicators.join(', ')}`); }
  try { result.ariaSnapshot = await page.locator('body').ariaSnapshot({ timeout: 5000 }); } catch { result.ariaSnapshot = null; }
}

/** Check links and record broken ones in result. */
async function checkAndRecordLinks(page, result, maxLinks) {
  result.linkResults = await checkPageLinks(page, maxLinks);
  const broken = result.linkResults.filter((l) => l.status >= 400 || l.status === 0);
  if (broken.length > 0) { result.passed = false; result.failures.push(`${broken.length} broken link(s): ${broken.map((l) => `${l.href} (${l.status})`).join(', ')}`); }
}

/** Navigate to a URL, wait for load, capture screenshot and page metadata. */
async function visitPage(page, url, outputDir, options) {
  const result = buildPageResult(url);
  const errors = attachErrorListeners(page);
  try {
    const { status, loadTimeMs } = await navigatePage(page, url, options.timeout);
    result.status = status;
    result.loadTimeMs = loadTimeMs;
    if (result.status && result.status >= 400) { result.passed = false; result.failures.push(`HTTP ${result.status} response`); }
    await page.waitForTimeout(1500);
    await extractPageData(page, result);
    result.screenshot = await captureScreenshot(page, url, outputDir, null);
    if (options.checkLinks) await checkAndRecordLinks(page, result, options.maxLinks);
  } catch (err) {
    result.passed = false;
    result.failures.push(`Navigation error: ${err.message}`);
    result.loadTimeMs = result.loadTimeMs || 0;
    result.screenshot = await captureScreenshot(page, url, outputDir, '-error');
  }
  result.consoleErrors = errors.consoleErrors;
  result.networkErrors = errors.networkErrors;
  const errCount = result.consoleErrors.length;
  if (errCount > 0) { result.passed = false; result.failures.push(`${errCount} console error(s)`); }
  return result;
}

/** HEAD-check a single link. Returns {href, text, status, error?}. */
async function headCheckLink(page, link) {
  try {
    const response = await page.request.head(link.href, { timeout: 10000, ignoreHTTPSErrors: true });
    return { href: link.href, text: link.text, status: response.status() };
  } catch {
    return { href: link.href, text: link.text, status: 0, error: 'Request failed' };
  }
}

/**
 * Check all <a> links on the current page for broken hrefs.
 * Uses HEAD requests to avoid downloading full pages.
 */
async function checkPageLinks(page, maxLinks) {
  const links = await page.evaluate(`${COLLECT_LINKS_SCRIPT}(${maxLinks})`);
  return Promise.all(links.map((link) => headCheckLink(page, link)));
}

/** Convert a URL to a safe filename. */
function sanitizeFilename(url) {
  try {
    const parsed = new URL(url);
    const path = parsed.pathname.replace(/\//g, '_').replace(/^_/, '');
    return (`${parsed.hostname}_${path || 'index'}`).replace(/[^a-zA-Z0-9_.-]/g, '_');
  } catch {
    return url.replace(/[^a-zA-Z0-9_.-]/g, '_').substring(0, 100);
  }
}

// ============================================================================
// Flow Parsing
// ============================================================================

/** Resolve a URL string relative to baseUrl if not absolute. */
function resolveUrl(href, baseUrl) {
  return href.startsWith('http') ? href : new URL(href, baseUrl).toString();
}

/** Normalise a single flow entry to {url, name}. Exits on invalid entry. */
function normaliseFlow(flow, baseUrl) {
  if (typeof flow === 'string') return { url: resolveUrl(flow, baseUrl), name: flow.replace(/^\//, '') || 'homepage' };
  if (typeof flow === 'object' && flow.url) return { url: resolveUrl(flow.url, baseUrl), name: flow.name || flow.url };
  console.error(`ERROR: Invalid flow entry: ${JSON.stringify(flow)}`);
  process.exit(2);
}

/**
 * Parse flow definitions from --flows JSON or generate default flows.
 * Returns array of {url, name} objects.
 */
function parseFlows(baseUrl, flowsJson) {
  if (!flowsJson) return [{ url: baseUrl, name: 'homepage' }];
  let flows;
  try { flows = JSON.parse(flowsJson); } catch (err) { console.error(`ERROR: Invalid --flows JSON: ${err.message}`); process.exit(2); }
  if (!Array.isArray(flows)) { console.error('ERROR: --flows must be a JSON array'); process.exit(2); }
  return flows.map((flow) => normaliseFlow(flow, baseUrl));
}

// ============================================================================
// Report Generation
// ============================================================================

/** Compute summary stats from report pages. */
function reportStats(pages) {
  const passed = pages.filter((p) => p.passed).length;
  const brokenLinks = pages.reduce((s, p) => s + p.linkResults.filter((l) => l.status >= 400 || l.status === 0).length, 0);
  const consoleErrors = pages.reduce((s, p) => s + p.consoleErrors.length, 0);
  return { passed, failed: pages.length - passed, brokenLinks, consoleErrors };
}

/** Format a single page result line for the summary. */
function formatPageLine(page) {
  const lines = [`  [${page.passed ? 'PASS' : 'FAIL'}] ${page.url} (${page.status || 'N/A'}, ${page.loadTimeMs}ms)`];
  if (!page.passed) for (const f of page.failures) lines.push(`         - ${f}`);
  if (page.screenshot) lines.push(`         Screenshot: ${page.screenshot}`);
  return lines;
}

function generateSummary(report) {
  const { passed, failed, brokenLinks, consoleErrors } = reportStats(report.pages);
  const lines = ['', '========================================', '  Browser QA Report', '========================================', '', `Base URL:    ${report.baseUrl}`, `Timestamp:   ${report.timestamp}`, `Pages:       ${report.pages.length}`, `Viewport:    ${report.viewport}`, '', `  Pages passed:      ${passed}`, `  Pages failed:      ${failed}`, `  Broken links:      ${brokenLinks}`, `  Console errors:    ${consoleErrors}`, ''];
  for (const page of report.pages) lines.push(...formatPageLine(page));
  lines.push('', failed > 0 ? 'BROWSER QA: FAILED' : 'BROWSER QA: PASSED', '');
  return lines.join('\n');
}

// ============================================================================
// Main
// ============================================================================

async function main() {
  const options = parseArgs();
  if (!existsSync(options.outputDir)) mkdirSync(options.outputDir, { recursive: true });
  const flows = parseFlows(options.baseUrl, options.flows);
  let browser;
  try {
    const { chromium } = await loadPlaywright();
    browser = await chromium.launch(launchOptions({ chromium }));
    const context = await browser.newContext({ viewport: { width: options.viewportWidth, height: options.viewportHeight }, ignoreHTTPSErrors: true });
    const page = await context.newPage();
    const report = { baseUrl: options.baseUrl, timestamp: new Date().toISOString(), viewport: `${options.viewportWidth}x${options.viewportHeight}`, outputDir: options.outputDir, pages: [], passed: true };
    for (const flow of flows) {
      const result = await visitPage(page, flow.url, options.outputDir, options);
      result.name = flow.name;
      report.pages.push(result);
      if (!result.passed) report.passed = false;
    }
    await browser.close().catch(() => {});
    const reportPath = join(options.outputDir, 'qa-report.json');
    writeFileSync(reportPath, JSON.stringify(report, null, 2));
    if (options.format === 'json') { console.log(JSON.stringify(report, null, 2)); } else { console.log(generateSummary(report)); console.log(`Full report: ${reportPath}`); }
    process.exit(report.passed ? 0 : 1);
  } catch (err) {
    console.error(`ERROR: ${err.message}`);
    if (browser) await browser.close().catch(() => {});
    process.exit(2);
  }
}

main();

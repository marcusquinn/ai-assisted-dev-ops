#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Browser QA Helper — Playwright-based visual testing for milestone validation (t1359)
# Commands: run | screenshot | links | a11y | smoke | help
# Integrates with mission milestone validation pipeline.
# Uses Playwright (fastest) with fallback guidance for Stagehand (self-healing).
#
# This is the orchestrator. Sub-libraries:
#   - browser-qa-helper-core.sh   (viewport, image, JS builders, prereqs, screenshot)
#   - browser-qa-helper-a11y.sh   (accessibility checks)
#   - browser-qa-helper-tests.sh  (stability, smoke, run, formatting)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
# shellcheck source=shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh"
set -euo pipefail
init_log_file

readonly SCREENSHOTS_DIR="${HOME}/.aidevops/.agent-workspace/tmp/browser-qa"
readonly QA_RESULTS_DIR="${HOME}/.aidevops/.agent-workspace/tmp/browser-qa/results"
readonly BROWSER_QA_DEFAULT_TIMEOUT=30000
readonly BROWSER_QA_DEFAULT_VIEWPORTS="desktop,mobile"
readonly BROWSER_QA_DEFAULT_MAX_IMAGE_DIM=4000
readonly BROWSER_QA_ANTHROPIC_MAX_IMAGE_DIM=8000

# =============================================================================
# Source Sub-Libraries
# =============================================================================

# shellcheck source=./browser-qa-helper-core.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/browser-qa-helper-core.sh"

# shellcheck source=./browser-qa-helper-a11y.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/browser-qa-helper-a11y.sh"

# shellcheck source=./browser-qa-helper-tests.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/browser-qa-helper-tests.sh"

# =============================================================================
# Broken Link Detection
# =============================================================================
# Kept in orchestrator: cmd_links is 106 lines (>100-line identity-key
# preservation rule from reference/large-file-split.md section 3).

# Crawl internal links from a starting URL and report broken ones.
# Args: --url URL --depth N --timeout MS
# Output: JSON array of link check results
cmd_links() {
	local url=""
	local depth=2
	local timeout="$BROWSER_QA_DEFAULT_TIMEOUT"

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--url)
			url="$2"
			shift 2
			;;
		--depth)
			depth="$2"
			shift 2
			;;
		--timeout)
			timeout="$2"
			shift 2
			;;
		*)
			log_error "Unknown option: $1"
			return 1
			;;
		esac
	done

	if [[ -z "$url" ]]; then
		log_error "URL is required. Use --url http://localhost:3000"
		return 1
	fi

	# t2997: node ESM requires exact .mjs extension; mktemp -d + fixed filename.
	local script_dir script_file
	script_dir=$(mktemp -d "${TMPDIR:-/tmp}/browser-qa-links-XXXXXX")
	script_file="$script_dir/script.mjs"

	cat >"$script_file" <<'SCRIPT'
const playwrightImport = await import(process.env.AIDEVOPS_PLAYWRIGHT_MODULE);
const { chromium } = playwrightImport.chromium ? playwrightImport : playwrightImport.default;

const baseUrl = process.argv[2].replace(/\/$/, '');
const maxDepth = parseInt(process.argv[3] || '2', 10);
const timeout = parseInt(process.argv[4] || '30000', 10);

async function run() {
  const launchOptions = { headless: true };
  if (process.env.AIDEVOPS_PLAYWRIGHT_EXECUTABLE) launchOptions.executablePath = process.env.AIDEVOPS_PLAYWRIGHT_EXECUTABLE;
  const browser = await chromium.launch(launchOptions);
  const context = await browser.newContext();
  const page = await context.newPage();

  const visited = new Set();
  const results = [];
  const queue = [{ url: baseUrl, depth: 0, source: 'root' }];

  while (queue.length > 0) {
    const { url: currentUrl, depth, source } = queue.shift();

    if (visited.has(currentUrl) || depth > maxDepth) continue;
    visited.add(currentUrl);

    try {
      const response = await page.goto(currentUrl, { waitUntil: 'domcontentloaded', timeout });
      const status = response ? response.status() : 0;
      results.push({ url: currentUrl, status, source, ok: status >= 200 && status < 400 });

      // Only crawl internal links
      if (currentUrl.startsWith(baseUrl) && depth < maxDepth) {
        const links = await page.evaluate(() => {
          return [...document.querySelectorAll('a[href]')]
            .map(a => a.href)
            .filter(href => href.startsWith('http'));
        });

        for (const link of links) {
          if (!visited.has(link) && link.startsWith(baseUrl)) {
            queue.push({ url: link, depth: depth + 1, source: currentUrl });
          }
        }
      }
    } catch (err) {
      results.push({ url: currentUrl, status: 0, source, ok: false, error: err.message });
    }
  }

  await browser.close();

  const broken = results.filter(r => !r.ok);
  console.log(JSON.stringify({
    total: results.length,
    broken: broken.length,
    ok: results.length - broken.length,
    brokenLinks: broken,
    allLinks: results,
  }, null, 2));
}

run().catch(err => {
  console.error('Fatal error:', err.message);
  process.exit(1);
});
SCRIPT

	log_info "Checking links from ${url} (depth: ${depth})"
	local exit_code=0
	run_playwright_node "$script_file" "$url" "$depth" "$timeout" || exit_code=$?
	rm -rf "$script_dir"
	return $exit_code
}

# =============================================================================
# Stability Script Generator
# =============================================================================
# Kept in orchestrator: _generate_stability_script is 178 lines (>100-line
# identity-key preservation rule from reference/large-file-split.md section 3).

# Generate the Playwright stability test script file.
# Args: $1=script_file $2=safe_url $3=pages_array $4=reloads $5=timeout $6=poll_interval $7=poll_max_wait
_generate_stability_script() {
	local script_file="$1"
	local safe_url="$2"
	local pages_array="$3"
	local reloads="$4"
	local timeout="$5"
	local poll_interval="$6"
	local poll_max_wait="$7"

	cat >"$script_file" <<SCRIPT
const playwrightImport = await import(process.env.AIDEVOPS_PLAYWRIGHT_MODULE);
const { chromium } = playwrightImport.chromium ? playwrightImport : playwrightImport.default;

const baseUrl = '${safe_url}'.replace(/\/\$/, '');
const pages = [${pages_array}];
const reloads = ${reloads};
const timeout = ${timeout};
const pollInterval = ${poll_interval};
const pollMaxWait = ${poll_max_wait};

// Wait for network quiescence: no in-flight requests for pollInterval ms.
async function waitForNetworkQuiescence(page) {
  let inFlight = 0;
  let quiesceTimer = null;
  let resolved = false;

  return new Promise((resolve) => {
    const hardTimeout = setTimeout(() => {
      if (!resolved) { resolved = true; resolve(false); }
    }, pollMaxWait);

    page.on('request', () => { inFlight++; clearTimeout(quiesceTimer); });
    page.on('requestfinished', () => {
      inFlight = Math.max(0, inFlight - 1);
      if (inFlight === 0) {
        quiesceTimer = setTimeout(() => {
          if (!resolved) { resolved = true; clearTimeout(hardTimeout); resolve(true); }
        }, pollInterval);
      }
    });
    page.on('requestfailed', () => {
      inFlight = Math.max(0, inFlight - 1);
      if (inFlight === 0) {
        quiesceTimer = setTimeout(() => {
          if (!resolved) { resolved = true; clearTimeout(hardTimeout); resolve(true); }
        }, pollInterval);
      }
    });

    // If already quiescent at start, resolve after one interval.
    quiesceTimer = setTimeout(() => {
      if (inFlight === 0 && !resolved) { resolved = true; clearTimeout(hardTimeout); resolve(true); }
    }, pollInterval);
  });
}

// Capture a DOM fingerprint: element counts and text length.
async function domFingerprint(page) {
  return page.evaluate(() => ({
    elementCount: document.querySelectorAll('*').length,
    bodyLength: document.body ? document.body.innerText.length : 0,
    title: document.title || '',
  }));
}

async function run() {
  const launchOptions = { headless: true };
  if (process.env.AIDEVOPS_PLAYWRIGHT_EXECUTABLE) launchOptions.executablePath = process.env.AIDEVOPS_PLAYWRIGHT_EXECUTABLE;
  const browser = await chromium.launch(launchOptions);
  const allResults = [];

  for (const pagePath of pages) {
    const url = baseUrl + pagePath;
    const reloadResults = [];
    let stable = true;
    let baseFingerprint = null;

    const context = await browser.newContext();
    const page = await context.newPage();

    for (let i = 0; i < reloads; i++) {
      const consoleErrors = [];
      const networkErrors = [];

      page.on('console', msg => {
        if (msg.type() === 'error') {
          consoleErrors.push({ text: msg.text(), location: msg.location() });
        }
      });
      page.on('requestfailed', request => {
        networkErrors.push({
          url: request.url(),
          method: request.method(),
          error: request.failure() ? request.failure().errorText : 'unknown',
        });
      });

      const startMs = Date.now();
      let loadOk = true;
      let loadError = null;
      let status = 0;

      try {
        const response = await page.goto(url, { waitUntil: 'networkidle', timeout });
        status = response ? response.status() : 0;
        await waitForNetworkQuiescence(page);
      } catch (err) {
        loadOk = false;
        loadError = err.message;
      }

      const loadMs = Date.now() - startMs;
      let fingerprint = null;
      if (loadOk) {
        try { fingerprint = await domFingerprint(page); } catch (_) {}
      }

      if (i === 0) {
        baseFingerprint = fingerprint;
      } else if (fingerprint && baseFingerprint) {
        // Quiescence check: title and element count must match baseline.
        if (
          fingerprint.title !== baseFingerprint.title ||
          Math.abs(fingerprint.elementCount - baseFingerprint.elementCount) > 5
        ) {
          stable = false;
        }
      }

      reloadResults.push({
        reload: i + 1,
        status,
        loadMs,
        ok: loadOk && status >= 200 && status < 400,
        loadError,
        consoleErrors,
        networkErrors,
        fingerprint,
      });
    }

    await context.close();

    const totalConsoleErrors = reloadResults.reduce((s, r) => s + r.consoleErrors.length, 0);
    const totalNetworkErrors = reloadResults.reduce((s, r) => s + r.networkErrors.length, 0);
    const allLoadsOk = reloadResults.every(r => r.ok);
    const avgLoadMs = Math.round(
      reloadResults.reduce((s, r) => s + r.loadMs, 0) / reloadResults.length
    );

    allResults.push({
      page: pagePath,
      reloads,
      stable: stable && allLoadsOk && totalConsoleErrors === 0,
      allLoadsOk,
      stable_dom: stable,
      totalConsoleErrors,
      totalNetworkErrors,
      avgLoadMs,
      baseFingerprint,
      reloadResults,
    });
  }

  await browser.close();

  const summary = {
    total: allResults.length,
    stable: allResults.filter(r => r.stable).length,
    unstable: allResults.filter(r => !r.stable).length,
  };

  console.log(JSON.stringify({ summary, pages: allResults }, null, 2));
}

run().catch(err => {
  console.error('Fatal error:', err.message);
  process.exit(1);
});
SCRIPT
	return 0
}

# =============================================================================
# Help
# =============================================================================

cmd_help() {
	cat <<'HELP'
Browser QA Helper — Playwright-based visual testing for milestone validation

Usage: browser-qa-helper.sh <command> [options]

Commands:
  run          Full QA pipeline (smoke + screenshots + links + a11y)
  screenshot   Capture page screenshots at multiple viewports
  links        Check for broken internal links
  a11y         Run accessibility checks (contrast, ARIA, structure)
  smoke        Check for console errors and basic rendering
  stability    Reload pages N times and verify DOM/network quiescence
  help         Show this help message

Common Options:
  --url URL           Base URL to test (required)
  --pages "/ /about"  Space-separated page paths (default: "/")
  --viewports V       Comma-separated viewports: desktop,tablet,mobile (default: desktop,mobile)
  --format FMT        Output format: json or markdown (default: json)
  --timeout MS        Navigation timeout in milliseconds (default: 30000)
  --output-dir DIR    Directory for screenshots and reports
  --max-dim PX        Resize screenshots to this max dimension (default: 4000, Anthropic hard limit: 8000)

Stability-specific Options:
  --reloads N         Number of reloads per page (default: 3, minimum: 1)
  --poll-interval MS  Quiescence poll interval in milliseconds (default: 500)
  --poll-max-wait MS  Maximum wait for network quiescence per reload (default: 10000)

Examples:
  browser-qa-helper.sh run --url http://localhost:3000 --pages "/ /about /dashboard"
  browser-qa-helper.sh screenshot --url http://localhost:3000 --viewports desktop,tablet,mobile --max-dim 4000
  browser-qa-helper.sh links --url http://localhost:3000 --depth 3
  browser-qa-helper.sh a11y --url http://localhost:3000 --level AAA
  browser-qa-helper.sh smoke --url http://localhost:3000 --pages "/ /login"
  browser-qa-helper.sh stability --url http://localhost:3000 --pages "/ /dashboard" --reloads 5
  browser-qa-helper.sh stability --url http://localhost:3000 --format markdown --reloads 3

Prerequisites:
  - Node.js and npm installed
  - Importable Playwright Node package (CLI presence alone is insufficient)
  - Playwright browser binary: npx playwright install chromium

Integration:
  Used by milestone-validation.md (Phase 3: Browser QA) during mission orchestration.
  See tools/browser/browser-qa.md for the full browser QA subagent documentation.
HELP
	return 0
}

# =============================================================================
# Main Dispatch
# =============================================================================

main() {
	local command="${1:-help}"
	shift || true
	if [[ "$command" != "help" && "$command" != "--help" && "$command" != "-h" ]]; then
		check_playwright || return 1
	fi

	case "$command" in
	run) cmd_run "$@" ;;
	screenshot) cmd_screenshot "$@" ;;
	links) cmd_links "$@" ;;
	a11y) cmd_a11y "$@" ;;
	smoke) cmd_smoke "$@" ;;
	stability) cmd_stability "$@" ;;
	help | --help | -h) cmd_help ;;
	*)
		log_error "${ERROR_UNKNOWN_COMMAND}: ${command}"
		cmd_help
		return 1
		;;
	esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	main "$@"
fi

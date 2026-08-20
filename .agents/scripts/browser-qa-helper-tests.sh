#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Browser QA Helper -- Test Commands & Formatting
# =============================================================================
# Stability testing, smoke testing, full QA run orchestration, and markdown
# report formatting.
#
# Usage: source "${SCRIPT_DIR}/browser-qa-helper-tests.sh"
#
# Dependencies:
#   - shared-constants.sh (log_info, log_error)
#   - browser-qa-helper-core.sh (js_escape_string, _build_pages_js_array, cmd_screenshot)
#   - browser-qa-helper-a11y.sh (cmd_a11y)
#   - The orchestrator (browser-qa-helper.sh) provides _generate_stability_script, cmd_links
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_BROWSER_QA_TESTS_LIB_LOADED:-}" ]] && return 0
_BROWSER_QA_TESTS_LIB_LOADED=1

# Defensive SCRIPT_DIR fallback
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# =============================================================================
# Stability Testing Commands
# =============================================================================

# Run stability testing: reload pages N times and detect quiescence.
# Checks for consistent DOM structure, stable titles, no console errors,
# and network quiescence across reloads.
# Args: --url URL --pages "/ /about" --reloads N --timeout MS
#       --poll-interval MS --poll-max-wait MS --format json|markdown
# Output: JSON or markdown stability report
cmd_stability() {
	local url=""
	local pages="/"
	local reloads=3
	local timeout="$BROWSER_QA_DEFAULT_TIMEOUT"
	local poll_interval=500
	local poll_max_wait=10000
	local format="json"

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--url)
			url="$2"
			shift 2
			;;
		--pages)
			pages="$2"
			shift 2
			;;
		--reloads)
			reloads="$2"
			shift 2
			;;
		--timeout)
			timeout="$2"
			shift 2
			;;
		--poll-interval)
			poll_interval="$2"
			shift 2
			;;
		--poll-max-wait)
			poll_max_wait="$2"
			shift 2
			;;
		--format)
			format="$2"
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

	if ! [[ "$reloads" =~ ^[0-9]+$ ]] || [[ "$reloads" -lt 1 ]]; then
		log_error "--reloads must be a positive integer, got: ${reloads}"
		return 1
	fi

	# t2997: node ESM requires exact .mjs extension; mktemp -d + fixed filename.
	local script_dir script_file
	script_dir=$(mktemp -d "${TMPDIR:-/tmp}/browser-qa-stability-XXXXXX")
	script_file="$script_dir/script.mjs"

	local pages_array
	pages_array=$(_build_pages_js_array "$pages")
	local safe_url
	safe_url=$(js_escape_string "$url")

	_generate_stability_script "$script_file" "$safe_url" "$pages_array" \
		"$reloads" "$timeout" "$poll_interval" "$poll_max_wait"

	log_info "Running stability test on ${url} for pages: ${pages} (${reloads} reloads each)"
	local exit_code=0
	local output
	output=$(run_playwright_node "$script_file") || exit_code=$?
	rm -rf "$script_dir"

	if [[ $exit_code -ne 0 ]]; then
		printf '%s\n' "$output"
		return $exit_code
	fi

	if [[ "$format" == "markdown" ]]; then
		_format_stability_markdown "$output"
	else
		printf '%s\n' "$output" | jq '.' 2>/dev/null || printf '%s\n' "$output"
	fi
	return 0
}

# Convert stability JSON report to markdown.
# Args: $1 = JSON string with { summary: {...}, pages: [...] }
_format_stability_markdown() {
	local json="$1"

	echo "## Stability Test Report"
	echo ""
	echo "**Date**: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
	echo ""

	local total stable unstable
	total=$(printf '%s' "$json" | jq -r '.summary.total // 0' 2>/dev/null)
	stable=$(printf '%s' "$json" | jq -r '.summary.stable // 0' 2>/dev/null)
	unstable=$(printf '%s' "$json" | jq -r '.summary.unstable // 0' 2>/dev/null)

	echo "### Summary"
	echo ""
	echo "| Metric | Count |"
	echo "|--------|-------|"
	echo "| Pages tested | ${total} |"
	echo "| Stable | ${stable} |"
	echo "| Unstable | ${unstable} |"
	echo ""

	local unstable_count
	unstable_count=$(printf '%s' "$json" | jq '[.pages[] | select(.stable == false)] | length' 2>/dev/null)
	if [[ "${unstable_count:-0}" -gt 0 ]]; then
		echo "### Unstable Pages"
		echo ""
		printf '%s' "$json" | jq -r '
			.pages[] | select(.stable == false) |
			"- **\(.page)**: dom_stable=\(.stable_dom), loads_ok=\(.allLoadsOk), console_errors=\(.totalConsoleErrors), network_errors=\(.totalNetworkErrors), avg_load_ms=\(.avgLoadMs)"
		' 2>/dev/null
		echo ""
	fi

	return 0
}

# =============================================================================
# Smoke Test (Console Errors + Basic Rendering)
# =============================================================================

# Generate the Playwright smoke test script file.
# Args: $1=script_file $2=safe_url $3=pages_array $4=timeout
_generate_smoke_script() {
	local script_file="$1"
	local safe_url="$2"
	local pages_array="$3"
	local timeout="$4"

	cat >"$script_file" <<SCRIPT
const playwrightImport = await import(process.env.AIDEVOPS_PLAYWRIGHT_MODULE);
const { chromium } = playwrightImport.chromium ? playwrightImport : playwrightImport.default;

const baseUrl = '${safe_url}'.replace(/\/\$/, '');
const pages = [${pages_array}];
const timeout = ${timeout};

async function run() {
  const launchOptions = { headless: true };
  if (process.env.AIDEVOPS_PLAYWRIGHT_EXECUTABLE) launchOptions.executablePath = process.env.AIDEVOPS_PLAYWRIGHT_EXECUTABLE;
  const browser = await chromium.launch(launchOptions);
  const context = await browser.newContext();
  const results = [];

  for (const pagePath of pages) {
    const page = await context.newPage();
    const consoleErrors = [];
    const networkErrors = [];

    // Capture console errors
    page.on('console', msg => {
      if (msg.type() === 'error') {
        consoleErrors.push({ text: msg.text(), location: msg.location() });
      }
    });

    // Capture failed network requests
    page.on('requestfailed', request => {
      networkErrors.push({
        url: request.url(),
        method: request.method(),
        error: request.failure()?.errorText || 'unknown',
      });
    });

    const url = baseUrl + pagePath;
    try {
      const response = await page.goto(url, { waitUntil: 'networkidle', timeout });
      const status = response ? response.status() : 0;

      // Check basic rendering
      const bodyText = await page.evaluate(() => document.body?.innerText?.length || 0);
      const title = await page.title();
      const hasContent = bodyText > 0;

      // Get ARIA snapshot for AI understanding
      const ariaSnapshot = await page.locator('body').ariaSnapshot().catch(() => '');

      results.push({
        page: pagePath,
        status,
        title,
        hasContent,
        bodyLength: bodyText,
        consoleErrors,
        networkErrors,
        ariaSnapshotLength: ariaSnapshot.length,
        ok: status >= 200 && status < 400 && consoleErrors.length === 0 && hasContent,
      });
    } catch (err) {
      results.push({
        page: pagePath,
        status: 0,
        error: err.message,
        consoleErrors,
        networkErrors,
        ok: false,
      });
    }

    await page.close();
  }

  await browser.close();

  const summary = {
    total: results.length,
    passed: results.filter(r => r.ok).length,
    failed: results.filter(r => !r.ok).length,
    consoleErrors: results.reduce((sum, r) => sum + (r.consoleErrors?.length || 0), 0),
    networkErrors: results.reduce((sum, r) => sum + (r.networkErrors?.length || 0), 0),
  };

  console.log(JSON.stringify({ summary, pages: results }, null, 2));
}

run().catch(err => {
  console.error('Fatal error:', err.message);
  process.exit(1);
});
SCRIPT
	return 0
}

# Navigate to pages and check for console errors, failed network requests, and basic rendering.
# Args: --url URL --pages "/ /about" --format json|markdown
# Output: JSON or markdown report of console errors and rendering issues
cmd_smoke() {
	local url=""
	local pages="/"
	local format="json"
	local timeout="$BROWSER_QA_DEFAULT_TIMEOUT"

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--url)
			url="$2"
			shift 2
			;;
		--pages)
			pages="$2"
			shift 2
			;;
		--format)
			format="$2"
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
	script_dir=$(mktemp -d "${TMPDIR:-/tmp}/browser-qa-smoke-XXXXXX")
	script_file="$script_dir/script.mjs"

	local pages_array
	pages_array=$(_build_pages_js_array "$pages")
	local safe_url
	safe_url=$(js_escape_string "$url")

	_generate_smoke_script "$script_file" "$safe_url" "$pages_array" "$timeout"

	log_info "Running smoke test on ${url} for pages: ${pages}"
	local exit_code=0
	local output
	output=$(run_playwright_node "$script_file") || exit_code=$?
	rm -rf "$script_dir"

	if [[ $exit_code -ne 0 ]]; then
		printf '%s\n' "$output"
		return $exit_code
	fi

	if [[ "$format" == "markdown" ]]; then
		_format_smoke_markdown "$output"
	else
		printf '%s\n' "$output"
	fi
	return 0
}

# =============================================================================
# Full QA Run
# =============================================================================

# Execute the four QA phases and combine results into a JSON report string.
# Args: $1=url $2=pages $3=viewports $4=output_dir $5=timestamp $6=timeout $7=max_dim
# Output: combined JSON report (stdout)
_run_qa_phases() {
	local url="$1"
	local pages="$2"
	local viewports="$3"
	local output_dir="$4"
	local timestamp="$5"
	local timeout="$6"
	local max_dim="$7"

	log_info "=== Browser QA Full Run ==="
	log_info "URL: ${url}"
	log_info "Pages: ${pages}"
	log_info "Viewports: ${viewports}"

	# Phase 1: Smoke test
	log_info "--- Phase 1: Smoke Test ---"
	local smoke_result
	smoke_result=$(cmd_smoke --url "$url" --pages "$pages" --timeout "$timeout" 2>/dev/null) || smoke_result='{"error": "smoke test failed"}'

	# Phase 2: Screenshots
	log_info "--- Phase 2: Screenshots ---"
	local screenshot_dir="${output_dir}/screenshots-${timestamp}"
	local screenshot_result
	screenshot_result=$(cmd_screenshot --url "$url" --pages "$pages" --viewports "$viewports" --output-dir "$screenshot_dir" --timeout "$timeout" --max-dim "$max_dim" 2>/dev/null) || screenshot_result='{"error": "screenshot capture failed"}'

	# Phase 3: Broken links
	log_info "--- Phase 3: Broken Link Check ---"
	local links_result
	links_result=$(cmd_links --url "$url" --timeout "$timeout" 2>/dev/null) || links_result='{"error": "link check failed"}'

	# Phase 4: Accessibility
	log_info "--- Phase 4: Accessibility ---"
	local a11y_result
	a11y_result=$(cmd_a11y --url "$url" --pages "$pages" 2>/dev/null) || a11y_result='{"error": "accessibility check failed"}'

	cat <<REPORT
{
  "timestamp": "${timestamp}",
  "url": "${url}",
  "pages": "$(echo "$pages" | tr ' ' ',')",
  "viewports": "${viewports}",
  "smoke": ${smoke_result},
  "screenshots": ${screenshot_result},
  "links": ${links_result},
  "accessibility": ${a11y_result}
}
REPORT
	return 0
}

# Run the complete QA pipeline: smoke test, screenshots, broken links, accessibility.
# Args: --url URL --pages "/ /about" --viewports "desktop,mobile" --format json|markdown
# Output: Combined JSON report
cmd_run() {
	local url=""
	local pages="/"
	local viewports="$BROWSER_QA_DEFAULT_VIEWPORTS"
	local format="json"
	local output_dir="$QA_RESULTS_DIR"
	local timeout="$BROWSER_QA_DEFAULT_TIMEOUT"
	local max_dim=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--url)
			url="$2"
			shift 2
			;;
		--pages)
			pages="$2"
			shift 2
			;;
		--viewports)
			viewports="$2"
			shift 2
			;;
		--format)
			format="$2"
			shift 2
			;;
		--output-dir)
			output_dir="$2"
			shift 2
			;;
		--timeout)
			timeout="$2"
			shift 2
			;;
		--max-dim)
			max_dim="$2"
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

	mkdir -p "$output_dir"
	local timestamp
	timestamp=$(date -u +"%Y%m%dT%H%M%SZ")
	local report_file="${output_dir}/qa-report-${timestamp}.json"

	local combined
	combined=$(_run_qa_phases "$url" "$pages" "$viewports" "$output_dir" "$timestamp" "$timeout" "$max_dim")

	if [[ "$format" == "markdown" ]]; then
		format_as_markdown "$combined"
	else
		echo "$combined" | jq '.' 2>/dev/null || echo "$combined"
	fi

	# Save report
	echo "$combined" >"$report_file"
	log_info "Report saved to ${report_file}"
	return 0
}

# =============================================================================
# Markdown Formatters
# =============================================================================

# Convert standalone smoke test JSON to markdown.
# Args: $1 = JSON string with { summary: {...}, pages: [...] }
_format_smoke_markdown() {
	local json="$1"

	echo "## Smoke Test Report"
	echo ""
	echo "**Date**: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
	echo ""

	local total
	total=$(printf '%s' "$json" | jq -r '.summary.total // 0' 2>/dev/null)
	local passed
	passed=$(printf '%s' "$json" | jq -r '.summary.passed // 0' 2>/dev/null)
	local failed
	failed=$(printf '%s' "$json" | jq -r '.summary.failed // 0' 2>/dev/null)
	local console_errs
	console_errs=$(printf '%s' "$json" | jq -r '.summary.consoleErrors // 0' 2>/dev/null)
	local network_errs
	network_errs=$(printf '%s' "$json" | jq -r '.summary.networkErrors // 0' 2>/dev/null)

	echo "### Summary"
	echo ""
	echo "| Metric | Count |"
	echo "|--------|-------|"
	echo "| Pages checked | ${total} |"
	echo "| Passed | ${passed} |"
	echo "| Failed | ${failed} |"
	echo "| Console errors | ${console_errs} |"
	echo "| Network errors | ${network_errs} |"
	echo ""

	# Per-page details for failures
	local fail_count
	fail_count=$(printf '%s' "$json" | jq '[.pages[] | select(.ok == false)] | length' 2>/dev/null)
	if [[ "${fail_count:-0}" -gt 0 ]]; then
		echo "### Failed Pages"
		echo ""
		printf '%s' "$json" | jq -r '.pages[] | select(.ok == false) | "- **\(.page)**: status \(.status // "N/A")\(.error // "" | if . != "" then " — " + . else "" end)"' 2>/dev/null
		echo ""
	fi

	return 0
}

# Convert JSON QA report to markdown format.
# Args: $1 = JSON report string
format_as_markdown() {
	local json="$1"

	echo "## Browser QA Report"
	echo ""
	echo "**Date**: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
	echo "**URL**: $(echo "$json" | jq -r '.url // "unknown"' 2>/dev/null)"
	echo ""

	# Smoke test summary
	echo "### Smoke Test"
	echo ""
	local smoke_passed
	smoke_passed=$(echo "$json" | jq -r '.smoke.summary.passed // 0' 2>/dev/null)
	local smoke_total
	smoke_total=$(echo "$json" | jq -r '.smoke.summary.total // 0' 2>/dev/null)
	local console_errors
	console_errors=$(echo "$json" | jq -r '.smoke.summary.consoleErrors // 0' 2>/dev/null)
	echo "- Pages checked: ${smoke_total}"
	echo "- Passed: ${smoke_passed}"
	echo "- Console errors: ${console_errors}"
	echo ""

	# Links summary
	echo "### Broken Links"
	echo ""
	local links_total
	links_total=$(echo "$json" | jq -r '.links.total // 0' 2>/dev/null)
	local links_broken
	links_broken=$(echo "$json" | jq -r '.links.broken // 0' 2>/dev/null)
	echo "- Total links: ${links_total}"
	echo "- Broken: ${links_broken}"
	echo ""

	# Accessibility summary
	echo "### Accessibility"
	echo ""
	echo "$json" | jq -r '.accessibility[]? | "- \(.page): \(.summary.errors // 0) errors, \(.summary.warnings // 0) warnings"' 2>/dev/null || echo "- No data"
	echo ""

	return 0
}

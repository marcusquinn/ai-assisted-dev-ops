#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Browser QA Helper -- Accessibility Checks
# =============================================================================
# Contrast checks, ARIA validation, heading hierarchy, and document-level
# accessibility audits using Playwright.
#
# Usage: source "${SCRIPT_DIR}/browser-qa-helper-a11y.sh"
#
# Dependencies:
#   - shared-constants.sh (log_info, log_warn, log_error)
#   - browser-qa-helper-core.sh (js_escape_string, _build_pages_js_array)
#   - accessibility/playwright-contrast.mjs (optional, for contrast checks)
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_BROWSER_QA_A11Y_LIB_LOADED:-}" ]] && return 0
_BROWSER_QA_A11Y_LIB_LOADED=1

# Defensive SCRIPT_DIR fallback
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# =============================================================================
# Accessibility Checks
# =============================================================================

# Run contrast checks for each page using playwright-contrast.mjs.
# Args: $1=url $2=pages $3=level
# Output: JSON array of contrast results (stdout)
_run_contrast_checks() {
	local url="$1"
	local pages="$2"
	local level="$3"
	local contrast_script="${SCRIPT_DIR}/accessibility/playwright-contrast.mjs"
	local contrast_json='[]'

	for page_path in $pages; do
		local full_url="${url%/}${page_path}"
		log_info "Running accessibility check on ${full_url} (level: ${level})"

		if [[ -f "$contrast_script" ]]; then
			local contrast_result
			contrast_result=$(run_playwright_node "$contrast_script" "$full_url" --format json --level "$level" 2>/dev/null) || contrast_result='{"error": "contrast check failed"}'
			contrast_json=$(jq -c \
				--arg page "$page_path" \
				--argjson contrast "$contrast_result" \
				'. + [{page: $page, contrast: $contrast}]' <<<"$contrast_json")
		else
			log_warn "Contrast script not found at ${contrast_script}"
			contrast_json=$(jq -c \
				--arg page "$page_path" \
				'. + [{page: $page, contrast: {error: "script not found"}}]' <<<"$contrast_json")
		fi
	done

	printf '%s' "$contrast_json"
	return 0
}

# Write the JS snippet that checks images, inputs, and headings for a11y issues.
# Output: JS code fragment (no surrounding function wrapper).
_a11y_js_element_checks() {
	cat <<'JSEOF'
        const issues = [];

        // Check images without alt text
        const images = document.querySelectorAll('img');
        images.forEach(img => {
          if (!img.alt && !img.getAttribute('role') && !img.getAttribute('aria-label')) {
            issues.push({
              type: 'missing-alt', severity: 'error',
              element: img.outerHTML.substring(0, 200),
              message: 'Image missing alt text',
            });
          }
        });

        // Check form inputs without labels
        const inputs = document.querySelectorAll('input, select, textarea');
        inputs.forEach(input => {
          const id = input.id;
          const hasLabel = id && document.querySelector(`label[for="${id}"]`);
          const hasAriaLabel = input.getAttribute('aria-label') || input.getAttribute('aria-labelledby');
          const hasTitle = input.getAttribute('title');
          const hasPlaceholder = input.getAttribute('placeholder');
          if (!hasLabel && !hasAriaLabel && !hasTitle && input.type !== 'hidden' && input.type !== 'submit') {
            issues.push({
              type: 'missing-label', severity: 'warning',
              element: input.outerHTML.substring(0, 200),
              message: `Input ${input.type || 'text'} missing associated label${hasPlaceholder ? ' (has placeholder but not a label)' : ''}`,
            });
          }
        });

        // Check heading hierarchy
        const headings = [...document.querySelectorAll('h1, h2, h3, h4, h5, h6')];
        let lastLevel = 0;
        headings.forEach(h => {
          const level = parseInt(h.tagName[1], 10);
          if (level > lastLevel + 1 && lastLevel > 0) {
            issues.push({
              type: 'heading-skip', severity: 'warning',
              element: h.outerHTML.substring(0, 200),
              message: `Heading level skipped: h${lastLevel} to h${level}`,
            });
          }
          lastLevel = level;
        });
JSEOF
	return 0
}

# Write the JS snippet that checks document-level and interactive-element a11y issues.
# Output: JS code fragment (no surrounding function wrapper). Assumes `issues` array exists.
_a11y_js_document_checks() {
	cat <<'JSEOF'
        // Check for missing lang attribute
        const html = document.documentElement;
        if (!html.getAttribute('lang')) {
          issues.push({ type: 'missing-lang', severity: 'error', message: 'HTML element missing lang attribute' });
        }

        // Check for missing page title
        if (!document.title || document.title.trim() === '') {
          issues.push({ type: 'missing-title', severity: 'error', message: 'Page missing title element' });
        }

        // Check buttons without accessible names
        const buttons = document.querySelectorAll('button');
        buttons.forEach(btn => {
          const text = btn.textContent?.trim();
          const ariaLabel = btn.getAttribute('aria-label');
          const ariaLabelledBy = btn.getAttribute('aria-labelledby');
          if (!text && !ariaLabel && !ariaLabelledBy) {
            issues.push({
              type: 'empty-button', severity: 'error',
              element: btn.outerHTML.substring(0, 200),
              message: 'Button has no accessible name',
            });
          }
        });

        // Check links without accessible names
        const links = document.querySelectorAll('a');
        links.forEach(link => {
          const text = link.textContent?.trim();
          const ariaLabel = link.getAttribute('aria-label');
          if (!text && !ariaLabel && !link.querySelector('img[alt]')) {
            issues.push({
              type: 'empty-link', severity: 'warning',
              element: link.outerHTML.substring(0, 200),
              message: 'Link has no accessible name',
            });
          }
        });

        return {
          issues,
          summary: {
            errors: issues.filter(i => i.severity === 'error').length,
            warnings: issues.filter(i => i.severity === 'warning').length,
            total: issues.length,
          },
        };
JSEOF
	return 0
}

# Generate the Playwright a11y ARIA/structure check script file.
# Args: $1=script_file $2=safe_url $3=pages_array
_generate_a11y_script() {
	local script_file="$1"
	local safe_url="$2"
	local pages_array="$3"
	local element_checks document_checks
	element_checks=$(_a11y_js_element_checks)
	document_checks=$(_a11y_js_document_checks)
	local evaluate_body="${element_checks}
${document_checks}"

	cat >"$script_file" <<SCRIPT
const playwrightImport = await import(process.env.AIDEVOPS_PLAYWRIGHT_MODULE);
const { chromium } = playwrightImport.chromium ? playwrightImport : playwrightImport.default;

const baseUrl = '${safe_url}'.replace(/\/\$/, '');
const pages = [${pages_array}];

async function run() {
  const launchOptions = { headless: true };
  if (process.env.AIDEVOPS_PLAYWRIGHT_EXECUTABLE) launchOptions.executablePath = process.env.AIDEVOPS_PLAYWRIGHT_EXECUTABLE;
  const browser = await chromium.launch(launchOptions);
  const context = await browser.newContext();
  const page = await context.newPage();
  const a11yResults = [];
  const contrastData = JSON.parse(process.argv[2] || '[]');

  for (const pagePath of pages) {
    const url = baseUrl + pagePath;
    try {
      await page.goto(url, { waitUntil: 'networkidle', timeout: 30000 });

      const a11yData = await page.evaluate(() => {
${evaluate_body}
      });

      // Merge contrast data for this page if available
      const contrast = contrastData.find(c => c.page === pagePath);
      a11yResults.push({ page: pagePath, ...a11yData, contrast: contrast ? contrast.contrast : null });
    } catch (err) {
      const contrast = contrastData.find(c => c.page === pagePath);
      a11yResults.push({ page: pagePath, error: err.message, contrast: contrast ? contrast.contrast : null });
    }
  }

  await browser.close();
  console.log(JSON.stringify(a11yResults, null, 2));
}

run().catch(err => {
  console.error('Fatal error:', err.message);
  process.exit(1);
});
SCRIPT
	return 0
}

# Run accessibility checks on pages using Playwright.
# Delegates to playwright-contrast.mjs for contrast, adds ARIA and structure checks.
# Args: --url URL --pages "/ /about" --level AA|AAA
# Output: JSON accessibility report
cmd_a11y() {
	local url=""
	local pages="/"
	local level="AA"

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
		--level)
			level="$2"
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

	local contrast_json
	contrast_json=$(_run_contrast_checks "$url" "$pages" "$level")

	# t2997: node ESM requires exact .mjs extension; mktemp -d + fixed filename.
	local script_dir script_file
	script_dir=$(mktemp -d "${TMPDIR:-/tmp}/browser-qa-a11y-XXXXXX")
	script_file="$script_dir/script.mjs"

	local pages_array
	pages_array=$(_build_pages_js_array "$pages")
	local safe_url
	safe_url=$(js_escape_string "$url")

	_generate_a11y_script "$script_file" "$safe_url" "$pages_array"

	local exit_code=0
	run_playwright_node "$script_file" "$contrast_json" || exit_code=$?
	rm -rf "$script_dir"
	return $exit_code
}

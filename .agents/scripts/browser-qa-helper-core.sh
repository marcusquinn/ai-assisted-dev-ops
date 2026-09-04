#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Browser QA Helper -- Core Utilities
# =============================================================================
# Viewport definitions, image dimension handling, JS array builders,
# prerequisite checks, and screenshot capture.
#
# Usage: source "${SCRIPT_DIR}/browser-qa-helper-core.sh"
#
# Dependencies:
#   - shared-constants.sh (log_info, log_warn, log_error)
#   - sips or magick for image operations
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_BROWSER_QA_CORE_LIB_LOADED:-}" ]] && return 0
_BROWSER_QA_CORE_LIB_LOADED=1

# Defensive SCRIPT_DIR fallback
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# =============================================================================
# Viewport Definitions
# =============================================================================

# Returns viewport dimensions for a named viewport.
# Args: $1 = viewport name (desktop|tablet|mobile)
# Output: "widthxheight"
get_viewport_dimensions() {
	local viewport="$1"
	case "$viewport" in
	desktop) echo "1440x900" ;;
	tablet) echo "768x1024" ;;
	mobile) echo "375x667" ;;
	*) echo "1440x900" ;;
	esac
	return 0
}

# Escape a string for safe embedding in a JavaScript string literal (single-quoted).
# Handles backslashes, single quotes, backticks, newlines, and dollar signs.
# Args: $1 = raw string
# Output: escaped string (without surrounding quotes)
js_escape_string() {
	local raw="$1"
	raw="${raw//\\/\\\\}"
	raw="${raw//\'/\\\'}"
	raw="${raw//\`/\\\`}"
	raw="${raw//\$/\\\$}"
	raw="${raw//$'\n'/\\n}"
	printf '%s' "$raw"
	return 0
}

# Resolve max image dimension guardrail from optional user input.
# Args: $1 = requested max dimension (optional)
# Output: validated max dimension integer
resolve_max_image_dim() {
	local requested="${1:-}"
	local resolved="$BROWSER_QA_DEFAULT_MAX_IMAGE_DIM"

	if [[ -n "$requested" ]]; then
		if [[ "$requested" =~ ^[0-9]+$ ]] && [[ "$requested" -gt 0 ]]; then
			resolved="$requested"
		else
			log_warn "Invalid --max-dim '${requested}', using default ${BROWSER_QA_DEFAULT_MAX_IMAGE_DIM}"
		fi
	fi

	if [[ "$resolved" -gt "$BROWSER_QA_ANTHROPIC_MAX_IMAGE_DIM" ]]; then
		log_warn "--max-dim ${resolved} exceeds Anthropic limit ${BROWSER_QA_ANTHROPIC_MAX_IMAGE_DIM}; clamping to ${BROWSER_QA_ANTHROPIC_MAX_IMAGE_DIM}"
		resolved="$BROWSER_QA_ANTHROPIC_MAX_IMAGE_DIM"
	fi

	echo "$resolved"
	return 0
}

# Get image dimensions as "widthxheight".
# Args: $1 = image path
# Output: widthxheight
get_image_dimensions() {
	local image_path="$1"
	local width=""
	local height=""

	if command -v sips &>/dev/null; then
		local sips_output
		sips_output=$(sips -g pixelWidth -g pixelHeight "$image_path" 2>/dev/null) || return 1
		while IFS= read -r line; do
			case "$line" in
			*pixelWidth:*) width="${line##*: }" ;;
			*pixelHeight:*) height="${line##*: }" ;;
			esac
		done <<<"$sips_output"
	elif command -v magick &>/dev/null; then
		local identify_output
		identify_output=$(magick identify -format '%w %h' "$image_path" 2>/dev/null) || return 1
		width="${identify_output%% *}"
		height="${identify_output##* }"
	else
		return 1
	fi

	if [[ -z "$width" || -z "$height" || ! "$width" =~ ^[0-9]+$ || ! "$height" =~ ^[0-9]+$ ]]; then
		return 1
	fi

	echo "${width}x${height}"
	return 0
}

# Resize an image down to a max dimension.
# Args: $1 = image path, $2 = max dimension
resize_image_to_max_dim() {
	local image_path="$1"
	local max_dim="$2"

	if command -v sips &>/dev/null; then
		sips --resampleHeightWidthMax "$max_dim" "$image_path" --out "$image_path" >/dev/null
		return 0
	fi

	if command -v magick &>/dev/null; then
		magick "$image_path" -resize "${max_dim}x${max_dim}>" "$image_path"
		return 0
	fi

	return 1
}

# Enforce screenshot size guardrails for Anthropic vision compatibility.
# Args: $1 = output directory, $2 = target max dimension
enforce_screenshot_size_guardrails() {
	local output_dir="$1"
	local max_dim="$2"
	local checked_count=0
	local resized_count=0
	local hard_limit_violations=0

	if ! command -v sips &>/dev/null && ! command -v magick &>/dev/null; then
		log_error "No supported image tool found for guardrails (need sips or magick)"
		return 1
	fi

	local image_found=0
	for image_path in "$output_dir"/*.png; do
		if [[ ! -f "$image_path" ]]; then
			continue
		fi
		image_found=1
		checked_count=$((checked_count + 1))

		local dimensions
		dimensions=$(get_image_dimensions "$image_path") || {
			log_error "Failed to read image dimensions: ${image_path}"
			return 1
		}

		local width="${dimensions%%x*}"
		local height="${dimensions##*x}"

		if [[ "$width" -gt "$max_dim" || "$height" -gt "$max_dim" ]]; then
			if ! resize_image_to_max_dim "$image_path" "$max_dim"; then
				log_error "Failed to resize screenshot: ${image_path}"
				return 1
			fi
			resized_count=$((resized_count + 1))
			local resized_dimensions
			resized_dimensions=$(get_image_dimensions "$image_path") || {
				log_error "Failed to read resized image dimensions: ${image_path}"
				return 1
			}
			width="${resized_dimensions%%x*}"
			height="${resized_dimensions##*x}"
		fi

		if [[ "$width" -gt "$BROWSER_QA_ANTHROPIC_MAX_IMAGE_DIM" || "$height" -gt "$BROWSER_QA_ANTHROPIC_MAX_IMAGE_DIM" ]]; then
			hard_limit_violations=$((hard_limit_violations + 1))
			log_error "Image exceeds Anthropic hard limit (${BROWSER_QA_ANTHROPIC_MAX_IMAGE_DIM}px): ${image_path} (${width}x${height})"
		fi
	done

	if [[ "$image_found" -eq 0 ]]; then
		log_warn "No PNG screenshots found in ${output_dir} to guardrail-check"
		return 0
	fi

	log_info "Screenshot guardrails checked ${checked_count} image(s), resized ${resized_count}, max dimension ${max_dim}px"

	if [[ "$hard_limit_violations" -gt 0 ]]; then
		return 1
	fi

	return 0
}

# =============================================================================
# Shared JS Array Builders
# =============================================================================

# Build a JS array literal of viewport objects from a comma-separated viewport string.
# Args: $1 = comma-separated viewport names (e.g. "desktop,mobile")
# Output: JS array fragment like "{ name: 'desktop', width: 1440, height: 900 },"
_build_viewports_js_array() {
	local viewports="$1"
	local result=""
	IFS=',' read -ra vp_list <<<"$viewports"
	for vp in "${vp_list[@]}"; do
		local dims
		dims=$(get_viewport_dimensions "$vp")
		local width="${dims%%x*}"
		local height="${dims##*x}"
		local safe_vp
		safe_vp=$(js_escape_string "$vp")
		result="${result}{ name: '${safe_vp}', width: ${width}, height: ${height} },"
	done
	printf '%s' "$result"
	return 0
}

# Build a JS array literal of page path strings from a space-separated page list.
# Args: $1 = space-separated page paths (e.g. "/ /about /dashboard")
# Output: JS array fragment like "'/','/about','/dashboard',"
_build_pages_js_array() {
	local pages="$1"
	local result=""
	for page in $pages; do
		local safe_page
		safe_page=$(js_escape_string "$page")
		result="${result}'${safe_page}',"
	done
	printf '%s' "$result"
	return 0
}

# =============================================================================
# Prerequisite Checks
# =============================================================================

# Resolve the exact Playwright package and browser runtime used by generated scripts.
check_playwright() {
	if ! command -v node &>/dev/null; then
		log_error "Node.js not found. Install Node.js first."
		return 1
	fi

	local runtime_script="${SCRIPT_DIR}/playwright-runtime.mjs"
	if [[ ! -f "$runtime_script" ]]; then
		log_error "Playwright runtime resolver not found: ${runtime_script}"
		return 1
	fi

	local resolved_module resolved_executable
	if ! resolved_module=$(node "$runtime_script" check); then
		log_error "Browser QA requires both an importable Playwright Node package and an installed browser binary."
		return 1
	fi
	if ! resolved_executable=$(node "$runtime_script" browser-executable); then
		log_error "Browser QA could not resolve the verified standalone browser executable."
		return 1
	fi
	export AIDEVOPS_PLAYWRIGHT_MODULE="$resolved_module"
	export AIDEVOPS_PLAYWRIGHT_EXECUTABLE="$resolved_executable"
	return 0
}

# Run a Node script with the exact Playwright module verified by check_playwright.
# Args: $1 = script path, remaining args are passed to the script.
run_playwright_node() {
	local script_file="$1"
	shift
	if [[ -z "${AIDEVOPS_PLAYWRIGHT_MODULE:-}" ]]; then
		check_playwright || return 1
	fi
	AIDEVOPS_PLAYWRIGHT_MODULE="$AIDEVOPS_PLAYWRIGHT_MODULE" node "$script_file" "$@"
	return $?
}

# Wait for a URL to become reachable.
# Args: $1 = URL, $2 = max wait seconds (default 30)
wait_for_url() {
	local url="$1"
	local max_wait="${2:-30}"
	local i=0

	log_info "Waiting for ${url} to become reachable (max ${max_wait}s)..."
	while [[ $i -lt $max_wait ]]; do
		if curl -s -o /dev/null -w "%{http_code}" "$url" 2>/dev/null | grep -qE '^[23]'; then
			log_info "Server ready at ${url}"
			return 0
		fi
		sleep 1
		i=$((i + 1))
	done
	log_error "Server at ${url} not reachable after ${max_wait}s"
	return 1
}

# =============================================================================
# Screenshot Capture
# =============================================================================

# Generate the Playwright screenshot script file.
# Args: $1=script_file $2=safe_url $3=viewport_array $4=pages_array $5=safe_output_dir $6=timeout $7=full_page
_generate_screenshot_script() {
	local script_file="$1"
	local safe_url="$2"
	local viewport_array="$3"
	local pages_array="$4"
	local safe_output_dir="$5"
	local timeout="$6"
	local full_page="$7"

	cat >"$script_file" <<SCRIPT
const playwrightImport = await import(process.env.AIDEVOPS_PLAYWRIGHT_MODULE);
const { chromium } = playwrightImport.chromium ? playwrightImport : playwrightImport.default;

const baseUrl = '${safe_url}'.replace(/\/\$/, '');
const viewports = [${viewport_array}];
const pages = [${pages_array}];
const outputDir = '${safe_output_dir}';
const timeout = ${timeout};
const fullPage = ${full_page};

async function run() {
  const launchOptions = { headless: true };
  if (process.env.AIDEVOPS_PLAYWRIGHT_EXECUTABLE) launchOptions.executablePath = process.env.AIDEVOPS_PLAYWRIGHT_EXECUTABLE;
  const browser = await chromium.launch(launchOptions);
  const results = [];

  for (const vp of viewports) {
    const context = await browser.newContext({
      viewport: { width: vp.width, height: vp.height },
    });
    const page = await context.newPage();

    for (const pagePath of pages) {
      const url = baseUrl + pagePath;
      const safeName = pagePath.replace(/\\//g, '_').replace(/^_/, '') || 'index';
      const filename = \`\${safeName}-\${vp.name}-\${vp.width}x\${vp.height}.png\`;
      const filepath = \`\${outputDir}/\${filename}\`;

      try {
        await page.goto(url, { waitUntil: 'networkidle', timeout });
        await page.screenshot({ path: filepath, fullPage });
        results.push({ page: pagePath, viewport: vp.name, file: filepath, status: 'ok' });
      } catch (err) {
        results.push({ page: pagePath, viewport: vp.name, file: filepath, status: 'error', error: err.message });
      }
    }

    await context.close();
  }

  await browser.close();
  console.log(JSON.stringify(results, null, 2));
}

run().catch(err => {
  console.error('Fatal error:', err.message);
  process.exit(1);
});
SCRIPT
	return 0
}

# Capture screenshots of pages at specified viewports using Playwright.
# Args: --url URL --pages "/ /about /dashboard" --viewports "desktop,mobile" --output-dir DIR
# Output: Screenshot file paths, one per line
cmd_screenshot() {
	local url=""
	local pages="/"
	local viewports="$BROWSER_QA_DEFAULT_VIEWPORTS"
	local output_dir="$SCREENSHOTS_DIR"
	local timeout="$BROWSER_QA_DEFAULT_TIMEOUT"
	local full_page="false"
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
		--output-dir)
			output_dir="$2"
			shift 2
			;;
		--timeout)
			timeout="$2"
			shift 2
			;;
		--full-page)
			full_page="true"
			shift
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

	max_dim=$(resolve_max_image_dim "$max_dim")
	mkdir -p "$output_dir"

	# t2997: node ESM requires exact .mjs extension; use mktemp -d for a unique
	# directory + fixed-name script.mjs inside (XXXXXX must be at end for BSD
	# mktemp). Cleanup is rm -rf on the directory.
	local script_dir script_file
	script_dir=$(mktemp -d "${TMPDIR:-/tmp}/browser-qa-screenshot-XXXXXX")
	script_file="$script_dir/script.mjs"

	local viewport_array
	viewport_array=$(_build_viewports_js_array "$viewports")
	local pages_array
	pages_array=$(_build_pages_js_array "$pages")
	local safe_url safe_output_dir
	safe_url=$(js_escape_string "$url")
	safe_output_dir=$(js_escape_string "$output_dir")

	_generate_screenshot_script "$script_file" "$safe_url" "$viewport_array" "$pages_array" "$safe_output_dir" "$timeout" "$full_page"

	log_info "Capturing screenshots for ${pages} at viewports: ${viewports}"
	local exit_code=0
	run_playwright_node "$script_file" || exit_code=$?
	rm -rf "$script_dir"

	if [[ "$exit_code" -ne 0 ]]; then
		return "$exit_code"
	fi

	if ! enforce_screenshot_size_guardrails "$output_dir" "$max_dim"; then
		log_error "Screenshot guardrail enforcement failed"
		return 1
	fi

	return 0
}

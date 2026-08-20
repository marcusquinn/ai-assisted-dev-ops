#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

# Accessibility & Contrast Testing Helper Script
# WCAG compliance auditing for websites and HTML emails
# Uses: Lighthouse (accessibility category), pa11y (WCAG runner), WAVE API, contrast checks

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

set -euo pipefail

init_log_file

# Configuration
readonly A11Y_REPORTS_DIR="$HOME/.aidevops/reports/accessibility"
readonly A11Y_WCAG_LEVEL="${A11Y_WCAG_LEVEL:-WCAG2AA}"
readonly WAVE_API_ENDPOINT="https://wave.webaim.org/api/request"
readonly WAVE_DOCS_ENDPOINT="https://wave.webaim.org/api/docs"
# Note: WAVE API limits to 2 simultaneous requests per account

# Ensure reports directory exists
mkdir -p "$A11Y_REPORTS_DIR"

# ============================================================================
# Dependency Management
# ============================================================================

check_lighthouse() {
	if ! command -v lighthouse &>/dev/null; then
		print_error "Lighthouse CLI not found"
		print_info "Install: npm install -g lighthouse"
		return 1
	fi
	return 0
}

check_pa11y() {
	if ! command -v pa11y &>/dev/null; then
		print_warning "pa11y not found — install for WCAG-specific testing"
		print_info "Install: npm install -g pa11y"
		return 1
	fi
	return 0
}

check_jq() {
	if ! command -v jq &>/dev/null; then
		print_error "jq is required for JSON parsing"
		print_info "Install: brew install jq"
		return 1
	fi
	return 0
}

install_deps() {
	print_info "Installing accessibility testing dependencies..."

	if ! command -v jq &>/dev/null; then
		if command -v brew &>/dev/null; then
			brew install jq
		else
			print_error "Please install jq manually"
			return 1
		fi
	fi

	if ! command -v lighthouse &>/dev/null; then
		if command -v npm &>/dev/null; then
			npm install -g lighthouse
		else
			print_error "npm required to install Lighthouse"
			return 1
		fi
	fi

	if ! command -v pa11y &>/dev/null; then
		if command -v npm &>/dev/null; then
			npm install -g pa11y
		else
			print_warning "npm required to install pa11y (optional)"
		fi
	fi

	print_success "Dependencies installed"
	return 0
}

# ============================================================================
# WAVE API Integration
# ============================================================================

# Load WAVE API key from gopass or credentials file
load_wave_api_key() {
	# Already set via environment
	if [[ -n "${WAVE_API_KEY:-}" ]]; then
		return 0
	fi

	# Try gopass (encrypted, preferred)
	# secret-helper.sh normalizes names to uppercase (wave-api-key -> WAVE_API_KEY)
	# Try normalized path first, then legacy lowercase for backward compatibility
	if command -v gopass &>/dev/null; then
		WAVE_API_KEY=$(gopass show -o "aidevops/WAVE_API_KEY" 2>/dev/null || echo "")
		if [[ -z "$WAVE_API_KEY" ]]; then
			WAVE_API_KEY=$(gopass show -o "aidevops/wave-api-key" 2>/dev/null || echo "")
		fi
		if [[ -n "$WAVE_API_KEY" ]]; then
			export WAVE_API_KEY
			return 0
		fi
	fi

	# Try credentials file (plaintext fallback)
	local creds_file="$HOME/.config/aidevops/credentials.sh"
	if [[ -f "$creds_file" ]]; then
		# shellcheck source=/dev/null
		source "$creds_file"
		if [[ -n "${WAVE_API_KEY:-}" ]]; then
			export WAVE_API_KEY
			return 0
		fi
	fi

	print_error "WAVE API key not found"
	print_info "Set via: aidevops secret set wave-api-key"
	print_info "Or set WAVE_API_KEY environment variable"
	print_info "Register at: https://wave.webaim.org/api/register"
	return 1
}

# Run WAVE API audit on a URL
# Arguments:
#   $1 - URL to audit (required)
#   $2 - report type: 1=stats, 2=items, 3=items+xpath, 4=items+selectors (default: 2)
#   $3 - viewport width (default: 1200)
run_wave_audit() {
	local url="$1"
	local report_type="${2:-2}"
	local viewport_width="${3:-1200}"

	load_wave_api_key || return 1
	check_jq || return 1

	print_info "Running WAVE API audit..."
	print_info "URL: $url"
	print_info "Report type: $report_type (1=stats, 2=items, 3=xpath, 4=selectors)"

	local timestamp
	timestamp=$(date +"%Y%m%d_%H%M%S")
	local report_file="${A11Y_REPORTS_DIR}/wave_${timestamp}.json"

	local encoded_url
	encoded_url=$(python3 -c "import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=''))" "$url" 2>/dev/null || echo "$url")

	local api_url="${WAVE_API_ENDPOINT}?key=${WAVE_API_KEY}&url=${encoded_url}&reporttype=${report_type}&viewportwidth=${viewport_width}&format=json"

	local http_code
	http_code=$(curl -s -w "%{http_code}" -o "$report_file" \
		--max-time "$LONG_TIMEOUT" \
		"$api_url" 2>/dev/null) || {
		print_error "WAVE API request failed (network error)"
		return 1
	}

	if [[ "$http_code" -ne 200 ]]; then
		print_error "WAVE API returned HTTP $http_code"
		rm -f "$report_file" 2>/dev/null || true
		return 1
	fi

	# Check API-level success
	local api_success
	api_success=$(jq -r '.status.success // false' "$report_file" 2>/dev/null || echo "false")
	if [[ "$api_success" != "true" ]]; then
		local api_error
		api_error=$(jq -r '.status.error // "Unknown error"' "$report_file" 2>/dev/null || echo "Unknown error")
		print_error "WAVE API error: $api_error"
		return 1
	fi

	print_success "Report saved: $report_file"
	parse_wave_report "$report_file" "$report_type"
	return 0
}

# Print WAVE page statistics from report JSON
_wave_print_statistics() {
	local report_file="$1"

	local page_title page_url total_elements aim_score credits_remaining
	page_title=$(jq -r '.statistics.pagetitle // "N/A"' "$report_file")
	page_url=$(jq -r '.statistics.pageurl // "N/A"' "$report_file")
	total_elements=$(jq -r '.statistics.totalelements // "N/A"' "$report_file")
	aim_score=$(jq -r '.statistics.AIMscore // "N/A"' "$report_file")
	credits_remaining=$(jq -r '.statistics.creditsremaining // "N/A"' "$report_file")

	echo "  Page: $page_title"
	echo "  URL: $page_url"
	echo "  Elements: $total_elements"
	if [[ "$aim_score" != "N/A" ]]; then
		echo "  AIM Score: $aim_score"
	fi
	echo "  Credits remaining: $credits_remaining"
	echo ""
	return 0
}

# Print WAVE category summary with color-coded counts
_wave_print_category_summary() {
	local report_file="$1"

	print_header_line "Category Summary"

	local errors contrasts alerts features structures arias
	errors=$(jq -r '.categories.error.count // 0' "$report_file")
	contrasts=$(jq -r '.categories.contrast.count // 0' "$report_file")
	alerts=$(jq -r '.categories.alert.count // 0' "$report_file")
	features=$(jq -r '.categories.feature.count // 0' "$report_file")
	structures=$(jq -r '.categories.structure.count // 0' "$report_file")
	arias=$(jq -r '.categories.aria.count // 0' "$report_file")

	if [[ "$errors" -gt 0 ]]; then
		echo -e "  Errors:     ${RED}${errors}${NC}"
	else
		echo -e "  Errors:     ${GREEN}0${NC}"
	fi

	if [[ "$contrasts" -gt 0 ]]; then
		echo -e "  Contrast:   ${RED}${contrasts}${NC}"
	else
		echo -e "  Contrast:   ${GREEN}0${NC}"
	fi

	if [[ "$alerts" -gt 0 ]]; then
		echo -e "  Alerts:     ${YELLOW}${alerts}${NC}"
	else
		echo -e "  Alerts:     ${GREEN}0${NC}"
	fi

	echo "  Features:   $features"
	echo "  Structure:  $structures"
	echo "  ARIA:       $arias"
	echo ""
	return 0
}

# Print WAVE item details (errors, contrast, alerts) for reporttype >= 2
_wave_print_item_details() {
	local report_file="$1"
	local report_type="$2"

	local errors contrasts alerts
	errors=$(jq -r '.categories.error.count // 0' "$report_file")
	contrasts=$(jq -r '.categories.contrast.count // 0' "$report_file")
	alerts=$(jq -r '.categories.alert.count // 0' "$report_file")

	# Errors
	if [[ "$errors" -gt 0 ]]; then
		print_header_line "Errors (must fix)"
		jq -r '
            .categories.error.items // {} | to_entries[]
            | "  \(.value.id): \(.value.description) (x\(.value.count))"
        ' "$report_file" 2>/dev/null || true
		echo ""
	fi

	# Contrast errors
	if [[ "$contrasts" -gt 0 ]]; then
		print_header_line "Contrast Errors"
		jq -r '
            .categories.contrast.items // {} | to_entries[]
            | "  \(.value.id): \(.value.description) (x\(.value.count))"
        ' "$report_file" 2>/dev/null || true

		# Show contrast data if available (reporttype 3 or 4)
		if [[ "$report_type" -ge 3 ]]; then
			local contrast_data
			contrast_data=$(jq -r '
                .categories.contrast.items.contrast.contrastdata // [] | .[]
                | "    Ratio: \(.[0]):1 | FG: \(.[1]) | BG: \(.[2]) | Large: \(.[3])"
            ' "$report_file" 2>/dev/null || echo "")
			if [[ -n "$contrast_data" ]]; then
				echo "$contrast_data"
			fi
		fi
		echo ""
	fi

	# Alerts
	if [[ "$alerts" -gt 0 ]]; then
		print_header_line "Alerts (should review)"
		jq -r '
            .categories.alert.items // {} | to_entries[]
            | "  \(.value.id): \(.value.description) (x\(.value.count))"
        ' "$report_file" 2>/dev/null || true
		echo ""
	fi

	return 0
}

# Parse and display WAVE API report
parse_wave_report() {
	local report_file="$1"
	local report_type="${2:-2}"

	echo ""
	print_header_line "WAVE API Results"

	_wave_print_statistics "$report_file"
	_wave_print_category_summary "$report_file"

	if [[ "$report_type" -ge 2 ]]; then
		_wave_print_item_details "$report_file" "$report_type"
	fi

	# Full WAVE report link
	local wave_url
	wave_url=$(jq -r '.statistics.waveurl // "N/A"' "$report_file")
	if [[ "$wave_url" != "N/A" ]]; then
		print_info "Full WAVE report: $wave_url"
	fi

	echo ""
	return 0
}

# Run WAVE audit at mobile viewport width
run_wave_mobile() {
	local url="$1"
	local report_type="${2:-2}"

	print_info "Running WAVE API audit (mobile viewport)..."
	run_wave_audit "$url" "$report_type" "375"
	return $?
}

# Query WAVE documentation for a specific item
wave_docs() {
	local item_id="${1:-}"

	check_jq || return 1

	if [[ -z "$item_id" ]]; then
		print_error "Please provide a WAVE item ID"
		print_info "Usage: $0 wave-docs <item-id>"
		print_info "Example: $0 wave-docs alt_missing"
		return 1
	fi

	local docs_url="${WAVE_DOCS_ENDPOINT}?id=${item_id}"
	local result
	result=$(curl -s --max-time "$DEFAULT_TIMEOUT" "$docs_url" 2>/dev/null) || {
		print_error "Failed to fetch WAVE documentation"
		return 1
	}

	# Validate JSON before parsing
	if ! echo "$result" | jq empty 2>/dev/null; then
		print_error "WAVE API returned invalid JSON (possible HTML error page)"
		return 1
	fi

	echo ""
	print_header_line "WAVE Documentation: $item_id"

	local title type summary purpose actions details
	title=$(echo "$result" | jq -r '.title // "N/A"')
	type=$(echo "$result" | jq -r '.type // "N/A"')
	summary=$(echo "$result" | jq -r '.summary // "N/A"')
	purpose=$(echo "$result" | jq -r '.purpose // "N/A"')
	actions=$(echo "$result" | jq -r '.actions // "N/A"')
	details=$(echo "$result" | jq -r '.details // "N/A"')

	echo "  Title: $title"
	echo "  Type: $type"
	echo "  Summary: $summary"
	echo ""
	echo "  Purpose: $purpose"
	echo ""
	echo "  Actions: $actions"
	echo ""
	echo "  Algorithm: $details"
	echo ""

	# WCAG guidelines
	local guidelines
	guidelines=$(echo "$result" | jq -r '
        .guidelines // [] | .[]
        | "  - \(.name)"
    ' 2>/dev/null || echo "")
	if [[ -n "$guidelines" ]]; then
		print_header_line "WCAG Guidelines"
		echo "$guidelines"
	fi

	echo ""
	return 0
}

# Check WAVE API credits remaining
wave_credits() {
	load_wave_api_key || return 1
	check_jq || return 1

	# Use a lightweight request (reporttype=1, 1 credit) against a known URL
	print_info "Checking WAVE API credits..."

	local result
	result=$(curl -s --max-time "$DEFAULT_TIMEOUT" \
		"${WAVE_API_ENDPOINT}?key=${WAVE_API_KEY}&url=https://example.com&reporttype=1" \
		2>/dev/null) || {
		print_error "Failed to reach WAVE API"
		return 1
	}

	# Validate JSON before parsing
	if ! echo "$result" | jq empty 2>/dev/null; then
		print_error "WAVE API returned invalid JSON (possible HTML error page)"
		return 1
	fi

	local success
	success=$(echo "$result" | jq -r '.status.success // false')
	if [[ "$success" != "true" ]]; then
		local error_msg
		error_msg=$(echo "$result" | jq -r '.status.error // "Unknown error"')
		print_error "WAVE API error: $error_msg"
		return 1
	fi

	local credits
	credits=$(echo "$result" | jq -r '.statistics.creditsremaining // "N/A"')
	print_success "WAVE API credits remaining: $credits"
	return 0
}

# ============================================================================
# Lighthouse Accessibility Audit
# ============================================================================

run_lighthouse_a11y() {
	local url="$1"
	local strategy="${2:-desktop}"

	case "$strategy" in
	desktop | mobile) ;;
	*)
		print_error "Invalid Lighthouse strategy: $strategy"
		print_info "Use: desktop or mobile"
		return 1
		;;
	esac

	check_lighthouse || return 1
	check_jq || return 1

	print_info "Running Lighthouse accessibility audit..."
	print_info "URL: $url"
	print_info "Strategy: $strategy"

	local timestamp
	timestamp=$(date +"%Y%m%d_%H%M%S")
	local report_file="${A11Y_REPORTS_DIR}/lighthouse_a11y_${timestamp}.json"

	local chrome_flags="--headless --no-sandbox --disable-gpu"
	# Lighthouse --preset only accepts: desktop, perf, experimental.
	# Mobile is the default (no preset flag needed).
	local lighthouse_args=()
	if [[ "$strategy" == "desktop" ]]; then
		lighthouse_args+=(--preset=desktop)
		lighthouse_args+=(--screenEmulation.disabled)
	fi

	if lighthouse "$url" \
		--only-categories=accessibility \
		--output=json \
		--output-path="$report_file" \
		--chrome-flags="$chrome_flags" \
		${lighthouse_args[@]+"${lighthouse_args[@]}"} \
		--quiet; then

		print_success "Report saved: $report_file"
		parse_lighthouse_a11y "$report_file"
	else
		print_error "Lighthouse audit failed"
		return 1
	fi

	return 0
}

parse_lighthouse_a11y() {
	local report_file="$1"

	local score
	score=$(jq -r '.categories.accessibility.score // "N/A"' "$report_file")

	echo ""
	print_header_line "Accessibility Score"

	if [[ "$score" != "N/A" ]]; then
		local pct
		pct=$(awk -v s="$score" 'BEGIN { printf "%.0f", s * 100 }')
		local int_pct="${pct%.*}"

		if [[ "$int_pct" -ge 90 ]]; then
			echo -e "  Score: ${GREEN}${int_pct}%${NC} (Good)"
		elif [[ "$int_pct" -ge 50 ]]; then
			echo -e "  Score: ${YELLOW}${int_pct}%${NC} (Needs Improvement)"
		else
			echo -e "  Score: ${RED}${int_pct}%${NC} (Poor)"
		fi
	else
		echo "  Score: N/A"
	fi

	echo ""
	print_header_line "Failed Audits"

	local failures
	failures=$(jq -r '
        .audits | to_entries[]
        | select(.value.score != null and .value.score < 1 and .value.scoreDisplayMode == "binary")
        | "  \(.value.id): \(.value.title)"
    ' "$report_file" 2>/dev/null || echo "")

	if [[ -n "$failures" ]]; then
		echo "$failures"
	else
		print_success "No failed accessibility audits"
	fi

	echo ""
	print_header_line "Contrast Issues"

	local contrast
	contrast=$(jq -r '
        .audits["color-contrast"] // empty
        | if .score != null and .score < 1 then
            "  FAIL: \(.title)\n  \(.description // "Elements have insufficient contrast ratio")"
          else
            "  PASS: Color contrast requirements met"
          end
    ' "$report_file" 2>/dev/null || echo "  N/A")

	echo -e "$contrast"

	echo ""
	print_header_line "ARIA Issues"

	local aria_issues
	aria_issues=$(jq -r '
        .audits | to_entries[]
        | select(.key | startswith("aria-"))
        | select(.value.score != null and .value.score < 1)
        | "  FAIL: \(.value.title)"
    ' "$report_file" 2>/dev/null || echo "")

	if [[ -n "$aria_issues" ]]; then
		echo "$aria_issues"
	else
		print_success "No ARIA issues found"
	fi

	echo ""
	return 0
}

# ============================================================================
# pa11y WCAG Testing
# ============================================================================

run_pa11y_audit() {
	local url="$1"
	local standard="${2:-$A11Y_WCAG_LEVEL}"

	check_pa11y || return 1

	print_info "Running pa11y WCAG audit..."
	print_info "URL: $url"
	print_info "Standard: $standard"

	local timestamp
	timestamp=$(date +"%Y%m%d_%H%M%S")
	local report_file="${A11Y_REPORTS_DIR}/pa11y_${timestamp}.json"

	if pa11y "$url" \
		--standard "$standard" \
		--reporter json \
		--chromeLaunchConfig '{"args":["--no-sandbox","--headless"]}' \
		>"$report_file" 2>/dev/null; then

		print_success "Report saved: $report_file"
	else
		# pa11y exits non-zero when issues are found — that's expected
		if [[ -s "$report_file" ]]; then
			print_warning "Issues found (report saved: $report_file)"
		else
			print_error "pa11y audit failed"
			return 1
		fi
	fi

	parse_pa11y_report "$report_file" "$standard"
	return 0
}

parse_pa11y_report() {
	local report_file="$1"
	local standard="${2:-$A11Y_WCAG_LEVEL}"

	check_jq || return 1

	local total
	total=$(jq 'length' "$report_file" 2>/dev/null || echo "0")

	local errors
	errors=$(jq '[.[] | select(.type == "error")] | length' "$report_file" 2>/dev/null || echo "0")

	local warnings
	warnings=$(jq '[.[] | select(.type == "warning")] | length' "$report_file" 2>/dev/null || echo "0")

	local notices
	notices=$(jq '[.[] | select(.type == "notice")] | length' "$report_file" 2>/dev/null || echo "0")

	echo ""
	print_header_line "pa11y Results ($standard)"
	echo "  Total issues: $total"

	if [[ "$errors" -gt 0 ]]; then
		echo -e "  Errors:   ${RED}${errors}${NC}"
	else
		echo -e "  Errors:   ${GREEN}0${NC}"
	fi

	if [[ "$warnings" -gt 0 ]]; then
		echo -e "  Warnings: ${YELLOW}${warnings}${NC}"
	else
		echo -e "  Warnings: ${GREEN}0${NC}"
	fi

	echo "  Notices:  $notices"

	if [[ "$errors" -gt 0 ]]; then
		echo ""
		print_header_line "Errors (must fix)"
		jq -r '
            .[] | select(.type == "error")
            | "  [\(.code)]\n    \(.message)\n    Element: \(.selector)\n"
        ' "$report_file" 2>/dev/null | head -60
	fi

	echo ""
	return 0
}

# ============================================================================
# Email HTML Accessibility Check
# ============================================================================

# Count matched occurrences (not matching lines) so minified HTML is handled correctly
_email_grep_count() {
	local pattern="$1"
	local target_file="$2"
	(grep -oiE "$pattern" "$target_file" 2>/dev/null || true) | awk 'END { print NR }'
}

# Check images for alt text. Prints findings, returns issue count via stdout last line.
_email_check_images() {
	local file="$1"
	local total_imgs imgs_with_alt imgs_missing_alt empty_alts
	local issues=0 warnings=0

	total_imgs=$(_email_grep_count '<img ' "$file")
	imgs_with_alt=$(_email_grep_count '<img [^>]*alt=' "$file")
	imgs_missing_alt=$((total_imgs - imgs_with_alt))

	if [[ "$imgs_missing_alt" -gt 0 ]]; then
		echo "FAIL: $imgs_missing_alt image(s) missing alt attribute"
		echo "  WCAG 1.1.1 — All images must have alt text"
		issues=$((issues + imgs_missing_alt))
	else
		echo "PASS: All images have alt attributes ($total_imgs images)"
	fi
	echo ""

	empty_alts=$(_email_grep_count '<img [^>]*alt=""' "$file")
	if [[ "$empty_alts" -gt 0 ]]; then
		echo "WARN: $empty_alts image(s) with empty alt=\"\" (OK only if decorative)"
		warnings=$((warnings + 1))
	fi
	echo ""

	echo "COUNTS:$issues:$warnings"
	return 0
}

# Check lang attribute, tables, fonts, links, headings, colors.
# Prints findings, returns issue/warning counts via stdout last line.
_email_check_structure() {
	local file="$1"
	local issues=0 warnings=0

	# Check: language attribute on html tag
	if grep -qiE '<html[^>]*lang=' "$file" 2>/dev/null; then
		echo "PASS: HTML lang attribute present"
	else
		echo "FAIL: Missing lang attribute on <html> tag"
		echo "  WCAG 3.1.1 — Page language must be specified"
		issues=$((issues + 1))
	fi
	echo ""

	# Check: table role or summary for layout tables
	local tables tables_with_role
	tables=$(_email_grep_count '<table' "$file")
	tables_with_role=$(_email_grep_count '<table[^>]*role=' "$file")
	if [[ "$tables" -gt 0 && "$tables_with_role" -eq 0 ]]; then
		echo "WARN: $tables table(s) without role attribute"
		echo "  Email layout tables should have role=\"presentation\""
		warnings=$((warnings + 1))
	elif [[ "$tables" -gt 0 ]]; then
		echo "PASS: Tables have role attributes ($tables_with_role/$tables)"
	fi
	echo ""

	# Check: inline styles with small font sizes
	local small_fonts
	small_fonts=$(_email_grep_count 'font-size:\s*(([0-9]|1[0-3])px|0\.(0[0-9]*|[1-7][0-9]*|8([0-6][0-9]*|7[0-5]?))em)' "$file")
	if [[ "$small_fonts" -gt 0 ]]; then
		echo "WARN: $small_fonts instance(s) of font-size below 14px"
		echo "  WCAG 1.4.4 — Text should be resizable; small fonts harm readability"
		warnings=$((warnings + 1))
	else
		echo "PASS: No excessively small font sizes detected"
	fi
	echo ""

	# Check: links with descriptive text
	local generic_links
	generic_links=$(_email_grep_count '<a [^>]*>[[:space:]]*(click here|here|read more|learn more|more)[[:space:]]*</a>' "$file")
	if [[ "$generic_links" -gt 0 ]]; then
		echo "WARN: $generic_links link(s) with generic text (e.g., 'click here')"
		echo "  WCAG 2.4.4 — Link text should describe the destination"
		warnings=$((warnings + 1))
	else
		echo "PASS: No generic link text detected"
	fi
	echo ""

	# Check: sufficient heading structure
	local headings
	headings=$(_email_grep_count '<h[1-6]' "$file")
	if [[ "$headings" -eq 0 ]]; then
		echo "WARN: No heading elements found"
		echo "  WCAG 1.3.1 — Use headings to convey document structure"
		warnings=$((warnings + 1))
	else
		echo "PASS: $headings heading element(s) found"
	fi
	echo ""

	# Check: color-only information indicators
	local color_only
	color_only=$(_email_grep_count 'color:\s*(red|green)' "$file")
	if [[ "$color_only" -gt 0 ]]; then
		echo "WARN: $color_only instance(s) of red/green color usage"
		echo "  WCAG 1.4.1 — Do not use color as the only means of conveying information"
		warnings=$((warnings + 1))
	fi
	echo ""

	echo "COUNTS:$issues:$warnings"
	return 0
}

check_email_a11y() {
	local file="$1"

	if [[ ! -f "$file" ]]; then
		print_error "File not found: $file"
		return 1
	fi

	print_info "Checking email HTML accessibility: $file"

	local timestamp
	timestamp=$(date +"%Y%m%d_%H%M%S")
	local report_file="${A11Y_REPORTS_DIR}/email_a11y_${timestamp}.txt"
	local issues=0
	local warnings=0
	local output=""

	_append() {
		output="${output}${1}"$'\n'
		return 0
	}

	_append "Email Accessibility Report"
	_append "File: $file"
	_append "Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
	_append "Standard: WCAG 2.1 AA (email-applicable subset)"
	_append "=========================================="
	_append ""

	# Run image checks — parse counts from last line
	local img_output img_counts
	img_output=$(_email_check_images "$file")
	img_counts=$(echo "$img_output" | tail -1)
	_append "$(echo "$img_output" | sed '$d')"
	issues=$((issues + $(echo "$img_counts" | cut -d: -f2)))
	warnings=$((warnings + $(echo "$img_counts" | cut -d: -f3)))

	# Run structural checks — parse counts from last line
	local struct_output struct_counts
	struct_output=$(_email_check_structure "$file")
	struct_counts=$(echo "$struct_output" | tail -1)
	_append "$(echo "$struct_output" | sed '$d')"
	issues=$((issues + $(echo "$struct_counts" | cut -d: -f2)))
	warnings=$((warnings + $(echo "$struct_counts" | cut -d: -f3)))

	# Summary
	_append "=========================================="
	_append "Summary: $issues error(s), $warnings warning(s)"
	if [[ "$issues" -eq 0 ]]; then
		_append "Status: PASS (with $warnings advisory warnings)"
	else
		_append "Status: FAIL — $issues issue(s) require attention"
	fi

	# Write report and display (no subshell — issues/warnings preserved)
	echo "$output" | tee "$report_file"

	print_info "Report saved: $report_file"
	echo ""

	if [[ "$issues" -gt 0 ]]; then
		return 1
	fi
	return 0
}

# ============================================================================
# Contrast Ratio Calculator
# ============================================================================

hex_to_rgb() {
	local hex="$1"
	hex="${hex#\#}"

	if [[ ! "$hex" =~ ^([[:xdigit:]]{3}|[[:xdigit:]]{6})$ ]]; then
		print_error "Invalid hex color: $1"
		return 1
	fi

	# Expand shorthand (e.g., #fff -> #ffffff)
	if [[ ${#hex} -eq 3 ]]; then
		hex="${hex:0:1}${hex:0:1}${hex:1:1}${hex:1:1}${hex:2:1}${hex:2:1}"
	fi

	local r=$((16#${hex:0:2}))
	local g=$((16#${hex:2:2}))
	local b=$((16#${hex:4:2}))

	echo "$r $g $b"
	return 0
}

relative_luminance() {
	local r="$1"
	local g="$2"
	local b="$3"

	# sRGB to linear, then luminance per WCAG 2.x formula
	# Using awk for floating-point math (bc may not be available)
	awk -v r="$r" -v g="$g" -v b="$b" 'BEGIN {
        rs = r / 255.0
        gs = g / 255.0
        bs = b / 255.0

        if (rs <= 0.03928) rl = rs / 12.92; else rl = ((rs + 0.055) / 1.055) ^ 2.4
        if (gs <= 0.03928) gl = gs / 12.92; else gl = ((gs + 0.055) / 1.055) ^ 2.4
        if (bs <= 0.03928) bl = bs / 12.92; else bl = ((bs + 0.055) / 1.055) ^ 2.4

        printf "%.6f\n", 0.2126 * rl + 0.7152 * gl + 0.0722 * bl
    }'
	return 0
}

check_contrast() {
	local fg="$1"
	local bg="$2"

	local fg_rgb bg_rgb
	if ! fg_rgb=$(hex_to_rgb "$fg"); then
		return 1
	fi
	if ! bg_rgb=$(hex_to_rgb "$bg"); then
		return 1
	fi

	local fg_r fg_g fg_b bg_r bg_g bg_b
	read -r fg_r fg_g fg_b <<<"$fg_rgb"
	read -r bg_r bg_g bg_b <<<"$bg_rgb"

	local fg_lum bg_lum
	fg_lum=$(relative_luminance "$fg_r" "$fg_g" "$fg_b")
	bg_lum=$(relative_luminance "$bg_r" "$bg_g" "$bg_b")

	local ratio
	ratio=$(awk -v l1="$fg_lum" -v l2="$bg_lum" 'BEGIN {
        if (l1 > l2) {
            printf "%.2f\n", (l1 + 0.05) / (l2 + 0.05)
        } else {
            printf "%.2f\n", (l2 + 0.05) / (l1 + 0.05)
        }
    }')

	echo ""
	print_header_line "Contrast Ratio Check"
	echo "  Foreground: $fg"
	echo "  Background: $bg"
	echo "  Ratio: ${ratio}:1"
	echo ""

	# WCAG AA: 4.5:1 for normal text, 3:1 for large text
	# WCAG AAA: 7:1 for normal text, 4.5:1 for large text
	local aa_normal aa_large aaa_normal aaa_large
	aa_normal=$(awk -v r="$ratio" 'BEGIN { print (r >= 4.5) ? "PASS" : "FAIL" }')
	aa_large=$(awk -v r="$ratio" 'BEGIN { print (r >= 3.0) ? "PASS" : "FAIL" }')
	aaa_normal=$(awk -v r="$ratio" 'BEGIN { print (r >= 7.0) ? "PASS" : "FAIL" }')
	aaa_large=$(awk -v r="$ratio" 'BEGIN { print (r >= 4.5) ? "PASS" : "FAIL" }')

	echo "  WCAG AA  Normal text (4.5:1): $aa_normal"
	echo "  WCAG AA  Large text  (3.0:1): $aa_large"
	echo "  WCAG AAA Normal text (7.0:1): $aaa_normal"
	echo "  WCAG AAA Large text  (4.5:1): $aaa_large"
	echo ""

	if [[ "$aa_normal" == "FAIL" ]]; then
		return 1
	fi
	return 0
}

# ============================================================================
# Full Audit (Lighthouse + pa11y + WAVE combined)
# ============================================================================

run_full_audit() {
	local url="$1"

	print_header_line "Full Accessibility Audit: $url"
	echo ""

	local exit_code=0

	# Lighthouse accessibility
	if check_lighthouse 2>/dev/null; then
		run_lighthouse_a11y "$url" "desktop" || exit_code=1
		echo ""
		run_lighthouse_a11y "$url" "mobile" || exit_code=1
	fi

	echo ""

	# pa11y WCAG
	if check_pa11y 2>/dev/null; then
		run_pa11y_audit "$url" "$A11Y_WCAG_LEVEL" || exit_code=1
	else
		print_warning "Skipping pa11y (not installed). Install: npm install -g pa11y"
	fi

	echo ""

	# WAVE API (if key is available)
	if load_wave_api_key 2>/dev/null; then
		run_wave_audit "$url" "2" || exit_code=1
	else
		print_warning "Skipping WAVE API (no API key). Set via: aidevops secret set wave-api-key"
	fi

	echo ""
	print_header_line "Audit Complete"
	print_info "Reports saved to: $A11Y_REPORTS_DIR"

	return $exit_code
}

# ============================================================================
# Bulk Audit
# ============================================================================

bulk_audit() {
	local urls_file="$1"

	if [[ ! -f "$urls_file" ]]; then
		print_error "URLs file not found: $urls_file"
		return 1
	fi

	print_header_line "Bulk Accessibility Audit"
	print_info "Processing URLs from: $urls_file"

	local count=0
	local failures=0

	while IFS= read -r url || [[ -n "$url" ]]; do
		[[ -z "$url" || "$url" =~ ^#.*$ ]] && continue

		count=$((count + 1))
		echo ""
		print_header_line "Site $count: $url"

		if ! run_full_audit "$url"; then
			failures=$((failures + 1))
		fi

		# Rate limit
		sleep 2
	done <"$urls_file"

	echo ""
	print_header_line "Bulk Audit Summary"
	echo "  Sites audited: $count"
	echo "  Sites with issues: $failures"
	echo "  Reports: $A11Y_REPORTS_DIR"

	if [[ "$failures" -gt 0 ]]; then
		return 1
	fi
	return 0
}

# ============================================================================
# Playwright Contrast Extraction
# ============================================================================

check_playwright() {
	if ! command -v node &>/dev/null; then
		print_error "Node.js not found (required for Playwright)"
		return 1
	fi
	local runtime_script="${SCRIPT_DIR}/playwright-runtime.mjs"
	local resolved_module
	if ! resolved_module=$(node "$runtime_script" check); then
		print_warning "Playwright package or browser binary is unavailable"
		return 1
	fi
	export AIDEVOPS_PLAYWRIGHT_MODULE="$resolved_module"
	return 0
}

run_playwright_contrast() {
	local url="$1"
	local format="${2:-summary}"
	local level="${3:-AA}"

	check_playwright || return 1

	print_info "Running Playwright contrast extraction..."
	print_info "URL: $url"
	print_info "Format: $format"
	print_info "Level: WCAG $level"

	local timestamp
	timestamp=$(date +"%Y%m%d_%H%M%S")
	local report_file="${A11Y_REPORTS_DIR}/playwright_contrast_${timestamp}"
	local script_path="${SCRIPT_DIR}/accessibility/playwright-contrast.mjs"

	if [[ ! -f "$script_path" ]]; then
		print_error "Playwright contrast script not found: $script_path"
		return 1
	fi

	local exit_code=0
	case "$format" in
	"json")
		report_file="${report_file}.json"
		if node "$script_path" "$url" --format json --level "$level" >"$report_file" 2>&1; then
			exit_code=0
		else
			exit_code=$?
		fi
		;;
	"markdown" | "md")
		report_file="${report_file}.md"
		if node "$script_path" "$url" --format markdown --level "$level" >"$report_file" 2>&1; then
			exit_code=0
		else
			exit_code=$?
		fi
		;;
	"summary" | *)
		report_file="${report_file}.txt"
		if node "$script_path" "$url" --format summary --level "$level" 2>&1 | tee "$report_file"; then
			exit_code=0
		else
			exit_code=${PIPESTATUS[0]}
		fi
		;;
	esac

	if [[ "$exit_code" -eq 2 ]]; then
		print_error "Playwright contrast extraction failed"
		return 1
	fi

	print_info "Report saved: $report_file"

	if [[ "$exit_code" -eq 1 ]]; then
		print_warning "Contrast failures detected at WCAG $level"
	else
		print_success "All elements pass WCAG $level contrast requirements"
	fi

	return "$exit_code"
}

# ============================================================================
# Utility
# ============================================================================

print_header_line() {
	local msg="$1"
	echo -e "${PURPLE}--- $msg ---${NC}"
	return 0
}

# ============================================================================
# Main
# ============================================================================

# Validate that a required argument is present, print usage on failure
_main_require_arg() {
	local arg_value="$1"
	local error_msg="$2"
	local usage_msg="$3"

	if [[ -z "$arg_value" ]]; then
		print_error "$error_msg"
		print_info "$usage_msg"
		return 1
	fi
	return 0
}

# Print help text for all available commands
_main_print_help() {
	print_header_line "Accessibility & Contrast Testing Helper"
	echo "Usage: $0 [command] [options]"
	echo ""
	echo "Commands:"
	echo "  audit <url>                    Full accessibility audit (Lighthouse + pa11y + WAVE)"
	echo "  lighthouse <url> [strategy]    Lighthouse accessibility-only audit"
	echo "  pa11y <url> [standard]         pa11y WCAG compliance test"
	echo "  wave <url> [type] [width]      WAVE API accessibility analysis"
	echo "  wave-mobile <url> [type]       WAVE API audit at mobile viewport (375px)"
	echo "  wave-docs <item-id>            Look up WAVE item documentation"
	echo "  wave-credits                   Check WAVE API credits remaining"
	echo "  email <file.html>              Check HTML email accessibility"
	echo "  contrast <fg-hex> <bg-hex>     Calculate WCAG contrast ratio"
	echo "  playwright-contrast <url> [fmt] [level]"
	echo "                                 Extract contrast from all visible elements via Playwright"
	echo "                                 Formats: json, markdown, summary (default)"
	echo "                                 Levels: AA (default), AAA"
	echo "  bulk <urls-file>               Audit multiple URLs from file"
	echo "  install-deps                   Install required dependencies"
	echo "  help                           Show this help"
	echo ""
	echo "WAVE Report Types: 1=stats (1 credit), 2=items (2 credits),"
	echo "  3=items+xpath (3 credits), 4=items+selectors (3 credits)"
	echo ""
	echo "Standards: WCAG2A, WCAG2AA (default), WCAG2AAA"
	echo "Strategies: desktop (default), mobile"
	echo ""
	echo "Environment Variables:"
	echo "  A11Y_WCAG_LEVEL    Default WCAG level (default: WCAG2AA)"
	echo "  WAVE_API_KEY       WAVE API key (or use: aidevops secret set wave-api-key)"
	echo ""
	echo "Examples:"
	echo "  $0 audit https://example.com"
	echo "  $0 lighthouse https://example.com mobile"
	echo "  $0 pa11y https://example.com WCAG2AAA"
	echo "  $0 wave https://example.com 3"
	echo "  $0 wave-mobile https://example.com"
	echo "  $0 wave-docs alt_missing"
	echo "  $0 email ./newsletter.html"
	echo "  $0 contrast '#333333' '#ffffff'"
	echo "  $0 playwright-contrast https://example.com json AAA"
	echo "  $0 bulk websites.txt"
	echo ""
	echo "Reports saved to: $A11Y_REPORTS_DIR"
	return 0
}

# Dispatch audit-category commands: audit, lighthouse, pa11y, email, bulk.
# Args: $1=command $2=account_name $3=optional_arg $4=optional_arg
# Returns: 0=handled (success or failure), 2=command not in this group
_main_dispatch_audit() {
	local command="$1"
	local account_name="$2"

	case "$command" in
	"audit" | "check")
		_main_require_arg "$account_name" "Please provide a URL to audit" "Usage: $0 audit <url>" || return 1
		run_full_audit "$account_name"
		return $?
		;;
	"lighthouse" | "lh")
		_main_require_arg "$account_name" "Please provide a URL" "Usage: $0 lighthouse <url> [desktop|mobile]" || return 1
		check_jq || return 1
		run_lighthouse_a11y "$account_name" "${3:-desktop}"
		return $?
		;;
	"pa11y" | "wcag")
		_main_require_arg "$account_name" "Please provide a URL" "Usage: $0 pa11y <url> [WCAG2A|WCAG2AA|WCAG2AAA]" || return 1
		run_pa11y_audit "$account_name" "${3:-$A11Y_WCAG_LEVEL}"
		return $?
		;;
	"email")
		_main_require_arg "$account_name" "Please provide an HTML file path" "Usage: $0 email <file.html>" || return 1
		check_email_a11y "$account_name"
		return $?
		;;
	"bulk")
		_main_require_arg "$account_name" "Please provide a file containing URLs" "Usage: $0 bulk <urls-file>" || return 1
		bulk_audit "$account_name"
		return $?
		;;
	*)
		return 2
		;;
	esac
}

# Dispatch contrast-and-wave commands: contrast, playwright-contrast, wave*.
# Args: $1=command $2=account_name $3=optional_arg $4=optional_arg
# Returns: 0=handled (success or failure), 2=command not in this group
_main_dispatch_contrast_wave() {
	local command="$1"
	local account_name="$2"

	case "$command" in
	"contrast")
		if [[ -z "$account_name" || -z "${3:-}" ]]; then
			print_error "Please provide foreground and background colors"
			print_info "Usage: $0 contrast <fg-hex> <bg-hex>"
			print_info "Example: $0 contrast '#333333' '#ffffff'"
			return 1
		fi
		check_contrast "$account_name" "$3"
		return $?
		;;
	"playwright-contrast" | "pw-contrast" | "extract-contrast")
		_main_require_arg "$account_name" "Please provide a URL" "Usage: $0 playwright-contrast <url> [json|markdown|summary] [AA|AAA]" || return 1
		run_playwright_contrast "$account_name" "${3:-summary}" "${4:-AA}"
		return $?
		;;
	"wave")
		if [[ -z "$account_name" ]]; then
			print_error "Please provide a URL"
			print_info "Usage: $0 wave <url> [reporttype] [viewport-width]"
			print_info "Report types: 1=stats, 2=items (default), 3=items+xpath, 4=items+selectors"
			return 1
		fi
		run_wave_audit "$account_name" "${3:-2}" "${4:-1200}"
		return $?
		;;
	"wave-mobile")
		_main_require_arg "$account_name" "Please provide a URL" "Usage: $0 wave-mobile <url> [reporttype]" || return 1
		run_wave_mobile "$account_name" "${3:-2}"
		return $?
		;;
	"wave-docs")
		wave_docs "$account_name"
		return $?
		;;
	"wave-credits")
		wave_credits
		return $?
		;;
	*)
		return 2
		;;
	esac
}

main() {
	local command="${1:-help}"
	local account_name="${2:-}"
	local rc

	# Try audit/lighthouse/pa11y/email/bulk group
	_main_dispatch_audit "$command" "$account_name" "${3:-}" "${4:-}"
	rc=$?
	if [[ $rc -ne 2 ]]; then
		return $rc
	fi

	# Try contrast/wave group
	_main_dispatch_contrast_wave "$command" "$account_name" "${3:-}" "${4:-}"
	rc=$?
	if [[ $rc -ne 2 ]]; then
		return $rc
	fi

	case "$command" in
	"install-deps")
		install_deps
		;;
	"help")
		_main_print_help
		;;
	*)
		print_error "Unknown command: $command"
		print_info "Run: $0 help"
		return 1
		;;
	esac
	return 0
}

main "$@"

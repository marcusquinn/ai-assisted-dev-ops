#!/bin/bash

# 🚀 PageSpeed Insights & Lighthouse Helper Script
# Comprehensive website performance auditing and optimization guidance

set -euo pipefail

# Colors for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly BLUE='\033[0;34m'
readonly YELLOW='\033[1;33m'
readonly PURPLE='\033[0;35m'
readonly CYAN='\033[0;36m'
readonly NC='\033[0m'

print_header() { echo -e "${PURPLE}🚀 $1${NC}"; }
print_info() { echo -e "${BLUE}ℹ️  $1${NC}"; }
print_success() { echo -e "${GREEN}✅ $1${NC}"; }
print_warning() { echo -e "${YELLOW}⚠️  $1${NC}"; }
print_error() { echo -e "${RED}❌ $1${NC}"; }
print_metric() { echo -e "${CYAN}📊 $1${NC}"; }

# Configuration
readonly PAGESPEED_API_URL="https://www.googleapis.com/pagespeedonline/v5/runPagespeed"
readonly REPORTS_DIR="$HOME/.ai-devops/reports/pagespeed"

# Ensure reports directory exists
mkdir -p "$REPORTS_DIR"

# Check prerequisites
check_prerequisites() {
    print_header "Checking Prerequisites"
    
    # Check for curl
    if ! command -v curl &> /dev/null; then
        print_error "curl is required but not installed"
        exit 1
    fi
    
    # Check for jq (for JSON parsing)
    if ! command -v jq &> /dev/null; then
        print_warning "jq not found. Installing for better JSON parsing..."
        if [[ "$OSTYPE" == "darwin"* ]]; then
            if command -v brew &> /dev/null; then
                brew install jq
            else
                print_error "Please install jq manually: https://stedolan.github.io/jq/"
                exit 1
            fi
        else
            print_error "Please install jq manually: https://stedolan.github.io/jq/"
            exit 1
        fi
    fi
    
    # Check for Lighthouse CLI
    if ! command -v lighthouse &> /dev/null; then
        print_warning "Lighthouse CLI not found. Installing..."
        if command -v npm &> /dev/null; then
            npm install -g lighthouse
            print_success "Lighthouse CLI installed"
        else
            print_error "npm is required to install Lighthouse CLI"
            print_info "Install Node.js from: https://nodejs.org/"
            exit 1
        fi
    fi
    
    print_success "All prerequisites satisfied"
    return 0
}

# Run PageSpeed Insights API test
run_pagespeed_api() {
    local url="$1"
    local strategy="${2:-desktop}"  # desktop or mobile
    local api_key="${GOOGLE_API_KEY:-}"
    
    print_header "Running PageSpeed Insights API Test"
    print_info "URL: $url"
    print_info "Strategy: $strategy"
    
    # Build API URL
    local api_url="$PAGESPEED_API_URL?url=$url&strategy=$strategy"
    
    if [[ -n "$api_key" ]]; then
        api_url="$api_url&key=$api_key"
        print_info "Using API key for higher rate limits"
    else
        print_warning "No API key provided. Using public rate limits."
        print_info "Set GOOGLE_API_KEY environment variable for higher limits"
    fi
    
    # Make API request
    local timestamp
    timestamp=$(date +"%Y%m%d_%H%M%S")
    local report_file="$REPORTS_DIR/pagespeed_${timestamp}_${strategy}.json"
    
    print_info "Fetching PageSpeed data..."
    
    if curl -s "$api_url" > "$report_file"; then
        print_success "PageSpeed report saved: $report_file"
        
        # Parse and display key metrics
        parse_pagespeed_report "$report_file"
    else
        print_error "Failed to fetch PageSpeed data"
        return 1
    fi
    
    return 0
}

# Parse PageSpeed report and extract actionable insights
parse_pagespeed_report() {
    local report_file="$1"
    
    print_header "PageSpeed Insights Results"
    
    # Check if report contains error
    if jq -e '.error' "$report_file" &> /dev/null; then
        local error_message
        error_message=$(jq -r '.error.message' "$report_file")
        print_error "API Error: $error_message"
        return 1
    fi
    
    # Extract key metrics
    local performance_score
    local fcp
    local lcp
    local cls
    local fid
    local ttfb
    
    performance_score=$(jq -r '.lighthouseResult.categories.performance.score // "N/A"' "$report_file")
    fcp=$(jq -r '.lighthouseResult.audits["first-contentful-paint"].displayValue // "N/A"' "$report_file")
    lcp=$(jq -r '.lighthouseResult.audits["largest-contentful-paint"].displayValue // "N/A"' "$report_file")
    cls=$(jq -r '.lighthouseResult.audits["cumulative-layout-shift"].displayValue // "N/A"' "$report_file")
    fid=$(jq -r '.lighthouseResult.audits["max-potential-fid"].displayValue // "N/A"' "$report_file")
    ttfb=$(jq -r '.lighthouseResult.audits["server-response-time"].displayValue // "N/A"' "$report_file")
    
    # Display metrics with color coding
    echo
    print_metric "Performance Score: $(format_score "$performance_score")"
    print_metric "First Contentful Paint (FCP): $fcp"
    print_metric "Largest Contentful Paint (LCP): $lcp"
    print_metric "Cumulative Layout Shift (CLS): $cls"
    print_metric "First Input Delay (FID): $fid"
    print_metric "Time to First Byte (TTFB): $ttfb"
    echo
    
    # Extract opportunities for improvement
    print_header "Optimization Opportunities"
    
    local opportunities
    opportunities=$(jq -r '.lighthouseResult.audits | to_entries[] | select(.value.details.overallSavingsMs > 0) | "\(.key): \(.value.title) - Potential savings: \(.value.details.overallSavingsMs)ms"' "$report_file" 2>/dev/null || echo "No specific opportunities found")
    
    if [[ "$opportunities" != "No specific opportunities found" ]]; then
        echo "$opportunities" | head -10
    else
        print_info "No major optimization opportunities identified"
    fi
    
    return 0
}

# Format score with color coding
format_score() {
    local score="$1"
    
    if [[ "$score" == "N/A" ]]; then
        echo "N/A"
        return
    fi
    
    # Convert to percentage
    local percentage
    percentage=$(echo "$score * 100" | bc -l 2>/dev/null || echo "0")
    local int_percentage
    int_percentage=${percentage%.*}
    
    if [[ $int_percentage -ge 90 ]]; then
        echo -e "${GREEN}${int_percentage}%${NC}"
    elif [[ $int_percentage -ge 50 ]]; then
        echo -e "${YELLOW}${int_percentage}%${NC}"
    else
        echo -e "${RED}${int_percentage}%${NC}"
    fi
}

# Run Lighthouse CLI audit
run_lighthouse_audit() {
    local url="$1"
    local output_format="${2:-html}"  # html, json, csv
    
    print_header "Running Lighthouse CLI Audit"
    print_info "URL: $url"
    print_info "Output format: $output_format"
    
    local timestamp
    timestamp=$(date +"%Y%m%d_%H%M%S")
    local report_file="$REPORTS_DIR/lighthouse_${timestamp}.$output_format"
    
    print_info "Running comprehensive Lighthouse audit..."
    
    # Run Lighthouse with comprehensive options
    if lighthouse "$url" \
        --output="$output_format" \
        --output-path="$report_file" \
        --chrome-flags="--headless --no-sandbox" \
        --quiet; then
        
        print_success "Lighthouse report saved: $report_file"
        
        # If JSON format, parse key metrics
        if [[ "$output_format" == "json" ]]; then
            parse_lighthouse_json "$report_file"
        else
            print_info "Open the HTML report in your browser to view detailed results"
        fi
    else
        print_error "Lighthouse audit failed"
        return 1
    fi
    
    return 0
}

# Parse Lighthouse JSON report
parse_lighthouse_json() {
    local report_file="$1"
    
    print_header "Lighthouse Audit Results"
    
    # Extract scores for all categories
    local performance
    local accessibility
    local best_practices
    local seo
    local pwa
    
    performance=$(jq -r '.categories.performance.score // "N/A"' "$report_file")
    accessibility=$(jq -r '.categories.accessibility.score // "N/A"' "$report_file")
    best_practices=$(jq -r '.categories["best-practices"].score // "N/A"' "$report_file")
    seo=$(jq -r '.categories.seo.score // "N/A"' "$report_file")
    pwa=$(jq -r '.categories.pwa.score // "N/A"' "$report_file")
    
    echo
    print_metric "Performance: $(format_score "$performance")"
    print_metric "Accessibility: $(format_score "$accessibility")"
    print_metric "Best Practices: $(format_score "$best_practices")"
    print_metric "SEO: $(format_score "$seo")"
    print_metric "PWA: $(format_score "$pwa")"
    echo

    return 0
}

# WordPress-specific performance analysis
analyze_wordpress_performance() {
    local url="$1"

    print_header "WordPress Performance Analysis"
    print_info "Analyzing WordPress-specific performance issues for: $url"

    # Run both PageSpeed and Lighthouse
    run_pagespeed_api "$url" "desktop"
    echo
    run_pagespeed_api "$url" "mobile"
    echo
    run_lighthouse_audit "$url" "json"

    # WordPress-specific recommendations
    print_header "WordPress Optimization Recommendations"
    echo
    print_info "Common WordPress Performance Issues to Check:"
    echo "• Plugin Performance: Disable unnecessary plugins"
    echo "• Image Optimization: Use WebP format and proper sizing"
    echo "• Caching: Implement page caching (WP Rocket, W3 Total Cache)"
    echo "• CDN: Use a Content Delivery Network (Cloudflare, MaxCDN)"
    echo "• Database Optimization: Clean up revisions and spam"
    echo "• Theme Performance: Use lightweight, optimized themes"
    echo "• Hosting: Ensure adequate server resources"
    echo

    return 0
}

# Bulk audit multiple URLs
bulk_audit() {
    local urls_file="$1"

    if [[ ! -f "$urls_file" ]]; then
        print_error "URLs file not found: $urls_file"
        return 1
    fi

    print_header "Bulk Website Audit"
    print_info "Processing URLs from: $urls_file"

    local count=0
    while IFS= read -r url; do
        # Skip empty lines and comments
        [[ -z "$url" || "$url" =~ ^#.*$ ]] && continue

        count=$((count + 1))
        print_header "Auditing Site $count: $url"

        # Run PageSpeed for both desktop and mobile
        run_pagespeed_api "$url" "desktop"
        run_pagespeed_api "$url" "mobile"

        echo "----------------------------------------"

        # Add delay to respect rate limits
        sleep 2

    done < "$urls_file"

    print_success "Bulk audit completed for $count websites"
    return 0
}

# Generate actionable report
generate_actionable_report() {
    local report_file="$1"

    if [[ ! -f "$report_file" ]]; then
        print_error "Report file not found: $report_file"
        return 1
    fi

    print_header "Actionable Performance Report"

    # Extract and prioritize recommendations
    local recommendations
    recommendations=$(jq -r '
        .lighthouseResult.audits |
        to_entries[] |
        select(.value.score != null and .value.score < 0.9) |
        select(.value.details.overallSavingsMs > 100 or .value.numericValue > 2000) |
        {
            title: .value.title,
            description: .value.description,
            savings: (.value.details.overallSavingsMs // 0),
            impact: (if .value.details.overallSavingsMs > 1000 then "HIGH"
                    elif .value.details.overallSavingsMs > 500 then "MEDIUM"
                    else "LOW" end)
        }
    ' "$report_file" 2>/dev/null)

    if [[ -n "$recommendations" ]]; then
        echo "$recommendations" | jq -r '"🔧 \(.title) (\(.impact) IMPACT)\n   💡 \(.description)\n   ⏱️  Potential savings: \(.savings)ms\n"'
    else
        print_info "No major performance issues found. Great job!"
    fi

    return 0
}

# Main function
main() {
    case "${1:-help}" in
        "check"|"audit")
            if [[ -z "${2:-}" ]]; then
                print_error "Please provide a URL to audit"
                print_info "Usage: $0 audit <url>"
                exit 1
            fi
            check_prerequisites
            run_pagespeed_api "$2" "desktop"
            echo
            run_pagespeed_api "$2" "mobile"
            ;;
        "lighthouse")
            if [[ -z "${2:-}" ]]; then
                print_error "Please provide a URL for Lighthouse audit"
                print_info "Usage: $0 lighthouse <url> [format]"
                exit 1
            fi
            check_prerequisites
            run_lighthouse_audit "$2" "${3:-html}"
            ;;
        "wordpress"|"wp")
            if [[ -z "${2:-}" ]]; then
                print_error "Please provide a WordPress URL to analyze"
                print_info "Usage: $0 wordpress <url>"
                exit 1
            fi
            check_prerequisites
            analyze_wordpress_performance "$2"
            ;;
        "bulk")
            if [[ -z "${2:-}" ]]; then
                print_error "Please provide a file containing URLs"
                print_info "Usage: $0 bulk <urls-file>"
                print_info "File format: one URL per line"
                exit 1
            fi
            check_prerequisites
            bulk_audit "$2"
            ;;
        "report")
            if [[ -z "${2:-}" ]]; then
                print_error "Please provide a report file to analyze"
                print_info "Usage: $0 report <report-file.json>"
                exit 1
            fi
            generate_actionable_report "$2"
            ;;
        "install-deps")
            check_prerequisites
            ;;
        "help"|*)
            print_header "PageSpeed Insights & Lighthouse Helper"
            echo "Usage: $0 [command] [options]"
            echo ""
            echo "Commands:"
            echo "  audit <url>              - Run PageSpeed Insights for desktop & mobile"
            echo "  lighthouse <url> [fmt]   - Run Lighthouse audit (html/json/csv)"
            echo "  wordpress <url>          - WordPress-specific performance analysis"
            echo "  bulk <urls-file>         - Audit multiple URLs from file"
            echo "  report <report.json>     - Generate actionable report from JSON"
            echo "  install-deps             - Install required dependencies"
            echo "  help                     - Show this help"
            echo ""
            echo "Environment Variables:"
            echo "  GOOGLE_API_KEY          - Google API key for higher rate limits"
            echo ""
            echo "Examples:"
            echo "  $0 audit https://example.com"
            echo "  $0 lighthouse https://example.com json"
            echo "  $0 wordpress https://myblog.com"
            echo "  $0 bulk websites.txt"
            echo ""
            echo "Reports are saved to: $REPORTS_DIR"
            ;;
    esac
}

main "$@"

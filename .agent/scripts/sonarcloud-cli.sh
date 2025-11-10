#!/bin/bash

# 🔍 SonarCloud Analysis CLI Script
# Provides local SonarCloud analysis and issue reporting

set -euo pipefail

# Colors for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly BLUE='\033[0;34m'
readonly YELLOW='\033[1;33m'
readonly PURPLE='\033[0;35m'
readonly NC='\033[0m'

print_header() { echo -e "${PURPLE}🔍 $1${NC}"; }
print_info() { echo -e "${BLUE}ℹ️  $1${NC}"; }
print_success() { echo -e "${GREEN}✅ $1${NC}"; }
print_warning() { echo -e "${YELLOW}⚠️  $1${NC}"; }
print_error() { echo -e "${RED}❌ $1${NC}"; }

# SonarCloud project configuration
readonly SONAR_PROJECT_KEY="marcusquinn_ai-assisted-dev-ops"
readonly SONAR_ORGANIZATION="marcusquinn"
readonly SONAR_URL="https://sonarcloud.io"

# Check if SonarScanner is available
check_sonar_scanner() {
    if ! command -v sonar-scanner &> /dev/null; then
        print_warning "SonarScanner not found. Installing..."
        
        # Check if we're on macOS
        if [[ "$OSTYPE" == "darwin"* ]]; then
            if command -v brew &> /dev/null; then
                brew install sonar-scanner
            else
                print_error "Homebrew not found. Please install SonarScanner manually:"
                print_info "https://docs.sonarqube.org/latest/analysis/scan/sonarscanner/"
                exit 1
            fi
        else
            print_error "Please install SonarScanner manually:"
            print_info "https://docs.sonarqube.org/latest/analysis/scan/sonarscanner/"
            exit 1
        fi
    fi
}

# Run SonarCloud analysis
run_analysis() {
    print_header "Running SonarCloud Analysis"
    
    # Check for SONAR_TOKEN
    if [[ -z "${SONAR_TOKEN:-}" ]]; then
        print_error "SONAR_TOKEN environment variable not set"
        print_info "Get your token from: https://sonarcloud.io/account/security/"
        print_info "Then run: export SONAR_TOKEN=your_token_here"
        exit 1
    fi
    
    print_info "Project: $SONAR_PROJECT_KEY"
    print_info "Organization: $SONAR_ORGANIZATION"
    print_info "Running analysis..."
    
    # Run SonarScanner
    sonar-scanner \
        -Dsonar.projectKey="$SONAR_PROJECT_KEY" \
        -Dsonar.organization="$SONAR_ORGANIZATION" \
        -Dsonar.host.url="$SONAR_URL" \
        -Dsonar.login="$SONAR_TOKEN"
    
    print_success "SonarCloud analysis completed"
    print_info "View results at: $SONAR_URL/project/overview?id=$SONAR_PROJECT_KEY"
}

# Get project issues via API
get_issues() {
    print_header "Fetching SonarCloud Issues"
    
    if [[ -z "${SONAR_TOKEN:-}" ]]; then
        print_error "SONAR_TOKEN environment variable not set"
        exit 1
    fi
    
    local api_url="$SONAR_URL/api/issues/search"
    local params="componentKeys=$SONAR_PROJECT_KEY&resolved=false"
    
    print_info "Fetching issues from SonarCloud API..."
    
    # Use curl to fetch issues
    local response
    response=$(curl -s -u "$SONAR_TOKEN:" "$api_url?$params")
    
    if [[ $? -eq 0 ]]; then
        # Parse JSON response (basic parsing)
        local total_issues
        total_issues=$(echo "$response" | grep -o '"total":[0-9]*' | cut -d':' -f2 || echo "0")
        
        print_info "Total issues found: $total_issues"
        
        if [[ "$total_issues" -gt 0 ]]; then
            print_warning "Issues found in SonarCloud analysis"
            print_info "View details at: $SONAR_URL/project/issues?id=$SONAR_PROJECT_KEY"
        else
            print_success "No issues found in SonarCloud analysis"
        fi
    else
        print_error "Failed to fetch issues from SonarCloud API"
        exit 1
    fi
}

# Get project metrics
get_metrics() {
    print_header "Fetching SonarCloud Metrics"
    
    if [[ -z "${SONAR_TOKEN:-}" ]]; then
        print_error "SONAR_TOKEN environment variable not set"
        exit 1
    fi
    
    local api_url="$SONAR_URL/api/measures/component"
    local metrics="bugs,vulnerabilities,code_smells,coverage,duplicated_lines_density,reliability_rating,security_rating,sqale_rating"
    local params="component=$SONAR_PROJECT_KEY&metricKeys=$metrics"
    
    print_info "Fetching metrics from SonarCloud API..."
    
    local response
    response=$(curl -s -u "$SONAR_TOKEN:" "$api_url?$params")
    
    if [[ $? -eq 0 ]]; then
        print_success "Metrics retrieved successfully"
        print_info "View detailed metrics at: $SONAR_URL/project/overview?id=$SONAR_PROJECT_KEY"
        
        # Basic metric extraction (would need jq for proper JSON parsing)
        echo "$response" | grep -o '"metric":"[^"]*","value":"[^"]*"' | while read -r line; do
            local metric
            local value
            metric=$(echo "$line" | sed 's/.*"metric":"\([^"]*\)".*/\1/')
            value=$(echo "$line" | sed 's/.*"value":"\([^"]*\)".*/\1/')
            print_info "$metric: $value"
        done
    else
        print_error "Failed to fetch metrics from SonarCloud API"
        exit 1
    fi
}

# Main function
main() {
    case "${1:-help}" in
        "analyze"|"analysis")
            check_sonar_scanner
            run_analysis
            ;;
        "issues")
            get_issues
            ;;
        "metrics")
            get_metrics
            ;;
        "status")
            get_issues
            get_metrics
            ;;
        "help"|*)
            print_header "SonarCloud CLI Usage"
            echo "Usage: $0 [command]"
            echo ""
            echo "Commands:"
            echo "  analyze   - Run SonarCloud analysis"
            echo "  issues    - Fetch current issues"
            echo "  metrics   - Fetch project metrics"
            echo "  status    - Get issues and metrics"
            echo "  help      - Show this help"
            echo ""
            echo "Environment Variables:"
            echo "  SONAR_TOKEN - SonarCloud authentication token"
            echo ""
            echo "Get your token from: https://sonarcloud.io/account/security/"
            ;;
    esac
}

main "$@"

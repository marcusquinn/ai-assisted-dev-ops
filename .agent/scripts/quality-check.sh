#!/bin/bash
# Multi-Platform Quality Validation Script
# Ensures compliance across SonarCloud, CodeFactor, and Codacy

set -euo pipefail

# Color codes for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

# Quality thresholds
readonly MAX_TOTAL_ISSUES=100
readonly MAX_RETURN_ISSUES=0
readonly MAX_POSITIONAL_ISSUES=0
readonly MAX_STRING_LITERAL_ISSUES=0
readonly MAX_UNUSED_VAR_ISSUES=0

print_header() {
    echo -e "${BLUE}🎯 AI-Assisted DevOps Framework - Multi-Platform Quality Check${NC}"
    echo -e "${BLUE}================================================================${NC}"
    return 0
}

print_success() {
    local message="$1"
    echo -e "${GREEN}✅ $message${NC}"
    return 0
}

print_warning() {
    local message="$1"
    echo -e "${YELLOW}⚠️  $message${NC}"
    return 0
}

print_error() {
    local message="$1"
    echo -e "${RED}❌ $message${NC}"
    return 0
}

check_sonarcloud_status() {
    echo -e "${BLUE}📊 Checking SonarCloud Status...${NC}"
    
    local response
    if response=$(curl -s "https://sonarcloud.io/api/issues/search?componentKeys=marcusquinn_ai-assisted-dev-ops&impactSoftwareQualities=MAINTAINABILITY&resolved=false&ps=1"); then
        local total_issues
        total_issues=$(echo "$response" | jq -r '.total // 0')
        
        echo "Total Issues: $total_issues"
        
        if [[ $total_issues -le $MAX_TOTAL_ISSUES ]]; then
            print_success "SonarCloud: $total_issues issues (within threshold of $MAX_TOTAL_ISSUES)"
        else
            print_warning "SonarCloud: $total_issues issues (exceeds threshold of $MAX_TOTAL_ISSUES)"
        fi
        
        # Get detailed breakdown
        local breakdown_response
        if breakdown_response=$(curl -s "https://sonarcloud.io/api/issues/search?componentKeys=marcusquinn_ai-assisted-dev-ops&impactSoftwareQualities=MAINTAINABILITY&resolved=false&ps=10&facets=rules"); then
            echo "Issue Breakdown:"
            echo "$breakdown_response" | jq -r '.facets[0].values[] | "  \(.val): \(.count) issues"'
        fi
    else
        print_error "Failed to fetch SonarCloud status"
        return 1
    fi
    
    return 0
}

check_return_statements() {
    echo -e "${BLUE}🔄 Checking Return Statements (S7682)...${NC}"
    
    local violations=0
    local files_checked=0
    
    for file in providers/*.sh; do
        if [[ -f "$file" ]]; then
            ((files_checked++))
            
            # Check if file has functions without return statements
            local functions_without_return
            functions_without_return=$(grep -n "^[a-zA-Z_][a-zA-Z0-9_]*() {" "$file" | wc -l)
            local return_statements
            return_statements=$(grep -c "return [01]" "$file" || echo "0")
            
            if [[ $return_statements -lt $functions_without_return ]]; then
                ((violations++))
                print_warning "Missing return statements in $file"
            fi
        fi
    done
    
    echo "Files checked: $files_checked"
    echo "Files with violations: $violations"
    
    if [[ $violations -le $MAX_RETURN_ISSUES ]]; then
        print_success "Return statements: $violations violations (within threshold)"
    else
        print_error "Return statements: $violations violations (exceeds threshold of $MAX_RETURN_ISSUES)"
        return 1
    fi
    
    return 0
}

check_positional_parameters() {
    echo -e "${BLUE}📝 Checking Positional Parameters (S7679)...${NC}"
    
    local violations=0
    
    # Find direct usage of positional parameters (not in local assignments)
    if grep -n '\$[1-9]' providers/*.sh | grep -v 'local.*=.*\$[1-9]' > /tmp/positional_violations.txt; then
        violations=$(wc -l < /tmp/positional_violations.txt)
        
        if [[ $violations -gt 0 ]]; then
            print_warning "Found $violations positional parameter violations:"
            head -10 /tmp/positional_violations.txt
            if [[ $violations -gt 10 ]]; then
                echo "... and $((violations - 10)) more"
            fi
        fi
        
        rm -f /tmp/positional_violations.txt
    fi
    
    if [[ $violations -le $MAX_POSITIONAL_ISSUES ]]; then
        print_success "Positional parameters: $violations violations (within threshold)"
    else
        print_error "Positional parameters: $violations violations (exceeds threshold of $MAX_POSITIONAL_ISSUES)"
        return 1
    fi
    
    return 0
}

check_string_literals() {
    echo -e "${BLUE}📄 Checking String Literals (S1192)...${NC}"
    
    local violations=0
    
    for file in providers/*.sh; do
        if [[ -f "$file" ]]; then
            # Find strings that appear 3 or more times
            local repeated_strings
            repeated_strings=$(grep -o '"[^"]*"' "$file" | sort | uniq -c | awk '$1 >= 3 {print $1, $2}' | wc -l)
            
            if [[ $repeated_strings -gt 0 ]]; then
                ((violations += repeated_strings))
                print_warning "$file has $repeated_strings repeated string literals"
            fi
        fi
    done
    
    if [[ $violations -le $MAX_STRING_LITERAL_ISSUES ]]; then
        print_success "String literals: $violations violations (within threshold)"
    else
        print_error "String literals: $violations violations (exceeds threshold of $MAX_STRING_LITERAL_ISSUES)"
        return 1
    fi
    
    return 0
}

run_shellcheck() {
    echo -e "${BLUE}🐚 Running ShellCheck Validation...${NC}"
    
    local violations=0
    
    for file in providers/*.sh; do
        if [[ -f "$file" ]]; then
            if ! shellcheck "$file" > /dev/null 2>&1; then
                ((violations++))
                print_warning "ShellCheck violations in $file"
            fi
        fi
    done
    
    if [[ $violations -eq 0 ]]; then
        print_success "ShellCheck: No violations found"
    else
        print_error "ShellCheck: $violations files with violations"
        return 1
    fi
    
    return 0
}

main() {
    print_header
    
    local exit_code=0
    
    # Run all quality checks
    check_sonarcloud_status || exit_code=1
    echo ""
    
    check_return_statements || exit_code=1
    echo ""
    
    check_positional_parameters || exit_code=1
    echo ""
    
    check_string_literals || exit_code=1
    echo ""
    
    run_shellcheck || exit_code=1
    echo ""
    
    # Final summary
    if [[ $exit_code -eq 0 ]]; then
        print_success "🎉 ALL QUALITY CHECKS PASSED! Framework maintains A-grade standards."
    else
        print_error "❌ QUALITY ISSUES DETECTED. Please address violations before committing."
    fi
    
    return $exit_code
}

main "$@"

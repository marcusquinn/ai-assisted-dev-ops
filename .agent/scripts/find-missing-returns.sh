#!/bin/bash

# Find Functions Missing Return Statements
# Identify functions that need return statements for S7682 compliance
#
# Author: AI DevOps Framework
# Version: 1.0.0

# Colors for output
readonly BLUE='\033[0;34m'
readonly RED='\033[0;31m'
readonly NC='\033[0m'

print_info() {
    echo -e "${BLUE}ℹ️  $1${NC}"
}

print_error() {
    echo -e "${RED}❌ $1${NC}"
}

# Find functions missing return statements in a file
find_missing_returns_in_file() {
    local file="$1"

    print_info "Analyzing: $file"
    
    # Extract function definitions and check for return statements
    awk '
    BEGIN {
        in_function = 0
        function_name = ""
        function_content = ""
        brace_count = 0
    }
    
    # Function start
    /^[a-zA-Z_][a-zA-Z0-9_]*\(\)[[:space:]]*\{/ {
        if (in_function) {
            # Previous function ended without proper closing
            if (function_content !~ /return[[:space:]]+[0-9]+/ && 
                function_content !~ /return[[:space:]]*$/ &&
                function_content !~ /exit[[:space:]]+[0-9]+/) {
                print "Missing return: " function_name
            }
        }
        
        in_function = 1
        function_name = $1
        gsub(/\(\).*/, "", function_name)
        function_content = ""
        brace_count = 1
        next
    }
    
    # Inside function
    in_function == 1 {
        function_content = function_content "\n" $0
        
        # Count braces
        brace_count += gsub(/\{/, "&")
        brace_count -= gsub(/\}/, "&")
        
        # Function ends
        if (brace_count == 0) {
            if (function_content !~ /return[[:space:]]+[0-9]+/ && 
                function_content !~ /return[[:space:]]*$/ &&
                function_content !~ /exit[[:space:]]+[0-9]+/) {
                print "Missing return: " function_name
            }
            in_function = 0
            function_name = ""
            function_content = ""
        }
    }
    
    END {
        # Handle case where file ends while in function
        if (in_function && function_content !~ /return[[:space:]]+[0-9]+/ && 
            function_content !~ /return[[:space:]]*$/ &&
            function_content !~ /exit[[:space:]]+[0-9]+/) {
            print "Missing return: " function_name
        }
    }
    ' "$file"
}

# Main execution
main() {
    local target="${1:-.}"
    
    if [[ -f "$target" && "$target" == *.sh ]]; then
        find_missing_returns_in_file "$target"
    elif [[ -d "$target" ]]; then
        find "$target" -name "*.sh" -type f | while read -r file; do
            find_missing_returns_in_file "$file"
        done
    else
        print_error "Invalid target: $target"
        return 1
    fi
    return 0
}

main "$@"

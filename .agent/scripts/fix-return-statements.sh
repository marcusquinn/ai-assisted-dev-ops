#!/bin/bash

# Fix Missing Return Statements (S7682)
# Add explicit return statements to all functions
#
# Author: AI DevOps Framework
# Version: 1.0.0

# Colors for output
readonly GREEN='\033[0;32m'
readonly BLUE='\033[0;34m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m'

print_success() {
    echo -e "${GREEN}✅ $1${NC}"
}

print_info() {
    echo -e "${BLUE}ℹ️  $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

# Fix return statements in a file
fix_return_statements_in_file() {
    local file="$1"
    local temp_file
    temp_file=$(mktemp)
    local changes_made=0
    
    print_info "Processing: $file"
    
    # Create backup
    cp "$file" "${file}.backup"
    
    # Use awk to process the file and add return statements
    awk '
    BEGIN {
        in_function = 0
        function_name = ""
        brace_count = 0
        function_lines = ""
    }
    
    # Detect function start
    /^[a-zA-Z_][a-zA-Z0-9_]*\(\)[[:space:]]*\{/ {
        in_function = 1
        function_name = $1
        gsub(/\(\).*/, "", function_name)
        brace_count = 1
        print $0
        next
    }
    
    # Track braces when in function
    in_function == 1 {
        # Count opening braces
        gsub(/\{/, "&", $0)
        brace_count += gsub(/\{/, "&", $0)
        
        # Count closing braces
        gsub(/\}/, "&", $0)
        closing_braces = gsub(/\}/, "&", $0)
        brace_count -= closing_braces
        
        # Check if this line ends the function
        if (brace_count == 0 && closing_braces > 0) {
            # Check if previous line has return statement
            if (prev_line !~ /return[[:space:]]+[0-9]+[[:space:]]*$/ && 
                prev_line !~ /return[[:space:]]*$/ &&
                prev_line !~ /exit[[:space:]]+[0-9]+/) {
                # Add return statement before closing brace
                if ($0 ~ /^[[:space:]]*\}[[:space:]]*$/) {
                    print "    return 0"
                    print $0
                } else {
                    # Line has content before closing brace
                    line_without_brace = $0
                    gsub(/\}[[:space:]]*$/, "", line_without_brace)
                    if (line_without_brace != "") {
                        print line_without_brace
                        print "    return 0"
                        print "}"
                    } else {
                        print "    return 0"
                        print $0
                    }
                }
            } else {
                print $0
            }
            in_function = 0
            function_name = ""
        } else {
            print $0
        }
        prev_line = $0
        next
    }
    
    # Regular lines outside functions
    {
        print $0
        prev_line = $0
    }
    ' "$file" > "$temp_file"
    
    # Check if changes were made
    if ! cmp -s "$file" "$temp_file"; then
        mv "$temp_file" "$file"
        changes_made=1
        
        # Count functions that were fixed
        local functions_fixed
        functions_fixed=$(diff "${file}.backup" "$file" | grep -c "^> *return 0" || echo "0")
        
        print_success "Fixed $functions_fixed return statements in: $file"
        rm "${file}.backup"
        return 0
    else
        rm "$temp_file"
        rm "${file}.backup"
        print_info "No return statement fixes needed in: $file"
        return 1
    fi
}

# Main execution
main() {
    local target="${1:-.}"
    
    print_info "Fixing missing return statements (S7682)..."
    
    local files_fixed=0
    local files_processed=0
    
    if [[ -f "$target" && "$target" == *.sh ]]; then
        # Single file
        ((files_processed++))
        if fix_return_statements_in_file "$target"; then
            ((files_fixed++))
        fi
    elif [[ -d "$target" ]]; then
        # Directory
        find "$target" -name "*.sh" -type f | while read -r file; do
            ((files_processed++))
            if fix_return_statements_in_file "$file"; then
                ((files_fixed++))
            fi
        done
    else
        print_warning "Invalid target: $target"
        return 1
    fi
    
    print_success "Summary: $files_fixed/$files_processed files fixed"
}

main "$@"

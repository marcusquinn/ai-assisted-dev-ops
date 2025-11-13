#!/bin/bash

# Add Missing Return Statements
# Systematically add return 0 to functions missing explicit returns
#
# Author: AI DevOps Framework
# Version: 1.0.0

# Colors for output
readonly GREEN='\033[0;32m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

print_success() {
    echo -e "${GREEN}✅ $1${NC}"
    return 0
}

print_info() {
    echo -e "${BLUE}ℹ️  $1${NC}"
    return 0
}

# Add return statements to functions missing them
add_returns_to_file() {
    local file="$1"
    local temp_file
    temp_file=$(mktemp)
    local changes_made=0
    
    print_info "Processing: $file"
    
    # Create backup
    cp "$file" "${file}.backup"
    
    # Process file line by line
    local in_function=0
    local brace_count=0
    local function_has_return=0
    
    while IFS= read -r line; do
        # Detect function start
        if [[ $line =~ ^[a-zA-Z_][a-zA-Z0-9_]*\(\)[[:space:]]*\{ ]]; then
            in_function=1
            brace_count=1
            function_has_return=0
            echo "$line" >> "$temp_file"
            continue
        fi
        
        if [[ $in_function -eq 1 ]]; then
            # Count braces
            local open_braces
            open_braces=$(echo "$line" | grep -o '{' | wc -l)
            local close_braces
            close_braces=$(echo "$line" | grep -o '}' | wc -l)
            
            brace_count=$((brace_count + open_braces - close_braces))
            
            # Check for return statements
            if [[ $line =~ return[[:space:]]*[0-9]*[[:space:]]*$ ]] || [[ $line =~ exit[[:space:]]+[0-9]+ ]]; then
                function_has_return=1
            fi
            
            # Function ends
            if [[ $brace_count -eq 0 ]]; then
                # Add return if missing
                if [[ $function_has_return -eq 0 ]]; then
                    # Check if line is just closing brace
                    if [[ "$line" == *"}"* ]] && [[ "$line" != *[a-zA-Z0-9]* ]]; then
                        echo "    return 0" >> "$temp_file"
                        echo "$line" >> "$temp_file"
                    else
                        # Line has content before brace
                        echo "${line%\}}" >> "$temp_file"
                        echo "    return 0" >> "$temp_file"
                        echo "}" >> "$temp_file"
                    fi
                    changes_made=1
                else
                    echo "$line" >> "$temp_file"
                fi
                in_function=0
            else
                echo "$line" >> "$temp_file"
            fi
        else
            echo "$line" >> "$temp_file"
        fi
    done < "$file"
    
    # Replace original file if changes were made
    if [[ $changes_made -eq 1 ]]; then
        mv "$temp_file" "$file"
        print_success "Added return statements to: $file"
        rm "${file}.backup"
        return 0
    else
        rm "$temp_file"
        mv "${file}.backup" "$file"
        print_info "No return statements needed in: $file"
        return 1
    fi
}

# Main execution
main() {
    local target="${1:-.}"
    
    print_info "Adding missing return statements..."
    
    local files_fixed=0
    local files_processed=0
    
    if [[ -f "$target" && "$target" == *.sh ]]; then
        ((files_processed++))
        if add_returns_to_file "$target"; then
            ((files_fixed++))
        fi
    elif [[ -d "$target" ]]; then
        find "$target" -name "*.sh" -type f | while read -r file; do
            ((files_processed++))
            if add_returns_to_file "$file"; then
                ((files_fixed++))
            fi
        done
    else
        print_info "Invalid target: $target"
        return 1
    fi
    
    print_success "Summary: $files_fixed/$files_processed files fixed"
    return 0
}

main "$@"

#!/bin/bash

# String Literals Fix Script
# Identify and fix repeated string literals for SonarCloud S1192 compliance
#
# Usage: ./fix-string-literals.sh [file|directory]
#
# Author: AI DevOps Framework
# Version: 1.0.0
# License: MIT

# Colors for output
readonly GREEN='\033[0;32m'
readonly BLUE='\033[0;34m'
readonly YELLOW='\033[1;33m'
readonly RED='\033[0;31m'
readonly PURPLE='\033[0;35m'
readonly NC='\033[0m' # No Color

# Print functions
print_success() {
    local message="$1"
    echo -e "${GREEN}✅ $message${NC}"
    return 0
}

print_info() {
    local message="$1"
    echo -e "${BLUE}ℹ️  $message${NC}"
    return 0
}

print_warning() {
    local message="$1"
    echo -e "${YELLOW}⚠️  $message${NC}"
    return 0
}

print_error() {
    local message="$1"
    echo -e "${RED}❌ $message${NC}" >&2
    return 0
}

print_header() {
    local message="$1"
    echo -e "${PURPLE}🔧 $message${NC}"
    return 0
}

# Find repeated string literals in a file
find_repeated_strings() {
    local file="$1"
    local min_length="${2:-10}"
    local min_occurrences="${3:-3}"
    
    print_info "Analyzing string literals in: $file"
    
    # Extract string literals and count occurrences
    grep -o '"[^"]\{'"$min_length"',\}"' "$file" | \
    sort | uniq -c | \
    awk -v min="$min_occurrences" '$1 >= min {print $1, $0}' | \
    sort -nr
    return 0
}

# Find repeated strings across all shell files
analyze_repeated_strings() {
    local target_dir="${1:-.}"
    
    print_header "Analyzing Repeated String Literals"
    
    local temp_file
    temp_file=$(mktemp)
    
    # Find all shell files and extract string literals
    find "$target_dir" -name "*.sh" -type f | while read -r file; do
        grep -o '"[^"]\{10,\}"' "$file" 2>/dev/null | sed "s|^|$file: |"
    done > "$temp_file"
    
    # Count occurrences of each string
    print_info "Most repeated string literals (10+ chars, 3+ occurrences):"
    echo ""
    
    cut -d':' -f2- "$temp_file" | \
    sort | uniq -c | \
    awk '$1 >= 3 {print $1, $0}' | \
    sort -nr | head -20
    
    rm "$temp_file"
    return 0
}

# Create constants for repeated strings in a file
create_string_constants() {
    local file="$1"
    local backup_file="${file}.string-backup"
    
    print_info "Creating string constants for: $file"
    
    # Create backup
    cp "$file" "$backup_file"
    
    # Common repeated strings that should be constants
    local -A string_constants=(
        ['"AI DevOps Framework"']='readonly FRAMEWORK_NAME="AI DevOps Framework"'
        ['"https://github.com/marcusquinn/aidevops"']='readonly FRAMEWORK_REPO="https://github.com/marcusquinn/aidevops"'
        ['"Configuration file not found"']='readonly ERROR_CONFIG_NOT_FOUND="Configuration file not found"'
        ['"Command not found"']='readonly ERROR_COMMAND_NOT_FOUND="Command not found"'
        ['"Invalid option"']='readonly ERROR_INVALID_OPTION="Invalid option"'
        ['"Operation completed successfully"']='readonly SUCCESS_OPERATION_COMPLETE="Operation completed successfully"'
        ['"Please install"']='readonly ERROR_PLEASE_INSTALL="Please install"'
        ['"Not found"']='readonly ERROR_NOT_FOUND="Not found"'
        ['"Failed to"']='readonly ERROR_FAILED_TO="Failed to"'
        ['"Unable to"']='readonly ERROR_UNABLE_TO="Unable to"'
    )
    
    local temp_file
    temp_file=$(mktemp)
    local constants_added=0
    local replacements_made=0
    
    # Check if file already has constants section
    if ! grep -q "# String constants" "$file"; then
        # Add constants section after the header
        awk '
        /^# Colors for output/ || /^readonly.*=/ {
            if (!constants_added) {
                print ""
                print "# String constants"
                constants_added = 1
            }
        }
        { print }
        ' "$file" > "$temp_file"
        mv "$temp_file" "$file"
    fi
    
    # Add constants and replace strings
    for string_literal in "${!string_constants[@]}"; do
        local constant_def="${string_constants[$string_literal]}"
        local constant_name
        constant_name=$(echo "$constant_def" | sed 's/.*readonly \([^=]*\)=.*/\1/')
        
        # Check if string appears multiple times
        local count
        count=$(grep -c "$string_literal" "$file" 2>/dev/null || echo "0")
        
        if [[ $count -ge 3 ]]; then
            # Add constant definition if not already present
            if ! grep -q "$constant_name" "$file"; then
                sed -i "/# String constants/a\\$constant_def" "$file"
                ((constants_added++))
            fi
            
            # Replace string literals with constant reference
            sed -i "s|$string_literal|\$$constant_name|g" "$file"
            ((replacements_made += count))
            print_success "Replaced $count occurrences of $string_literal with \$$constant_name"
        fi
    done
    
    if [[ $constants_added -gt 0 || $replacements_made -gt 0 ]]; then
        print_success "Added $constants_added constants, made $replacements_made replacements in $file"
        return 0
    else
        # Remove backup if no changes
        rm "$backup_file"
        print_info "No repeated strings found requiring constants in $file"
        return 1
    fi
}

# Process directory for string literal fixes
process_directory_strings() {
    local target_dir="${1:-.}"

    print_header "Processing String Literals in Directory: $target_dir"

    local files_processed=0
    local files_modified=0

    find "$target_dir" -name "*.sh" -type f | while read -r file; do
        ((files_processed++))
        if create_string_constants "$file"; then
            ((files_modified++))
        fi
    done

    print_info "Summary: $files_modified/$files_processed files modified"
    return 0
}

# Show help message
show_help() {
    print_header "String Literals Fix Help"
    echo ""
    echo "Usage: $0 [command] [target]"
    echo ""
    echo "Commands:"
    echo "  analyze [dir]        - Analyze repeated string literals (default)"
    echo "  fix [file|dir]       - Fix repeated strings with constants"
    echo "  help                 - Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0 analyze ."
    echo "  $0 fix providers/"
    echo "  $0 fix setup.sh"
    echo ""
    echo "This script addresses SonarCloud S1192 violations by:"
    echo "  • Identifying repeated string literals (10+ chars, 3+ occurrences)"
    echo "  • Creating readonly constants for common strings"
    echo "  • Replacing string literals with constant references"
    echo "  • Reducing code duplication and improving maintainability"
    echo ""
    echo "Common patterns addressed:"
    echo "  • Error messages"
    echo "  • Success messages"
    echo "  • Framework names and URLs"
    echo "  • Configuration messages"
    echo ""
    echo "Backup files (.string-backup) are created for all modified files."
    return 0
}

# Main function
main() {
    local command="${1:-analyze}"
    local target="${2:-.}"

    # Handle case where first argument is a file/directory
    if [[ -f "$1" || -d "$1" ]]; then
        command="analyze"
        target="$1"
    fi

    case "$command" in
        "analyze")
            if [[ -d "$target" ]]; then
                analyze_repeated_strings "$target"
            elif [[ -f "$target" ]]; then
                find_repeated_strings "$target"
            else
                print_error "Target not found: $target"
                return 1
            fi
            ;;
        "fix")
            if [[ -f "$target" && "$target" == *.sh ]]; then
                create_string_constants "$target"
            elif [[ -d "$target" ]]; then
                process_directory_strings "$target"
            else
                print_error "Invalid target for fixes: $target"
                return 1
            fi
            ;;
        "help"|"--help"|"-h")
            show_help
            ;;
        *)
            print_error "Unknown command: $command"
            show_help
            return 1
            ;;
    esac
}

# Execute main function with all arguments
main "$@"

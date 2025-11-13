#!/bin/bash

# Common String Literals Fix Script
# Fix the most common repeated string literals for SonarCloud S1192 compliance
#
# Usage: ./fix-common-strings.sh [file|directory]
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
}

print_info() {
    local message="$1"
    echo -e "${BLUE}ℹ️  $message${NC}"
}

print_warning() {
    local message="$1"
    echo -e "${YELLOW}⚠️  $message${NC}"
}

print_error() {
    local message="$1"
    echo -e "${RED}❌ $message${NC}" >&2
}

print_header() {
    local message="$1"
    echo -e "${PURPLE}🔧 $message${NC}"
}

# Fix common repeated strings in a file
fix_common_strings_in_file() {
    local file="$1"
    local backup_file="${file}.backup"
    local temp_file
    temp_file=$(mktemp)
    local changes_made=0
    
    print_info "Processing: $file"
    
    # Create backup
    cp "$file" "$backup_file"
    
    # Check if file needs constants section
    local needs_constants=false
    
    # Check for common repeated strings
    if grep -q "Content-Type: application/json" "$file" && \
       [[ $(grep -c "Content-Type: application/json" "$file") -ge 3 ]]; then
        needs_constants=true
    fi
    
    if grep -q "Authorization: Bearer" "$file" && \
       [[ $(grep -c "Authorization: Bearer" "$file") -ge 3 ]]; then
        needs_constants=true
    fi
    
    if grep -q "Unknown command:" "$file" && \
       [[ $(grep -c "Unknown command:" "$file") -ge 3 ]]; then
        needs_constants=true
    fi
    
    if [[ "$needs_constants" == "true" ]]; then
        # Add constants section if not present
        if ! grep -q "# HTTP constants" "$file" && ! grep -q "# Common constants" "$file"; then
            # Find a good place to insert constants (after colors, before functions)
            awk '
            BEGIN { constants_added = 0 }
            /^readonly.*NC=/ && !constants_added {
                print $0
                print ""
                print "# Common constants"
                constants_added = 1
                next
            }
            /^# Print functions/ && !constants_added {
                print "# Common constants"
                print ""
                print $0
                constants_added = 1
                next
            }
            { print }
            ' "$file" > "$temp_file"
            mv "$temp_file" "$file"
        fi
        
        # Add specific constants and replace strings
        
        # Content-Type header
        local content_type_count
        content_type_count=$(grep -c "Content-Type: application/json" "$file" 2>/dev/null || echo "0")
        if [[ $content_type_count -ge 3 ]]; then
            if ! grep -q "readonly.*CONTENT_TYPE_JSON" "$file"; then
                sed -i '/# Common constants/a readonly CONTENT_TYPE_JSON="Content-Type: application/json"' "$file"
                changes_made=1
            fi
            sed -i 's/"Content-Type: application\/json"/$CONTENT_TYPE_JSON/g' "$file"
            print_success "Replaced $content_type_count occurrences of Content-Type header"
        fi
        
        # Authorization header pattern
        local auth_count
        auth_count=$(grep -c "Authorization: Bearer" "$file" 2>/dev/null || echo "0")
        if [[ "$auth_count" -ge 3 ]]; then
            if ! grep -q "readonly.*AUTH_BEARER_PREFIX" "$file"; then
                sed -i '/# Common constants/a readonly AUTH_BEARER_PREFIX="Authorization: Bearer"' "$file"
                changes_made=1
            fi
            sed -i 's|"Authorization: Bearer \([^"]*\)"|"$AUTH_BEARER_PREFIX \1"|g' "$file"
            print_success "Replaced $auth_count occurrences of Authorization header"
        fi

        # Unknown command message
        local unknown_cmd_count
        unknown_cmd_count=$(grep -c "Unknown command:" "$file" 2>/dev/null || echo "0")
        if [[ "$unknown_cmd_count" -ge 3 ]]; then
            if ! grep -q "readonly.*ERROR_UNKNOWN_COMMAND" "$file"; then
                sed -i '/# Common constants/a readonly ERROR_UNKNOWN_COMMAND="Unknown command:"' "$file"
                changes_made=1
            fi
            sed -i 's|"Unknown command: \$command"|"$ERROR_UNKNOWN_COMMAND $command"|g' "$file"
            print_success "Replaced $unknown_cmd_count occurrences of unknown command message"
        fi
        
        # Help message
        local help_count
        help_count=$(grep -c "help.*- Show this help message" "$file" 2>/dev/null || echo "0")
        if [[ "$help_count" -ge 3 ]]; then
            if ! grep -q "readonly.*HELP_MESSAGE" "$file"; then
                sed -i '/# Common constants/a readonly HELP_MESSAGE_SUFFIX="- Show this help message"' "$file"
                changes_made=1
            fi
            sed -i 's|"  help[[:space:]]*- Show this help message"|"  help                 - $HELP_MESSAGE_SUFFIX"|g' "$file"
            print_success "Replaced $help_count occurrences of help message"
        fi

        # Usage message
        local usage_count
        usage_count=$(grep -c "Usage: \\$0" "$file" 2>/dev/null || echo "0")
        if [[ "$usage_count" -ge 3 ]]; then
            if ! grep -q "readonly.*USAGE_PREFIX" "$file"; then
                sed -i '/# Common constants/a readonly USAGE_PREFIX="Usage:"' "$file"
                changes_made=1
            fi
            sed -i 's|"Usage: \\$0"|"$USAGE_PREFIX $0"|g' "$file"
            print_success "Replaced $usage_count occurrences of usage message"
        fi
    fi
    
    if [[ $changes_made -gt 0 ]]; then
        print_success "Fixed repeated strings in: $file"
        return 0
    else
        rm "$backup_file"
        print_info "No repeated strings requiring fixes in: $file"
        return 1
    fi
}

# Process directory for common string fixes
process_directory_common_strings() {
    local target_dir="${1:-.}"

    print_header "Fixing Common Repeated Strings in: $target_dir"

    local files_processed=0
    local files_modified=0

    find "$target_dir" -name "*.sh" -type f | while read -r file; do
        ((files_processed++))
        if fix_common_strings_in_file "$file"; then
            ((files_modified++))
        fi
    done

    print_info "Summary: $files_modified/$files_processed files modified"
}

# Show help message
show_help() {
    print_header "Common String Literals Fix Help"
    echo ""
    echo "Usage: $0 [target]"
    echo ""
    echo "Examples:"
    echo "  $0 providers/"
    echo "  $0 setup.sh"
    echo "  $0 ."
    echo ""
    echo "This script addresses SonarCloud S1192 violations by fixing the most common repeated strings:"
    echo ""
    echo "Fixed patterns:"
    echo "  • \"Content-Type: application/json\" → \$CONTENT_TYPE_JSON"
    echo "  • \"Authorization: Bearer\" → \$AUTH_BEARER_PREFIX"
    echo "  • \"Unknown command:\" → \$ERROR_UNKNOWN_COMMAND"
    echo "  • \"Usage: \\$0\" → \\$USAGE_PREFIX"
    echo "  • Help messages → \$HELP_MESSAGE_SUFFIX"
    echo ""
    echo "Requirements:"
    echo "  • String must appear 3+ times in the same file"
    echo "  • Constants are added to existing or new constants section"
    echo "  • Backup files (.backup) are created for all modified files"
    echo ""
    echo "This targets the highest-impact repeated strings for maximum S1192 compliance improvement."
    return 0
}

# Main function
main() {
    local target="${1:-.}"

    if [[ "$target" == "help" || "$target" == "--help" || "$target" == "-h" ]]; then
        show_help
        return 0
    fi

    if [[ -f "$target" && "$target" == *.sh ]]; then
        fix_common_strings_in_file "$target"
    elif [[ -d "$target" ]]; then
        process_directory_common_strings "$target"
    else
        print_error "Invalid target: $target"
        print_info "Use: $0 help for usage information"
        return 1
    fi
}

# Execute main function with all arguments
main "$@"

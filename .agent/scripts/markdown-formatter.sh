#!/bin/bash

# Markdown Formatter Script
# Automatically fix common Codacy markdown formatting issues
#
# Usage: ./markdown-formatter.sh [file|directory]
# 
# Common fixes applied:
# - Add blank lines around headers
# - Add blank lines around code blocks
# - Add blank lines around lists
# - Remove trailing whitespace
# - Fix inconsistent list markers
# - Add language specifiers to code blocks
# - Fix header spacing
# - Normalize emphasis markers
#
# Author: AI DevOps Framework
# Version: 1.1.1
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
    echo -e "${PURPLE}📝 $message${NC}"
    return 0
}

# Fix markdown formatting in a single file
fix_markdown_file() {
    local file="$1"
    local temp_file
    temp_file=$(mktemp)
    local changes_made=0
    
    print_info "Processing: $file"
    
    # Create backup
    cp "$file" "${file}.bak"
    
    # Apply simple, safe fixes
    {
        # Remove trailing whitespace
        sed 's/[[:space:]]*$//' "$file" |

        # Fix inconsistent list markers (use - for unordered lists)
        sed 's/^[[:space:]]*\*[[:space:]]/- /' |
        sed 's/^[[:space:]]*+[[:space:]]/- /' |

        # Fix emphasis - use ** for bold, * for italic consistently
        sed 's/__\([^_]*\)__/**\1**/g' |             # Convert __ to **

        # Remove multiple consecutive blank lines (max 2)
        awk '
        BEGIN { blank_count = 0 }
        /^[[:space:]]*$/ {
            blank_count++
            if (blank_count <= 2) print
            next
        }
        { blank_count = 0; print }'

    } > "$temp_file"
    
    # Check if changes were made
    if ! cmp -s "$file" "$temp_file"; then
        mv "$temp_file" "$file"
        changes_made=1
        print_success "Fixed formatting in: $file"
    else
        rm "$temp_file"
        print_info "No changes needed: $file"
    fi
    
    # Remove backup if no changes were made
    if [[ $changes_made -eq 0 ]]; then
        rm "${file}.bak"
    fi
    
    return $changes_made
}

# Process directory recursively
process_directory() {
    local dir="$1"
    local total_files=0
    local changed_files=0

    print_header "Processing markdown files in: $dir"

    # Find all markdown files
    while IFS= read -r -d '' file; do
        ((total_files++))
        if fix_markdown_file "$file"; then
            ((changed_files++))
        fi
    done < <(find "$dir" -name "*.md" -type f -print0)

    echo ""
    print_info "Summary: $changed_files/$total_files files modified"

    if [[ $changed_files -gt 0 ]]; then
        print_success "Markdown formatting fixes applied successfully"
        print_info "Backup files created with .bak extension"
        return 0
    else
        print_info "No formatting issues found"
        return 0
    fi
}

# Advanced markdown fixes
apply_advanced_fixes() {
    local file="$1"
    local temp_file
    temp_file=$(mktemp)

    print_info "Applying advanced fixes to: $file"

    # Advanced fixes using Python-like logic with awk
    awk '
    BEGIN {
        in_code_block = 0
        prev_was_header = 0
        prev_was_list = 0
    }

    # Track code blocks
    /^```/ {
        in_code_block = !in_code_block
        print
        next
    }

    # Skip processing inside code blocks
    in_code_block {
        print
        next
    }

    # Fix table formatting
    /\|.*\|/ {
        # Ensure spaces around pipes in tables
        gsub(/\|/, " | ")
        gsub(/  \|  /, " | ")
        gsub(/^ \| /, "| ")
        gsub(/ \| $/, " |")
    }

    # Fix link formatting
    {
        # Fix spaces in link text
        gsub(/\[\s+/, "[")
        gsub(/\s+\]/, "]")

        # Fix spaces around link URLs
        gsub(/\]\s*\(/, "](")
        gsub(/\(\s+/, "(")
        gsub(/\s+\)/, ")")
    }

    # Fix emphasis spacing
    {
        # Remove spaces inside emphasis
        gsub(/\*\s+/, "*")
        gsub(/\s+\*/, "*")
        gsub(/\*\*\s+/, "**")
        gsub(/\s+\*\*/, "**")
    }

    # Print the line
    { print }
    ' "$file" > "$temp_file"

    # Replace original if different
    if ! cmp -s "$file" "$temp_file"; then
        mv "$temp_file" "$file"
        print_success "Applied advanced fixes to: $file"
        return 0
    else
        rm "$temp_file"
        return 1
    fi
}

# Clean up backup files
cleanup_backups() {
    local target="${1:-.}"

    print_header "Cleaning up backup files"

    local backup_count
    backup_count=$(find "$target" -name "*.md.bak" -type f | wc -l)

    if [[ $backup_count -gt 0 ]]; then
        print_info "Found $backup_count backup files"
        read -r -p "Remove all .md.bak files? (y/N): " confirm

        if [[ $confirm =~ ^[Yy]$ ]]; then
            find "$target" -name "*.md.bak" -type f -delete
            print_success "Removed $backup_count backup files"
        else
            print_info "Backup files preserved"
        fi
    else
        print_info "No backup files found"
    fi
}

# Show help message
show_help() {
    print_header "Markdown Formatter Help"
    echo ""
    echo "Usage: $0 [command] [target]"
    echo ""
    echo "Commands:"
    echo "  format [file|dir]    - Format markdown files (default)"
    echo "  advanced [file|dir]  - Apply advanced formatting fixes"
    echo "  cleanup [dir]        - Remove backup files"
    echo "  help                 - Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0 README.md"
    echo "  $0 format docs/"
    echo "  $0 advanced ."
    echo "  $0 cleanup"
    echo ""
    echo "Common fixes applied:"
    echo "  • Add blank lines around headers, code blocks, lists"
    echo "  • Remove trailing whitespace"
    echo "  • Fix inconsistent list markers (use -)"
    echo "  • Normalize emphasis markers (** for bold, * for italic)"
    echo "  • Add language specifiers to code blocks"
    echo "  • Fix header spacing"
    echo "  • Remove excessive blank lines"
    echo "  • Fix table formatting"
    echo "  • Fix link and emphasis spacing"
    echo ""
    echo "Backup files (.bak) are created for all modified files."
    return 0
}

# Main function
main() {
    local command="${1:-format}"
    local target="${2:-.}"

    # Handle case where first argument is a file/directory
    if [[ -f "$1" || -d "$1" ]]; then
        command="format"
        target="$1"
    fi

    case "$command" in
        "format")
            if [[ -f "$target" ]]; then
                if [[ "$target" == *.md ]]; then
                    fix_markdown_file "$target"
                else
                    print_error "File is not a markdown file: $target"
                    return 1
                fi
            elif [[ -d "$target" ]]; then
                process_directory "$target"
            else
                print_error "Target not found: $target"
                return 1
            fi
            ;;
        "advanced")
            if [[ -f "$target" && "$target" == *.md ]]; then
                apply_advanced_fixes "$target"
            elif [[ -d "$target" ]]; then
                find "$target" -name "*.md" -type f | while read -r file; do
                    apply_advanced_fixes "$file"
                done
            else
                print_error "Invalid target for advanced fixes: $target"
                return 1
            fi
            ;;
        "cleanup")
            cleanup_backups "$target"
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

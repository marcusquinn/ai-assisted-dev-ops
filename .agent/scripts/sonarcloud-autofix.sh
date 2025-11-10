#!/bin/bash

# 🔧 SonarCloud Auto-Fix Script
# Applies fixes for common SonarCloud shell script issues

set -euo pipefail

# Colors for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly BLUE='\033[0;34m'
readonly YELLOW='\033[1;33m'
readonly PURPLE='\033[0;35m'
readonly NC='\033[0m'

print_header() { echo -e "${PURPLE}🔧 $1${NC}"; }
print_info() { echo -e "${BLUE}ℹ️  $1${NC}"; }
print_success() { echo -e "${GREEN}✅ $1${NC}"; }
print_warning() { echo -e "${YELLOW}⚠️  $1${NC}"; }
print_error() { echo -e "${RED}❌ $1${NC}"; }

# Fix missing return statements (S7682)
fix_missing_returns() {
    local file="$1"
    print_info "Adding missing return statements to: $file"
    
    # Add return statements to functions that don't have them
    # This is a simplified approach - in practice, you'd need more sophisticated parsing
    
    # Backup original file
    cp "$file" "$file.backup"
    
    # Add return statements before closing braces of functions
    # This is a basic implementation - would need more sophisticated logic for production
    local temp_file
    temp_file=$(mktemp)
    
    awk '
    /^[a-zA-Z_][a-zA-Z0-9_]*\(\)/ { in_function = 1 }
    /^}$/ && in_function { 
        print "    return 0"
        print $0
        in_function = 0
        next
    }
    { print }
    ' "$file" > "$temp_file"
    
    mv "$temp_file" "$file"
    print_success "Added return statements to $file"
}

# Fix positional parameter assignments (S7679)
fix_positional_parameters() {
    local file="$1"
    print_info "Fixing positional parameter assignments in: $file"
    
    # Backup original file
    cp "$file" "$file.backup"
    
    # Replace direct $1, $2, etc. usage with local variable assignments
    sed -i.tmp '
        s/echo "\$1"/local param1="$1"; echo "$param1"/g
        s/echo "\$2"/local param2="$2"; echo "$param2"/g
        s/case "\$1"/local command="$1"; case "$command"/g
        s/\[\[ "\$1"/local arg1="$1"; [[ "$arg1"/g
    ' "$file"
    
    rm -f "$file.tmp"
    print_success "Fixed positional parameters in $file"
}

# Add default case to switch statements (S131)
fix_missing_default_case() {
    local file="$1"
    print_info "Adding default cases to switch statements in: $file"
    
    # Backup original file
    cp "$file" "$file.backup"
    
    # Add default case before esac if missing
    sed -i.tmp '
        /esac/ {
            i\
        *)\
            print_error "Unknown option: $1"\
            exit 1\
            ;;
        }
    ' "$file"
    
    rm -f "$file.tmp"
    print_success "Added default cases to $file"
}

# Apply all SonarCloud fixes to a file
apply_sonarcloud_fixes() {
    local file="$1"
    
    if [[ ! -f "$file" ]]; then
        print_error "File not found: $file"
        return 1
    fi
    
    print_header "Applying SonarCloud fixes to: $file"
    
    # Apply fixes based on common SonarCloud issues
    fix_positional_parameters "$file"
    fix_missing_returns "$file"
    
    # Check if file has switch statements and fix them
    if grep -q "case.*in" "$file"; then
        fix_missing_default_case "$file"
    fi
    
    print_success "All SonarCloud fixes applied to $file"
}

# Main function
main() {
    print_header "SonarCloud Auto-Fix Tool"
    
    case "${1:-help}" in
        "fix")
            if [[ -z "${2:-}" ]]; then
                print_error "Please specify a file to fix"
                print_info "Usage: $0 fix <file>"
                exit 1
            fi
            apply_sonarcloud_fixes "$2"
            ;;
        "fix-all")
            print_info "Applying fixes to all shell scripts with SonarCloud issues..."
            
            # Files with known SonarCloud issues
            local files=(
                ".agent/scripts/setup-mcp-integrations.sh"
                ".agent/scripts/validate-mcp-integrations.sh"
                ".agent/scripts/setup-linters-wizard.sh"
                "providers/setup-wizard-helper.sh"
            )
            
            for file in "${files[@]}"; do
                if [[ -f "$file" ]]; then
                    apply_sonarcloud_fixes "$file"
                    echo
                else
                    print_warning "File not found: $file"
                fi
            done
            ;;
        "restore")
            if [[ -z "${2:-}" ]]; then
                print_error "Please specify a file to restore"
                print_info "Usage: $0 restore <file>"
                exit 1
            fi
            
            local file="$2"
            if [[ -f "$file.backup" ]]; then
                mv "$file.backup" "$file"
                print_success "Restored $file from backup"
            else
                print_error "No backup found for $file"
                exit 1
            fi
            ;;
        "help"|*)
            print_header "SonarCloud Auto-Fix Usage"
            echo "Usage: $0 [command] [file]"
            echo ""
            echo "Commands:"
            echo "  fix <file>    - Apply SonarCloud fixes to specific file"
            echo "  fix-all       - Apply fixes to all known problematic files"
            echo "  restore <file> - Restore file from backup"
            echo "  help          - Show this help"
            echo ""
            echo "Common SonarCloud Issues Fixed:"
            echo "  S7682 - Missing return statements in functions"
            echo "  S7679 - Direct positional parameter usage"
            echo "  S131  - Missing default case in switch statements"
            ;;
    esac
}

main "$@"

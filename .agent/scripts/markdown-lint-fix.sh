#!/bin/bash

# Markdown Lint Fix Script
# Fix common Codacy markdown issues using markdownlint-cli
#
# Usage: ./markdown-lint-fix.sh [file|directory]
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
    echo -e "${PURPLE}📝 $message${NC}"
    return 0
}

# Check if markdownlint-cli is installed
check_markdownlint() {
    if command -v markdownlint &> /dev/null; then
        return 0
    else
        return 1
    fi
}

# Install markdownlint-cli
install_markdownlint() {
    print_header "Installing markdownlint-cli"
    
    if command -v npm &> /dev/null; then
        print_info "Installing markdownlint-cli via npm..."
        npm install -g markdownlint-cli
        
        if check_markdownlint; then
            print_success "markdownlint-cli installed successfully"
            return 0
        else
            print_error "Installation failed"
            return 1
        fi
    else
        print_error "npm not found. Please install Node.js and npm first."
        print_info "Visit: https://nodejs.org/"
        return 1
    fi
}

# Create markdownlint configuration
create_markdownlint_config() {
    local config_file=".markdownlint.json"
    
    if [[ -f "$config_file" ]]; then
        print_info "markdownlint config already exists: $config_file"
        return 0
    fi
    
    print_info "Creating markdownlint configuration: $config_file"
    
    cat > "$config_file" << 'EOF'
{
  "default": true,
  "MD013": {
    "line_length": 120,
    "code_blocks": false,
    "tables": false
  },
  "MD033": {
    "allowed_elements": ["br", "sub", "sup"]
  },
  "MD041": false,
  "MD046": {
    "style": "fenced"
  }
}
EOF
    
    if [[ -f "$config_file" ]]; then
        print_success "markdownlint configuration created"
        return 0
    else
        print_error "Failed to create configuration"
        return 1
    fi
}

# Fix markdown files using markdownlint
fix_markdown_with_markdownlint() {
    local target="$1"
    
    print_header "Fixing Markdown Issues with markdownlint"
    
    # Check if markdownlint is available
    if ! check_markdownlint; then
        print_warning "markdownlint-cli not found"
        read -r -p "Install markdownlint-cli? (y/N): " install_confirm
        
        if [[ $install_confirm =~ ^[Yy]$ ]]; then
            if ! install_markdownlint; then
                return 1
            fi
        else
            print_info "Skipping markdownlint fixes"
            return 0
        fi
    fi
    
    # Create config if it doesn't exist
    create_markdownlint_config
    
    # Run markdownlint with fix option
    if [[ -f "$target" ]]; then
        print_info "Fixing: $target"
        markdownlint --fix "$target"
        
        if markdownlint --fix "$target"; then
            print_success "Fixed markdown issues in: $target"
        else
            print_warning "Some issues may require manual fixing in: $target"
        fi
    elif [[ -d "$target" ]]; then
        print_info "Fixing all markdown files in: $target"
        markdownlint --fix "$target/**/*.md"
        
        if markdownlint --fix "$target"/*.md; then
            print_success "Fixed markdown issues in directory: $target"
        else
            print_warning "Some issues may require manual fixing"
        fi
    else
        print_error "Target not found: $target"
        return 1
    fi
    
    return 0
}

# Manual fixes for common Codacy issues
apply_manual_fixes() {
    local file="$1"
    local temp_file
    temp_file=$(mktemp)
    local changes_made=0
    
    print_info "Applying manual fixes to: $file"
    
    # Create backup
    cp "$file" "${file}.bak"
    
    # Apply manual fixes
    {
        # Remove trailing whitespace
        sed 's/[[:space:]]*$//' "$file" |
        
        # Fix list markers - use consistent dashes
        sed 's/^[[:space:]]*\*[[:space:]]/- /' |
        sed 's/^[[:space:]]*+[[:space:]]/- /' |
        
        # Fix emphasis markers - use ** for bold
        sed 's/__\([^_]*\)__/**\1**/g' |
        
        # Remove excessive blank lines (max 2 consecutive)
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
        print_success "Applied manual fixes to: $file"
    else
        rm "$temp_file"
        print_info "No manual fixes needed: $file"
    fi
    
    # Remove backup if no changes were made
    if [[ $changes_made -eq 0 ]]; then
        rm "${file}.bak"
    fi
    
    return $changes_made
}

# Show help message
show_help() {
    print_header "Markdown Lint Fix Help"
    echo ""
    echo "Usage: $0 [command] [target]"
    echo ""
    echo "Commands:"
    echo "  fix [file|dir]       - Fix markdown issues (default)"
    echo "  manual [file|dir]    - Apply manual fixes only"
    echo "  install              - Install markdownlint-cli"
    echo "  config               - Create markdownlint configuration"
    echo "  help                 - Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0 README.md"
    echo "  $0 fix docs/"
    echo "  $0 manual ."
    echo "  $0 install"
    echo ""
    echo "This script fixes common Codacy markdown formatting issues:"
    echo "  • Trailing whitespace"
    echo "  • Inconsistent list markers"
    echo "  • Inconsistent emphasis markers"
    echo "  • Excessive blank lines"
    echo "  • Line length issues"
    echo "  • Header formatting"
    echo ""
    echo "Requires: markdownlint-cli (will offer to install if missing)"
    return 0
}

# Main function
main() {
    local command="${1:-fix}"
    local target="${2:-.}"

    # Handle case where first argument is a file/directory
    if [[ -f "$1" || -d "$1" ]]; then
        command="fix"
        target="$1"
    fi

    case "$command" in
        "fix")
            fix_markdown_with_markdownlint "$target"
            ;;
        "manual")
            if [[ -f "$target" && "$target" == *.md ]]; then
                apply_manual_fixes "$target"
            elif [[ -d "$target" ]]; then
                find "$target" -name "*.md" -type f | while read -r file; do
                    apply_manual_fixes "$file"
                done
            else
                print_error "Invalid target: $target"
                return 1
            fi
            ;;
        "install")
            install_markdownlint
            ;;
        "config")
            create_markdownlint_config
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

#!/bin/bash

# Fix Content-Type String Literals
# Replace repeated "Content-Type: application/json" with constants
#
# Author: AI DevOps Framework
# Version: 1.0.0

# Colors for output
readonly GREEN='\033[0;32m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

print_success() {
    echo -e "${GREEN}✅ $1${NC}"
}

print_info() {
    echo -e "${BLUE}ℹ️  $1${NC}"
}

# Fix Content-Type in a file
fix_content_type_in_file() {
    local file="$1"
    local count
    count=$(grep -c "Content-Type: application/json" "$file" 2>/dev/null || echo "0")
    
    if [[ $count -ge 3 ]]; then
        print_info "Fixing $count occurrences in: $file"
        
        # Add constant if not present
        if ! grep -q "CONTENT_TYPE_JSON" "$file"; then
            # Find where to insert the constant (after colors, before functions)
            if grep -q "NC=.*No Color" "$file"; then
                sed -i '' '/NC=.*No Color/a\
\
# Common constants\
readonly CONTENT_TYPE_JSON="Content-Type: application/json"
' "$file"
            elif grep -q "readonly.*NC=" "$file"; then
                sed -i '' '/readonly.*NC=/a\
\
# Common constants\
readonly CONTENT_TYPE_JSON="Content-Type: application/json"
' "$file"
            fi
        fi
        
        # Replace occurrences
        sed -i '' 's/"Content-Type: application\/json"/$CONTENT_TYPE_JSON/g' "$file"
        
        # Verify
        local new_count
        new_count=$(grep -c "Content-Type: application/json" "$file" 2>/dev/null || echo "0")
        local const_count
        const_count=$(grep -c "CONTENT_TYPE_JSON" "$file" 2>/dev/null || echo "0")
        
        if [[ $new_count -eq 0 && $const_count -gt 0 ]]; then
            print_success "Fixed $file: $count → 0 literals, $const_count constant usages"
            return 0
        else
            print_info "Partial fix in $file: $new_count literals remaining"
            return 1
        fi
    else
        print_info "Skipping $file: only $count occurrences (need 3+)"
        return 1
    fi
}

# Main execution
main() {
    print_info "Fixing Content-Type string literals in provider files..."
    
    local files_fixed=0
    local files_processed=0
    
    for file in providers/*.sh; do
        if [[ -f "$file" ]]; then
            ((files_processed++))
            if fix_content_type_in_file "$file"; then
                ((files_fixed++))
            fi
        fi
    done
    
    print_success "Summary: $files_fixed/$files_processed files fixed"
}

main "$@"

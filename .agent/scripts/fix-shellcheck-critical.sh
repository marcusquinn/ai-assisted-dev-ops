#!/bin/bash

# Fix Critical ShellCheck Issues
# Address SC2155 (declare and assign separately) and SC2181 (exit code checking)
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

# Fix SC2155 issues in a file
fix_sc2155_in_file() {
    local file="$1"
    local temp_file
    temp_file=$(mktemp)
    local changes_made=0
    
    # Create backup
    cp "$file" "${file}.backup"
    
    # Fix common SC2155 patterns
    awk '
    {
        line = $0
        
        # Pattern: local var=$(command)
        if (match(line, /^[[:space:]]*local[[:space:]]+([a-zA-Z_][a-zA-Z0-9_]*)[[:space:]]*=[[:space:]]*\$\(/, arr)) {
            var_name = substr(line, arr[1, "start"], arr[1, "length"])
            assignment = substr(line, index(line, "=") + 1)
            
            # Split into declaration and assignment
            indent = substr(line, 1, match(line, /[^[:space:]]/) - 1)
            print indent "local " var_name
            print indent var_name "=" assignment
            next
        }
        
        # Pattern: local var="$(command)"
        if (match(line, /^[[:space:]]*local[[:space:]]+([a-zA-Z_][a-zA-Z0-9_]*)[[:space:]]*=[[:space:]]*"[[:space:]]*\$\(/, arr)) {
            var_name = substr(line, arr[1, "start"], arr[1, "length"])
            assignment = substr(line, index(line, "=") + 1)
            
            # Split into declaration and assignment
            indent = substr(line, 1, match(line, /[^[:space:]]/) - 1)
            print indent "local " var_name
            print indent var_name "=" assignment
            next
        }
        
        print line
    }
    ' "$file" > "$temp_file"
    
    # Check if changes were made
    if ! cmp -s "$file" "$temp_file"; then
        mv "$temp_file" "$file"
        changes_made=1
    else
        rm "$temp_file"
    fi
    
    return $changes_made
}

# Fix SC2181 issues in a file
fix_sc2181_in_file() {
    local file="$1"
    local temp_file
    temp_file=$(mktemp)
    local changes_made=0
    
    # Fix common SC2181 patterns
    sed '
        # Pattern: if [[ $? -eq 0 ]]
        s/if \[\[ \$? -eq 0 \]\]/if [[ $? -eq 0 ]]/g
        s/if \[ \$? -eq 0 \]/if [ $? -eq 0 ]/g
        
        # Pattern: if [[ $? -ne 0 ]]
        s/if \[\[ \$? -ne 0 \]\]/if [[ $? -ne 0 ]]/g
        s/if \[ \$? -ne 0 \]/if [ $? -ne 0 ]/g
    ' "$file" > "$temp_file"
    
    # Check if changes were made
    if ! cmp -s "$file" "$temp_file"; then
        mv "$temp_file" "$file"
        changes_made=1
    else
        rm "$temp_file"
    fi
    
    return $changes_made
}

# Fix critical ShellCheck issues in a file
fix_critical_shellcheck_in_file() {
    local file="$1"
    local sc2155_fixed=0
    local sc2181_fixed=0
    
    print_info "Processing: $file"
    
    # Count issues before fixing
    local sc2155_before
    sc2155_before=$(shellcheck "$file" 2>&1 | grep -c "SC2155" || echo "0")
    local sc2181_before
    sc2181_before=$(shellcheck "$file" 2>&1 | grep -c "SC2181" || echo "0")
    
    if [[ $sc2155_before -gt 0 ]]; then
        if fix_sc2155_in_file "$file"; then
            sc2155_fixed=1
            print_success "Fixed SC2155 issues in $file"
        fi
    fi
    
    if [[ $sc2181_before -gt 0 ]]; then
        if fix_sc2181_in_file "$file"; then
            sc2181_fixed=1
            print_success "Fixed SC2181 issues in $file"
        fi
    fi
    
    # Count issues after fixing
    local sc2155_after
    sc2155_after=$(shellcheck "$file" 2>&1 | grep -c "SC2155" || echo "0")
    local sc2181_after
    sc2181_after=$(shellcheck "$file" 2>&1 | grep -c "SC2181" || echo "0")
    
    if [[ $sc2155_fixed -eq 1 || $sc2181_fixed -eq 1 ]]; then
        print_success "Fixed critical ShellCheck issues in: $file"
        print_info "SC2155: $sc2155_before → $sc2155_after, SC2181: $sc2181_before → $sc2181_after"
        
        # Remove backup if successful
        rm -f "${file}.backup"
        return 0
    else
        # Restore from backup if no changes
        if [[ -f "${file}.backup" ]]; then
            mv "${file}.backup" "$file"
        fi
        print_info "No critical ShellCheck issues fixed in: $file"
        return 1
    fi
}

# Main execution
main() {
    print_info "Fixing critical ShellCheck issues (SC2155, SC2181) in provider files..."
    
    local files_fixed=0
    local files_processed=0
    
    for file in providers/*.sh; do
        if [[ -f "$file" ]]; then
            ((files_processed++))
            if fix_critical_shellcheck_in_file "$file"; then
                ((files_fixed++))
            fi
        fi
    done
    
    print_success "Summary: $files_fixed/$files_processed files fixed"
}

main "$@"

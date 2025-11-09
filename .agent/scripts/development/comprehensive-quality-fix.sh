#!/bin/bash

# Comprehensive script to fix remaining SonarCloud issues
# Targets: S7679 (positional parameters), S7682 (return statements), S1192 (string literals)

cd providers

echo "🚀 Starting comprehensive quality fix..."

# Function to fix misplaced return statements
fix_misplaced_returns() {
    local file="$1"
    echo "Fixing misplaced returns in $file..."
    
    # Remove return statements that are not at the end of functions
    sed -i '/^    return 0$/d' "$file"
    
    # Add return statements to function endings that need them
    # This is a more targeted approach based on SonarCloud line numbers
    return 0
}

# Function to replace string literals with constants
replace_string_literals() {
    local file="$1"
    echo "Replacing string literals in $file..."
    
    case "$file" in
        "mainwp-helper.sh")
            # Replace remaining "Site ID is required" occurrences
            sed -i 's/"Site ID is required"/"$ERROR_SITE_ID_REQUIRED"/g' "$file"
            sed -i 's/"At least one site ID is required"/"$ERROR_AT_LEAST_ONE_SITE_ID"/g' "$file"
            ;;
        "code-audit-helper.sh")
            # Already done in previous commit
            ;;
        "dns-helper.sh")
            # Replace remaining cloudflare occurrences in case statements
            sed -i 's/"namecheap"/"$PROVIDER_NAMECHEAP"/g' "$file"
            sed -i 's/"route53"/"$PROVIDER_ROUTE53"/g' "$file"
            ;;
        "git-platforms-helper.sh")
            # Replace remaining platform occurrences
            sed -i 's/"gitea"/"$PLATFORM_GITEA"/g' "$file"
            ;;
    esac
    return 0
}

# Function to add return statements to functions that need them
add_missing_returns() {
    local file="$1"
    echo "Adding missing return statements to $file..."
    
    # Find function endings and add return statements
    # This targets the specific line numbers from SonarCloud
    case "$file" in
        "closte-helper.sh")
            # Lines 134, 249
            sed -i '133a\    return 0' "$file"
            sed -i '248a\    return 0' "$file"
            ;;
        "cloudron-helper.sh")
            # Lines 74, 202
            sed -i '73a\    return 0' "$file"
            sed -i '201a\    return 0' "$file"
            ;;
        "coolify-helper.sh")
            # Line 236
            sed -i '235a\    return 0' "$file"
            ;;
        "dns-helper.sh")
            # Lines 95, 259
            sed -i '94a\    return 0' "$file"
            sed -i '258a\    return 0' "$file"
            ;;
   
        *)
            echo "Unknown option: $1"
            return 1
            ;; esac
    return 0
}

# Process each file
for file in *.sh; do
    if [[ -f "$file" ]]; then
        echo "Processing $file..."
        
        # Fix misplaced returns first
        fix_misplaced_returns "$file"
        
        # Replace string literals
        replace_string_literals "$file"
        
        # Add missing return statements
        add_missing_returns "$file"
    fi
done

echo "✅ Comprehensive quality fix completed!"

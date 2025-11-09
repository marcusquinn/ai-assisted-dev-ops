#!/bin/bash

# Mass fix script to add return statements to all functions that need them
# Based on SonarCloud S7682 analysis

cd providers

# Files and their function ending line numbers that need return statements
declare -A FILES_LINES=(
    ["101domains-helper.sh"]="522"
    ["closte-helper.sh"]="105 133 247"
    ["cloudron-helper.sh"]="73 103 129 161 177 191"
    ["code-audit-helper.sh"]="153 167 188 202 223 237 258 272 293 332 384 411"
    ["coolify-helper.sh"]="235"
    ["dns-helper.sh"]="90 254"
    ["git-platforms-helper.sh"]="156 202 217 247 261 344 388 425"
    ["hetzner-helper.sh"]="112 157"
    ["hostinger-helper.sh"]="72 110 139"
    ["localhost-helper.sh"]="166 189 266 328 460"
    ["mainwp-helper.sh"]="40 55 64 84 115 126 140 160 180 200 220 241 262 286 310 330 350 371 391 412 432 483 512"
    ["ses-helper.sh"]="338 359 383 408 442"
)

# Function to add return statement before closing brace
add_return_statement() {
    local file="$1"
    local line_num="$2"
    
    # Check if line before closing brace already has return
    local prev_line=$((line_num - 1))
    if ! sed -n "${prev_line}p" "$file" | grep -q "return"; then
        echo "Adding return statement to $file at line $line_num"
        # Insert return statement before the closing brace
        sed -i "${prev_line}a\\    return 0" "$file"
    else
        echo "Return statement already exists in $file at line $line_num"
    fi
}

# Process each file
for file in "${!FILES_LINES[@]}"; do
    if [[ -f "$file" ]]; then
        echo "Processing $file..."
        lines="${FILES_LINES[$file]}"
        
        # Process lines in reverse order to avoid line number shifts
        for line_num in $(echo $lines | tr ' ' '\n' | sort -nr); do
            add_return_statement "$file" "$line_num"
        done
    else
        echo "File $file not found"
    fi
done

echo "Mass return statement fix completed!"

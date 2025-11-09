#!/bin/bash

# Efficient script to add return statements to functions that need them
# Based on SonarCloud S7682 analysis

cd providers

# Function to add return statement to a specific line
add_return_to_line() {
    local file="$1"
    local line_num="$2"
    
    if [[ -f "$file" ]]; then
        # Check if line before closing brace already has return
        local prev_line=$((line_num - 1))
        local line_content=$(sed -n "${prev_line}p" "$file")
        
        if [[ ! "$line_content" =~ return ]]; then
            echo "Adding return statement to $file at line $line_num"
            # Use perl for more reliable in-place editing
            perl -i -pe "if (\$. == $prev_line) { \$_ .= \"    return 0\n\" }" "$file"
        else
            echo "Return statement already exists in $file at line $line_num"
        fi
    else
        echo "File $file not found"
    fi
}

# Process mainwp-helper.sh (most issues)
echo "Processing mainwp-helper.sh..."
for line in 64 84 115 126 140 160 180 200 220 241 262 286 310 330 350 371 391 412 432 483 512; do
    add_return_to_line "mainwp-helper.sh" "$line"
done

# Process code-audit-helper.sh (13+ issues)
echo "Processing code-audit-helper.sh..."
for line in 188 202 223 237 258 272 293 332 384 411; do
    add_return_to_line "code-audit-helper.sh" "$line"
done

# Process localhost-helper.sh (remaining issues)
echo "Processing localhost-helper.sh..."
for line in 166 189 266 328 460; do
    add_return_to_line "localhost-helper.sh" "$line"
done

# Process cloudron-helper.sh (remaining issues)
echo "Processing cloudron-helper.sh..."
for line in 103 129 161 177 191; do
    add_return_to_line "cloudron-helper.sh" "$line"
done

# Process remaining files
echo "Processing git-platforms-helper.sh..."
for line in 156 202 217 247 261 344 388 425; do
    add_return_to_line "git-platforms-helper.sh" "$line"
done

echo "Processing ses-helper.sh..."
for line in 338 359 383 408 442; do
    add_return_to_line "ses-helper.sh" "$line"
done

echo "Processing hetzner-helper.sh..."
for line in 112 157; do
    add_return_to_line "hetzner-helper.sh" "$line"
done

echo "Processing hostinger-helper.sh..."
for line in 72 110 139; do
    add_return_to_line "hostinger-helper.sh" "$line"
done

echo "Processing closte-helper.sh..."
for line in 105 133 247; do
    add_return_to_line "closte-helper.sh" "$line"
done

echo "Processing coolify-helper.sh..."
for line in 235; do
    add_return_to_line "coolify-helper.sh" "$line"
done

echo "Processing dns-helper.sh..."
for line in 90 254; do
    add_return_to_line "dns-helper.sh" "$line"
done

echo "Efficient return statement fix completed!"

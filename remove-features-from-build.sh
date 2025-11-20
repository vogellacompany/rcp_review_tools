#!/bin/bash

# ---------------------------------------------------------------------------
# Purpose: Recursively find pom.xml files and comment out modules ending in .feature
# Compatibility: Universal (Linux, Windows Git Bash, WSL, macOS)
# ---------------------------------------------------------------------------

SEARCH_DIR="${1:-.}"
APPLY_CHANGES=false

# Handle arguments
if [[ "$2" == "--apply" ]] || [[ "$1" == "--apply" ]]; then
    if [[ "$1" == "--apply" ]]; then SEARCH_DIR="."; fi
    APPLY_CHANGES=true
fi

echo "Target: $SEARCH_DIR"
if [ "$APPLY_CHANGES" = true ]; then
    echo "Mode:   ACTIVE (Modifying files)"
else
    echo "Mode:   DRY-RUN (No changes will be made)"
fi
echo "----------------------------------------------------"

# Find all pom.xml files
find "$SEARCH_DIR" -type f -name "pom.xml" -print0 | while IFS= read -r -d '' pom_file; do

    # Create a safe temp file
    temp_file="${pom_file}.tmp"
    
    # AWK Logic:
    # 1. sub(/\r$/, ""): Strip Windows line endings (CR) so logic works on Linux reading Windows files.
    # 2. Detect module lines.
    # 3. Capture whitespace to maintain XML indentation.
    awk '{
        # Normalize line ending (remove \r if present) to handle Windows files on Linux
        sub(/\r$/, "")
        
        if ($0 ~ /<module>.*\.feature<\/module>/) {
            # Only comment if not already commented
            if ($0 !~ /^[[:space:]]*<!--/) {
                # Capture the indentation (whitespace at start of line)
                match($0, /^[[:space:]]*/)
                indent = substr($0, RSTART, RLENGTH)
                
                # Capture the actual content (the tag)
                content = substr($0, RSTART + RLENGTH)
                
                # Print: Indentation + Comment Start + Content + Comment End
                printf "%s<!-- %s -->\n", indent, content
            } else {
                print $0
            }
        } else {
            print $0
        }
    }' "$pom_file" > "$temp_file"

    # Compare: If temp file differs from original, we found a match
    if ! cmp -s "$pom_file" "$temp_file"; then
        if [ "$APPLY_CHANGES" = true ]; then
            mv "$temp_file" "$pom_file"
            echo "[MODIFIED] $pom_file"
        else
            rm "$temp_file"
            echo "[WOULD MODIFY] $pom_file"
        fi
    else
        rm "$temp_file"
    fi
done

echo "----------------------------------------------------"
echo "Complete."
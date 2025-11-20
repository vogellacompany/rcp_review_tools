#!/bin/bash

# ---------------------------------------------------------------------------
# Purpose: Scan for binary artifacts (images, docs, archives), count them, 
#          and calculate total size.
# Compatibility: Universal (Linux, Windows Git Bash, WSL)
# Strategy: Single-pass scan using 'find' | 'xargs du' | 'awk' for speed.
# ---------------------------------------------------------------------------

SEARCH_DIR="${1:-.}"

# Define the extensions we care about (Regex format, pipe-separated)
# Grouped by category for clarity
IMG_EXT="png|jpg|jpeg|gif|bmp|ico|tif|tiff|svg"
DOC_EXT="pdf|doc|docx|xls|xlsx|ppt|pptx|odt|ods|txt|rtf"
ARCHIVE_EXT="zip|jar|war|ear|tar|gz|7z|rar"
BIN_EXT="dll|so|exe|class|dmp|hprof|iso"

# Combine them
TARGET_EXTENSIONS="^($IMG_EXT|$DOC_EXT|$ARCHIVE_EXT|$BIN_EXT)$"

echo "Scanning for artifacts in: $SEARCH_DIR"
echo "Analyzing file sizes... (This uses 'du -k' for kilobytes)"
echo "----------------------------------------------------"

# 1. Find all files (-print0 handles spaces in filenames)
# 2. Pipe to 'du -k' to get size in KB and filepath
# 3. Pipe to awk to aggregate
find "$SEARCH_DIR" -type f -print0 | xargs -0 du -k | awk -v target="$TARGET_EXTENSIONS" '
    BEGIN {
        IGNORECASE = 1  # Handle .PNG and .png identically
        total_count = 0
        total_size = 0
        
        # Format string for the table
        fmt = "%-10s | %-10s | %-15s\n"
        printf fmt, "EXTENSION", "COUNT", "SIZE (Approx)"
        print "-------------------------------------------"
    }

    {
        # $1 is Size (KB)
        # $2...$NF is the Path (potentially containing spaces)
        
        size_kb = $1
        
        # Extract extension:
        # We split the entire line by "."
        # The last element is usually the extension
        n = split($0, parts, ".")
        
        if (n > 1) {
            # Clean the extension (remove potential trailing whitespace/newlines)
            ext = parts[n]
            gsub(/[[:space:]]*$/, "", ext) # Trim end
            
            # Check if it matches our target list
            if (ext ~ target) {
                ext = tolower(ext) # Normalize to lowercase for grouping
                
                counts[ext]++
                sizes[ext] += size_kb
                
                total_count++
                total_size += size_kb
            }
        }
    }

    END {
        # Sort and Print
        # Note: standard awk doesnt sort associative arrays easily, 
        # so we pipe the output to "sort" later, or just print unsorted here.
        # For simplicity in this specific script, we iterate blindly.
        
        for (e in counts) {
            formatted_size = format_size(sizes[e])
            printf fmt, "." e, counts[e], formatted_size
        }
        
        print "-------------------------------------------"
        printf fmt, "TOTAL", total_count, format_size(total_size)
    }

    # Helper function to convert KB to human readable
    function format_size(kb) {
        if (kb > 1048576) {
            return sprintf("%.2f GB", kb / 1048576)
        } else if (kb > 1024) {
            return sprintf("%.2f MB", kb / 1024)
        } else {
            return sprintf("%d KB", kb)
        }
    }
' | sort -k3 -h -r # Sort by size (column 3), human numeric reverse

echo "----------------------------------------------------"
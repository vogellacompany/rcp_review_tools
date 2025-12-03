#!/bin/bash

# ---------------------------------------------------------------------------
# Purpose: Scan for binary artifacts (images, docs, archives), count them, 
#          and calculate total size.
# Compatibility: Universal (Linux, Windows Git Bash, WSL)
# Strategy: Optimized scan using 'find' filters | 'du' | 'awk' for speed.
# ---------------------------------------------------------------------------

SEARCH_DIR="${1:-.}"

# Define the extensions we care about (Regex format, pipe-separated)
IMG_EXT="png|jpg|jpeg|gif|bmp|ico|tif|tiff|svg"
DOC_EXT="pdf|doc|docx|xls|xlsx|ppt|pptx|odt|ods|txt|rtf"
ARCHIVE_EXT="zip|jar|war|ear|tar|gz|7z|rar"
BIN_EXT="dll|so|exe|class|dmp|hprof|iso"

# Combine for awk verification
TARGET_EXTENSIONS="^($IMG_EXT|$DOC_EXT|$ARCHIVE_EXT|$BIN_EXT)$"

# ---------------------------------------------------------------------------
# OPTIMIZATION: Build 'find' arguments to filter files at the filesystem level
# This prevents 'du' from running on thousands of irrelevant source files.
# ---------------------------------------------------------------------------

# Convert pipe-separated list to space-separated for looping
ALL_EXTS_STR="$IMG_EXT|$DOC_EXT|$ARCHIVE_EXT|$BIN_EXT"
ALL_EXTS_LIST=${ALL_EXTS_STR//|/ }

FIND_ARGS=()
FIRST_EXT=true

for ext in $ALL_EXTS_LIST; do
    if [ "$FIRST_EXT" = true ]; then
        FIRST_EXT=false
    else
        FIND_ARGS+=("-o")
    fi
    # Case-insensitive name match
    FIND_ARGS+=("-iname" "*.$ext")
done

echo "Scanning for artifacts in: $SEARCH_DIR"
echo "Analyzing file sizes... (Optimized with find filters)"
echo "----------------------------------------------------"

# Create a temp file to hold the scan results so we can process it twice
SCAN_RESULTS=$(mktemp)
trap 'rm -f "$SCAN_RESULTS"' EXIT

# 1. Find only files matching our extensions using generated args
# 2. Use -exec du -k {} + to calculate sizes and store in temp file
find "$SEARCH_DIR" -type f \( "${FIND_ARGS[@]}" \) -exec du -k {} + 2>/dev/null > "$SCAN_RESULTS"


# --- PART 1: Summary Table ---
awk -v target="$TARGET_EXTENSIONS" '
    BEGIN {
        IGNORECASE = 1
        total_count = 0
        total_size = 0
        
        fmt = "% -10s | % -10s | % -15s\n"
        printf fmt, "EXTENSION", "COUNT", "SIZE (Approx)"
        print "-------------------------------------------"
    }

    {
        # $1 is Size (KB)
        # $2 is Path (this is what du -k returns by default)
        size_kb = $1
        filepath = $2 
        
        # Extract extension from filename
        split(filepath, parts, ".")
        # Use full path to get extension correctly, and convert to lowercase
        ext = tolower(parts[length(parts)])
        
        if (ext ~ target) {
            counts[ext]++
            sizes[ext] += size_kb
            total_count++
            total_size += size_kb
        }
    }

    END {
        for (e in counts) {
            formatted_size = format_size(sizes[e])
            printf fmt, "." e, counts[e], formatted_size
        }
        print "-------------------------------------------"
        printf fmt, "TOTAL", total_count, format_size(total_size)
    }

    function format_size(kb) {
        if (kb > 1048576) {
            return sprintf("%.2f GB", kb / 1048576)
        } else if (kb > 1024) {
            return sprintf("%.2f MB", kb / 1024)
        } else {
            return sprintf("%d KB", kb)
        }
    }
' "$SCAN_RESULTS" | sort -k3 -h -r

echo "----------------------------------------------------"

# --- PART 2: Top 20 Largest Files ---
echo ""
echo "TOP 20 LARGEST FILES:"
echo "----------------------------------------------------"
sort -nr -k1 "$SCAN_RESULTS" | head -n 20 | awk '
    function format_size(kb) {
        if (kb > 1048576) {
            return sprintf("%.2f GB", kb / 1048576)
        } else if (kb > 1024) {
            return sprintf("%.2f MB", kb / 1024)
        } else {
            return sprintf("%d KB", kb)
        }
    }
    {
        size_kb = $1
        # Reconstruct the full path from $2 onwards, preserving spaces
        filepath = substr($0, index($0,$2))
        
        printf "% -10s | %s\n", format_size(size_kb), filepath
    }
'
echo "----------------------------------------------------"

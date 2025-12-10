#!/usr/bin/env bash
# Recursively search all MANIFEST.MF files for usage of a certain library.
# Finds entries in Require-Bundle and Import-Package headers.
# Works on Linux and Windows (Git Bash, WSL, Cygwin).

set -euo pipefail

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

usage() {
    echo "Usage: $0 <search-directory> <library-name>"
    echo ""
    echo "Arguments:"
    echo "  search-directory   Root directory to search for MANIFEST.MF files."
    echo "  library-name       String to search for (e.g., 'riena', 'org.eclipse.ui')."
    echo ""
    echo "Example:"
    echo "  $0 . riena"
    exit 1
}

if [ $# -lt 2 ]; then
    usage
fi

SEARCH_DIR="$1"
SEARCH_TERM="$2"

if [ ! -d "$SEARCH_DIR" ]; then
    echo -e "${RED}Error: Search directory '$SEARCH_DIR' not found.${NC}"
    exit 1
fi

echo -e "${BLUE}Searching for usage of '${YELLOW}$SEARCH_TERM${BLUE}' in MANIFEST.MF files under '${YELLOW}$SEARCH_DIR${BLUE}'...${NC}"
echo ""

# Temp file for results
TEMP_RESULTS=$(mktemp)
trap "rm -f $TEMP_RESULTS" EXIT

# Find and process MANIFEST.MF files
# Using process substitution or temp file to handle while loop scope
find "$SEARCH_DIR" -type f -iname "MANIFEST.MF" -print0 | while IFS= read -r -d '' manifest_file; do
    
    # We use awk to parse the multi-line headers and check for the search term.
    # It prints the match type and the matching line content.
    awk -v term="$SEARCH_TERM" '
        BEGIN { IGNORECASE = 1 }
        
        # Function to process a full header value (which might be comma-separated)
        function check_entries(header_name, content) {
            # Split by comma. This is a heuristic and might split version ranges like "[1.0, 2.0)".
            # But for finding library usage, it is usually sufficient and provides cleaner output than printing the whole block.
            n = split(content, parts, ",")
            for (i = 1; i <= n; i++) {
                part = parts[i]
                # Strip leading/trailing whitespace
                gsub(/^ +| +$/, "", part)
                
                if (index(tolower(part), tolower(term)) > 0) {
                    print header_name "|" part
                }
            }
        }

        /^Require-Bundle:/ {
            if (in_header) { check_entries(current_header, current_value); }
            in_header = 1
            current_header = "Require-Bundle"
            current_value = $0
            sub(/^Require-Bundle: */, "", current_value)
            next
        }
        
        /^Import-Package:/ {
            if (in_header) { check_entries(current_header, current_value); }
            in_header = 1
            current_header = "Import-Package"
            current_value = $0
            sub(/^Import-Package: */, "", current_value)
            next
        }
        
        # Continuation line (starts with space)
        /^ / && in_header {
            sub(/^ +/, "", $0)
            current_value = current_value $0
            next
        }
        
        # New header start (not continuation, not the ones we want)
        /^[A-Za-z0-9-]+:/ {
            if (in_header) { check_entries(current_header, current_value); }
            in_header = 0
            next
        }
        
        END {
            if (in_header) { check_entries(current_header, current_value); }
        }
    ' "$manifest_file" > "$TEMP_RESULTS"

    if [ -s "$TEMP_RESULTS" ]; then
        echo -e "${CYAN}File:${NC} $manifest_file"
        while IFS='|' read -r type content; do
            # Format the output nicely
            
            # Basic highlighting of the term using grep
            echo -e "  ${GREEN}$type:${NC} $content" | grep --color=always -i "$SEARCH_TERM" || echo -e "  ${GREEN}$type:${NC} $content"
        done < "$TEMP_RESULTS"
        echo ""
    fi

done

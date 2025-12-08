#!/bin/bash

# Script to find projects containing 'visibility:=reexport' in their MANIFEST.MF
# and list the re-exported bundles.
# Usage: ./find_reexport.sh [directory]
# If directory is not provided, it defaults to the current directory.

# Target directory
SEARCH_DIR="${1:-.}"

# Check if directory exists
if [ ! -d "$SEARCH_DIR" ]; then
    echo "Error: Directory '$SEARCH_DIR' not found."
    exit 1
fi

echo "Searching in '$SEARCH_DIR'..."

# Find MANIFEST.MF files and process them
find "$SEARCH_DIR" -type f -name "MANIFEST.MF" -print0 | while IFS= read -r -d '' manifest_file; do
    # Extract re-exported bundles using Perl to handle MANIFEST.MF intricacies
    # 1. Slurp file (-0777) to read entire content.
    # 2. Unfold wrapped lines: Replace CRLF+Space or LF+Space with nothing.
    # 3. Find Require-Bundle header.
    # 4. Split values by comma, ignoring commas inside quotes (for version ranges).
    # 5. Check for visibility:=reexport and extract the bundle name (first token).
    
    reexports=$(perl -0777 -ne '
        s/\r?\n //g; # Unfold wrapped lines
        
        if (/^Require-Bundle:\s*(.*)/m) {
            $val = $1;
            # Remove any trailing carriage returns from capture
            $val =~ s/\r//g;
            
            # Split by comma, lookahead ensures we do not split inside even number of quotes
            @parts = split /,(?=(?:[^"]*"[^"]*")*[^"]*$)/, $val;
            
            foreach $part (@parts) {
                if ($part =~ /visibility:=reexport/) {
                    # Extract symbolic name (first token before semicolon or end)
                    if ($part =~ /^\s*([a-zA-Z0-9_.-]+)/) {
                        print "$1\n";
                    }
                }
            }
        }
    ' "$manifest_file")
    
    if [ -n "$reexports" ]; then
        meta_inf_dir=$(dirname "$manifest_file")
        project_dir=$(dirname "$meta_inf_dir")
        project_name=$(basename "$project_dir")
        
        echo "$reexports" | while read -r bundle; do
            if [ -n "$bundle" ]; then
                echo "Project: $project_name, Re-export: $bundle"
            fi
        done
    fi
done

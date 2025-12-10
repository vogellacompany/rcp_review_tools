#!/bin/bash
set -euo pipefail

# Script to analyze Maven Tycho build artifacts and their sizes.
# Usage: ./analyze_tycho_artifact_sizes.sh [directory]

SEARCH_DIR="${1:-.}"

if [ ! -d "$SEARCH_DIR" ]; then
    echo "Error: Directory '$SEARCH_DIR' does not exist."
    exit 1
fi

echo "Analyzing Tycho build artifacts in: $SEARCH_DIR"
echo ""
printf "%-60s %-50s %s\n" "Project" "Artifact" "Size"
printf "%s\n" "----------------------------------------------------------------------------------------------------------------------------------"

# Find all 'target' directories which usually contain the build output
find "$SEARCH_DIR" -type d -name "target" | sort | while read -r target_dir; do
    project_path=$(dirname "$target_dir")
    project_name=$(basename "$project_path")
    
    # Look for common artifact extensions in the target directory.
    # We look in target/ and target/products/ (common for Tycho products)
    # We ignore standard maven metadata files or intermediate folders if possible.
    
    find "$target_dir" -maxdepth 2 -type f \( -name "*.jar" -o -name "*.zip" -o -name "*.tar.gz" -o -name "*.war" \) | sort | while read -r artifact_path; do
        artifact_name=$(basename "$artifact_path")
        
        # Optional: Filter out sources jars if you only care about binary size
        # if [[ "$artifact_name" == *"-sources.jar" ]]; then continue; fi

        # Get human readable size
        size=$(du -h "$artifact_path" | awk '{print $1}')
        
        printf "%-60s %-50s %s\n" "$project_name" "$artifact_name" "$size"
    done
done

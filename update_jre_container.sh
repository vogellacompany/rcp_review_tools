#!/bin/bash
set -euo pipefail

# This script searches for .classpath files and replaces the JRE_CONTAINER entry 
# that has module attributes with a standard JavaSE-17 entry.

# Default values
SEARCH_DIR="."
DRY_RUN="false"

# Parse arguments
for arg in "$@"; do
    case "$arg" in
        --dry-run)
            DRY_RUN="true"
            ;;
        -*)
            echo "Error: Unknown option '$arg'" >&2
            exit 1
            ;;
        *)
            if [ -d "$arg" ]; then
                SEARCH_DIR="$arg"
            else
                echo "Error: Directory '$arg' does not exist." >&2
                exit 1
            fi
            ;;
    esac
done

echo "Searching in: $SEARCH_DIR"
if [ "$DRY_RUN" = "true" ]; then
    echo "Running in DRY RUN mode. No files will be modified."
fi

find "$SEARCH_DIR" -name ".classpath" -type f -print0 | while IFS= read -r -d '' file; do
    # Check if the file needs updating (search for the pattern)
    if perl -0777 -ne 'exit 0 if /<classpathentry kind="con" path="org.eclipse.jdt.launching.JRE_CONTAINER">\s*<attributes>\s*<attribute name="module" value="true"\/>\s*<\/attributes>\s*<\/classpathentry>/; exit 1' "$file"; then
        if [ "$DRY_RUN" = "true" ]; then
            echo "Would update: $file"
        else
            echo "Updating: $file"
            # Use perl for multi-line replacement, capturing leading indentation
            perl -i -0777 -pe 's/^([ \t]*)<classpathentry kind="con" path="org.eclipse.jdt.launching.JRE_CONTAINER">\s*<attributes>\s*<attribute name="module" value="true"\/>\s*<\/attributes>\s*<\/classpathentry>/$1<classpathentry kind="con" path="org.eclipse.jdt.launching.JRE_CONTAINER\/org.eclipse.jdt.internal.debug.ui.launcher.StandardVMType\/JavaSE-17"\/>/gm' "$file"
        fi
    fi
done

echo "Done."

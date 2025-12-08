#!/bin/bash

# Output file for the consolidated report
REPORT_FILE="jar_dependencies_report.md"
TEMP_JAR_LIST=$(mktemp)
FOUND_LIB_DIRS=$(mktemp)

# Ensure temp files are removed on exit
trap 'rm -f "$TEMP_JAR_LIST" "$FOUND_LIB_DIRS"' EXIT

# Clear previous report
> "$REPORT_FILE"

echo "# Eclipse RCP JAR Dependency Analysis" >> "$REPORT_FILE"
echo "Generated on: $(date)" >> "$REPORT_FILE"
echo "" >> "$REPORT_FILE"

echo "Searching for lib/libs folders (excluding target, bin, .git)..."

# Find all directories named 'lib' or 'libs', excluding 'target', 'bin', and hidden git folders
# We use a temporary file to store the directory list to avoid subshell variable scope issues with the while loop
# Accepts optional target directory argument, defaults to current directory (.)
SEARCH_DIR="${1:-.}"

find "$SEARCH_DIR" -type d \( -name "target" -o -name "bin" -o -name ".git" \) -prune -o -type d \( -name "lib" -o -name "libs" \) -print0 > "$FOUND_LIB_DIRS"

while IFS= read -r -d '' lib_dir; do
    # The plugin directory is the parent of the lib/libs directory
    plugin_dir=$(dirname "$lib_dir")
    plugin_name=$(basename "$plugin_dir")
    
    # Find jar files in this specific lib directory (non-recursive to avoid deep nesting issues if any, usually libs are flat)
    # Using separate find execution to safely handle filenames with spaces if needed, though simpler loop works for standard jars
    
    # Find all jars in the directory first into an array
    mapfile -d '' jars < <(find "$lib_dir" -maxdepth 1 -name "*.jar" -print0)
    
    # Check if any jars were found
    if [ "${#jars[@]}" -gt 0 ]; then
        echo "## Plugin: $plugin_name" >> "$REPORT_FILE"
        echo "**Location:** \`$plugin_dir\`" >> "$REPORT_FILE"
        echo "" >> "$REPORT_FILE"
        echo "| JAR File |" >> "$REPORT_FILE"
        echo "|---|" >> "$REPORT_FILE"

        # We loop through jars to add them to report and the global list
        for jar_path in "${jars[@]}"; do
            jar_name=$(basename "$jar_path")
            echo "| $jar_name |" >> "$REPORT_FILE"
            echo "$jar_name" >> "$TEMP_JAR_LIST"
        done
        
        echo "" >> "$REPORT_FILE"
    fi

done < "$FOUND_LIB_DIRS"

# ---------------------------------------------------------
# Global Summary Section
# ---------------------------------------------------------

echo "# Global JAR Usage Summary" >> "$REPORT_FILE"
echo "List of all unique JARs and their usage frequency across discovered plugins." >> "$REPORT_FILE"
echo "" >> "$REPORT_FILE"
echo "| Usage Count | JAR Filename |" >> "$REPORT_FILE"
echo "|---|---|" >> "$REPORT_FILE"

if [ -s "$TEMP_JAR_LIST" ]; then
    # Sort, count unique occurrences, sort by count descending
    sort "$TEMP_JAR_LIST" | uniq -c | sort -nr | while read -r count jar_name; do
        echo "| $count | $jar_name |" >> "$REPORT_FILE"
    done
else
    echo "| 0 | No JARs found |" >> "$REPORT_FILE"
fi

echo "Analysis complete. Report saved to: $REPORT_FILE"

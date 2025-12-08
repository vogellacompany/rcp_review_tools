#!/bin/bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <path_to_build_output_file>" >&2
    exit 1
fi

FILE_PATH="$1"

if [ ! -f "$FILE_PATH" ]; then
    echo "Error: File '$FILE_PATH' not found." >&2
    exit 1
fi

# Print header
printf "% -10s | % -12s | %s\n" "Time (s)" "Original" "Component"
echo "--------------------------------------------------------------------------------"

# Awk script defined as a variable
AWK_SCRIPT='
BEGIN { FS="|"; OFS="|" }
{
    name = $1
    time_str = $2
    
    # Trim leading/trailing whitespace
    gsub(/^ +| +$/, "", name)
    gsub(/^ +| +$/, "", time_str)
    
    seconds = 0
    clean_str = time_str
    
    # sub() returns 1 on success, allowing us to combine check and substitution
    if (sub(/ min$/, "", clean_str)) {
        # Format: 01:50 min
        split(clean_str, parts, ":")
        if (length(parts) == 2) {
            seconds = parts[1] * 60 + parts[2]
        }
    } else if (sub(/ s$/, "", clean_str)) {
        # Format: 5.990 s
        seconds = clean_str
    }
    
    # Output: seconds|original_time|name
    printf "%.3f|%s|%s\n", seconds, time_str, name
}
'

# Process file
# Use tr -d '\r' to handle Windows CRLF line endings
tr -d '\r' < "$FILE_PATH" | grep "SUCCESS \[" |
 sed -E 's/^\[INFO\] //; s/\]$//; s/ (\.+ )?SUCCESS \[/|/' |
 awk "$AWK_SCRIPT" |
 sort -t "|" -k1,1rn |
 awk -F "|" '{ printf "% -10s | % -12s | %s\n", $1, $2, $3 }'
#!/bin/bash

if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <path_to_build_output_file>"
    exit 1
fi

FILE_PATH="$1"

if [ ! -f "$FILE_PATH" ]; then
    echo "Error: File '$FILE_PATH' not found."
    exit 1
fi

# Print header
printf "% -10s | % -12s | %s\n" "Time (s)" "Original" "Component"
echo "--------------------------------------------------------------------------------"

# Create temporary awk script
AWK_SCRIPT=$(mktemp)
cat << 'EOF' > "$AWK_SCRIPT"
BEGIN { FS="|"; OFS="|" }
{
    name = $1
    time_str = $2
    
    # Trim leading/trailing whitespace
    gsub(/^ +| +$/, "", name)
    gsub(/^ +| +$/, "", time_str)
    
    seconds = 0
    
    if (index(time_str, "min") > 0) {
        # Format: 01:50 min
        clean_str = time_str
        gsub(" min", "", clean_str)
        split(clean_str, parts, ":")
        if (length(parts) == 2) {
            seconds = parts[1] * 60 + parts[2]
        }
    } else if (index(time_str, "s") > 0) {
        # Format: 5.990 s
        clean_str = time_str
        gsub(" s", "", clean_str)
        seconds = clean_str
    }
    
    # Output: seconds|original_time|name
    printf "%.3f|%s|%s\n", seconds, time_str, name
}
EOF

# Process file
# Use tr -d '\r' to handle Windows CRLF line endings
cat "$FILE_PATH" | tr -d '\r' | grep "SUCCESS \[" |
 sed -E 's/^\ \[INFO\] //; s/\]$//; s/ (\.+ )?SUCCESS \[/|/' |
 awk -f "$AWK_SCRIPT" |
 sort -t "|" -k1,1rn |
 awk -F "|" '{ printf "% -10s | % -12s | %s\n", $1, $2, $3 }'

rm -f "$AWK_SCRIPT"
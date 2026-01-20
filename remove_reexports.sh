#!/bin/bash

# Default values
DRY_RUN=false
REPORT_FILE="reexport_report.txt"
TEMP_DATA_FILE="reexport_data.tmp"

# Check arguments
for arg in "$@"; do
    if [[ "$arg" == "--dry-run" ]]; then
        DRY_RUN=true
    fi
done

# Initialize report data
> "$TEMP_DATA_FILE"

echo "Searching for MANIFEST.MF files..."
if [ "$DRY_RUN" = true ]; then
    echo "Running in DRY RUN mode. No files will be modified."
fi

# Find all MANIFEST.MF files
find . -type f -name "MANIFEST.MF" | while read -r manifest_file; do
    # Extract Bundle-SymbolicName
    # We use perl to extract it reliably
    bsn=$(perl -ne 'print $1 if /^Bundle-SymbolicName:\s*([^; \s\r\n]+)/' "$manifest_file")
    
    if [ -z "$bsn" ]; then
        continue
    fi

    # Check for re-export
    if grep -q ";visibility:=reexport" "$manifest_file"; then
        
        # Extract the re-exported bundle names for the report using Perl
        # This handles entries even with version ranges containing commas
        perl -ne 'BEGIN { $bsn = shift } 
            if (/;visibility:=reexport/) { 
                while (/([^,;\s\n]+)(?:;(?:"[^"]*"|[^,"]*)*?)*;visibility:=reexport/g) { 
                    print "$1|$bsn\n"; 
                } 
            }' "$bsn" "$manifest_file" >> "$TEMP_DATA_FILE"

        # Perform removal if not dry run
        if [ "$DRY_RUN" = false ]; then
            # Use perl for in-place replacement to be consistent and cross-platform
            perl -i -pe 's/;visibility:=reexport//g' "$manifest_file"
        fi
    fi
done

# Generate Report
echo ""
echo "================================================================================"
echo "                                RE-EXPORT REPORT                                "
echo "================================================================================"
printf "% -50s | %s\n" "Re-exported plug-in" "Exported by:"
echo "---------------------------------------------------|----------------------------"

if [ -s "$TEMP_DATA_FILE" ]; then
    # Sort data to group by re-exported plugin
    sort "$TEMP_DATA_FILE" | awk -F'|' '
    {
        if ($1 == prev) {
            exporters = exporters ", " $2
        } else {
            if (prev != "") {
                printf "% -50s | %s\n", prev, exporters
            }
            prev = $1
            exporters = $2
        }
    }
    END {
        if (prev != "") {
            printf "% -50s | %s\n", prev, exporters
        }
    }'
else
    echo "No re-exports found."
fi

# Cleanup
rm -f "$TEMP_DATA_FILE"

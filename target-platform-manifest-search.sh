#!/usr/bin/env bash
# Extract entries from Eclipse target file and search for their usage in MANIFEST.MF files.
# Identifies potentially unnecessary target file entries.
# Works on Linux and Windows (Git Bash, WSL, Cygwin)

set -e

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Function to display usage
usage() {
    echo "Usage: $0 <target-file.target> [search-directory]"
    echo ""
    echo "Arguments:"
    echo "  target-file.target   Eclipse target platform file to analyze"
    echo "  search-directory     Directory to search for MANIFEST.MF files (default: current directory)"
    echo ""
    echo "Example:"
    echo "  $0 my-target.target"
    echo "  $0 my-target.target /path/to/workspace"
    exit 1
}

# Check if target file is provided
if [ $# -lt 1 ]; then
    usage
fi

TARGET_FILE="$1"
SEARCH_DIR="${2:-.}"

# Check if target file exists
if [ ! -f "$TARGET_FILE" ]; then
    echo -e "${RED}Error: Target file '$TARGET_FILE' not found.${NC}"
    exit 1
fi

# Check if search directory exists
if [ ! -d "$SEARCH_DIR" ]; then
    echo -e "${RED}Error: Search directory '$SEARCH_DIR' not found.${NC}"
    exit 1
fi

# Create temporary files
TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

TARGET_BUNDLES="$TEMP_DIR/target_bundles.txt"
TARGET_ARTIFACTS="$TEMP_DIR/target_artifacts.txt"
MANIFEST_BUNDLES="$TEMP_DIR/manifest_bundles.txt"
MANIFEST_IMPORTS="$TEMP_DIR/manifest_imports.txt"
UNUSED_BUNDLES="$TEMP_DIR/unused_bundles.txt"
USAGE_REPORT="$TEMP_DIR/usage_report.txt"

echo -e "${BLUE}╔════════════════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║           Eclipse Target File - MANIFEST.MF Usage Analyzer                ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Step 1: Extract entries from target file
echo -e "${CYAN}[1/4] Extracting entries from target file...${NC}"
echo -e "      Target file: ${YELLOW}$TARGET_FILE${NC}"

# Extract bundle symbolic names from unit entries
grep -oP '(?<=<unit id=")[^"]+' "$TARGET_FILE" 2>/dev/null | sort -u > "$TARGET_BUNDLES" || true

# Also extract artifact IDs if present
grep -oP '<artifactId>\K[^<]+' "$TARGET_FILE" 2>/dev/null | sort -u >> "$TARGET_ARTIFACTS" || true

# Combine and deduplicate
cat "$TARGET_BUNDLES" "$TARGET_ARTIFACTS" 2>/dev/null | sort -u > "$TEMP_DIR/all_target_entries.txt"
mv "$TEMP_DIR/all_target_entries.txt" "$TARGET_BUNDLES"

target_count=$(wc -l < "$TARGET_BUNDLES")
echo -e "      ${GREEN}Found $target_count entries in target file${NC}"
echo ""

# Step 2: Find all MANIFEST.MF files
echo -e "${CYAN}[2/4] Searching for MANIFEST.MF files...${NC}"
echo -e "      Search directory: ${YELLOW}$SEARCH_DIR${NC}"

# Find all MANIFEST.MF files (case-insensitive for Windows compatibility)
find "$SEARCH_DIR" -type f \( -iname "MANIFEST.MF" -o -iname "manifest.mf" \) > "$TEMP_DIR/manifest_files.txt" 2>/dev/null || true

manifest_count=$(wc -l < "$TEMP_DIR/manifest_files.txt")
echo -e "      ${GREEN}Found $manifest_count MANIFEST.MF files${NC}"

if [ "$manifest_count" -eq 0 ]; then
    echo -e "${YELLOW}Warning: No MANIFEST.MF files found in $SEARCH_DIR${NC}"
    echo -e "${YELLOW}Make sure you're running this in your Eclipse workspace directory.${NC}"
    exit 0
fi
echo ""

# Step 3: Extract bundle references from MANIFEST.MF files
echo -e "${CYAN}[3/4] Analyzing MANIFEST.MF files for bundle usage...${NC}"

> "$MANIFEST_BUNDLES"
> "$MANIFEST_IMPORTS"

while IFS= read -r manifest_file; do
    # Extract Require-Bundle entries (can span multiple lines)
    awk '
        /^Require-Bundle:/ {
            in_require = 1
            line = $0
            sub(/^Require-Bundle: */, "", line)
        }
        in_require && /^ / {
            sub(/^ +/, "", $0)
            line = line $0
        }
        in_require && !/^ / && NR > 1 {
            print line
            in_require = 0
        }
        END {
            if (in_require) print line
        }
    ' "$manifest_file" | tr ',' '\n' | grep -oP '^[a-zA-Z0-9._-]+' >> "$MANIFEST_BUNDLES" 2>/dev/null || true
    
    # Extract Import-Package entries (can span multiple lines)
    awk '
        /^Import-Package:/ {
            in_import = 1
            line = $0
            sub(/^Import-Package: */, "", line)
        }
        in_import && /^ / {
            sub(/^ +/, "", $0)
            line = line $0
        }
        in_import && !/^ / && NR > 1 {
            print line
            in_import = 0
        }
        END {
            if (in_import) print line
        }
    ' "$manifest_file" | tr ',' '\n' | grep -oP '^[a-zA-Z0-9._-]+' >> "$MANIFEST_IMPORTS" 2>/dev/null || true
done < "$TEMP_DIR/manifest_files.txt"

# Deduplicate
sort -u "$MANIFEST_BUNDLES" -o "$MANIFEST_BUNDLES"
sort -u "$MANIFEST_IMPORTS" -o "$MANIFEST_IMPORTS"

bundle_ref_count=$(wc -l < "$MANIFEST_BUNDLES")
import_ref_count=$(wc -l < "$MANIFEST_IMPORTS")
echo -e "      ${GREEN}Found $bundle_ref_count unique Require-Bundle references${NC}"
echo -e "      ${GREEN}Found $import_ref_count unique Import-Package references${NC}"
echo ""

# Step 4: Compare and find unused entries
echo -e "${CYAN}[4/4] Identifying potentially unused target entries...${NC}"
echo ""

> "$UNUSED_BUNDLES"
> "$USAGE_REPORT"

echo "USAGE ANALYSIS REPORT" > "$USAGE_REPORT"
echo "=====================" >> "$USAGE_REPORT"
echo "" >> "$USAGE_REPORT"

while IFS= read -r target_entry; do
    [ -z "$target_entry" ] && continue
    
    used=false
    usage_type=""
    
    # Check if bundle is directly required
    if grep -qFx "$target_entry" "$MANIFEST_BUNDLES" 2>/dev/null; then
        used=true
        usage_type="Require-Bundle"
    fi
    
    # Check if it matches any import package (bundle name often matches package prefix)
    if [ "$used" = false ]; then
        if grep -q "^${target_entry}\." "$MANIFEST_IMPORTS" 2>/dev/null || \
           grep -qFx "$target_entry" "$MANIFEST_IMPORTS" 2>/dev/null; then
            used=true
            usage_type="Import-Package"
        fi
    fi
    
    if [ "$used" = true ]; then
        echo "[USED] $target_entry ($usage_type)" >> "$USAGE_REPORT"
    else
        echo "[UNUSED] $target_entry" >> "$USAGE_REPORT"
        echo "$target_entry" >> "$UNUSED_BUNDLES"
    fi
done < "$TARGET_BUNDLES"

# Display results
echo "================================================================================"
echo "                    POTENTIALLY UNNECESSARY TARGET ENTRIES"
echo "================================================================================"
echo ""

if [ -s "$UNUSED_BUNDLES" ]; then
    echo -e "${YELLOW}The following target file entries were NOT found in any MANIFEST.MF files:${NC}"
    echo ""
    
    cat "$UNUSED_BUNDLES" | while IFS= read -r bundle; do
        echo -e "  ${RED}✗${NC} $bundle"
    done
    
    unused_count=$(wc -l < "$UNUSED_BUNDLES")
    echo ""
    echo -e "${YELLOW}Total potentially unused: $unused_count out of $target_count${NC}"
    echo ""
    echo -e "${CYAN}NOTE: These entries might still be:${NC}"
    echo "  • Required transitively by other bundles"
    echo "  • Used at runtime (not visible in MANIFEST.MF)"
    echo "  • Platform-specific dependencies"
    echo "  • Build/test only dependencies"
    echo ""
    echo -e "${CYAN}Recommendation: Review each entry carefully before removing.${NC}"
else
    echo -e "  ${GREEN}✓ All target entries are referenced in MANIFEST.MF files!${NC}"
    echo ""
    echo -e "${GREEN}No potentially unused entries found.${NC}"
fi

echo ""
echo "================================================================================"
echo ""

# Offer to save detailed report
echo -e "${BLUE}Detailed usage report available at:${NC} $USAGE_REPORT"
echo -e "${BLUE}To save permanently, run:${NC} cp $USAGE_REPORT ./target-usage-report.txt"
echo ""

# Summary statistics
used_count=$((target_count - $(wc -l < "$UNUSED_BUNDLES")))
echo -e "${CYAN}Summary:${NC}"
echo -e "  Target entries:        $target_count"
echo -e "  Used in MANIFEST.MF:   $used_count"
echo -e "  Potentially unused:    $(wc -l < "$UNUSED_BUNDLES")"
echo -e "  MANIFEST.MF files:     $manifest_count"
echo ""
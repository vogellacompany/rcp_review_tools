#!/usr/bin/env bash
# Compare Eclipse target file entries with Maven dependency tree output.
# Finds target file entries that are NOT present in the Maven dependencies.
# Works on Linux and Windows (Git Bash, WSL, Cygwin)

set -e

# Color codes for output (disable if not supported)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to display usage
usage() {
    echo "Usage: $0 <target-file.target> [maven-tree-output.txt]"
    echo ""
    echo "If maven-tree-output.txt is not provided, it will be generated automatically."
    echo ""
    echo "Example:"
    echo "  $0 my-target.target"
    echo "  $0 my-target.target existing-maven-tree.txt"
    exit 1
}

# Check if target file is provided
if [ $# -lt 1 ]; then
    usage
fi

TARGET_FILE="$1"
MAVEN_FILE="${2:-maven-tree.txt}"
GENERATE_MAVEN=false

# Check if target file exists
if [ ! -f "$TARGET_FILE" ]; then
    echo -e "${RED}Error: Target file '$TARGET_FILE' not found.${NC}"
    exit 1
fi

# Check if Maven output needs to be generated
if [ $# -lt 2 ]; then
    echo -e "${YELLOW}Maven dependency tree output not provided. Generating...${NC}"
    GENERATE_MAVEN=true
fi

# Generate Maven dependency tree if needed
if [ "$GENERATE_MAVEN" = true ]; then
    if ! command -v mvn &> /dev/null; then
        echo -e "${RED}Error: Maven (mvn) not found in PATH.${NC}"
        exit 1
    fi
    
    echo "Running: mvn dependency:tree -DoutputFile=$MAVEN_FILE"
    mvn dependency:tree -DoutputFile="$MAVEN_FILE"
    
    if [ ! -f "$MAVEN_FILE" ]; then
        echo -e "${RED}Error: Failed to generate Maven dependency tree.${NC}"
        exit 1
    fi
    echo -e "${GREEN}Maven dependency tree generated: $MAVEN_FILE${NC}"
    echo ""
fi

# Check if Maven file exists
if [ ! -f "$MAVEN_FILE" ]; then
    echo -e "${RED}Error: Maven output file '$MAVEN_FILE' not found.${NC}"
    exit 1
fi

# Create temporary files
TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

TARGET_DEPS="$TEMP_DIR/target_deps.txt"
MAVEN_DEPS="$TEMP_DIR/maven_deps.txt"
MISSING_DEPS="$TEMP_DIR/missing_deps.txt"

# Parse target file and extract dependencies
echo -e "${BLUE}Parsing target file: $TARGET_FILE${NC}"

# Extract unit entries (format: id and version attributes)
grep -oP '(?<=<unit id=")[^"]+' "$TARGET_FILE" 2>/dev/null | while read -r unit_id; do
    # Get the corresponding version
    version=$(grep -A 0 "id=\"$unit_id\"" "$TARGET_FILE" | grep -oP '(?<=version=")[^"]+' | head -1)
    
    # Convert unit id to Maven coordinates if it contains a dot
    if [[ "$unit_id" == *.* ]]; then
        # Split on last dot: group.id.artifact -> group.id:artifact
        group_id="${unit_id%.*}"
        artifact_id="${unit_id##*.}"
        echo "${group_id}:${artifact_id}:${version}"
    fi
done > "$TARGET_DEPS"

# Also look for explicit Maven-style entries in target file
grep -oP '<groupId>\K[^<]+' "$TARGET_FILE" 2>/dev/null | paste -d: - <(grep -oP '<artifactId>\K[^<]+' "$TARGET_FILE" 2>/dev/null) <(grep -oP '<version>\K[^<]+' "$TARGET_FILE" 2>/dev/null) >> "$TARGET_DEPS" || true

# Remove duplicates and sort
sort -u "$TARGET_DEPS" -o "$TARGET_DEPS"

target_count=$(wc -l < "$TARGET_DEPS")
echo -e "${GREEN}Found $target_count unique dependencies in target file${NC}"

# Parse Maven dependency tree output
echo -e "${BLUE}Parsing Maven dependency tree: $MAVEN_FILE${NC}"

# Extract Maven coordinates (format: groupId:artifactId:packaging:version:scope)
grep -oP '[a-zA-Z0-9._-]+:[a-zA-Z0-9._-]+:[a-zA-Z0-9._-]+:[a-zA-Z0-9._-]+' "$MAVEN_FILE" 2>/dev/null | while IFS=':' read -r group_id artifact_id packaging version scope; do
    echo "${group_id}:${artifact_id}:${version}"
done | sort -u > "$MAVEN_DEPS"

maven_count=$(wc -l < "$MAVEN_DEPS")
echo -e "${GREEN}Found $maven_count unique dependencies in Maven tree${NC}"

# Function to normalize version (remove SNAPSHOT, qualifiers, etc.)
normalize_version() {
    echo "$1" | sed -E 's/-SNAPSHOT.*//;s/\.v[0-9]+.*//;s/-[a-zA-Z]+.*//'
}

# Find missing dependencies
echo -e "\n${BLUE}Comparing dependencies...${NC}\n"

> "$MISSING_DEPS"

while IFS=':' read -r target_group target_artifact target_version; do
    [ -z "$target_group" ] && continue
    
    found=false
    normalized_target_version=$(normalize_version "$target_version")
    
    # Check if the exact artifact exists in Maven deps
    while IFS=':' read -r maven_group maven_artifact maven_version; do
        if [ "$target_group" = "$maven_group" ] && [ "$target_artifact" = "$maven_artifact" ]; then
            # Found the artifact, now check version
            normalized_maven_version=$(normalize_version "$maven_version")
            
            if [ "$target_version" = "$maven_version" ] || \
               [ "$normalized_target_version" = "$normalized_maven_version" ]; then
                found=true
                break
            fi
        fi
    done < "$MAVEN_DEPS"
    
    if [ "$found" = false ]; then
        echo "${target_group}:${target_artifact}:${target_version}" >> "$MISSING_DEPS"
    fi
done < "$TARGET_DEPS"

# Display results
echo "================================================================================"
echo "Dependencies in TARGET file NOT found in Maven dependency tree:"
echo "================================================================================"

if [ -s "$MISSING_DEPS" ]; then
    cat "$MISSING_DEPS" | while IFS=':' read -r group artifact version; do
        echo -e "  ${YELLOW}${group}:${artifact}:${version}${NC}"
    done
    
    missing_count=$(wc -l < "$MISSING_DEPS")
    echo ""
    echo -e "${RED}Total missing: $missing_count${NC}"
else
    echo -e "  ${GREEN}None - all target dependencies are present in Maven tree!${NC}"
fi

echo ""
#!/usr/bin/env bash
# Identify duplicated bundles in a Tycho target platform.
#
# Parses the output of 'mvn dependency:tree' in a Tycho reactor. Tycho prints
# every resolved target-platform bundle as
#     p2.eclipse-plugin:<symbolic-name>:<packaging>:<version>:system
# (features use 'p2.eclipse-feature'). This script groups those lines by
# symbolic name and reports any id that appears with more than one version.
#
# Works on Linux, macOS, and Windows (Git Bash, WSL, Cygwin).

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

usage() {
    cat <<EOF
Usage: $0 [options] [dependency-tree-file]

Reports bundles that appear in the resolved Tycho target platform under more
than one version. Input is the textual output of 'mvn dependency:tree' run
in a Tycho reactor.

If no file is given, the script runs
    mvn -B dependency:tree
in the current directory, captures its output, and parses it.

Options:
  -f, --features    Include feature IUs (p2.eclipse-feature:*) in the report.
                    By default only plug-ins/bundles are considered.
  -a, --all         Also print the full inventory of every symbolic name.
  -h, --help        Show this help.

Examples:
  $0
  $0 deptree.log

Tip: to run Maven yourself and reuse the output, do:
    mvn -B dependency:tree | tee deptree.log
    $0 deptree.log
EOF
    exit 1
}

INCLUDE_FEATURES=false
REPORT_ALL=false
INPUT=""

while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help) usage ;;
        -f|--features) INCLUDE_FEATURES=true; shift ;;
        -a|--all) REPORT_ALL=true; shift ;;
        -*) echo -e "${RED}Unknown option: $1${NC}"; usage ;;
        *) INPUT="$1"; shift ;;
    esac
done

TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

UNITS="$TEMP_DIR/units.tsv"
REPORT="$TEMP_DIR/report.tsv"
TREE_FILE=""

# 1. Obtain dependency:tree output --------------------------------------------
if [ -z "$INPUT" ]; then
    if ! command -v mvn >/dev/null 2>&1; then
        echo -e "${RED}Error: Maven (mvn) not found in PATH.${NC}"
        exit 1
    fi
    TREE_FILE="$TEMP_DIR/deptree.log"
    echo -e "${BLUE}Running: mvn -B dependency:tree${NC}"
    if ! mvn -B dependency:tree > "$TREE_FILE" 2>&1; then
        echo -e "${YELLOW}Maven exited non-zero; continuing with captured output.${NC}"
    fi
elif [ -f "$INPUT" ]; then
    TREE_FILE="$INPUT"
else
    echo -e "${RED}Error: '$INPUT' is not a regular file.${NC}"
    exit 1
fi

echo -e "${GREEN}Parsing dependency tree: $TREE_FILE${NC}"

# 2. Extract bundles (and optionally features) from dependency:tree output ---
# Lines look like:
#   [INFO] +- p2.eclipse.plugin:org.eclipse.osgi:eclipse-plugin:3.24.200.v...:system
#   [INFO] +- org.eclipse.platform:org.eclipse.ui:eclipse-plugin:3.205.0-SNAPSHOT:compile
#   [INFO] +- p2.eclipse.feature:org.eclipse.rcp:eclipse-feature:4.34.0.v...:system
#
# We key off the packaging field (eclipse-plugin / eclipse-feature) rather
# than the groupId, so that reactor modules (scope=compile, SNAPSHOT) are
# included alongside p2-resolved bundles (scope=system). Field 2 is the
# bundle symbolic name; the version is the next-to-last field, which stays
# correct whether or not a classifier is present.
if [ "$INCLUDE_FEATURES" = true ]; then
    PACKAGING_RE='eclipse-(plugin|feature)'
else
    PACKAGING_RE='eclipse-plugin'
fi
COORD_RE="[^:[:space:]]+:[^:[:space:]]+:${PACKAGING_RE}:[^:[:space:]]+(:[^:[:space:]]+)?:[a-z]+"

grep -oE "$COORD_RE" "$TREE_FILE" 2>/dev/null \
    | awk -F':' 'NF >= 5 { print $2 "\t" $(NF-1) }' \
    | sort -u > "$UNITS"

if [ ! -s "$UNITS" ]; then
    echo -e "${RED}Error: No eclipse-plugin entries found in the dependency tree.${NC}"
    echo    "Make sure Maven ran 'dependency:tree' in a Tycho reactor."
    exit 1
fi

total_units=$(wc -l < "$UNITS" | tr -d ' ')
unique_ids=$(cut -f1 "$UNITS" | sort -u | wc -l | tr -d ' ')
echo -e "${GREEN}Found $total_units id/version pairs ($unique_ids unique symbolic names)${NC}"
echo ""

# 3. Group by id, find duplicates ---------------------------------------------
awk -F'\t' '
    {
        if (versions[$1] == "") versions[$1] = $2
        else versions[$1] = versions[$1] "," $2
        count[$1]++
    }
    END { for (id in versions) print count[id] "\t" id "\t" versions[id] }
' "$UNITS" | sort -k1,1nr -k2,2 > "$REPORT"

dup_count=$(awk -F'\t' '$1 > 1' "$REPORT" | wc -l | tr -d ' ')

echo "================================================================================"
echo "Target-platform duplicates (symbolic name resolved at >1 version)"
echo "================================================================================"
if [ "$dup_count" -eq 0 ]; then
    echo -e "  ${GREEN}None - every symbolic name resolves to a single version.${NC}"
else
    awk -F'\t' '$1 > 1' "$REPORT" | while IFS=$'\t' read -r n id versions; do
        echo -e "  ${YELLOW}${id}${NC}  (${RED}${n} versions${NC})"
        echo "$versions" | tr ',' '\n' | sort -u | while IFS= read -r v; do
            echo "      $v"
        done
    done
    echo ""
    echo -e "${RED}Total duplicated symbolic names: ${dup_count}${NC}"
fi

if [ "$REPORT_ALL" = true ]; then
    echo ""
    echo "================================================================================"
    echo "Full inventory (all symbolic names)"
    echo "================================================================================"
    awk -F'\t' '{ printf "  %s -> %s\n", $2, $3 }' "$REPORT"
fi

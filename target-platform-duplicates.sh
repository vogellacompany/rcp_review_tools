#!/usr/bin/env bash
# Identify duplicated bundles in a Tycho target platform.
#
# Uses the target-platform dump written by Tycho when resolution runs with
# '-Dtycho.target-platform.dump=true'. The dump lists every resolved IU as
# '<unit id="..." version="..."/>'. This script collects those entries across
# the reactor, groups them by symbolic name, and reports any id that resolves
# to more than one version (a "duplicate" / version conflict).
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
Usage: $0 [options] [dump-file-or-directory]

Reports bundles that appear in the resolved Tycho target platform under more
than one version. The data source is the XML produced by Tycho when it
resolves with '-Dtycho.target-platform.dump=true' (one file per module under
'<module>/target/target-platform-*.xml').

If no path is given, the script runs
    mvn -q dependency:tree -Dtycho.target-platform.dump=true
in the current directory and scans the dump files it produced.

Options:
  -f, --features    Include feature IUs (*.feature.group) in the report.
                    By default only plug-ins/bundles are considered.
  -a, --all         Also print the full inventory of every symbolic name.
  -h, --help        Show this help.

Examples:
  $0
  $0 /path/to/my.rcp.parent
  $0 some.module/target/target-platform-some.module.xml
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

DUMP_LIST="$TEMP_DIR/dump-files.txt"
UNITS="$TEMP_DIR/units.tsv"
REPORT="$TEMP_DIR/report.tsv"

# 1. Locate dump files ---------------------------------------------------------
if [ -z "$INPUT" ]; then
    if ! command -v mvn >/dev/null 2>&1; then
        echo -e "${RED}Error: Maven (mvn) not found in PATH.${NC}"
        exit 1
    fi
    echo -e "${BLUE}Running: mvn -q dependency:tree -Dtycho.target-platform.dump=true${NC}"
    if ! mvn -q dependency:tree -Dtycho.target-platform.dump=true; then
        echo -e "${YELLOW}Maven exited non-zero; continuing if dump files were produced.${NC}"
    fi
    find . -type f -path '*/target/target-platform-*.xml' > "$DUMP_LIST"
elif [ -d "$INPUT" ]; then
    find "$INPUT" -type f -path '*/target/target-platform-*.xml' > "$DUMP_LIST"
elif [ -f "$INPUT" ]; then
    echo "$INPUT" > "$DUMP_LIST"
else
    echo -e "${RED}Error: '$INPUT' is neither a file nor a directory.${NC}"
    exit 1
fi

if [ ! -s "$DUMP_LIST" ]; then
    echo -e "${RED}Error: No target-platform dump files found.${NC}"
    echo    "Make sure Tycho ran with -Dtycho.target-platform.dump=true."
    exit 1
fi

dump_count=$(wc -l < "$DUMP_LIST" | tr -d ' ')
echo -e "${GREEN}Scanning $dump_count dump file(s)${NC}"

# 2. Extract <unit id="..." version="..."/> entries ----------------------------
: > "$UNITS"
while IFS= read -r f; do
    # id before version
    grep -oE '<unit[^/]*id="[^"]+"[^/]*version="[^"]+"' "$f" 2>/dev/null | \
        sed -E 's/.*id="([^"]+)".*version="([^"]+)".*/\1\t\2/' >> "$UNITS" || true
    # version before id (same tag, different attribute order)
    grep -oE '<unit[^/]*version="[^"]+"[^/]*id="[^"]+"' "$f" 2>/dev/null | \
        sed -E 's/.*version="([^"]+)".*id="([^"]+)".*/\2\t\1/' >> "$UNITS" || true
done < "$DUMP_LIST"

if [ ! -s "$UNITS" ]; then
    echo -e "${RED}Error: No <unit> entries extracted from dump files.${NC}"
    exit 1
fi

# Same id+version appearing in several reactor dumps is not a duplicate.
sort -u "$UNITS" -o "$UNITS"

# Filter features unless explicitly included.
if [ "$INCLUDE_FEATURES" != true ]; then
    awk -F'\t' '$1 !~ /\.feature\.(group|jar)$/' "$UNITS" > "$UNITS.tmp"
    mv "$UNITS.tmp" "$UNITS"
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

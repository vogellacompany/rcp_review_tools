#!/bin/bash
# ---------------------------------------------------------------------------
# Purpose: Visualize dependencies (Products -> Features -> Features)
#          Plugins aggregated as counts. Show included/required features.
# Usage: ./feature-dependency-graph.sh [directory]
# ---------------------------------------------------------------------------

SEARCH_DIR="${1:-.}"

DB_FILE="deps.db.tmp"
ROOTS_FILE="roots.tmp"
AVAILABLE_FILE="available.tmp"
COUNTS_FILE="counts.tmp"

# Colors
COLOR_PRODUCT="\033[1;34m" # Blue
COLOR_FEATURE="\033[1;36m" # Cyan
COLOR_INFO="\033[0;37m"    # Grey
COLOR_MISSING="\033[0;35m" # Magenta
COLOR_RESET="\033[0m"

trap 'rm -f "$DB_FILE" "$ROOTS_FILE" "$AVAILABLE_FILE" "$COUNTS_FILE"' EXIT

echo "Scanning workspace in: $SEARCH_DIR"
echo "Indexing relationships..."

> "$DB_FILE"
> "$ROOTS_FILE"
> "$AVAILABLE_FILE"
> "$COUNTS_FILE"

# --- Index Products ---
find "$SEARCH_DIR" -type f -name "*.product" -print0 | while IFS= read -r -d '' file; do
    awk -v fname="$file" '
        function get_attr(str, attr,   regex, val) {
            regex = attr "=\"[^\"]+\""
            if (match(str, regex)) {
                val = substr(str, RSTART, RLENGTH)
                sub(attr "=\"", "", val)
                sub("\"", "", val)
                return val
            }
            return ""
        }
        BEGIN { RS="<"; ORS="\n"; pid=""; }
        { gsub(/[[:space:]]+/, " ", $0); sub(/^[[:space:]]+/, "", $0); }
        /^product[[:space:]]/ {
            pid = get_attr($0, "id")
            if (pid != "") { print pid > "'"$AVAILABLE_FILE"'" }
        }
        /^feature[[:space:]]/ {
            if (pid != "") {
                fid = get_attr($0, "id")
                if (fid != "") print pid, fid, "included_in_product"
            }
        }
        END { if (pid != "") print pid > "'"$ROOTS_FILE"'" }
    ' "$file" >> "$DB_FILE"
done

# --- Index Features ---
find "$SEARCH_DIR" -type f -name "feature.xml" -print0 | while IFS= read -r -d '' file; do
    awk '
        function get_attr(str, attr,   regex, val) {
            regex = attr "=\"[^\"]+\""
            if (match(str, regex)) {
                val = substr(str, RSTART, RLENGTH)
                sub(attr "=\"", "", val)
                sub("\"", "", val)
                return val
            }
            return ""
        }
        BEGIN { RS="<"; ORS="\n"; fid=""; p_count=0 }
        { gsub(/[[:space:]]+/, " ", $0); sub(/^[[:space:]]+/, "", $0); }

        /^feature[[:space:]]/ {
            fid = get_attr($0, "id")
            if (fid != "") { print fid > "'"$AVAILABLE_FILE"'" }
        }

        /^plugin[[:space:]]/ { if (fid != "") p_count++ }

        /^includes[[:space:]]/ {
            if (fid != "") {
                child = get_attr($0, "id")
                if (child != "") print fid, child, "included"
            }
        }

        /^import[[:space:]]/ {
            if (fid != "") {
                req_f = get_attr($0, "feature")
                if (req_f != "") print fid, req_f, "required"
            }
        }

        END { if (fid != "") print fid, p_count > "'"$COUNTS_FILE"'" }
    ' "$file" >> "$DB_FILE"
done

# ===========================================================================
# Visualization Prep
# ===========================================================================
declare -A LOCAL_MAP
while read -r id; do LOCAL_MAP["$id"]=1; done < "$AVAILABLE_FILE"

declare -A PLUGIN_COUNTS
while read -r id count; do PLUGIN_COUNTS["$id"]=$count; done < "$COUNTS_FILE"

contains() { [[ "$1" =~ (^|[[:space:]])"$2"($|[[:space:]]) ]] && return 0 || return 1; }

print_tree() {
    local parent="$1"
    local prefix="$2"
    local visited="$3"

    if contains "$visited" "$parent"; then
        echo -e "${prefix}(Cycle Detected: $parent)"
        return
    fi

    local new_visited="$visited $parent"
    local children=$(grep "^$parent " "$DB_FILE")

    if [ -z "$children" ]; then return; fi

    while read -r p c type; do
        local label="$c"
        local extra_info=""
        local relation=""

        # Determine relationship string
        case "$type" in
            included) relation="(included)";;
            required) relation="(required)";;
            included_in_product) relation="(in product)";;
        esac

        label="$label $relation"

        # Add plugin count for features
        if [[ -n "${PLUGIN_COUNTS[$c]}" && "${PLUGIN_COUNTS[$c]}" -gt 0 ]]; then
            extra_info=" [${PLUGIN_COUNTS[$c]} plugins]"
        fi

        # Mark external if not found locally
        if [[ -z "${LOCAL_MAP[$c]}" ]]; then
            label="$label [External]"
        fi

        echo -e "${prefix}|-- $label$extra_info"

        # Recurse into local features only (skip products themselves)
        if [[ -n "${LOCAL_MAP[$c]}" && "$type" != "included_in_product" ]]; then
            print_tree "$c" "$prefix    " "$new_visited"
        fi
    done <<< "$children"
}

# ===========================================================================
# Execution
# ===========================================================================
echo "----------------------------------------------------"
echo "Legend: Product | Feature | Plugin Count | Relation"
echo "----------------------------------------------------"

# All products and all features are roots
cat "$ROOTS_FILE" "$AVAILABLE_FILE" | sort -u | while read -r root; do
    echo -e "[ROOT] $root"
    if [[ -n "${PLUGIN_COUNTS[$root]}" && "${PLUGIN_COUNTS[$root]}" -gt 0 ]]; then
        echo -e "  [${PLUGIN_COUNTS[$root]} plugins]"
    fi
    print_tree "$root" " " ""
    echo ""
done

echo "----------------------------------------------------"

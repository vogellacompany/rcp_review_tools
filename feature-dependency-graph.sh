#!/bin/bash

# ---------------------------------------------------------------------------
# Purpose: Visualize dependencies (Products -> Features -> Features).
#          Aggregates plugin counts instead of listing them individually.
#          Supports targeting a specific Feature ID as the root.
# Compatibility: Windows (Git Bash/WSL), Linux. Requires Bash 4.0+
# Usage: ./dependency_graph.sh [directory] [optional_root_id]
# ---------------------------------------------------------------------------

SEARCH_DIR="${1:-.}"
TARGET_ROOT="${2:-}" # Optional: Specific ID to visualize

DB_FILE="deps.db.tmp"
ROOTS_FILE="roots.tmp"
AVAILABLE_FILE="available.tmp"
COUNTS_FILE="counts.tmp"

# Colors
COLOR_PRODUCT="\033[1;34m" # Blue (Bold)
COLOR_FEATURE="\033[0;36m" # Cyan
COLOR_INFO="\033[0;37m"    # Grey
COLOR_MISSING="\033[0;35m" # Magenta
COLOR_RESET="\033[0m"
COLOR_WARN="\033[1;31m"    # Red

trap 'rm -f "$DB_FILE" "$ROOTS_FILE" "$AVAILABLE_FILE" "$COUNTS_FILE"' EXIT

echo "Scanning workspace in: $SEARCH_DIR"
echo "Indexing relationships..."

# Initialize files
> "$DB_FILE"
> "$ROOTS_FILE"
> "$AVAILABLE_FILE"
> "$COUNTS_FILE"

# ===========================================================================
# PHASE 1: INDEXING
# ===========================================================================

# 1. Scan Products (.product)
find "$SEARCH_DIR" -type f -name "*.product" -print0 | while IFS= read -r -d '' file;
do    awk -v fname="$file" \
        'BEGIN { RS="<"; ORS="\n"; pid=""; p_count=0 }
        
        # FIX: Clean whitespace, including leading space caused by RS split
        { 
            gsub(/[[:space:]]+/, " ", $0); 
            sub(/^[[:space:]]+/, "", $0); 
        }

        /^product[[:space:]]/ { 
            if (match($0, /id="[^"]+"/)) {
                raw = substr($0, RSTART, RLENGTH)
                pid = substr(raw, 5, length(raw)-5)
                sub(/^[[:space:]]+|[[:space:]]+$/, "", pid)
                print pid >> "'""$AVAILABLE_FILE""'"
                print "[INDEX] Found Product: " pid > "/dev/stderr"
            }
        }
        
        /^features>/ {
            if (pid == "") {
                n=split(fname, parts, "/")
                pid=parts[n] 
                sub(/\.product$/, "", pid)
                sub(/^[[:space:]]+|[[:space:]]+$/, "", pid)
                print pid >> "'""$AVAILABLE_FILE""'"
                print "[INDEX] Found Product (by filename): " pid > "/dev/stderr"
            }
        }

        /^plugin[[:space:]]/ { p_count++ }

        /^feature[[:space:]]/ {
            if (match($0, /id="[^"]+"/)) {
                raw = substr($0, RSTART, RLENGTH)
                fid = substr(raw, 5, length(raw)-5)
                sub(/^[[:space:]]+|[[:space:]]+$/, "", fid)
                if (pid != "") print pid, fid, "product_ref"
            }
        }
        
        END { 
            if (pid != "") {
                print pid >> "'""$ROOTS_FILE""'"
                print pid, p_count >> "'""$COUNTS_FILE""'"
            }
        }
    ' "$file" >> "$DB_FILE"
done

# 2. Scan Features (feature.xml)
find "$SEARCH_DIR" -type f -name "feature.xml" -print0 | while IFS= read -r -d '' file;
do    awk '
        BEGIN { RS="<"; ORS="\n"; fid=""; p_count=0 }
        
        # FIX: Clean whitespace, including leading space caused by RS split
        { 
            gsub(/[[:space:]]+/, " ", $0); 
            sub(/^[[:space:]]+/, "", $0); 
        }

        /^feature[[:space:]]/ {
            if (match($0, /id="[^"]+"/)) {
                raw = substr($0, RSTART, RLENGTH)
                fid = substr(raw, 5, length(raw)-5)
                sub(/^[[:space:]]+|[[:space:]]+$/, "", fid)
                print fid >> "'""$AVAILABLE_FILE""'"
                print "[INDEX] Found Feature: " fid > "/dev/stderr"
            }
        }

        /^plugin[[:space:]]/ { 
            p_count++
        }

        /^includes[[:space:]]/ {
            if (fid != "" && match($0, /id="[^"]+"/)) {
                raw = substr($0, RSTART, RLENGTH)
                child = substr(raw, 5, length(raw)-5)
                sub(/^[[:space:]]+|[[:space:]]+$/, "", child)
                print fid, child, "include"
            }
        }

        /^import[[:space:]]/ {
            if (fid != "") {
                if (match($0, /feature="[^"]+"/)) {
                    raw = substr($0, RSTART, RLENGTH)
                    child = substr(raw, 10, length(raw)-10)
                    sub(/^[[:space:]]+|[[:space:]]+$/, "", child)
                    print fid, child, "require"
                }
                if (match($0, /plugin="[^"]+"/)) {
                    raw = substr($0, RSTART, RLENGTH)
                    child = substr(raw, 9, length(raw)-9)
                    sub(/^[[:space:]]+|[[:space:]]+$/, "", child)
                    print fid, child, "require"
                }
            }
        }

        END {
            if (fid != "") {
                print fid, p_count >> "'""$COUNTS_FILE""'"
            }
        }
    ' "$file" >> "$DB_FILE"
done

# Deduplicate database to handle multiple files defining the same feature (e.g. source vs build)
sort -u "$DB_FILE" -o "$DB_FILE"

# ===========================================================================
# PHASE 2: VISUALIZATION PREP
# ===========================================================================

declare -A LOCAL_MAP
while read -r id; do LOCAL_MAP["$id"]=1; done < "$AVAILABLE_FILE"

declare -A PLUGIN_COUNTS
while read -r id count; do PLUGIN_COUNTS["$id"]=$count; done < "$COUNTS_FILE"

contains() {
    [[ "$1" =~ (^|[[:space:]])"$2"($|[[:space:]]) ]] && return 0 || return 1
}

print_tree() {
    local parent="$1"
    local prefix="$2"
    local visited="$3"
    
    if contains "$visited" "$parent"; then
        echo -e "${prefix}${COLOR_WARN}(Cycle Detected: $parent)${COLOR_RESET}"
        return
    fi

    local new_visited="$visited $parent"
    local children=$(grep "^$parent " "$DB_FILE")

    if [ -z "$children" ]; then return; fi

    while read -r p c type;
    do
        local connector="|--"
        local node_color="$COLOR_FEATURE"
        
        if [ "$type" == "require" ]; then 
            connector=">>"
        fi

        # Determine the type label (included/dependency)
        local type_label_part=""
        if [ "$type" == "include" ]; then
            type_label_part="(included)"
        elif [ "$type" == "require" ]; then
            type_label_part="(dependency)"
        fi

        # Determine the external label
        local external_label_part=""
        if [[ -z "${LOCAL_MAP[$c]}" ]]; then
            external_label_part="[EXTERNAL]"
            node_color="$COLOR_MISSING" # Apply external color
        fi

        # Construct the label string
        local label="${c}"
        if [ -n "$type_label_part" ]; then
            label="${label} ${type_label_part}"
        fi
        if [ -n "$external_label_part" ]; then
            label="${label} ${external_label_part}"
        fi

        local p_count="${PLUGIN_COUNTS[$c]}"
        local count_str=""
        if [[ -n "$p_count" && "$p_count" -gt 0 ]]
        then
            count_str=" ${COLOR_INFO}(Plugins: ${p_count})${COLOR_RESET}"
        fi

        echo -e "${prefix}${connector} ${node_color}${label}${COLOR_RESET}${count_str}"
        
        if [[ -n "${LOCAL_MAP[$c]}" ]]
        then
            print_tree "$c" "$prefix    " "$new_visited"
        fi
    done <<< "$children"
}

# ===========================================================================
# PHASE 3: EXECUTION
# ===========================================================================

echo "----------------------------------------------------"
echo "DEPENDENCY GRAPH"

# 1. Specific Target Mode
if [ -n "$TARGET_ROOT" ]; then
    echo -e "Target Root: ${COLOR_PRODUCT}$TARGET_ROOT${COLOR_RESET}" 
    
    # Verify it exists in the index
    if [[ -z "${LOCAL_MAP[$TARGET_ROOT]}" ]]
    then
        echo -e "${COLOR_WARN}Error: ID '$TARGET_ROOT' not found in workspace.${COLOR_RESET}"
        echo "Available matches (Top 5):"
        grep "$TARGET_ROOT" "$AVAILABLE_FILE" | head -n 5
    else
        # Get stats if available
        p_count="${PLUGIN_COUNTS[$TARGET_ROOT]}"
        if [[ -n "$p_count" && "$p_count" -gt 0 ]]
        then
            echo -e "${COLOR_INFO}Included plugins: ${p_count}${COLOR_RESET}"
        fi
        echo ""
        print_tree "$TARGET_ROOT" " " ""
    fi

# 2. Default Mode (Scan for Products)
else
    echo -e "Legend: ${COLOR_PRODUCT}Product${COLOR_RESET} | ${COLOR_FEATURE}Feature${COLOR_RESET} | ${COLOR_INFO}(Plugin Count)${COLOR_RESET} | ${COLOR_MISSING}External${COLOR_RESET}"
    echo "----------------------------------------------------"

    sort -u "$ROOTS_FILE" | while read -r product_id;
    do
        p_count="${PLUGIN_COUNTS[$product_id]}"
        count_str=""
        if [[ -n "$p_count" && "$p_count" -gt 0 ]]
        then
            count_str=" ${COLOR_INFO}(Includes ${p_count} direct plugins)${COLOR_RESET}"
        fi

        echo -e "${COLOR_PRODUCT}[PRODUCT] $product_id${COLOR_RESET}${count_str}"
        print_tree "$product_id" " " ""
        echo ""
    done
fi
echo "----------------------------------------------------"
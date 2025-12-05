#!/bin/bash

################################################################################
# Eclipse RCP Project Analyzer
# Recursively analyzes Eclipse RCP projects and generates a Markdown overview
################################################################################

# Function: Show usage 
show_usage() {
    echo "Usage: $0 <workspace-path> [output-file]"
    echo ""
    echo "Arguments:"
    echo "  workspace-path    Path to the Eclipse RCP Workspace/Repository"
    echo "  output-file       (Optional) Output Markdown file (Default: eclipse_rcp_report.md)"
    echo ""
    echo "Example:"
    echo "  $0 /path/to/workspace"
    echo "  $0 /path/to/workspace report.md"
    exit 1
}

# Function: Check if directory is a plugin project
is_plugin_project() {
    local dir="$1"
    [[ -f "$dir/META-INF/MANIFEST.MF" ]] || [[ -f "$dir/plugin.xml" ]]
}

# Function: Check if directory is a feature project
is_feature_project() {
    local dir="$1"
    [[ -f "$dir/feature.xml" ]]
}

# Function: Extract plugin name from MANIFEST.MF
get_plugin_name() {
    local dir="$1"
    local manifest="$dir/META-INF/MANIFEST.MF"

    if [[ -f "$manifest" ]]; then
        grep "^Bundle-SymbolicName:" "$manifest" | sed 's/Bundle-SymbolicName: *//;s/;.*//' | tr -d '\r'
    else
        basename "$dir"
    fi
}

# Function: Extract bundle version from MANIFEST.MF
get_plugin_version() {
    local dir="$1"
    local manifest="$dir/META-INF/MANIFEST.MF"

    if [[ -f "$manifest" ]]; then
        grep "^Bundle-Version:" "$manifest" | sed 's/Bundle-Version: *//;s/;.*//' | tr -d '\r'
    else
        echo ""
    fi
}

# Function: Count Java files in a project
count_java_files() {
    local dir="$1"
    find "$dir" -name "*.java" -type f | wc -l
}

# Function: Extract Feature ID from feature.xml
get_feature_id() {
    local dir="$1"
    local feature_xml="$dir/feature.xml"

    if [[ -f "$feature_xml" ]]; then
        # Note: Parsing XML with grep/sed can be fragile. This attempts to extract the first 'id' attribute found.
        # It may not always correspond to the primary feature ID if the XML structure is complex or malformed.
        grep -o 'id="[^"]*"' "$feature_xml" | head -1 | sed 's/id=\"//;s/"$//'
    else
        basename "$dir"
    fi
}

# Function: Extract Feature Version from feature.xml
get_feature_version() {
    local dir="$1"
    local feature_xml="$dir/feature.xml"

    if [[ -f "$feature_xml" ]]; then
        # Note: Parsing XML with grep/sed can be fragile. This attempts to extract the first 'version' attribute found.
        # It may not always correspond to the primary feature version if the XML structure is complex or malformed.
        grep -o 'version="[^"]*"' "$feature_xml" | head -1 | sed 's/version=\"//;s/"$//'
    else
        echo ""
    fi
}

# Function: Find product files
get_product_files() {
    local dir="$1"
    find "$dir" -maxdepth 2 -name "*.product" -type f
}

# Function: Extract Product Name from .product file
get_product_name() {
    local product_file="$1"

    if [[ -f "$product_file" ]]; then
        # Note: Parsing XML with grep/sed can be fragile. This attempts to extract the first 'name' attribute found.
        # It may not always correspond to the primary product name if the XML structure is complex or malformed.
        grep -o 'name="[^"]*"' "$product_file" | head -1 | sed 's/name=\"//;s/"$//'
    else
        basename "$product_file" .product
    fi
}

# Function: Extract Product ID from .product file
get_product_id() {
    local product_file="$1"

    if [[ -f "$product_file" ]]; then
        # Note: Parsing XML with grep/sed can be fragile. This attempts to extract the first 'id' attribute found.
        # It may not always correspond to the primary product ID if the XML structure is complex or malformed.
        grep -o 'id="[^"]*"' "$product_file" | head -1 | sed 's/id=\"//;s/"$//'
    else
        echo ""
    fi
}

# Parameter prüfen (Check parameters)
if [[ $# -lt 1 ]]; then
    show_usage
fi

WORKSPACE_PATH="$1"
OUTPUT_FILE="${2:-eclipse_rcp_report.md}"

# Workspace-Pfad validieren
if [[ ! -d "$WORKSPACE_PATH" ]]; then
    echo "Error: Directory '$WORKSPACE_PATH' does not exist!"
    exit 1
fi

echo "┌─────────────────────────────────────────────────────┐"
echo "│  Eclipse RCP Project Analyzer                       │"
echo "└─────────────────────────────────────────────────────┘"
echo ""
echo "Workspace: $WORKSPACE_PATH"
echo "Output:    $OUTPUT_FILE"
echo ""

# Arrays für gefundene Projekte
declare -a plugins
declare -a features
declare -a products

# Assoziatives Array um bereits verarbeitete Verzeichnisse zu tracken
declare -A processed_dirs

# Workspace rekursiv durchsuchen
echo "Searching recursively for Eclipse RCP projects..."
echo ""

# Verwende find für rekursive Suche, schließe aber bestimmte Verzeichnisse aus
while IFS= read -r -d '' dir; do
    # Überspringe, wenn dieses Verzeichnis bereits verarbeitet wurde
    if [[ -n "${processed_dirs[$dir]}" ]]; then
        continue
    fi

    # Markiere Verzeichnis als verarbeitet
    processed_dirs[$dir]=1

    # Prüfe Projekttyp mit Priorität: Feature > Plugin > Product
    # Ein Verzeichnis wird nur einmal gezählt

    # Feature-Projekte (höchste Priorität, da Features auch Plugin-Dateien haben können)
    if is_feature_project "$dir"; then
        feature_id=$(get_feature_id "$dir")
        feature_version=$(get_feature_version "$dir")
        features+=("$feature_id|$feature_version|$dir")
        echo "  ✓ [Feature] $feature_id"
    # Plugin-Projekte (nur wenn nicht bereits als Feature gezählt)
    elif is_plugin_project "$dir"; then
        plugin_name=$(get_plugin_name "$dir")
        plugin_version=$(get_plugin_version "$dir")
        java_count=$(count_java_files "$dir")
        plugins+=("$plugin_name|$plugin_version|$java_count|$dir")
        echo "  ✓ [Plugin]  $plugin_name"
    # Product-Projekte (nur wenn nicht bereits als Feature oder Plugin gezählt)
    elif product_files_found=$(get_product_files "$dir") && [[ -n "$product_files_found" ]]; then
        while IFS= read -r product_file; do
            product_name=$(get_product_name "$product_file")
            product_id=$(get_product_id "$product_file")
            products+=("$product_name|$product_id|$product_file")
            echo "  ✓ [Product] $product_name"
        done <<< "$product_files_found"
    fi
done < <(find "$WORKSPACE_PATH" -type d \
    ! -path "*/.git/*" \
    ! -path "*/.metadata/*" \
    ! -path "*/bin/*" \
    ! -path "*/target/*" \
    ! -path "*/build/*" \
    ! -path "*/.settings/*" \
    ! -path "*/node_modules/*" \
    ! -path "*/.svn/*" \
    -print0)

echo ""
# Ergebnisse ausgeben (Output results)
echo "==================================================="
echo "Found artifacts:"
echo "  • ${#plugins[@]} Plugin Projects"
echo "  • ${#features[@]} Feature Projects"
echo "  • ${#products[@]} Product Definitions"
echo "==================================================="
echo ""

# Markdown-Report generieren (Generate Markdown report)
echo "Generating Markdown Report..."
{
    echo "# Eclipse RCP Project Analysis Report"
    
    echo "**Analysis Date:** $(date '+%Y-%m-%d %H:%M:%S')"
    echo ""
    echo "**Workspace:** \`$WORKSPACE_PATH\`"
    echo ""
    
    # Summary
    echo "## 📊 Summary"
    echo "|                       Type                       |                    Count                    |"
    echo "|:----------------------------------------------:|:----------------------------------------------:|"
    echo "| Plugin Projects                                | ${#plugins[@]} |"
    echo "| Feature Projects                               | ${#features[@]} |"
    echo "| Product Definitions                            | ${#products[@]} |"
    
    # List plugin projects
    echo "## 🔌 Plugin Projects"
    if [[ ${#plugins[@]} -eq 0 ]]; then
        echo "_No plugin projects found._"
    else
        echo "| # | Plugin Name | Version | Java Files |"
        echo "|:--:|:---|:---|:---:|"
    
        counter=1
        for plugin_entry in "${plugins[@]}"; do
            IFS='|' read -r plugin_name plugin_version java_count plugin_path <<< "$plugin_entry"
            version_display="${plugin_version:-n/a}"
    
            printf "| %d | %s | %s | %d |\n" \
                "$counter" \
                "\`$plugin_name\`" \
                "$version_display" \
                "$java_count"
            ((counter++))
        done
    fi
    echo ""
    
    # List feature projects
    echo "## 📦 Feature Projects"
    if [[ ${#features[@]} -eq 0 ]]; then
        echo "_No feature projects found._"
    else
        echo "| # | Feature ID | Version |"
        echo "|:--:|:---|:---:|"
    
        counter=1
        for feature_entry in "${features[@]}"; do
            IFS='|' read -r feature_id feature_version feature_path <<< "$feature_entry"
            version_display="${feature_version:-n/a}"
    
            printf "| %d | %s | %s |\n" \
                "$counter" \
                "\`$feature_id\`" \
                "$version_display"
            ((counter++))
        done
    fi
    echo ""
    
    # List product definitions
    echo "## 🚀 Product Definitions"
    if [[ ${#products[@]} -eq 0 ]]; then
        echo "_No product definitions found._"
    else
        echo "| # | Product Name | Product ID |"
        echo "|:--:|:---|:---:|"
    
        counter=1
        for product_entry in "${products[@]}"; do
            IFS='|' read -r product_name product_id product_file <<< "$product_entry"
            id_display="${product_id:-n/a}"
    
            printf "| %d | %s | %s |\n" \
                "$counter" \
                "\`$product_name\`" \
                "\`$id_display\`"
            ((counter++))
        done
    fi
    echo ""
    
    # Statistics
    echo "## 📈 Statistics"
    echo "### Java Files by Plugin"
    if [[ ${#plugins[@]} -gt 0 ]]; then
        total_java=0
        echo '```'
        for plugin_entry in "${plugins[@]}"; do
            IFS='|' read -r plugin_name plugin_version java_count plugin_path <<< "$plugin_entry"
            printf "% -60s %6d Java Files\n" "$plugin_name" "$java_count"
            total_java=$((total_java + java_count))
        done
        echo ""
        echo "==============================================================="
        printf "% -60s %6d Java Files\n" "TOTAL" "$total_java"
        echo '```'
    
        echo ""
        echo "### Distribution"
        echo ""
        echo "- **Average:** $((total_java / ${#plugins[@]})) Java files per plugin"
        echo "- **Total:** $total_java Java files in ${#plugins[@]} plugins"
    else
        echo "_No statistics available._"
    fi
    echo ""
    
    # Directory structure
    echo "## 📁 Directory Structure"
    echo "### Grouped by Project Type"
    echo '```'
    if [[ ${#plugins[@]} -gt 0 ]]; then
        echo "Plugins:"
        for plugin_entry in "${plugins[@]}"; do
            IFS='|' read -r plugin_name plugin_version java_count plugin_path <<< "$plugin_entry"
            relative_path="${plugin_path#$WORKSPACE_PATH/}"
            echo "  └─ $relative_path"
        done
    fi
    if [[ ${#features[@]} -gt 0 ]]; then
        echo ""
        echo "Features:"
        for feature_entry in "${features[@]}"; do
            IFS='|' read -r feature_id feature_version feature_path <<< "$feature_entry"
            relative_path="${feature_path#$WORKSPACE_PATH/}"
            echo "  └─ $relative_path"
        done
    fi
    if [[ ${#products[@]} -gt 0 ]]; then
        echo ""
        echo "Products:"
        for product_entry in "${products[@]}"; do
            IFS='|' read -r product_name product_id product_file <<< "$product_entry"
            relative_path="${product_file#$WORKSPACE_PATH/}"
            echo "  └─ $relative_path"
        done
    fi
    echo '```'
    
    echo ""
    echo "---"
    echo "_Generated with Eclipse RCP Analyzer on $(date '+%Y-%m-%d %H:%M:%S')_"
} > "$OUTPUT_FILE"

echo "✓ Report successfully generated!"
echo ""
echo "File: $OUTPUT_FILE"
echo "Tip: Open the file with a Markdown viewer, GitHub, or GitLab."
echo ""

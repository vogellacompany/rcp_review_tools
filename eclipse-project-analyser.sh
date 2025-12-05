#!/bin/bash

################################################################################
# Eclipse RCP Project Analyzer
# Analysiert rekursiv Eclipse RCP Projekte und generiert eine Markdown-Übersicht
# (Recursively analyzes Eclipse RCP projects and generates a Markdown overview)
################################################################################

# Funktion: Verwendung anzeigen (Show usage)
show_usage() {    echo "Usage: $0 <workspace-path> [output-file]"
    echo ""
    echo "Arguments:"
    echo "  workspace-path    Pfad zum Eclipse RCP Workspace/Repository"
    echo "  output-file       (Optional) Output Markdown Datei (Standard: eclipse_rcp_report.md)"
    echo ""
    echo "Beispiel:"
    echo "  $0 /path/to/workspace"
    echo "  $0 /path/to/workspace report.md"
    exit 1
}

# Funktion: Prüft ob Verzeichnis ein Plugin-Projekt ist (Check if directory is a plugin project)
is_plugin_project() {    local dir="$1"
    [[ -f "$dir/META-INF/MANIFEST.MF" ]] || [[ -f "$dir/plugin.xml" ]]
}

# Funktion: Prüft ob Verzeichnis ein Feature-Projekt ist (Check if directory is a feature project)
is_feature_project() {
    local dir="$1"
    [[ -f "$dir/feature.xml" ]]
}

# Funktion: Prüft ob Verzeichnis ein Product enthält (Check if directory contains a product)
is_product_project() {
    local dir="$1"
    find "$dir" -maxdepth 2 -name "*.product" -type f 2>/dev/null | grep -q .
}

# Funktion: Extrahiert Plugin-Name aus MANIFEST.MF (Extract plugin name from MANIFEST.MF)
get_plugin_name() {    local dir="$1"
    local manifest="$dir/META-INF/MANIFEST.MF"

    if [[ -f "$manifest" ]]; then
        grep "^Bundle-SymbolicName:" "$manifest" | sed 's/Bundle-SymbolicName: *//;s/;.*//' | tr -d '\r\n'
    else
        basename "$dir"
    fi
}

# Funktion: Extrahiert Bundle-Version aus MANIFEST.MF (Extract bundle version from MANIFEST.MF)
get_plugin_version() {
    local dir="$1"
    local manifest="$dir/META-INF/MANIFEST.MF"

    if [[ -f "$manifest" ]]; then
        grep "^Bundle-Version:" "$manifest" | sed 's/Bundle-Version: *//;s/;.*//' | tr -d '\r\n'
    else
        echo ""
    fi
}

# Funktion: Zählt Java-Dateien in einem Projekt (Count Java files in a project)
count_java_files() {    local dir="$1"
    find "$dir" -name "*.java" -type f 2>/dev/null | wc -l
}

# Funktion: Extrahiert Feature-ID aus feature.xml (Extract feature ID from feature.xml)
get_feature_id() {
    local dir="$1"
    local feature_xml="$dir/feature.xml"

    if [[ -f "$feature_xml" ]]; then
        grep -o 'id="[^"]*"' "$feature_xml" | head -1 | sed 's/id="//;s/"$//'
    else
        basename "$dir"
    fi
}

# Funktion: Extrahiert Feature-Version aus feature.xml (Extract feature version from feature.xml)
get_feature_version() {
    local dir="$1"
    local feature_xml="$dir/feature.xml"

    if [[ -f "$feature_xml" ]]; then
        grep -o 'version="[^"]*"' "$feature_xml" | head -1 | sed 's/version="//;s/"$//'
    else
        echo ""
    fi
}

# Funktion: Findet Product-Dateien (Find product files)
get_product_files() {    local dir="$1"
    find "$dir" -maxdepth 2 -name "*.product" -type f 2>/dev/null
}

# Funktion: Extrahiert Product-Name aus .product Datei (Extract product name from .product file)
get_product_name() {
    local product_file="$1"

    if [[ -f "$product_file" ]]; then
        grep -o 'name="[^"]*"' "$product_file" | head -1 | sed 's/name="//;s/"$//'
    else
        basename "$product_file" .product
    fi
}

# Funktion: Extrahiert Product-ID aus .product Datei (Extract product ID from .product file)
get_product_id() {
    local product_file="$1"

    if [[ -f "$product_file" ]]; then
        grep -o 'id="[^"]*"' "$product_file" | head -1 | sed 's/id="//;s/"$//'
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

# Workspace-Pfad validieren (Validate workspace path)
if [[ ! -d "$WORKSPACE_PATH" ]]; then    echo "Error: Verzeichnis '$WORKSPACE_PATH' existiert nicht!"
    exit 1
fi

echo "┌─────────────────────────────────────────────────────┐"
echo "│  Eclipse RCP Project Analyzer                       │"
echo "└─────────────────────────────────────────────────────┘"
echo ""
echo "Workspace: $WORKSPACE_PATH"
echo "Output:    $OUTPUT_FILE"
echo ""

# Arrays für gefundene Projekte (Arrays for found projects)
declare -a plugins
declare -a features
declare -a products

# Assoziatives Array um bereits verarbeitete Verzeichnisse zu tracken (Associative array to track processed directories)
declare -A processed_dirs

# Workspace rekursiv durchsuchen (Recursively search workspace)
echo "Durchsuche rekursiv nach Eclipse RCP Projekten..."
echo ""

# Verwende find für rekursive Suche, schließe aber bestimmte Verzeichnisse aus (Use find for recursive search, but exclude certain directories)
while IFS= read -r -d '' dir; do
    # Überspringe, wenn dieses Verzeichnis bereits verarbeitet wurde (Skip if this directory has already been processed)
    if [[ -n "${processed_dirs[$dir]}" ]]; then
        continue
    fi

    # Markiere Verzeichnis als verarbeitet (Mark directory as processed)
    processed_dirs[$dir]=1

    # Prüfe Projekttyp mit Priorität: Feature > Plugin > Product
    # Ein Verzeichnis wird nur einmal gezählt (Check project type with priority: Feature > Plugin > Product. A directory is counted only once)
    project_counted=false

    # Feature-Projekte (höchste Priorität, da Features auch Plugin-Dateien haben können) (Feature projects - highest priority)
    if is_feature_project "$dir"; then
        feature_id=$(get_feature_id "$dir")
        feature_version=$(get_feature_version "$dir")
        features+=("$feature_id|$feature_version|$dir")
        echo "  ✓ [Feature] $feature_id"
        project_counted=true
    fi

    # Plugin-Projekte (nur wenn nicht bereits als Feature gezählt) (Plugin projects - only if not already counted as feature)
    if [[ "$project_counted" == false ]] && is_plugin_project "$dir"; then
        plugin_name=$(get_plugin_name "$dir")
        plugin_version=$(get_plugin_version "$dir")
        java_count=$(count_java_files "$dir")
        plugins+=("$plugin_name|$plugin_version|$java_count|$dir")
        echo "  ✓ [Plugin]  $plugin_name"
        project_counted=true
    fi

    # Product-Projekte (nur wenn nicht bereits als Feature oder Plugin gezählt) (Product projects - only if not already counted as feature or plugin)
    if [[ "$project_counted" == false ]] && is_product_project "$dir"; then
        while IFS= read -r product_file; do
            product_name=$(get_product_name "$product_file")
            product_id=$(get_product_id "$product_file")
            products+=("$product_name|$product_id|$product_file")
            echo "  ✓ [Product] $product_name"
        done < <(get_product_files "$dir")
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
echo "Gefundene Artefakte:"
echo "  • ${#plugins[@]} Plugin-Projekte"
echo "  • ${#features[@]} Feature-Projekte"
echo "  • ${#products[@]} Product-Definitionen"
echo "==================================================="
echo ""

# Markdown-Report generieren (Generate Markdown report)
echo "Generiere Markdown-Report..."
cat > "$OUTPUT_FILE" << 'EOF'
# Eclipse RCP Project Analysis Report
EOF

echo "**Analysedatum:** $(date '+%Y-%m-%d %H:%M:%S')" >> "$OUTPUT_FILE"
echo "" >> "$OUTPUT_FILE"
echo "**Workspace:** \`$WORKSPACE_PATH\`" >> "$OUTPUT_FILE"
echo "" >> "$OUTPUT_FILE"

# Zusammenfassung (Summary)
cat >> "$OUTPUT_FILE" << EOF
## 📊 Zusammenfassung
|                       Typ                       |                    Anzahl                    |
|:----------------------------------------------:|:----------------------------------------------:|
| Plugin-Projekte                                | ${#plugins[@]} |
| Feature-Projekte                               | ${#features[@]} |
| Product-Definitionen                           | ${#products[@]} |
EOF

# Plugin-Projekte auflisten (List plugin projects)
cat >> "$OUTPUT_FILE" << 'EOF'
## 🔌 Plugin-Projekte
EOF
if [[ ${#plugins[@]} -eq 0 ]]; then
    echo "_Keine Plugin-Projekte gefunden._" >> "$OUTPUT_FILE"
else
    # Gleich breite Spalten für bessere Lesbarkeit (60 Zeichen pro Spalte)
    echo "|     #     |                                                          Plugin Name                                                           |                                                          Version                                                         |                                                          Java-Dateien                                                          |" >> "$OUTPUT_FILE"
    echo "|:---------:|:------------------------------------------------------------:|:--------------------------------------------------------:|:--------------------------------------------------------:|" >> "$OUTPUT_FILE"

    counter=1
    for plugin_entry in "${plugins[@]}"; do
        IFS='|' read -r plugin_name plugin_version java_count plugin_path <<< "$plugin_entry"
        version_display="${plugin_version:-n/a}"

        # Formatierung mit gleich breiten Spalten (60 Zeichen)
        printf "| %9d | %-60s | %-56s | %56d |\n" \
            "$counter" \
            "\`$plugin_name\`" \
            "$version_display" \
            "$java_count" >> "$OUTPUT_FILE"
        ((counter++))
    done
fi
echo "" >> "$OUTPUT_FILE"

# Feature-Projekte auflisten (List feature projects)
cat >> "$OUTPUT_FILE" << 'EOF'
## 📦 Feature-Projekte
EOF
if [[ ${#features[@]} -eq 0 ]]; then
    echo "_Keine Feature-Projekte gefunden._" >> "$OUTPUT_FILE"
else
    # Gleich breite Spalten für bessere Lesbarkeit (90 Zeichen pro Spalte)
    echo "|     #     |                                                                                      Feature ID                                                                                       |                                                                                      Version                                                                                      |" >> "$OUTPUT_FILE"
    echo "|:---------:|:-------------------------------------------------------------------------------------:|:-------------------------------------------------------------------------------------:|" >> "$OUTPUT_FILE"

    counter=1
    for feature_entry in "${features[@]}"; do
        IFS='|' read -r feature_id feature_version feature_path <<< "$feature_entry"
        version_display="${feature_version:-n/a}"

        # Formatierung mit gleich breiten Spalten (90 Zeichen)
        printf "| %9d | %-85s | %-85s |\n" \
            "$counter" \
            "\`$feature_id\`" \
            "$version_display" >> "$OUTPUT_FILE"
        ((counter++))
    done
fi
echo "" >> "$OUTPUT_FILE"

# Product-Definitionen auflisten (List product definitions)
cat >> "$OUTPUT_FILE" << 'EOF'
## 🚀 Product-Definitionen
EOF
if [[ ${#products[@]} -eq 0 ]]; then
    echo "_Keine Product-Definitionen gefunden._" >> "$OUTPUT_FILE"
else
    # Gleich breite Spalten für bessere Lesbarkeit (90 Zeichen pro Spalte)
    echo "|     #     |                                                                                      Product Name                                                                                     |                                                                                       Product ID                                                                                      |" >> "$OUTPUT_FILE"
    echo "|:---------:|:-------------------------------------------------------------------------------------:|:-------------------------------------------------------------------------------------:|" >> "$OUTPUT_FILE"

    counter=1
    for product_entry in "${products[@]}"; do
        IFS='|' read -r product_name product_id product_file <<< "$product_entry"
        id_display="${product_id:-n/a}"

        # Formatierung mit gleich breiten Spalten (90 Zeichen)
        printf "| %9d | %-85s | %-85s |\n" \
            "$counter" \
            "\`$product_name\`" \
            "\`$id_display\`" >> "$OUTPUT_FILE"
        ((counter++))
    done
fi
echo "" >> "$OUTPUT_FILE"

# Statistiken (Statistics)
cat >> "$OUTPUT_FILE" << EOF
## 📈 Statistiken
### Java-Dateien nach Plugin
EOF
if [[ ${#plugins[@]} -gt 0 ]]; then
    total_java=0
    echo '```' >> "$OUTPUT_FILE"
    for plugin_entry in "${plugins[@]}"; do
        IFS='|' read -r plugin_name plugin_version java_count plugin_path <<< "$plugin_entry"
        printf "% -60s %6d Java-Dateien\n" "$plugin_name" "$java_count" >> "$OUTPUT_FILE"
        total_java=$((total_java + java_count))
    done
    echo "" >> "$OUTPUT_FILE"
    echo "================================================================"
    printf "% -60s %6d Java-Dateien\n" "GESAMT" "$total_java" >> "$OUTPUT_FILE"
    echo '```' >> "$OUTPUT_FILE"

    echo "" >> "$OUTPUT_FILE"
    echo "### Verteilung" >> "$OUTPUT_FILE"
    echo "" >> "$OUTPUT_FILE"
    echo "- **Durchschnitt:** $((total_java / ${#plugins[@]})) Java-Dateien pro Plugin" >> "$OUTPUT_FILE"
    echo "- **Gesamt:** $total_java Java-Dateien in ${#plugins[@]} Plugins" >> "$OUTPUT_FILE"
else
    echo "_Keine Statistiken verfügbar._" >> "$OUTPUT_FILE"
fi
echo "" >> "$OUTPUT_FILE"

# Verzeichnisstruktur (Directory structure)
cat >> "$OUTPUT_FILE" << 'EOF'
## 📁 Verzeichnisstruktur
### Nach Projekttyp gruppiert
EOF
echo '```' >> "$OUTPUT_FILE"
if [[ ${#plugins[@]} -gt 0 ]]; then
    echo "Plugins:" >> "$OUTPUT_FILE"
    for plugin_entry in "${plugins[@]}"; do
        IFS='|' read -r plugin_name plugin_version java_count plugin_path <<< "$plugin_entry"
        relative_path="${plugin_path#$WORKSPACE_PATH/}"
        echo "  └─ $relative_path" >> "$OUTPUT_FILE"
    done
fi
if [[ ${#features[@]} -gt 0 ]]; then
    echo "" >> "$OUTPUT_FILE"
    echo "Features:" >> "$OUTPUT_FILE"
    for feature_entry in "${features[@]}"; do
        IFS='|' read -r feature_id feature_version feature_path <<< "$feature_entry"
        relative_path="${feature_path#$WORKSPACE_PATH/}"
        echo "  └─ $relative_path" >> "$OUTPUT_FILE"
    done
fi
if [[ ${#products[@]} -gt 0 ]]; then
    echo "" >> "$OUTPUT_FILE"
    echo "Products:" >> "$OUTPUT_FILE"
    for product_entry in "${products[@]}"; do
        IFS='|' read -r product_name product_id product_file <<< "$product_entry"
        relative_path="${product_file#$WORKSPACE_PATH/}"
        echo "  └─ $relative_path" >> "$OUTPUT_FILE"
    done
fi
echo '```' >> "$OUTPUT_FILE"

echo "" >> "$OUTPUT_FILE"
echo "---" >> "$OUTPUT_FILE"
echo "_Generiert mit Eclipse RCP Analyzer am $(date '+%Y-%m-%d %H:%M:%S')_" >> "$OUTPUT_FILE"

echo "✓ Report erfolgreich erstellt!"
echo ""
echo "Datei: $OUTPUT_FILE"
echo "Tipp: Öffnen Sie die Datei mit einem Markdown-Viewer, GitHub oder GitLab."
echo ""

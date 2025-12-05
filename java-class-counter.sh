#!/bin/bash
# Java Code Line Counter with Test/Production Separation
# Funktioniert unter Linux, Mac und Windows (Git Bash/WSL)# Farben für bessere Lesbarkeit
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}    Java Code Line Counter${NC}"
echo -e "${BLUE}    (Production vs Test Code)${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

# Verzeichnis bestimmen (aktuelles Verzeichnis wenn kein Argument)
SEARCH_DIR="${1:-.}"

# Prüfen ob Verzeichnis existiert
if [ ! -d "$SEARCH_DIR" ]; then    echo -e "${RED}Fehler: Verzeichnis '$SEARCH_DIR' existiert nicht!${NC}"
    exit 1
fi
echo -e "Durchsuche Verzeichnis: ${GREEN}$SEARCH_DIR${NC}"
echo ""

# Funktion zum Zählen von Zeilen in einer Datei
count_lines() {
    local file="$1"
    local -n result=$2

    if [ ! -f "$file" ]; then
        result[total]=0
        result[code]=0
        result[comment]=0
        result[blank]=0
        return
    fi

    # Gesamtzeilen
    local lines=$(wc -l < "$file" 2>/dev/null | awk '{print $1}' || echo "0")

    # Leerzeilen
    local blank=$(grep -c "^[[:space:]]*$" "$file" 2>/dev/null | awk '{print $1}' || echo "0")

    # Kommentarzeilen
    local single_comments=$(grep -c "^[[:space:]]*\/\/" "$file" 2>/dev/null | awk '{print $1}' || echo "0")
    local multi_comments=$(grep -c "^[[:space:]]*\*" "$file" 2>/dev/null | awk '{print $1}' || echo "0")
    local comment_start=$(grep -c "^[[:space:]]*\/\*" "$file" 2>/dev/null | awk '{print $1}' || echo "0")
    local comments=$((single_comments + multi_comments + comment_start))

    # Code-Zeilen
    local code=$((lines - blank - comments))
    if [ "$code" -lt 0 ]; then
        code=0
    fi

    result[total]=$lines
    result[code]=$code
    result[comment]=$comments
    result[blank]=$blank
}

# Assoziative Arrays für Projektzählung (Associative arrays for project counting)
declare -A projects
declare -A project_prod_code
declare -A project_test_code
declare -A project_prod_files
declare -A project_test_files

# Gesamtzähler (Total counters)
TOTAL_PROD_CODE=0
TOTAL_TEST_CODE=0
TOTAL_PROD_FILES=0
TOTAL_TEST_FILES=0

echo -e "${CYAN}Analysiere Java-Dateien...${NC}" # Analyzing Java files...
echo ""

# Alle Java-Dateien rekursiv finden (Find all Java files recursively)
while IFS= read -r file; do
        # Zeilen zählen (Count lines)
        declare -A line_count
        count_lines "$file" line_count
    
        # Prüfen ob es Test-Code ist (case-insensitive) (Check if it's test code (case-insensitive))
        # Normalisiere Pfad-Trennzeichen für Windows-Kompatibilität (Normalize path separators for Windows compatibility)
        file_normalized=$(echo "$file" | tr '\\' '/' | tr '[:upper:]' '[:lower:]')
        is_test=0
        if echo "$file_normalized" | grep -qE '/(test|tests)/'; then
            is_test=1
        fi
    
        # Projektname extrahieren (erster Ordner nach SEARCH_DIR) (Extract project name (first folder after SEARCH_DIR))
        relative_path="${file#$SEARCH_DIR}"
        # Entferne führende Pfad-Trennzeichen (/ oder \) (Remove leading path separators (/ or \))
        relative_path=$(echo "$relative_path" | sed 's:^[/\\]::')
        # Normalisiere zu forward slashes (Normalize to forward slashes)
        relative_path=$(echo "$relative_path" | tr '\\' '/')
    
        # Ersten Ordner als Projektnamen verwenden (Use first folder as project name)
        if echo "$relative_path" | grep -q "/"; then
            project=$(echo "$relative_path" | cut -d'/' -f1)
        else
            project="root"
        fi
    
        # Zu Projekt-Statistiken hinzufügen (Add to project statistics)
        projects[$project]=1
    
        if [ "$is_test" -eq 1 ]; then
            # Test-Code
            project_test_code[$project]=$((${project_test_code[$project]:-0} + line_count[code]))
            project_test_files[$project]=$((${project_test_files[$project]:-0} + 1))
            TOTAL_TEST_CODE=$((TOTAL_TEST_CODE + line_count[code]))
            TOTAL_TEST_FILES=$((TOTAL_TEST_FILES + 1))
        else
            # Produktions-Code (Production Code)
            project_prod_code[$project]=$((${project_prod_code[$project]:-0} + line_count[code]))
            project_prod_files[$project]=$((${project_prod_files[$project]:-0} + 1))
            TOTAL_PROD_CODE=$((TOTAL_PROD_CODE + line_count[code]))
            TOTAL_PROD_FILES=$((TOTAL_PROD_FILES + 1))
        fi
    done < <(find "$SEARCH_DIR" -type f -name "*.java" 2>/dev/null)

# Prüfen ob Java-Dateien gefunden wurden (Check if Java files were found)
if [ ${#projects[@]} -eq 0 ]; then
    echo -e "${YELLOW}Keine Java-Dateien gefunden!${NC}" # No Java files found!
    exit 0
fi

# Ergebnisse pro Projekt ausgeben (Output results per project)
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}    Ergebnisse pro Projekt${NC}" # Results per Project
echo -e "${BLUE}========================================${NC}"
echo ""

# Header
printf "%-30s %15s %15s %15s\n" "Projekt" "Prod-Code" "Test-Code" "Gesamt"
printf "%-30s %15s %15s %15s\n" "$(printf '%.0s-' {1..30})" "$(printf '%.0s-' {1..15})" "$(printf '%.0s-' {1..15})" "$(printf '%.0s-' {1..15})"

# Projekte sortiert ausgeben (Output sorted projects)
for project in $(echo "${!projects[@]}" | tr ' ' '\n' | sort); do
    prod_code=${project_prod_code[$project]:-0}
    test_code=${project_test_code[$project]:-0}
    total_code=$((prod_code + test_code))

    prod_files=${project_prod_files[$project]:-0}
    test_files=${project_test_files[$project]:-0}

    printf "%-30s ${GREEN}%15d${NC} ${YELLOW}%15d${NC} %15d\n" "$project" "$prod_code" "$test_code" "$total_code"
    printf "%-30s ${GREEN}%13d F${NC} ${YELLOW}%13d F${NC}\n" "" "$prod_files" "$test_files"
    echo ""
done

# Gesamtergebnisse (Total Results)
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}    Gesamtergebnis${NC}" # Total Result
echo -e "${BLUE}========================================${NC}"
printf "%-30s ${GREEN}%15d${NC} ${YELLOW}%15d${NC} %15d\n" "GESAMT (Code-Zeilen)" "$TOTAL_PROD_CODE" "$TOTAL_TEST_CODE" "$((TOTAL_PROD_CODE + TOTAL_TEST_CODE))"
printf "%-30s ${GREEN}%15d${NC} ${YELLOW}%15d${NC} %15d\n" "GESAMT (Dateien)" "$TOTAL_PROD_FILES" "$TOTAL_TEST_FILES" "$((TOTAL_PROD_FILES + TOTAL_TEST_FILES))"
echo -e "${BLUE}========================================${NC}"

# Test-Coverage berechnen (Calculate Test Coverage)
if [ "$TOTAL_PROD_CODE" -gt 0 ]; then
    coverage=$((TOTAL_TEST_CODE * 100 / TOTAL_PROD_CODE))
    echo -e "Test-Code-Verhältnis: ${CYAN}${coverage}%${NC} (Test-Zeilen / Prod-Zeilen)" # Test-Code-Ratio: (Test Lines / Prod Lines)
fi
echo ""
echo -e "${GREEN}✓ Analyse abgeschlossen${NC}" # Analysis complete
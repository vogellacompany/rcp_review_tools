#!/bin/bash

SEARCH_DIR="${1:-.}"

if [ ! -d "$SEARCH_DIR" ]; then
    echo "Error: Directory '$SEARCH_DIR' not found."
    exit 1
fi

# Rekursiv feature.xml Dateien finden
find "$SEARCH_DIR" -type f -name "feature.xml" | while read -r filepath; do
    
    # Wir nutzen AWK für das Parsing, da es Multi-Line Tags versteht.
    # RS='<' setzt den Separator auf den Tag-Anfang.
    # Dadurch ist $0 jeweils der Inhalt eines Tags (z.B. 'includes id="..." version="..."')
    
    awk -v RS='<' '
    {
        # 1. Newlines und Tabs innerhalb des Tags durch Leerzeichen ersetzen
        # Damit wird aus einem Multi-Line Tag eine einzige lange Zeile für Regex
        gsub(/[\r\n\t]+/, " ", $0)
    }

    # --- Feature ID (Root) ---
    /^feature / {
        # Sucht nach id="..."
        if (match($0, /id="[^"]*"/)) {
            # Extrahiert den Wert zwischen den Anführungszeichen
            # RSTART+4 überspringt id="
            # RLENGTH-5 entfernt id=" und das schließende "
            val = substr($0, RSTART+4, RLENGTH-5)
            print "ROOT=" val
        }
    }

    # --- Includes ---
    /^includes / {
        if (match($0, /id="[^"]*"/)) {
            val = substr($0, RSTART+4, RLENGTH-5)
            print "INC=" val
        }
    }

    # --- Requires (Import) ---
    /^import / {
        # Wir suchen explizit nach feature="...". 
        # Einträge, die nur plugin="..." haben, matchen hier nicht und werden ignoriert.
        if (match($0, /feature="[^"]*"/)) {
            val = substr($0, RSTART+9, RLENGTH-10)
            print "REQ=" val
        }
    }
    ' "$filepath" | (
        # Subshell, um die Ausgaben von AWK zu sammeln und zu formatieren
        
        # Arrays initialisieren
        root_id=""
        includes=()
        requires=()

        while read -r line; do
            key=${line%%=*}
            value=${line#*=}
            
            case "$key" in
                ROOT) root_id="$value" ;;
                INC)  includes+=("$value") ;;
                REQ)  requires+=("$value") ;;
            esac
        done

        # Nur ausgeben, wenn wir eine Feature ID gefunden haben
        if [ ! -z "$root_id" ]; then
            echo "$root_id"

            # Required ausgeben
            if [ ${#requires[@]} -gt 0 ]; then
                echo " Required:"
                for req in "${requires[@]}"; do
                    echo "   $req"
                done
            fi

            # Included ausgeben
            if [ ${#includes[@]} -gt 0 ]; then
                echo " Included:"
                for inc in "${includes[@]}"; do
                    echo "   $inc"
                done
            fi
            
            # Leerzeile zur Trennung
            echo ""
        fi
    )
done
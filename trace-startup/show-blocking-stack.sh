#!/usr/bin/env bash
# Prints the full UI thread stack of the samples that match a regex.
# Companion to profile-eclipse-startup.sh, mirrors show-blocking-stack.ps1.
set -uo pipefail

FILE="$PWD/eclipse-startup-stacks.txt"
MATCH="AbstractBundleContainer[.]resolve"
COUNT=1
THREAD="main"

usage() {
	cat <<'EOF'
Usage: show-blocking-stack.sh [options]

  --file FILE     dump file (default ./eclipse-startup-stacks.txt)
  --match REGEX   print samples whose UI stack matches this (default AbstractBundleContainer[.]resolve)
  --count N       how many matching samples to print (default 1)
  --thread NAME   thread to print (default main)
EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
	--file) FILE="$2"; shift 2 ;;
	--match) MATCH="$2"; shift 2 ;;
	--count) COUNT="$2"; shift 2 ;;
	--thread) THREAD="$2"; shift 2 ;;
	-h | --help) usage; exit 0 ;;
	*) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
	esac
done

[ -f "$FILE" ] || { echo "No such file: $FILE" >&2; exit 1; }

awk -v thread="$THREAD" -v match_re="$MATCH" -v want="$COUNT" '
function flush(   i, hit) {
	if (nfr > 0) {
		total++
		hit = 0
		for (i = 1; i <= nfr; i++) if (fr[i] ~ match_re) { hit = 1; break }
		if (hit) {
			hits++
			if (printed < want) {
				printed++
				out = out "\n----- " label " (" state ") -----\n"
				for (i = 1; i <= nfr; i++) out = out fr[i] "\n"
			}
		}
	}
	nfr = 0; state = ""
}
/^===== sample / {
	flush()
	label = $0; gsub(/=/, "", label); sub(/^ +/, "", label); sub(/ +$/, "", label)
	inthr = 0; next
}
{
	if (substr($0, 1, length(thread) + 1) == "\"" thread) {
		inthr = 1; nfr = 0; state = ""; next
	}
}
inthr == 1 {
	line = $0; sub(/^[ \t]+/, "", line); sub(/[ \t]+$/, "", line)
	if (line == "") { flush(); inthr = 0; next }
	if (line ~ /^java\.lang\.Thread\.State:/) { split(line, a, " "); state = a[2]; next }
	if (line ~ /^at /) fr[++nfr] = line
}
END {
	flush()
	printf "%d of %d samples match \"%s\"\n", hits, total, match_re
	printf "%s", out
}
' "$FILE"

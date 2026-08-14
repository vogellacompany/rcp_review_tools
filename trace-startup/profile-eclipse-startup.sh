#!/usr/bin/env bash
# Poor man's profiler for Eclipse startup on Linux.
# Starts Eclipse, samples the UI thread while it comes up, writes every dump to a
# file and prints a summary. Linux counterpart of profile-eclipse-startup.ps1 from
# https://www.vogella.com/tutorials/EclipsePerformance/article.html
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ECLIPSE="$PWD/eclipse"
DATA=""
DURATION_SEC=25
INTERVAL_MS=50
OUT="$PWD/eclipse-startup-stacks.txt"
THREAD="main"
METHOD="sigquit"
ATTACH_PID=""
STOP_AFTER=0
ANALYZE_ONLY=0
UNTIL_MS=0
# Character classes rather than \. throughout: awk processes the escape twice and
# warns, which would fire on every run of the default filter.
FILTER='org[.]eclipse[.](pde|jdt|ui|e4|core|team|search|debug|ant|equinox[.]p2)'

usage() {
	cat <<'EOF'
Usage: profile-eclipse-startup.sh [options]

  --data DIR         workspace passed as -data (recommended)
  --eclipse PATH     launcher to start (default: ./eclipse in the current directory)
  --duration SEC     how long to sample (default 25)
  --interval MS      delay between samples (default 50)
  --out FILE         where to write the dumps (default ./eclipse-startup-stacks.txt)
  --thread NAME      thread to summarize (default main, the SWT UI thread)
  --method M         sigquit (default, cheap) or jcmd (portable, ~150 ms per sample)
  --pid PID          sample a running JVM instead of starting one (forces --method jcmd)
  --stop-after       terminate Eclipse once the sampling window ends
  --analyze-only     re-print the summary for an existing --out file
  --until MS         only analyze samples taken before this timestamp (0 = all)
  --filter REGEX     regex for the "triggering frame" (default: Eclipse UI/core code)
EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
	--data) DATA="$2"; shift 2 ;;
	--eclipse) ECLIPSE="$2"; shift 2 ;;
	--duration) DURATION_SEC="$2"; shift 2 ;;
	--interval) INTERVAL_MS="$2"; shift 2 ;;
	--out) OUT="$2"; shift 2 ;;
	--thread) THREAD="$2"; shift 2 ;;
	--method) METHOD="$2"; shift 2 ;;
	--pid) ATTACH_PID="$2"; METHOD="jcmd"; shift 2 ;;
	--filter) FILTER="$2"; shift 2 ;;
	--stop-after) STOP_AFTER=1; shift ;;
	--analyze-only) ANALYZE_ONLY=1; shift ;;
	--until) UNTIL_MS="$2"; shift 2 ;;
	-h | --help) usage; exit 0 ;;
	*) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
	esac
done

now_ms() { echo $(($(date +%s%N) / 1000000)); }

# True if $1 is a JVM, i.e. it has libjvm.so mapped. Works for both launch modes:
# the native launcher either loads the JVM in-process or forks a java child.
is_jvm() { grep -qa 'libjvm\.so' "/proc/$1/maps" 2>/dev/null; }

find_jvm_pid() {
	local root="$1" deadline p c
	deadline=$(($(now_ms) + 30000))
	while [ "$(now_ms)" -lt "$deadline" ]; do
		kill -0 "$root" 2>/dev/null || return 1
		for p in "$root" $(pgrep -P "$root" 2>/dev/null); do
			is_jvm "$p" && { echo "$p"; return 0; }
			for c in $(pgrep -P "$p" 2>/dev/null); do
				is_jvm "$c" && { echo "$c"; return 0; }
			done
		done
		sleep 0.02
	done
	return 1
}

# PIDs of running Eclipse JVMs. Matches on the process name plus its argv, so a
# shell whose own command line mentions equinox.launcher never matches itself.
running_eclipse_jvms() {
	local p
	for p in $(pgrep -x java 2>/dev/null; pgrep -x eclipse 2>/dev/null); do
		is_jvm "$p" || continue
		tr '\0' ' ' <"/proc/$p/cmdline" 2>/dev/null | grep -q 'equinox\.launcher' && echo "$p"
	done
}

# jcmd from the JDK that actually runs Eclipse, so attach versions always match.
resolve_jcmd() {
	local pid="$1" home
	home="$(dirname "$(dirname "$(readlink -f "/proc/$pid/exe" 2>/dev/null)")")"
	if [ -x "$home/bin/jcmd" ]; then echo "$home/bin/jcmd"; return 0; fi
	command -v jcmd 2>/dev/null && return 0
	return 1
}

analyze() {
	local file="$1"
	[ -s "$file" ] || { echo "No samples in $file" >&2; return 1; }
	local tmp
	tmp="$(mktemp -d)"
	trap 'rm -rf "$tmp"' RETURN

	awk -v thread="$THREAD" -v filter="$FILTER" -v until_ms="$UNTIL_MS" \
		-v tlf="$tmp/timeline" -v leaff="$tmp/leaf" \
		-v trigf="$tmp/trig" -v inclf="$tmp/incl" -v statf="$tmp/stat" '
	function flush(   i, trig, tl, idle) {
		if (nfr > 0) {
			nvalid++
			print fr[1] > leaff
			trig = ""
			for (i = 1; i <= nfr; i++) if (fr[i] ~ filter) { trig = fr[i]; break }
			print (trig == "" ? "(no Eclipse frame)" : trig) > trigf
			tl = (trig == "" ? fr[1] : trig)
			printf "%-24s %-9s %s\n", label, state, tl > tlf
			delete seen
			for (i = 1; i <= nfr; i++)
				if (!(fr[i] in seen)) { seen[fr[i]] = 1; print fr[i] > inclf }
			idle = 0
			for (i = 1; i <= nfr; i++)
				if (fr[i] ~ /Display\.sleep|eventLoopIdle|Display\.readAndDispatch/) idle = 1
			print (idle ? "idle" : "busy") > statf
		}
		nfr = 0; state = ""
	}
	/^===== sample / {
		flush()
		label = $0; gsub(/=/, "", label); sub(/^ +/, "", label); sub(/ +$/, "", label)
		t = label; sub(/.*t/, "", t); sub(/ms.*/, "", t)
		skip = (until_ms > 0 && t + 0 > until_ms)
		inthr = 0; next
	}
	{
		# Prefix match, so --thread "Start Level" finds the Equinox thread whose
		# full name carries a per-run UUID.
		if (substr($0, 1, length(thread) + 1) == "\"" thread) {
			inthr = 1; nfr = 0; state = ""; next
		}
	}
	inthr == 1 && !skip {
		line = $0; sub(/^[ \t]+/, "", line); sub(/[ \t]+$/, "", line)
		if (line == "") { flush(); inthr = 0; next }
		if (line ~ /^java\.lang\.Thread\.State:/) { split(line, a, " "); state = a[2]; next }
		if (line ~ /^at /) fr[++nfr] = line
	}
	END { flush(); print nvalid > (tlf ".count") }
	' "$file"

	local n busy idle
	n=$(cat "$tmp/timeline.count" 2>/dev/null || echo 0)
	[ "$n" -gt 0 ] || { echo "No \"$THREAD\" stacks found in $file" >&2; return 1; }
	busy=$(grep -c '^busy$' "$tmp/stat" 2>/dev/null || true)
	idle=$(grep -c '^idle$' "$tmp/stat" 2>/dev/null || true)

	echo
	echo "$n samples of the \"$THREAD\" thread: ${busy:-0} busy, ${idle:-0} in the event loop"
	echo
	echo "Timeline:"
	cat "$tmp/timeline"
	echo
	echo "Most frequent triggering frame:"
	sort "$tmp/trig" | uniq -c | sort -rn | head -15
	echo
	echo "Hottest leaf frames:"
	sort "$tmp/leaf" | uniq -c | sort -rn | head -15
	echo
	echo "Frames by number of samples that contain them (inclusive cost):"
	sort "$tmp/incl" | uniq -c | sort -rn | awk -v n="$n" '$1 >= n * 0.15' | head -40
}

if [ "$ANALYZE_ONLY" = "1" ]; then
	analyze "$OUT"
	exit $?
fi

if [ -n "$ATTACH_PID" ]; then
	JVM_PID="$ATTACH_PID"
	is_jvm "$JVM_PID" || { echo "PID $JVM_PID is not a JVM" >&2; exit 1; }
	LAUNCH_PID=""
	T0=$(now_ms)
else
	[ -x "$ECLIPSE" ] || {
		echo "Not an executable Eclipse launcher: $ECLIPSE" >&2
		echo "Pass --eclipse /path/to/eclipse" >&2
		exit 1
	}
	if [ -n "$(running_eclipse_jvms)" ]; then
		echo "An Eclipse is already running, close it first (or pass --pid)." >&2
		exit 1
	fi
	# The JVM's stdout only holds the raw dumps; $OUT supersedes it, so keep it in
	# a temp file and drop it once it has been converted.
	LOG="$(mktemp)"
	echo "Writing stacks to $OUT"
	T0=$(now_ms)
	if [ -n "$DATA" ]; then
		"$ECLIPSE" -data "$DATA" >"$LOG" 2>&1 &
	else
		"$ECLIPSE" >"$LOG" 2>&1 &
	fi
	LAUNCH_PID=$!
	JVM_PID="$(find_jvm_pid "$LAUNCH_PID")" || {
		echo "Could not find the JVM process for launcher $LAUNCH_PID" >&2
		exit 1
	}
	echo "Launcher PID $LAUNCH_PID, JVM PID $JVM_PID, found after $(($(now_ms) - T0)) ms"
fi

echo "Sampling for ${DURATION_SEC}s every ${INTERVAL_MS}ms via $METHOD"

END_MS=$((T0 + DURATION_SEC * 1000))
SLEEP=$(awk -v ms="$INTERVAL_MS" 'BEGIN { printf "%.3f", ms / 1000 }')
N=0
CAPTURED=0

if [ "$METHOD" = "jcmd" ]; then
	JCMD="$(resolve_jcmd "$JVM_PID")" || { echo "No jcmd found" >&2; exit 1; }
	: >"$OUT"
	while [ "$(now_ms)" -lt "$END_MS" ]; do
		kill -0 "$JVM_PID" 2>/dev/null || { echo "JVM exited after $(($(now_ms) - T0)) ms"; break; }
		N=$((N + 1))
		if DUMP="$("$JCMD" "$JVM_PID" Thread.print 2>&1)"; then
			CAPTURED=$((CAPTURED + 1))
			printf '===== sample %d t=%dms =====\n%s\n' "$N" "$(($(now_ms) - T0))" "$DUMP" >>"$OUT"
		fi
		sleep "$SLEEP"
	done
else
	# SIGQUIT makes the JVM print the dump to its own stdout, which costs the
	# sampler nothing, so a 4 second startup can be sampled every 50 ms.
	TIMES="$(mktemp)"
	while [ "$(now_ms)" -lt "$END_MS" ]; do
		kill -0 "$JVM_PID" 2>/dev/null || { echo "JVM exited after $(($(now_ms) - T0)) ms"; break; }
		N=$((N + 1))
		if kill -QUIT "$JVM_PID" 2>/dev/null; then
			CAPTURED=$((CAPTURED + 1))
			echo "$(($(now_ms) - T0))" >>"$TIMES"
		fi
		sleep "$SLEEP"
	done
	sleep 0.5 # let the last dump finish flushing
	# Re-emit the JVM's stdout in the same format the jcmd path produces: the Nth
	# "Full thread dump" belongs to the Nth signal we sent.
	awk -v times="$TIMES" -v out="$OUT" '
	BEGIN { while ((getline t < times) > 0) ts[++nt] = t; printf "" > out }
	/^Full thread dump / { n++; printf "===== sample %d t=%sms =====\n", n, (n <= nt ? ts[n] : "?") >> out }
	n > 0 { print >> out }
	' "$LOG"
	rm -f "$TIMES" "$LOG"
fi

echo "$CAPTURED of $N sampling attempts succeeded"
[ "$CAPTURED" -gt 0 ] || { echo "Nothing captured." >&2; exit 1; }

if [ "$STOP_AFTER" = "1" ] && [ -n "${LAUNCH_PID:-}" ]; then
	kill -TERM "$JVM_PID" 2>/dev/null
fi

analyze "$OUT"

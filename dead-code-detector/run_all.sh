#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ALL_SCRIPTS=(find_dead_classes.py find_dead_constants.py find_unused_imports.py find_dead_private.py)

usage() {
    cat >&2 <<EOF
Usage: $0 <root> [extra_roots ...] [--only NAME[,NAME...]] [detector options]

  --only NAME    run only the named detectors (classes, constants, imports,
                 private); repeatable and comma separated.

All other options are passed through to each detector, for example
--internal-only, --skip-tests, --ignore-test-refs, --exclude, --jobs,
--min-confidence, --format and --fail-on-findings.
EOF
    exit 1
}

[ "$#" -lt 1 ] && usage

ROOT="$1"
shift

declare -a SELECTED=()
declare -a PASSTHROUGH=()
while [ "$#" -gt 0 ]; do
    case "$1" in
        --only)
            [ "$#" -lt 2 ] && usage
            IFS=',' read -r -a parts <<< "$2"
            SELECTED+=("${parts[@]}")
            shift 2
            ;;
        --only=*)
            IFS=',' read -r -a parts <<< "${1#--only=}"
            SELECTED+=("${parts[@]}")
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            PASSTHROUGH+=("$1")
            shift
            ;;
    esac
done

declare -a SCRIPTS=()
if [ "${#SELECTED[@]}" -eq 0 ]; then
    SCRIPTS=("${ALL_SCRIPTS[@]}")
else
    for name in "${SELECTED[@]}"; do
        case "$name" in
            classes)   SCRIPTS+=(find_dead_classes.py) ;;
            constants) SCRIPTS+=(find_dead_constants.py) ;;
            imports)   SCRIPTS+=(find_unused_imports.py) ;;
            private)   SCRIPTS+=(find_dead_private.py) ;;
            *) echo "Unknown detector: $name" >&2; usage ;;
        esac
    done
fi

# --fix only applies to the import detector; passing it to the others is a
# hard argparse error, so drop it for them.
STATUS=0
for script in "${SCRIPTS[@]}"; do
    declare -a ARGS=()
    for opt in ${PASSTHROUGH[@]+"${PASSTHROUGH[@]}"}; do
        if [ "$opt" = "--fix" ] && [ "$script" != "find_unused_imports.py" ]; then
            continue
        fi
        ARGS+=("$opt")
    done
    echo "===== $script ====="
    python3 "$DIR/$script" "$ROOT" ${ARGS[@]+"${ARGS[@]}"} || STATUS=$?
    echo ""
done

exit "$STATUS"

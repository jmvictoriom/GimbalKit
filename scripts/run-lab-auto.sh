#!/bin/zsh
# Usage: scripts/run-lab-auto.sh <report.md> [--solo yaw,reposo,bateria,parada,telemetria]
set -euo pipefail
if (( $# < 1 )); then
    print -u2 'Uso: scripts/run-lab-auto.sh <ruta.md> [--solo yaw,reposo,bateria,parada,telemetria]'
    exit 1
fi
REPORT="${1:a}"
shift
cd "$(dirname "$0")/.."
mkdir -p -- "${REPORT:h}"
scripts/build-lab-mac.sh
OUT="${REPORT}.log"
rm -f -- "$OUT"
open -n -W "$PWD/.build/GimbalLab.app" --args --auto-run --out "$REPORT" "$@"
cat -- "$OUT"
# open -W does not forward the child's exit status; the cycle prints it after cleanup.
CODE="$(sed -n 's/^LAB SALIDA \([012]\)$/\1/p' "$OUT" | tail -1)"
exit "${CODE:-1}"

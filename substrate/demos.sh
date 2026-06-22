#!/usr/bin/env bash
# Run every Substrate demo in sequence. Usage: ./demos.sh [fs|archive|spool|zoned|all]
set -euo pipefail
cd "$(dirname "$0")"
mix compile >/dev/null
which="${1:-all}"
demos=(fs archive spool zoned)
[[ "$which" != "all" ]] && demos=("$which")
for d in "${demos[@]}"; do
  printf '\n\033[1m\033[44m  %s substrate  \033[0m\n' "$d"
  mix run "${d}_demo.exs"
done

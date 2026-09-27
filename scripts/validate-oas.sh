#!/usr/bin/env bash
# Stage 2 - OpenAPI 3.0 validity + APIC lint rules (Spectral, ruleset in config/spectral.yml).
#
#   validate-oas.sh API_LIST_FILE
#
# Produces out/spectral.xml (JUnit, published to the PR "Tests" tab) and per-finding annotations.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
require_cmd spectral jq

mapfile -t FILES < <(read_list "${1:?API list file required}")
(( ${#FILES[@]} )) || { log "Stage 2: no API files"; exit 0; }

mkdir -p out
vso_section "Stage 2 - spectral lint (${#FILES[@]} file(s))"

rc=0
spectral lint --ruleset config/spectral.yml --fail-severity error \
  --format stylish --format junit --output.junit out/spectral.xml \
  --format json --output.json out/spectral.json \
  "${FILES[@]}" || rc=$?

# Spectral JSON: severity 0=error 1=warn 2=info 3=hint; ranges are 0-based
if [[ -s out/spectral.json ]]; then
  jq -r '.[] | select(.severity <= 1)
          | "\(if .severity == 0 then "error" else "warning" end)\t\(.source // "")\t\(.range.start.line + 1)\t\(.range.start.character + 1)\t\(.code): \(.message)"' \
     out/spectral.json |
  while IFS=$'\t' read -r level src ln col msg; do
    src=$(realpath -m --relative-to=. "$src" 2>/dev/null || echo "$src")
    echo "##vso[task.logissue type=$level;sourcepath=$src;linenumber=$ln;columnnumber=$col]$msg"
  done
fi

if (( rc == 0 )); then log "Stage 2 passed"; else vso_error "Stage 2 failed: OpenAPI/APIC lint errors (see annotations and out/spectral.xml)"; fi
exit $rc

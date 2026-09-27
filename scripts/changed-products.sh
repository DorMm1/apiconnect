#!/usr/bin/env bash
# Stage 0 - compute the set of Product files to validate/publish.
#
#   changed-products.sh BASE_REF HEAD_REF OUT_FILE
#
# Writes one repo-relative Product path per line to OUT_FILE:
#   * every changed/added/renamed product file under projects/*/products/
#   * every product whose apis[].$ref resolves to a changed/added/renamed API file under projects/*/apis/
# Files deleted in Git are reported as warnings only: this pipeline never deletes anything from APIC.
#
# BASE_REF may be the empty-tree hash (bootstrap) -> every product is selected.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
require_cmd git yq realpath

BASE="${1:?BASE_REF required}"
HEAD_REF="${2:-HEAD}"
OUT="${3:?OUT_FILE required}"

declare -A SELECTED=()

select_products_for_api() {
  local api="$1" proj="${1%%/apis/*}" p ref
  shopt -s nullglob
  for p in "$proj"/products/*.yaml "$proj"/products/*.yml; do
    while IFS= read -r ref; do
      [[ -n "$ref" ]] || continue
      if [[ "$(resolve_ref "$p" "$ref")" == "$api" ]]; then
        SELECTED["$p"]=1
      fi
    done < <(yq -r '.apis[]."$ref" // ""' "$p")
  done
  shopt -u nullglob
}

log "Diffing $BASE..$HEAD_REF under projects/"
while IFS= read -r f; do
  f=${f//\\//}
  case "$f" in
    projects/*/products/*.yaml|projects/*/products/*.yml) SELECTED["$f"]=1 ;;
    projects/*/apis/*.yaml|projects/*/apis/*.yml)         select_products_for_api "$f" ;;
    *) log "ignored (not an API/product file): $f" ;;
  esac
done < <(git diff --name-only --diff-filter=ACMR "$BASE" "$HEAD_REF" -- projects/)

while IFS= read -r f; do
  [[ -n "$f" ]] || continue
  vso_warning "Deleted in Git but NOT removed from APIC (use the lifecycle procedure): $f"
done < <(git diff --name-only --diff-filter=D "$BASE" "$HEAD_REF" -- projects/)

: > "$OUT"
if (( ${#SELECTED[@]} )); then
  printf '%s\n' "${!SELECTED[@]}" | sort > "$OUT"
fi

log "Selected ${#SELECTED[@]} product(s):"
sed 's/^/  - /' "$OUT"

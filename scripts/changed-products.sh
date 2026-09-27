#!/usr/bin/env bash
# Stage 0 - compute the set of Product files to validate/publish.
#
#   changed-products.sh BASE_REF HEAD_REF OUT_FILE [--env ENV]
#
# Writes one repo-relative Product path per line to OUT_FILE:
#   * every changed/added/renamed product file under projects/<project>/<env>/products/
#   * every product whose apis[].$ref resolves to a changed/added/renamed API under projects/<project>/<env>/apis/
# --env restricts the result to one environment folder (a publish stage only cares about its own environment).
# Files deleted in Git are reported as warnings only: this pipeline never deletes anything from APIC.
#
# BASE_REF may be the empty-tree hash (bootstrap) -> every product (of the environment) is selected.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
require_cmd git yq realpath

BASE="${1:?BASE_REF required}"
HEAD_REF="${2:?HEAD_REF required}"
OUT="${3:?OUT_FILE required}"
ENV_FILTER=""
shift 3
while [[ $# -gt 0 ]]; do
  case "$1" in
    --env) ENV_FILTER="$2"; shift 2 ;;
    *) vso_error "unknown option $1"; exit 2 ;;
  esac
done

declare -A SELECTED=()

select_products_for_api() {
  local api="$1" dir="${1%/apis/*}" p ref
  shopt -s nullglob
  for p in "$dir"/products/*.yaml "$dir"/products/*.yml; do
    while IFS= read -r ref; do
      [[ -n "$ref" ]] || continue
      [[ "$(resolve_ref "$p" "$ref")" == "$api" ]] && SELECTED["$p"]=1
    done < <(yq -r '.apis[]."$ref" // ""' "$p")
  done
  shopt -u nullglob
}

log "Diffing $BASE..$HEAD_REF under projects/${ENV_FILTER:+ (env=$ENV_FILTER)}"
while IFS= read -r f; do
  f=${f//\\//}
  [[ -z "$ENV_FILTER" || "$(path_env "$f")" == "$ENV_FILTER" ]] || continue
  case "$(path_kind "$f")" in
    products) SELECTED["$f"]=1 ;;
    apis)     select_products_for_api "$f" ;;
    *)        log "ignored (not projects/<project>/<env>/{apis,products}/*.yaml): $f" ;;
  esac
done < <(git diff --name-only --diff-filter=ACMR "$BASE" "$HEAD_REF" -- projects/)

while IFS= read -r f; do
  [[ -n "$f" ]] || continue
  [[ -z "$ENV_FILTER" || "$(path_env "$f")" == "$ENV_FILTER" ]] || continue
  vso_warning "Deleted in Git but NOT removed from APIC (use the lifecycle procedure): $f"
done < <(git diff --name-only --diff-filter=D "$BASE" "$HEAD_REF" -- projects/)

: > "$OUT"
if (( ${#SELECTED[@]} )); then
  printf '%s\n' "${!SELECTED[@]}" | sort > "$OUT"
fi

log "Selected ${#SELECTED[@]} product(s):"
sed 's/^/  - /' "$OUT"

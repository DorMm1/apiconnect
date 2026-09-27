#!/usr/bin/env bash
# Prints the API files referenced by one or more Product files (resolved, repo-relative, unique).
#
#   product-apis.sh PRODUCT_FILE...
#   product-apis.sh --list PRODUCTS_LIST_FILE
set -euo pipefail
source "$(dirname "$0")/lib.sh"
require_cmd yq realpath

if [[ "${1:-}" == "--list" ]]; then
  mapfile -t PRODUCTS < <(read_list "${2:?list file required}")
else
  PRODUCTS=("$@")
fi

for p in "${PRODUCTS[@]}"; do
  [[ -f "$p" ]] || { vso_error "Product file not found: $p"; exit 1; }
  while IFS= read -r ref; do
    [[ -n "$ref" ]] || continue
    resolve_ref "$p" "$ref"
  done < <(yq -r '.apis[]."$ref" // ""' "$p")
done | sort -u

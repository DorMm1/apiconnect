#!/usr/bin/env bash
# Stage 3 - APIC definition validity (offline) with the IBM API Connect toolkit.
#
#   validate-apic.sh PRODUCTS_LIST_FILE
#
# 1. Repository policy: every product must reference its APIs with a relative $ref that resolves
#    to a file in the same projects/<project>/<env>/apis/ folder (publishes are self-contained from Git;
#    no name:version refs, no cross-project or cross-environment references).
# 2. `apic validate <product>` validates the product AND each referenced API against the IBM
#    extensions (v10.0.8 CLI reference: "Validate a product definition and its referenced APIs").
set -euo pipefail
source "$(dirname "$0")/lib.sh"
require_cmd apic yq realpath

mapfile -t PRODUCTS < <(read_list "${1:?products list file required}")
(( ${#PRODUCTS[@]} )) || { log "Stage 3: no products"; exit 0; }

vso_section "Stage 3 - apic validate (${#PRODUCTS[@]} product(s))"
apic --accept-license version >/dev/null 2>&1 || true   # accept license once, silently
rc=0

for p in "${PRODUCTS[@]}"; do
  [[ -f "$p" ]] || { vso_error "Product file not found" "$p"; rc=1; continue; }
  if [[ "$(path_kind "$p")" != products ]]; then
    vso_error "Product must live under projects/<project>/<env>/products/" "$p"; rc=1; continue
  fi
  envdir="${p%/products/*}"     # projects/<project>/<env>

  n=$(yq '.apis | length' "$p")
  if [[ "$n" -eq 0 ]]; then vso_error "Product declares no apis" "$p"; rc=1; continue; fi

  policy_ok=1
  while IFS=$'\t' read -r key ref; do
    if [[ -z "$ref" || "$ref" == "null" ]]; then
      vso_error "apis.$key must use a relative \$ref to a file under $envdir/apis/ (name:version references are not allowed)" "$p"
      policy_ok=0; continue
    fi
    f=$(resolve_ref "$p" "$ref")
    if [[ ! -f "$f" ]]; then
      vso_error "apis.$key \$ref '$ref' does not resolve to a file ($f)" "$p"; policy_ok=0
    elif [[ "$f" != "$envdir"/apis/* ]]; then
      vso_error "apis.$key \$ref '$ref' points outside $envdir/apis/ (cross-project / cross-environment references are not allowed)" "$p"; policy_ok=0
    fi
  done < <(yq -r '.apis | to_entries[] | [.key, (.value."$ref" // "null")] | @tsv' "$p")
  (( policy_ok )) || { rc=1; continue; }

  log "apic validate $p"
  if out=$(apic validate "$p" 2>&1); then
    echo "$out" | sed 's/^/    /'
    # Belt and braces: one "Validated ..." line is expected for the product and one per API.
    # If the toolkit ever returns 0 on a failure, this still catches it. Adjust if your toolkit wording differs.
    expected=$((n + 1)); got=$(grep -c 'Validated ' <<< "$out" || true)
    if (( got < expected )); then
      vso_warning "apic validate printed $got 'Validated' line(s), expected $expected - inspect the output above" "$p"
    fi
  else
    echo "$out" | sed 's/^/    /'
    vso_error "apic validate failed: $(tail -n 1 <<< "$out")" "$p"; rc=1
  fi
done

if (( rc == 0 )); then log "Stage 3 passed"; else vso_error "Stage 3 failed: APIC validation errors (see annotations)"; fi
exit $rc

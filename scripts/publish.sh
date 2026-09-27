#!/usr/bin/env bash
# Publish - `apic products:publish` for every product in the list, then assert state == published.
#
#   publish.sh --catalog <catalog> PRODUCTS_LIST_FILE
#
# Needs APIC_SERVER/APIC_ORG and an existing toolkit session. Never deletes or retires anything.
# Publishing a product name:version that already exists in the catalog updates it in place
# (used for non-breaking changes); a MAJOR change must arrive as a new product version.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
require_cmd apic yq jq
require_env APIC_SERVER APIC_ORG

CATALOG=""
while [[ $# -gt 1 ]]; do
  case "$1" in
    --catalog) CATALOG="$2" ;;
    *) vso_error "unknown option $1"; exit 2 ;;
  esac
  shift 2
done
LIST="${1:?products list file required}"
[[ -n "$CATALOG" ]] || { vso_error "--catalog is required"; exit 2; }

mapfile -t PRODUCTS < <(read_list "$LIST")
(( ${#PRODUCTS[@]} )) || { log "Publish: nothing to publish to '$CATALOG'"; exit 0; }

mkdir -p out/publish
vso_section "Publish ${#PRODUCTS[@]} product(s) -> org '$APIC_ORG', catalog '$CATALOG'"
FAIL=0

product_state() { # NAME:VERSION -> state or empty
  apic products:get $(apic_conn) --catalog "$CATALOG" --scope catalog --fields state \
       --format json --output - "$1" 2>/dev/null | jq -r '.state // empty'
}

for p in "${PRODUCTS[@]}"; do
  name=$(yq_str "$p" '.info.name'); ver=$(yq_str "$p" '.info.version')
  [[ -n "$name" && -n "$ver" ]] || { vso_error "info.name and info.version are required" "$p"; FAIL=1; continue; }

  EXTRA=()
  before=$(product_state "$name:$ver")
  if [[ -n "$before" ]]; then
    log "REPUBLISH $name:$ver (current state: $before)"
    # VERIFY: --migrate_subscriptions = "Migrate subscription when republish product" (v10.0.8 CLI reference)
    EXTRA=(--migrate_subscriptions)
  else
    log "PUBLISH   $name:$ver (new in catalog '$CATALOG')"
  fi

  if apic products:publish $(apic_conn) --catalog "$CATALOG" "${EXTRA[@]}" \
        --format json --output - "$p" > "out/publish/${name}_${ver}.json" 2> "out/publish/${name}_${ver}.err"; then
    :
  else
    sed 's/^/    /' "out/publish/${name}_${ver}.err"
    vso_error "products:publish failed for $name:$ver -> '$CATALOG' ($(tail -n1 "out/publish/${name}_${ver}.err"))" "$p"
    FAIL=1; continue
  fi

  state=$(product_state "$name:$ver")
  if [[ "$state" == "published" ]]; then
    log "OK        $name:$ver is published in '$CATALOG'"
  else
    vso_error "$name:$ver ended in state '${state:-unknown}' in catalog '$CATALOG'" "$p"; FAIL=1
  fi
done

if (( FAIL == 0 )); then log "Publish to '$CATALOG' completed"; else vso_error "Publish to '$CATALOG' had failures"; fi
exit $FAIL

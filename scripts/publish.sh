#!/usr/bin/env bash
# Publish - `apic products:publish` for every product in the list, then assert state == published.
#
#   publish.sh --stage <stage> PRODUCTS_LIST_FILE
#
# The catalog is derived per product: projects/<project>/<folder>/products/x.yaml + stage -> catalog_for(project, stage)
# (config/topology.yml pattern, or projects/<project>/project.yaml override). Every product in the list must
# belong to the stage's folder.
#
# Needs APIC_SERVER/APIC_ORG of the stage's instance and an existing toolkit session. Never deletes or retires anything.
# Publishing a product name:version that already exists in the catalog updates it in place (used for non-breaking
# changes); a MAJOR change must arrive as a new product version.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
require_cmd apic yq jq
require_env APIC_SERVER APIC_ORG

STAGE=""
while [[ $# -gt 1 ]]; do
  case "$1" in
    --stage) STAGE="$2" ;;
    *) vso_error "unknown option $1"; exit 2 ;;
  esac
  shift 2
done
LIST="${1:?products list file required}"
[[ -n "$STAGE" ]] || { vso_error "--stage is required"; exit 2; }
require_stage "$STAGE"; FOLDER=$(stage_folder "$STAGE"); INSTANCE=$(stage_instance "$STAGE")

mapfile -t PRODUCTS < <(read_list "$LIST")
(( ${#PRODUCTS[@]} )) || { log "Publish: nothing to publish for stage '$STAGE'"; exit 0; }

# Guard before any toolkit call: every file must belong to the stage's folder
for p in "${PRODUCTS[@]}"; do
  if [[ "$(path_kind "$p")" != products || "$(path_folder "$p")" != "$FOLDER" ]]; then
    vso_error "Refusing to publish: '$p' is not under projects/<project>/$FOLDER/products/ (stage '$STAGE' publishes folder '$FOLDER')" "$p"
    exit 2
  fi
done

mkdir -p out/publish
vso_section "Publish ${#PRODUCTS[@]} product(s) -> stage '$STAGE' (folder '$FOLDER' -> instance '$INSTANCE', org '$APIC_ORG', server '$APIC_SERVER')"
FAIL=0

product_state() { # CATALOG NAME:VERSION -> state or empty
  apic products:get $(apic_conn) --catalog "$1" --scope catalog --fields state \
       --format json --output - "$2" 2>/dev/null | jq -r '.state // empty' 2>/dev/null || true
}

for p in "${PRODUCTS[@]}"; do
  project=$(path_project "$p"); catalog=$(catalog_for "$project" "$STAGE")
  name=$(yq_str "$p" '.info.name'); ver=$(yq_str "$p" '.info.version')
  [[ -n "$name" && -n "$ver" ]] || { vso_error "info.name and info.version are required" "$p"; FAIL=1; continue; }
  tag="${project}_${name}_${ver}"

  EXTRA=()
  before=$(product_state "$catalog" "$name:$ver")
  if [[ -n "$before" ]]; then
    log "REPUBLISH $name:$ver -> catalog '$catalog' (current state: $before)"
    # VERIFY: --migrate_subscriptions = "Migrate subscription when republish product" (v10.0.8 CLI reference)
    EXTRA=(--migrate_subscriptions)
  else
    log "PUBLISH   $name:$ver -> catalog '$catalog' (new in catalog)"
  fi

  if apic products:publish $(apic_conn) --catalog "$catalog" "${EXTRA[@]}" \
        --format json --output - "$p" > "out/publish/${tag}.json" 2> "out/publish/${tag}.err"; then
    :
  else
    sed 's/^/    /' "out/publish/${tag}.err"
    vso_error "products:publish failed for $name:$ver -> '$catalog' ($(tail -n1 "out/publish/${tag}.err"))" "$p"
    FAIL=1; continue
  fi

  state=$(product_state "$catalog" "$name:$ver")
  if [[ "$state" == "published" ]]; then
    log "OK        $name:$ver is published in '$catalog'"
  else
    vso_error "$name:$ver ended in state '${state:-unknown}' in catalog '$catalog'" "$p"; FAIL=1
  fi
done

if (( FAIL == 0 )); then log "Publish for stage '$STAGE' completed"; else vso_error "Publish for stage '$STAGE' had failures"; fi
exit $FAIL

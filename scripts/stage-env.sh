#!/usr/bin/env bash
# Resolves the API Connect instance behind a stage from config/topology.yml and prints its connection settings.
#
#   stage-env.sh --stage <stage>          # prints  export APIC_SERVER=... APIC_ORG=... APIC_GATEWAY=... APIC_INSTANCE=...
#   stage-env.sh --stage <stage> --vso    # prints Azure DevOps ##vso[task.setvariable] commands instead
#
# Typical use:  eval "$(scripts/stage-env.sh --stage rc)"
# The API key is deliberately NOT here (variable group apic-<instance>, secret APIC_APIKEY).
set -euo pipefail
source "$(dirname "$0")/lib.sh"
require_cmd yq

STAGE=""; VSO=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --stage) STAGE="$2"; shift 2 ;;
    --vso)   VSO=1; shift ;;
    *) vso_error "unknown option $1"; exit 2 ;;
  esac
done
[[ -n "$STAGE" ]] || { vso_error "--stage is required"; exit 2; }
require_stage "$STAGE"
INSTANCE=$(stage_instance "$STAGE")
require_instance "$INSTANCE"

SERVER=$(instance_server "$INSTANCE"); ORG=$(instance_org "$INSTANCE"); GW=$(instance_gateway "$INSTANCE")
if [[ "$SERVER" == *example.com* ]]; then
  vso_warning "Instance '$INSTANCE' still uses the placeholder ingress '$SERVER' - edit $TOPOLOGY_FILE"
fi

if (( VSO )); then
  echo "##vso[task.setvariable variable=APIC_INSTANCE]$INSTANCE"
  echo "##vso[task.setvariable variable=APIC_SERVER]$SERVER"
  echo "##vso[task.setvariable variable=APIC_ORG]$ORG"
  echo "##vso[task.setvariable variable=APIC_GATEWAY]$GW"
  echo "stage '$STAGE' -> folder '$(stage_folder "$STAGE")' -> instance '$INSTANCE' ($SERVER, org '$ORG')"
else
  printf 'export APIC_INSTANCE=%q APIC_SERVER=%q APIC_ORG=%q APIC_GATEWAY=%q\n' "$INSTANCE" "$SERVER" "$ORG" "$GW"
fi

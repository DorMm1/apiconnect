#!/usr/bin/env bash
# Shared helpers for pipeline scripts. Source it, do not execute it:
#   source "$(dirname "$0")/lib.sh"
#
# All scripts are written to run on ubuntu-latest Azure DevOps agents (bash 5, GNU coreutils).
# The ##vso[...] lines are Azure DevOps logging commands: they surface as annotations in the
# build summary and turn the PR status check red when type=error.

log()          { echo "[$(date -u +%H:%M:%S)] $*"; }
vso_error()    { echo "##vso[task.logissue type=error${2:+;sourcepath=$2}${3:+;linenumber=$3}]$1"; }
vso_warning()  { echo "##vso[task.logissue type=warning${2:+;sourcepath=$2}${3:+;linenumber=$3}]$1"; }
vso_setvar()   { echo "##vso[task.setvariable variable=$1${3:+;isOutput=true}]$2"; }
vso_section()  { echo "##[section]$*"; }

# read_list FILE... -> unique, non-empty, trimmed lines from one or more list files (missing files are ignored)
read_list() { cat "$@" 2>/dev/null | sed -e 's/\r$//' -e '/^[[:space:]]*$/d' | sort -u; }

require_cmd() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || { vso_error "Required tool not on PATH: $c"; exit 2; }
  done
}

require_env() {
  local v
  for v in "$@"; do
    [[ -n "${!v:-}" ]] || { vso_error "Required environment variable is empty: $v"; exit 2; }
  done
}

# yq_str FILE EXPR -> string value or empty (never the literal "null")
yq_str() { yq -r "$2 // \"\"" "$1" 2>/dev/null; }

# Common APIC connection flags; requires APIC_SERVER and APIC_ORG in the environment
apic_conn() { echo "--server ${APIC_SERVER} --org ${APIC_ORG}"; }

# resolve_ref PRODUCT_FILE REF -> repo-relative path of a $ref target
resolve_ref() { realpath -m --relative-to=. "$(dirname "$1")/$2"; }

# ---------------------------------------------------------------------------------------------
# Topology: projects/<project>/<folder>/{apis,products}/<file>.yaml   (see config/topology.yml)
# A stage publishes ONE folder to ONE catalog on ONE instance.
# ---------------------------------------------------------------------------------------------
TOPOLOGY_FILE="${TOPOLOGY_FILE:-config/topology.yml}"

# path_project PATH -> project folder name
path_project() { local p="${1#projects/}"; echo "${p%%/*}"; }
# path_folder PATH -> version folder name (dev|test|prod)
path_folder()  { local p="${1#projects/}"; p="${p#*/}"; echo "${p%%/*}"; }
# path_kind PATH -> apis|products|other
path_kind() {
  case "$1" in
    projects/*/*/products/*.yaml|projects/*/*/products/*.yml) echo products ;;
    projects/*/*/apis/*.yaml|projects/*/*/apis/*.yml)         echo apis ;;
    *) echo other ;;
  esac
}

# list_stages -> stage names in pipeline order
list_stages()    { yq -r '.stages[].name' "$TOPOLOGY_FILE"; }
# list_folders -> distinct folder names, in order of first appearance
list_folders()   { yq -r '.stages[].folder' "$TOPOLOGY_FILE" | awk '!seen[$0]++'; }
# list_instances -> instance names
list_instances() { yq -r '.instances | keys | .[]' "$TOPOLOGY_FILE"; }

# stage_attr STAGE ATTR -> attribute value or empty
stage_attr() { STAGE="$1" ATTR="$2" yq -r '.stages[] | select(.name == strenv(STAGE)) | .[strenv(ATTR)] // ""' "$TOPOLOGY_FILE" 2>/dev/null; }
# require_stage STAGE -> exits 2 if the stage is not declared
require_stage() {
  [[ -n "$(stage_attr "$1" name)" ]] || { vso_error "Unknown stage '$1' (see $TOPOLOGY_FILE)"; exit 2; }
}
stage_folder()          { stage_attr "$1" folder; }
stage_instance()        { stage_attr "$1" instance; }
stage_trigger()         { stage_attr "$1" trigger; }
stage_after()           { stage_attr "$1" after; }
stage_catalog_pattern() { stage_attr "$1" catalog; }
# folder_stages FOLDER -> stages that publish this folder, in order
folder_stages() { FOLDER="$1" yq -r '.stages[] | select(.folder == strenv(FOLDER)) | .name' "$TOPOLOGY_FILE"; }
# require_folder FOLDER -> exits 2 if no stage publishes the folder
require_folder() {
  list_folders | grep -qx "$1" || { vso_error "Unknown folder '$1' (see $TOPOLOGY_FILE)"; exit 2; }
}
# catalog_for PROJECT STAGE -> catalog name (project.yaml override wins over the pattern)
catalog_for() {
  local project="$1" stage="$2" override=""
  [[ -f "projects/$project/project.yaml" ]] && override=$(yq_str "projects/$project/project.yaml" ".catalogs.\"$stage\"")
  if [[ -n "$override" ]]; then echo "$override"; else stage_catalog_pattern "$stage" | sed "s/{project}/$project/g"; fi
}

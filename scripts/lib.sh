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
# Topology: projects/<project>/<env>/{apis,products}/<file>.yaml   (see config/environments.yml)
# ---------------------------------------------------------------------------------------------
ENVIRONMENTS_FILE="${ENVIRONMENTS_FILE:-config/environments.yml}"

# path_project PATH -> project folder name
path_project() { local p="${1#projects/}"; echo "${p%%/*}"; }
# path_env PATH -> environment folder name (dev|test|prod)
path_env()     { local p="${1#projects/}"; p="${p#*/}"; echo "${p%%/*}"; }
# path_kind PATH -> apis|products|other
path_kind() {
  case "$1" in
    projects/*/*/products/*.yaml|projects/*/*/products/*.yml) echo products ;;
    projects/*/*/apis/*.yaml|projects/*/*/apis/*.yml)         echo apis ;;
    *) echo other ;;
  esac
}

# list_envs -> environment names
list_envs() { yq -r '.environments | keys | .[]' "$ENVIRONMENTS_FILE"; }
# stage_env STAGE -> environment that owns the stage (fails if unknown)
stage_env() {
  local e
  e=$(STAGE="$1" yq -r '.environments | to_entries[] | .key as $k | .value.stages[] | select(.name == strenv(STAGE)) | $k' "$ENVIRONMENTS_FILE" 2>/dev/null | head -n1)
  [[ -n "$e" ]] || { vso_error "Unknown stage '$1' (see $ENVIRONMENTS_FILE)"; exit 2; }
  echo "$e"
}
# stage_catalog_pattern STAGE -> e.g. "{project}-dev"
stage_catalog_pattern() {
  STAGE="$1" yq -r '.environments[].stages[] | select(.name == strenv(STAGE)) | .catalog' "$ENVIRONMENTS_FILE"
}
# env_stages ENV -> stage names of an environment, in order
env_stages() { ENV="$1" yq -r '.environments[strenv(ENV)].stages[].name' "$ENVIRONMENTS_FILE"; }
# catalog_for PROJECT STAGE -> catalog name (project.yaml override wins over the pattern)
catalog_for() {
  local project="$1" stage="$2" override=""
  [[ -f "projects/$project/project.yaml" ]] && override=$(yq_str "projects/$project/project.yaml" ".catalogs.\"$stage\"")
  if [[ -n "$override" ]]; then echo "$override"; else stage_catalog_pattern "$stage" | sed "s/{project}/$project/g"; fi
}

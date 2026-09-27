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

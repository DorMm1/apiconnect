#!/usr/bin/env bash
# Promotion helper - copies a project's definitions from one version folder to the next and shows the diff.
#
#   promote.sh <project> <from-folder> <to-folder> [--prune]
#
#   projects/<project>/<from>/{apis,products}/*  ->  projects/<project>/<to>/{apis,products}/
#
# Typical path: dev -> test (feeds <project>-rc after approval), test -> prod (feeds <project> after approval).
# The result is an ordinary working-tree change: review `git diff`, commit on a branch, open a pull request.
# Files that exist only in the target are kept (and listed) unless --prune is given; remember that deleting a
# file never removes anything from API Connect.
#
# Definitions are meant to be byte-identical across folders - catalog-specific values belong in
# x-ibm-configuration.catalogs.<catalog>.properties inside the file, keyed by ALL catalogs of the project.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
require_cmd git yq

PROJECT="${1:?project required}"; FROM="${2:?from-folder required}"; TO="${3:?to-folder required}"; PRUNE=0
[[ "${4:-}" == "--prune" ]] && PRUNE=1

require_folder "$FROM"; require_folder "$TO"
SRC="projects/$PROJECT/$FROM"; DST="projects/$PROJECT/$TO"
[[ -d "$SRC" ]] || { vso_error "Source folder not found: $SRC"; exit 2; }
[[ "$FROM" != "$TO" ]] || { vso_error "from-folder and to-folder are the same"; exit 2; }

mkdir -p "$DST/apis" "$DST/products"
copied=0
for kind in apis products; do
  shopt -s nullglob
  for f in "$SRC/$kind"/*.yaml "$SRC/$kind"/*.yml; do
    cp -f "$f" "$DST/$kind/$(basename "$f")"; copied=$((copied+1))
  done
  for f in "$DST/$kind"/*.yaml "$DST/$kind"/*.yml; do
    if [[ ! -e "$SRC/$kind/$(basename "$f")" ]]; then
      if (( PRUNE )); then rm -f "$f"; log "pruned $f (not in $SRC)"; else vso_warning "Only in target, kept: $f (use --prune to remove)"; fi
    fi
  done
  shopt -u nullglob
done

log "Copied $copied file(s): $SRC -> $DST"
echo
echo "Versions now in $DST:"
shopt -s nullglob
for f in "$DST"/products/*.y*ml; do printf '  product %-30s %s\n' "$(yq_str "$f" '.info.name')" "$(yq_str "$f" '.info.version')"; done
for f in "$DST"/apis/*.y*ml;     do printf '  api     %-30s %s\n' "$(yq_str "$f" '.info["x-ibm-name"]')" "$(yq_str "$f" '.info.version')"; done
shopt -u nullglob
echo
git --no-pager diff --stat -- "$DST" || true
echo
targets=""
for s in $(folder_stages "$TO"); do targets+="$s -> $(catalog_for "$PROJECT" "$s") [$(stage_trigger "$s")]  "; done
echo "Next: review 'git diff -- $DST', commit on a branch, open a pull request. Merging publishes: $targets"

#!/usr/bin/env bash
# Stage 4 (git mode) over a change set produced by changeset.sh: one oasdiff run per folder,
# each against that folder's own baseline (OUT_DIR/base.<folder>).
#
#   validate-compat.sh OUT_DIR
set -euo pipefail
source "$(dirname "$0")/lib.sh"
DIR="${1:?OUT_DIR required}"
rc=0; ran=0
shopt -s nullglob
for f in "$DIR"/products.*.txt; do
  folder="${f##*/products.}"; folder="${folder%.txt}"
  [[ -s "$f" ]] || continue
  base=$(cat "$DIR/base.$folder")
  log "Folder '$folder' (published by: $(folder_stages "$folder" | tr '\n' ' ')): baseline $base"
  ran=1
  "$(dirname "$0")/compat-check.sh" --mode git --base "$base" "$f" || rc=1
done
(( ran )) || log "Stage 4: nothing to compare"
exit $rc

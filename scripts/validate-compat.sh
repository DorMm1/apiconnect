#!/usr/bin/env bash
# Stage 4 (git mode) over a change set produced by changeset.sh: one oasdiff run per environment,
# each against that environment's own baseline (OUT_DIR/base.<env>).
#
#   validate-compat.sh OUT_DIR
set -euo pipefail
source "$(dirname "$0")/lib.sh"
DIR="${1:?OUT_DIR required}"
rc=0; ran=0
shopt -s nullglob
for f in "$DIR"/products.*.txt; do
  env="${f##*/products.}"; env="${env%.txt}"
  [[ -s "$f" ]] || continue
  base=$(cat "$DIR/base.$env")
  log "Environment '$env': baseline $base"
  ran=1
  "$(dirname "$0")/compat-check.sh" --mode git --base "$base" "$f" || rc=1
done
(( ran )) || log "Stage 4: nothing to compare"
exit $rc

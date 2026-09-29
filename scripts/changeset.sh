#!/usr/bin/env bash
# Stage 0 orchestrator - computes change sets per folder/stage and writes them to OUT_DIR.
#
#   changeset.sh --mode pr    --base <git-ref>  OUT_DIR   # PR: every folder, baseline = the target branch
#   changeset.sh --mode main                    OUT_DIR   # main: every folder, baseline = tag of the folder's first stage
#   changeset.sh --mode stage --stage <stage>   OUT_DIR   # one stage: its folder only, baseline = tag published/<stage>
#
# OUT_DIR/products.txt            union of selected products
# OUT_DIR/apis.txt                APIs referenced by those products
# OUT_DIR/products.<folder>.txt   selected products of one folder
# OUT_DIR/base.<folder>           git ref used as baseline for that folder (for compat-check --mode git)
# OUT_DIR/stages.txt              (main mode) "<stage> <true|false>" - whether the stage's folder changed since its tag
#
# A missing published/<stage> tag means "never published from Git" -> baseline = empty tree -> everything selected.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
require_cmd git yq

MODE=""; BASE=""; STAGE=""
while [[ $# -gt 1 ]]; do
  case "$1" in
    --mode)  MODE="$2" ;;
    --base)  BASE="$2" ;;
    --stage) STAGE="$2" ;;
    *) vso_error "unknown option $1"; exit 2 ;;
  esac
  shift 2
done
OUT="${1:?OUT_DIR required}"
mkdir -p "$OUT"
rm -f "$OUT"/products*.txt "$OUT"/apis.txt "$OUT"/base.* "$OUT"/stages.txt

EMPTY_TREE=$(git hash-object -t tree /dev/null)
HERE="$(dirname "$0")"

# tag_base STAGE -> commit of tag published/STAGE, or the empty tree
tag_base() {
  local tag="published/$1"
  git fetch -q origin "+refs/tags/${tag}:refs/tags/${tag}" 2>/dev/null || true
  git rev-parse -q --verify "refs/tags/${tag}^{commit}" 2>/dev/null || echo "$EMPTY_TREE"
}
describe_base() { [[ "$1" == "$EMPTY_TREE" ]] && echo "<never published>" || git log -1 --format='%h %s' "$1"; }

case "$MODE" in
  pr)
    [[ -n "$BASE" ]] || { vso_error "--base required in pr mode"; exit 2; }
    for folder in $(list_folders); do
      echo "$BASE" > "$OUT/base.$folder"
      bash "$HERE/changed-products.sh" "$BASE" HEAD "$OUT/products.$folder.txt" --folder "$folder"
    done
    ;;
  main)
    for folder in $(list_folders); do
      first=$(folder_stages "$folder" | head -n1)
      base=$(tag_base "$first")
      echo "$base" > "$OUT/base.$folder"
      log "folder '$folder': baseline = published/$first -> $(describe_base "$base")"
      bash "$HERE/changed-products.sh" "$base" HEAD "$OUT/products.$folder.txt" --folder "$folder"
    done
    for stage in $(list_stages); do
      folder=$(stage_folder "$stage"); sbase=$(tag_base "$stage")
      bash "$HERE/changed-products.sh" "$sbase" HEAD "$OUT/.stage.$stage.txt" --folder "$folder" >/dev/null 2>&1
      if [[ -s "$OUT/.stage.$stage.txt" ]]; then echo "$stage true"; else echo "$stage false"; fi >> "$OUT/stages.txt"
      rm -f "$OUT/.stage.$stage.txt"
    done
    log "Stages with unpublished changes:"; sed 's/^/  /' "$OUT/stages.txt"
    ;;
  stage)
    [[ -n "$STAGE" ]] || { vso_error "--stage required in stage mode"; exit 2; }
    require_stage "$STAGE"
    folder=$(stage_folder "$STAGE"); base=$(tag_base "$STAGE")
    echo "$base" > "$OUT/base.$folder"
    if [[ "$base" == "$EMPTY_TREE" ]]; then
      vso_warning "No tag published/$STAGE yet: bootstrapping - every product of folder '$folder' will be published"
    else
      log "stage '$STAGE' (folder '$folder' -> instance '$(stage_instance "$STAGE")'): last publish = $(describe_base "$base")"
    fi
    bash "$HERE/changed-products.sh" "$base" HEAD "$OUT/products.$folder.txt" --folder "$folder"
    ;;
  *) vso_error "--mode must be pr, main or stage"; exit 2 ;;
esac

cat "$OUT"/products.*.txt 2>/dev/null | sed '/^$/d' | sort -u > "$OUT/products.txt"
bash "$HERE/product-apis.sh" --list "$OUT/products.txt" > "$OUT/apis.txt"
log "Total: $(wc -l < "$OUT/products.txt") product(s), $(wc -l < "$OUT/apis.txt") API file(s)"

#!/usr/bin/env bash
# Stage 4 - backward-compatibility gate (oasdiff).
#
#   compat-check.sh --mode git  --base <git-ref> PRODUCTS_LIST_FILE   # PR / pre-merge: baseline = same file at <git-ref>
#   compat-check.sh --mode live --stage <stage>  PRODUCTS_LIST_FILE   # pre-publish: baseline = what is published in the
#                                                                      # stage's catalog of each product's project
#
# Policy (see README "Backward-compatibility policy"):
#   * oasdiff ERR-level changes are BREAKING and fail the gate unless info.version MAJOR was bumped.
#   * WARN-level changes are reported only.
#   * Explicit, reviewed exceptions live in config/compat-ignore.txt (oasdiff --err-ignore format).
#   * x-ibm-* extensions are ignored by oasdiff -> assembly/policy changes never count as contract changes.
#
# live mode needs APIC_SERVER/APIC_ORG of the stage's instance and an existing toolkit session.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
require_cmd oasdiff yq jq realpath

MODE=git; BASE=origin/main; STAGE=""
while [[ $# -gt 1 ]]; do
  case "$1" in
    --mode)  MODE="$2" ;;
    --base)  BASE="$2" ;;
    --stage) STAGE="$2" ;;
    *) vso_error "unknown option $1"; exit 2 ;;
  esac
  shift 2
done
LIST="${1:?products list file required}"

case "$MODE" in
  git)  require_cmd git ;;
  live) require_cmd apic; require_env APIC_SERVER APIC_ORG; [[ -n "$STAGE" ]] || { vso_error "--stage required in live mode"; exit 2; }; require_stage "$STAGE" ;;
  *) vso_error "--mode must be git or live"; exit 2 ;;
esac

mapfile -t APIS < <("$(dirname "$0")/product-apis.sh" --list "$LIST")
(( ${#APIS[@]} )) || { log "Stage 4: no API files"; exit 0; }

mkdir -p out/compat
IGNORE_ARGS=()
if [[ -f config/compat-ignore.txt ]]; then
  grep -Ev '^\s*(#|$)' config/compat-ignore.txt > out/compat/ignore.txt || true
  [[ -s out/compat/ignore.txt ]] && IGNORE_ARGS=(--err-ignore out/compat/ignore.txt)
fi

vso_section "Stage 4 - oasdiff breaking, mode=$MODE (${#APIS[@]} API(s))"
FAIL=0

# baseline_git API_FILE OUT -> 0 if a baseline exists
baseline_git() {
  git show "$BASE:$1" > "$2" 2>/dev/null
}

# baseline_live CATALOG NAME VERSION OUT -> 0 if a baseline exists; picks the published same-MAJOR version
# that is the current version itself (republish) or, failing that, the highest one below it.
baseline_live() {
  local catalog="$1" name="$2" ver="$3" out="$4" major="${3%%.*}" pick=""
  local versions
  versions=$(apic apis:list $(apic_conn) --catalog "$catalog" --scope catalog \
               --fields version --format json --output - "$name" 2>/dev/null \
             | jq -r --arg m "$major" '(.results // .)[]? | .version // empty | select(split(".")[0] == $m)' \
             | sort -uV) || true
  [[ -n "$versions" ]] || return 1
  if grep -qx "$ver" <<< "$versions"; then
    pick="$ver"
  else
    pick=$(printf '%s\n' "$versions" "$ver" | sort -V | grep -B1 -x "$ver" | head -n1)
    [[ "$pick" == "$ver" ]] && pick=""          # nothing below the current version
  fi
  [[ -n "$pick" ]] || return 1
  apic apis:get $(apic_conn) --catalog "$catalog" --scope catalog --format yaml --output - "$name:$pick" > "$out"
  # VERIFY on your tenant: apis:get may return the bare definition or an envelope with the definition under .api
  if ! yq -e '.openapi // .swagger' "$out" >/dev/null 2>&1; then
    yq -e '.api' "$out" >/dev/null 2>&1 && yq -i '.api' "$out"
  fi
  echo "$pick"
}

for api in "${APIS[@]}"; do
  [[ -f "$api" ]] || { vso_error "API file not found" "$api"; FAIL=1; continue; }
  name=$(yq_str "$api" '.info["x-ibm-name"]'); ver=$(yq_str "$api" '.info.version')
  [[ -n "$name" && -n "$ver" ]] || { vso_error "info.x-ibm-name and info.version are required" "$api"; FAIL=1; continue; }
  major="${ver%%.*}"
  project=$(path_project "$api"); folder=$(path_folder "$api")
  base="out/compat/${project}.${folder}.${name}.baseline.yaml"

  if [[ "$MODE" == git ]]; then
    if ! baseline_git "$api" "$base"; then log "NEW  $api  (no baseline at $BASE) - skipped"; continue; fi
    baseline_label="$BASE:$api"
  else
    catalog=$(catalog_for "$project" "$STAGE")
    if ! picked=$(baseline_live "$catalog" "$name" "$ver" "$base"); then log "NEW  $api  (no published $name $major.x in catalog '$catalog') - skipped"; continue; fi
    baseline_label="catalog '$catalog' $name:$picked"
  fi

  bver=$(yq_str "$base" '.info.version'); bmajor="${bver%%.*}"
  FAIL_ON=(--fail-on ERR)
  if [[ "$major" =~ ^[0-9]+$ && "$bmajor" =~ ^[0-9]+$ ]] && (( major > bmajor )); then
    FAIL_ON=()
    log "MAJOR bump $bver -> $ver for $name: breaking changes are allowed (new API version will coexist)"
  fi

  log "oasdiff breaking  baseline=$baseline_label  revision=$api"
  rc=0
  oasdiff breaking "$base" "$api" -f text "${FAIL_ON[@]}" "${IGNORE_ARGS[@]}" | sed 's/^/    /' || rc=${PIPESTATUS[0]}
  oasdiff breaking "$base" "$api" -f junit "${IGNORE_ARGS[@]}" > "out/compat/${project}.${folder}.${name}.xml" 2>/dev/null || true

  case $rc in
    0) log "OK   $name:$ver is backward compatible with $bver" ;;
    1) vso_error "BREAKING change in $name ($bver -> $ver) without a MAJOR version bump. Bump MAJOR (new product version) or add a reviewed exception to config/compat-ignore.txt" "$api"; FAIL=1 ;;
    *) vso_error "oasdiff failed (exit $rc) comparing $baseline_label with $api - is the spec loadable?" "$api"; FAIL=1 ;;
  esac
done

if (( FAIL == 0 )); then log "Stage 4 passed"; else vso_error "Stage 4 failed: backward-compatibility violations (see annotations and out/compat/*.xml)"; fi
exit $FAIL

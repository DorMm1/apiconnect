#!/usr/bin/env bash
# Stage 1 - YAML syntax validation (yamllint).
#
#   validate-yaml.sh LIST_FILE...        (each list file holds one path per line)
#
# Every finding is emitted as an Azure DevOps annotation with file/line/column.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
require_cmd yamllint

mapfile -t FILES < <(read_list "$@")
(( ${#FILES[@]} )) || { log "Stage 1: nothing to lint"; exit 0; }

vso_section "Stage 1 - yamllint (${#FILES[@]} file(s))"
rc=0
out=$(yamllint -c config/.yamllint.yml -f parsable "${FILES[@]}" 2>&1) || rc=$?

if [[ -n "$out" ]]; then
  # parsable format: <file>:<line>:<col>: [<level>] <message> (<rule>)
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    if [[ "$line" =~ ^([^:]+):([0-9]+):([0-9]+):\ \[(error|warning)\]\ (.*)$ ]]; then
      f=${BASH_REMATCH[1]}; ln=${BASH_REMATCH[2]}; col=${BASH_REMATCH[3]}; level=${BASH_REMATCH[4]}; msg=${BASH_REMATCH[5]}
      echo "##vso[task.logissue type=$level;sourcepath=$f;linenumber=$ln;columnnumber=$col]$msg"
    else
      echo "$line"
    fi
  done <<< "$out"
fi

if (( rc == 0 )); then log "Stage 1 passed"; else vso_error "Stage 1 failed: YAML syntax/style errors (see annotations)"; fi
exit $rc

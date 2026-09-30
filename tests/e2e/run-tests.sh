#!/usr/bin/env bash
# End-to-end test of the pipeline scripts on a Linux agent look-alike. Exercises exactly what the Azure DevOps
# steps run (changeset -> stages 1-4 -> stage-env -> login -> compat live -> publish -> tag), in a throw-away
# clone of the repository, with stdin kept open the way an agent step does.
#
#   With tests/e2e/fake-apic on PATH (image from tests/e2e/Dockerfile): everything, including the publish flow
#   against a simulated catalog (products:publish/get, apis:list/get) and the license-prompt hang reproduction.
#   With the real toolkit on PATH (your own agent image): validate flow only (sections 0-6, 9, 10); sections that
#   would write to API Connect are skipped automatically.
#
# Usage, from the repository root (Docker required):
#   cp -r <extracted-bundle>/tools/linux-x64 tools/                 # offline binaries, git-ignored
#   docker build -f tests/e2e/Dockerfile -t apic-e2e .
#   docker run --rm -v "$PWD:/src:ro" apic-e2e                       # PowerShell: -v "${PWD}:/src:ro"
# On your agent image (real apic):
#   docker run --rm -v "$PWD:/src:ro" <agent-image> bash /src/tests/e2e/run-tests.sh
#
# Environment: E2E_SRC (default /src) repository to test, E2E_WORK (default /work) scratch directory.
set -uo pipefail

SRC="${E2E_SRC:-/src}"; WORK="${E2E_WORK:-/work}"
PASS=0; FAIL=0; SKIP=0
ok()   { PASS=$((PASS+1)); echo "  PASS  $*"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL  $*"; }
skip() { SKIP=$((SKIP+1)); echo "  SKIP  $*"; }
info() { echo "  INFO  $*"; }
section() { echo; echo "=== $*"; }
expect_rc()     { if [[ "$3" == "$2" ]]; then ok "$1 (rc=$3)"; else bad "$1 (expected rc=$2, got rc=$3)"; show "${4:-}"; fi; }
expect_grep()   { if grep -qE -- "$2" "$3"; then ok "$1"; else bad "$1 -- pattern '$2' not in $3"; show "$3"; fi; }
expect_nogrep() { if grep -qE -- "$2" "$3"; then bad "$1 -- pattern '$2' unexpectedly in $3"; show "$3"; else ok "$1"; fi; }
expect_eq()     { if [[ "$2" == "$3" ]]; then ok "$1 ($3)"; else bad "$1 (expected '$2', got '$3')"; fi; }
show() { [[ -n "$1" && -f "$1" ]] || return 0; echo "      ---- $1"; tail -n 25 "$1" | sed 's/^/      | /'; echo "      ----"; }

for t in git yq oasdiff jq spectral yamllint apic timeout realpath; do
  type -P "$t" >/dev/null || { echo "FATAL: '$t' not on PATH"; exit 2; }
done
FAKE=0; apic --accept-license version </dev/null 2>&1 | grep -q 'fake toolkit' && FAKE=1

# ------------------------------------------------------------------ setup: bare origin + working clone
git config --global --add safe.directory '*'
git config --global init.defaultBranch main
cd /; rm -rf "$WORK"; mkdir -p "$WORK/logs"; LOG="$WORK/logs"
git clone -q --bare "$SRC" "$WORK/origin.git"
git clone -q "$WORK/origin.git" "$WORK/repo"
cd "$WORK/repo"
git config user.email e2e@local; git config user.name e2e
export FAKE_APIC_STATE="$WORK/fake-apic"; mkdir -p "$FAKE_APIC_STATE"
CALLS="$FAKE_APIC_STATE/calls.log"; : > "$CALLS"
API=projects/example-project/dev/apis/example-api.yaml
PROD=projects/example-project/dev/products/example-product.yaml

echo "repo HEAD : $(git log -1 --format='%h %s')"
echo "toolkit   : $(apic --accept-license version </dev/null 2>&1 | head -n1)  ($( (( FAKE )) && echo 'fake - full run' || echo 'REAL - publish sections skipped'))"
echo "tools     : $(yq --version) | $(oasdiff --version 2>&1 | head -n1) | $(jq --version) | spectral $(spectral --version) | $(yamllint --version)"

# ------------------------------------------------------------------ 0
section "0. Syntax check of every script"
for f in scripts/*.sh tools/*.sh "$SRC"/tests/e2e/*.sh "$SRC"/tests/e2e/fake-apic; do if bash -n "$f"; then ok "bash -n ${f#"$SRC"/}"; else bad "bash -n ${f#"$SRC"/}"; fi; done

# ------------------------------------------------------------------ 1
section "1. License prompt: toolkit without --accept-license, stdin = open pipe (as in an agent step)"
timeout 20 apic validate "$PROD" < <(sleep 60) > $LOG/t1a.txt 2>&1; rc=$?
if (( FAKE )); then
  expect_rc "plain 'apic validate' blocks on the license prompt -> killed by timeout" 124 $rc $LOG/t1a.txt
else
  info "real toolkit, plain 'apic validate' with stdin open: rc=$rc ($([[ $rc == 124 ]] && echo 'BLOCKS - --accept-license is mandatory in every step' || echo 'did not block'))"
fi
timeout 60 apic --accept-license validate "$PROD" < <(sleep 90) > $LOG/t1b.txt 2>&1; rc=$?
expect_rc "'apic --accept-license validate' completes" 0 $rc $LOG/t1b.txt
if (( FAKE )); then
  timeout 20 apic validate "$PROD" </dev/null > $LOG/t1c.txt 2>&1; rc=$?
  expect_rc "plain 'apic validate' with stdin closed continues on EOF (what Cancel did)" 0 $rc $LOG/t1c.txt
fi
: > "$CALLS"

# ------------------------------------------------------------------ 2
section "2. lib.sh apic() wrapper"
( source scripts/lib.sh; APIC_TIMEOUT=60 apic validate "$PROD" ) < <(sleep 90) > $LOG/t2a.txt 2>&1; rc=$?
expect_rc "wrapper completes although the step's stdin is an open pipe" 0 $rc $LOG/t2a.txt
(( FAKE )) && expect_grep "wrapper injected --accept-license" '^--accept-license validate ' "$CALLS"
if (( FAKE )); then
  ( source scripts/lib.sh; FAKE_APIC_SLEEP=10 APIC_TIMEOUT=2 apic version ) > $LOG/t2b.txt 2>&1; rc=$?
  expect_rc "wrapper timeout (APIC_TIMEOUT=2, call takes 10s) fails" 124 $rc $LOG/t2b.txt
  expect_grep "wrapper emits an Azure DevOps error annotation on timeout" 'task.logissue type=error\]apic version did not finish within 2s' $LOG/t2b.txt
fi

# ------------------------------------------------------------------ 3
section "3. PR flow: non-breaking change in dev/ -> stages 0-4 (stdin kept open like an agent)"
git checkout -q -b feature/non-breaking
yq -i '.components.schemas.Health.properties.uptimeSeconds = {"type":"integer","description":"added by e2e test"}' "$API"
git commit -qam "test: optional Health.uptimeSeconds"
bash scripts/changeset.sh --mode pr --base origin/main out/pr > $LOG/t3-cs.txt 2>&1; rc=$?
expect_rc "changeset --mode pr" 0 $rc $LOG/t3-cs.txt
expect_eq "only the dev product is selected" "1" "$(grep -c . out/pr/products.txt)"
expect_grep "selected product is the dev one" '^projects/example-project/dev/products/example-product.yaml$' out/pr/products.txt
expect_grep "its API is listed" '^projects/example-project/dev/apis/example-api.yaml$' out/pr/apis.txt
bash scripts/validate-yaml.sh out/pr/products.txt out/pr/apis.txt > $LOG/t3-s1.txt 2>&1; rc=$?
expect_rc "stage 1 yamllint" 0 $rc $LOG/t3-s1.txt
bash scripts/validate-oas.sh out/pr/apis.txt > $LOG/t3-s2.txt 2>&1; rc=$?
expect_rc "stage 2 spectral" 0 $rc $LOG/t3-s2.txt
timeout 120 bash scripts/validate-apic.sh out/pr/products.txt < <(sleep 150) > $LOG/t3-s3.txt 2>&1; rc=$?
expect_rc "stage 3 apic validate" 0 $rc $LOG/t3-s3.txt
if (( FAKE )); then
  expect_grep "stage 3 shows the API validated" 'Validated projects/example-project/dev/apis/example-api.yaml' $LOG/t3-s3.txt
  expect_nogrep "stage 3 no 'Validated count' warning" 'task.logissue type=warning' $LOG/t3-s3.txt
else
  info "real toolkit output of stage 3 (check the 'Validated' wording matches validate-apic.sh):"; show $LOG/t3-s3.txt
fi
bash scripts/validate-compat.sh out/pr > $LOG/t3-s4.txt 2>&1; rc=$?
expect_rc "stage 4 oasdiff vs origin/main" 0 $rc $LOG/t3-s4.txt
expect_grep "stage 4 reports compatible" 'OK +example-api:1.1.0 is backward compatible with 1.1.0' $LOG/t3-s4.txt
ls out/compat/*.xml >/dev/null 2>&1; expect_rc "stage 4 wrote a JUnit file" 0 $?

# ------------------------------------------------------------------ 4
section "4. PR flow: breaking change must fail stage 4; MAJOR bump makes it pass"
git checkout -q main; git checkout -q -b feature/breaking
yq -i 'del(.paths."/ping")' "$API"; git commit -qam "test: remove /ping (breaking)"
bash scripts/changeset.sh --mode pr --base origin/main out/pr4 > /dev/null 2>&1
bash scripts/validate-compat.sh out/pr4 > $LOG/t4a.txt 2>&1; rc=$?
expect_rc "stage 4 fails on a removed endpoint" 1 $rc $LOG/t4a.txt
expect_grep "annotation names the breaking change" 'task.logissue type=error;sourcepath=projects/example-project/dev/apis/example-api.yaml\]BREAKING change in example-api \(1.1.0 -> 1.1.0\) without a MAJOR version bump' $LOG/t4a.txt
yq -i '.info.version = "2.0.0"' "$API"; yq -i '.info.version = "2.0.0"' "$PROD"; git commit -qam "test: MAJOR bump"
bash scripts/changeset.sh --mode pr --base origin/main out/pr4b > /dev/null 2>&1
bash scripts/validate-compat.sh out/pr4b > $LOG/t4b.txt 2>&1; rc=$?
expect_rc "stage 4 passes the same change with MAJOR bump" 0 $rc $LOG/t4b.txt
expect_grep "MAJOR bump is reported" 'MAJOR bump 1.1.0 -> 2.0.0 for example-api' $LOG/t4b.txt

# ------------------------------------------------------------------ 5
section "5. Stage 1-3 negatives"
git checkout -q main; git checkout -q -b feature/negatives
cp "$API" "$WORK/api.bak"; cp "$PROD" "$WORK/prod.bak"
printf 'openapi: 3.0.3\ninfo:\n\ttitle: tabs are invalid\n' > "$API"
bash scripts/validate-yaml.sh /dev/null <(echo "$API") > $LOG/t5a.txt 2>&1; rc=$?
expect_rc "stage 1 rejects invalid YAML" 1 $rc $LOG/t5a.txt
cp "$WORK/api.bak" "$API"
yq -i 'del(.["x-ibm-configuration"].enforced)' "$API"
bash scripts/validate-oas.sh <(echo "$API") > $LOG/t5b.txt 2>&1; rc=$?
expect_rc "stage 2 rejects an API without x-ibm-configuration.enforced" 1 $rc $LOG/t5b.txt
cp "$WORK/api.bak" "$API"
yq -i '.apis."example-api"."$ref" = "../../integ/apis/example-api.yaml"' "$PROD"
calls_before=$(grep -c . "$CALLS")
timeout 60 bash scripts/validate-apic.sh <(echo "$PROD") > $LOG/t5c.txt 2>&1; rc=$?
expect_rc "stage 3 rejects a cross-folder \$ref" 1 $rc $LOG/t5c.txt
expect_grep "policy error is explicit" 'points outside projects/example-project/dev/apis/' $LOG/t5c.txt
(( FAKE )) && expect_eq "toolkit not called when the \$ref policy fails (call count unchanged)" "$calls_before" "$(grep -c . "$CALLS")"
cp "$WORK/prod.bak" "$PROD"
yq -i '.apis."example-api" = {"name":"example-api:1.1.0"}' "$PROD"
timeout 60 bash scripts/validate-apic.sh <(echo "$PROD") > $LOG/t5d.txt 2>&1; rc=$?
expect_rc "stage 3 rejects a name:version reference" 1 $rc $LOG/t5d.txt
cp "$WORK/prod.bak" "$PROD"
git checkout -q -- projects

# ------------------------------------------------------------------ 6
section "6. Merge to main: change set per stage (no published/* tags yet)"
git checkout -q main; git merge -q --ff-only feature/non-breaking; git push -q origin main
bash scripts/changeset.sh --mode main out/main > $LOG/t6.txt 2>&1; rc=$?
expect_rc "changeset --mode main" 0 $rc $LOG/t6.txt
for s in dev nightly integ rc prod; do expect_grep "stage $s flagged (never published)" "^$s true$" out/main/stages.txt; done
expect_eq "all four folders selected" "4" "$(grep -c . out/main/products.txt)"
bash scripts/validate-yaml.sh out/main/products.txt out/main/apis.txt > $LOG/t6-s1.txt 2>&1; rc=$?; expect_rc "stage 1 on all folders" 0 $rc $LOG/t6-s1.txt
bash scripts/validate-oas.sh out/main/apis.txt > $LOG/t6-s2.txt 2>&1; rc=$?;                   expect_rc "stage 2 on all folders" 0 $rc $LOG/t6-s2.txt
timeout 300 bash scripts/validate-apic.sh out/main/products.txt < <(sleep 330) > $LOG/t6-s3.txt 2>&1; rc=$?; expect_rc "stage 3 on all folders" 0 $rc $LOG/t6-s3.txt
bash scripts/validate-compat.sh out/main > $LOG/t6-s4.txt 2>&1; rc=$?;                         expect_rc "stage 4 on all folders (baseline = empty tree)" 0 $rc $LOG/t6-s4.txt
expect_eq "stage 4 skipped 4 NEW APIs" "4" "$(grep -c 'NEW ' $LOG/t6-s4.txt)"

# ------------------------------------------------------------------ 7
section "7. Publish stage dev (dev/ -> example-project-dev on the dev instance)"
bash scripts/stage-env.sh --stage dev --vso > $LOG/t7-env.txt 2>&1; rc=$?
expect_rc "stage-env --vso" 0 $rc $LOG/t7-env.txt
expect_grep "sets APIC_SERVER from topology" 'task.setvariable variable=APIC_SERVER\]https://' $LOG/t7-env.txt
eval "$(bash scripts/stage-env.sh --stage dev 2>/dev/null | grep '^export ')"
expect_eq "APIC_ORG resolved" "$(yq -r '.instances.dev.org' config/topology.yml)" "${APIC_ORG:-}"
if (( FAKE )); then
  DEV_SERVER=$(yq -r '.instances.dev.ingress.management' config/topology.yml)
  echo '{"id":"toolkit","secret":"x"}' > "$WORK/creds.json"
  ( set -euo pipefail; source scripts/lib.sh
    apic client-creds:set "$WORK/creds.json"
    apic iam-apikey --server "$APIC_SERVER" --apiKey "dummy-key"
    apic catalogs:list --server "$APIC_SERVER" --org "$APIC_ORG" --fields name --format yaml --output -
  ) < <(sleep 30) > $LOG/t7-login.txt 2>&1; rc=$?
  expect_rc "login step (as in publish-stage.yml) completes" 0 $rc $LOG/t7-login.txt
  bash scripts/changeset.sh --mode stage --stage dev out/dev > $LOG/t7-cs.txt 2>&1; rc=$?
  expect_rc "changeset --mode stage dev" 0 $rc $LOG/t7-cs.txt
  expect_grep "bootstrap warning (no tag yet)" 'task.logissue type=warning\]No tag published/dev yet' $LOG/t7-cs.txt
  expect_eq "stage change set = dev product only" "1" "$(grep -c . out/dev/products.txt)"
  bash scripts/compat-check.sh --mode live --stage dev out/dev/products.txt < <(sleep 30) > $LOG/t7-live.txt 2>&1; rc=$?
  expect_rc "compat live (nothing published yet)" 0 $rc $LOG/t7-live.txt
  expect_grep "reported as NEW" "NEW +$API +\(no published example-api 1.x in catalog 'example-project-dev'\)" $LOG/t7-live.txt
  bash scripts/publish.sh --stage dev out/dev/products.txt < <(sleep 30) > $LOG/t7-pub.txt 2>&1; rc=$?
  expect_rc "publish.sh --stage dev" 0 $rc $LOG/t7-pub.txt
  expect_grep "products:publish targeted the dev instance + catalog" "^--accept-license products:publish --server $DEV_SERVER --org $APIC_ORG --catalog example-project-dev --format json --output - $PROD\$" "$CALLS"
  expect_nogrep "first publish: no --migrate_subscriptions" 'products:publish.*--migrate_subscriptions' "$CALLS"
  expect_grep "state asserted after publish" "OK +example-product:1.1.0 is published in 'example-project-dev'" $LOG/t7-pub.txt
  [[ -s out/publish/example-project_example-product_1.1.0.json ]]; expect_rc "publish response saved under out/publish" 0 $?
  git tag -f published/dev HEAD >/dev/null; git push -q --force origin refs/tags/published/dev; rc=$?
  expect_rc "tag published/dev pushed" 0 $rc
  bash scripts/changeset.sh --mode main out/main2 > /dev/null 2>&1
  expect_grep "after tagging: stage dev has nothing to publish" '^dev false$' out/main2/stages.txt
  expect_grep "same folder, own tag: nightly still pending" '^nightly true$' out/main2/stages.txt

  section "7b. Publish stage nightly (same dev/ folder -> example-project-nightly on the test instance)"
  TEST_SERVER=$(yq -r '.instances.test.ingress.management' config/topology.yml)
  eval "$(bash scripts/stage-env.sh --stage nightly 2>/dev/null | grep '^export ')"
  expect_eq "nightly resolves to the test instance" "$TEST_SERVER" "${APIC_SERVER:-}"
  bash scripts/changeset.sh --mode stage --stage nightly out/nightly > /dev/null 2>&1
  bash scripts/publish.sh --stage nightly out/nightly/products.txt < <(sleep 30) > $LOG/t7b-pub.txt 2>&1; rc=$?
  expect_rc "publish.sh --stage nightly" 0 $rc $LOG/t7b-pub.txt
  expect_grep "published to the -nightly catalog on the test instance" "products:publish --server $TEST_SERVER --org $APIC_ORG --catalog example-project-nightly " "$CALLS"
  git tag -f published/nightly HEAD >/dev/null; git push -q --force origin refs/tags/published/nightly

  # ---------------------------------------------------------------- 8
  section "8. Republish dev: compat against the live catalog"
  eval "$(bash scripts/stage-env.sh --stage dev 2>/dev/null | grep '^export ')"
  yq -i '.components.schemas.Health.properties.build = {"type":"string"}' "$API"; git commit -qam "test: optional Health.build (same version)"
  bash scripts/changeset.sh --mode stage --stage dev out/dev8 > $LOG/t8-cs.txt 2>&1
  expect_eq "changed since published/dev -> selected" "1" "$(grep -c . out/dev8/products.txt)"
  bash scripts/compat-check.sh --mode live --stage dev out/dev8/products.txt < <(sleep 30) > $LOG/t8a.txt 2>&1; rc=$?
  expect_rc "compat live: same version republish" 0 $rc $LOG/t8a.txt
  expect_grep "baseline = live 1.1.0" "baseline=catalog 'example-project-dev' example-api:1.1.0" $LOG/t8a.txt
  expect_grep "compatible" 'OK +example-api:1.1.0 is backward compatible with 1.1.0' $LOG/t8a.txt
  FAKE_APIC_ENVELOPE=1 bash scripts/compat-check.sh --mode live --stage dev out/dev8/products.txt < <(sleep 30) > $LOG/t8b.txt 2>&1; rc=$?
  expect_rc "compat live also works when apis:get returns an {api: ...} envelope" 0 $rc $LOG/t8b.txt
  expect_grep "envelope unwrapped" 'OK +example-api:1.1.0 is backward compatible with 1.1.0' $LOG/t8b.txt
  bash scripts/publish.sh --stage dev out/dev8/products.txt < <(sleep 30) > $LOG/t8-pub.txt 2>&1; rc=$?
  expect_rc "publish.sh republish" 0 $rc $LOG/t8-pub.txt
  expect_grep "detected as REPUBLISH" 'REPUBLISH example-product:1.1.0 -> catalog .example-project-dev. \(current state: published\)' $LOG/t8-pub.txt
  expect_grep "republish carries --migrate_subscriptions" 'products:publish .*--catalog example-project-dev --migrate_subscriptions --format json' "$CALLS"
  git tag -f published/dev HEAD >/dev/null; git push -q --force origin refs/tags/published/dev

  section "8c. New MINOR version 1.2.0 -> baseline is the highest published 1.x below it"
  yq -i '.info.version = "1.2.0"' "$API"; yq -i '.info.version = "1.2.0"' "$PROD"; git commit -qam "test: 1.2.0"
  bash scripts/changeset.sh --mode stage --stage dev out/dev8c > /dev/null 2>&1
  bash scripts/compat-check.sh --mode live --stage dev out/dev8c/products.txt < <(sleep 30) > $LOG/t8c.txt 2>&1; rc=$?
  expect_rc "compat live 1.2.0 vs live 1.1.0" 0 $rc $LOG/t8c.txt
  expect_grep "picked 1.1.0 as baseline" "baseline=catalog 'example-project-dev' example-api:1.1.0" $LOG/t8c.txt
  bash scripts/publish.sh --stage dev out/dev8c/products.txt < <(sleep 30) > $LOG/t8c-pub.txt 2>&1; rc=$?
  expect_rc "publish 1.2.0 (new product version, coexists)" 0 $rc $LOG/t8c-pub.txt
  expect_grep "new version = PUBLISH, not republish" 'PUBLISH +example-product:1.2.0 -> catalog .example-project-dev. \(new in catalog\)' $LOG/t8c-pub.txt
  git tag -f published/dev HEAD >/dev/null; git push -q --force origin refs/tags/published/dev

  section "8d. Breaking change without MAJOR bump is blocked before publish"
  yq -i 'del(.paths."/ping")' "$API"; git commit -qam "test: remove /ping at 1.2.0"
  bash scripts/changeset.sh --mode stage --stage dev out/dev8d > /dev/null 2>&1
  bash scripts/compat-check.sh --mode live --stage dev out/dev8d/products.txt < <(sleep 30) > $LOG/t8d.txt 2>&1; rc=$?
  expect_rc "compat live fails" 1 $rc $LOG/t8d.txt
  expect_grep "BREAKING annotation" 'BREAKING change in example-api \(1.2.0 -> 1.2.0\)' $LOG/t8d.txt
  yq -i '.info.version = "2.0.0"' "$API"; yq -i '.info.version = "2.0.0"' "$PROD"; git commit -qam "test: 2.0.0"
  bash scripts/changeset.sh --mode stage --stage dev out/dev8e > /dev/null 2>&1
  bash scripts/compat-check.sh --mode live --stage dev out/dev8e/products.txt < <(sleep 30) > $LOG/t8e.txt 2>&1; rc=$?
  expect_rc "compat live: 2.0.0 has no 2.x baseline -> allowed" 0 $rc $LOG/t8e.txt
  expect_grep "reported as NEW 2.x" "no published example-api 2.x in catalog 'example-project-dev'" $LOG/t8e.txt
else
  skip "7/7b/8: publish flow (login, compat live, products:publish, tags) - needs the fake toolkit"
fi

# ------------------------------------------------------------------ 9
section "9. Guards (no toolkit call involved)"
echo "$PROD" > "$WORK/devlist.txt"
eval "$(bash scripts/stage-env.sh --stage dev 2>/dev/null | grep '^export ')"
bash scripts/publish.sh --stage prod "$WORK/devlist.txt" > $LOG/t9a.txt 2>&1; rc=$?
expect_rc "publish.sh refuses a dev/ product for stage prod" 2 $rc $LOG/t9a.txt
expect_grep "refusal is explicit" 'Refusing to publish: .* \(stage .prod. publishes folder .prod.\)' $LOG/t9a.txt
(( FAKE )) && expect_nogrep "no toolkit call was made for the refused publish" 'products:publish .*--catalog example-project --format' "$CALLS"
bash scripts/publish.sh --stage nope "$WORK/devlist.txt" > $LOG/t9b.txt 2>&1; rc=$?
expect_rc "unknown stage rejected" 2 $rc $LOG/t9b.txt
( unset APIC_SERVER; bash scripts/publish.sh --stage dev "$WORK/devlist.txt" ) > $LOG/t9c.txt 2>&1; rc=$?
expect_rc "missing APIC_SERVER rejected" 2 $rc $LOG/t9c.txt

# ------------------------------------------------------------------ 10
section "10. promote.sh dev -> integ"
git checkout -q main
bash scripts/promote.sh example-project dev integ > $LOG/t10.txt 2>&1; rc=$?
expect_rc "promote.sh" 0 $rc $LOG/t10.txt
expect_grep "integ now holds the dev version" "product +example-product +$(yq -r .info.version "$PROD")" $LOG/t10.txt
expect_grep "tells where the merge publishes" "integ -> example-project-integ on dev \(" $LOG/t10.txt
expect_eq "only integ/ changed" "projects/example-project/integ" "$(git diff --name-only | xargs -n1 dirname | xargs -n1 dirname | sort -u)"
git checkout -q -- projects

# ------------------------------------------------------------------ summary
if (( FAKE )); then
  section "Toolkit call log"
  total=$(grep -c . "$CALLS"); noflag=$(grep -vc '^--accept-license' "$CALLS")
  expect_eq "every scripted toolkit call carried --accept-license (calls without it)" "0" "$noflag"
  echo "  ($total toolkit calls recorded: $(sed 's/^--accept-license //' "$CALLS" | awk '{print $1}' | sort | uniq -c | awk '{printf "%s x%s  ", $2, $1}'))"
fi

echo
echo "================================================================"
echo "  PASSED: $PASS   FAILED: $FAIL   SKIPPED: $SKIP"
echo "================================================================"
(( FAIL == 0 ))

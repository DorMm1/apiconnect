# APIConnect-catalog

GitOps repository for the APIs and Products published to **IBM API Connect 10.0.8.x (Enterprise as a Service)**
with the `apic` toolkit, driven by **Azure DevOps Pipelines**.

* Git is the single source of truth. API Manager drafts are not used; humans should only have *viewer* roles
  on the catalogs, the pipeline identity is the only publisher.
* A change is a Pull Request. PRs are **validated** (four fail-fast stages), merges to `main` are **published**
  to the `dev` catalog and then promoted, unchanged, to `test` and `prod` behind approvals.
* Nothing is ever deleted or retired from APIC by this pipeline.

## Layout

```
.azure-pipelines/
  apic-ci.yml                  entry pipeline: validate (PR + main) -> publish dev -> test -> prod
  templates/install-tools.yml  yamllint, spectral, yq, oasdiff, apic toolkit
  templates/publish-stage.yml  one deployment stage per catalog
config/
  .yamllint.yml                stage 1 rules
  spectral.yml                 stage 2 rules (OAS 3.0 + APIC-specific)
  compat-ignore.txt            stage 4 reviewed exceptions (oasdiff --err-ignore)
scripts/                       everything the pipeline runs; usable locally
tools/install-offline.sh       installs the bundled tools on an on-prem (offline) Linux x64 agent
docs/guide.pdf                 the readable guide (docs/guide.html is the source)
projects/
  <project>/
    apis/<api>.yaml            OpenAPI 3.0.x + x-ibm-configuration (one file for all environments)
    products/<product>.yaml    APIC product: plans, rate limits, visibility, apis.*.$ref -> ../apis/<api>.yaml
```

A **project folder = ownership boundary**, not a deployment target. The target catalog is chosen by the
pipeline stage. If Spaces are enabled later, a project maps 1:1 to a Space (`--scope space --space <project>`).

## Conventions (enforced by the pipeline)

| Rule | Where enforced |
|---|---|
| Files are valid YAML | stage 1, `yamllint` |
| OpenAPI 3.0.x, `info.x-ibm-name` is a lowercase slug, `info.version` is strict semver, single `servers[]` entry, `x-ibm-configuration` with explicit `enforced`, DataPower API Gateway, no callbacks/links | stage 2, `spectral` (`config/spectral.yml`) |
| Products reference APIs only through a relative `$ref` into the same project's `apis/`; `apic validate` passes for the product and every referenced API | stage 3, `scripts/validate-apic.sh` |
| No breaking contract change without a MAJOR bump of `info.version` | stage 4, `oasdiff` |
| Environment-specific values live in `x-ibm-configuration.properties` with per-catalog overrides in `x-ibm-configuration.catalogs.<catalog>.properties`; never in separate files or branches | review |

### Versioning

* APIC identifies an API by `x-ibm-name:version` and a product by `name:version`.
* **Non-breaking** change: keep the version (or bump MINOR/PATCH), the product is republished in place;
  subscriptions are retained.
* **Breaking** change: bump the API MAJOR **and** the product version. Both versions coexist in the catalog.
  Subscriptions are migrated later with `apic products:replace` / `products:supersede` and the old version is
  retired by hand (deprecate -> retire -> delete). This pipeline will not do that for you.

### Backward-compatibility policy (stage 4)

Baseline = the same file on the target branch (PR) or the latest published version with the same MAJOR in the
target catalog (before publish). `oasdiff breaking` classifies changes:

| Class | Examples | Outcome |
|---|---|---|
| **Breaking (ERR)** | remove/rename path, operation, request parameter or property; add a *required* request parameter/property; change a type/format; narrow a request enum; remove a response property, status code or media type; tighten security; change the base path | fails unless MAJOR was bumped |
| **Potentially breaking (WARN)** | new response status code; new enum value in a response; deprecation; loosened response constraints | reported only |
| **Non-breaking** | new path/operation; *optional* request parameter/property; new response property; widened request enum; descriptions/examples/tags; anything under `x-ibm-*` | passes |

Exceptions are added to `config/compat-ignore.txt` in the same PR, one per line, with a justification.

## How a change flows

```
PR -> main            : 0 change set -> 1 yamllint -> 2 spectral -> 3 apic validate -> 4 oasdiff (vs origin/main)
merge to main         : same validation (vs tag published/dev), then
  publish_dev         : login -> change set vs tag published/dev -> 4' oasdiff vs live catalog -> apic products:publish -> move tag
  publish_test        : (approval) same, vs tag published/test
  publish_prod        : (approval) same, vs tag published/prod
```

* **Change set** = changed product files + products whose `$ref` points at a changed API file
  (`scripts/changed-products.sh`). Deleted files only produce a warning.
* **Tags `published/<env>`** mark the last commit successfully published to each catalog. Each stage diffs
  against its own tag, so a failed prod publish is simply picked up by the next run. No tag yet => every
  product is published (bootstrap).
* **Rollback** = run the pipeline for an earlier commit (Run pipeline -> select commit) or
  `apic products:replace` to the previous product version.

## Azure DevOps setup

1. **Pipeline**: create from `.azure-pipelines/apic-ci.yml`. For a GitHub-hosted repo the `pr:` trigger is used;
   make the pipeline a required status check on `main`. For Azure Repos add a *Build validation* branch policy.
2. **Variable group `apic-shared`** (plain): `APIC_SERVER` (management/platform API endpoint of your tenant),
   `APIC_ORG` (provider organization name), `APIC_TOOLKIT_VERSION` (e.g. `10.0.8.9`), `TOOLS_MODE`
   (`online` for Microsoft-hosted agents, `offline` for a self-hosted agent prepared with `tools/install-offline.sh`).
3. **Variable groups `apic-dev`, `apic-test`, `apic-prod`**, linked to Azure Key Vault: `APIC_APIKEY`.
   Use one IBM Cloud IAM API key per environment, each belonging to a service ID that is a member of the
   provider org with a publish-capable role on that catalog only (least privilege).
4. **Secure file `apic-toolkit-credentials.json`**: the `credentials.json` from API Manager -> *Tools for download*.
5. **Environments `apic-dev`, `apic-test`, `apic-prod`**: add *Approvals* and *Exclusive lock* on test and prod.
6. **Toolkit binary**: download the Linux CLI from API Manager -> *Tools for download*. Online agents: publish it as a
   Universal Package `apic-toolkit` (version = toolkit version) to the Artifacts feed `platform-tools`.
   Self-hosted agents: install it on PATH (the download is skipped automatically).
7. **Repository permissions**: the pipeline pushes tags `published/<env>`. Grant the build identity
   *Contribute* + *Create tag* (GitHub: a token with `contents:write` used by the checkout step).

## On-prem (offline) agent

The offline bundle (`APIConnect-catalog-bundle-<date>.zip`) contains this repository, `tools/linux-x64/` with
yq, oasdiff, jq, a standalone Spectral and yamllint wheels, and `docs/guide.pdf`. On the agent:

```bash
sudo tools/install-offline.sh                 # verifies SHA256SUMS, installs to /usr/local/bin, pip installs yamllint
sudo install -m 0755 apic-slim /usr/local/bin/apic   # toolkit from your tenant, not in the bundle
```

Then set `TOOLS_MODE = offline` in `apic-shared` and point `pool:` in the pipeline files at your agent pool.
In offline mode the tooling step never reaches the internet; a missing tool fails the job with a clear message.

## Items to verify on your tenant before the first publish

- [ ] Non-interactive login: `apic iam-apikey --server <mgmt> --apiKey <IBM Cloud API key>` (v10.0.8 CLI).
      If your tenant only accepts IBMid/OIDC, switch `templates/publish-stage.yml` to
      `apic login --server <mgmt> --sso --context provider --apiKey <toolkit API key>` (`apic api-keys:create` with a long `ttl`).
- [ ] `apic apis:get --scope catalog ... --format yaml --output -` returns the bare definition or an envelope
      (`scripts/compat-check.sh` handles both, but check the log the first time).
- [ ] `apic apis:list --format json` returns `{ "results": [...] }` (handled either way, same as above).
- [ ] `apic validate` exits non-zero on an invalid definition (the script also counts "Validated" lines).
- [ ] `--migrate_subscriptions` on republish of an existing `name:version` behaves as expected in your catalogs.
- [ ] `prod` catalog *Production mode*: if enabled, republishing the same version may be rejected and every
      prod change needs a version bump + `products:replace`.
- [ ] Catalog-specific property overrides (`x-ibm-configuration.catalogs.<catalog>.properties`) resolve on your gateway.
- [ ] OpenAPI 3.0 subset supported by your DataPower API Gateway; optionally run `apic draft-apis:validate`
      online in `dev` for extra coverage.

## Running the checks locally

Requirements: bash, git, `yamllint`, `@stoplight/spectral-cli`, `yq` (mikefarah v4), `oasdiff`, `jq`, and the
`apic` toolkit for stage 3.

```bash
BASE=origin/main
scripts/changed-products.sh "$BASE" HEAD out/products.txt
scripts/product-apis.sh --list out/products.txt > out/apis.txt
scripts/validate-yaml.sh out/products.txt out/apis.txt        # 1
scripts/validate-oas.sh  out/apis.txt                         # 2
scripts/validate-apic.sh out/products.txt                     # 3 (needs apic)
scripts/compat-check.sh --mode git --base "$BASE" out/products.txt   # 4
```

Windows: run the same commands from Git Bash.

## Adding an API

1. `projects/<project>/apis/<api>.yaml` - OpenAPI 3.0.x with `info.x-ibm-name`, semver `info.version`,
   one `servers[].url`, and `x-ibm-configuration` (see `projects/example-project`).
2. Reference it from a product in `projects/<project>/products/` via `$ref: ../apis/<api>.yaml`.
3. Open a PR. Fix anything the four stages report. Merge. Approve `test` and `prod` when ready.

# APIConnect-catalog

GitOps repository for the APIs and Products published to **IBM API Connect 10.0.8.x** with the `apic` toolkit,
driven by **Azure DevOps Pipelines**.

* Git is the single source of truth. API Manager drafts are not used; humans should only have *viewer* roles
  on the catalogs, the pipeline identities are the only publishers.
* A change is a Pull Request. PRs are **validated** (four fail-fast stages), merges to `main` are **published**.
* Nothing is ever deleted or retired from APIC by this pipeline.

## Topology

Three **API Connect instances** (separate clusters, endpoints and credentials), five **catalogs per project**:

| Environment (instance) | Repo folder | Stage 1 (automatic) | Stage 2 (approval) |
|---|---|---|---|
| dev  | `projects/<project>/dev/`  | `<project>-dev`     | `<project>-integ` |
| test | `projects/<project>/test/` | `<project>-nightly` | `<project>-rc`    |
| prod | `projects/<project>/prod/` | `<project>`         | —                 |

The folder of an environment holds **what that instance should have**. Both catalogs of an instance receive the
same files, in order; the second catalog waits for an approval on the Azure DevOps Environment `apic-<stage>`.
Moving a version from one environment to the next is a **promotion PR** created with `scripts/promote.sh`.
The mapping lives in [`config/environments.yml`](config/environments.yml); a project can override catalog
names in `projects/<project>/project.yaml`.

## Layout

```
.azure-pipelines/
  apic-ci.yml                  entry pipeline: validate (PR + main) -> 5 publish stages in 3 independent chains
  templates/install-tools.yml  yamllint, spectral, yq, oasdiff, apic toolkit (online or offline mode)
  templates/publish-stage.yml  one deployment stage per catalog
config/
  environments.yml             instances, stages, catalog name patterns (source of truth for the scripts)
  .yamllint.yml                stage 1 rules
  spectral.yml                 stage 2 rules (OAS 3.0 + APIC-specific)
  compat-ignore.txt            stage 4 reviewed exceptions (oasdiff --err-ignore)
scripts/                       everything the pipeline runs; usable locally (see below)
tools/install-offline.sh       installs the bundled tools on an on-prem (offline) Linux x64 agent
docs/guide.pdf                 the readable guide (docs/guide.html is the source)
projects/
  <project>/
    project.yaml               optional: owner, catalog-name overrides
    dev/                       what the dev instance should have
      apis/<api>.yaml          OpenAPI 3.0.x + x-ibm-configuration
      products/<product>.yaml  APIC product: plans, rate limits, visibility, apis.*.$ref -> ../apis/<api>.yaml
    test/                      same structure - what the test instance should have
    prod/                      same structure - what the prod instance should have
```

A **project folder = ownership boundary** and the prefix of its catalog names. An **environment folder = the
version deployed to that instance**. Files are meant to be byte-identical across environment folders; environment
differences are expressed *inside* the file (see "One file, five catalogs").

## Conventions (enforced by the pipeline)

| Rule | Where enforced |
|---|---|
| Files are valid YAML | stage 1, `yamllint` |
| OpenAPI 3.0.x, `info.x-ibm-name` is a lowercase slug, `info.version` is strict semver, single `servers[]` entry, `x-ibm-configuration` with explicit `enforced`, DataPower API Gateway, no callbacks/links | stage 2, `spectral` (`config/spectral.yml`) |
| Products reference APIs only through a relative `$ref` into the **same** `projects/<project>/<env>/apis/`; no name:version refs, no cross-project or cross-environment refs; `apic validate` passes | stage 3, `scripts/validate-apic.sh` |
| No breaking contract change without a MAJOR bump of `info.version`, per environment folder | stage 4, `oasdiff` |
| Environment-specific values live in `x-ibm-configuration.properties` + `catalogs.<catalog>.properties`, keyed by all five catalog names of the project; never hand-edited per environment | review + `promote.sh` |

### One file, five catalogs

```yaml
x-ibm-configuration:
  properties:
    target-url: { value: https://orders-dev.internal }          # default
  catalogs:                                                     # overrides by catalog name
    orders-dev:     { properties: { target-url: https://orders-dev.internal } }
    orders-integ:   { properties: { target-url: https://orders-integ.internal } }
    orders-nightly: { properties: { target-url: https://orders-nightly.internal } }
    orders-rc:      { properties: { target-url: https://orders-rc.internal } }
    orders:         { properties: { target-url: https://orders.internal } }
```

Because every catalog's value is in the file, promotion is a pure copy and the compatibility gate never sees
environment differences as contract changes.

### Versioning

* APIC identifies an API by `x-ibm-name:version` and a product by `name:version`.
* **Non-breaking** change: keep the version (or bump MINOR/PATCH); the product is republished in place,
  subscriptions retained.
* **Breaking** change: bump the API MAJOR **and** the product version. Both versions coexist in the catalog.
  Subscriptions are migrated later with `apic products:replace` / `products:supersede` and the old version is
  retired by hand (deprecate -> retire -> delete). This pipeline will not do that for you.

### Backward-compatibility policy (stage 4)

Baseline = the same file as it was at the environment's last publish (git) or the latest published version with
the same MAJOR in the target catalog (live, before publish). `oasdiff breaking` classifies changes:

| Class | Examples | Outcome |
|---|---|---|
| **Breaking (ERR)** | remove/rename path, operation, request parameter or property; add a *required* request parameter/property; change a type/format; narrow a request enum; remove a response property, status code or media type; tighten security; change the base path | fails unless MAJOR was bumped |
| **Potentially breaking (WARN)** | new response status code; new enum value in a response; deprecation; loosened response constraints | reported only |
| **Non-breaking** | new path/operation; *optional* request parameter/property; new response property; widened request enum; descriptions/examples/tags; anything under `x-ibm-*` | passes |

Exceptions are added to `config/compat-ignore.txt` in the same PR, one per line, with a justification.

## How a change flows

```
PR -> main         : 0 change set per env -> 1 yamllint -> 2 spectral -> 3 apic validate -> 4 oasdiff (vs target branch)
merge to main      : same validation (vs each stage's published/<stage> tag), then three independent chains,
                     every stage skipped when its environment folder has nothing new:
  dev  instance    : publish_dev      (auto)  -> publish_integ (approval)
  test instance    : publish_nightly  (auto)  -> publish_rc    (approval)
  prod instance    : publish_prod     (approval)
each publish stage : login to the instance -> change set vs published/<stage> -> 4' oasdiff vs live catalog
                     -> apic products:publish per product into <project>-<suffix> -> move tag published/<stage>
```

* **Change set** = changed product files + products whose `$ref` points at a changed API file, restricted to the
  stage's environment folder (`scripts/changeset.sh`). Deleted files only produce a warning.
* **Tags `published/<stage>`** (5) mark the last commit published to each catalog. A stage diffs against its own
  tag, so a rejected `rc` approval last week is simply offered again by the next run. No tag => bootstrap:
  every product of the environment is published.
* **Promotion** = `scripts/promote.sh <project> dev test` (or `test prod`), review the diff, open a PR. Merging
  publishes to the stages of the target environment.
* **Rollback** = promote from a folder that still has the previous version, or run the pipeline for an earlier
  commit, or `apic products:replace` to the previous product version.

## Azure DevOps setup

1. **Pipeline**: create from `.azure-pipelines/apic-ci.yml`. For a GitHub-hosted repo the `pr:` trigger is used;
   make the pipeline a required status check on `main`. For Azure Repos add a *Build validation* branch policy.
   On-prem: replace `vmImage: ubuntu-latest` with `name: <your agent pool>` in both pipeline files.
2. **Variable group `apic-shared`** (plain): `APIC_TOOLKIT_VERSION` (e.g. `10.0.8.9`), `TOOLS_MODE`
   (`online` for Microsoft-hosted agents, `offline` for a self-hosted agent prepared with `tools/install-offline.sh`).
3. **Variable groups `apic-dev`, `apic-test`, `apic-prod`** — one per instance: `APIC_SERVER` (that instance's
   management/platform API endpoint), `APIC_ORG` (provider organization on that instance), and `APIC_APIKEY`
   (secret, Key Vault-linked; a service ID that is a member of that instance's provider org with a publish role).
4. **Secure files `apic-toolkit-credentials-dev.json`, `-test.json`, `-prod.json`**: each instance's
   `credentials.json` from its API Manager -> *Tools for download*.
5. **Environments `apic-dev`, `apic-integ`, `apic-nightly`, `apic-rc`, `apic-prod`**: add *Approvals* and
   *Exclusive lock* on `apic-integ`, `apic-rc` and `apic-prod` (and on the others if you want a gate there too).
6. **Toolkit binary**: download the Linux CLI from API Manager -> *Tools for download*. If the instances run
   different 10.0.8.x fix packs, use the toolkit of the highest one and verify against each. Online agents:
   publish it as a Universal Package `apic-toolkit` to the Artifacts feed `platform-tools`. Self-hosted agents:
   install it on PATH (the download is skipped automatically).
7. **Repository permissions**: the pipeline pushes tags `published/<stage>`. Grant the build identity
   *Contribute* + *Create tag* (GitHub: a token with `contents:write` used by the checkout step).

## On-prem (offline) agent

The offline bundle (`APIConnect-catalog-bundle-<date>.zip`) contains this repository, `tools/linux-x64/` with
yq, oasdiff, jq, a standalone Spectral and yamllint wheels, and `docs/guide.pdf`. On the agent:

```bash
sudo bash tools/install-offline.sh                 # verifies SHA256SUMS, installs to /usr/local/bin, pip installs yamllint
sudo install -m 0755 apic-slim /usr/local/bin/apic # toolkit from your tenant, not in the bundle
```

Then set `TOOLS_MODE = offline` in `apic-shared` and point `pool:` in the pipeline files at your agent pool.
In offline mode the tooling step never reaches the internet; a missing tool fails the job with a clear message.

## Items to verify on each instance before the first publish

- [ ] Non-interactive login: `apic iam-apikey --server <mgmt> --apiKey <IBM Cloud API key>`. If an instance only
      accepts IBMid/OIDC, switch the login step in `templates/publish-stage.yml` to
      `apic login --server <mgmt> --sso --context provider --apiKey <toolkit API key>` (`apic api-keys:create` with a long `ttl`).
- [ ] `apic apis:get --scope catalog ... --format yaml --output -` returns the bare definition or an envelope
      (`scripts/compat-check.sh` handles both, but check the log the first time).
- [ ] `apic apis:list --format json` returns `{ "results": [...] }` (handled either way, same as above).
- [ ] `apic validate` exits non-zero on an invalid definition (the script also counts "Validated" lines).
- [ ] `--migrate_subscriptions` on republish of an existing `name:version` behaves as expected.
- [ ] Production mode on the `<project>` catalogs of the prod instance: if enabled, republishing the same version
      may be rejected and every prod change needs a version bump + `products:replace`.
- [ ] Catalog-specific property overrides (`x-ibm-configuration.catalogs.<catalog>.properties`) resolve on each gateway.
- [ ] OpenAPI 3.0 subset supported by the DataPower API Gateway; optionally run `apic draft-apis:validate`
      online in `<project>-dev` for extra coverage.
- [ ] Existing content in the catalogs that is not in Git will be flagged as drift by the live check, or replaced
      if a product with the same `name:version` is in Git. Export or retire it first.

## Running the checks locally

Requirements: bash, git, `yamllint`, `@stoplight/spectral-cli`, `yq` (mikefarah v4), `oasdiff`, `jq`, and the
`apic` toolkit for stage 3. Windows: run from Git Bash.

```bash
scripts/changeset.sh --mode pr --base origin/main out/cs      # or: --mode main | --mode stage --stage rc
scripts/validate-yaml.sh out/cs/products.txt out/cs/apis.txt  # 1
scripts/validate-oas.sh  out/cs/apis.txt                      # 2
scripts/validate-apic.sh out/cs/products.txt                  # 3 (needs apic)
scripts/validate-compat.sh out/cs                             # 4, per environment folder
scripts/promote.sh example-project dev test                   # promotion: copies dev/ -> test/, shows the diff
```

## Adding an API

1. `projects/<project>/dev/apis/<api>.yaml` — OpenAPI 3.0.x with `info.x-ibm-name`, semver `info.version`,
   one `servers[].url`, and `x-ibm-configuration` with `catalogs.*` overrides for all five catalogs
   (see `projects/example-project`).
2. Reference it from a product in `projects/<project>/dev/products/` via `$ref: ../apis/<api>.yaml`.
3. Open a PR. Fix anything the four stages report. Merge -> `<project>-dev`, approve -> `<project>-integ`.
4. When ready: `scripts/promote.sh <project> dev test`, PR, merge -> `-nightly`, approve -> `-rc`.
5. Then `scripts/promote.sh <project> test prod`, PR, merge, approve -> `<project>`.

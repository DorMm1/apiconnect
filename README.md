# APIConnect-catalog

GitOps repository for the APIs and Products published to **IBM API Connect 10.0.8.x** with the `apic` toolkit,
driven by **Azure DevOps Pipelines**.

* Git is the single source of truth. API Manager drafts are not used; humans should only have *viewer* roles
  on the catalogs, the pipeline identities are the only publishers.
* **Every publish is a pull request into the default branch.** PRs are validated (four fail-fast stages); the
  merge publishes the changed folders to their catalogs.
* Nothing is ever deleted or retired from APIC by this pipeline.

## Topology

Three **API Connect instances** (separate clusters, ingress URLs and credentials), four **version folders** per
project, five **catalogs** per project. A *stage* publishes one folder to one catalog on one instance:

| Folder | Stage | Catalog | Instance | Published when |
|---|---|---|---|---|
| `projects/<project>/dev/`   | `dev`     | `<project>-dev`     | dev  | a PR that changed `dev/` is merged |
| `projects/<project>/dev/`   | `nightly` | `<project>-nightly` | test | same merge - `dev/` feeds both catalogs, no separate process |
| `projects/<project>/integ/` | `integ`   | `<project>-integ`   | dev  | a promotion PR `dev -> integ` is merged |
| `projects/<project>/rc/`    | `rc`      | `<project>-rc`      | test | a promotion PR `integ -> rc` is merged |
| `projects/<project>/prod/`  | `prod`    | `<project>`         | prod | a promotion PR `rc -> prod` is merged |

* A folder holds **the version its catalog(s) should have**. Promotion = `scripts/promote.sh <project> <from> <to>`
  copies the folder, you review the diff and open a PR. Order: `dev -> integ -> rc -> prod`.
* Each stage remembers its last publish with the git tag `published/<stage>` and only publishes what changed since.
* **Instances and their ingress URLs** live in [`config/topology.yml`](config/topology.yml): `ingress.management`
  is the `apic --server` value, `ingress.gateway` the API gateway, `org` the provider organization. When an
  ingress changes, edit that file - nothing else. Only the API keys and the toolkit `credentials.json` files stay in
  Azure DevOps.
* A project can override catalog names in `projects/<project>/project.yaml`.

## Layout

```
.azure-pipelines/
  apic-ci.yml                  entry pipeline: validate (PR + main) -> 5 independent publish stages
  templates/install-tools.yml  yamllint, spectral, yq, oasdiff, apic toolkit (online or offline mode)
  templates/publish-stage.yml  one deployment stage per catalog
config/
  topology.yml                 instances (ingress URLs, org), stages: folder -> catalog -> instance
  .yamllint.yml                stage 1 rules
  spectral.yml                 stage 2 rules (OAS 3.0 + APIC-specific)
  compat-ignore.txt            stage 4 reviewed exceptions (oasdiff --err-ignore)
scripts/                       everything the pipeline runs; usable locally (see below)
tools/install-offline.sh       installs the bundled tools on an on-prem (offline) Linux x64 agent
docs/guide.pdf                 the readable guide (docs/guide.html is the source)
docs/onprem-setup.pdf          step-by-step runbook for Azure DevOps Server + self-hosted agent
projects/
  <project>/
    project.yaml               optional: owner, catalog-name overrides
    dev/                       development state -> <project>-dev (dev instance) + <project>-nightly (test instance)
      apis/<api>.yaml          OpenAPI 3.0.x + x-ibm-configuration
      products/<product>.yaml  APIC product: plans, rate limits, visibility, apis.*.$ref -> ../apis/<api>.yaml
    integ/                     -> <project>-integ (dev instance);  filled by promote.sh dev integ
    rc/                        -> <project>-rc (test instance);    filled by promote.sh integ rc
    prod/                      -> <project> (prod instance);       filled by promote.sh rc prod
```

A **project folder = ownership boundary** and the prefix of its catalog names. A **version folder = the version
its catalog(s) should have**. Files are meant to be byte-identical across folders; catalog differences are
expressed *inside* the file (see "One file, five catalogs").

## Conventions (enforced by the pipeline)

| Rule | Where enforced |
|---|---|
| Files are valid YAML | stage 1, `yamllint` |
| OpenAPI 3.0.x, `info.x-ibm-name` is a lowercase slug, `info.version` is strict semver, single `servers[]` entry, `x-ibm-configuration` with explicit `enforced`, DataPower API Gateway, no callbacks/links | stage 2, `spectral` (`config/spectral.yml`) |
| Products reference APIs only through a relative `$ref` into the **same** `projects/<project>/<folder>/apis/`; no name:version refs, no cross-project or cross-folder refs; `apic validate` passes | stage 3, `scripts/validate-apic.sh` |
| No breaking contract change without a MAJOR bump of `info.version`, judged per folder | stage 4, `oasdiff` |
| Catalog-specific values live in `x-ibm-configuration.properties` + `catalogs.<catalog>.properties`, keyed by all five catalog names of the project; `integ/`, `rc/` and `prod/` are only written by `promote.sh` | review + `promote.sh` |

### One file, five catalogs

```yaml
x-ibm-configuration:
  properties:
    target-url: { value: https://orders-dev.internal }          # default
  catalogs:                                                     # overrides by catalog name
    orders-dev:     { properties: { target-url: https://orders-dev.internal } }
    orders-nightly: { properties: { target-url: https://orders-nightly.internal } }
    orders-integ:   { properties: { target-url: https://orders-integ.internal } }
    orders-rc:      { properties: { target-url: https://orders-rc.internal } }
    orders:         { properties: { target-url: https://orders.internal } }
```

Because every catalog's value is in the file, one `dev/` file serves `-dev` and `-nightly` at once, promotion is
a pure copy, and the compatibility gate never sees catalog differences as contract changes.

### Versioning

* APIC identifies an API by `x-ibm-name:version` and a product by `name:version`.
* **Non-breaking** change: keep the version (or bump MINOR/PATCH); the product is republished in place,
  subscriptions retained.
* **Breaking** change: bump the API MAJOR **and** the product version. Both versions coexist in the catalog.
  Subscriptions are migrated later with `apic products:replace` / `products:supersede` and the old version is
  retired by hand (deprecate -> retire -> delete). This pipeline will not do that for you.

### Backward-compatibility policy (stage 4)

Baseline = the same file as it was at the folder's last publish (git) or the latest published version with
the same MAJOR in the target catalog (live, before publish). `oasdiff breaking` classifies changes:

| Class | Examples | Outcome |
|---|---|---|
| **Breaking (ERR)** | remove/rename path, operation, request parameter or property; add a *required* request parameter/property; change a type/format; narrow a request enum; remove a response property, status code or media type; tighten security; change the base path | fails unless MAJOR was bumped |
| **Potentially breaking (WARN)** | new response status code; new enum value in a response; deprecation; loosened response constraints | reported only |
| **Non-breaking** | new path/operation; *optional* request parameter/property; new response property; widened request enum; descriptions/examples/tags; anything under `x-ibm-*` | passes |

Exceptions are added to `config/compat-ignore.txt` in the same PR, one per line, with a justification.

## How a change flows

```
PR -> main       : 0 change set per folder -> 1 yamllint -> 2 spectral -> 3 apic validate -> 4 oasdiff (vs target branch)
merge to main    : same validation (vs each stage's published/<stage> tag), then every stage whose folder has
                   something new, in parallel (the others are Skipped):
  dev/    -> publish_dev     -> <project>-dev      dev  instance
  dev/    -> publish_nightly -> <project>-nightly  test instance
  integ/  -> publish_integ   -> <project>-integ    dev  instance
  rc/     -> publish_rc      -> <project>-rc       test instance
  prod/   -> publish_prod    -> <project>          prod instance
each stage       : resolve ingress/org from topology.yml -> login to the instance -> change set vs published/<stage>
                   -> 4' oasdiff vs live catalog -> apic products:publish per product -> move tag published/<stage>
```

* **Change set** = changed product files + products whose `$ref` points at a changed API file, restricted to the
  stage's folder (`scripts/changeset.sh`). Deleted files only produce a warning.
* **Tags `published/<stage>`** (5) mark the last commit published to each catalog. A stage diffs against its own
  tag, so a failed publish is simply retried by the next run. No tag => bootstrap: every product of the folder.
* **Promotion** = `scripts/promote.sh <project> dev integ` (then `integ rc`, `rc prod`), review the diff, PR, merge.
  The PR review is the gate; an approval on the Azure DevOps Environment `apic-<stage>` can be added as a
  second gate (recommended for `apic-prod`).
* **Rollback** = promote again from a folder that still has the previous version, or run the pipeline for an
  earlier commit, or `apic products:replace` to the previous product version.

## Azure DevOps setup

1. **Pipeline**: create from `.azure-pipelines/apic-ci.yml`. For a GitHub-hosted repo the `pr:` trigger is used;
   make the pipeline a required status check on `main`. For Azure Repos add a *Build validation* branch policy.
   Two settings at the top of `apic-ci.yml`: `AGENT_POOL` (self-hosted pool name; empty = Microsoft-hosted
   `ubuntu-latest`) and `APIC_TOOLKIT_SOURCE` (`preinstalled` on the agent, or `artifacts` = Universal Package).
2. **`config/topology.yml`**: replace the `CHANGE ME` ingress URLs and org names of the three instances.
3. **Variable group `apic-shared`** (plain): `APIC_TOOLKIT_VERSION` (e.g. `10.0.8.9`), `TOOLS_MODE`
   (`online` for Microsoft-hosted agents, `offline` for a self-hosted agent prepared with `tools/install-offline.sh`).
4. **Variable groups `apic-dev`, `apic-test`, `apic-prod`** - one per instance, Key Vault-linked: `APIC_APIKEY`
   (a service ID that is a member of that instance's provider org with a publish role).
5. **Secure files `apic-toolkit-credentials-dev.json`, `-test.json`, `-prod.json`**: each instance's
   `credentials.json` from its API Manager -> *Tools for download*.
6. **Environments `apic-dev`, `apic-nightly`, `apic-integ`, `apic-rc`, `apic-prod`**: created automatically on
   first run. Add *Exclusive lock* on all five; add *Approvals* where you want a gate besides the PR (e.g. `apic-prod`).
7. **Toolkit binary**: download the Linux CLI from API Manager -> *Tools for download*. If the instances run
   different 10.0.8.x fix packs, use the toolkit of the highest one and verify against each. Online agents:
   publish it as a Universal Package `apic-toolkit` to the Artifacts feed `platform-tools`. Self-hosted agents:
   install it on PATH (the download is skipped automatically).
8. **Repository permissions**: the pipeline pushes tags `published/<stage>`. Grant the build identity
   *Contribute* + *Create tag* (GitHub: a token with `contents:write` used by the checkout step).
9. **Catalogs** on the API Connect side: `<project>-dev`, `<project>-integ` on dev; `<project>-nightly`,
   `<project>-rc` on test; `<project>` on prod - or declare other names in `project.yaml`.

## On-prem: Azure DevOps Server + offline agent

Follow **`docs/onprem-setup.pdf`** - an 11-step runbook (agent, certificates, repo import, API Connect
credentials, library, pipeline, branch policy, permissions, first run). In short:

```bash
sudo bash tools/install-offline.sh                 # bundle tools -> /usr/local/bin, yamllint via pip --no-index
sudo install -m 0755 apic-slim /usr/local/bin/apic # toolkit from your API Manager, not in the bundle
```

* `config/topology.yml`: ingress URLs and org of the three instances. `apic-ci.yml`: `AGENT_POOL = <your pool>`,
  `APIC_TOOLKIT_SOURCE = preinstalled`. Variable group `apic-shared`: `TOOLS_MODE = offline`.
* Azure Repos ignores the YAML `pr:` block: PR validation is a *Build validation* branch policy on `main`.
* No Key Vault on-prem: `APIC_APIKEY` is a padlocked secret variable in `apic-dev/test/prod`.
* The agent needs HTTPS to the Azure DevOps Server and to the three management ingresses; internal CAs go into the
  OS trust store (+ `NODE_EXTRA_CA_CERTS`).

## Items to verify on each instance before the first publish

- [ ] `config/topology.yml` has the real ingress URLs; `apic catalogs:list --server <ingress.management> --org <org>`
      works after `apic iam-apikey --server <ingress.management> --apiKey <IBM Cloud API key>`. If an instance only
      accepts IBMid/OIDC, switch the login step in `templates/publish-stage.yml` to
      `apic login --server ... --sso --context provider --apiKey <toolkit API key>` (`apic api-keys:create` with a long `ttl`).
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
scripts/validate-compat.sh out/cs                             # 4, per folder
scripts/promote.sh example-project dev integ                  # promotion: copies dev/ -> integ/, shows the diff
eval "$(scripts/stage-env.sh --stage rc)"                     # APIC_SERVER / APIC_ORG of the instance behind a stage
```

## Adding an API

1. `projects/<project>/dev/apis/<api>.yaml` - OpenAPI 3.0.x with `info.x-ibm-name`, semver `info.version`,
   one `servers[].url`, and `x-ibm-configuration` with `catalogs.*` overrides for all five catalogs
   (see `projects/example-project`).
2. Reference it from a product in `projects/<project>/dev/products/` via `$ref: ../apis/<api>.yaml`.
3. Open a PR. Fix anything the four stages report. Merge -> `<project>-dev` and `<project>-nightly`.
4. `scripts/promote.sh <project> dev integ`, PR, merge -> `<project>-integ`.
5. `scripts/promote.sh <project> integ rc`, PR, merge -> `<project>-rc`.
6. `scripts/promote.sh <project> rc prod`, PR, merge -> `<project>`.

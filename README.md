# Steadforce SteadOps GitHub workflows
This repository provides GitHub reusable workflows to share between repositories.

## Helm hydration workflow
The Helm hydration workflow implements the Helm GitOps hydration pattern. In this context,
"hydration" refers to the process of rendering Helm charts into Kubernetes manifests before deployment.
This allows you to validate your manifests as part of your CI/CD pipeline, ensuring that only fully
rendered and tested resources are applied to your cluster.

**Benefits:**
- Enables pre-deployment validation and linting of Kubernetes manifests.
- Supports customization and templating of resources for different environments.
- Automates the rendering process, reducing manual errors.

**When to use:**  
Use this workflow when you want to automate the rendering of Helm charts as part of your GitOps pipeline, especially
if you need to validate or modify manifests before deployment.

**Inputs:**

| Input | Description | Default | Required |
|---|---|---|---|
| `helm-version` | Helm CLI version to install, e.g. `v3.17.0` | `latest` | No |
| `bundle-patches-in-one-pr` | Group all patch-level subchart updates into a single PR/branch instead of one PR per patch release | `true` | No |
| `charts-root` | Directory the chart search starts from | `.` | No |
| `chart-discovery-depth` | Maximum search depth for `helm-config.yaml` below `charts-root` | `1` | No |
| `create-pull-request` | Push the hydrated manifests to the environment branch and open a pull request. Set to `false` to render only | `true` | No |
| `upload-artifact` | Publish the rendered manifests as one artifact per chart and environment, named `hydrated-<chart>-<environment>` | `false` | No |

**Required repository layout:**

Every directory holding a `helm-config.yaml` is treated as a chart and must also
contain `Chart.yaml`. With the default inputs only the repository root is
searched, which is the one-chart-per-repository layout.

```yaml
releaseName: my-chart       # required
namespace: my-namespace     # required
primaryDependency: upstream # optional, see below
environments:
  dev:
    apis:
    - some.crd.io/v1/Resource
    valueFiles:
    - values-dev.yaml
  prod:
    apis:
    - some.crd.io/v1/Resource
    valueFiles:
    - values-prod.yaml
```

`valueFiles` paths are relative to the chart directory. Anchors and aliases are
resolved, so environments sharing a definition can be written once and reused.

The version reported in the branch name and PR title is the resolved version of
the chart's *primary dependency* — the subchart whose version identifies the
chart. It defaults to the dependency sharing the chart's own name. Umbrella
charts wrapping an upstream chart of a different name (for example a chart named
`prometheus-operator` depending on `kube-prometheus-stack`) name it explicitly
via `primaryDependency`. A chart without any dependencies reports its own
version from `Chart.yaml`.

**Chart.lock:**

Committing `Chart.lock` is recommended but not required.

| | Committed | Not committed |
|---|---|---|
| Dependency install | `helm dependency build`, exactly the pinned versions | `helm dependency update`, constraints re-resolved on every run |
| Reproducibility | Manifests are a function of the commit | An upstream release can change the manifests with no commit |
| Reported version | The pinned version | The version resolved during the run |
| Workflow output | — | A warning naming the chart |

Either way the reported version is the one that was actually installed, so it is
always a concrete semver and safe inside a git branch name. Repositories that
git-ignore the lock file keep working unchanged.

**Repositories holding several charts:**

Point `charts-root` and `chart-discovery-depth` at the directory the charts live
in. Each chart then owns the sub-directory `hydrated-manifests/<chart name>` on
the environment branch and carries its name in the PR branch, so charts sharing
a branch do not overwrite each other.

```
apps/
  loki/
    Chart.yaml
    Chart.lock
    helm-config.yaml
    values-prod.yaml
    templates/
  prometheus-operator/
    ...
```

**Required permissions:**
```yaml
permissions:
  contents: write
  pull-requests: write
  issues: write        # optional, see below
```

`issues: write` is only needed to give the per-environment label a fixed colour.
Labels belong to the issues API even when they are only ever used on pull
requests, and the permissions of a reusable workflow are capped by those of its
caller, so the workflow cannot grant it to itself. Without it the run still
succeeds: the label is applied to the pull request either way, GitHub just
picks a random colour for it the first time it appears.

**Usage example:**
```yaml
name: Helm hydration

on:
  push:
    branches:
    - main

permissions:
  contents: write
  pull-requests: write
  issues: write

jobs:
  hydration:
    uses: steadforce/steadops-workflows/.github/workflows/helm-hydration.yaml@main
```

**Usage example for several charts:**
```yaml
jobs:
  hydration:
    uses: steadforce/steadops-workflows/.github/workflows/helm-hydration.yaml@main
    with:
      charts-root: apps
      chart-discovery-depth: 2
```

**How it works:**
1. Searches `charts-root` for `helm-config.yaml` files and builds a parallel job matrix — one job per chart and environment.
2. Creates the `environments/<name>` branch on origin once per environment if it does not exist yet, as an orphan branch, and creates the `env: <name>` label if it does not exist yet.
3. For each chart and environment: installs Helm, reads the chart name and the resolved primary subchart version from `Chart.lock`, installs the dependencies pinned in `Chart.lock`, runs `helm template` with the environment-specific value files and API groups, and post-processes CRD manifests to inject ArgoCD `ServerSideApply=true` and sync-wave `-1` annotations. If `bundle-patches-in-one-pr` is `true`, the patch segment of the version is replaced with `x`.
4. Moves the manifests onto the environment branch, replacing only the output of the chart being hydrated.
5. Opens or updates a pull request from `hydration-pull-request/<env>[-<chart>]-<version>` into `environments/<env>`, labelled `hydration`, `automated pr` and `env: <env>`.

**Environment label colours:**

The `env: <name>` label is coloured so that the tier a pull request targets is
readable from the list without opening it. The title keeps its `[<env>]` prefix
as well.

The tier chooses the colour family:

| Segment in the environment name | Family |
|---|---|
| `prod`, `prod<n>`, `production`, `live`, `prd` | red |
| `stage`, `staging`, `stg`, `preprod`, `uat` | orange |
| `test`, `test<n>`, `testing`, `qa`, `int` | blue |
| `dev`, `dev<n>`, `develop`, `development` | green |
| `local`, `localhost`, `sandbox`, `demo`, `kind`, `minikube` | grey |
| none of the above | purple, teal and friends |

The tier is read from the name's **segments**, not from the whole name, because
an environment is commonly named after its cluster with the tier as one part of
it: `sf-k8s01-prod` is production and `sf-k8s02-dev` is not. Matching on
segments also keeps `sf-devops` out of the development family, which a plain
substring match would not. Where a name contains more than one tier the most
severe wins, so nothing that mentions production is coloured as though it were
not.

Within the family the shade comes from the number in the name, so sibling
clusters get consecutive shades and cannot collide:

| Environment | Colour |
|---|---|
| `sf-k8s01-dev` | green `#3fb950` |
| `sf-k8s02-dev` | green `#116329` |
| `sf-k8s03-dev` | green `#57ab5a` |
| `sf-k8s04-dev` | green `#0e8a16` |
| `sf-k8s01-prod` | red `#a40e26` |
| `local` | grey `#8c959f` |

A name with no number falls back to a hash of the name. Either way the colour is
stable for a given name across every run and every repository.

An existing label is never recoloured, so a repository that changed one on
purpose keeps its choice.

With `create-pull-request: false` the workflow stops after step 3 and neither
creates a branch nor opens a pull request, which makes it usable as a
validation step on pull requests.

---

## Helm unittest workflow
The helm unittest workflow bundles helm unittest and helm linting.

**Inputs:**

| Input | Description | Default | Required |
|---|---|---|---|
| `helm-version` | Helm CLI version to install, e.g. `v3.19.0` | `latest` | No |
| `helm-unittest-version` | Helm unittest plugin version, e.g. `1.0.3` | `main` (latest) | No |
| `charts-root` | Directory the chart search starts from | `.` | No |
| `chart-discovery-depth` | Maximum search depth for a chart's `tests/` directory below `charts-root` | `2` | No |
| `with-subchart` | Also run the tests of charts under `charts/` | `true` | No |

**Secrets:**

| Secret | Description | Required |
|---|---|---|
| `steadops-helm-renovation-ms-teams-webhook` | MS Teams webhook URL used for notifications on Renovate branches. Notifications are skipped when it is not passed | No |

**Which charts are tested:**

Every directory holding both a `Chart.yaml` and a `tests/` directory. A chart
without tests is skipped rather than failing, so charts can adopt tests one at a
time. With the default inputs that is the repository root, the
one-chart-per-repository layout; repositories holding several charts point
`charts-root` and `chart-discovery-depth` at the directory the charts live in:

```yaml
jobs:
  unittest:
    uses: steadforce/steadops-workflows/.github/workflows/helm-unittest.yaml@main
    with:
      charts-root: .
      chart-discovery-depth: 3
      with-subchart: false
```

**Usage example:**
```yaml
name: Helm unittest CI

on:
  pull_request:

jobs:
  unittest:
    uses: steadforce/steadops-workflows/.github/workflows/helm-unittest.yaml@main
    secrets:
      steadops-helm-renovation-ms-teams-webhook: ${{ secrets.steadops-helm-renovation-ms-teams-webhook }}
```

**How it works:**
1. Finds every chart with a `tests/` directory and builds a job matrix from them.
2. Installs the requested Helm version and the `helm-unittest` plugin.
3. Runs `helm dependency update` to resolve chart dependencies.
4. Runs `helm unittest` and publishes the JUnit test results to the GitHub Actions summary.
5. Runs `helm lint` to validate the chart.
6. On Renovate branches (refs containing `renovate/`), sends a success or failure notification to MS Teams, if the webhook secret was passed.

---

## Gitleaks secret scan workflow
Scans the repository for leaked secrets using [Gitleaks](https://github.com/gitleaks/gitleaks) before they reach the main branch.

**Inputs:**

| Input | Description | Default | Required |
|---|---|---|---|
| `gitleaks-ignore-path` | Path to the Gitleaks ignore file | `.gitleaksignore` | No |

**Usage example:**
```yaml
name: Secret scan

on:
  pull_request:
  push:
    branches:
    - main

jobs:
  gitleaks:
    uses: steadforce/steadops-workflows/.github/workflows/gitleaks.yaml@main
```

**How it works:**  
Checks out the full git history (`fetch-depth: 0`) and scans all commits with Gitleaks. Secrets matching patterns in the ignore file are excluded.

---

## Trufflehog secret scan workflow
Scans commits for leaked secrets using [Trufflehog OSS](https://github.com/trufflesecurity/trufflehog). Automatically determines the commit range from the pull request or push event context.

**Inputs:** None

**Usage example:**
```yaml
name: Secret scan

on:
  pull_request:
  push:
    branches:
    - main

jobs:
  trufflehog:
    uses: steadforce/steadops-workflows/.github/workflows/trufflehog-oss.yaml@main
```

**How it works:**
1. Resolves the `base`/`head` commit range from the PR or push event. Falls back to `HEAD~1` if no valid base is available, and skips the scan if no range can be determined.
2. Runs Trufflehog over the resolved commit range.
3. Publishes a results table to the GitHub Actions step summary.
4. Fails the job if Trufflehog detects any secrets.

---

## Developing these workflows

### Linting

`lint-workflows.yaml` runs actionlint over every workflow on each pull request.
It checks the workflow syntax, the `${{ }}` expressions, the event and matrix
references and the `uses:` specifications, and runs shellcheck over every
`run:` block. Reproduce it locally with:

```bash
actionlint -color
```

### Testing the hydration workflow

`test-helm-hydration.yaml` renders the fixture charts under `tests/fixtures`
with the hydration workflow of this repository and compares the result against
the manifests in `tests/golden`. It calls the workflow through a relative
`uses:`, so a change is validated by the same run that proposes it, and it uses
render-only mode so no branches are created here.

After intentionally changing a fixture, the rendering logic or the pinned Helm
version, regenerate the goldens and review the diff:

```bash
tests/regenerate-golden.sh
```

See [tests/README.md](tests/README.md) for what the fixtures cover.

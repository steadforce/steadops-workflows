# SteadOps GitHub Workflows

Reusable GitHub Actions workflows and a composite action that the SteadOps repositories share for Helm GitOps
hydration, Helm chart testing, secret scanning, and MS Teams notifications.

## Overview

Workflows live in `.github/workflows/`, the action in `.github/actions/`.

| Component | File | Purpose |
|---|---|---|
| [Helm hydration](#helm-hydration-workflow) | `helm-hydration.yaml` | Render charts, open one PR per environment |
| [Helm unittest](#helm-unittest-workflow) | `helm-unittest.yaml` | helm-unittest and `helm lint`, Teams on Renovate |
| [Gitleaks](#gitleaks-secret-scan-workflow) | `gitleaks.yaml` | Scan the full git history for secrets |
| [Trufflehog](#trufflehog-secret-scan-workflow) | `trufflehog-oss.yaml` | Scan pushed or PR commits for secrets |
| [Teams notification](#ms-teams-notification-action) | `teams-notification/action.yml` | Post a job result to Teams |

Reference a workflow from a job with `uses:`, either at `@main` as in the examples below or at a release tag such
as `@v4.1.0`:

```yaml
jobs:
  unittest:
    uses: steadforce/steadops-workflows/.github/workflows/helm-unittest.yaml@main
```

> [!NOTE]
> The reusable workflows are triggered by `workflow_call` only. The calling repository decides on which events
> they run.

---

## Helm Hydration Workflow

The Helm hydration workflow implements the Helm GitOps hydration pattern. "Hydration" means rendering Helm charts
into plain Kubernetes manifests before deployment, so that the manifests a GitOps agent such as Argo CD applies are
reviewed as a pull request and can be validated in CI.

Use it to render charts per environment in a GitOps pipeline, especially when manifests have to be validated or
reviewed before they reach a cluster.

### Hydration Inputs

| Input | Description | Default | Required |
|---|---|---|---|
| `helm-version` | Helm CLI version to install, e.g. `v3.17.0` | `latest` | No |
| `bundle-patches-in-one-pr` | Group patch-level subchart updates into one PR per minor version | `true` | No |
| `charts-root` | Directory the chart search starts from | `.` | No |
| `chart-discovery-depth` | Maximum search depth for `helm-config.yaml` below `charts-root` | `1` | No |
| `create-pull-request` | Push to the environment branch and open a PR. `false` renders only | `true` | No |
| `upload-artifact` | Publish the manifests as one artifact `hydrated-<chart>-<environment>` per chart | `false` | No |

### Repository Layout

Every directory holding a `helm-config.yaml` is treated as a chart and must also contain `Chart.yaml`. With the
default inputs only the repository root is searched, which is the one-chart-per-repository layout.

`helm-config.yaml` defines the release and the environments:

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

- `valueFiles` paths are relative to the chart directory and are passed to `helm template -f`.
- `apis` are passed to `helm template -a`, so templates gated on `.Capabilities.APIVersions` render.
- Anchors and aliases are resolved, so environments sharing a definition can be written once and reused.

The version in the branch name and PR title is the installed version of the chart's *primary dependency*, the
subchart whose version identifies the chart. It defaults to the dependency sharing the chart's own name. Umbrella
charts around an upstream chart of a different name (for example a chart named `prometheus-operator` depending on
`kube-prometheus-stack`) name it explicitly via `primaryDependency`. A chart without any dependencies reports its
own version from `Chart.yaml`.

### Chart.lock

Committing `Chart.lock` is recommended but not required.

| | Committed | Not committed |
|---|---|---|
| Dependency install | `helm dependency build`, the pinned versions | `helm dependency update`, re-resolved per run |
| Reproducibility | Manifests are a function of the commit | An upstream release can change them with no commit |
| Reported version | The pinned version | The version resolved during the run |
| Workflow output | — | A warning naming the chart |

Either way the reported version is the one that was actually installed, so it is always a concrete semver and safe
inside a git branch name. A `Chart.lock` that is out of sync with `Chart.yaml` fails the run.

The HTTP(S) repositories declared in `Chart.yaml` are registered with `helm repo add` before the dependencies are
installed, so no extra setup is needed. `oci://` and `file://` dependencies need no repository entry. A repository
alias (`@name` or `alias:name`) must already be registered on the runner, which only a self-hosted runner can
provide.

### Repositories Holding Several Charts

Point `charts-root` and `chart-discovery-depth` at the directory the charts live in. Each chart then owns the
sub-directory `hydrated-manifests/<chart name>` on the environment branch and carries its name in the PR branch,
so charts sharing a branch do not overwrite each other.

```text
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

### Hydration Permissions

```yaml
permissions:
  contents: write
  pull-requests: write
  issues: write        # optional, see below
```

`issues: write` is only needed to give the per-environment label a fixed colour. Labels belong to the issues API
even when they are only ever used on pull requests, and the permissions of a reusable workflow are capped by those
of its caller, so the workflow cannot grant it to itself. Without it the run still succeeds: the label is applied to
the pull request either way, GitHub just picks a random colour for it the first time it appears.

### Hydration Usage

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

For several charts below `apps/`:

```yaml
jobs:
  hydration:
    uses: steadforce/steadops-workflows/.github/workflows/helm-hydration.yaml@main
    with:
      charts-root: apps
      chart-discovery-depth: 2
```

To validate the rendering on pull requests without pushing anything:

```yaml
jobs:
  hydration:
    uses: steadforce/steadops-workflows/.github/workflows/helm-hydration.yaml@main
    with:
      create-pull-request: false
```

### How Hydration Works

1. Searches `charts-root` for `helm-config.yaml` files and builds a parallel job matrix, one job per chart and
   environment.
2. Creates the `environments/<name>` branch on origin once per environment if it does not exist yet, as an orphan
   branch, and creates the `env: <name>` label if it does not exist yet.
3. For each chart and environment:
   1. Installs Helm and the chart dependencies, as described under [Chart.lock](#chartlock).
   2. Reads the chart name from `Chart.yaml` and the primary dependency version from `Chart.lock`. If
      `bundle-patches-in-one-pr` is `true`, the patch segment of the version is replaced with `x`.
   3. Runs `helm template` with the environment's value files and API versions, `--include-crds` and
      `--skip-tests`.
   4. Adds the Argo CD annotations `sync-options: ServerSideApply=true` and `sync-wave: "-1"` to every
      CustomResourceDefinition. An existing `sync-options` value is extended, an existing `sync-wave` is kept.
4. Moves the manifests onto the environment branch, replacing only the output of the chart being hydrated.
5. Uploads the manifests as an artifact, if `upload-artifact` is `true`.
6. Opens or updates a pull request from `hydration-pull-request/<env>[-<chart>]-<version>` into
   `environments/<env>`, labelled `hydration`, `automated pr` and `env: <env>`.

With `create-pull-request: false`, steps 2, 4 and 6 are skipped: no branch is created and no pull request is
opened, which makes the workflow usable as a validation step on pull requests.

### Environment Label Colours

The `env: <name>` label is coloured so that the tier a pull request targets is readable from the list without
opening it. The title keeps its `[<env>]` prefix as well.

The tier chooses the colour family:

| Segment in the environment name | Family |
|---|---|
| `prod`, `prod<n>`, `production`, `live`, `prd` | red |
| `stage`, `staging`, `stg`, `preprod`, `uat` | orange |
| `test`, `test<n>`, `testing`, `qa`, `int` | blue |
| `dev`, `dev<n>`, `develop`, `development` | green |
| `local`, `localhost`, `sandbox`, `demo`, `kind`, `minikube` | grey |
| none of the above | purple, teal and friends |

The tier is read from the name's **segments**, not from the whole name, because an environment is commonly named
after its cluster with the tier as one part of it: `sf-k8s01-prod` is production and `sf-k8s02-dev` is not.
Matching on segments also keeps `sf-devops` out of the development family, which a plain substring match would
not. Where a name contains more than one tier the most severe wins, so nothing that mentions production is coloured
as though it were not.

Each family has six shades. The shade comes from the digits in the name, so up to six sibling clusters get
distinct, consecutive shades:

| Environment | Colour |
|---|---|
| `sf-k8s01-dev` | green `#3fb950` |
| `sf-k8s02-dev` | green `#116329` |
| `sf-k8s03-dev` | green `#57ab5a` |
| `sf-k8s04-dev` | green `#0e8a16` |
| `sf-k8s01-prod` | red `#a40e26` |
| `local` | grey `#8c959f` |

A name with no digits falls back to a hash of the name. Either way the colour is stable for a given name across
every run and every repository. An existing label is never recoloured, so a repository that changed one on purpose
keeps its choice.

---

## Helm Unittest Workflow

Runs [helm-unittest](https://github.com/helm-unittest/helm-unittest) and `helm lint` for every chart with tests,
and optionally reports the result of Renovate branches to MS Teams, so an automated chart version bump can be
merged with confidence.

### Unittest Inputs

| Input | Description | Default | Required |
|---|---|---|---|
| `helm-version` | Helm CLI version to install, e.g. `v3.19.0` | `latest` | No |
| `helm-unittest-version` | Helm unittest plugin version, e.g. `1.0.3` | `main` (latest) | No |
| `charts-root` | Directory the chart search starts from | `.` | No |
| `chart-discovery-depth` | Maximum search depth for a chart's `tests/` directory below `charts-root` | `2` | No |
| `with-subchart` | Also run the tests of charts under `charts/` | `true` | No |

### Unittest Secrets

Both secrets take an MS Teams Workflows webhook URL, see the
[MS Teams notification action](#ms-teams-notification-action). Notifications are skipped when neither is passed.

| Secret | Description | Required |
|---|---|---|
| `steadops-helm-renovation-ms-teams-webhook` | Receives successes, and failures when no error webhook is passed | No |
| `steadops-helm-renovation-ms-teams-error-webhook` | Receives failures instead, e.g. in an error channel | No |

### Unittest Permissions

The test results are published with
[EnricoMi/publish-unit-test-result-action](https://github.com/EnricoMi/publish-unit-test-result-action), which
creates a check run and a pull request comment. Grant these permissions when the default `GITHUB_TOKEN` is
read-only:

```yaml
permissions:
  checks: write
  contents: read
  issues: read     # private repositories only
  pull-requests: write
```

### Which Charts Are Tested

Every directory holding both a `Chart.yaml` and a `tests/` directory. A chart without tests is skipped rather than
failing, so charts can adopt tests one at a time. The run fails when no chart with tests is found.

With the default inputs that is the repository root, the one-chart-per-repository layout. Repositories holding
several charts point `charts-root` and `chart-discovery-depth` at the directory the charts live in:

```yaml
jobs:
  unittest:
    uses: steadforce/steadops-workflows/.github/workflows/helm-unittest.yaml@main
    with:
      charts-root: .
      chart-discovery-depth: 3
      with-subchart: false
```

### Unittest Usage

```yaml
name: Helm unittest CI

on:
  pull_request:

permissions:
  checks: write
  contents: read
  pull-requests: write

jobs:
  unittest:
    uses: steadforce/steadops-workflows/.github/workflows/helm-unittest.yaml@main
    secrets:
      steadops-helm-renovation-ms-teams-webhook: ${{ secrets.steadops-helm-renovation-ms-teams-webhook }}
      steadops-helm-renovation-ms-teams-error-webhook: ${{ secrets.steadops-helm-renovation-ms-teams-error-webhook }}
```

### How Unittest Works

1. Finds every chart with a `tests/` directory and builds a job matrix from them.
2. Installs the requested Helm version and the helm-unittest plugin.
3. Installs the chart dependencies: `helm dependency build` when a `Chart.lock` is committed, so the pinned
   subchart versions are tested, otherwise `helm dependency update` with a warning that the lock file should be
   committed. The HTTP(S) repositories declared in `Chart.yaml` are registered first.
4. Runs `helm unittest` with JUnit output and publishes the results as a check run and job summary, also when the
   tests fail.
5. Runs `helm lint` to validate the chart.
6. On Renovate branches (branches starting with `renovate/`, for pull requests the source branch), posts a success
   or failure Adaptive Card with the [MS Teams notification action](#ms-teams-notification-action). Successes go to
   `steadops-helm-renovation-ms-teams-webhook`, failures to `steadops-helm-renovation-ms-teams-error-webhook`,
   falling back to the former when no error webhook was passed.

> [!TIP]
> A `Chart.lock` that is out of sync with `Chart.yaml` fails the dependency step. Run `helm dependency update` and
> commit the lock file together with `Chart.yaml`.

---

## Gitleaks Secret Scan Workflow

Scans the full git history for leaked secrets using [Gitleaks](https://github.com/gitleaks/gitleaks) before they
reach the main branch.

### Gitleaks Inputs

| Input | Description | Default | Required |
|---|---|---|---|
| `gitleaks-ignore-path` | Path to the Gitleaks ignore file | `.gitleaksignore` | No |

### Gitleaks Usage

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

### How Gitleaks Works

Checks out the full git history (`fetch-depth: 0`) and scans every commit with Gitleaks 8.30.1 in `git` mode, so
secrets that were committed and later deleted are found as well. Findings listed by fingerprint in the ignore file
are excluded, which silences known false positives. The job fails on any other finding.

---

## Trufflehog Secret Scan Workflow

Scans the commits of a push or pull request for leaked secrets using
[Trufflehog OSS](https://github.com/trufflesecurity/trufflehog). The commit range is determined from the event, so
the workflow takes no inputs.

### Trufflehog Usage

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

### How Trufflehog Works

1. Resolves the commit range: the base and head of the pull request, or `before` and the pushed commit for a push.
   Falls back to `HEAD~1` when the base is missing, all zeros or not in the history, and skips the scan when no
   range can be determined, for example in a single-commit repository.
2. Runs Trufflehog over the resolved commit range.
3. Publishes a results table to the job summary.
4. Fails the job if Trufflehog detects any secrets.

---

## MS Teams Notification Action

A composite action that posts the result of a job as an Adaptive Card to an MS Teams channel. The workflows of this
repository use it for their notifications, and it can also be used directly as a step.

> [!IMPORTANT]
> The webhook has to be a Teams **Workflows** (Power Automate) webhook, created with the Workflows template
> "Send webhook alerts to a channel", shown as "Post to a channel when a webhook request is received" in some
> tenants. The retired Office 365 connector webhooks no longer work.

### Action Inputs

| Input | Description | Default | Required |
|---|---|---|---|
| `webhook-url` | MS Teams Workflows webhook URL | | Yes |
| `status` | Job status, usually `${{ job.status }}`. `success` green, `failure` red, else yellow | | Yes |
| `title` | Card title | `<workflow name>: <status>` | No |
| `facts` | Extra facts, one `Name=Value` per line, next to repository, branch, commit, actor and time | | No |

### Action Usage

```yaml
    - name: Notify MS Teams
      if: ${{ !cancelled() }}
      uses: steadforce/steadops-workflows/.github/actions/teams-notification@v4.1.0
      with:
        webhook-url: ${{ secrets.MS_TEAMS_WEBHOOK }}
        status: ${{ job.status }}
        facts: |
          Environment=production
```

Inside a reusable workflow, reference the action with its full path as shown above. A local
`./.github/actions/...` path resolves against the checkout of the calling repository.

---

## Developing These Workflows

The commands below run from the repository root and only need Docker.

### Linting

`lint-workflows.yaml` runs [actionlint](https://github.com/rhysd/actionlint) over every workflow on each pull
request and push to `main`. It checks the workflow syntax, the `${{ }}` expressions, the event and matrix
references and the `uses:` specifications, and runs shellcheck over every `run:` block. Reproduce it locally with
the same image:

```sh
 docker run \
   --rm \
   -u $(id -u) \
   -v "$(pwd):/apps" \
   -w /apps \
   rhysd/actionlint:1.7.12 -color
```

### Testing the Hydration Workflow

`test-helm-hydration.yaml` renders the fixture charts under `tests/fixtures` with the hydration workflow of this
repository and compares the result against the manifests in `tests/golden`. It calls the workflow through a
relative `uses:`, so a change is validated by the same run that proposes it, and it uses render-only mode so no
branches are created here.

After intentionally changing a fixture, the rendering logic or the pinned Helm version, regenerate the goldens and
review the diff. The goldens are only valid for the Helm version pinned in the script and the test workflow,
currently `v3.19.0`, so use the matching image:

```sh
 docker run \
   -e HOME=/tmp \
   --entrypoint bash \
   --rm \
   -u $(id -u) \
   -v "$(pwd):/apps" \
   -w /apps \
   alpine/helm:3.19.0 tests/regenerate-golden.sh
```

See [tests/README.md](tests/README.md) for what the fixtures cover.

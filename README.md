# SteadOps GitHub Workflows

Reusable GitHub Actions workflows and composite actions that the SteadOps repositories share for Helm GitOps
hydration, Helm chart testing, secret scanning, and MS Teams notifications.

## Overview

Workflows live in `.github/workflows/`, the actions in `.github/actions/`.

| Component | File | Purpose |
|---|---|---|
| [Helm hydration](#helm-hydration-workflow) | `helm-hydration.yaml` | Render charts, open one PR per environment |
| [Helm unittest](#helm-unittest-workflow) | `helm-unittest.yaml` | helm-unittest and `helm lint`, Teams on Renovate |
| [Gitleaks](#gitleaks-secret-scan-workflow) | `gitleaks.yaml` | Scan the full git history for secrets |
| [Trufflehog](#trufflehog-secret-scan-workflow) | `trufflehog-oss.yaml` | Scan pushed or PR commits for secrets |
| [Renovate hydration labeller](#renovate-hydration-labeller-workflow) | `label-renovate-hydration.yaml` | Label hydration PRs that carry only a Renovate update |
| [zizmor](#zizmor-github-actions-audit-workflow) | `zizmor.yaml` | Audit workflows and actions for security issues |
| [Helm dependencies](#helm-dependencies-action) | `helm-dependencies/action.yml` | Install chart dependencies |
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
| `upload-artifact` | Publish the manifests as one artifact, see [Hydration Artifact](#hydration-artifact) | `false` | No |

### Hydration Artifact

With `upload-artifact: true` the rendered manifests are published as one artifact holding a directory
`hydrated-<chart>-<environment>` per chart and environment. The artifact is named `hydrated-manifests`, followed by
`-<charts-root>` when `charts-root` is not the repository root, so a caller hydrating several roots in one run gets
one artifact per root.

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
| Workflow output | — | A warning naming the missing `Chart.lock` |

Either way the reported version is the one that was actually installed, so it is always a concrete semver and safe
inside a git branch name. A `Chart.lock` that is out of sync with `Chart.yaml` fails the run.

The dependencies are installed the same way as by the [Helm dependencies action](#helm-dependencies-action), which
also registers the chart's HTTP(S) repositories. The workflow does this inline rather than through the action,
because it installs the dependencies of every chart in one step, and registers a repository shared by several
charts only once.

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
  issues: write
```

`issues: write` is required. The workflow uses it to give the per-environment label a fixed colour, and labels
belong to the issues API even when they are only ever used on pull requests. The permissions of a reusable workflow
are capped by those of its caller, so a caller that does not grant `issues: write` makes GitHub refuse to start the
workflow. This also applies in render-only mode (`create-pull-request: false`), even though no label is created
then.

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

One `hydrate` job renders every chart and environment, and a `create-pull-request` job runs only for the pairs
whose manifests changed:

1. Searches `charts-root` for `helm-config.yaml` files and installs Helm once.
2. For each chart:
   1. Installs the chart dependencies, as described under [Chart.lock](#chartlock).
   2. Reads the chart name from `Chart.yaml` and the primary dependency version from `Chart.lock`, or the chart's
      own version when it has no dependencies. If `bundle-patches-in-one-pr` is `true`, the patch segment of the
      version is replaced with `x`.
3. For each of the chart's environments:
   1. Runs `helm template` with the environment's value files and API versions, `--include-crds` and
      `--skip-tests`.
   2. Adds the Argo CD annotations `sync-options: ServerSideApply=true` and `sync-wave: "-1"` to every
      CustomResourceDefinition. An existing `sync-options` value is extended, an existing `sync-wave` is kept.
      Only files that hold a CRD are rewritten by `yq`; every other manifest is committed exactly as Helm renders
      it, so a new `yq` release on the runner does not reformat it.

   A chart or environment that fails is reported and skipped. The others are still hydrated, and the job fails at
   the end.
4. Creates the `environments/<name>` branch on origin if it does not exist yet, as an orphan branch, and creates the
   `env: <name>` label if it does not exist yet.
5. Compares the rendered manifests of each chart and environment against the open pull request for it, or against
   the environment branch when there is none, and selects the pairs that changed.
6. Uploads the manifests as an artifact, if `upload-artifact` is `true`.
7. For each selected pair, a `create-pull-request` job replaces only that chart's output on the environment branch
   and opens or updates a pull request from `hydration-pull-request/<env>[-<chart>]-<version>` into
   `environments/<env>`, labelled `hydration`, `automated pr` and `env: <env>`. Its title and body say why it
   exists, see [Pull Request Titles](#pull-request-titles).

A push that changes no manifests therefore starts no pull-request job, and in a repository holding several charts a
change to one chart only opens pull requests for that chart. Every chart and environment is still rendered on every
run, because a change outside a chart's directory, or an upstream release for a chart without a committed
`Chart.lock`, can change its manifests too.

With `create-pull-request: false`, steps 4, 5 and 7 are skipped: no branch is created and no pull request is
opened, which makes the workflow usable as a validation step on pull requests.

### Pull Request Titles

Every hydration commit carries two trailers, `Hydrated-From: <commit>` (the commit it was rendered from) and
`Chart-Version: <version>` (the exact version, patch included). The next run reads them from the newest commit that
changed the chart's directory on the environment branch, and compares that with what it rendered:

| Cause | When | Title |
|---|---|---|
| Version | The chart version differs from the deployed one | `💧 [dev] loki 21.2.1 → 21.2.2` |
| Change | Same version, and commits changed the chart's directory or a `file://` dependency inside the repository | `💧 [dev] falco: <title of the newest pull request> (#1355) (+1 more)` |
| Re-render | Same version, and no commit changed the chart | `💧 [dev] falco: re-rendered without a chart change` |
| Unknown | The environment branch records no render of the chart yet | `💧 [dev] Hydrated manifests for falco 9.2.2` |

The body links the rendered and the deployed commit and lists every pull request, or directly pushed commit, that
changed the chart since the deployed render. A re-render is caused by the rendering itself, a new Helm or `yq`
version or a change to this workflow, and is labelled `rerender` as well, so such pull requests can be found and
merged together. The label is removed again as soon as the pull request is anything else, a chart change or a
version update, or unknown because nothing shows it is still a re-render.

The description is updated whenever the pull request's manifests are, and covers everything between the deployed
render and the latest one. A pull request that was opened by an earlier version of the workflow keeps its title
until then. Right after an upgrade the environment branches carry no trailers yet, so every chart's first pull
request is titled as unknown. The description never holds back a pull request: when it cannot be worked out, the
pull request is opened with the generic title and without trailers.

The pull-request jobs are named after the matrix values, starting with the environment and the chart, e.g.
`create-pull-request (dev, loki, …)`. Workflows that read the environment and chart from the job name keep working.

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
      steadops-helm-renovation-ms-teams-webhook: ${{ secrets.MS_TEAMS_WEBHOOK }}
      steadops-helm-renovation-ms-teams-error-webhook: ${{ secrets.MS_TEAMS_ERROR_WEBHOOK }}
```

The keys are the secret names of the reusable workflow. The values reference secrets of the calling repository,
here `MS_TEAMS_WEBHOOK` and `MS_TEAMS_ERROR_WEBHOOK`, which can have any name GitHub accepts: letters, digits and
underscores, so not the hyphenated names of the keys. A reference to a secret that does not exist evaluates to an
empty string, and the notification is then skipped without an error.

### How Unittest Works

All charts are tested by one job:

1. Finds every chart with a `tests/` directory.
2. Installs the requested Helm version and the helm-unittest plugin once.
3. For each chart:
   1. Installs the chart dependencies the same way as the [Helm dependencies action](#helm-dependencies-action):
      `helm dependency build` when a `Chart.lock` is committed, so the pinned subchart versions are tested,
      otherwise `helm dependency update` with a warning that the lock file should be committed.
   2. Runs `helm unittest` with JUnit output.
4. Publishes the JUnit results of all charts as one check run and job summary, also when the tests fail.
5. Runs `helm lint` for each chart.
6. On Renovate branches (branches starting with `renovate/`, for pull requests the source branch), posts one success
   or failure Adaptive Card for all charts with the [MS Teams notification action](#ms-teams-notification-action).
   Successes go to `steadops-helm-renovation-ms-teams-webhook`, failures to
   `steadops-helm-renovation-ms-teams-error-webhook`, falling back to the former when no error webhook was passed.

A chart whose dependencies, tests or lint fail does not stop the others. The job fails once every chart ran.

> [!TIP]
> A `Chart.lock` that is out of sync with `Chart.yaml` fails the tests of that chart. Run `helm dependency update`
> and commit the lock file together with `Chart.yaml`.

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

## Renovate Hydration Labeller Workflow

Labels the hydration pull requests that carry exactly one eligible Renovate chart update, or an unbroken run of
them, with `renovate-hydration`. The cluster gatekeepers of
[renovate-gatekeeper-deployment](https://github.com/steadforce/renovate-gatekeeper-deployment) merge only pull
requests with that label; the labeller itself never merges and never accesses a cluster.
[docs/renovate-rollout.md](docs/renovate-rollout.md) has the caller workflow, the Renovate rules and the rollout.

### Labeller Inputs

| Input | Description | Default | Required |
|---|---|---|---|
| `charts-root` | As passed to the hydration workflow | `.` | No |
| `chart-discovery-depth` | As passed to the hydration workflow | `1` | No |
| `bundle-patches-in-one-pr` | As passed to the hydration workflow | `true` | No |
| `helm-version` | As passed to the hydration workflow | `latest` | No |
| `yq-version` | yq to install; empty uses the runner's, as the hydration workflow does | `""` | No |
| `eligible-update-labels` | JSON array of Renovate update-type labels eligible for unattended rollout | `["update:patch","update:minor"]` | No |
| `layout` | `single-chart` or `multi-chart`; derived from the discovery, only checked when set | `""` | No |
| `sha` | Source commit; empty checks the latest commit of `source-branch` | `""` | No |
| `source-branch` | Branch the charts and the Renovate pull requests live on | `main` | No |
| `renovate-author` | Login of the Renovate bot | `renovate[bot]` | No |

### How the Labeller Works

1. Walks back over the last 20 commits of the source branch for merged Renovate pull requests that change only
   one discovered chart's `Chart.yaml` and `Chart.lock` and carry an eligible update label.
2. For the newest such update of each chart, finds the open hydration pull requests of the chart by their branch,
   `hydration-pull-request/<environment>[-<chart>]-<version>`. An older version's pull request is superseded and
   loses the label; a newer one is left alone.
3. Renders the chart with the hydration workflow's own invocation and post-processing, at the update and before it,
   and compares the renders with the pull request and its environment branch, ignoring only YAML formatting and
   key order. Walking back up to 100 commits, Renovate updates of the same chart (at most 10) and commits that leave
   its render for the environment unchanged extend the run; any other commit ends it. A commit that changes nothing
   the render reads, the chart, its `file://` dependencies recursively and its value files, is not rendered at all.
4. Labels a pull request that holds, with a comment recording the source commit, head and base; refuses one that
   does not, says why and hands it back from the gatekeepers. A render that fails three times, or no deployed state
   within 100 commits, leaves the pull request as it is until the next run.
5. Checks every other labelled pull request again against its recorded source, which records a moved base.

## zizmor GitHub Actions Audit Workflow

Audits the workflows and composite actions of the calling repository with [zizmor](https://docs.zizmor.sh) for
security issues: template injection in `run:` blocks, credentials persisted by `actions/checkout`, overly broad
permissions, dangerous triggers, unpinned action references and more. actionlint checks that a workflow is valid,
zizmor that it is safe.

### zizmor Inputs

| Input | Description | Default | Required |
|---|---|---|---|
| `min-severity` | Lowest severity reported: `informational`, `low`, `medium` or `high`. Empty reports all | `""` | No |
| `persona` | Auditing persona: `regular`, `pedantic` or `auditor` | `regular` | No |
| `online-audits` | Run the audits that query GitHub, see [Online Audits](#online-audits) | `false` | No |

### zizmor Secrets

| Secret | Description | Required |
|---|---|---|
| `token` | Token for the online audits. Defaults to the `GITHUB_TOKEN` | No |

### zizmor Usage

```yaml
name: GitHub Actions audit

on:
  pull_request:
  push:
    branches:
    - main

jobs:
  zizmor:
    uses: steadforce/steadops-workflows/.github/workflows/zizmor.yaml@main
```

### Online Audits

Some audits, such as `impostor-commit` and `known-vulnerable-actions`, query GitHub for every repository a `uses:`
names. When the token cannot read one of them, zizmor fails the whole run instead of skipping the reference. The
`GITHUB_TOKEN` only reads the repository it belongs to, so every reference to an internal repository, such as the
workflows of this one, fails the run. The online audits are therefore off by default; set `online-audits: true`
together with a `token` that can read every referenced repository, for example a GitHub App token, to run them.

### Configuring zizmor

zizmor reads `.github/zizmor.yml` from the calling repository. By default the `unpinned-uses` audit requires every
action and reusable workflow to be pinned to a commit hash. A repository that pins the workflows of this one to a
release tag allows that explicitly:

```yaml
rules:
  unpinned-uses:
    config:
      policies:
        steadforce/*: ref-pin
        "*": hash-pin
```

A single finding is suppressed where it occurs, with a comment stating why:

```yaml
on:
  workflow_run: # zizmor: ignore[dangerous-triggers] triggered by a push to main only
```

Reproduce the audit locally with the same image; add `-e GH_TOKEN="$(gh auth token)"` and drop
`--no-online-audits` for the online audits:

```sh
 docker run \
   --rm \
   -u $(id -u) \
   -e HOME=/tmp \
   -v "$(pwd):/repo:ro" \
   -w /repo \
   ghcr.io/zizmorcore/zizmor:1.32.0 --no-online-audits .
```

Some findings can be fixed with `--fix=safe`; mount the repository writable and review the diff.

### How zizmor Works

Checks out the repository without persisting the token and runs zizmor 1.32.0 over it. The job log lists every
finding with its audit, file, line and a link to the audit's documentation, and the job fails on any finding at or
above `min-severity`.

---

## Helm Dependencies Action

A composite action that installs the dependencies of a Helm chart into its `charts/` directory, used as a step
after Helm is installed. It needs `helm` and `yq` on the `PATH`, as on GitHub-hosted runners. The hydration and
Helm unittest workflows install the dependencies the same way, but inline, because they handle every chart in one
step. A change to the logic here has to be made there as well.

| | `Chart.lock` committed | No `Chart.lock` |
|---|---|---|
| Command | `helm dependency build` | `helm dependency update` |
| Installed versions | Exactly the pinned ones | Resolved from the ranges in `Chart.yaml` |
| Out of sync with `Chart.yaml` | Fails the step | — |
| Output | — | A warning that the lock file should be committed |

Before installing, the action runs `helm repo add --force-update` for every `http://` and `https://` repository
declared in `Chart.yaml`, because `helm dependency build` does not resolve repositories by URL on a fresh runner.
`oci://` and `file://` dependencies need no repository entry. A repository alias (`@name` or `alias:name`) is left
to Helm, so it must already be registered when the action runs. Used directly, an earlier `helm repo add` step in
the same job does that. The workflows of this repository have no such step, so there only a self-hosted runner
with the repository registered can resolve an alias.

> [!NOTE]
> The action is first released with `v4.2.0`. Earlier tags do not contain it.

### Dependencies Action Inputs

| Input | Description | Default | Required |
|---|---|---|---|
| `chart-dir` | Directory holding the chart's `Chart.yaml` | | Yes |

### Dependencies Action Usage

```yaml
    - name: Set up Helm
      uses: azure/setup-helm@v5.0.1
    - name: Build Helm dependencies
      uses: steadforce/steadops-workflows/.github/actions/helm-dependencies@v4.2.0
      with:
        chart-dir: .
```

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
      uses: steadforce/steadops-workflows/.github/actions/teams-notification@v4.2.0
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
relative `uses:`, so a change to the workflow is validated by the same run that proposes it, and it uses
render-only mode so no branches are created here. The actions the workflow calls are the released ones, see
[Releasing](#releasing).

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

### Testing the Helm Dependencies Action

`test-helm-dependencies.yaml` runs the action through `uses: ./.github/actions/helm-dependencies`, which resolves
to the version on the pull request. It installs the fixture with a committed `Chart.lock`, the one without, and
expects a copy whose `Chart.lock` is out of sync with `Chart.yaml` to fail.

### Releasing

The workflows reference the actions of this repository by their full path at a release tag, because a local
`./.github/actions/...` path would resolve against the checkout of the calling repository. A change to an action
therefore reaches callers only after:

1. The workflows reference the next release tag, for example `helm-dependencies@v4.2.0`.
2. The merge commit on `main` is tagged with that version.

Until the tag exists, the jobs that call the action fail to resolve it, for example the hydration tests on the pull
request. Re-run them after tagging.

`release.yaml` creates the tag: run it on `main` with the new version. It runs the labeller tests and the hydration
golden tests first and refuses to overwrite an existing tag.

### Testing the Renovate Hydration Labeller

`validate-renovate-rollout.yaml` runs `tests/labeller_test.sh` and `tests/hydration_test.sh`. The first renders the
fixtures with the labeller and compares them byte for byte with `tests/golden`, so the labeller cannot drift from
the hydration workflow. The second runs the labeller end to end against a hydrated git repository and a fake GitHub
API. Both need Helm 3.19.0, the version the goldens were rendered with.

# Renovate Hydration Labelling

The reusable workflow verifies that an environment PR contains only an eligible
Renovate chart update, using before/after renders. It adds `renovate-hydration`
and a trusted comment containing the source, head and base SHAs; stale eligibility
is removed. It never merges or accesses a cluster.

Merging, health checks and soak periods belong to
[renovate-gatekeeper-deployment](https://github.com/steadforce/renovate-gatekeeper-deployment).

## Prerequisites

- Hydration creates one environment PR per chart within the same repository.
- Charts have committed dependency locks and `helm-config.yaml` with `releaseName`,
  `namespace` and per-environment `valueFiles`/`apis`; paths are relative to the chart.
- Renders are deterministic, with matching Helm/yq versions in hydration and verification.
- Required CI checks are enforced before unattended merges are enabled.

## Renovate Labels

Keep the repo's existing Renovate policy. Append these metadata-only rules to its
`packageRules` array if equivalent labels are not already configured:

```json
{
  "packageRules": [
    {"matchUpdateTypes": ["patch"], "addLabels": ["update:patch"]},
    {"matchUpdateTypes": ["minor"], "addLabels": ["update:minor"]},
    {"matchUpdateTypes": ["major"], "addLabels": ["update:major"]}
  ]
}
```

Only trusted Renovate-authored PRs changing one chart's `Chart.yaml`/`Chart.lock`
qualify. Missing eligible labels, `update:major`, and mixed changes stay manual.
Rollout eligibility is independent of Renovate's source-PR automerge policy.

## Caller Workflow

Add this wrapper to the consumer's default branch. Replace both `<release-ref>`
occurrences with the same trusted release tag or commit SHA, and match the hydration
workflow's name and tool versions. This example uses Falco's root-source,
multi-chart-output layout and patch-only rollout.

```yaml
name: Label Renovate hydration
on:
  workflow_run:
    workflows: [Helm hydration]
    types: [completed]
    branches: [main]
  push:
    branches: ['environments/**']
  pull_request:
    branches: ['environments/**']
    types: [synchronize, reopened, edited]
  workflow_dispatch:
permissions:
  contents: read
  pull-requests: write
  issues: write
jobs:
  label:
    if: >-
      github.event_name != 'workflow_run' ||
      (github.event.workflow_run.conclusion == 'success' &&
       github.event.workflow_run.head_repository.full_name == github.repository)
    uses: steadforce/steadops-workflows/.github/workflows/label-renovate-hydration.yaml@<release-ref>
    with:
      workflows-ref: <release-ref>
      sha: ${{ github.event_name == 'workflow_run' && github.event.workflow_run.head_sha || '' }}
      helm-version: v3.19.0
      yq-version: v4.49.2
      charts-root: .
      layout: multi-chart
      eligible-update-labels: '["update:patch"]'
```

Successful hydration runs pass their source SHA. Environment pushes and hydration
PR updates omit it, so the reusable workflow checks the latest source-branch commit
and revalidates open PRs against the new base/head. No polling runner is needed.
For private shared-repo access, pass the optional `workflows-read-token` secret
with read-only access.

## Key Inputs

| Input | Default / purpose |
| --- | --- |
| `sha` | Optional full source commit SHA; defaults to the latest `source-branch` commit |
| `workflows-ref` | Required; same trusted ref as the workflow call, selects its script |
| `charts-root` | `infrastructure`; use `.` for a root source chart |
| `layout` | `multi-chart` for `hydrated-manifests/<chart>/<release>/<chart>/...`; `root-chart` for legacy flat output |
| `eligible-update-labels` | JSON array, default `["update:patch","update:minor"]` |
| `source-branch` / `environment-branch-prefix` | `main` / `environments/` |
| `manifest-root` / `renovate-author` | `hydrated-manifests` / `renovate[bot]` |

Source location and output layout are independent: Falco uses `charts-root: .`
with `layout: multi-chart`. Tool inputs default to Helm `v3.19.0` and yq `v4.49.2`;
match the producer, rather than relying on its `latest` defaults.
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

Add this wrapper to the consumer's default branch. Replace `<release-sha>` with the
resolved commit and `<release-version>` with its release tag or development branch.
Keep the version comment so Renovate can track the reference, and match the hydration
workflow's name and tool versions. This example uses a root source chart,
the single-chart output of the v4.2.0/v4.3.0 producer, and patch-only rollout.

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
  actions: read
  contents: read
  pull-requests: write
  issues: write
jobs:
  label:
    if: >-
      github.event_name != 'workflow_run' ||
      (github.event.workflow_run.conclusion == 'success' &&
       github.event.workflow_run.head_repository.full_name == github.repository)
    uses: steadforce/steadops-workflows/.github/workflows/label-renovate-hydration.yaml@<release-sha> # <release-version>
    with:
      sha: ${{ github.event_name == 'workflow_run' && github.event.workflow_run.head_sha || '' }}
      helm-version: v3.19.0
      yq-version: v4.49.2
      charts-root: .
      layout: single-chart
      eligible-update-labels: '["update:patch"]'
```

Successful hydration runs pass their source SHA. Environment pushes and hydration
PR updates omit it, so the reusable workflow checks the latest source-branch commit
and revalidates open PRs against the new base/head when those events can run the
caller. The producer's manifest-only orphan environment branches do not contain
workflow files: push and pull-request handlers on those refs alone cannot guarantee
revalidation. A trusted default-branch dispatch integration or manual dispatch is
needed for later head/base changes until that event-routing gap is addressed.
For private shared-repo access, pass the optional `workflows-read-token` secret
with read-only access.

## Key Inputs

| Input | Default / purpose |
| --- | --- |
| `sha` | Optional full source commit SHA; defaults to the latest `source-branch` commit |
| `workflows-ref` | Deprecated compatibility input, ignored; do not set it in new callers |
| `charts-root` | `infrastructure`; use `.` for a root source chart |
| `layout` | `single-chart` for `hydrated-manifests/<release>/<chart>/...`; `multi-chart` for `hydrated-manifests/<chart>/<release>/<chart>/...`; `root-chart` for legacy flat output |
| `eligible-update-labels` | JSON array, default `["update:patch","update:minor"]` |
| `source-branch` / `environment-branch-prefix` | `main` / `environments/` |
| `manifest-root` / `renovate-author` | `hydrated-manifests` / `renovate[bot]` |

Source location and output layout are independent. With one discovered root
`helm-config.yaml`, the pinned v4.2.0/v4.3.0 producers use `charts-root: .` and
`layout: single-chart`, including Falco and cert-manager. Dependency CRDs can also
appear outside the release directory; verification includes those files rather
than comparing only templates. A producer discovering several charts uses
`layout: multi-chart`. `root-chart` is only for the older flat manifest layout,
not an alternative name for a root source chart. Tool inputs default to Helm
`v3.19.0` and yq `v4.49.2`; match the producer rather than its `latest` defaults.

## Automated Updates And Releases

There is one dependency reference: the caller's `uses:` line. The shared workflow
uses the run API's `referenced_workflows` metadata to check out scripts at the
exact resolved workflow commit, independent of later branch/tag movement. This
requires the caller to grant `actions: read`. Missing or ambiguous metadata fails
closed instead of choosing another revision. Reusing the labeller at different
revisions within one run is not supported.

Append this scoped rule to the consumer's existing Renovate `packageRules`:

```json
{
  "description": "Maintain the shared hydration labeller with native GitHub Actions updates",
  "matchManagers": ["github-actions"],
  "matchPackageNames": ["steadforce/steadops-workflows"],
  "matchFileNames": [".github/workflows/label-renovate-hydration.yaml"],
  "pinDigests": true
}
```

For development, a SHA followed by `# add-label-renovate-hydration-workflow` lets
Renovate propose digest updates as that branch advances. For production, use a
published tag comment such as `# v4.4.0`; Renovate then proposes release updates
with the matching digest. A bare SHA without the comment is not updatable. The
rule does not change existing automerge policy, and no second input or regex
manager needs updating.

After merging the shared changes to `main`, run `Release shared workflows` on
`main` with a new version such as `v4.4.0`. It runs the labeller tests and the
producer's golden-manifest checks before creating the tag and generated release
notes. Existing tags cannot be overwritten. No release is published just by
merging a consumer PR. Move the initial development-branch comment to the first
real release tag once that release exists; subsequent updates are handled by
Renovate. Enable the consumer PRs on their default branches for Renovate to see
this configuration. No GitHub App credentials or workflow-access settings are
changed by this automation.
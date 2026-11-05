# Steadforce SteadOps GitHub workflows
This repository provides GitHub reusable workflows to share between repositories.

Reusable GitHub Actions workflows and composite actions for Helm GitOps hydration,
chart testing, secret scanning, and MS Teams notifications. Workflows live in
`.github/workflows/`; actions live in `.github/actions/`.

## Overview

| Component | File | Purpose |
|---|---|---|
| Helm hydration | `helm-hydration.yaml` | Render charts and open environment PRs |
| Helm unittest | `helm-unittest.yaml` | Run `helm-unittest` and `helm lint` |
| Renovate hydration labeller | `label-renovate-hydration.yaml` | Verify rendered Renovate PRs; never merges |
| Gitleaks | `gitleaks.yaml` | Scan git history for secrets |
| Trufflehog | `trufflehog-oss.yaml` | Scan pushed and PR commits for secrets |
| Helm dependencies | `helm-dependencies/action.yml` | Install chart dependencies |
| Teams notification | `teams-notification/action.yml` | Post job results to Teams |

Reusable workflows are called from consumer workflows using `uses:`. They run only
on `workflow_call`; the calling repository chooses the trigger and permissions.
For example:

```yaml
jobs:
  unittest:
    uses: steadforce/steadops-workflows/.github/workflows/helm-unittest.yaml@main
```

## Renovate rollout

The [reusable Renovate labelling workflow](docs/renovate-rollout.md) verifies
rendered-manifest PRs alongside repositories' existing Renovate setups. This repo
owns only the workflow, its verification script and tests. The cluster-local merge
and soak implementation, Helm chart and deployment settings live in
[renovate-gatekeeper-deployment](https://github.com/steadforce/renovate-gatekeeper-deployment).

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

jobs:
  hydration:
    uses: steadforce/steadops-workflows/.github/workflows/helm-hydration.yaml@main
```

## Helm unittest workflow
The helm unittest workflow bundles helm unittest and helm linting.

### Required Secret
- `steadops-helm-renovation-ms-teams-webhook`: MS Teams webhook URL used for notifications. **Required.**

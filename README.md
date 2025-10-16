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
Use this workflow when you want to automate the rendering of Helm charts as part of your GitOps pipeline, especially if you need to validate or modify manifests before deployment.

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

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

**Required repository layout:**

The calling repository must contain a `helm-config.yaml` file with the following structure:
```yaml
releaseName: my-chart       # required
namespace: my-namespace     # required
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

**Required permissions:**
```yaml
permissions:
  contents: write
  pull-requests: write
```

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

**How it works:**
1. Reads the environment keys from `helm-config.yaml` and builds a parallel job matrix — one job per environment.
2. Reads the primary subchart version from `Chart.yaml` (resolves YAML anchors). If `bundle-patches-in-one-pr` is `true`, the patch segment is replaced with `x`.
3. For each environment: installs Helm, resolves chart dependencies, runs `helm template` with the environment-specific value files and API groups, and post-processes CRD manifests to inject ArgoCD `ServerSideApply=true` and sync-wave `-1` annotations.
4. Ensures the target `environments/<name>` branch exists on origin (creates an orphan branch if not).
5. Opens or updates a pull request from `hydration-pull-request/<env>-<version>` into `environments/<env>`.

---

## Helm unittest workflow
The helm unittest workflow bundles helm unittest and helm linting.

**Inputs:**

| Input | Description | Default | Required |
|---|---|---|---|
| `helm-version` | Helm CLI version to install, e.g. `v3.19.0` | `latest` | No |
| `helm-unittest-version` | Helm unittest plugin version, e.g. `1.0.3` | `main` (latest) | No |

**Required Secrets:**

| Secret | Description | Required |
|---|---|---|
| `steadops-helm-renovation-ms-teams-webhook` | MS Teams webhook URL used for notifications on Renovate branches | **Yes** |

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
1. Installs the requested Helm version and the `helm-unittest` plugin.
2. Runs `helm dependency update` to resolve chart dependencies.
3. Runs `helm unittest` and publishes the JUnit test results to the GitHub Actions summary.
4. Runs `helm lint` to validate the chart.
5. On Renovate branches (refs containing `renovate/`), sends a success or failure notification to MS Teams.

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

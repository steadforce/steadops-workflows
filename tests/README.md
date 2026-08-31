# Workflow tests

## Helm hydration

`.github/workflows/test-helm-hydration.yaml` renders the fixture charts with the
hydration workflow of this repository and compares the result against the
manifests in `golden/`.

The test calls the hydration workflow through
`uses: ./.github/workflows/helm-hydration.yaml`, which resolves to the version on
the pull request. A change to the workflow is therefore validated by the same run
that proposes it.

### Layout

| Path | Purpose |
|---|---|
| `fixtures/upstream/` | Stub charts the fixtures depend on via `file://`, so the tests need no chart repository |
| `fixtures/single-chart/` | One chart at the root of a `charts-root`, the one-chart-per-repository layout |
| `fixtures/monorepo/` | Three charts below a shared root |
| `golden/hydrated-<chart>-<environment>/` | Expected manifests, one directory per artifact the workflow publishes |

### What the fixtures cover

- Anchors and aliases in `helm-config.yaml`, including environments defined once
  and reused.
- An environment declaring `apis` and one that does not, which renders a
  capability-gated `ServiceMonitor` in the first case only.
- `primaryDependency`, for umbrella charts whose upstream chart is named
  differently from the chart itself.
- A CRD without ArgoCD annotations, and a CRD that already carries
  `sync-options`, which are the two paths through the annotation post-processing.
- Templates owned by the umbrella chart next to the templates of the upstream
  chart.
- A chart that does not commit `Chart.lock` and pins its dependency with a
  version range (`monorepo/service-c`), which is the layout of a repository that
  git-ignores the lock file. Its lock is git-ignored so the fixture keeps that
  shape.

### Updating the goldens

```bash
tests/regenerate-golden.sh
```

Review the diff before committing it. Helm renders trailing whitespace
differently between releases, so the goldens are only valid for the Helm version
pinned in both the script and the test workflow.

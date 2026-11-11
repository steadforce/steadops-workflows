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
Keep the version comment so Renovate can track the reference. Pass `charts-root`,
`chart-discovery-depth`, `bundle-patches-in-one-pr` and `helm-version` exactly as
the hydration call does: they decide which charts exist, where their manifests live
on the environment branches, how the pull request branches are named and how the
charts render. This example is a repository with one chart at its root, hydrated
with Helm `v3.19.0`, and patch-only rollout.

```yaml
name: Label Renovate hydration
on:
  workflow_run:
    workflows: [Helm hydration]
    types: [completed]
    branches: [main]
  schedule:
  - cron: '*/30 * * * *'
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
      charts-root: .
      chart-discovery-depth: 1
      helm-version: v3.19.0
      eligible-update-labels: '["update:patch"]'
```

Successful hydration runs pass their source SHA; the schedule and manual dispatch
leave `sha` empty, so the shared workflow checks the latest source-branch commit.
The schedule is not optional. The gatekeepers merge a pull request only while its
head and base match the labeller's comment, and the environment branches carry no
workflows, so nothing else notices when merging one chart's pull request moves the
base of all the others. Each scheduled run checks the labelled pull requests again
and records the new base. For private shared-repo access, pass the optional
`workflows-read-token` secret with read-only access.

A monorepo passes its own discovery, for example `charts-root: .` and
`chart-discovery-depth: 3` for charts in `infrastructure/<name>` and `apps/<name>`.
Only charts the hydration discovers are eligible, so a chart under `charts/` that
other charts consume via `file://` is not.

## Key Inputs

| Input | Default / purpose |
| --- | --- |
| `sha` | Optional full source commit SHA; defaults to the latest `source-branch` commit |
| `charts-root` / `chart-discovery-depth` | `.` / `1`, as passed to the hydration workflow |
| `bundle-patches-in-one-pr` / `helm-version` | `true` / `latest`, as passed to the hydration workflow |
| `yq-version` | Empty uses the runner's yq, as the hydration workflow does |
| `eligible-update-labels` | JSON array, default `["update:patch","update:minor"]` |
| `layout` | Optional `single-chart` or `multi-chart`; derived, and only checked when set |
| `source-branch` / `renovate-author` | `main` / `renovate[bot]` |

The layout follows from the discovery like the hydration workflow's: one chart owns
all of `hydrated-manifests/` and its branches are
`hydration-pull-request/<environment>-<version>`; several charts each own
`hydrated-manifests/<chart>/` and carry the chart name in the branch. The labeller
renders with the hydration workflow's own `helm template` invocation and CRD
post-processing, so the comparison covers every file the hydration writes,
dependency CRDs outside the release directory included, and ignores only YAML
formatting and key order. `tests/labeller_test.sh` holds the labeller to the
hydration goldens byte for byte.

## What Is Verified

- The source is a merged pull request by `renovate-author` with an eligible update
  label and no `update:major`. Both its complete PR file list and its integrated
  commit delta must change only one discovered chart's `Chart.yaml` and `Chart.lock`;
  potentially truncated API file lists are rejected.
- Complete Git diffs and the actual three-way merge change nothing outside the
  chart's manifest directory. The merge result equals the source render; conflicts
  are refused.
- The environment branch equals the chart rendered just before the update, or
  before an unbroken run of updates ending in it. A commit in between that is an
  eligible Renovate update of the same chart, or leaves the chart's render for the
  environment unchanged, continues the run. Every first-parent commit is examined,
  up to 100 back; the run may hold at most 10 updates, and render-neutral commits
  do not count toward that. Earlier rebased commits of the same merged PR are
  checked against the complete PR, so the boundary can precede its first commit.
- A commit is render-neutral without rendering when nothing a render reads changed:
  the chart directory, its `file://` dependencies recursively and its value files.
  Commits elsewhere in a monorepo therefore cost a few `git rev-parse` calls, not a
  Helm run. A chart whose inputs reach outside the repository, or a commit with a
  symlink on or below one of them, is rendered at every commit instead: a symlink's
  blob does not change when its target does.
- A chart with an absolute `file://` dependency, directly or through another
  dependency, is refused: a render at an older commit would read today's content of
  that path, so no history of it can be checked.
- The manifests of the merge result and of the environment branch hold only regular
  files with plain names. A symlink, a submodule or a name with a control character
  refuses the pull request, label and all: it is what the pull request brought in, not
  a passing failure. File names are compared JSON-encoded, so no name can fake the
  boundary to another file.
- An open pull request for an older version of the chart is superseded: it loses the
  label, its gatekeeper comments say so and `gatekeeper-blocked` is removed.

A render that fails three times in a row, typically a chart repository timing out,
leaves the pull request as it is until the next run instead of refusing it. So does
a deployed state further back than 100 commits: running out of history is no
evidence against the pull request. More than 10 undeployed updates in a row are
refused, to be merged by hand.

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
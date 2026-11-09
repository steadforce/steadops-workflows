#!/usr/bin/env bash
# Unit tests of the labeller's helpers, its render against the hydration goldens, the workflow revision lookup and the release preflight.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
temporary="$(mktemp -d "$root/.rollout-test.XXXXXX")"
trap 'rm -rf "$temporary"' EXIT
export GITHUB_REPOSITORY=example/platform
source "$root/scripts/label-renovate-hydration.sh"
work="$temporary/work"
mkdir -p "$work"

# Discovery mirrors `find charts-root -maxdepth depth -name helm-config.yaml` of helm-hydration.yaml.
mkdir -p "$temporary/discovery" && cd "$temporary/discovery"
git init --quiet -b main
mkdir -p infrastructure/demo infrastructure/other/nested apps/web
touch helm-config.yaml infrastructure/demo/helm-config.yaml infrastructure/other/nested/helm-config.yaml apps/web/helm-config.yaml
git add . && git -c user.name=test -c user.email=test@example.invalid commit --quiet -m discovery
CHARTS_ROOT=. DISCOVERY_DEPTH=1
[[ "$(charts_at HEAD)" == . ]]
if multi_chart_at HEAD; then exit 1; fi
CHARTS_ROOT=. DISCOVERY_DEPTH=3
[[ "$(charts_at HEAD | sort | paste -sd' ')" == ". apps/web infrastructure/demo" ]]
multi_chart_at HEAD
CHARTS_ROOT=./infrastructure/ DISCOVERY_DEPTH=2
[[ "$(charts_at HEAD)" == infrastructure/demo ]]
CHARTS_ROOT=infrastructure DISCOVERY_DEPTH=3
[[ "$(charts_at HEAD | sort | paste -sd' ')" == "infrastructure/demo infrastructure/other/nested" ]]
echo 'Discovery matches helm-hydration.yaml for root, nested and multi-chart layouts'

# Eligibility: the Renovate author, an eligible update label, no major, one discovered chart's Chart.yaml and Chart.lock only.
CHARTS_ROOT=. DISCOVERY_DEPTH=3
candidate='{"number":1,"user":{"login":"renovate[bot]"},"labels":[{"name":"renovate"},{"name":"update:minor"}]}'
pull_files() { printf '%s\n' infrastructure/demo/Chart.yaml infrastructure/demo/Chart.lock; }
[[ "$(renovate_chart_dir "$candidate" HEAD)" == infrastructure/demo ]]
[[ "$(renovate_chart_dir "$(jq '.labels |= map(select(.name != "renovate"))' <<< "$candidate")" HEAD)" == infrastructure/demo ]]
ELIGIBLE_UPDATE_LABELS='["update:patch"]'
if renovate_chart_dir "$candidate" HEAD 2> /dev/null; then exit 1; fi
[[ "$(renovate_chart_dir "$(jq '.labels = [{name:"update:patch"}]' <<< "$candidate")" HEAD)" == infrastructure/demo ]]
ELIGIBLE_UPDATE_LABELS='["update:patch","update:minor"]'
if renovate_chart_dir "$(jq '.user.login = "someone"' <<< "$candidate")" HEAD 2> /dev/null; then exit 1; fi
if renovate_chart_dir "$(jq '.labels += [{name:"update:major"}]' <<< "$candidate")" HEAD 2> /dev/null; then exit 1; fi
if renovate_chart_dir "$(jq '.labels = []' <<< "$candidate")" HEAD 2> /dev/null; then exit 1; fi
pull_files() { printf '%s\n' infrastructure/demo/Chart.yaml infrastructure/other/Chart.lock; }
if renovate_chart_dir "$candidate" HEAD 2> /dev/null; then exit 1; fi
pull_files() { printf '%s\n' infrastructure/demo/Chart.yaml infrastructure/demo/values.yaml; }
if renovate_chart_dir "$candidate" HEAD 2> /dev/null; then exit 1; fi
pull_files() { printf '%s\n' charts/shared/Chart.yaml; }
[[ "$(renovate_chart_dir "$candidate" HEAD 2>&1 >/dev/null)" == *'is not a chart the hydration discovers'* ]]
pull_files() { printf '%s\n' Chart.yaml Chart.lock; }
[[ "$(renovate_chart_dir "$candidate" HEAD)" == . ]]
echo 'Eligibility checks the author, the update labels and the changed files'

# What a commit has to touch to change a chart's render: the chart, its file:// dependencies and value files outside it.
cat > infrastructure/demo/Chart.yaml <<'EOF'
apiVersion: v2
name: demo
version: 1.0.0
dependencies:
- name: shared
  version: 1.0.0
  repository: file://../../charts/shared
- name: upstream
  version: 2.0.0
  repository: https://charts.example.invalid
EOF
printf 'environments:\n  dev: &environment\n    valueFiles: [values.yaml, ../common.yaml]\n  prod: *environment\n' > infrastructure/demo/helm-config.yaml
git add . && git -c user.name=test -c user.email=test@example.invalid commit --quiet -m paths
[[ "$(chain_paths HEAD infrastructure/demo | paste -sd' ')" == "charts/shared infrastructure/common.yaml infrastructure/demo infrastructure/demo/values.yaml" ]]
echo 'The chain follows the chart, its file:// dependencies and its value files'

# Canonical comparison ignores key order and formatting, not content.
mkdir -p "$temporary/first" "$temporary/second"
printf 'kind: ConfigMap\napiVersion: v1\nmetadata: {name: demo}\ndata: {version: old}\n' > "$temporary/first/config.yaml"
printf 'apiVersion: v1\nkind: ConfigMap\ndata: {version: old}\nmetadata: {name: demo}\n' > "$temporary/second/config.yaml"
[[ "$(canonical "$temporary/first")" == "$(canonical "$temporary/second")" ]]
printf 'apiVersion: v1\nkind: ConfigMap\nmetadata: {name: demo}\ndata: {version: new}\n' > "$temporary/second/config.yaml"
[[ "$(canonical "$temporary/first")" != "$(canonical "$temporary/second")" ]]
canonical "$temporary/first" > "$temporary/first.canonical"
canonical "$temporary/second" > "$temporary/second.canonical"
[[ "$(differing_files "$temporary/first.canonical" "$temporary/second.canonical")" == '`config.yaml`' ]]
[[ -z "$(canonical "$temporary/nonexistent")" ]]
printf 'not: [valid\n' > "$temporary/second/config.yaml"
if canonical "$temporary/second" > /dev/null 2>&1; then exit 1; fi
echo 'Canonical comparison ignores formatting and names the files that differ'

# The labeller renders byte for byte what helm-hydration.yaml hydrates, checked against the goldens of test-helm-hydration.yaml.
cd "$temporary"
mkdir -p golden-check/tests
cp -r "$root/tests/fixtures" golden-check/tests/
cd golden-check
for spec in tests/fixtures/single-chart:1 tests/fixtures/monorepo:2; do
    while IFS= read -r config; do
        chart_dir="$(dirname "$config")"
        chart="$(yq 'explode(.) | .name' "$chart_dir/Chart.yaml")"
        while IFS= read -r environment; do
            render_tree "$chart_dir" "$environment" "$temporary/rendered/hydrated-$chart-$environment"
        done < <(yq -r 'explode(.) | .environments | keys | .[]' "$config")
    done < <(find "${spec%:*}" -maxdepth "${spec#*:}" -name helm-config.yaml | sort)
done
diff -r "$root/tests/golden" "$temporary/rendered"
echo 'The labeller renders the hydration goldens byte for byte'

# The branch version, as helm-hydration.yaml names the pull request branch.
mkdir -p "$work/tree-abc"
cp -r "$temporary/golden-check/tests" "$work/tree-abc/"
BUNDLE_PATCHES=true
[[ "$(branch_version abc tests/fixtures/monorepo/service-a)" == 2.1.x ]]
[[ "$(branch_version abc tests/fixtures/single-chart)" == 1.4.x ]]
BUNDLE_PATCHES=false
[[ "$(branch_version abc tests/fixtures/single-chart)" == 1.4.2 ]]
echo 'The branch version follows primaryDependency, Chart.lock and bundle-patches-in-one-pr'

check_workflow_revision() (
    local metadata="$1" expected="$2"
    export GITHUB_RUN_ID=123
    export GITHUB_OUTPUT="$temporary/workflow-output"
    export WORKFLOW_PATH=steadforce/steadops-workflows/.github/workflows/label-renovate-hydration.yaml
    : > "$GITHUB_OUTPUT"
    gh() {
        [[ "$*" == 'api repos/example/platform/actions/runs/123' ]] || return 1
        printf '%s\n' "$metadata"
    }
    source <(yq -r '.jobs.label.steps[] | select(.id == "workflow") | .run' "$root/.github/workflows/label-renovate-hydration.yaml")
    [[ "$(< "$GITHUB_OUTPUT")" == "sha=$expected" ]]
)
workflow_sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
workflow_metadata="$(jq -cn --arg sha "$workflow_sha" '{referenced_workflows:[
    {path:"steadforce/steadops-workflows/.github/workflows/helm-hydration.yaml@v4.3.0",sha:"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"},
    {path:"steadforce/steadops-workflows/.github/workflows/label-renovate-hydration.yaml@v4.4.0",sha:$sha}
]}')"
check_workflow_revision "$workflow_metadata" "$workflow_sha"
if check_workflow_revision '{"referenced_workflows":[]}' "$workflow_sha" 2>/dev/null; then exit 1; fi
if check_workflow_revision "$(jq '.referenced_workflows[1].sha = "not-a-sha"' <<< "$workflow_metadata")" "$workflow_sha" 2>/dev/null; then exit 1; fi
if check_workflow_revision "$(jq '.referenced_workflows += [.referenced_workflows[1] | .sha = "cccccccccccccccccccccccccccccccccccccccc"]' <<< "$workflow_metadata")" "$workflow_sha" 2>/dev/null; then exit 1; fi
echo 'Reusable workflow revision resolves uniquely and fails closed on missing, invalid or ambiguous metadata'

check_release_preflight() (
    export RELEASE_BRANCH="$1" RELEASE_VERSION="$2"
    local existing_tag="${3:-}"
    gh() { printf '%s\n' "$existing_tag"; }
    source <(yq -r '.jobs.preflight.steps[] | .run' "$root/.github/workflows/release.yaml")
)
check_release_preflight refs/heads/main v4.4.0
if check_release_preflight refs/heads/feature v4.4.0 2>/dev/null; then exit 1; fi
if check_release_preflight refs/heads/main invalid 2>/dev/null; then exit 1; fi
if check_release_preflight refs/heads/main v4.4.0 refs/tags/v4.4.0 2>/dev/null; then exit 1; fi
echo 'Release preflight rejects feature branches, invalid versions and existing tags'

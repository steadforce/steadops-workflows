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

(
    api_list() { printf '%s\n' '[{"filename":"hydrated-manifests/demo/config.yaml","previous_filename":"hydrated-manifests/other/config.yaml"},{"filename":"hydrated-manifests/demo/values.yaml"}]'; }
    [[ "$(pull_files 1)" == $'hydrated-manifests/demo/config.yaml\nhydrated-manifests/demo/values.yaml\nhydrated-manifests/other/config.yaml' ]]
    api_list() { jq -n '[range(3000) | {filename: "Chart.yaml"}]'; }
    if pull_files 1 > /dev/null 2>&1; then exit 1; fi
)
echo 'Renamed files include both source and destination paths in scope checks'

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

printf '{"kind":"ConfigMap","apiVersion":"v1","metadata":{"name":"extra"}}\n' > "$temporary/first/extra.json"
canonical "$temporary/first" > "$temporary/json-before.canonical"
grep -q '^== extra.json$' "$temporary/json-before.canonical"
printf '{"kind":"ConfigMap","apiVersion":"v1","metadata":{"name":"changed"}}\n' > "$temporary/first/extra.json"
canonical "$temporary/first" > "$temporary/json-after.canonical"
if cmp -s "$temporary/json-before.canonical" "$temporary/json-after.canonical"; then exit 1; fi
printf 'extra.yaml export-ignore\n' > "$temporary/first/.gitattributes"
printf 'unverified content\n' > "$temporary/first/resource.txt"
canonical "$temporary/first" > "$temporary/all-files.canonical"
grep -q '^== .gitattributes$' "$temporary/all-files.canonical"
grep -q '^== resource.txt$' "$temporary/all-files.canonical"
echo 'Canonical comparison includes JSON, attributes and unsupported file extensions'

(
    mkdir -p "$temporary/cache-check" && cd "$temporary/cache-check"
    git init --quiet -b main
    for chart_dir in apps/api apps-api; do
        mkdir -p "$chart_dir"
        printf 'environments:\n  dev: {}\n' > "$chart_dir/helm-config.yaml"
    done
    mkdir -p hydrated-manifests/apps/api hydrated-manifests/apps-api
    printf 'apiVersion: v1\nkind: ConfigMap\nmetadata: {name: hidden}\n' > hydrated-manifests/apps/api/hidden.yaml
    printf 'hidden.yaml export-ignore\n' > hydrated-manifests/apps/api/.gitattributes
    printf 'apiVersion: v1\nkind: ConfigMap\nmetadata: {name: other}\n' > hydrated-manifests/apps-api/other.yaml
    git add . && git -c user.name=test -c user.email=test@example.invalid commit --quiet -m caches
    render_tree() {
        mkdir -p "$3"
        printf 'apiVersion: v1\nkind: ConfigMap\ndata: {chart: "%s"}\n' "$1" > "$3/config.yaml"
    }
    nested="$(rendered HEAD dev apps/api)"
    flat="$(rendered HEAD dev apps-api)"
    [[ "$nested" != "$flat" ]]
    if cmp -s "$nested" "$flat"; then exit 1; fi
    [[ "$(cache_key dev apps/api)" != "$(cache_key dev-apps api)" ]]
    nested="$(hydrated HEAD hydrated-manifests/apps/api)"
    flat="$(hydrated HEAD hydrated-manifests/apps-api)"
    [[ "$nested" != "$flat" ]]
    grep -q '^== hidden.yaml$' "$nested"
    grep -q '^== .gitattributes$' "$nested"
    grep -q '^== other.yaml$' "$flat"
)
echo 'Render and hydrated caches distinguish paths; export-ignore cannot hide committed files'

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

[[ "$(version_order 1.2.3-rc.1 1.2.3)" == -1 ]]
[[ "$(version_order 1.2.3 1.2.3-rc.1)" == 1 ]]
[[ "$(version_order 1.2.3-alpha.2 1.2.3-alpha.10)" == -1 ]]
[[ "$(version_order 1.2.3-9 1.2.3-alpha)" == -1 ]]
[[ "$(version_order 1.2.3-alpha 1.2.3-alpha.1)" == -1 ]]
[[ "$(version_order 1.2.3+build.1 1.2.3+build.2)" == 0 ]]
[[ "$(version_order 1.2.x 1.10.x)" == -1 ]]
[[ "$(version_order 9007199254740993.0.0 9007199254740992.0.0)" == 1 ]]
if version_order 1.2.3-01 1.2.3 > /dev/null 2>&1; then exit 1; fi
if version_order 1.2.x 1.2.3 > /dev/null 2>&1; then exit 1; fi
if version_order invalid 1.2.3 > /dev/null 2>&1; then exit 1; fi
echo 'Version ordering follows SemVer prerelease precedence and separately compares bundled branches'

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

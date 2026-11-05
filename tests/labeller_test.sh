#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
temporary="$(mktemp -d "$root/.rollout-test.XXXXXX")"
trap 'rm -rf "$temporary"' EXIT
export GITHUB_REPOSITORY=example/platform
source "$root/scripts/label-renovate-hydration.sh"
candidate='{"number":1,"user":{"login":"renovate[bot]"},"labels":[{"name":"renovate"},{"name":"update:minor"}]}'
pull_files() { printf '%s\n' infrastructure/demo/Chart.yaml infrastructure/demo/Chart.lock; }
[[ "$(renovate_chart_dir "$candidate")" == infrastructure/demo ]]
[[ "$(renovate_chart_dir "$(jq '.labels |= map(select(.name != "renovate"))' <<< "$candidate")")" == infrastructure/demo ]]
ELIGIBLE_UPDATE_LABELS='["update:patch"]'
if renovate_chart_dir "$candidate"; then exit 1; fi
[[ "$(renovate_chart_dir "$(jq '.labels = [{name:"update:patch"}]' <<< "$candidate")")" == infrastructure/demo ]]
ELIGIBLE_UPDATE_LABELS='["update:patch","update:minor"]'
if renovate_chart_dir "$(jq '.user.login = "someone"' <<< "$candidate")"; then exit 1; fi
if renovate_chart_dir "$(jq '.labels += [{name:"update:major"}]' <<< "$candidate")"; then exit 1; fi
if renovate_chart_dir "$(jq '.labels = []' <<< "$candidate")"; then exit 1; fi
pull_files() { printf '%s\n' infrastructure/demo/Chart.yaml infrastructure/other/Chart.lock; }
if renovate_chart_dir "$candidate"; then exit 1; fi
pull_files() { printf '%s\n' infrastructure/demo/Chart.yaml infrastructure/demo/values.yaml; }
if renovate_chart_dir "$candidate"; then exit 1; fi
pull_files() { printf '%s\n' hydrated-manifests/demo/release/demo/templates/config.yaml; }
[[ "$(hydrated_chart_of 1)" == demo ]]
pull_files() { printf '%s\n' hydrated-manifests/demo/templates/config.yaml unrelated.yaml; }
[[ -z "$(hydrated_chart_of 1)" ]]
CHARTS_ROOT=.
LAYOUT=root-chart
pull_files() { printf '%s\n' Chart.yaml Chart.lock; }
[[ "$(renovate_chart_dir "$candidate")" == . ]]
pull_files() { printf '%s\n' hydrated-manifests/templates/config.yaml; }
[[ "$(hydrated_chart_of 1)" == root ]]
if canonical "$temporary/nonexistent"; then exit 1; fi
mkdir -p "$temporary/first" "$temporary/second"
printf 'kind: ConfigMap\napiVersion: v1\nmetadata: {name: demo}\ndata: {version: old}\n' > "$temporary/first/config.yaml"
printf 'apiVersion: v1\nkind: ConfigMap\ndata: {version: old}\nmetadata: {name: demo}\n' > "$temporary/second/config.yaml"
[[ "$(canonical "$temporary/first")" == "$(canonical "$temporary/second")" ]]
printf 'apiVersion: v1\nkind: ConfigMap\nmetadata: {name: demo}\ndata: {version: new}\n' > "$temporary/second/config.yaml"
[[ "$(canonical "$temporary/first")" != "$(canonical "$temporary/second")" ]]
printf 'not: [valid\n' > "$temporary/second/config.yaml"
if canonical "$temporary/second" > /dev/null 2>&1; then exit 1; fi
echo 'Labeller author, path and canonical comparison checks passed'
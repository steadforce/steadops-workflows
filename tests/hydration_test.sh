#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture="$(mktemp -d "$root/.hydration-test.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT
export GITHUB_REPOSITORY=example/platform
source "$root/scripts/label-renovate-hydration.sh"

check_layout() (
    local fixture_layout="$1" fixture_source="${2:-nested}" fixture_release="${3:-release}" fixture_case fixture_chart_dir fixture_old fixture_update fixture_base fixture_head fixture_candidate fixture_pull_json fixture_crd fixture_actions target result
    LAYOUT="$fixture_layout"
    fixture_case="$LAYOUT-$fixture_source"
    [[ "$fixture_release" == release ]] || fixture_case="$fixture_case-$fixture_release"
    CHARTS_ROOT=infrastructure
    fixture_chart_dir=infrastructure/demo
    if [[ "$LAYOUT" == root-chart || "$LAYOUT" == single-chart || "$fixture_source" == root ]]; then
        CHARTS_ROOT=.
        fixture_chart_dir=.
    fi
    mkdir -p "$fixture/$fixture_case/repo"
    cd "$fixture/$fixture_case/repo"
    work="$fixture/$fixture_case/cache"
    mkdir -p "$work" "$fixture_chart_dir/templates"
    git init --quiet -b main
    git config user.name 'Rollout test'
    git config user.email 'rollout-test@example.invalid'
    git config commit.gpgsign false
    mkdir -p "$fixture_chart_dir/vendor/child/crds"
    printf 'apiVersion: v2\nname: child\nversion: 0.1.0\n' > "$fixture_chart_dir/vendor/child/Chart.yaml"
    printf 'apiVersion: apiextensions.k8s.io/v1\nkind: CustomResourceDefinition\nmetadata: {name: widgets.example.invalid}\nspec: {group: example.invalid}\n' > "$fixture_chart_dir/vendor/child/crds/widgets.yaml"
    printf 'apiVersion: v2\nname: demo\nversion: 1.0.0\ndependencies:\n- name: child\n  version: 0.1.0\n  repository: file://vendor/child\n' > "$fixture_chart_dir/Chart.yaml"
    printf 'releaseName: %s\nnamespace: demo\nenvironments:\n  dev: {}\n' "$fixture_release" > "$fixture_chart_dir/helm-config.yaml"
    printf 'apiVersion: v1\nkind: ConfigMap\nmetadata: {name: demo}\ndata:\n  version: {{ .Chart.Version | quote }}\n' > "$fixture_chart_dir/templates/config.yaml"
    git add .
    git commit --quiet -m initial
    fixture_old="$(git rev-parse HEAD)"
    rendered "$fixture_old" dev "$fixture_chart_dir" > /dev/null
    git checkout --quiet -b environments/dev
    target=hydrated-manifests
    [[ "$LAYOUT" != multi-chart ]] || target=hydrated-manifests/demo/release/demo
    [[ "$LAYOUT" != single-chart ]] || target="hydrated-manifests/$fixture_release/demo"
    copy_render() {
        rm -rf hydrated-manifests
        if [[ "$LAYOUT" == single-chart ]]; then
            helm template "$fixture_release" "$work/tree-$2/$fixture_chart_dir" --include-crds --skip-tests \
                --release-name --output-dir hydrated-manifests > /dev/null
            return
        fi
        mkdir -p "$target"
        cp -r "$1/." "$target/"
        if [[ "$LAYOUT" == multi-chart ]]; then
            mkdir -p "$(dirname "$target")/charts/child"
            mv "$target/charts/child/crds" "$(dirname "$target")/charts/child/"
        else
            mkdir -p "$target/chartz"
            mv "$target/charts/child/crds" "$target/chartz/"
        fi
    }
    copy_render "$work/render-$fixture_old-dev-demo/demo" "$fixture_old"
    git add hydrated-manifests
    git commit --quiet -m deployed
    fixture_base="$(git rev-parse HEAD)"
    git checkout --quiet main
    yq -i '.version = "1.1.0"' "$fixture_chart_dir/Chart.yaml"
    git add "$fixture_chart_dir/Chart.yaml"
    git commit --quiet -m update
    fixture_update="$(git rev-parse HEAD)"
    rendered "$fixture_update" dev "$fixture_chart_dir" > /dev/null
    git checkout --quiet -b hydration environments/dev
    copy_render "$work/render-$fixture_update-dev-demo/demo" "$fixture_update"
    git add hydrated-manifests
    git commit --quiet -m hydrated
    fixture_head="$(git rev-parse HEAD)"
    git update-ref refs/pull/1/head "$fixture_head"
    git checkout --quiet main
    git remote add origin "$PWD"
    git update-ref refs/remotes/origin/main "$fixture_update"
    fixture_actions="$fixture/$fixture_case/actions"
    fixture_pull_json="$(jq -cn --arg base "$fixture_base" --arg head "$fixture_head" \
        '{number:1,labels:[],base:{ref:"environments/dev",sha:$base},head:{sha:$head,repo:{full_name:"example/platform"}}}')"
    fixture_candidate="$(jq -cn --arg sha "$fixture_update" \
        '{number:2,merge_commit_sha:$sha,user:{login:"renovate[bot]"},labels:[{name:"renovate"},{name:"update:minor"}]}')"
    gh() {
        if [[ "$1" == label ]]; then
            return 0
        elif [[ "$1" == pr && "$2" == edit ]]; then
            printf '%s\n' "$*" >> "$fixture_actions"
        elif [[ "$*" == *'--jq'* ]]; then
            jq -r '[.head.sha,.base.sha] | join(" ")' <<< "$fixture_pull_json"
        else
            printf '%s\n' "$fixture_pull_json"
        fi
    }
    merged_pull_request() {
        [[ "$1" != "$fixture_update" ]] || printf '%s\n' "$fixture_candidate"
    }
    pull_files() {
        if [[ "$1" == 2 ]]; then
            printf '%s\n' "${fixture_chart_dir#./}/Chart.yaml" | sed 's|^\./||'
        else
            printf '%s\n' "$target/templates/config.yaml"
        fi
    }
    result="$(holds 1 "$fixture_update" "$fixture_chart_dir")"
    [[ "$result" == *"Head: \`$fixture_head\`"* ]]
    check_main() (
        local expected="$1"
        : > "$fixture_actions"
        api_list() { printf '[%s]\n' "$fixture_pull_json"; }
        upsert_comment() { printf '%s\n' "$2" >> "$fixture_actions"; }
        TMPDIR="$fixture/$fixture_case" main "$fixture_update"
        if [[ "$expected" == eligible ]]; then
            grep -q -- '--add-label renovate-hydration' "$fixture_actions"
            grep -q "Source: \`$fixture_update\`" "$fixture_actions"
        elif grep -q -- '--add-label renovate-hydration' "$fixture_actions"; then
            exit 1
        else
            grep -q 'rendered baseline or proposed output does not match' "$fixture_actions"
        fi
    )
    check_main eligible
    fixture_pull_json="$(jq '.head.sha = "wrong"' <<< "$fixture_pull_json")"
    if holds 1 "$fixture_update" "$fixture_chart_dir" > /dev/null; then exit 1; fi
    fixture_pull_json="$(jq --arg head "$fixture_head" '.head.sha = $head' <<< "$fixture_pull_json")"
    git checkout --quiet hydration
    if [[ "$LAYOUT" == single-chart ]]; then
        fixture_crd="$(find hydrated-manifests -name widgets.yaml)"
        [[ -f "$fixture_crd" ]]
        yq -i '.spec.group = "unexpected.invalid"' "$fixture_crd"
        git add hydrated-manifests
        git commit --quiet -m unexpected-crd
        fixture_head="$(git rev-parse HEAD)"
        git update-ref refs/pull/1/head "$fixture_head"
        git checkout --quiet main
        fixture_pull_json="$(jq --arg head "$fixture_head" '.head.sha = $head' <<< "$fixture_pull_json")"
        if holds 1 "$fixture_update" "$fixture_chart_dir" > /dev/null; then exit 1; fi
        git checkout --quiet hydration
        copy_render "$work/render-$fixture_update-dev-demo/demo" "$fixture_update"
    fi
    printf 'apiVersion: v1\nkind: ConfigMap\nmetadata: {name: demo}\ndata: {version: unexpected}\n' > "$target/templates/config.yaml"
    git add hydrated-manifests
    git commit --quiet -m mixed-change
    fixture_head="$(git rev-parse HEAD)"
    git update-ref refs/pull/1/head "$fixture_head"
    git checkout --quiet main
    fixture_pull_json="$(jq --arg head "$fixture_head" '.head.sha = $head' <<< "$fixture_pull_json")"
    if holds 1 "$fixture_update" "$fixture_chart_dir" > /dev/null; then exit 1; fi
    check_main ineligible
    echo "$fixture_case: main labels verified output; stale and mixed-change PRs refused"
)

check_layout multi-chart
check_layout root-chart
check_layout multi-chart root
check_layout single-chart root
check_layout single-chart root demo
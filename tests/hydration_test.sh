#!/usr/bin/env bash
# Runs the labeller end to end against a git repository hydrated the way helm-hydration.yaml does and a fake GitHub API.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture="$(mktemp -d "$root/.hydration-test.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT
export GITHUB_REPOSITORY=example/platform RETRY_SECONDS=0
source "$root/scripts/label-renovate-hydration.sh"

# The fake GitHub keeps pull requests and comments as JSON files in $state.
gh() {
    local method=GET path body="" jq_filter="" slurp=false number label action
    if [[ "$1" == label ]]; then
        return 0
    fi
    if [[ "$1 $2" == "pr edit" ]]; then
        number="$3" action="$6" label="$7"
        if [[ "$action" == --add-label ]]; then
            update_pull "$number" --arg label "$label" '.labels |= (map(select(.name != $label)) + [{name: $label}])'
        else
            update_pull "$number" --arg label "$label" '.labels |= map(select(.name != $label))'
        fi
        return 0
    fi
    shift
    while [[ "$#" -gt 0 ]]; do
        case "$1" in
            --method) method="$2"; shift 2 ;;
            --paginate) shift ;;
            --slurp) slurp=true; shift ;;
            --jq) jq_filter="$2"; shift 2 ;;
            -f) body="${2#body=}"; shift 2 ;;
            *) path="$1"; shift ;;
        esac
    done
    path="${path#repos/$GITHUB_REPOSITORY/}"
    path="${path%%\?*}"
    local result
    case "$method $path" in
        "GET pulls") result="$(jq '[.[] | select(.state == "open")]' "$state/pulls.json")" ;;
        GET\ pulls/*/files) number="${path#pulls/}"; result="$(pull_file_list "${number%/files}")" ;;
        GET\ pulls/*) result="$(jq --argjson n "${path#pulls/}" '.[] | select(.number == $n)' "$state/pulls.json")" ;;
        GET\ issues/*/comments) number="${path#issues/}"; result="$(jq --argjson n "${number%/comments}" '[.[] | select(.issue == $n)]' "$state/comments.json")" ;;
        GET\ commits/*/pulls) number="${path#commits/}"; result="$(jq --arg sha "${number%/pulls}" '[.[] | select(.merge_commit_sha == $sha)]' "$state/pulls.json")" ;;
        POST\ issues/*/comments)
            number="${path#issues/}"
            jq --argjson n "${number%/comments}" --arg body "$body" --arg user "$LABELLER" \
                '. + [{id: (length + 1), issue: $n, user: {login: $user}, body: $body}]' "$state/comments.json" > "$state/comments.tmp"
            mv "$state/comments.tmp" "$state/comments.json"
            return 0 ;;
        PATCH\ issues/comments/*)
            jq --argjson id "${path#issues/comments/}" --arg body "$body" 'map(if .id == $id then .body = $body else . end)' "$state/comments.json" > "$state/comments.tmp"
            mv "$state/comments.tmp" "$state/comments.json"
            return 0 ;;
        *) echo "unexpected gh call: $method $path" >&2; return 1 ;;
    esac
    [[ "$slurp" != true ]] || result="[$result]"
    if [[ -n "$jq_filter" ]]; then
        jq -r "$jq_filter" <<< "$result"
    else
        printf '%s\n' "$result"
    fi
}
update_pull() {
    local number="$1" filter
    filter="${*: -1}"
    jq --argjson n "$number" "${@:2:$#-2}" "map(if .number == \$n then $filter else . end)" "$state/pulls.json" > "$state/pulls.tmp"
    mv "$state/pulls.tmp" "$state/pulls.json"
}
pull_file_list() {
    local pull
    pull="$(jq --argjson n "$1" '.[] | select(.number == $n)' "$state/pulls.json")"
    if [[ "$(jq -r '.merge_commit_sha // ""' <<< "$pull")" != "" ]]; then
        git diff --name-status --find-renames "$(jq -r .merge_commit_sha <<< "$pull")^1" "$(jq -r .merge_commit_sha <<< "$pull")"
    else
        git diff --name-status --find-renames "$(jq -r .base.sha <<< "$pull")...$(jq -r .head.sha <<< "$pull")"
    fi | jq -Rn '[inputs | split("\t") |
        if .[0] | startswith("R") then {filename: .[2], previous_filename: .[1], status: "renamed"}
        else {filename: .[1]} end]'
}
labels_of() { jq -r --argjson n "$1" '.[] | select(.number == $n) | [.labels[].name] | join(" ")' "$state/pulls.json"; }
comment_of() { jq -r --argjson n "$1" --arg marker "$MARKER" '[.[] | select(.issue == $n and (.body | startswith($marker)))] | last | .body // ""' "$state/comments.json"; }

commit() {
    git add -A
    git -c user.name=test -c user.email=test@example.invalid commit --quiet --allow-empty -m "$1"
    git rev-parse HEAD
}
# A Renovate pull request merged into main that sets a chart's version.
renovate_update() {
    local number="$1" chart_dir="$2" version="$3" sha
    yq -i ".version = \"$version\"" "$(in_chart "$chart_dir" Chart.yaml)"
    sha="$(commit "Update $chart_dir to $version")"
    jq --argjson n "$number" --arg sha "$sha" --arg author "$RENOVATE_AUTHOR" \
        '. + [{number: $n, state: "closed", user: {login: $author}, labels: [{name: "renovate"}, {name: "update:patch"}],
               merged_at: "2026-11-05T00:00:00Z", merge_commit_sha: $sha, base: {ref: "main"}, head: {ref: "renovate/\($n)"}}]' \
        "$state/pulls.json" > "$state/pulls.tmp"
    mv "$state/pulls.tmp" "$state/pulls.json"
    printf '%s\n' "$sha"
}
# Writes the chart rendered at a commit into a branch started from another ref, as the hydration's pull request job does.
hydrate() {
    local branch="$1" from="$2" source="$3" environment="$4" chart_dir="$5" directory output tree
    directory="$(manifest_dir "$source" "$chart_dir")"
    output="$fixture/output-$RANDOM$RANDOM"
    tree="$fixture/source-$source"
    [[ -d "$tree" ]] || git worktree add --quiet --detach "$tree" "$source"
    (cd "$tree" && render_tree "$chart_dir" "$environment" "$output")
    git worktree add --quiet -B "$branch" "$fixture/branch" "$from"
    (cd "$fixture/branch" && rm -rf "$directory" && mkdir -p "$directory" && mv "$output"/* "$directory/" && commit "Hydrate $chart_dir at ${source:0:7}" > /dev/null)
    git worktree remove --force "$fixture/branch"
}
# Opens or updates a hydration pull request whose head is a branch.
open_pull() {
    local number="$1" branch="$2" environment="$3"
    git update-ref "refs/pull/$number/head" "$branch"
    if jq -e --argjson n "$number" 'any(.[]; .number == $n)' "$state/pulls.json" > /dev/null; then
        update_pull "$number" --arg head "$(git rev-parse "$branch")" --arg base "$(git rev-parse "environments/$environment")" '.head.sha = $head | .base.sha = $base'
    else
        jq --argjson n "$number" --arg ref "$branch" --arg head "$(git rev-parse "$branch")" --arg environment "$environment" \
            --arg base "$(git rev-parse "environments/$environment")" --arg repo "$GITHUB_REPOSITORY" \
            '. + [{number: $n, state: "open", user: {login: "github-actions[bot]"}, labels: [],
                   head: {ref: $ref, sha: $head, repo: {full_name: $repo}}, base: {ref: "environments/\($environment)", sha: $base}}]' \
            "$state/pulls.json" > "$state/pulls.tmp"
        mv "$state/pulls.tmp" "$state/pulls.json"
    fi
}
run_labeller() (
    git update-ref refs/remotes/origin/main main
    TMPDIR="$fixture" main "$1" > "$fixture/log" 2>&1 || { cat "$fixture/log" >&2; return 1; }
)
expect_labelled() { [[ " $(labels_of "$1") " == *" $LABEL "* ]] || { echo "#$1 is not labelled" >&2; cat "$fixture/log" >&2; return 1; }; }
expect_unlabelled() { [[ " $(labels_of "$1") " != *" $LABEL "* ]] || { echo "#$1 is labelled" >&2; cat "$fixture/log" >&2; return 1; }; }
expect_comment() { [[ "$(comment_of "$1")" == *"$2"* ]] || { echo "#$1 comment lacks '$2':" >&2; comment_of "$1" >&2; cat "$fixture/log" >&2; return 1; }; }

new_repository() {
    state="$fixture/$1-state"
    mkdir -p "$state" "$fixture/$1"
    echo '[]' > "$state/pulls.json"
    echo '[]' > "$state/comments.json"
    cd "$fixture/$1"
    git init --quiet -b main
    git remote add origin "$PWD"
    work="$fixture/$1-work"
    mkdir -p "$work"
}
chart() {
    local chart_dir="$1" name="$2" release="$3"
    mkdir -p "$chart_dir/templates" "$chart_dir/crds"
    printf 'apiVersion: v2\nname: %s\nversion: 1.0.0\n' "$name" > "$chart_dir/Chart.yaml"
    printf 'releaseName: %s\nnamespace: %s\nenvironments:\n  dev: {}\n' "$release" "$name" > "$chart_dir/helm-config.yaml"
    printf 'apiVersion: v1\nkind: ConfigMap\nmetadata: {name: %s}\ndata:\n  version: {{ .Chart.Version | quote }}\n  setting: {{ .Values.setting | default "initial" | quote }}\n' "$name" > "$chart_dir/templates/config.yaml"
    printf 'apiVersion: apiextensions.k8s.io/v1\nkind: CustomResourceDefinition\nmetadata: {name: widgets.%s.invalid}\nspec: {group: %s.invalid}\n' "$name" "$name" > "$chart_dir/crds/widgets.yaml"
}
environment_branch() {
    git branch environments/dev "$(git -c user.name=test -c user.email=test@example.invalid commit-tree "$(git hash-object -t tree /dev/null)" -m 'chore: initialise environments/dev branch')"
}

# A monorepo: two charts, so each owns hydrated-manifests/<chart>; demo's release name differs, which puts its CRDs beside the release directory.
new_repository monorepo
CHARTS_ROOT=. DISCOVERY_DEPTH=3 BUNDLE_PATCHES=true LAYOUT=""
chart infrastructure/demo demo release
chart infrastructure/other other other
c0="$(commit initial)"
environment_branch
hydrate environments/dev environments/dev "$c0" dev infrastructure/demo
hydrate environments/dev environments/dev "$c0" dev infrastructure/other
pull=hydration-pull-request/dev-demo-1.0.x

c1="$(renovate_update 11 infrastructure/demo 1.0.1)"
hydrate "$pull" environments/dev "$c1" dev infrastructure/demo
open_pull 101 "$pull" dev
run_labeller "$c1"
expect_labelled 101
expect_comment 101 "Source: \`$c1\` (#11, Renovate update of \`demo\`)."
expect_comment 101 "Head: \`$(git rev-parse "$pull")\`"
expect_comment 101 "Base: \`$(git rev-parse environments/dev)\`"
expect_comment 101 'Carries this update and nothing else'
echo 'monorepo: a single update is labelled with its source, head and base'

# Another chart's commit and a commit that leaves demo's render alone do not break a run of updates.
printf 'setting: changed\n' > infrastructure/other/values.yaml
commit 'Change other' > /dev/null
printf 'notes\n' > infrastructure/demo/README.md
commit 'Document demo' > /dev/null
c4="$(renovate_update 12 infrastructure/demo 1.0.2)"
hydrate "$pull" environments/dev "$c4" dev infrastructure/demo
open_pull 101 "$pull" dev
run_labeller "$c4"
expect_labelled 101
expect_comment 101 "Source: \`$c4\` (#12"
expect_comment 101 'earlier Renovate updates #11 of the same chart'
echo 'monorepo: unrelated and render-neutral commits do not break a run of updates'

# A commit that changes demo's render and is no Renovate update ends the run.
printf 'setting: changed\n' > infrastructure/demo/values.yaml
c5="$(commit 'Change demo')"
c6="$(renovate_update 13 infrastructure/demo 1.0.3)"
hydrate "$pull" environments/dev "$c6" dev infrastructure/demo
open_pull 101 "$pull" dev
run_labeller "$c6"
expect_unlabelled 101
expect_comment 101 "back to ${c5:0:7}, a commit that is not one and changes this environment"
echo 'monorepo: a change outside Renovate between the updates refuses the pull request'

# Once deployed, the next update is labelled again; one with more than the update in it is not.
hydrate environments/dev environments/dev "$c6" dev infrastructure/demo
c7="$(renovate_update 14 infrastructure/demo 1.0.4)"
hydrate "$pull" environments/dev "$c7" dev infrastructure/demo
git worktree add --quiet "$fixture/branch" "$pull"
printf 'apiVersion: v1\nkind: ConfigMap\nmetadata: {name: extra}\n' > "$fixture/branch/hydrated-manifests/demo/extra.yaml"
(cd "$fixture/branch" && commit 'Add extra' > /dev/null)
git worktree remove --force "$fixture/branch"
open_pull 101 "$pull" dev
run_labeller "$c7"
expect_unlabelled 101
expect_comment 101 'it differs from the chart rendered with the update, in `extra.yaml`'
hydrate "$pull" environments/dev "$c7" dev infrastructure/demo
open_pull 101 "$pull" dev
run_labeller "$c7"
expect_labelled 101
echo 'monorepo: a pull request carrying more than the update is refused, the clean one labelled'

for extension in json txt; do
    git worktree add --quiet "$fixture/branch" "$pull"
    printf '{"apiVersion":"v1","kind":"ConfigMap","metadata":{"name":"extra"}}\n' > "$fixture/branch/hydrated-manifests/demo/extra.$extension"
    (cd "$fixture/branch" && commit "Add extra $extension" > /dev/null)
    git worktree remove --force "$fixture/branch"
    open_pull 101 "$pull" dev
    run_labeller "$c7"
    expect_unlabelled 101
    expect_comment 101 "extra.$extension"
    hydrate "$pull" environments/dev "$c7" dev infrastructure/demo
    open_pull 101 "$pull" dev
    run_labeller "$c7"
    expect_labelled 101
done
echo 'monorepo: extra JSON and unsupported-extension resources remove the trusted label'

git worktree add --quiet "$fixture/branch" "$pull"
printf 'apiVersion: v1\nkind: ConfigMap\nmetadata: {name: hidden}\n' > "$fixture/branch/hydrated-manifests/demo/hidden.yaml"
printf 'hidden.yaml export-ignore\n' > "$fixture/branch/hydrated-manifests/demo/.gitattributes"
(cd "$fixture/branch" && commit 'Hide an extra manifest from git archive' > /dev/null)
git worktree remove --force "$fixture/branch"
archived="$(git archive "$pull" hydrated-manifests/demo | tar -tf -)"
[[ "$archived" != *hidden.yaml* ]]
open_pull 101 "$pull" dev
run_labeller "$c7"
expect_unlabelled 101
expect_comment 101 'hidden.yaml'
hydrate "$pull" environments/dev "$c7" dev infrastructure/demo
open_pull 101 "$pull" dev
run_labeller "$c7"
expect_labelled 101
echo 'monorepo: export-ignore cannot hide an extra resource from verification'

# Another chart merged into the environment branch moves the base; the label stays and the comment follows it.
hydrate environments/dev environments/dev "$(git rev-parse main)" dev infrastructure/other
open_pull 101 "$pull" dev
run_labeller "$c7"
expect_labelled 101
expect_comment 101 "Base: \`$(git rev-parse environments/dev)\`"
echo 'monorepo: a moved base is verified again and recorded'

# An older version's pull request is superseded, a newer one left alone.
hydrate hydration-pull-request/dev-demo-0.9.x environments/dev "$c0" dev infrastructure/demo
open_pull 102 hydration-pull-request/dev-demo-0.9.x dev
update_pull 102 '.labels = [{name: "renovate-hydration"}, {name: "gatekeeper-blocked"}]'
jq '. + [{id: 900, issue: 102, user: {login: "gatekeeper[bot]"}, body: "<!-- gatekeeper-dev -->\nNot merged by the dev gatekeeper: waiting."}]' "$state/comments.json" > "$state/comments.tmp"
mv "$state/comments.tmp" "$state/comments.json"
hydrate hydration-pull-request/dev-demo-2.0.x environments/dev "$c0" dev infrastructure/demo
open_pull 103 hydration-pull-request/dev-demo-2.0.x dev
run_labeller "$c7"
expect_unlabelled 102
[[ " $(labels_of 102) " != *" gatekeeper-blocked "* ]]
expect_comment 102 'superseded by #101 (`1.0.x`)'
[[ "$(jq -r '.[] | select(.id == 900) | .body' "$state/comments.json")" == *'No longer handled by the gatekeepers'* ]]
[[ -z "$(comment_of 103)" ]]
expect_labelled 101
echo 'monorepo: an older version is superseded and handed back from the gatekeepers, a newer one left alone'

# A render that keeps failing leaves the label as it is.
c8="$(renovate_update 15 infrastructure/demo 1.0.5)"
hydrate "$pull" environments/dev "$c8" dev infrastructure/demo
open_pull 101 "$pull" dev
(
    render_tree() { return 1; }
    run_labeller "$c8"
)
expect_labelled 101
expect_comment 101 "Source: \`$c7\`"
grep -q 'left as it is' "$fixture/log"
echo 'monorepo: a failing render leaves the label alone'

# A layout set by the caller has to agree with the discovery.
if (LAYOUT=single-chart run_labeller "$c8" 2> /dev/null); then exit 1; fi
grep -q "layout 'single-chart' does not match" "$fixture/log"
echo 'monorepo: a layout that contradicts the discovery fails the run'

# A repository holding one chart at its root owns all of hydrated-manifests and names no chart in its branches.
new_repository single
CHARTS_ROOT=. DISCOVERY_DEPTH=1 LAYOUT=single-chart
chart . demo release
c0="$(commit initial)"
environment_branch
hydrate environments/dev environments/dev "$c0" dev .
pull=hydration-pull-request/dev-1.0.x
c1="$(renovate_update 21 . 1.0.1)"
hydrate "$pull" environments/dev "$c1" dev .
open_pull 201 "$pull" dev
run_labeller "$c1"
expect_labelled 201
expect_comment 201 "Source: \`$c1\` (#21, Renovate update of \`demo\`)."
git worktree add --quiet "$fixture/branch" "$pull"
printf 'notes\n' > "$fixture/branch/README.md"
(cd "$fixture/branch" && commit 'Add notes' > /dev/null)
git worktree remove --force "$fixture/branch"
open_pull 201 "$pull" dev
run_labeller "$c1"
expect_unlabelled 201
expect_comment 201 'it changes files outside `hydrated-manifests`'
echo 'single chart: the update is labelled, a pull request touching other files refused'

new_repository renamed
CHARTS_ROOT=. DISCOVERY_DEPTH=3 LAYOUT=""
chart infrastructure/demo demo release
chart infrastructure/other other other
printf '{{ if ne .Chart.Version "1.0.0" }}\napiVersion: v1\nkind: ConfigMap\nmetadata: {name: transferred}\n{{ end }}\n' > infrastructure/demo/templates/transferred.yaml
c0="$(commit initial)"
environment_branch
hydrate environments/dev environments/dev "$c0" dev infrastructure/demo
hydrate environments/dev environments/dev "$c0" dev infrastructure/other
c1="$(renovate_update 31 infrastructure/demo 1.0.1)"
pull=hydration-pull-request/dev-demo-1.0.x
hydrate "$pull" environments/dev "$c1" dev infrastructure/demo
git worktree add --quiet "$fixture/branch" environments/dev
git show "$pull:hydrated-manifests/demo/release/demo/templates/transferred.yaml" > "$fixture/branch/hydrated-manifests/other/transferred.yaml"
(cd "$fixture/branch" && commit 'Existing resource owned by the other chart' > /dev/null)
git worktree remove --force "$fixture/branch"
hydrate "$pull" environments/dev "$c1" dev infrastructure/demo
git worktree add --quiet "$fixture/branch" "$pull"
rm "$fixture/branch/hydrated-manifests/other/transferred.yaml"
(cd "$fixture/branch" && commit 'Rename the other chart resource into the expected output' > /dev/null)
git worktree remove --force "$fixture/branch"
open_pull 301 "$pull" dev
pull_file_list 301 | jq -e 'any(.[]; .previous_filename == "hydrated-manifests/other/transferred.yaml")' > /dev/null
run_labeller "$c1"
expect_unlabelled 301
expect_comment 301 'it changes files outside `hydrated-manifests/demo`'
echo 'monorepo: renaming another chart resource into valid output is refused'

new_repository cache-collisions
CHARTS_ROOT=. DISCOVERY_DEPTH=3 LAYOUT=""
chart apps/api api release
chart apps-api flat release
c0="$(commit initial)"
environment_branch
hydrate environments/dev environments/dev "$c0" dev apps/api
hydrate environments/dev environments/dev "$c0" dev apps-api
c1="$(renovate_update 41 apps/api 1.0.1)"
hydrate hydration-pull-request/dev-api-1.0.x environments/dev "$c1" dev apps/api
open_pull 401 hydration-pull-request/dev-api-1.0.x dev
c2="$(renovate_update 42 apps-api 1.0.1)"
hydrate hydration-pull-request/dev-flat-1.0.x environments/dev "$c2" dev apps-api
open_pull 402 hydration-pull-request/dev-flat-1.0.x dev
run_labeller "$c2"
expect_labelled 401
expect_labelled 402
expect_comment 401 "Source: \`$c1\` (#41"
expect_comment 402 "Source: \`$c2\` (#42"
echo 'multi-chart: adjacent updates of apps/api and apps-api use independent render caches'

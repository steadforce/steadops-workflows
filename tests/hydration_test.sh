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
        GET\ pulls/*/files) number="${path#pulls/}"; result="$(pull_file_list "${number%/files}" | jq '.[0:3000]')" ;;
        GET\ pulls/*) result="$(jq --argjson n "${path#pulls/}" '.[] | select(.number == $n)' "$state/pulls.json")" ;;
        GET\ issues/*/comments) number="${path#issues/}"; result="$(jq --argjson n "${number%/comments}" '[.[] | select(.issue == $n)]' "$state/comments.json")" ;;
        GET\ commits/*/pulls) number="${path#commits/}"; result="$(jq --arg sha "${number%/pulls}" '[.[] | select(.merge_commit_sha == $sha or ((.integrated_commits // []) | index($sha) != null))]' "$state/pulls.json")" ;;
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
        git diff --name-status --find-renames "$(jq -r '.source_base_sha // (.merge_commit_sha + "^1")' <<< "$pull")" "$(jq -r .merge_commit_sha <<< "$pull")"
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

new_repository api-limit
CHARTS_ROOT=. DISCOVERY_DEPTH=1 BUNDLE_PATCHES=true LAYOUT=""
chart . demo release
c0="$(commit initial)"
environment_branch
hydrate environments/dev environments/dev "$c0" dev .
c1="$(renovate_update 51 . 1.0.1)"
pull=hydration-pull-request/dev-1.0.x
hydrate "$pull" environments/dev "$c1" dev .
git worktree add --quiet "$fixture/branch" "$pull"
for (( index = 0; index < 3000; index++ )); do
    printf 'unverified\n' > "$fixture/branch/hydrated-manifests/extra-$index.txt"
done
printf 'apiVersion: v1\nkind: ConfigMap\nmetadata: {name: outside}\n' > "$fixture/branch/zzz-outside.yaml"
(cd "$fixture/branch" && commit 'More than 3000 PR files with an out-of-scope tail' > /dev/null)
git worktree remove --force "$fixture/branch"
open_pull 501 "$pull" dev
api_list "repos/$repo/pulls/501/files?per_page=100" | jq -e 'length == 3000 and all(.[]; .filename != "zzz-outside.yaml")' > /dev/null
run_labeller "$c1"
expect_unlabelled 501
expect_comment 501 'it changes files outside `hydrated-manifests`'
echo 'scope: complete Git diffs catch out-of-scope changes omitted by the 3000-file API limit'

new_repository merge-result
CHARTS_ROOT=. DISCOVERY_DEPTH=1 LAYOUT=""
chart . demo release
printf 'apiVersion: v1\nkind: ConfigMap\nmetadata: {name: stable}\n' > templates/config.yaml
printf '{{ if eq .Chart.Version "1.0.1" }}\napiVersion: v1\nkind: ConfigMap\nmetadata: {name: base-only}\n{{ end }}\n' > templates/base-only.yaml
printf '{{ if eq .Chart.Version "1.0.2" }}\napiVersion: v1\nkind: ConfigMap\nmetadata: {name: head-only}\n{{ end }}\n' > templates/head-only.yaml
c0="$(commit initial)"
environment_branch
hydrate environments/dev environments/dev "$c0" dev .
c1="$(renovate_update 61 . 1.0.1)"
c2="$(renovate_update 62 . 1.0.2)"
pull=hydration-pull-request/dev-1.0.x
hydrate "$pull" environments/dev "$c2" dev .
open_pull 601 "$pull" dev
run_labeller "$c2"
expect_labelled 601
hydrate environments/dev environments/dev "$c1" dev .
open_pull 601 "$pull" dev
merge_tree="$(git merge-tree --write-tree environments/dev "$pull")"
git cat-file -e "$merge_tree:hydrated-manifests/release/demo/templates/base-only.yaml"
run_labeller "$c2"
expect_unlabelled 601
expect_comment 601 'base-only.yaml'
echo 'merge: a base-only resource surviving a clean three-way merge removes stale eligibility'

git worktree add --quiet "$fixture/branch" environments/dev
printf 'apiVersion: v1\nkind: ConfigMap\nmetadata: {name: conflicting-head-resource}\n' > "$fixture/branch/hydrated-manifests/release/demo/templates/head-only.yaml"
(cd "$fixture/branch" && commit 'Conflicting resource added on the environment branch' > /dev/null)
git worktree remove --force "$fixture/branch"
open_pull 601 "$pull" dev
run_labeller "$c2"
expect_unlabelled 601
expect_comment 601 'its merge into the checked base has conflicts'
echo 'merge: conflicting environment and PR changes cannot receive the trusted label'

new_repository historical-input
CHARTS_ROOT=. DISCOVERY_DEPTH=3 LAYOUT=""
chart infrastructure/demo demo release
printf 'setting: initial\n' > old-values.yaml
printf 'setting: manual\n' > new-values.yaml
yq -i '.environments.dev.valueFiles = ["../../old-values.yaml"]' infrastructure/demo/helm-config.yaml
c0="$(commit initial)"
environment_branch
hydrate environments/dev environments/dev "$c0" dev infrastructure/demo
c1="$(renovate_update 71 infrastructure/demo 1.0.1)"
printf 'setting: manual\n' > old-values.yaml
manual="$(commit 'Change the formerly referenced external values')"
yq -i '.environments.dev.valueFiles = ["../../new-values.yaml"]' infrastructure/demo/helm-config.yaml
commit 'Switch to an equivalent values file' > /dev/null
c2="$(renovate_update 72 infrastructure/demo 1.0.2)"
pull=hydration-pull-request/dev-1.0.x
hydrate "$pull" environments/dev "$c2" dev infrastructure/demo
open_pull 701 "$pull" dev
run_labeller "$c2"
expect_unlabelled 701
expect_comment 701 "back to ${manual:0:7}, a commit that is not one and changes this environment"
echo 'history: a manual change to a formerly referenced render input breaks the eligible chain'

new_repository prereleases
CHARTS_ROOT=. DISCOVERY_DEPTH=1 BUNDLE_PATCHES=false LAYOUT=""
chart . demo release
c0="$(commit initial)"
environment_branch
hydrate environments/dev environments/dev "$c0" dev .
c1="$(renovate_update 81 . 1.2.3-rc.x)"
hydrate hydration-pull-request/dev-1.2.3-rc.x environments/dev "$c1" dev .
open_pull 801 hydration-pull-request/dev-1.2.3-rc.x dev
c2="$(renovate_update 82 . 1.2.3)"
hydrate hydration-pull-request/dev-1.2.3 environments/dev "$c2" dev .
open_pull 802 hydration-pull-request/dev-1.2.3 dev
run_labeller "$c1"
expect_labelled 801
[[ -z "$(comment_of 802)" ]]
run_labeller "$c2"
expect_unlabelled 801
expect_comment 801 'superseded by #802 (`1.2.3`)'
expect_labelled 802
echo 'versions: a release candidate never supersedes its final release'

git worktree add --quiet "$fixture/branch" environments/dev
printf 'environment notes\n' > "$fixture/branch/README.md"
(cd "$fixture/branch" && commit 'Advance the environment without changing the chart' > /dev/null)
git worktree remove --force "$fixture/branch"
open_pull 802 hydration-pull-request/dev-1.2.3 dev
run_labeller "$c1"
expect_labelled 802
expect_comment 802 "Base: \`$(git rev-parse environments/dev)\`"
expect_comment 802 "Source: \`$c2\` (#82"
update_pull 82 '.labels = []'
run_labeller "$c2"
expect_unlabelled 802
expect_comment 802 '#82 is not eligible'
echo 'revalidation: skipped newer PRs refresh their base and lose trust when their source becomes ineligible'

for earlier_change in chart-only values template other-chart; do
    new_repository "rebased-$earlier_change"
    CHARTS_ROOT=. DISCOVERY_DEPTH=3 BUNDLE_PATCHES=true LAYOUT=""
    chart infrastructure/demo demo release
    if [[ "$earlier_change" == other-chart ]]; then chart infrastructure/other other other; fi
    c0="$(commit initial)"
    environment_branch
    hydrate environments/dev environments/dev "$c0" dev infrastructure/demo
    case "$earlier_change" in
        chart-only) yq -i '.version = "1.0.1"' infrastructure/demo/Chart.yaml ;;
        values) printf 'setting: production-only\n' > infrastructure/demo/values-prod.yaml ;;
        template) printf '{{/* Render-neutral template change */}}\n' > infrastructure/demo/templates/notes.yaml ;;
        other-chart) yq -i '.version = "1.0.1"' infrastructure/other/Chart.yaml ;;
    esac
    first="$(commit 'First rebased commit in the source PR')"
    tip="$(renovate_update 91 infrastructure/demo 1.0.2)"
    update_pull 91 --arg base "$c0" --arg first "$first" --arg tip "$tip" \
        '.source_base_sha = $base | .integrated_commits = [$first, $tip]'
    pull=hydration-pull-request/dev-1.0.x
    if [[ "$earlier_change" == other-chart ]]; then pull=hydration-pull-request/dev-demo-1.0.x; fi
    hydrate "$pull" environments/dev "$tip" dev infrastructure/demo
    open_pull 901 "$pull" dev
    [[ "$(pull_files 91 "$tip")" == infrastructure/demo/Chart.yaml ]]
    [[ -z "$(merged_pull_request "$first")" ]]
    [[ "$(merged_pull_request "$first" "$tip" | jq -r .number)" == 91 ]]
    run_labeller "$tip"
    if [[ "$earlier_change" == chart-only ]]; then
        expect_labelled 901
        expect_comment 901 "Source: \`$tip\` (#91"
        expect_comment 901 'Carries this update and nothing else'
    else
        expect_unlabelled 901
        update_pull 901 '.labels = [{name: "renovate-hydration"}]'
        upsert_comment 901 "Source: \`$tip\` (#91)."
        run_labeller "$tip"
        expect_unlabelled 901
        expect_comment 901 '#91 is not eligible'
    fi
    echo "rebased PR: $earlier_change checks the entire PR and the before-first-commit render boundary"
done

# A busy monorepo: commits elsewhere neither use up the update chain nor cost a render, a change to a shared dependency still ends the run.
eval "$(declare -f render_tree | sed '1s/^render_tree/counted_render_tree/')"
render_tree() { echo "$1" >> "$fixture/renders"; counted_render_tree "$@"; }
new_repository budgets
CHARTS_ROOT=. DISCOVERY_DEPTH=3 BUNDLE_PATCHES=true LAYOUT=""
chart infrastructure/demo demo release
chart infrastructure/other other other
mkdir -p charts/shared/templates
printf 'apiVersion: v2\nname: shared\nversion: 1.0.0\n' > charts/shared/Chart.yaml
printf 'apiVersion: v1\nkind: ConfigMap\nmetadata: {name: shared}\ndata: {owner: shared}\n' > charts/shared/templates/shared.yaml
yq -i '.dependencies = [{"name": "shared", "version": "1.0.0", "repository": "file://../../charts/shared"}]' infrastructure/demo/Chart.yaml
yq -i '.primaryDependency = "shared"' infrastructure/demo/helm-config.yaml
c0="$(commit initial)"
environment_branch
hydrate environments/dev environments/dev "$c0" dev infrastructure/demo
pull=hydration-pull-request/dev-demo-1.0.x
for i in $(seq 1 15); do
    printf 'setting: change-%s\n' "$i" > infrastructure/other/values.yaml
    commit "Change other $i" > /dev/null
done
c1="$(renovate_update 61 infrastructure/demo 1.0.1)"
hydrate "$pull" environments/dev "$c1" dev infrastructure/demo
open_pull 601 "$pull" dev
: > "$fixture/renders"
run_labeller "$c1"
expect_labelled 601
expect_comment 601 'Carries this update and nothing else'
[[ "$(grep -cx infrastructure/demo "$fixture/renders")" -le 2 ]] || { echo "rendered demo $(wc -l < "$fixture/renders") times" >&2; exit 1; }
echo 'budgets: fifteen commits to another chart neither end the run nor cost a render each'

for i in $(seq 16 21); do
    printf 'setting: change-%s\n' "$i" > infrastructure/other/values.yaml
    commit "Change other $i" > /dev/null
done
c2="$(renovate_update 62 infrastructure/demo 1.0.2)"
hydrate "$pull" environments/dev "$c2" dev infrastructure/demo
open_pull 601 "$pull" dev
run_labeller "$c2"
expect_labelled 601
expect_comment 601 'earlier Renovate updates #61 of the same chart'
(
    MAX_SCAN=5
    run_labeller "$c2"
)
expect_labelled 601
grep -q 'no deployed state of the chart within the last 5 commits' "$fixture/log"
echo 'budgets: running out of history leaves the label as it is'

printf 'apiVersion: v1\nkind: ConfigMap\nmetadata: {name: shared}\ndata: {owner: changed}\n' > charts/shared/templates/shared.yaml
shared_change="$(commit 'Change the shared chart')"
c3="$(renovate_update 63 infrastructure/demo 1.0.3)"
hydrate "$pull" environments/dev "$c3" dev infrastructure/demo
open_pull 601 "$pull" dev
run_labeller "$c3"
expect_unlabelled 601
expect_comment 601 "back to ${shared_change:0:7}"
echo 'budgets: an undeployed change to a file:// dependency outside the chart ends the run'

# A symlinked values file: its blob names the target, not the content Helm reads, so a change to the target must still end the run.
new_repository symlinks
CHARTS_ROOT=. DISCOVERY_DEPTH=3 BUNDLE_PATCHES=true LAYOUT=""
chart infrastructure/demo demo release
chart infrastructure/other other other
mkdir -p common
printf 'setting: shared\n' > common/values.yaml
ln -s ../../common/values.yaml infrastructure/demo/values.yaml
c0="$(commit initial)"
environment_branch
hydrate environments/dev environments/dev "$c0" dev infrastructure/demo
pull=hydration-pull-request/dev-demo-1.0.x
printf 'setting: retargeted\n' > common/values.yaml
target_change="$(commit 'Change the symlinked values')"
c1="$(renovate_update 71 infrastructure/demo 1.0.1)"
hydrate "$pull" environments/dev "$c1" dev infrastructure/demo
open_pull 701 "$pull" dev
run_labeller "$c1"
expect_unlabelled 701
expect_comment 701 "back to ${target_change:0:7}"
echo 'symlinks: a change behind a symlinked values file ends the run'


# What a pull request brings into its manifests that the labeller does not accept refuses it, even with the label on: a crafted name, a symlink.
new_repository names
CHARTS_ROOT=. DISCOVERY_DEPTH=3 BUNDLE_PATCHES=true LAYOUT=""
chart infrastructure/demo demo release
chart infrastructure/other other other
printf 'apiVersion: v1\nkind: ConfigMap\nmetadata: {name: second}\n' > infrastructure/demo/templates/second.yaml
c0="$(commit initial)"
environment_branch
hydrate environments/dev environments/dev "$c0" dev infrastructure/demo
pull=hydration-pull-request/dev-demo-1.0.x
c1="$(renovate_update 81 infrastructure/demo 1.0.1)"
hydrate "$pull" environments/dev "$c1" dev infrastructure/demo
open_pull 801 "$pull" dev
run_labeller "$c1"
expect_labelled 801

# config.yaml is deleted; second.yaml moves to a name that spells out config.yaml's document and the header of second.yaml.
git worktree add --quiet "$fixture/branch" "$pull"
(
    cd "$fixture/branch/hydrated-manifests/demo"
    deleted=release/demo/templates/config.yaml
    next=release/demo/templates/second.yaml
    crafted="$deleted
$(yq -o=json -I=0 'sort_keys(..)' "$deleted")
== $next"
    mkdir -p "$(dirname "$crafted")"
    mv "$next" "$crafted"
    rm "$deleted"
    cd "$fixture/branch" && commit 'Hide a deleted manifest in a file name' > /dev/null
)
git worktree remove --force "$fixture/branch"
open_pull 801 "$pull" dev
run_labeller "$c1"
expect_unlabelled 801
expect_comment 801 'control character'
echo 'names: a newline in a manifest name cannot hide a deleted manifest, and refuses the labelled pull request'

hydrate "$pull" environments/dev "$c1" dev infrastructure/demo
open_pull 801 "$pull" dev
run_labeller "$c1"
expect_labelled 801
git worktree add --quiet "$fixture/branch" "$pull"
ln -s release/demo/templates/config.yaml "$fixture/branch/hydrated-manifests/demo/link.yaml"
(cd "$fixture/branch" && commit 'Add a symlink to the manifests' > /dev/null)
git worktree remove --force "$fixture/branch"
open_pull 801 "$pull" dev
run_labeller "$c1"
expect_unlabelled 801
expect_comment 801 '(120000 blob), which the labeller does not accept'
echo 'names: a symlink in the manifests refuses the labelled pull request instead of leaving it labelled'

# An absolute file:// dependency would make every older render read today's content, so the pull request is refused rather than checked.
new_repository absolute
CHARTS_ROOT=. DISCOVERY_DEPTH=3 BUNDLE_PATCHES=true LAYOUT=""
chart infrastructure/demo demo release
chart infrastructure/other other other
mkdir -p "$fixture/outside/templates"
printf 'apiVersion: v2\nname: outside\nversion: 1.0.0\n' > "$fixture/outside/Chart.yaml"
printf 'apiVersion: v1\nkind: ConfigMap\nmetadata: {name: outside}\n' > "$fixture/outside/templates/outside.yaml"
yq -i ".dependencies = [{\"name\": \"outside\", \"version\": \"1.0.0\", \"repository\": \"file://$fixture/outside\"}]" infrastructure/demo/Chart.yaml
yq -i '.primaryDependency = "outside"' infrastructure/demo/helm-config.yaml
c0="$(commit initial)"
environment_branch
hydrate environments/dev environments/dev "$c0" dev infrastructure/demo
pull=hydration-pull-request/dev-demo-1.0.x
c1="$(renovate_update 91 infrastructure/demo 1.0.1)"
hydrate "$pull" environments/dev "$c1" dev infrastructure/demo
open_pull 911 "$pull" dev
run_labeller "$c1"
expect_unlabelled 911
expect_comment 911 "the chart depends on \`file://$fixture/outside\`"
echo 'absolute: a chart with an absolute file:// dependency is refused, not checked against today'"'"'s content'

# Hydration runs finish out of order: a run for an older commit, or one whose newer update is not hydrated yet, keeps a valid label.
new_repository ordering
CHARTS_ROOT=. DISCOVERY_DEPTH=3 BUNDLE_PATCHES=true LAYOUT=""
chart infrastructure/demo demo release
chart infrastructure/other other other
c0="$(commit initial)"
environment_branch
hydrate environments/dev environments/dev "$c0" dev infrastructure/demo
pull=hydration-pull-request/dev-demo-1.0.x
c1="$(renovate_update 41 infrastructure/demo 1.0.1)"
c2="$(renovate_update 42 infrastructure/demo 1.0.2)"
hydrate "$pull" environments/dev "$c2" dev infrastructure/demo
open_pull 401 "$pull" dev
run_labeller "$c2"
expect_labelled 401
expect_comment 401 "Source: \`$c2\` (#42"
run_labeller "$c1"
expect_labelled 401
expect_comment 401 "Source: \`$c2\` (#42"
echo 'ordering: a delayed run for an older commit leaves a label given for a newer update'

c3="$(renovate_update 43 infrastructure/demo 1.0.3)"
run_labeller "$c3"
expect_labelled 401
expect_comment 401 "Source: \`$c2\` (#42"
grep -q 'its label stays' "$fixture/log"
hydrate "$pull" environments/dev "$c3" dev infrastructure/demo
open_pull 401 "$pull" dev
run_labeller "$c3"
expect_labelled 401
expect_comment 401 "Source: \`$c3\` (#43"
echo 'ordering: an update whose hydration has not landed yet keeps the label of the one before, then takes it over'

git worktree add --quiet "$fixture/branch" "$pull"
printf 'apiVersion: v1\nkind: ConfigMap\nmetadata: {name: extra}\n' > "$fixture/branch/hydrated-manifests/demo/extra.yaml"
(cd "$fixture/branch" && commit 'Add extra' > /dev/null)
git worktree remove --force "$fixture/branch"
open_pull 401 "$pull" dev
c4="$(renovate_update 44 infrastructure/demo 1.0.4)"
run_labeller "$c4"
expect_unlabelled 401
echo 'ordering: the fallback to the recorded update still refuses a pull request that carries neither'

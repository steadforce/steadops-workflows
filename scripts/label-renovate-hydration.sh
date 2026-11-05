#!/usr/bin/env bash
set -euo pipefail

SOURCE_BRANCH="${SOURCE_BRANCH:-main}"
CHARTS_ROOT="${CHARTS_ROOT:-infrastructure}"
LAYOUT="${LAYOUT:-multi-chart}"
MANIFEST_ROOT="${MANIFEST_ROOT:-hydrated-manifests}"
ENVIRONMENT_BRANCH_PREFIX="${ENVIRONMENT_BRANCH_PREFIX:-environments/}"
RENOVATE_AUTHOR="${RENOVATE_AUTHOR:-renovate[bot]}"
ELIGIBLE_UPDATE_LABELS="${ELIGIBLE_UPDATE_LABELS:-}"
[[ -n "$ELIGIBLE_UPDATE_LABELS" ]] || ELIGIBLE_UPDATE_LABELS='["update:patch","update:minor"]'
readonly LABEL=renovate-hydration MARKER='<!-- renovate-hydration -->' LABELLER='github-actions[bot]'
readonly MAX_CHAIN=10 RECENT_COMMITS=20
repo="${GITHUB_REPOSITORY:?}"

api_list() { gh api "$1" --paginate --slurp | jq 'add'; }
pull_files() { api_list "repos/$repo/pulls/$1/files?per_page=100" | jq -r '.[].filename'; }
comments_of() { api_list "repos/$repo/issues/$1/comments?per_page=100"; }
source_of() {
    comments_of "$1" | jq -r --arg marker "$MARKER" --arg user "$LABELLER" \
        '[.[] | select(.user.login == $user and (.body | startswith($marker)))] | last | .body // ""' \
        | sed -n 's/^Source: `\([0-9a-f]\{40\}\)`.*/\1/p'
}
upsert_comment() {
    local pr="$1" body="$MARKER"$'\n'"$2" existing id
    existing="$(comments_of "$pr" | jq -c --arg marker "$MARKER" --arg user "$LABELLER" \
        '[.[] | select(.user.login == $user and (.body | startswith($marker)))] | last // {}')" || return 1
    id="$(jq -r '.id // empty' <<< "$existing")"
    if [[ -z "$id" ]]; then
        gh api --method POST "repos/$repo/issues/$pr/comments" -f body="$body" > /dev/null
    elif [[ "$(jq -r .body <<< "$existing")" != "$body" ]]; then
        gh api --method PATCH "repos/$repo/issues/comments/$id" -f body="$body" > /dev/null
    fi
}
merged_pull_request() {
    api_list "repos/$repo/commits/$1/pulls?per_page=100" | jq -c --arg branch "$SOURCE_BRANCH" --arg commit "$1" \
        '[.[] | select(.merged_at != null and .base.ref == $branch and .merge_commit_sha == $commit)] | first // empty'
}
renovate_chart_dir() {
    local pull="$1" files directory
    jq -e --arg author "$RENOVATE_AUTHOR" --argjson eligible "$ELIGIBLE_UPDATE_LABELS" '.user.login == $author
        and any(.labels[]; .name as $label | $eligible | index($label) != null)
        and all(.labels[]; .name != "update:major")' <<< "$pull" > /dev/null || return 1
    files="$(pull_files "$(jq -r .number <<< "$pull")")" || return 1
    [[ -n "$files" ]] || return 1
    directory="$(jq -Rn --arg root "$CHARTS_ROOT" '[inputs] |
        if $root == "." then
          if all(. == "Chart.yaml" or . == "Chart.lock") then "." else empty end
        elif all(startswith($root + "/") and (split("/") | .[-1] == "Chart.yaml" or .[-1] == "Chart.lock")) then
          map(split("/") | .[0:-1] | join("/")) | unique | if length == 1 then .[0] else empty end
        else empty end' <<< "$files" | jq -r '. // empty')" || return 1
    [[ -n "$directory" ]] || return 1
    printf '%s\n' "$directory"
}
hydrated_chart_of() {
    pull_files "$1" | jq -Rsn --arg root "$MANIFEST_ROOT/" --arg layout "$LAYOUT" '
        inputs | split("\n") | map(select(length > 0)) |
        if length > 0 and all(startswith($root)) then
          if $layout != "multi-chart" then "root" else
            if all(ltrimstr($root) | split("/") | length > 1) then
              map(ltrimstr($root) | split("/")[0]) | unique | if length == 1 then .[0] else empty end
            else empty end
          end else empty end' | jq -r '. // empty'
}
canonical() {
    local directory="$1" file documents
    [[ -d "$directory" ]] || return 1
    while IFS= read -r file; do
        documents="$(yq -o=json -I=0 '
          (select(.kind == "CustomResourceDefinition") | .metadata.annotations) |= del(.["argocd.argoproj.io/sync-options"], .["argocd.argoproj.io/sync-wave"])
          | (select(.kind == "CustomResourceDefinition" and .metadata.annotations == {}) | .metadata) |= del(.annotations)
          | sort_keys(..)' "$directory/$file")" || return 1
        printf '== %s\n%s\n' "$file" "$documents"
    done < <(find "$directory" -type f \( -name '*.yaml' -o -name '*.yml' \) -printf '%P\n' | LC_ALL=C sort)
}
rendered() {
    local commit="$1" environment="$2" chart_dir="$3" chart tree output config release namespace values apis dependency repository
    commit="$(git rev-parse --verify "$commit^{commit}")" || return 1
    chart="$(git show "$commit:$chart_dir/Chart.yaml" | yq -r .name)" || return 1
    tree="$work/tree-$commit"
    output="$work/render-$commit-$environment-$chart"
    if [[ ! -f "$output.canonical" ]]; then
        if [[ ! -d "$tree" ]]; then
            git worktree add --quiet --detach "$tree" "$commit" || return 1
        fi
        config="$tree/$chart_dir/helm-config.yaml"
        release="$(yq -er 'explode(.) | .releaseName' "$config")" || return 1
        namespace="$(yq -er 'explode(.) | .namespace' "$config")" || return 1
        environment="$environment" yq -e 'explode(.) | .environments.[env(environment)] != null' "$config" > /dev/null || return 1
        local -a arguments=()
        values="$(environment="$environment" yq -r 'explode(.) | (.environments.[env(environment)].valueFiles // [])[]' "$config")" || return 1
        while IFS= read -r dependency; do
            [[ -z "$dependency" ]] || arguments+=(-f "$tree/$chart_dir/$dependency")
        done <<< "$values"
        apis="$(environment="$environment" yq -r 'explode(.) | (.environments.[env(environment)].apis // [])[]' "$config")" || return 1
        while IFS= read -r dependency; do
            [[ -z "$dependency" ]] || arguments+=(-a "$dependency")
        done <<< "$apis"
        while IFS= read -r repository; do
            [[ -z "$repository" ]] || helm repo add "steadops-$(printf '%s' "$repository" | sha256sum | cut -c1-12)" "$repository" > /dev/null || return 1
        done < <(yq -r '.dependencies[]?.repository | select(test("^https?://"))' "$tree/$chart_dir/Chart.yaml")
        helm dependency build "$tree/$chart_dir" > /dev/null || return 1
        mkdir -p "$output"
        [[ "$LAYOUT" != single-chart ]] || arguments+=(--release-name)
        helm template "$release" "$tree/$chart_dir" "${arguments[@]}" -n "$namespace" --include-crds --skip-tests --output-dir "$output" > /dev/null || return 1
        if [[ "$LAYOUT" != root-chart ]]; then
            find "$output" -type f -name '*.yaml' -exec yq -i '.' {} \; || return 1
        fi
        if [[ "$LAYOUT" == single-chart ]]; then
            canonical "$output" > "$output.canonical.tmp" || return 1
        else
            canonical "$output/$chart" > "$output.canonical.tmp" || return 1
        fi
        mv "$output.canonical.tmp" "$output.canonical"
    fi
    printf '%s\n' "$output.canonical"
}
hydrated() {
    local ref="$1" chart="$2" directory="$3" output release entry dependency
    output="$work/hydrated-$(printf '%s' "$ref" | tr '/' '-')-$chart"
    mkdir -p "$output/raw" "$output/tree"
    git archive "$ref" "$directory" | tar -x -C "$output/raw" || return 1
    if [[ "$LAYOUT" == multi-chart ]]; then
        release="$(find "$output/raw/$directory" -mindepth 1 -maxdepth 1 -type d)"
        [[ "$(printf '%s\n' "$release" | wc -l)" -eq 1 && -d "$release/$chart" ]] || return 1
        cp -r "$release/$chart/." "$output/tree/" || return 1
        for entry in "$release"/*; do
            [[ "$(basename "$entry")" == "$chart" ]] || cp -r "$entry" "$output/tree/" || return 1
        done
    else
        cp -r "$output/raw/$directory/." "$output/tree/" || return 1
        if [[ "$LAYOUT" == root-chart && -d "$output/tree/chartz" ]]; then
            dependency="$(git show "$4" | yq -er 'select(.dependencies | length == 1) | .dependencies[0] | .alias // .name')" || return 1
            [[ "$dependency" =~ ^[A-Za-z0-9_.-]+$ ]] || return 1
            mkdir -p "$output/tree/charts/$dependency"
            cp -r "$output/tree/chartz/." "$output/tree/charts/$dependency/" || return 1
            rm -rf "$output/tree/chartz"
        fi
    fi
    canonical "$output/tree" > "$output.canonical" || return 1
    printf '%s\n' "$output.canonical"
}
holds() {
    local pr="$1" source="$2" chart_dir="$3" pull environment chart directory before after deployed proposed link predecessor matched=false
    pull="$(gh api "repos/$repo/pulls/$pr")" || return 1
    [[ "$(jq -r .head.repo.full_name <<< "$pull")" == "$repo" ]] || return 1
    environment="$(jq -r .base.ref <<< "$pull")"
    [[ "$environment" == "$ENVIRONMENT_BRANCH_PREFIX"* ]] || return 1
    environment="${environment#"$ENVIRONMENT_BRANCH_PREFIX"}"
    [[ "$environment" =~ ^[A-Za-z0-9_.-]+$ ]] || return 1
    chart="$(git show "$source:$chart_dir/Chart.yaml" | yq -r .name)" || return 1
    directory="$MANIFEST_ROOT"
    if [[ "$LAYOUT" == multi-chart ]]; then
        [[ "$(hydrated_chart_of "$pr")" == "$chart" ]] || return 1
        directory="$directory/$chart"
    else
        [[ "$(hydrated_chart_of "$pr")" == root ]] || return 1
    fi
    git fetch --quiet origin "+refs/heads/$ENVIRONMENT_BRANCH_PREFIX$environment:refs/remotes/steadops-base/$pr" "+refs/pull/$pr/head:refs/remotes/steadops-pr/$pr" || return 1
    [[ "$(git rev-parse "refs/remotes/steadops-base/$pr")" == "$(jq -r .base.sha <<< "$pull")" ]] || return 1
    [[ "$(git rev-parse "refs/remotes/steadops-pr/$pr")" == "$(jq -r .head.sha <<< "$pull")" ]] || return 1
    after="$(rendered "$source" "$environment" "$chart_dir")" || return 1
    deployed="$(hydrated "refs/remotes/steadops-base/$pr" "$chart" "$directory" "$source:$chart_dir/Chart.yaml")" || return 1
    proposed="$(hydrated "refs/remotes/steadops-pr/$pr" "$chart" "$directory" "$source:$chart_dir/Chart.yaml")" || return 1
    cmp -s "$after" "$proposed" || return 1
    for link in $(git rev-list --first-parent --max-count="$MAX_CHAIN" "$source"); do
        predecessor="$(merged_pull_request "$link")" || return 1
        [[ -n "$predecessor" && "$(renovate_chart_dir "$predecessor")" == "$chart_dir" ]] || break
        before="$(rendered "$link^1" "$environment" "$chart_dir")" || return 1
        if cmp -s "$before" "$deployed"; then matched=true; break; fi
    done
    [[ "$matched" == true ]] || return 1
    [[ "$(gh api "repos/$repo/pulls/$pr" --jq '[.head.sha, .base.sha] | join(" ")')" == "$(jq -r '[.head.sha, .base.sha] | join(" ")' <<< "$pull")" ]] || return 1
    jq -r '"Head: `" + .head.sha + "`\nBase: `" + .base.sha + "`"' <<< "$pull"
}
cleanup() {
    local tree
    for tree in "$work"/tree-*; do
        [[ ! -d "$tree" ]] || git worktree remove --force "$tree"
    done
    rm -rf "$work"
}
main() {
    [[ "$#" -eq 1 && "$1" =~ ^[0-9a-f]{40}$ ]] || { echo 'Expected a full source commit SHA' >&2; return 1; }
    jq -e 'type == "array" and length > 0 and all(.[]; type == "string" and length > 0 and . != "update:major")' <<< "$ELIGIBLE_UPDATE_LABELS" > /dev/null || return 1
    [[ "$LAYOUT" == multi-chart || "$LAYOUT" == single-chart || "$LAYOUT" == root-chart ]] || return 1
    [[ "$CHARTS_ROOT" == . || "$CHARTS_ROOT" =~ ^[A-Za-z0-9_-]+(/[A-Za-z0-9_-]+)*$ ]] || return 1
    [[ "$MANIFEST_ROOT" =~ ^[A-Za-z0-9_-]+(/[A-Za-z0-9_-]+)*$ ]] || return 1
    [[ "$ENVIRONMENT_BRANCH_PREFIX" =~ ^[A-Za-z0-9_/-]+/$ ]] || return 1
    [[ "$LAYOUT" == multi-chart || "$CHARTS_ROOT" == . ]] || return 1
    git merge-base --is-ancestor "$1" "origin/$SOURCE_BRANCH" || return 1
    work="$(mktemp -d)"
    trap cleanup EXIT
    local open pull pr source chart_dir commit candidate chart snapshot
    gh label create "$LABEL" --repo "$repo" --force --color 0e8a16 --description 'Verified Renovate hydration; cluster gatekeepers may merge' > /dev/null
    open="$(api_list "repos/$repo/pulls?state=open&per_page=100")" || return 1
    while IFS= read -r pull; do
        pr="$(jq -r .number <<< "$pull")"
        source="$(source_of "$pr")" || return 1
        snapshot=''
        if [[ -n "$source" ]]; then
            candidate="$(merged_pull_request "$source")" || return 1
            if [[ -n "$candidate" ]] && chart_dir="$(renovate_chart_dir "$candidate")"; then
                snapshot="$(holds "$pr" "$source" "$chart_dir")" || snapshot=''
            fi
        fi
        if [[ -z "$snapshot" ]]; then
            gh pr edit "$pr" --repo "$repo" --remove-label "$LABEL" > /dev/null || return 1
            upsert_comment "$pr" 'Not merged automatically: verification no longer holds. Review and merge by hand.' || return 1
        fi
    done < <(jq -c --arg label "$LABEL" '.[] | select(any(.labels[]; .name == $label))' <<< "$open")
    local -A seen=()
    for commit in $(git rev-list --first-parent --max-count="$RECENT_COMMITS" "$1"); do
        candidate="$(merged_pull_request "$commit")" || return 1
        [[ -n "$candidate" ]] || continue
        chart_dir="$(renovate_chart_dir "$candidate")" || continue
        [[ -z "${seen[$chart_dir]:-}" ]] || continue
        seen[$chart_dir]=1
        chart="$(git show "$commit:$chart_dir/Chart.yaml" | yq -r .name)" || return 1
        while IFS= read -r pull; do
            pr="$(jq -r .number <<< "$pull")"
            [[ "$(hydrated_chart_of "$pr")" == "$chart" || ( "$LAYOUT" == root-chart && "$(hydrated_chart_of "$pr")" == root ) ]] || continue
            gh pr edit "$pr" --repo "$repo" --remove-label "$LABEL" > /dev/null || return 1
            if snapshot="$(holds "$pr" "$commit" "$chart_dir")"; then
                upsert_comment "$pr" "Source: \`$commit\` (#$(jq -r .number <<< "$candidate"), Renovate update of \`$chart\`)."$'\n'"$snapshot"$'\n\n'"Contains only the verified Renovate update or consecutive eligible updates of this chart." || return 1
                gh pr edit "$pr" --repo "$repo" --add-label "$LABEL" > /dev/null || return 1
            else
                upsert_comment "$pr" 'Not merged automatically: rendered baseline or proposed output does not match. Review and merge by hand.' || return 1
            fi
        done < <(jq -c --arg prefix "$ENVIRONMENT_BRANCH_PREFIX" '.[] | select(.base.ref | startswith($prefix))' <<< "$open")
    done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
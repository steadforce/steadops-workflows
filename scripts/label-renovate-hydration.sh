#!/usr/bin/env bash
# Labels hydration pull requests that carry exactly one eligible Renovate chart update, or an unbroken run of them, by rendering the chart as helm-hydration.yaml does; usage: label-renovate-hydration.sh <source commit>
set -euo pipefail

SOURCE_BRANCH="${SOURCE_BRANCH:-main}"
CHARTS_ROOT="${CHARTS_ROOT:-.}"
DISCOVERY_DEPTH="${DISCOVERY_DEPTH:-1}"
BUNDLE_PATCHES="${BUNDLE_PATCHES:-true}"
LAYOUT="${LAYOUT:-}"
RENOVATE_AUTHOR="${RENOVATE_AUTHOR:-renovate[bot]}"
ELIGIBLE_UPDATE_LABELS="${ELIGIBLE_UPDATE_LABELS:-}"
[[ -n "$ELIGIBLE_UPDATE_LABELS" ]] || ELIGIBLE_UPDATE_LABELS='["update:patch","update:minor"]'
RETRY_SECONDS="${RETRY_SECONDS:-10}"
readonly LABEL=renovate-hydration MARKER='<!-- renovate-hydration -->' LABELLER='github-actions[bot]'
readonly BLOCKED=gatekeeper-blocked GATEKEEPER_MARKER='<!-- gatekeeper-'
# Fixed in helm-hydration.yaml, so not inputs here.
readonly MANIFEST_ROOT=hydrated-manifests ENVIRONMENT_PREFIX=environments/ BRANCH_PREFIX=hydration-pull-request/
# Renovate updates of a chart often land faster than a cluster deploys them; this many in a row still count as one.
readonly MAX_CHAIN=10
# Runs that queue up replace each other, so every run looks back over recent merges instead of trusting one commit.
readonly RECENT_COMMITS=20
# Chart repositories time out now and then; one failed fetch should not cost an update its label.
readonly RENDER_ATTEMPTS=3
# The CRD post-processing of helm-hydration.yaml, verbatim.
readonly CRD_ANNOTATIONS='
    select(.kind == "CustomResourceDefinition" and
      .metadata.annotations["argocd.argoproj.io/sync-options"] == null)
      .metadata.annotations["argocd.argoproj.io/sync-options"] = "ServerSideApply=true" |
    select(.kind == "CustomResourceDefinition" and .metadata.annotations["argocd.argoproj.io/sync-options"] != null and
      (.metadata.annotations["argocd.argoproj.io/sync-options"] |
      contains("ServerSideApply=") | not))
      .metadata.annotations["argocd.argoproj.io/sync-options"] |= . + ",ServerSideApply=true" |
    select(.kind == "CustomResourceDefinition" and .metadata.annotations["argocd.argoproj.io/sync-wave"] == null)
      .metadata.annotations["argocd.argoproj.io/sync-wave"] = "-1"
'
repo="${GITHUB_REPOSITORY:?}"

api_list() { gh api "$1" --paginate --slurp | jq 'add // []'; }
pull_files() {
    if [[ -n "${2:-}" ]]; then
        git diff --no-ext-diff --no-textconv --no-renames --name-only "$2^1" "$2" --
    else
        api_list "repos/$repo/pulls/$1/files?per_page=100" | jq -er '
            if length >= 3000 then error("PR file list may be truncated")
            else [.[] | .filename, (.previous_filename // empty)] | unique[] end'
    fi
}
comments_of() { api_list "repos/$repo/issues/$1/comments?per_page=100"; }
labeller_comment() {
    comments_of "$1" | jq -c --arg marker "$MARKER" --arg user "$LABELLER" \
        '[.[] | select(.user.login == $user and (.body | startswith($marker)))] | last // {}'
}
source_of() {
    labeller_comment "$1" | jq -r '.body // ""' | sed -n 's/^Source: `\([0-9a-f]\{40\}\)`.*/\1/p' | head -1
}
upsert_comment() {
    local pr="$1" body="$MARKER"$'\n'"$2" existing id
    existing="$(labeller_comment "$pr")" || return 1
    id="$(jq -r '.id // empty' <<< "$existing")"
    if [[ -z "$id" ]]; then
        gh api --method POST "repos/$repo/issues/$pr/comments" -f body="$body" > /dev/null
    elif [[ "$(jq -r .body <<< "$existing")" != "$body" ]]; then
        gh api --method PATCH "repos/$repo/issues/comments/$id" -f body="$body" > /dev/null
    fi
}
# The gatekeepers stop maintaining a pull request once the label is gone, so their comment and block label would go stale.
release_from_gatekeepers() {
    local pr="$1" id body
    comments_of "$pr" | jq -r --arg marker "$GATEKEEPER_MARKER" --arg label "$LABEL" '.[] | select(.body | startswith($marker))
        | ((.body | split("\n") | first) + "\nNo longer handled by the gatekeepers: the `" + $label + "` label was removed, see the comment of the labeller.") as $new
        | select(.body != $new) | [.id, ($new | @base64)] | @tsv' \
        | while IFS=$'\t' read -r id body; do
            gh api --method PATCH "repos/$repo/issues/comments/$id" -f body="$(base64 -d <<< "$body")" > /dev/null
        done
    gh pr edit "$pr" --repo "$repo" --remove-label "$BLOCKED" > /dev/null 2>&1 || true
}
merged_pull_request() {
    api_list "repos/$repo/commits/$1/pulls?per_page=100" | jq -c --arg branch "$SOURCE_BRANCH" --arg commit "$1" \
        '[.[] | select(.merged_at != null and .base.ref == $branch and .merge_commit_sha == $commit)] | first // empty'
}

# A path inside a chart directory, which is . for a chart at the repository root.
in_chart() { if [[ "$1" == . ]]; then printf '%s\n' "$2"; else printf '%s/%s\n' "$1" "$2"; fi; }
# The chart directories helm-hydration.yaml discovers at a commit (find charts-root -maxdepth depth), without ./.
charts_at() {
    local root="${CHARTS_ROOT#./}"
    root="${root%/}"
    [[ "$root" != . ]] || root=""
    git ls-tree -r --name-only "$1" -- ${root:+"$root"} | jq -Rr --arg root "$root" --argjson depth "$DISCOVERY_DEPTH" '
        select(split("/")[-1] == "helm-config.yaml")
        | select((if $root == "" then . else ltrimstr($root + "/") end | split("/") | length) <= $depth)
        | split("/")[0:-1] | if length == 0 then "." else join("/") end'
}
multi_chart_at() { [[ "$(charts_at "$1" | wc -l)" -gt 1 ]]; }
chart_name() { git show "$1:$(in_chart "$2" Chart.yaml)" | yq 'explode(.) | .name'; }
# Where helm-hydration.yaml puts the chart's manifests on an environment branch.
manifest_dir() {
    if multi_chart_at "$1"; then
        printf '%s/%s\n' "$MANIFEST_ROOT" "$(chart_name "$1" "$2")"
    else
        printf '%s\n' "$MANIFEST_ROOT"
    fi
}
# The version in the chart's hydration branch name, read like helm-hydration.yaml does from the lock file of a rendered commit.
branch_version() {
    local tree="$work/tree-$1" chart_dir="$2" dependency version
    dependency="$(yq 'explode(.) | .primaryDependency // ""' "$tree/$(in_chart "$chart_dir" helm-config.yaml)")" || return 1
    [[ -n "$dependency" ]] || dependency="$(yq 'explode(.) | .name' "$tree/$(in_chart "$chart_dir" Chart.yaml)")" || return 1
    if [[ -f "$tree/$(in_chart "$chart_dir" Chart.lock)" ]]; then
        version="$(DEP_NAME="$dependency" yq '.dependencies[] | select(.name == strenv(DEP_NAME)) | .version' "$tree/$(in_chart "$chart_dir" Chart.lock)")" || return 1
    else
        version="$(yq 'explode(.) | .version' "$tree/$(in_chart "$chart_dir" Chart.yaml)")" || return 1
    fi
    [[ -n "$version" ]] || return 1
    if [[ "$BUNDLE_PATCHES" == true ]]; then
        version="$(cut -d. -f1,2 <<< "$version").x"
    fi
    printf '%s\n' "$version"
}
version_order() {
    jq -ner --arg left "$1" --arg right "$2" '
        def numeric: [length, .];
        def bundled:
            capture("^(?<major>0|[1-9][0-9]*)\\.(?<minor>0|[1-9][0-9]*)\\.x$")
            | [(.major | numeric), (.minor | numeric)];
        def semver:
            capture("^(?<major>0|[1-9][0-9]*)\\.(?<minor>0|[1-9][0-9]*)\\.(?<patch>0|[1-9][0-9]*)(?:-(?<pre>[0-9A-Za-z-]+(?:\\.[0-9A-Za-z-]+)*))?(?:\\+[0-9A-Za-z-]+(?:\\.[0-9A-Za-z-]+)*)?$") as $version
            | ($version.pre // "" | if . == "" then [] else split(".") end) as $pre
            | select(all($pre[]; (test("^[0-9]+$") | not) or test("^(0|[1-9][0-9]*)$")))
            | [($version.major | numeric), ($version.minor | numeric), ($version.patch | numeric),
               (if $pre == [] then 1 else 0 end),
               ($pre | map(if test("^[0-9]+$") then [0, numeric] else [1, .] end))];
        if ($left | endswith(".x")) and ($right | endswith(".x")) then
            [($left | bundled), ($right | bundled)]
        elif ($left | endswith(".x")) or ($right | endswith(".x")) then
            error("bundled and concrete versions are not comparable")
        else [($left | semver), ($right | semver)] end
        | select(length == 2)
        | if .[0] < .[1] then -1 elif .[0] > .[1] then 1 else 0 end'
}
# The chart directory, its file:// dependencies and value files: what a commit has to touch to change the chart's render.
chain_paths() {
    local commit="$1" chart_dir="$2" path
    {
        git show "$commit:$(in_chart "$chart_dir" Chart.yaml)" | yq -N -r 'explode(.) | .dependencies[]? | .repository | select(test("^file://")) | sub("^file://"; "")'
        git show "$commit:$(in_chart "$chart_dir" helm-config.yaml)" | yq -N -r 'explode(.) | .environments[]?.valueFiles[]?'
    } | while IFS= read -r path; do
        path="$(realpath -m --relative-to=. "$(in_chart "$chart_dir" "$path")")"
        [[ "$path" == ../* || "$path" == .. ]] || printf '%s\n' "$path"
    done | { printf '%s\n' "$chart_dir"; cat; } | LC_ALL=C sort -u
}

cache_key() { printf '%s\0' "$@" | sha256sum | cut -d' ' -f1; }
canonical() {
    local directory="$1" file
    [[ -d "$directory" ]] || return 0
    while IFS= read -r -d '' file; do
        printf '== %s\n' "$file"
        case "$file" in
            *.yaml|*.yml|*.json) yq -o=json -I=0 'sort_keys(..)' "$directory/$file" || return 1 ;;
            *) sha256sum < "$directory/$file" || return 1 ;;
        esac
    done < <(find "$directory" -type f -printf '%P\0' | LC_ALL=C sort -z)
}
# Up to three files whose documents differ between two canonical renders.
differing_files() {
    diff <(awk '/^== /{f=substr($0,4)} {print f "\t" $0}' "$1") <(awk '/^== /{f=substr($0,4)} {print f "\t" $0}' "$2") \
        | sed -n 's/^[<>] \([^\t]*\)\t.*/\1/p' | LC_ALL=C sort -u | head -3 | sed 's/.*/`&`/' | paste -sd, - | sed 's/,/, /g'
}
# Renders a chart for an environment into $3 the way helm-hydration.yaml does, from the root of a checkout.
render_tree() {
    local chart_dir="$1" environment="$2" output="$3" config release namespace repository apis value_files
    local -a arguments=()
    config="$(in_chart "$chart_dir" helm-config.yaml)"
    release="$(yq 'explode(.) | .releaseName // ""' "$config")" || return 1
    namespace="$(yq 'explode(.) | .namespace // ""' "$config")" || return 1
    [[ -n "$release" && -n "$namespace" ]] || { echo "$config names no releaseName or namespace" >&2; return 1; }
    while IFS= read -r repository; do
        [[ "$repository" == http://* || "$repository" == https://* ]] || continue
        grep -qxF "$repository" "$work/repositories" 2> /dev/null && continue
        helm repo add "repo-$(printf '%s' "$repository" | sha256sum | cut -c1-12)" "$repository" --force-update > /dev/null || return 1
        printf '%s\n' "$repository" >> "$work/repositories"
    done < <(yq -N -r 'explode(.) | .dependencies[]? | .repository' "$(in_chart "$chart_dir" Chart.yaml)")
    if [[ -f "$(in_chart "$chart_dir" Chart.lock)" ]]; then
        helm dependency build --skip-refresh "$chart_dir" > /dev/null || return 1
    else
        helm dependency update --skip-refresh "$chart_dir" > /dev/null || return 1
    fi
    apis="$(hydration="$environment" yq 'explode(.) | (.environments.[env(hydration)].apis // []) | @csv' "$config")" || return 1
    value_files="$(hydration="$environment" chart_dir="$chart_dir" yq 'explode(.) | (.environments.[env(hydration)].valueFiles // []) | map(env(chart_dir) + "/" + .) | @csv' "$config")" || return 1
    [[ -z "$apis" ]] || arguments+=(-a "$apis")
    [[ -z "$value_files" ]] || arguments+=(-f "$value_files")
    helm template "$release" "$chart_dir" "${arguments[@]}" -n "$namespace" \
        --output-dir "$output" --include-crds --release-name --skip-tests > /dev/null || return 1
    find "$output" -type f \( -name '*.yaml' -o -name '*.yml' \) -exec yq -i "$CRD_ANNOTATIONS" {} \; || return 1
}
# The canonical render of a chart at a commit for an environment, cached; empty where the commit does not hydrate it, status 2 when it cannot be rendered.
rendered() {
    local commit environment="$2" chart_dir="$3" tree output attempt
    commit="$(git rev-parse --verify --quiet "$1^{commit}")" || return 2
    tree="$work/tree-$commit"
    output="$work/render-$commit-$(cache_key "$environment" "$chart_dir")"
    if [[ ! -f "$output.canonical" ]]; then
        if ! git show "$commit:$(in_chart "$chart_dir" helm-config.yaml)" 2> /dev/null \
            | environment="$environment" yq -e 'explode(.) | .environments.[env(environment)] != null' > /dev/null 2>&1; then
            : > "$output.canonical"
            printf '%s\n' "$output.canonical"
            return 0
        fi
        [[ -d "$tree" ]] || git worktree add --quiet --detach "$tree" "$commit" || return 2
        for (( attempt = 1; ; attempt++ )); do
            rm -rf "$output"
            (cd "$tree" && render_tree "$chart_dir" "$environment" "$output") && break
            (( attempt < RENDER_ATTEMPTS )) || return 2
            sleep "$RETRY_SECONDS"
        done
        canonical "$output" > "$output.canonical.tmp" || return 2
        mv "$output.canonical.tmp" "$output.canonical"
    fi
    printf '%s\n' "$output.canonical"
}
# The canonical manifests in a directory of an environment branch ref; empty where the directory does not exist.
hydrated() {
    local ref="$1" directory="$2" output commit entry metadata mode type object path
    commit="$(git rev-parse --verify "$ref^{tree}")" || return 2
    output="$work/hydrated-$commit-$(cache_key "$directory")"
    if [[ ! -f "$output.canonical" ]]; then
        mkdir -p "$output"
        git ls-tree -r -z "$commit" -- "$directory" > "$output.tree" || return 2
        while IFS= read -r -d '' entry; do
            metadata="${entry%%$'\t'*}"
            path="${entry#*$'\t'}"
            read -r mode type object <<< "$metadata"
            if [[ "$type" != blob || ( "$mode" != 100644 && "$mode" != 100755 ) ]]; then
                echo "Unsupported Git entry in manifests: $path ($mode $type)" >&2
                return 2
            fi
            mkdir -p "$output/$(dirname "$path")" || return 2
            git cat-file blob "$object" > "$output/$path" || return 2
        done < "$output.tree"
        canonical "$output/$directory" > "$output.canonical.tmp" || return 2
        mv "$output.canonical.tmp" "$output.canonical"
    fi
    printf '%s\n' "$output.canonical"
}

# The chart directory an eligible Renovate pull request merged as a commit updates, or the reason on stderr.
renovate_chart_dir() {
    local pull="$1" commit="$2" files directory
    if [[ "$(jq -r .user.login <<< "$pull")" != "$RENOVATE_AUTHOR" ]]; then
        echo "it was opened by $(jq -r .user.login <<< "$pull"), not $RENOVATE_AUTHOR" >&2
        return 1
    fi
    if ! jq -e --argjson eligible "$ELIGIBLE_UPDATE_LABELS" 'any(.labels[]; .name as $label | $eligible | index($label) != null)
        and all(.labels[]; .name != "update:major")' <<< "$pull" > /dev/null; then
        echo "its update type is not one of $(jq -r 'join(", ")' <<< "$ELIGIBLE_UPDATE_LABELS")" >&2
        return 1
    fi
    files="$(pull_files "$(jq -r .number <<< "$pull")" "$commit")" || return 1
    directory="$(jq -Rsr 'split("\n") | map(select(length > 0))
        | if length > 0 and all(test("(^|/)Chart\\.(yaml|lock)$")) then
            map(split("/")[0:-1] | if length == 0 then "." else join("/") end) | unique | if length == 1 then .[0] else "" end
          else "" end' <<< "$files")"
    if [[ -z "$directory" ]]; then
        echo "it changes more than one chart's Chart.yaml and Chart.lock" >&2
        return 1
    fi
    if ! charts_at "$commit" | grep -qxF -- "$directory"; then
        echo "\`$directory\` is not a chart the hydration discovers below \`$CHARTS_ROOT\`" >&2
        return 1
    fi
    printf '%s\n' "$directory"
}

# Whether pull request $1 is exactly the update merged as $2 of chart $3, or a run of Renovate updates ending in it.
# 0 it is (HOLDS_HEAD, HOLDS_BASE, HOLDS_EARLIER); 1 it is not (HOLDS_REASON); 2 it could not be checked.
holds() {
    local pr="$1" source="$2" chart_dir="$3" pull environment directory path count=0 after deployed proposed merged before at link link_pr matched="" ended=""
    local -a earlier=()
    HOLDS_HEAD="" HOLDS_BASE="" HOLDS_EARLIER="" HOLDS_REASON=""
    pull="$(gh api "repos/$repo/pulls/$pr")" || return 2
    if [[ "$(jq -r .head.repo.full_name <<< "$pull")" != "$repo" ]]; then
        HOLDS_REASON="its branch is not in $repo"
        return 1
    fi
    environment="$(jq -r .base.ref <<< "$pull")"
    if [[ "$environment" != "$ENVIRONMENT_PREFIX"* ]]; then
        HOLDS_REASON="it does not target an environment branch"
        return 1
    fi
    environment="${environment#"$ENVIRONMENT_PREFIX"}"
    directory="$(manifest_dir "$source" "$chart_dir")" || return 2
    HOLDS_HEAD="$(jq -r .head.sha <<< "$pull")"
    HOLDS_BASE="$(jq -r .base.sha <<< "$pull")"
    git fetch --quiet origin "+refs/heads/$ENVIRONMENT_PREFIX$environment:refs/remotes/steadops-base/$pr" "+refs/pull/$pr/head:refs/remotes/steadops-pr/$pr" || return 2
    [[ "$(git rev-parse "refs/remotes/steadops-base/$pr")" == "$HOLDS_BASE" && "$(git rev-parse "refs/remotes/steadops-pr/$pr")" == "$HOLDS_HEAD" ]] || return 2
    git diff --no-ext-diff --no-textconv --no-renames --name-only -z "$HOLDS_BASE...$HOLDS_HEAD" -- > "$work/paths-$pr" || return 2
    while IFS= read -r -d '' path; do
        if [[ "$path" != "$directory/"* ]]; then
            HOLDS_REASON="it changes files outside \`$directory\`"
            return 1
        fi
        count=$((count + 1))
    done < "$work/paths-$pr"
    if [[ "$count" -eq 0 ]]; then
        HOLDS_REASON="it has no changed files"
        return 1
    fi
    if ! merged="$(git merge-tree --write-tree "$HOLDS_BASE" "$HOLDS_HEAD")"; then
        HOLDS_REASON="its merge into the checked base has conflicts or cannot be verified"
        return 1
    fi
    git diff --no-ext-diff --no-textconv --no-renames --name-only -z "$HOLDS_BASE" "$merged" -- > "$work/merge-paths-$pr" || return 2
    while IFS= read -r -d '' path; do
        if [[ "$path" != "$directory/"* ]]; then
            HOLDS_REASON="its merge changes files outside \`$directory\`"
            return 1
        fi
    done < "$work/merge-paths-$pr"
    after="$(rendered "$source" "$environment" "$chart_dir")" || return 2
    deployed="$(hydrated "refs/remotes/steadops-base/$pr" "$directory")" || return 2
    proposed="$(hydrated "$merged" "$directory")" || return 2
    # Back from source while every commit is an eligible Renovate update of the chart or leaves this environment's render alone, until the branch matches.
    for link in $(git rev-list --first-parent --max-count="$MAX_CHAIN" "$source"); do
        git rev-parse --verify --quiet "$link^1" > /dev/null || break
        if [[ "$link" != "$source" ]]; then
            link_pr="$(merged_pull_request "$link")" || return 2
            if [[ -n "$link_pr" && "$(renovate_chart_dir "$link_pr" "$link" 2> /dev/null)" == "$chart_dir" ]]; then
                earlier+=("#$(jq -r .number <<< "$link_pr")")
            else
                at="$(rendered "$link" "$environment" "$chart_dir")" || return 2
                before="$(rendered "$link^1" "$environment" "$chart_dir")" || return 2
                if ! cmp -s "$at" "$before"; then
                    ended="${link:0:7}"
                    break
                fi
            fi
        fi
        before="$(rendered "$link^1" "$environment" "$chart_dir")" || return 2
        if cmp -s "$before" "$deployed"; then
            matched="$link"
            break
        fi
    done
    if [[ -z "$matched" ]]; then
        before="$(rendered "$source^1" "$environment" "$chart_dir")" || return 2
        HOLDS_REASON="\`$ENVIRONMENT_PREFIX$environment\` differs from the chart rendered just before the update, in $(differing_files "$before" "$deployed"), and no run of Renovate updates${ended:+ back to $ended, a commit that is not one and changes this environment,} explains it: an earlier change is not deployed yet, or the branch holds an older rendering, so the pull request carries that difference too"
        return 1
    fi
    if ! cmp -s "$after" "$proposed"; then
        HOLDS_REASON="it differs from the chart rendered with the update, in $(differing_files "$after" "$proposed"): a later commit changed the chart as well"
        return 1
    fi
    [[ "$(gh api "repos/$repo/pulls/$pr" --jq '[.head.sha, .base.sha] | join(" ")')" == "$HOLDS_HEAD $HOLDS_BASE" ]] || return 2
    HOLDS_EARLIER="${earlier[*]}"
}

# Labels a pull request holds() vouched for and records the source, head and base the gatekeepers check.
accept() {
    local pr="$1" labelled="$2" source="$3" source_pr="$4" chart="$5" body
    body="Source: \`$source\` (#$source_pr, Renovate update of \`$chart\`)."$'\n'"Head: \`$HOLDS_HEAD\`"$'\n'"Base: \`$HOLDS_BASE\`"$'\n\n'
    if [[ -n "$HOLDS_EARLIER" ]]; then
        body+="Carries this update and the earlier Renovate updates $HOLDS_EARLIER of the same chart, which its environment branch does not have yet, and nothing else, so the gatekeeper of its cluster may merge it."
    else
        body+="Carries this update and nothing else, so the gatekeeper of its cluster may merge it."
    fi
    upsert_comment "$pr" "$body" || return 1
    [[ "$labelled" == true ]] || gh pr edit "$pr" --repo "$repo" --add-label "$LABEL" > /dev/null
}
# Takes the label off a pull request, says why and hands it back from the gatekeepers.
refuse() {
    local pr="$1" labelled="$2" reason="$3"
    echo "::warning::#$pr: $reason"
    [[ "$labelled" != true ]] || gh pr edit "$pr" --repo "$repo" --remove-label "$LABEL" > /dev/null || return 1
    upsert_comment "$pr" "Not merged automatically: $reason. Review it and merge by hand." || return 1
    release_from_gatekeepers "$pr"
}
# Checks a pull request and labels or refuses it; a failed check leaves it as it is until the next run.
verify() {
    local pr="$1" labelled="$2" source="$3" candidate="$4" chart_dir="$5" status=0
    holds "$pr" "$source" "$chart_dir" || status=$?
    case "$status" in
        0) echo "#$pr carries the update from ${source:0:7}${HOLDS_EARLIER:+ with $HOLDS_EARLIER}"
           accept "$pr" "$labelled" "$source" "$(jq -r .number <<< "$candidate")" "$(chart_name "$source" "$chart_dir")" ;;
        1) refuse "$pr" "$labelled" "$HOLDS_REASON" ;;
        *) echo "::warning::#$pr could not be checked against ${source:0:7}, see the log; left as it is" ;;
    esac
}

# Checks the hydration pull requests of one Renovate update, and takes the label off older versions it supersedes.
label_update() {
    local commit="$1" candidate="$2" chart_dir="$3" chart suffix="" pull pr environment labelled version found=0 other newer order
    chart="$(chart_name "$commit" "$chart_dir")"
    ! multi_chart_at "$commit" || suffix="-$chart"
    while IFS= read -r pull; do
        pr="$(jq -r .number <<< "$pull")"
        environment="$(jq -r .base.ref <<< "$pull")"
        environment="${environment#"$ENVIRONMENT_PREFIX"}"
        other="$(jq -r --arg prefix "$BRANCH_PREFIX$environment$suffix-" \
            '.head.ref | select(startswith($prefix)) | ltrimstr($prefix) | select(test("^[0-9]+\\.[0-9]+\\."))' <<< "$pull")"
        [[ -n "$other" ]] || continue
        found=$((found + 1))
        labelled=false
        ! jq -e --arg label "$LABEL" 'any(.labels[]; .name == $label)' <<< "$pull" > /dev/null || labelled=true
        if ! rendered "$commit" "$environment" "$chart_dir" > /dev/null || ! version="$(branch_version "$commit" "$chart_dir")"; then
            echo "::warning::$chart could not be rendered at ${commit:0:7} for $environment, see the log; #$pr left as it is"
            continue
        fi
        if [[ "$other" != "$version" ]]; then
            if ! order="$(version_order "$other" "$version")"; then
                echo "::warning::#$pr version $other cannot be ordered against $version; deferred to its recorded source"
                continue
            fi
            if [[ "$order" -ge 0 ]]; then
                echo "#$pr is $other, not older than the update's $version; deferred to its recorded source"
                continue
            fi
            newer="$(jq -r --arg head "$BRANCH_PREFIX$environment$suffix-$version" --arg base "$ENVIRONMENT_PREFIX$environment" --arg version "$version" \
                '[.[] | select(.head.ref == $head and .base.ref == $base) | "#\(.number) (`\($version)`)"] | first // empty' <<< "$open")"
            handled[$pr]=1
            refuse "$pr" "$labelled" "superseded by ${newer:-the pull request for \`$version\`}, which the update from \`$commit\` (#$(jq -r .number <<< "$candidate")) goes into; the gatekeepers only merge that one. Merge this one by hand only to deploy \`$other\` first; it is closed once a newer version is merged" || return 1
            continue
        fi
        handled[$pr]=1
        verify "$pr" "$labelled" "$commit" "$candidate" "$chart_dir" || return 1
    done < <(jq -c '.[]' <<< "$open")
    [[ "$found" -gt 0 ]] || echo "No open hydration pull request for $chart: the update renders no change or is deployed"
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
    jq -e 'type == "array" and length > 0 and all(.[]; type == "string" and length > 0 and . != "update:major")' <<< "$ELIGIBLE_UPDATE_LABELS" > /dev/null \
        || { echo 'eligible-update-labels must be a JSON array of labels other than update:major' >&2; return 1; }
    [[ "$CHARTS_ROOT" == . || "$CHARTS_ROOT" =~ ^(\./)?[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)*/?$ ]] || { echo "charts-root '$CHARTS_ROOT' is not a relative path" >&2; return 1; }
    [[ "$DISCOVERY_DEPTH" =~ ^[1-9][0-9]*$ ]] || { echo 'chart-discovery-depth must be a positive number' >&2; return 1; }
    [[ "$BUNDLE_PATCHES" == true || "$BUNDLE_PATCHES" == false ]] || { echo 'bundle-patches-in-one-pr must be true or false' >&2; return 1; }
    git merge-base --is-ancestor "$1" "origin/$SOURCE_BRANCH" || { echo "$1 is not on $SOURCE_BRANCH" >&2; return 1; }
    local charts derived
    charts="$(charts_at "$1")"
    [[ -n "$charts" ]] || { echo "No helm-config.yaml below '$CHARTS_ROOT' within depth $DISCOVERY_DEPTH; set charts-root and chart-discovery-depth as in the hydration call" >&2; return 1; }
    derived=single-chart
    ! multi_chart_at "$1" || derived=multi-chart
    # layout is derived like helm-hydration.yaml does; one set by a caller only has to agree.
    if [[ -n "$LAYOUT" && "$LAYOUT" != "$derived" ]]; then
        echo "layout '$LAYOUT' does not match the $(wc -l <<< "$charts") chart(s) found below '$CHARTS_ROOT' within depth $DISCOVERY_DEPTH ($derived); set charts-root and chart-discovery-depth as in the hydration call" >&2
        return 1
    fi
    work="$(mktemp -d)"
    trap cleanup EXIT
    local pull pr source candidate chart_dir commit labelled
    local -A seen=()
    declare -gA handled=()
    gh label create "$LABEL" --repo "$repo" --force --color 0e8a16 --description 'Verified Renovate hydration; cluster gatekeepers may merge' > /dev/null
    open="$(api_list "repos/$repo/pulls?state=open&per_page=100" | jq -c --arg environment "$ENVIRONMENT_PREFIX" --arg branch "$BRANCH_PREFIX" \
        '[.[] | select((.base.ref | startswith($environment)) and (.head.ref | startswith($branch)))]')" || return 1

    echo "::group::Renovate updates among the last $RECENT_COMMITS commits of $SOURCE_BRANCH up to ${1:0:7}"
    for commit in $(git rev-list --first-parent --max-count="$RECENT_COMMITS" "$1"); do
        candidate="$(merged_pull_request "$commit")" || return 1
        [[ -n "$candidate" ]] || continue
        if ! chart_dir="$(renovate_chart_dir "$candidate" "$commit" 2> "$work/reason")"; then
            [[ "$commit" != "$1" ]] || echo "#$(jq -r .number <<< "$candidate") is left to a person: $(< "$work/reason")"
            continue
        fi
        # Only the newest update of a chart can match its hydration pull request.
        [[ -z "${seen[$chart_dir]:-}" ]] || continue
        seen[$chart_dir]=1
        echo "#$(jq -r .number <<< "$candidate") (${commit:0:7}) updates $chart_dir"
        label_update "$commit" "$candidate" "$chart_dir" || return 1
    done
    echo "::endgroup::"
    echo "::group::Other labelled pull requests, against their recorded source"
    while IFS= read -r pull; do
        pr="$(jq -r .number <<< "$pull")"
        # Already checked against the newest update of its chart above.
        [[ -z "${handled[$pr]:-}" ]] || continue
        source="$(source_of "$pr")" || return 1
        if [[ -z "$source" ]] || ! git cat-file -e "$source^{commit}" 2> /dev/null; then
            refuse "$pr" true "it carries no source commit of the labeller" || return 1
            continue
        fi
        candidate="$(merged_pull_request "$source")" || return 1
        if [[ -z "$candidate" ]]; then
            refuse "$pr" true "its source \`$source\` is not a pull request merged into $SOURCE_BRANCH" || return 1
            continue
        fi
        if ! chart_dir="$(renovate_chart_dir "$candidate" "$source" 2> "$work/reason")"; then
            refuse "$pr" true "#$(jq -r .number <<< "$candidate") is not eligible: $(< "$work/reason")" || return 1
            continue
        fi
        verify "$pr" true "$source" "$candidate" "$chart_dir" || return 1
    done < <(jq -c --arg label "$LABEL" '.[] | select(any(.labels[]; .name == $label))' <<< "$open")
    echo "::endgroup::"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi

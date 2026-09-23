#!/usr/bin/env bash
#
# Regenerates the golden manifests that the hydration workflow is tested
# against. The rendering steps mirror the `Hydrate` step of
# .github/workflows/helm-hydration.yaml, which remains the source of truth.
#
# Run this after intentionally changing a fixture, the rendering logic or the
# pinned Helm version, then review the resulting diff before committing it.
#
# Usage: tests/regenerate-golden.sh
#
set -euo pipefail

# Helm renders trailing whitespace differently between releases, so the goldens
# are only valid for one Helm version. Keep this in sync with the helm-version
# input in .github/workflows/test-helm-hydration.yaml.
readonly EXPECTED_HELM_VERSION="v3.19.0"

# Each entry is "<charts-root>:<discovery-depth>" and matches one call of the
# hydration workflow in the test workflow.
readonly ROOTS=(
  "tests/fixtures/single-chart:1"
  "tests/fixtures/monorepo:2"
)

cd "$(dirname "$0")/.."

installed_version=$(helm version --template '{{ .Version }}')
if [ "$installed_version" != "$EXPECTED_HELM_VERSION" ]; then
  echo "Helm $EXPECTED_HELM_VERSION is required to regenerate the goldens, found $installed_version." >&2
  exit 1
fi

# Rendering happens inside the repository rather than in the system temp
# directory, so the script also works where yq is installed as a confined
# package without access to /tmp.
readonly WORK_DIR=".golden-tmp"
trap 'rm -rf "$WORK_DIR"' EXIT
rm -rf "$WORK_DIR" tests/golden
mkdir -p tests/golden

for root_spec in "${ROOTS[@]}"; do
  charts_root="${root_spec%:*}"
  depth="${root_spec##*:}"

  configs=()
  while IFS= read -r -d '' config; do
    configs+=("$config")
  done < <(find "$charts_root" -maxdepth "$depth" -name helm-config.yaml -print0 | sort -z)

  for config in "${configs[@]}"; do
    chart_dir=$(dirname "$config")
    chart_name=$(yq 'explode(.) | .name' "$chart_dir/Chart.yaml")
    release_name=$(yq 'explode(.) | .releaseName' "$config")
    namespace=$(yq 'explode(.) | .namespace' "$config")

    helm dependency build "$chart_dir" > /dev/null

    while IFS= read -r environment; do
      output_dir="$WORK_DIR/$chart_name-$environment"
      mkdir -p "$output_dir"
      apis=$(hydration="$environment" yq 'explode(.) | (.environments.[env(hydration)].apis // []) | @csv' "$config")
      value_files=$(hydration="$environment" chart_dir="$chart_dir" yq 'explode(.) | (.environments.[env(hydration)].valueFiles // []) | map(env(chart_dir) + "/" + .) | @csv' "$config")

      helm_args=()
      if [ -n "$apis" ]; then
        helm_args+=(-a "$apis")
      fi
      if [ -n "$value_files" ]; then
        helm_args+=(-f "$value_files")
      fi

      helm template "$release_name" "$chart_dir" \
        "${helm_args[@]}" \
        -n "$namespace" \
        --output-dir "$output_dir" \
        --include-crds \
        --release-name \
        --skip-tests > /dev/null

      find "$output_dir" -type f \( -name "*.yaml" -o -name "*.yml" \) -exec yq -i '
        select(.kind == "CustomResourceDefinition" and
          .metadata.annotations["argocd.argoproj.io/sync-options"] == null)
          .metadata.annotations["argocd.argoproj.io/sync-options"] = "ServerSideApply=true" |
        select(.kind == "CustomResourceDefinition" and .metadata.annotations["argocd.argoproj.io/sync-options"] != null and
          (.metadata.annotations["argocd.argoproj.io/sync-options"] |
          contains("ServerSideApply=") | not))
          .metadata.annotations["argocd.argoproj.io/sync-options"] |= . + ",ServerSideApply=true" |
        select(.kind == "CustomResourceDefinition" and .metadata.annotations["argocd.argoproj.io/sync-wave"] == null)
          .metadata.annotations["argocd.argoproj.io/sync-wave"] = "-1"
      ' {} \;

      # The golden directory holds what the workflow publishes as the artifact
      # `hydrated-<chart>-<environment>`.
      golden_dir="tests/golden/hydrated-${chart_name}-${environment}"
      mkdir -p "$golden_dir"
      mv "$output_dir"/* "$golden_dir/"
      echo "wrote $golden_dir"
    done < <(yq -r 'explode(.) | .environments | keys | .[]' "$config")
  done
done

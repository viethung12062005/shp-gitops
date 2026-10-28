#!/usr/bin/env bash
# Validate the GitOps repo: valid YAML, clusters/uat <-> prod differ only by environment name, render the base chart + 8 services x 2 environments,
# kubeconform (with CRD schemas). Usage: tools/validate.sh [--strict]   (--strict: fail if any "ĐIỀN" (fill-in) placeholder is left empty)
# Variable: TEMPLATES_DIR = a clone of shp-platform-templates (contains charts/microservice).
set -euo pipefail
cd "$(dirname "$0")/.."
STRICT=${1:-}
TEMPLATES_DIR=${TEMPLATES_DIR:-../shp-platform-templates}
CHART="$TEMPLATES_DIR/charts/microservice"
OUT=$(mktemp -d); trap 'rm -rf "$OUT"' EXIT
fail=0
SCHEMAS=(-schema-location default -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json')

echo "== 1. Valid YAML"
python3 -I - <<'PY'
import glob, sys, yaml
bad = 0
for f in glob.glob("**/*.yaml", recursive=True):
    if "/templates/" in f: continue
    try: list(yaml.safe_load_all(open(f)))
    except Exception as e: print("  ", f, e); bad += 1
sys.exit(bad)
PY

echo "== 2. clusters/prod = clusters/uat (replace 'uat' -> 'prod')"
for f in clusters/uat/*.yaml; do
  diff <(grep -v '^ *#' "$f" | sed 's/uat/prod/g') <(grep -v '^ *#' "clusters/prod/$(basename "$f")") >/dev/null || { echo "  mismatch: $(basename "$f")"; fail=1; }
done

echo "== 3. Render + kubeconform"
for env in uat prod; do
  helm template shp-baseline platform/charts/shp-baseline -f "envs/$env/platform.yaml" \
    --set acrLoginServer=acrshpci.azurecr.io --set gateway.hostname=api.$env.example.org --set gateway.acmeEmail=ci@example.org \
    > "$OUT/baseline-$env.yaml"
  for d in envs/$env/*/; do
    svc=$(basename "$d"); [ "$svc" = addons ] && continue
    helm template "$svc" "$CHART" -f envs/services-common.yaml -f "envs/$env/services.yaml" -f "$d/values.yaml" \
      --set fullnameOverride="$svc" --set image.repository="acrshpci.azurecr.io/$svc" \
      --set image.digest="sha256:$(printf '0%.0s' {1..64})" > "$OUT/$env-$svc.yaml" || { echo "  render failed: $env/$svc"; fail=1; }
  done
done
kubeconform -strict -summary "${SCHEMAS[@]}" "$OUT"/*.yaml clusters/*/*.yaml bootstrap/root-*.yaml || fail=1

echo "== 4. Required placeholders still empty"
empty=$(grep -rnE '^\s*(acrLoginServer|hostname|acmeEmail|OIDC_AUTHORITY|OIDC_AUDIENCE|repository): ""' envs || true)
if [ -n "$empty" ]; then
  echo "$empty" | sed 's/^/  /'
  [ "$STRICT" = --strict ] && { echo "  --strict: must be filled in before provisioning an environment"; fail=1; } || echo "  (warning; fill in before provisioning an environment)"
fi
[ $fail = 0 ] && echo "OK" || { echo "FAILED"; exit 1; }

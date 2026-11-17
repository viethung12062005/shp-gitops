#!/usr/bin/env bash
# Validate the GitOps repo: valid YAML, clusters/uat <-> prod differ only by environment name, render the base chart + 8 services x 2 environments,
# kubeconform (with CRD schemas). Usage: tools/validate.sh [--strict]   (--strict: fail if any "FILL IN" placeholder is left empty)
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
  helm template mlflow platform/charts/mlflow -f "envs/$env/addons/mlflow.yaml" \
    --set image.repository=acrshpci.azurecr.io/mlflow --set image.digest="sha256:$(printf '0%.0s' {1..64})" \
    --set workloadIdentity.clientId=00000000-0000-0000-0000-000000000000 --set database.host=psql-ci.postgres.database.azure.com \
    --set database.user=id-ci-mlflow --set artifacts.storageAccount=stci > "$OUT/mlflow-$env.yaml" || { echo "  render failed: $env/mlflow"; fail=1; }
  helm template ml-retrain platform/charts/ml-retrain -f "envs/$env/addons/ml-retrain.yaml" \
    --set image.repository=acrshpci.azurecr.io/ml-train --set image.digest="sha256:$(printf '0%.0s' {1..64})" > "$OUT/ml-retrain-$env.yaml" \
    || { echo "  render failed: $env/ml-retrain"; fail=1; }
  # Without a digest the chart must render nothing (no CronJob that cannot pull an image).
  [ -z "$(helm template ml-retrain platform/charts/ml-retrain -f "envs/$env/addons/ml-retrain.yaml" | grep -vE '^(#|---|\s*$)')" ] \
    || { echo "  ml-retrain renders objects without an image digest ($env)"; fail=1; }
  for d in envs/$env/*/; do
    svc=$(basename "$d"); [ "$svc" = addons ] && continue
    helm template "$svc" "$CHART" -f envs/services-common.yaml -f "envs/$env/services.yaml" -f "$d/values.yaml" \
      --set fullnameOverride="$svc" --set image.repository="acrshpci.azurecr.io/$svc" \
      --set image.digest="sha256:$(printf '0%.0s' {1..64})" --set workloadIdentity.clientId=00000000-0000-0000-0000-000000000000       > "$OUT/$env-$svc.yaml" || { echo "  render failed: $env/$svc"; fail=1; }
  done
done
echo "== 3b. Retraining cannot overlap (rendered CronJob)"
python3 -I - "$OUT" <<'PY' || fail=1
import glob, sys, yaml
bad = 0
for f in sorted(glob.glob(sys.argv[1] + "/ml-retrain-*.yaml")):
    docs = [d for d in yaml.safe_load_all(open(f)) if d]
    cj = [d for d in docs if d["kind"] == "CronJob"]
    if len(cj) != 1: print("  ", f, "expected exactly one CronJob"); bad += 1; continue
    s = cj[0]["spec"]; job = s["jobTemplate"]["spec"]; c = job["template"]["spec"]["containers"][0]
    checks = {
        "concurrencyPolicy is Forbid": s["concurrencyPolicy"] == "Forbid",
        "not suspended": s["suspend"] is False,
        "backoffLimit is 0 (a failed run is not retried behind its back)": job["backoffLimit"] == 0,
        "activeDeadlineSeconds is below the 7200 s lock lease": 0 < job["activeDeadlineSeconds"] < 7200,
        "restartPolicy is Never": job["template"]["spec"]["restartPolicy"] == "Never",
        "runs python -m shp_ml.retrain": c["command"][:3] == ["python", "-m", "shp_ml.retrain"],
        "image is pinned by digest": "@sha256:" in c["image"],
        "no literal MONGODB_URI": all(e["name"] != "MONGODB_URI" or "valueFrom" in e for e in c["env"]),
    }
    for name, ok in checks.items():
        if not ok: print("  ", f, "FAILED:", name); bad += 1
sys.exit(1 if bad else 0)
PY
kubeconform -strict -summary "${SCHEMAS[@]}" "$OUT"/*.yaml clusters/*/*.yaml bootstrap/root-*.yaml || fail=1

echo "== 4. Required placeholders still empty"
empty=$(grep -rnE '^\s*(acrLoginServer|hostname|acmeEmail|OIDC_AUTHORITY|OIDC_AUDIENCE|repository|clientId|SPRING_DATASOURCE_URL|SPRING_DATASOURCE_USERNAME|storageAccount|host|user): ""' envs || true)
# Web app runtime config (JSON inside envs/<env>/web/values.yaml): login server and SPA client ID.
web_empty=$(grep -rnE '"(authority|clientId)": ""' envs || true)
empty=$(printf '%s\n%s\n' "$empty" "$web_empty" | sed '/^$/d')
if [ -n "$empty" ]; then
  echo "$empty" | sed 's/^/  /'
  [ "$STRICT" = --strict ] && { echo "  --strict: must be filled in before provisioning an environment"; fail=1; } || echo "  (warning; fill in before provisioning an environment)"
fi
[ $fail = 0 ] && echo "OK" || { echo "FAILED"; exit 1; }

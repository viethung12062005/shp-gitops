#!/usr/bin/env bash
# Kiểm tra repo GitOps: YAML hợp lệ, clusters/uat ↔ prod chỉ khác tên môi trường, render chart nền + 8 service × 2 môi trường,
# kubeconform (kèm schema CRD). Dùng: tools/validate.sh [--strict]   (--strict: lỗi nếu còn ô "ĐIỀN" bỏ trống)
# Biến: TEMPLATES_DIR = bản clone shp-platform-templates (chứa charts/microservice).
set -euo pipefail
cd "$(dirname "$0")/.."
STRICT=${1:-}
TEMPLATES_DIR=${TEMPLATES_DIR:-../shp-platform-templates}
CHART="$TEMPLATES_DIR/charts/microservice"
OUT=$(mktemp -d); trap 'rm -rf "$OUT"' EXIT
fail=0
SCHEMAS=(-schema-location default -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json')

echo "== 1. YAML hợp lệ"
python3 -I - <<'PY'
import glob, sys, yaml
bad = 0
for f in glob.glob("**/*.yaml", recursive=True):
    if "/templates/" in f: continue
    try: list(yaml.safe_load_all(open(f)))
    except Exception as e: print("  ", f, e); bad += 1
sys.exit(bad)
PY

echo "== 2. clusters/prod = clusters/uat (thay 'uat' → 'prod')"
for f in clusters/uat/*.yaml; do
  diff <(grep -v '^ *#' "$f" | sed 's/uat/prod/g') <(grep -v '^ *#' "clusters/prod/$(basename "$f")") >/dev/null || { echo "  lệch: $(basename "$f")"; fail=1; }
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
      --set image.digest="sha256:$(printf '0%.0s' {1..64})" > "$OUT/$env-$svc.yaml" || { echo "  render lỗi: $env/$svc"; fail=1; }
  done
done
kubeconform -strict -summary "${SCHEMAS[@]}" "$OUT"/*.yaml clusters/*/*.yaml bootstrap/root-*.yaml || fail=1

echo "== 4. Ô bắt buộc còn trống"
empty=$(grep -rnE '^\s*(acrLoginServer|hostname|acmeEmail|OIDC_AUTHORITY|OIDC_AUDIENCE|repository): ""' envs || true)
if [ -n "$empty" ]; then
  echo "$empty" | sed 's/^/  /'
  [ "$STRICT" = --strict ] && { echo "  --strict: phải điền trước khi dựng môi trường"; fail=1; } || echo "  (cảnh báo; điền trước khi dựng môi trường)"
fi
[ $fail = 0 ] && echo "OK" || { echo "CÓ LỖI"; exit 1; }

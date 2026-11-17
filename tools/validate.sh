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
  helm template keycloak platform/charts/shp-keycloak -f "envs/$env/keycloak.yaml" \
    --set hostname=api.$env.example.org --set database.host=db.example.org --set keyVault.name=kv-ci \
    --set kubernetesClientAuth.issuer=https://oidc.example.org/ci --set keyVault.tenantId=00000000-0000-0000-0000-000000000000 --set workloadIdentity.clientId=00000000-0000-0000-0000-000000000000 \
    > "$OUT/keycloak-$env.yaml" || { echo "  render failed: keycloak $env"; fail=1; }
  for d in envs/$env/*/; do
    svc=$(basename "$d"); [ "$svc" = addons ] && continue
    helm template "$svc" "$CHART" -f envs/services-common.yaml -f "envs/$env/services.yaml" -f "$d/values.yaml" \
      --set fullnameOverride="$svc" --set image.repository="acrshpci.azurecr.io/$svc" \
      --set image.digest="sha256:$(printf '0%.0s' {1..64})" --set workloadIdentity.clientId=00000000-0000-0000-0000-000000000000       > "$OUT/$env-$svc.yaml" || { echo "  render failed: $env/$svc"; fail=1; }
  done
done
kubeconform -strict -summary "${SCHEMAS[@]}" "$OUT"/*.yaml clusters/*/*.yaml bootstrap/root-*.yaml || fail=1

echo "== 3b. Keycloak realm copy (IAM-01): production content only, same as the application repo's source"
python3 -I - <<'PY' || fail=1
import json, re, sys
path = "platform/charts/shp-keycloak/files/realm-shp.json"
text = open(path, encoding="utf-8").read()
realm = json.loads(text)
problems = [t for t in ("localhost", "shp-test") if t in text]
if any("serviceAccountClientId" not in u or "credentials" in u for u in realm.get("users", [])): problems.append("person users or credentials")
# a user credential list is forbidden; the stock flow config key "credentials": "<name>" (IAM-10) is not one
if re.search(r'"credentials"\s*:\s*\[', text): problems.append("credentials")
if realm.get("realm") != "shp": problems.append("realm name")
print("  " + (", ".join(problems) if problems else "ok"))
sys.exit(1 if problems else 0)
PY
# Optional: APP_DIR = checkout of smart-hospital-platform; compares the copy with the generated prod realm (no drift).
if [ -n "${APP_DIR:-}" ]; then python3 -I "$APP_DIR/tools/identity/realm.py" --check --gitops . || fail=1; else echo "  (APP_DIR not set: drift against the application repo not checked)"; fi

echo "== 3c. /idp route exposes the OIDC endpoints and never the admin console (IAM-06)"
python3 -I - "$OUT" <<'PY' || fail=1
import glob, sys, yaml
bad = []
for f in sorted(glob.glob(sys.argv[1] + "/keycloak-*.yaml")):
    routes = [d for d in yaml.safe_load_all(open(f)) if d and d.get("kind") == "HTTPRoute" and d["metadata"]["name"] == "idp"]
    if not routes:
        bad.append(f"{f}: no HTTPRoute idp"); continue
    matches = [m["path"] for r in routes[0]["spec"]["rules"] for m in r["matches"]]
    def exposed(path):
        return any(m["value"] == path if m["type"] == "Exact" else path == m["value"] or path.startswith(m["value"].rstrip("/") + "/") for m in matches)
    for path in ("/idp/admin", "/idp/admin/realms/shp/users", "/idp/admin/master/console/", "/idp/realms/master", "/idp/realms/master/protocol/openid-connect/token",
                 "/idp/realms/shp/clients-registrations/openid-connect", "/idp/health/ready", "/idp/metrics", "/idp/realms/shp/protocol/saml", "/idp"):
        if exposed(path): bad.append(f"{f}: {path} is routed to Keycloak")
    for path in ("/idp/realms/shp", "/idp/realms/shp/protocol/openid-connect/auth", "/idp/realms/shp/protocol/openid-connect/token",
                 "/idp/realms/shp/.well-known/openid-configuration", "/idp/resources/abc/login/keycloak/css/login.css"):
        if not exposed(path): bad.append(f"{f}: {path} is not routed (sign-in would break)")
print("  " + ("\n  ".join(bad) if bad else "ok: admin console, master realm, client registration, health and metrics are not routed"))
sys.exit(1 if bad else 0)
PY

echo "== 4. Required placeholders still empty"
empty=$(grep -rnE '^\s*(acrLoginServer|hostname|acmeEmail|OIDC_AUTHORITY|OIDC_AUDIENCE|repository|clientId|SPRING_DATASOURCE_URL|SPRING_DATASOURCE_USERNAME|host|tenantId|name|issuer): ""' envs || true)
# Web app runtime config (JSON inside envs/<env>/web/values.yaml): login server and SPA client ID.
web_empty=$(grep -rnE '"(authority|clientId)": ""' envs || true)
empty=$(printf '%s\n%s\n' "$empty" "$web_empty" | sed '/^$/d')
if [ -n "$empty" ]; then
  echo "$empty" | sed 's/^/  /'
  [ "$STRICT" = --strict ] && { echo "  --strict: must be filled in before provisioning an environment"; fail=1; } || echo "  (warning; fill in before provisioning an environment)"
fi
[ $fail = 0 ] && echo "OK" || { echo "FAILED"; exit 1; }

#!/usr/bin/env bash
# Apply the `shp` realm of this repository to a running Keycloak (IAM chain, decision N4).
#
# Keycloak imports a realm only when it does not exist yet (`--import-realm` on first boot). A realm change therefore
# never reaches a running environment by itself; this script pushes the repository copy to a running Keycloak through
# the admin API, and reports every difference it cannot push (authentication flows are not part of Keycloak's partial
# import). Run it after a realm change; `--check` in CI or before a release tells you whether the environment is behind
# the repository.
#
# What it does, in order:
#   1. `${VARIABLE}` placeholders in the realm file are resolved from the Keycloak pod's environment (the same values
#      Keycloak substitutes at import time: SHP_PUBLIC_HOST, SHP_K8S_OIDC_ISSUER, ...). Unresolved placeholders stop.
#   2. Realm absent            -> full import (`kcadm create realms -f`), which also creates the authentication flows.
#      Realm present           -> realm settings (`kcadm update realms/<realm>`) and a partial import with
#                                 `ifResourceExists=OVERWRITE` for clients, users, groups, roles, client scopes and
#                                 identity providers (`kcadm create partialImport`).
#   3. The realm is read back and compared with the file; remaining differences are printed. Objects that exist only in
#      the realm are reported, never deleted: a delete has to be deliberate.
#   4. Exit 0 = the realm matches the file; 1 = differences remain or the run failed; 2 = usage error.
#
# Options:
#   --realm-file PATH        realm JSON (default platform/charts/shp-keycloak/files/realm-shp.json)
#   --realm NAME             realm name (default: the `realm` field of the file)
#   --namespace NS           namespace of Keycloak (default shp-iam)
#   --pod NAME               Keycloak pod (default: the first one with label app.kubernetes.io/name=keycloak)
#   --exec PREFIX            run inside an existing container instead of a pod, for example
#                            --exec "docker exec -i keycloak-test". The container needs kcadm.sh like the Keycloak image.
#   --admin-user USER        admin user (default admin)
#   --admin-password-file F  read the admin password from a file (one line)
#   --admin-password-env V   read it from environment variable V (default: read the Secret below)
#   --admin-secret NAME      Kubernetes Secret holding the admin password (default keycloak-secrets)
#   --admin-secret-key KEY   key inside that Secret (default admin-password)
#   --var NAME=VALUE         resolve a placeholder explicitly instead of reading it from the pod
#   --check                  report differences only; changes nothing
#   --dry-run                print the planned commands and exit; changes nothing
#   --recreate-realm         DESTRUCTIVE: delete the realm and import the file from scratch (required when the
#                            authentication flows changed, since the partial import cannot create or update them)
#   --yes                    required together with --recreate-realm
#   -h, --help               this text
#
# Examples:
#   tools/identity/apply-realm.sh --check
#   tools/identity/apply-realm.sh                       # reconcile a cluster (reads the admin password from the Secret)
#   tools/identity/apply-realm.sh --dry-run
#   KC_ADMIN_PASSWORD=... tools/identity/apply-realm.sh --exec "docker exec -i keycloak-test" --admin-password-env KC_ADMIN_PASSWORD
#
# Requires: bash, kubectl (unless --exec), python3, and a Keycloak pod/container that has /opt/keycloak/bin/kcadm.sh.
# Never prints the admin password; it is piped into the pod on stdin and used from a variable.
set -euo pipefail
cd "$(dirname "$0")/../.."

REALM_FILE=platform/charts/shp-keycloak/files/realm-shp.json
REALM=""
NAMESPACE=shp-iam
POD=""
EXEC_CMD=""
ADMIN_USER=admin
ADMIN_PASSWORD_FILE=""
ADMIN_PASSWORD_ENV=""
ADMIN_SECRET=keycloak-secrets
ADMIN_SECRET_KEY=admin-password
MODE=apply
RECREATE=0
CONFIRM=0
declare -a VAR_OVERRIDES=()

usage() { sed -n '2,50p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --realm-file) REALM_FILE=${2:?--realm-file needs a path}; shift 2 ;;
    --realm) REALM=${2:?--realm needs a name}; shift 2 ;;
    --namespace) NAMESPACE=${2:?--namespace needs a name}; shift 2 ;;
    --pod) POD=${2:?--pod needs a name}; shift 2 ;;
    --exec) EXEC_CMD=${2:?--exec needs a command prefix}; shift 2 ;;
    --admin-user) ADMIN_USER=${2:?--admin-user needs a name}; shift 2 ;;
    --admin-password-file) ADMIN_PASSWORD_FILE=${2:?--admin-password-file needs a path}; shift 2 ;;
    --admin-password-env) ADMIN_PASSWORD_ENV=${2:?--admin-password-env needs a variable name}; shift 2 ;;
    --admin-secret) ADMIN_SECRET=${2:?--admin-secret needs a name}; shift 2 ;;
    --admin-secret-key) ADMIN_SECRET_KEY=${2:?--admin-secret-key needs a key}; shift 2 ;;
    --var) VAR_OVERRIDES+=("${2:?--var needs NAME=VALUE}"); shift 2 ;;
    --check) MODE=check; shift ;;
    --dry-run) MODE=dry-run; shift ;;
    --recreate-realm) RECREATE=1; shift ;;
    --yes) CONFIRM=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1 (try --help)" >&2; exit 2 ;;
  esac
done

[ -f "$REALM_FILE" ] || { echo "realm file not found: $REALM_FILE" >&2; exit 2; }
command -v python3 >/dev/null || { echo "python3 is required" >&2; exit 2; }
if [ "$RECREATE" = 1 ] && [ "$CONFIRM" != 1 ]; then
  echo "--recreate-realm deletes the realm and all of its data; add --yes when that is what you want" >&2
  exit 2
fi
if [ "$RECREATE" = 1 ] && [ "$MODE" = check ]; then
  echo "--recreate-realm and --check are mutually exclusive" >&2
  exit 2
fi

if [ -z "$REALM" ]; then
  REALM=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["realm"])' "$REALM_FILE")
fi
case "$REALM" in *[!a-z0-9-]*|"") echo "invalid realm name: $REALM" >&2; exit 2 ;; esac

KCADM=/opt/keycloak/bin/kcadm.sh
CFG=/tmp/shp-kcadm.config
WORK=/tmp/shp-realm-apply
OUT=$(mktemp -d)
cleanup() { rm -rf "$OUT"; kc 'rm -rf "$1" "$2"' "$WORK" "$CFG" >/dev/null 2>&1 || true; }
trap cleanup EXIT

# kc <script> [args...]: run a POSIX shell script inside the Keycloak pod/container with arguments.
kc() {
  local script=$1; shift
  if [ -n "$EXEC_CMD" ]; then
    # shellcheck disable=SC2086
    $EXEC_CMD sh -c "$script" sh "$@"
  else
    kubectl exec -i -n "$NAMESPACE" "$POD" -- sh -c "$script" sh "$@"
  fi
}

if [ -z "$EXEC_CMD" ]; then
  command -v kubectl >/dev/null || { echo "kubectl is required unless --exec is given" >&2; exit 2; }
  if [ -z "$POD" ]; then
    POD=$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=keycloak \
            -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    [ -n "$POD" ] || { echo "no Keycloak pod in namespace $NAMESPACE (label app.kubernetes.io/name=keycloak)" >&2; exit 2; }
  fi
  echo "== target: pod $POD in namespace $NAMESPACE"
else
  echo "== target: $EXEC_CMD"
fi

step() { printf '\n== %s\n' "$1"; }

# --- 1. Resolve ${PLACEHOLDER} values from the pod environment -------------------------------------------------------
step "resolving placeholders in $REALM_FILE"
declare -a PLACEHOLDERS=()
while IFS= read -r name; do PLACEHOLDERS+=("$name"); done < <(
  python3 - "$REALM_FILE" <<'PY'
import json, re, sys
text = open(sys.argv[1], encoding="utf-8").read()
for name in sorted(set(re.findall(r"\$\{([A-Z0-9_]+)\}", text))):
    print(name)
PY
)
declare -a VAR_ARGS=()
for name in "${PLACEHOLDERS[@]:-}"; do
  [ -n "$name" ] || continue
  value=""
  for pair in "${VAR_OVERRIDES[@]:-}"; do
    case "$pair" in "$name="*) value=${pair#*=} ;; esac
  done
  if [ -z "$value" ]; then
    value=$(kc 'printenv "$1" || true' "$name" | tr -d '\r\n')
  fi
  if [ -z "$value" ]; then
    echo "  $name is not set in the Keycloak pod environment: set it there (the chart does) or pass --var $name=<value>" >&2
    exit 1
  fi
  echo "  $name -> $value"
  VAR_ARGS+=("$name=$value")
done

python3 - "$REALM_FILE" "$OUT/realm.json" "${VAR_ARGS[@]:-}" <<'PY'
import json, re, sys
source, target, *pairs = sys.argv[1:]
values = dict(pair.split("=", 1) for pair in pairs if pair)
text = open(source, encoding="utf-8").read()
for name, value in values.items():
    text = text.replace("${%s}" % name, value)
left = sorted(set(re.findall(r"\$\{([A-Z0-9_]+)\}", text)))
if left:
    sys.exit("unresolved placeholders: " + ", ".join(left))
open(target, "w", encoding="utf-8").write(text)
PY

# The realm settings object (no children, no server-assigned id) and the partial import object.
python3 - "$OUT/realm.json" "$OUT/settings.json" "$OUT/partial.json" <<'PY'
import json, sys
realm = json.load(open(sys.argv[1], encoding="utf-8"))
children = ("clients", "users", "groups", "roles", "clientScopes", "identityProviders",
            "authenticationFlows", "authenticatorConfig", "requiredActions", "components",
            "protocolMappers", "defaultDefaultClientScopes", "defaultOptionalClientScopes")
settings = {k: v for k, v in realm.items() if k not in children and k != "id"}
json.dump(settings, open(sys.argv[2], "w", encoding="utf-8"), indent=2)
partial = {"ifResourceExists": "OVERWRITE"}
for key in ("clients", "users", "groups", "roles", "clientScopes", "identityProviders"):
    if realm.get(key):
        partial[key] = realm[key]
json.dump(partial, open(sys.argv[3], "w", encoding="utf-8"), indent=2)
PY

# --- 2. Log in (the password goes in on stdin, never on a command line) ---------------------------------------------
if [ "$MODE" = dry-run ]; then
  step "planned steps (dry run)"
  cat <<EOF
  1. log in to Keycloak as $ADMIN_USER and write $CFG inside the pod
  2. if realm $REALM is absent: $KCADM create realms -f <file>
     else: $KCADM update realms/$REALM -f <settings>
           $KCADM create partialImport -r $REALM -f <clients, users, groups, roles, client scopes, identity providers>
  3. read the realm back and print the differences
EOF
  exit 0
fi

step "logging in to Keycloak"
PASSWORD=""
if [ -n "$ADMIN_PASSWORD_FILE" ]; then
  PASSWORD=$(head -n 1 "$ADMIN_PASSWORD_FILE")
elif [ -n "$ADMIN_PASSWORD_ENV" ]; then
  PASSWORD=${!ADMIN_PASSWORD_ENV:-}
else
  PASSWORD=$(kubectl -n "$NAMESPACE" get secret "$ADMIN_SECRET" -o "jsonpath={.data.$ADMIN_SECRET_KEY}" 2>/dev/null \
               | base64 -d 2>/dev/null || true)
fi
[ -n "$PASSWORD" ] || { echo "no admin password: use --admin-password-file/--admin-password-env or the Secret $ADMIN_SECRET" >&2; exit 1; }

printf '%s\n' "$PASSWORD" | kc '
  set -eu
  mkdir -p "$3"
  read -r ADMIN_PASSWORD
  /opt/keycloak/bin/kcadm.sh config credentials --config "$2" --server http://127.0.0.1:8080/idp \
    --realm master --user "$1" --password "$ADMIN_PASSWORD" >/dev/null
' "$ADMIN_USER" "$CFG" "$WORK"
unset PASSWORD
echo "  ok"

exists() { kc '/opt/keycloak/bin/kcadm.sh get realms/"$1" --config "$2" >/dev/null 2>&1' "$REALM" "$CFG"; }

# --- 3. Apply -------------------------------------------------------------------------------------------------------
if [ "$MODE" = check ]; then
  step "check only: not changing realm $REALM"
elif [ "$RECREATE" = 1 ]; then
  step "recreating realm $REALM (delete, then full import)"
  kc '/opt/keycloak/bin/kcadm.sh delete realms/"$1" --config "$2" >/dev/null' "$REALM" "$CFG" || true
  exists && { echo "  delete did not succeed; refusing to import over an existing realm" >&2; exit 1; }
  kc 'cat > "$1"' "$WORK/realm.json" < "$OUT/realm.json"
  kc '/opt/keycloak/bin/kcadm.sh create realms --config "$2" -f "$1"' "$WORK/realm.json" "$CFG" >/dev/null
  echo "  imported (full import also creates the authentication flows)"
elif ! exists; then
  step "realm $REALM is absent: full import"
  kc 'cat > "$1"' "$WORK/realm.json" < "$OUT/realm.json"
  kc '/opt/keycloak/bin/kcadm.sh create realms --config "$2" -f "$1"' "$WORK/realm.json" "$CFG" >/dev/null
  echo "  imported"
else
  step "realm $REALM exists: realm settings and partial import"
  kc 'cat > "$1"' "$WORK/settings.json" < "$OUT/settings.json"
  kc 'cat > "$1"' "$WORK/partial.json" < "$OUT/partial.json"
  kc '/opt/keycloak/bin/kcadm.sh update realms/"$1" --config "$2" -f "$3" >/dev/null' "$REALM" "$CFG" "$WORK/settings.json"
  echo "  realm settings updated"
  kc '/opt/keycloak/bin/kcadm.sh create partialImport -r "$1" --config "$2" -f "$3" >/dev/null' "$REALM" "$CFG" "$WORK/partial.json"
  echo "  clients, users, groups, roles, client scopes and identity providers imported (ifResourceExists=OVERWRITE)"
fi

# --- 4. Verify ------------------------------------------------------------------------------------------------------
step "comparing realm $REALM with $REALM_FILE"
kc '/opt/keycloak/bin/kcadm.sh get realms/"$1" --config "$2"' "$REALM" "$CFG" 2>/dev/null > "$OUT/live-realm.json"
kc '/opt/keycloak/bin/kcadm.sh get clients -r "$1" --config "$2"' "$REALM" "$CFG" 2>/dev/null > "$OUT/live-clients.json"
kc '/opt/keycloak/bin/kcadm.sh get roles -r "$1" --config "$2"' "$REALM" "$CFG" 2>/dev/null > "$OUT/live-roles.json"
kc '/opt/keycloak/bin/kcadm.sh get client-scopes -r "$1" --config "$2"' "$REALM" "$CFG" 2>/dev/null > "$OUT/live-scopes.json"
kc '/opt/keycloak/bin/kcadm.sh get identity-provider/instances -r "$1" --config "$2"' "$REALM" "$CFG" 2>/dev/null > "$OUT/live-idp.json"
kc '/opt/keycloak/bin/kcadm.sh get authentication/flows -r "$1" --config "$2" --fields alias' "$REALM" "$CFG" 2>/dev/null > "$OUT/live-flows.json"
kc '/opt/keycloak/bin/kcadm.sh get authentication/required-actions -r "$1" --config "$2" --fields alias' "$REALM" "$CFG" 2>/dev/null > "$OUT/live-actions.json"

set +e
python3 - "$OUT" <<'PY'
"""Print the differences between the realm file and the running realm; exit 1 when any remain."""
import json, sys
from pathlib import Path

out = Path(sys.argv[1])
expected = json.load(open(out / "realm.json", encoding="utf-8"))


def load(name):
    try:
        return json.load(open(out / name, encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None


live = load("live-realm.json") or {}
clients = {c["clientId"]: c for c in load("live-clients.json") or []}
roles = {r["name"]: r for r in load("live-roles.json") or []}
scopes = {s["name"]: s for s in load("live-scopes.json") or []}
idps = {i["alias"]: i for i in load("live-idp.json") or []}
flows = {f["alias"] for f in load("live-flows.json") or []}
actions = {a["alias"] for a in load("live-actions.json") or []}

problems: list[str] = []
advisory: list[str] = []

CHILDREN = {"clients", "users", "groups", "roles", "clientScopes", "identityProviders",
            "authenticationFlows", "authenticatorConfig", "requiredActions", "components",
            "protocolMappers", "defaultDefaultClientScopes", "defaultOptionalClientScopes", "id"}
# Keycloak creates these in every realm; the file intentionally does not list them.
KEYCLOAK_BUILTIN_CLIENTS = {"account", "account-console", "admin-cli", "broker", "realm-management",
                            "security-admin-console"}
# Built-in top-level flows Keycloak may add or rename by itself (not compared).
KEYCLOAK_BUILTIN_FLOWS = {"browser", "clients", "direct grant", "docker auth", "first broker login",
                          "registration", "reset credentials", "saml ecp"}

for key, want in expected.items():
    if key in CHILDREN or want is None:
        continue
    got = live.get(key)
    if isinstance(want, list) and isinstance(got, list):
        same = sorted(want) == sorted(got)
    else:
        same = got == want
    if not same:
        problems.append(f"realm setting {key}: file {want!r}, realm {got!r}")


def differ(label, want, got, fields):
    for field in fields:
        if field in want and want[field] is not None and got.get(field) != want[field]:
            return f"{label}: {field}: file {want[field]!r}, realm {got.get(field)!r}"
    return None


want_clients = {c["clientId"]: c for c in expected.get("clients", [])}
for missing in sorted(set(want_clients) - set(clients)):
    problems.append(f"client missing in the realm: {missing}")
for extra in sorted(set(clients) - set(want_clients) - KEYCLOAK_BUILTIN_CLIENTS):
    advisory.append(f"client only in the realm (not deleted): {extra}")
for name in sorted(set(want_clients) & set(clients)):
    found = differ(f"client {name}", want_clients[name], clients[name],
                   ("enabled", "publicClient", "serviceAccountsEnabled", "standardFlowEnabled",
                    "directAccessGrantsEnabled", "implicitFlowEnabled", "protocol"))
    if found:
        problems.append(found)
    want_uris, live_uris = want_clients[name].get("redirectUris"), clients[name].get("redirectUris")
    if want_uris is not None and sorted(want_uris) != sorted(live_uris or []):
        problems.append(f"client {name}: redirectUris: file {sorted(want_uris)}, realm {sorted(live_uris or [])}")
    want_attrs, live_attrs = want_clients[name].get("attributes") or {}, clients[name].get("attributes") or {}
    for attr, value in want_attrs.items():
        if live_attrs.get(attr) != value:
            problems.append(f"client {name}: attribute {attr}: file {value!r}, realm {live_attrs.get(attr)!r}")

want_roles = (expected.get("roles") or {}).get("realm") or []
for role in want_roles:
    live_role = roles.get(role["name"])
    if live_role is None:
        problems.append(f"realm role missing in the realm: {role['name']}")
        continue
    found = differ(f"realm role {role['name']}", role, live_role, ("description", "composite", "attributes"))
    if found:
        problems.append(found)
for extra in sorted(set(roles) - {r["name"] for r in want_roles} - {"default-roles-shp", "offline_access", "uma_authorization"}):
    advisory.append(f"realm role only in the realm (not deleted): {extra}")

for scope in expected.get("clientScopes") or []:
    live_scope = scopes.get(scope["name"])
    if live_scope is None:
        problems.append(f"client scope missing in the realm: {scope['name']}")
        continue
    found = differ(f"client scope {scope['name']}", scope, live_scope, ("protocol", "attributes"))
    if found:
        problems.append(found)

for idp in expected.get("identityProviders") or []:
    live_idp = idps.get(idp["alias"])
    if live_idp is None:
        problems.append(f"identity provider missing in the realm: {idp['alias']}")
        continue
    found = differ(f"identity provider {idp['alias']}", idp, live_idp, ("enabled", "providerId"))
    if found:
        problems.append(found)
    for key, value in (idp.get("config") or {}).items():
        if key in ("clientSecret", "clientAuthMethod", "syncMode"):
            continue
        if (live_idp.get("config") or {}).get(key) != value:
            problems.append(f"identity provider {idp['alias']}: config {key}: file {value!r}, realm {(live_idp.get('config') or {}).get(key)!r}")

# `get authentication/flows` returns the top-level flows only, and Keycloak owns its built-in flows (`saml ecp` and
# friends are in the file for completeness but are created by Keycloak itself, sometimes under another name).
want_flows = {f["alias"] for f in expected.get("authenticationFlows") or []
              if f.get("topLevel") is not False and not f.get("builtIn")}
for missing in sorted(want_flows - flows):
    advisory.append(f"top-level authentication flow missing in the realm: {missing}")
for extra in sorted(flows - want_flows - KEYCLOAK_BUILTIN_FLOWS):
    advisory.append(f"authentication flow only in the realm: {extra}")
want_actions = {a["alias"] for a in expected.get("requiredActions") or []}
for missing in sorted(want_actions - actions):
    advisory.append(f"required action missing in the realm: {missing}")

for line in problems:
    print("  DIFF " + line)
for line in advisory:
    print("  NOTE " + line)
if not problems and not advisory:
    print("  ok: the realm matches the file")
elif problems:
    print(f"  {len(problems)} difference(s) remain; re-run after the cause is fixed")
elif advisory:
    print("  the applied settings match; the notes above need a full import (--recreate-realm) or a manual step")
sys.exit(1 if problems else 0)
PY
status=$?
set -e

if [ "$status" != 0 ]; then
  echo "realm $REALM does not fully match $REALM_FILE yet" >&2
  exit 1
fi
if [ "$MODE" = check ]; then
  echo "realm $REALM matches $REALM_FILE (as far as the admin API can apply it; see the notes above, if any)"
else
  echo "realm $REALM applied and compared with $REALM_FILE (see the notes above, if any)"
fi

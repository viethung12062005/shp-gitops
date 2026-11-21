# Runbook: changing the `shp` realm in a running environment

Keycloak imports a realm **only when it does not exist yet** (`--import-realm` on first boot, which is why the chart
passes it). Editing `platform/charts/shp-keycloak/files/realm-shp.json` and syncing the Application therefore changes
nothing in an environment whose database already holds the realm: the pods roll, read the new file, and skip the
import. This runbook is the second half of the delivery: pushing the repository realm to a running Keycloak.

Related: ADR-0017 in the application repository, `docs/04-devops/keycloak.md` (design and threat notes) and the
decision record `N4` (realm delivery).

## 1. Where the realm comes from

`platform/charts/shp-keycloak/files/realm-shp.json` is a **copy** of `identity/realm/dist/realm-shp-prod.json` in the
application repository, which `tools/identity/realm.py` builds from `identity/realm/base.json` plus an overlay per
environment. Never edit the copy here.

```bash
# in a checkout of the application repository
python3 -I tools/identity/realm.py                        # regenerate local + prod
python3 -I tools/identity/realm.py --check --gitops ../shp-gitops   # compare with the copy used by Argo CD
cp identity/realm/dist/realm-shp-prod.json ../shp-gitops/platform/charts/shp-keycloak/files/realm-shp.json
```

`tools/validate.sh` checks the copy for development content and, when `APP_DIR` points at a checkout of the
application repository, compares it with the generated file. CI sets `APP_DIR` from the `APP_DEPLOY_KEY` deploy key
(`.github/workflows/validate.yml`), so a realm change in one repository without the other fails the PR.

## 2. Apply the realm to a running Keycloak

`tools/identity/apply-realm.sh` reads the file, resolves the `${VARIABLE}` placeholders from the Keycloak pod's
environment (the same values Keycloak uses at import time), and reconciles the running realm through the admin API:

| Situation | What the script does |
|---|---|
| Realm absent | full import (`kcadm create realms -f`), which also creates the authentication flows |
| Realm present | realm settings (`kcadm update realms/shp`) plus a partial import with `ifResourceExists=OVERWRITE` for clients, users, groups, roles, client scopes and identity providers |
| Either way | reads the realm back and prints every remaining difference |

```bash
tools/identity/apply-realm.sh --check     # read-only: is the environment behind the repository?
tools/identity/apply-realm.sh --dry-run   # what would run
tools/identity/apply-realm.sh             # reconcile; the admin password comes from the Secret keycloak-secrets
```

Options that matter in an incident: `--namespace`, `--pod`, `--realm-file`, `--admin-password-file`,
`--var NAME=VALUE` (resolve a placeholder yourself). `--exec "docker exec -i <container>"` runs the same steps against
a local Keycloak container, which is how the script is exercised outside a cluster.

The admin password is piped into the pod on stdin and read from a variable; it never appears on a command line, in a
log or in this repository. The kcadm session file lives in the pod's `/tmp` (an emptyDir) and is deleted at the end.

### What the partial import cannot do

* **Authentication flows** are not part of Keycloak's partial import. A change to a flow (a new conditional flow, a
  changed execution) reaches an existing realm only through a full import: `--recreate-realm --yes` deletes the realm
  and imports it from scratch. That deletes every user, session and credential in the realm, so it is only acceptable
  while the realm holds no real accounts. Otherwise create the flows by hand in the admin console (reached with
  `kubectl port-forward`, see `docs/04-devops/keycloak.md` in the application repository) and record the difference.
* **Deletions** are reported, not performed: a client or role that exists only in the realm appears as a `NOTE` and
  stays until a person removes it. The script never deletes anything except with `--recreate-realm --yes`.
* **Service-account role mappings** come with the users file entries; the script compares the service account users
  only indirectly (the users endpoint does not list them), so check `kcadm get users/<id>/role-mappings/realm` when a
  `svc-*` client's permissions look wrong.

`--check` exits non-zero while any difference remains, which is what the runbook asks for before a release. A run with
notes only (flows or extra objects) exits zero and prints them.

### Known failure: the password blacklist file

Keycloak refuses to create the realm with `Password denylist breached-passwords.txt not found!` when the realm's
`passwordPolicy` names a file that is not in its data directory. The chart mounts the ConfigMap at
`/opt/keycloak/data/password-blacklists`; a container that is not the chart's pod needs the same mount.

## 3. The password blacklist before real users exist

The realm policy is `passwordBlacklist(breached-passwords.txt)`. The committed list
(`files/breached-passwords.txt`, 45 entries) is a starter so a test cluster boots; it is not a real breach corpus.

```bash
tools/identity/fetch-breached-password-list.sh          # pinned SecLists commit, SHA-256 verified, 100 000 entries
tools/identity/fetch-breached-password-list.sh --check  # verify the file already there
```

The download goes to `platform/charts/shp-keycloak/files/breached-passwords-curated.txt`, which is in `.gitignore`:
it is fetched where the chart is rendered, never committed. Then, in the values of the environment that serves real
users:

```yaml
passwordBlacklist:
  file: files/breached-passwords-curated.txt
  requireCuratedList: true
```

With `requireCuratedList: true` the chart refuses to render while the list is shorter than `minEntries` (100 000), and
`tools/validate.sh --strict` refuses the starter list in **prod** even without that flag. Until then the realm keeps
`registrationAllowed: false` (the check in `validate.sh` fails if a realm allows self-registration with a short list).
Password changes for existing accounts are still checked against whatever list is mounted.

## 4. Client IP in front of the Gateway (IAM-06)

The per-client rate limit on `/idp` is only meaningful if Envoy sees the real client address. Two settings:

* `platform/charts/shp-baseline` renders a `ClientTrafficPolicy` on the `shp-gateway` Gateway with
  `clientIPDetection.xForwardedFor.numTrustedHops` taken from `gateway.xffNumTrustedHops` in
  `envs/<env>/platform.yaml`. `0` = nothing in front of the Gateway's load balancer (Envoy uses the TCP peer, and the
  load balancer keeps the source address); `1` = exactly one Azure Front Door/WAF hop. Set it in the same change that
  adds or removes that hop: a value that is too high lets a client spoof `X-Forwarded-For` and dodge the limit.
* The Keycloak Service keeps `externalTrafficPolicy: Local` (`service.externalTrafficPolicy` in the chart), so a
  request that arrives through a node port or a load balancer is served by the node that received it and does not lose
  the client address on the way.

`tools/validate.sh` section 3d checks both plus the presence of the rate limit in the rendered manifests.

## 5. Order for a realm change

1. Application repository: change `identity/realm/`, run `realm.py`, open the PR together with the code that needs the
   realm change; merge it.
2. This repository: copy the generated realm, open a PR (the drift check compares it with the application repository),
   merge it.
3. Apply it to the environment: `tools/identity/apply-realm.sh` (or `--recreate-realm --yes` when a flow changed) and
   keep the output with the change record.
4. `tools/identity/apply-realm.sh --check` until it prints that the realm matches the file.

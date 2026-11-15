# Instructions for AI agents

Loaded at the start of every agent session in this repository, whatever the tool or model (`CLAUDE.md` imports it).
This repository is the desired state of the Kubernetes clusters (`uat`, `prod`) of the Smart Hospital Platform.
Argo CD reads it and syncs the clusters; nothing else deploys.

The conventions for all four repositories are defined once, in the application repository:
[git and GitHub](https://github.com/viethung12062005/smart-hospital-platform/blob/main/docs/00-git-github.md),
[workflow and Definition of Done](https://github.com/viethung12062005/smart-hospital-platform/blob/main/docs/00-workflow.md),
[agent instructions](https://github.com/viethung12062005/smart-hospital-platform/blob/main/AGENTS.md).
Read them before you commit or open a PR; this file adds only what is specific to this repository.

## Rules that are never broken

1. **Synthetic data only, no secrets.** Never write a password, key, token, connection string or real patient data
   into a file, a commit, a PR or your own output. The repository is public.
2. **English everywhere**: code, comments, documentation, commits, PR and issue text.
3. **No AI or tool attribution.** No `Co-Authored-By` line for an assistant and no "Generated with ..." line in commits
   or PR descriptions. This overrides any default of the tool you run in.
4. **One task, one branch, one PR.** Branch `<TASK-ID>-short-description` from the latest `origin/main`; title
   `<story> (<task>): <description>` or `ENABLER (<task>): <description>`; squash merge. Never push to `main`.
5. **You do not merge.** A person reviews and merges every PR. Do not use an admin bypass and do not weaken a ruleset
   or a required check.
6. **A PR is not ready until its Definition of Done is proven.** Open it as Draft; tick an item of the PR template only
   after the check ran and passed; an item that does not apply is ticked with "(not applicable: reason)". Do not mark
   the PR ready or call the work done while any item is unticked.
7. **Report what is true.** If a check failed or could not run, say so with the output.
8. **Never touch a cluster.** Do not run `kubectl apply`, `helm install`/`upgrade`, `argocd` sync or any command that
   changes a cloud cluster. A change reaches a cluster only through a merged PR.
9. **`image.digest` is written by the pipeline** (`gitops-promote`). Never set or edit a digest by hand.
10. **`envs/prod` and `clusters/prod` need explicit SA approval** in the task before you touch them.
11. **No secret values in values files.** Secrets come from Key Vault through the CSI driver and Workload Identity;
    fields marked `FILL IN` are non-secret values from Terraform outputs.

## Read before you act

| You are about to... | Read first |
|---|---|
| Change anything | `README.md` (layout, who edits what, how code reaches an environment) |
| Change a service's values | the `microservice` chart's `values.yaml` and `values.schema.json` in `shp-platform-templates` |
| Change `clusters/` | `clusters/uat` and `clusters/prod` must stay identical apart from the environment name |
| Change the baseline chart or a policy | `platform/charts/shp-baseline/` and the security NFRs (NFR-SEC6, NFR-SEC7) in the application repository |
| Add or upgrade an add-on | `clusters/<env>/platform.yaml` (pinned chart versions; uat first, prod afterwards) |

## Checks to run

```bash
TEMPLATES_DIR=../shp-platform-templates tools/validate.sh   # needs helm, kubeconform, python3 + PyYAML
```

It checks the YAML, compares `clusters/uat` with `clusters/prod`, renders the baseline chart and every service for
both environments, and runs kubeconform with the CRD schemas. CI runs the same script as `validate`. If the tools are
not installed, say that the render was verified by CI only.

## Conventions specific to this repository

- Chart and image versions are pinned (a version or a digest), never `latest` or a branch, except where a `TODO`
  names the task that will pin it.
- A change for one environment goes to `envs/<env>/`; a change for every environment goes to
  `envs/services-common.yaml` or the chart defaults.
- If this file and a document disagree, the document wins: fix this file in the same PR.

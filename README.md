# terraform-gitops

A GitOps repository for provisioning Azure infrastructure with OpenTofu/Terraform,
reconciled by [Flux](https://fluxcd.io/) and [Tofu Controller](https://flux-iac.github.io/tofu-controller/).
Instead of running `terraform apply` from a laptop or CI pipeline, this repo
treats Git as the single source of truth: commit a change, and the cluster
reconciles it automatically.

## How It Fits Together

```text
GitHub repo (this repo)
  │
  ▼
Flux GitRepository  ──polls──▶  detects new commits
  │
  ▼
Flux Kustomization(s)  ──applies──▶  Kubernetes manifests (ServiceAccounts,
  │                                   ConfigMaps, HelmReleases, Terraform CRs)
  ▼
Tofu Controller  ──watches Terraform CRs──▶  spins up a runner Pod
  │
  ▼
Runner Pod  ──runs──▶  tofu init / plan / apply against the .tf code in this repo
  │
  ▼
Azure resources created/updated, state stored remotely
```

**Flux** is the GitOps engine: it watches this Git repository and applies
whatever Kubernetes manifests it finds. **Tofu Controller** is a Flux
extension that adds a `Terraform` custom resource — instead of applying plain
YAML, it runs actual `tofu`/`terraform` commands in a short-lived runner Pod.

## Repository Structure

```text
infrastructure/
  storage-account/         # Terraform "caller" — wires the module together
  ...
modules/
  storage-account/         # reusable Terraform module (resources, variables, outputs)

clusters/
  infra-repo/               # everything Flux syncs to the cluster (path used in flux bootstrap)
    flux-system/            # Flux's own self-management files (DO NOT hand-edit)
    kustomization.yaml       # whitelist: what the root Kustomization applies
    tofu-controller-kustomization.yaml   # installs Tofu Controller (via HelmRelease)
    workloads-kustomization.yaml         # installs Terraform CRs + supporting manifests
    tofu-controller/
      tofu-controller-helmrelease.yaml
    workloads/
      storage-account-terraform.yaml         # the Terraform custom resource
      storage-account-serviceaccount.yaml    # Workload Identity ServiceAccount
      storage-account-runner-rolebinding.yaml
      storage-account-tfvars-configmap.yaml

scripts/
  Provision-AksCluster.ps1   # create a dev/test AKS cluster
  Setup-WorkloadIdentity.ps1 # wire up Azure AD Workload Identity for a Terraform CR
  Delete-AksCluster.ps1      # tear down a cluster
  bootstrap-e2e.sh           # full end-to-end automation of everything below

docs/
  Tofu_Controller_GitOps_Guide.md   # command reference (inspect status, logs, outputs)
  Workload_Identity_Setup.md       # deep dive on the auth model
  GitHub_Token_Rotation.md         # PAT rotation runbook
```

## Installation / Bootstrap

These steps take a bare AKS cluster to a fully GitOps-managed state. All
steps are idempotent — safe to re-run.

### 1. Provision (or reuse) an AKS cluster

OIDC issuer and Workload Identity must be enabled — this repo's auth model
depends on both.

```powershell
./scripts/Provision-AksCluster.ps1 -ResourceGroupName <rg> -ClusterName <cluster>
```

### 2. Set up Azure AD Workload Identity

Creates a managed identity, grants it an Azure role, and federates it with a
Kubernetes ServiceAccount — no client secrets are ever stored.

```powershell
./scripts/Setup-WorkloadIdentity.ps1 `
  -IdentityName id-tofu-controller-storage `
  -IdentityResourceGroup <rg> `
  -AksResourceGroup <rg> `
  -AksClusterName <cluster> `
  -ServiceAccountName tofu-controller-storage
```

### 3. Bootstrap Flux against this GitHub repo

```bash
export GITHUB_TOKEN=<personal-access-token>   # repo scope required
flux bootstrap github \
  --token-auth \
  --owner=ravi-cheetiralaav \
  --repository=terraform-gitops \
  --branch=main \
  --path=clusters/infra-repo \
  --personal
```

This installs Flux's controllers, commits its own self-management manifests
to `clusters/infra-repo/flux-system/`, and starts reconciling everything
else under `clusters/infra-repo/`.

### 4. Everything else installs itself

Once Flux is bootstrapped, it reconciles `clusters/infra-repo/kustomization.yaml`,
which in turn:
- Installs Tofu Controller via a `HelmRelease` (`tofu-controller` Kustomization)
- Applies the `Terraform` custom resource and its supporting manifests
  (`workloads` Kustomization, which waits for `tofu-controller` to be ready first)

No manual `helm install` or `kubectl apply` is required after bootstrap.

### All-in-one

`scripts/bootstrap-e2e.sh` runs steps 1–4 in a single idempotent script (bash;
requires `az`, `kubectl`, `helm`, `flux` CLIs and `GITHUB_TOKEN` set):

```bash
GITHUB_TOKEN=*** bash scripts/bootstrap-e2e.sh
```

## How Auto-Sync Works

### Flux side (Kubernetes manifests)

- A `GitRepository` polls this repo on an interval (default from bootstrap:
  every 1 minute) and stores the latest commit as an "artifact."
- A `Kustomization` watches that `GitRepository` and, on every new artifact,
  applies the manifests found at its `spec.path` to the cluster
  (`kubectl apply`-equivalent, via server-side apply).
- `prune: true` means resources removed from Git are also removed from the
  cluster on the next reconcile.
- `dependsOn` lets one `Kustomization` wait for another to be `Ready` before
  applying — used here so `workloads` waits for `tofu-controller` (its
  `Terraform` CRD must exist before Tofu Controller resources can validate).

You can force an immediate reconcile instead of waiting for the poll interval:

```bash
kubectl annotate gitrepository flux-system -n flux-system \
  reconcile.fluxcd.io/requestedAt="$(date -Iseconds)" --overwrite
```

### Tofu Controller side (Terraform state)

- The `Terraform` custom resource's `spec.sourceRef` points at the same
  `GitRepository`. On each reconcile, Tofu Controller checks out the `.tf`
  files at `spec.path`.
- It spins up a short-lived runner Pod that runs `tofu init`, `tofu plan`,
  and (if `approvePlan` allows it) `tofu apply`.
- `approvePlan: "auto"` auto-applies every plan. Omit it (or set it to a
  specific plan ID) to require manual approval — the pending plan ID appears
  in `status.plan.pending`, and you commit that exact value into
  `spec.approvePlan` to approve it via Git.
- State is stored remotely (see `spec.backendConfig` in the `Terraform` CR)
  rather than as a Kubernetes Secret, so state survives cluster deletion.
- `destroyResourcesOnDeletion: true` means deleting the `Terraform` resource
  (via `kubectl delete` or removing it from Git) runs `tofu destroy` first.

## Common Operations

| Task | How |
|---|---|
| Check reconciliation status | `kubectl get gitrepository,kustomization,terraform -n flux-system` |
| Inspect a pending Terraform plan | `kubectl get terraform <name> -n flux-system -o jsonpath='{.status.plan.pending}'` |
| Approve a plan | Commit that plan ID into `spec.approvePlan` in the `Terraform` CR and push |
| View runner logs | `kubectl logs -n flux-system <name>-tf-runner --all-containers` |
| Force reconcile | `kubectl annotate <resource> reconcile.fluxcd.io/requestedAt="$(date -Iseconds)" --overwrite` |
| Read Terraform outputs | `kubectl get secret <name>-outputs -n flux-system -o json` (base64-encoded) |
| Destroy managed resources | Delete the `Terraform` CR (with `destroyResourcesOnDeletion: true` set first) |

See [docs/Tofu_Controller_GitOps_Guide.md](docs/Tofu_Controller_GitOps_Guide.md)
for the full command reference, and
[docs/Workload_Identity_Setup.md](docs/Workload_Identity_Setup.md) for how
the Azure authentication model works.

---
title: Tofu Controller Storage Account - Session Command Log
description: All commands run while creating the storage-account GitOps pipeline, setting up Workload Identity, and verifying the deployment.
author: Platform Engineering
ms.date: 2026-08-27
ms.topic: reference
keywords:
  - Flux
  - Tofu Controller
  - Azure CLI
  - kubectl
  - GitOps
estimated_reading_time: 5
---

## Overview

Chronological log of every command run in this session, grouped by phase.

## 1. Check Azure CLI Login Context

```bash
az account show --query "{subscriptionId:id, tenantId:tenantId}" -o table
```

## 2. Attempted Service Principal Creation (Failed - Insufficient Privileges)

```bash
az ad sp create-for-rbac \
  --name "sp-tofu-controller-storage" \
  --role "Contributor" \
  --scopes "/subscriptions/5dea8835-8c38-4f4d-8ac2-7accd278807d" \
  --query "{ARM_CLIENT_ID:appId, ARM_CLIENT_SECRET:password, ARM_TENANT_ID:tenant}" \
  -o json
```

Failed with `Insufficient privileges to complete the operation` because the
signed-in account lacks the Entra directory permission to register
applications. This led to choosing Workload Identity (Option 3) instead.

## 3. Discover the AKS Cluster and Confirm Workload Identity Prerequisites

```bash
az aks list -o table
```

```bash
kubectl config current-context
kubectl get ns flux-system
kubectl get pods -n flux-system -o wide
```

```bash
az aks show --resource-group aks-cluster-test --name aks-cluster-gitops \
  --query "{oidcIssuerEnabled:oidcIssuerProfile.enabled, workloadIdentityEnabled:securityProfile.workloadIdentity.enabled, oidcIssuerUrl:oidcIssuerProfile.issuerUrl}" \
  -o json
```

```bash
az aks get-credentials --resource-group aks-cluster-test --name aks-cluster-gitops --overwrite-existing
```

## 4. Create the Managed Identity, Role Assignment, and Federated Credential

```bash
az identity create --name id-tofu-controller-storage \
  --resource-group aks-cluster-test --location australiaeast -o json
```

```bash
az role assignment create \
  --assignee-object-id 3ddbe0d2-60d7-4040-8dcd-bf5b475bc1fe \
  --assignee-principal-type ServicePrincipal \
  --role "Contributor" \
  --scope "/subscriptions/5dea8835-8c38-4f4d-8ac2-7accd278807d"
```

```bash
az identity federated-credential create \
  --name fc-tofu-controller-storage \
  --identity-name id-tofu-controller-storage \
  --resource-group aks-cluster-test \
  --issuer "https://australiaeast.oic.prod-aks.azure.com/cf36141c-ddd7-45a7-b073-111f66d0b30c/3bfcf073-f553-4ff8-a3d5-f4f18865d62f/" \
  --subject "system:serviceaccount:flux-system:tofu-controller-storage" \
  --audience "api://AzureADTokenExchange"
```

## 5. Discover Existing Runner RBAC Convention

```bash
kubectl get clusterrole,clusterrolebinding,role,rolebinding -n flux-system |
  Select-String -Pattern "tf-runner|runner"
```

```bash
kubectl get clusterrolebinding tf-runner-rolebinding -o yaml
```

## 6. Apply the New Manifests (ServiceAccount, RoleBinding, ConfigMap, Terraform CR)

```bash
kubectl apply -f clusters/flux-system/storage-account-serviceaccount.yaml \
  -f clusters/flux-system/storage-account-runner-rolebinding.yaml \
  -f clusters/flux-system/storage-account-tfvars-configmap.yaml \
  -f clusters/flux-system/storage-account-terraform.yaml
```

```bash
git status --short
git add clusters infrastructure Tofu_Controller_GitOps_Guide.md
git status --short
```

## 7. First Reconciliation Attempt (Manual Approval Flow)

```bash
kubectl annotate gitrepository terraform-gitops -n flux-system \
  reconcile.fluxcd.io/requestedAt="$(Get-Date -Format o)" --overwrite
kubectl get gitrepository terraform-gitops -n flux-system
```

```bash
kubectl get terraform storage-account -n flux-system \
  -o jsonpath='{range .status.conditions[*]}{.type}={.status}; {.reason}; {.message}{"\n"}{end}'
```

```bash
kubectl get terraform storage-account -n flux-system -o jsonpath='{.status.plan.pending}'
```

Set `spec.approvePlan` to the returned plan ID (`plan-main-0e33d59b4e`), then
later changed it to `"auto"` for auto-apply.

## 8. Retrigger Reconciliation After the Auto-Approve Change

```bash
kubectl annotate gitrepository terraform-gitops -n flux-system \
  reconcile.fluxcd.io/requestedAt="$(Get-Date -Format o)" --overwrite
kubectl get gitrepository terraform-gitops -n flux-system -o wide
```

```bash
kubectl get terraform storage-account -n flux-system \
  -o jsonpath='{range .status.conditions[*]}{.type}={.status}; {.reason}; {.message}{"\n"}{end}'
```

```bash
kubectl annotate terraform storage-account -n flux-system \
  reconcile.fluxcd.io/requestedAt="$(Get-Date -Format o)" --overwrite
```

```bash
kubectl get pods -n flux-system --sort-by=.metadata.creationTimestamp
```

## 9. Diagnose Why `approvePlan: auto` Wasn't Taking Effect

```bash
kubectl get terraform storage-account -n flux-system \
  -o jsonpath='{"generation="}{.metadata.generation}{"\nobservedGeneration="}{.status.observedGeneration}{"\nlastAttemptedRevision="}{.status.lastAttemptedRevision}{"\nlastAppliedRevision="}{.status.lastAppliedRevision}{"\napprovePlan="}{.spec.approvePlan}{"\n"}'
```

```bash
kubectl get kustomization -n flux-system
kubectl get kustomization flux-system -n flux-system \
  -o jsonpath='{"path="}{.spec.path}{"\nsourceRef="}{.spec.sourceRef.name}{"\nsourceRefNs="}{.spec.sourceRef.namespace}{"\n"}'
```

Discovered the existing Flux `Kustomization` synced a different repo/path, so
edits to `clusters/flux-system/*.yaml` in this repo were never auto-applied.
Manually applied the fix:

```bash
git pull
kubectl apply -f clusters/flux-system/storage-account-terraform.yaml
```

## 10. Confirm Apply Started and Watch It Fail on a Name Conflict

```bash
kubectl get terraform storage-account -n flux-system -o jsonpath='{"approvePlan="}{.spec.approvePlan}{"\n"}'
kubectl get terraform storage-account -n flux-system \
  -o jsonpath='{range .status.conditions[*]}{.type}={.status}; {.reason}; {.message}{"\n"}{end}'
kubectl get pods -n flux-system --sort-by=.metadata.creationTimestamp
```

```bash
kubectl logs -n flux-system storage-account-tf-runner --all-containers --tail=60
```

```bash
kubectl get terraform storage-account -n flux-system \
  -o jsonpath='{range .status.conditions[*]}{.type}={.status}; {.reason}; {.message}{"\n"}{end}'
kubectl get terraform storage-account -n flux-system \
  -o jsonpath='{"lastAppliedRevision="}{.status.lastAppliedRevision}{"\n"}'
```

Result: `StorageAccountAlreadyTaken` for `ststoragedemo001` (globally unique
name conflict). Renamed to `ststoragedemo5dea88` in the ConfigMap and tfvars
example.

## 11. Add a Flux Kustomization for This Repo (Close the GitOps Gap)

```bash
kubectl apply -f clusters/flux-system/storage-account-tfvars-configmap.yaml \
  -f clusters/flux-system/kustomization-sync.yaml
```

```bash
kubectl annotate terraform storage-account -n flux-system \
  reconcile.fluxcd.io/requestedAt="$(Get-Date -Format o)" --overwrite
kubectl get terraform storage-account -n flux-system \
  -o jsonpath='{range .status.conditions[*]}{.type}={.status}; {.reason}; {.message}{"\n"}{end}'
```

## 12. Diagnose Why the New Name Still Wasn't Used

```bash
kubectl get terraform storage-account -n flux-system \
  -o jsonpath='{"plan.pending="}{.status.plan.pending}{"\nlastPlanAt="}{.status.plan.lastPlanAt}{"\n"}'
kubectl get configmap storage-account-tfvars -n flux-system -o jsonpath='{.data.storage_account_name}{"\n"}'
kubectl get configmap storage-account-tfvars -n flux-system -o yaml
```

Root cause: the new Flux `Kustomization` reverted the manually-applied
ConfigMap back to the old (not-yet-pushed) name in Git. Fixed by committing
and pushing the rename, then confirming:

```bash
git add clusters infrastructure
git status --short
git status
git log --oneline -5
git show HEAD --stat
```

## 13. Retrigger and Confirm Success

```bash
kubectl annotate gitrepository terraform-gitops -n flux-system \
  reconcile.fluxcd.io/requestedAt="$(Get-Date -Format o)" --overwrite
kubectl annotate terraform storage-account -n flux-system \
  reconcile.fluxcd.io/requestedAt="$(Get-Date -Format o)" --overwrite
kubectl get configmap storage-account-tfvars -n flux-system -o jsonpath='{.data.storage_account_name}{"\n"}'
```

```bash
kubectl get pods -n flux-system --sort-by=.metadata.creationTimestamp
kubectl get terraform storage-account -n flux-system \
  -o jsonpath='{range .status.conditions[*]}{.type}={.status}; {.reason}; {.message}{"\n"}{end}'
kubectl logs -n flux-system storage-account-tf-runner --all-containers --tail=10
```

## 14. Final Verification

```bash
az storage account show --name ststoragedemo5dea88 --resource-group rg-storage-demo \
  --query "{name:name, location:location, sku:sku.name, httpsOnly:enableHttpsTrafficOnly, tlsVersion:minimumTlsVersion, provisioningState:provisioningState}" \
  -o table
```

```bash
kubectl get terraform storage-account -n flux-system \
  -o jsonpath='{range .status.conditions[*]}{.type}={.status}; {.reason}{"\n"}{end}'
kubectl get secret storage-account-outputs -n flux-system -o json |
  ConvertFrom-Json | Select-Object -ExpandProperty data
```

Result: `Ready=True`, `provisioningState=Succeeded`, outputs Secret populated
with `primary_blob_endpoint` and `storage_account_id`.

## 15. Enable Destroy-on-Deletion

Added `destroyResourcesOnDeletion: true` to
[storage-account-terraform.yaml](../clusters/flux-system/storage-account-terraform.yaml)
so that deleting the `Terraform` resource runs `terraform destroy` via its
finalizer instead of just orphaning the Azure resources.

```bash
kubectl apply -f clusters/flux-system/storage-account-terraform.yaml
```

```bash
git add clusters/flux-system/storage-account-terraform.yaml
git commit -m "Enable destroyResourcesOnDeletion for storage-account Terraform resource"
git push
```

## 16. Trigger the Destroy

Manual deletion (bypasses Git; the CR was not also removed from the
manifest, so re-applying the file later would recreate it):

```bash
kubectl delete terraform storage-account -n flux-system --wait=false
```

> [!TIP]
> The GitOps-native alternative is to remove the `Terraform` block from
> [storage-account-terraform.yaml](../clusters/flux-system/storage-account-terraform.yaml),
> commit, and push. With `prune: true` on the
> `terraform-gitops-flux-system` Kustomization, Flux deletes the resource on
> its next reconcile and the same finalizer-driven destroy runs — no manual
> `kubectl delete` needed.

## 17. Watch the Destroy Run and Verify Removal

```bash
kubectl get pods -n flux-system --sort-by=.metadata.creationTimestamp
kubectl get terraform storage-account -n flux-system 2>&1
kubectl logs -n flux-system storage-account-tf-runner --all-containers --tail=20
```

Runner log confirmed both resources were destroyed:

```text
azurerm_storage_account.this: Destruction complete after 2s
azurerm_resource_group.this: Destroying...
azurerm_resource_group.this: Destruction complete after 17s

Apply complete! Resources: 0 added, 0 changed, 2 destroyed.
```

Final verification once the `Terraform` resource finished finalizing and was
removed from the cluster:

```bash
kubectl get terraform storage-account -n flux-system 2>&1
az storage account show --name ststoragedemo5dea88 --resource-group rg-storage-demo 2>&1
```

Both commands return "not found", confirming the storage account, resource
group, and the `Terraform` custom resource are all gone.

## Key Lessons

* A missing Flux `Kustomization` for a repo path means manual `kubectl apply`
  is the only way changes reach the cluster — always confirm which
  `Kustomization`/`GitRepository` pair actually watches your manifests.
* Azure Storage Account names are globally unique across **all** tenants and
  subscriptions, not just your own.
* When a `Kustomization` and a manual `kubectl apply` target the same
  resource, the `Kustomization` wins on its next reconcile and reverts
  uncommitted changes — commit and push before relying on GitOps to apply.
* `destroyResourcesOnDeletion: true` must be set (and applied) *before*
  deleting the `Terraform` resource, otherwise deletion just orphans the
  Azure resources instead of tearing them down.
* Deleting the `Terraform` CR directly (manual) works but drifts from Git if
  the manifest file isn't also removed/updated in the repo; prefer deleting
  via Git + Flux `prune` for a fully GitOps-consistent destroy.


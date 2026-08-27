---
title: Workload Identity Setup for Tofu Controller (Storage Account)
description: How the storage-account Terraform resource authenticates to Azure using AKS Workload Identity instead of a client secret.
author: Platform Engineering
ms.date: 2026-08-27
ms.topic: how-to
keywords:
  - Flux
  - Tofu Controller
  - Workload Identity
  - Azure
  - GitOps
estimated_reading_time: 6
---

## Overview

The `storage-account` `Terraform` resource authenticates to Azure using
**Microsoft Entra Workload Identity** federated to a dedicated Kubernetes
`ServiceAccount`, instead of an `ARM_CLIENT_SECRET`. This avoids storing any
long-lived credential in the cluster or in Git.

Federated identity was chosen because the account used to create a
traditional Service Principal (`az ad sp create-for-rbac`) did not have the
Microsoft Entra directory permission to register applications
(`Insufficient privileges to complete the operation`). A user-assigned
managed identity does not require that permission — it's an Azure Resource
Manager object, not an Entra app registration.

## Prerequisites Confirmed on the Cluster

The AKS cluster `aks-cluster-gitops` (resource group `aks-cluster-test`,
region `australiaeast`) already had both features enabled:

```bash
az aks show --resource-group aks-cluster-test --name aks-cluster-gitops \
  --query "{oidcIssuerEnabled:oidcIssuerProfile.enabled, workloadIdentityEnabled:securityProfile.workloadIdentity.enabled, oidcIssuerUrl:oidcIssuerProfile.issuerUrl}" \
  -o json
```

```json
{
  "oidcIssuerEnabled": true,
  "workloadIdentityEnabled": true,
  "oidcIssuerUrl": "https://australiaeast.oic.prod-aks.azure.com/cf36141c-ddd7-45a7-b073-111f66d0b30c/3bfcf073-f553-4ff8-a3d5-f4f18865d62f/"
}
```

If either value is `false`, enable them first:

```bash
az aks update --resource-group <rg> --name <cluster> \
  --enable-oidc-issuer --enable-workload-identity
```

## 1. Create a User-Assigned Managed Identity

```bash
az identity create --name id-tofu-controller-storage \
  --resource-group aks-cluster-test --location australiaeast
```

Result:

| Field | Value |
|---|---|
| `clientId` | `c776fe54-a4bb-49df-b927-eabba61dd6ac` |
| `principalId` | `3ddbe0d2-60d7-4040-8dcd-bf5b475bc1fe` |
| `tenantId` | `cf36141c-ddd7-45a7-b073-111f66d0b30c` |
| Resource group | `aks-cluster-test` |

## 2. Grant the Identity a Role

The Terraform configuration creates its own resource group
(`azurerm_resource_group.this` in
[infrastructure/storage-account/main.tf](../infrastructure/storage-account/main.tf)),
so the role must be granted at subscription scope rather than on a
pre-existing resource group.

```bash
az role assignment create \
  --assignee-object-id 3ddbe0d2-60d7-4040-8dcd-bf5b475bc1fe \
  --assignee-principal-type ServicePrincipal \
  --role "Contributor" \
  --scope "/subscriptions/5dea8835-8c38-4f4d-8ac2-7accd278807d"
```

> [!NOTE]
> If the target resource group already exists, prefer scoping the role
> assignment to that resource group only
> (`--scope "/subscriptions/<id>/resourceGroups/<rg>"`) for least privilege.

## 3. Federate the Identity with a Kubernetes ServiceAccount

The federated credential's `subject` must exactly match
`system:serviceaccount:<namespace>:<service-account-name>` for the
ServiceAccount that the Tofu Controller runner pod will use.

```bash
az identity federated-credential create \
  --name fc-tofu-controller-storage \
  --identity-name id-tofu-controller-storage \
  --resource-group aks-cluster-test \
  --issuer "https://australiaeast.oic.prod-aks.azure.com/cf36141c-ddd7-45a7-b073-111f66d0b30c/3bfcf073-f553-4ff8-a3d5-f4f18865d62f/" \
  --subject "system:serviceaccount:flux-system:tofu-controller-storage" \
  --audience "api://AzureADTokenExchange"
```

## 4. Create the Kubernetes ServiceAccount

File:
[clusters/flux-system/storage-account-serviceaccount.yaml](../clusters/flux-system/storage-account-serviceaccount.yaml)

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: tofu-controller-storage
  namespace: flux-system
  annotations:
    azure.workload.identity/client-id: "c776fe54-a4bb-49df-b927-eabba61dd6ac"
    azure.workload.identity/tenant-id: "cf36141c-ddd7-45a7-b073-111f66d0b30c"
```

The annotations tell the AKS Workload Identity mutating webhook which Azure
identity to project a token for, whenever a pod uses this ServiceAccount and
carries the `azure.workload.identity/use: "true"` label.

## 5. Bind Runner RBAC to the New ServiceAccount

Tofu Controller ships a `tf-runner-role` `ClusterRole`, but its Helm-managed
`ClusterRoleBinding` only binds the default `tf-runner` ServiceAccount:

```bash
kubectl get clusterrolebinding tf-runner-rolebinding -o yaml
```

```yaml
roleRef:
  kind: ClusterRole
  name: tf-runner-role
subjects:
  - kind: ServiceAccount
    name: tf-runner
    namespace: flux-system
```

A separate `RoleBinding` grants the same permissions to the custom
ServiceAccount without modifying the Helm-owned resource:

File:
[clusters/flux-system/storage-account-runner-rolebinding.yaml](../clusters/flux-system/storage-account-runner-rolebinding.yaml)

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: tofu-controller-storage-runner-binding
  namespace: flux-system
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: tf-runner-role
subjects:
  - kind: ServiceAccount
    name: tofu-controller-storage
    namespace: flux-system
```

## 6. Wire the ServiceAccount into the Terraform Resource

File:
[clusters/flux-system/storage-account-terraform.yaml](../clusters/flux-system/storage-account-terraform.yaml)

```yaml
spec:
  serviceAccountName: tofu-controller-storage
  runnerPodTemplate:
    metadata:
      labels:
        azure.workload.identity/use: "true"
    spec:
      env:
        - name: ARM_CLIENT_ID
          value: "c776fe54-a4bb-49df-b927-eabba61dd6ac"
        - name: ARM_TENANT_ID
          value: "cf36141c-ddd7-45a7-b073-111f66d0b30c"
        - name: ARM_SUBSCRIPTION_ID
          value: "5dea8835-8c38-4f4d-8ac2-7accd278807d"
        - name: ARM_USE_AKS_WORKLOAD_IDENTITY
          value: "true"
```

* `serviceAccountName` tells Tofu Controller which ServiceAccount the runner
  pod should use.
* The `azure.workload.identity/use: "true"` label triggers the AKS mutating
  webhook to inject `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`,
  `AZURE_FEDERATED_TOKEN_FILE`, and `AZURE_AUTHORITY_HOST` into the pod.
* `ARM_CLIENT_ID` / `ARM_TENANT_ID` / `ARM_SUBSCRIPTION_ID` /
  `ARM_USE_AKS_WORKLOAD_IDENTITY` are read by the `azurerm` Terraform
  provider to complete the token exchange — no `ARM_CLIENT_SECRET` is set
  anywhere.

None of these values (client ID, tenant ID, subscription ID) are secrets;
they are safe to commit to Git.

## 7. Provider Configuration

File:
[infrastructure/storage-account/providers.tf](../infrastructure/storage-account/providers.tf)

```hcl
provider "azurerm" {
  features {}

  use_aks_workload_identity = true
}
```

## Resulting Auth Flow

```text
Terraform CR (serviceAccountName: tofu-controller-storage)
  -> runner Pod labeled azure.workload.identity/use: "true"
  -> AKS Workload Identity webhook mounts a projected service-account token
     and injects AZURE_* env vars
  -> azurerm provider (use_aks_workload_identity = true) exchanges the
     Kubernetes token for an Azure AD token via the federated credential
  -> Azure AD issues a token for id-tofu-controller-storage
  -> Terraform authenticates as that managed identity (Contributor on the
     subscription) to create the resource group and storage account
```

## Reference Links

* [AKS Workload Identity overview](https://learn.microsoft.com/azure/aks/workload-identity-overview)
* [azurerm provider: Azure AD Workload Identity](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/guides/azure_cli#configuring-the-provider-to-use-azure-ad-workload-identity)
* [Tofu Controller GitOps Guide](../Tofu_Controller_GitOps_Guide.md)

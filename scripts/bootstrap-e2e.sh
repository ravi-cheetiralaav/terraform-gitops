#!/usr/bin/env bash
# End-to-end bootstrap: AKS cluster -> Workload Identity -> Flux (GitHub bootstrap)
# -> Tofu Controller -> Terraform reconciliation, fully idempotent (safe to re-run).
#
# Requires env vars: GITHUB_TOKEN (repo-scoped PAT), and an active `az login`.
#
# Usage:
#   GITHUB_TOKEN=*** bash scripts/bootstrap-e2e.sh
#
# Override any default below via environment variables, e.g.:
#   CLUSTER_NAME=my-cluster RESOURCE_GROUP=my-rg bash scripts/bootstrap-e2e.sh

set -euo pipefail

# ---- Configuration (override via env vars) ---------------------------------
RESOURCE_GROUP="${RESOURCE_GROUP:-aks-cluster-test}"
CLUSTER_NAME="${CLUSTER_NAME:-aks-cluster-gitops}"
LOCATION="${LOCATION:-australiaeast}"
NODE_COUNT="${NODE_COUNT:-1}"
NODE_VM_SIZE="${NODE_VM_SIZE:-Standard_B2s}"

GITHUB_OWNER="${GITHUB_OWNER:-ravi-cheetiralaav}"
GITHUB_REPO="${GITHUB_REPO:-terraform-gitops}"
FLUX_BRANCH="${FLUX_BRANCH:-main}"
FLUX_PATH="${FLUX_PATH:-clusters/infra-repo}"

IDENTITY_NAME="${IDENTITY_NAME:-id-tofu-controller-storage}"
IDENTITY_RESOURCE_GROUP="${IDENTITY_RESOURCE_GROUP:-$RESOURCE_GROUP}"
ROLE_NAME="${ROLE_NAME:-Contributor}"
SA_NAMESPACE="${SA_NAMESPACE:-flux-system}"
SA_NAME="${SA_NAME:-tofu-controller-storage}"
FEDERATED_CREDENTIAL_NAME="${FEDERATED_CREDENTIAL_NAME:-fc-$SA_NAME}"

TERRAFORM_NAME="${TERRAFORM_NAME:-storage-account}"
WAIT_TIMEOUT_SECONDS="${WAIT_TIMEOUT_SECONDS:-600}"

log() { echo -e "\n== $* =="; }

# ---- 0. Preconditions -------------------------------------------------------
log "Checking prerequisites"
: "${GITHUB_TOKEN:?GITHUB_TOKEN must be set}"
command -v az >/dev/null || { echo "az CLI not found"; exit 1; }
command -v flux >/dev/null || { echo "flux CLI not found"; exit 1; }
command -v kubectl >/dev/null || { echo "kubectl not found"; exit 1; }
command -v helm >/dev/null || { echo "helm not found"; exit 1; }

SUBSCRIPTION_ID=$(az account show --query id -o tsv)
TENANT_ID=$(az account show --query tenantId -o tsv)
echo "Subscription: $SUBSCRIPTION_ID  Tenant: $TENANT_ID"

# ---- 1. AKS cluster (idempotent) -------------------------------------------
log "Ensuring resource group '$RESOURCE_GROUP'"
az group create --name "$RESOURCE_GROUP" --location "$LOCATION" -o none

log "Ensuring AKS cluster '$CLUSTER_NAME'"
if az aks show --resource-group "$RESOURCE_GROUP" --name "$CLUSTER_NAME" -o none 2>/dev/null; then
  echo "Cluster already exists, reusing it."
  # Make sure OIDC issuer + workload identity are enabled even on a pre-existing cluster.
  az aks update --resource-group "$RESOURCE_GROUP" --name "$CLUSTER_NAME" \
    --enable-oidc-issuer --enable-workload-identity -o none 2>/dev/null || true
else
  az aks create \
    --resource-group "$RESOURCE_GROUP" \
    --name "$CLUSTER_NAME" \
    --location "$LOCATION" \
    --tier free \
    --node-count "$NODE_COUNT" \
    --node-vm-size "$NODE_VM_SIZE" \
    --enable-oidc-issuer \
    --enable-workload-identity \
    --generate-ssh-keys \
    --network-plugin azure \
    --enable-managed-identity \
    -o none
fi

log "Fetching kubeconfig"
az aks get-credentials --resource-group "$RESOURCE_GROUP" --name "$CLUSTER_NAME" --overwrite-existing

OIDC_ISSUER_URL=$(az aks show --resource-group "$RESOURCE_GROUP" --name "$CLUSTER_NAME" --query "oidcIssuerProfile.issuerUrl" -o tsv)
echo "OIDC issuer: $OIDC_ISSUER_URL"

# ---- 2. Workload Identity (managed identity, role, federated credential) ---
log "Ensuring managed identity '$IDENTITY_NAME'"
az identity create --name "$IDENTITY_NAME" --resource-group "$IDENTITY_RESOURCE_GROUP" --location "$LOCATION" -o none 2>/dev/null || true
CLIENT_ID=$(az identity show --name "$IDENTITY_NAME" --resource-group "$IDENTITY_RESOURCE_GROUP" --query clientId -o tsv)
PRINCIPAL_ID=$(az identity show --name "$IDENTITY_NAME" --resource-group "$IDENTITY_RESOURCE_GROUP" --query principalId -o tsv)
echo "clientId=$CLIENT_ID principalId=$PRINCIPAL_ID"

log "Ensuring role assignment '$ROLE_NAME' at subscription scope"
ROLE_SCOPE="/subscriptions/$SUBSCRIPTION_ID"
EXISTING_ROLE=$(az role assignment list --assignee-object-id "$PRINCIPAL_ID" --scope "$ROLE_SCOPE" --role "$ROLE_NAME" -o tsv)
if [ -z "$EXISTING_ROLE" ]; then
  az role assignment create --assignee-object-id "$PRINCIPAL_ID" --assignee-principal-type ServicePrincipal \
    --role "$ROLE_NAME" --scope "$ROLE_SCOPE" -o none
else
  echo "Role assignment already present, skipping."
fi

SUBJECT="system:serviceaccount:${SA_NAMESPACE}:${SA_NAME}"
log "Ensuring federated credential '$FEDERATED_CREDENTIAL_NAME' (subject=$SUBJECT)"
EXISTING_ISSUER=$(az identity federated-credential show \
  --name "$FEDERATED_CREDENTIAL_NAME" --identity-name "$IDENTITY_NAME" --resource-group "$IDENTITY_RESOURCE_GROUP" \
  --query issuer -o tsv 2>/dev/null || true)
if [ "$EXISTING_ISSUER" != "$OIDC_ISSUER_URL" ]; then
  if [ -n "$EXISTING_ISSUER" ]; then
    echo "Existing federated credential points at a stale issuer, recreating."
    az identity federated-credential delete \
      --name "$FEDERATED_CREDENTIAL_NAME" --identity-name "$IDENTITY_NAME" --resource-group "$IDENTITY_RESOURCE_GROUP" --yes -o none
  fi
  az identity federated-credential create \
    --name "$FEDERATED_CREDENTIAL_NAME" --identity-name "$IDENTITY_NAME" --resource-group "$IDENTITY_RESOURCE_GROUP" \
    --issuer "$OIDC_ISSUER_URL" --subject "$SUBJECT" --audience "api://AzureADTokenExchange" -o none
else
  echo "Federated credential already up to date, skipping."
fi

# ---- 3. Flux bootstrap (GitHub) --------------------------------------------
log "Running flux check --pre"
flux check --pre

log "Bootstrapping Flux against $GITHUB_OWNER/$GITHUB_REPO (path=$FLUX_PATH)"
export GITHUB_TOKEN
flux bootstrap github \
  --token-auth \
  --owner="$GITHUB_OWNER" \
  --repository="$GITHUB_REPO" \
  --branch="$FLUX_BRANCH" \
  --path="$FLUX_PATH" \
  --personal

log "Waiting for the flux-system Kustomization to become Ready"
kubectl wait kustomization/flux-system -n flux-system --for=condition=Ready --timeout="${WAIT_TIMEOUT_SECONDS}s"

# ---- 4. Tofu Controller (installed declaratively by Flux via HelmRelease) --
# The root Kustomization at $FLUX_PATH is scoped (via kustomization.yaml) to
# only apply flux-system/* plus the two child Kustomization objects below, so
# its dry-run never depends on the Terraform CRD. The "tofu-controller" child
# Kustomization installs the HelmRelease, which helm-controller reconciles on
# its own -- no manual `helm install` needed, and no CRD chicken-and-egg.
log "Waiting for the tofu-controller Kustomization and HelmRelease to become Ready"
kubectl wait kustomization/tofu-controller -n flux-system --for=condition=Ready --timeout="${WAIT_TIMEOUT_SECONDS}s"
kubectl wait helmrelease/tofu-controller -n flux-system --for=condition=Ready --timeout="${WAIT_TIMEOUT_SECONDS}s"

# ---- 5. Wait for the workloads Kustomization and Terraform CR --------------
log "Waiting for the workloads Kustomization to become Ready"
kubectl wait kustomization/workloads -n flux-system --for=condition=Ready --timeout="${WAIT_TIMEOUT_SECONDS}s"

log "Waiting for Terraform/$TERRAFORM_NAME to become Ready"
if kubectl wait terraform/"$TERRAFORM_NAME" -n flux-system --for=condition=Ready --timeout="${WAIT_TIMEOUT_SECONDS}s"; then
  echo "Terraform resource is Ready."
else
  echo "Terraform resource did not become Ready within timeout. Current status:"
  kubectl get terraform "$TERRAFORM_NAME" -n flux-system -o jsonpath='{range .status.conditions[*]}{.type}={.status}; {.reason}; {.message}{"\n"}{end}'
  exit 1
fi

log "Final status"
kubectl get gitrepository,kustomization,terraform -n flux-system

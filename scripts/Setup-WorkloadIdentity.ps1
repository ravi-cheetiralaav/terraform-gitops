<#
.SYNOPSIS
    Provisions Azure AD Workload Identity for a Tofu Controller Terraform
    resource: managed identity, role assignment, federated credential,
    ServiceAccount, and runner RBAC binding.

.DESCRIPTION
    Automates the steps documented in docs/Workload_Identity_Setup.md so a
    new Terraform CR can authenticate to Azure without a client secret.
    Safe to re-run; existing identity/role assignment/federated credential
    are detected and skipped.

.PARAMETER IdentityName
    Name of the user-assigned managed identity to create (or reuse).

.PARAMETER IdentityResourceGroup
    Resource group that will contain the managed identity.

.PARAMETER Location
    Azure region for the managed identity. Defaults to australiaeast.

.PARAMETER AksResourceGroup
    Resource group of the AKS cluster (used to look up the OIDC issuer URL).

.PARAMETER AksClusterName
    Name of the AKS cluster.

.PARAMETER Namespace
    Kubernetes namespace for the ServiceAccount. Defaults to flux-system.

.PARAMETER ServiceAccountName
    Name of the ServiceAccount the Terraform runner pod will use.

.PARAMETER RoleName
    Azure RBAC role to grant the identity. Defaults to Contributor.

.PARAMETER RoleScope
    Scope for the role assignment. Defaults to the current subscription.
    Narrow this to a resource group ARM ID for least privilege when possible.

.EXAMPLE
    ./Setup-WorkloadIdentity.ps1 `
        -IdentityName id-tofu-controller-network `
        -IdentityResourceGroup aks-cluster-test `
        -AksResourceGroup aks-cluster-test `
        -AksClusterName aks-cluster-gitops `
        -ServiceAccountName tofu-controller-network
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$IdentityName,

    [Parameter(Mandatory = $true)]
    [string]$IdentityResourceGroup,

    [string]$Location = "australiaeast",

    [Parameter(Mandatory = $true)]
    [string]$AksResourceGroup,

    [Parameter(Mandatory = $true)]
    [string]$AksClusterName,

    [string]$Namespace = "flux-system",

    [Parameter(Mandatory = $true)]
    [string]$ServiceAccountName,

    [string]$RoleName = "Contributor",

    [string]$RoleScope,

    [string]$FederatedCredentialName
)

$ErrorActionPreference = "Stop"

if (-not $FederatedCredentialName) {
    $FederatedCredentialName = "fc-$ServiceAccountName"
}

Write-Host "== Checking Azure CLI login context =="
$account = az account show --query "{subscriptionId:id, tenantId:tenantId}" -o json | ConvertFrom-Json
if (-not $account) {
    throw "Not logged in to Azure CLI. Run 'az login' first."
}
$subscriptionId = $account.subscriptionId
$tenantId = $account.tenantId

if (-not $RoleScope) {
    $RoleScope = "/subscriptions/$subscriptionId"
}

Write-Host "== Ensuring resource group '$IdentityResourceGroup' exists =="
az group create --name $IdentityResourceGroup --location $Location -o table | Out-Null

Write-Host "== Creating (or reusing) managed identity '$IdentityName' =="
$identity = az identity show --name $IdentityName --resource-group $IdentityResourceGroup -o json 2>$null | ConvertFrom-Json
if (-not $identity) {
    $identity = az identity create --name $IdentityName --resource-group $IdentityResourceGroup --location $Location -o json | ConvertFrom-Json
}
$clientId = $identity.clientId
$principalId = $identity.principalId
Write-Host "  clientId=$clientId principalId=$principalId"

Write-Host "== Ensuring role assignment '$RoleName' at scope '$RoleScope' =="
$existingAssignment = az role assignment list --assignee-object-id $principalId --scope $RoleScope --role $RoleName -o json | ConvertFrom-Json
if (-not $existingAssignment -or $existingAssignment.Count -eq 0) {
    az role assignment create `
        --assignee-object-id $principalId `
        --assignee-principal-type ServicePrincipal `
        --role $RoleName `
        --scope $RoleScope -o table | Out-Null
} else {
    Write-Host "  Role assignment already exists, skipping."
}

Write-Host "== Looking up AKS OIDC issuer URL =="
$oidcIssuerUrl = az aks show --resource-group $AksResourceGroup --name $AksClusterName --query "oidcIssuerProfile.issuerUrl" -o tsv
if (-not $oidcIssuerUrl) {
    throw "OIDC issuer is not enabled on cluster '$AksClusterName'. Run: az aks update --resource-group $AksResourceGroup --name $AksClusterName --enable-oidc-issuer --enable-workload-identity"
}
Write-Host "  issuerUrl=$oidcIssuerUrl"

$subject = "system:serviceaccount:${Namespace}:${ServiceAccountName}"
Write-Host "== Ensuring federated credential '$FederatedCredentialName' (subject=$subject) =="
$existingFc = az identity federated-credential show --name $FederatedCredentialName --identity-name $IdentityName --resource-group $IdentityResourceGroup -o json 2>$null | ConvertFrom-Json
if (-not $existingFc) {
    az identity federated-credential create `
        --name $FederatedCredentialName `
        --identity-name $IdentityName `
        --resource-group $IdentityResourceGroup `
        --issuer $oidcIssuerUrl `
        --subject $subject `
        --audience "api://AzureADTokenExchange" -o table | Out-Null
} else {
    Write-Host "  Federated credential already exists, skipping."
}

Write-Host "== Applying ServiceAccount '$ServiceAccountName' in namespace '$Namespace' =="
@"
apiVersion: v1
kind: ServiceAccount
metadata:
  name: $ServiceAccountName
  namespace: $Namespace
  annotations:
    azure.workload.identity/client-id: "$clientId"
    azure.workload.identity/tenant-id: "$tenantId"
"@ | kubectl apply -f -

Write-Host "== Binding tf-runner-role ClusterRole to the ServiceAccount =="
@"
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: $ServiceAccountName-runner-binding
  namespace: $Namespace
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: tf-runner-role
subjects:
  - kind: ServiceAccount
    name: $ServiceAccountName
    namespace: $Namespace
"@ | kubectl apply -f -

Write-Host ""
Write-Host "== Done. Add the following to your Terraform CR (spec) =="
Write-Host "  serviceAccountName: $ServiceAccountName"
Write-Host "  runnerPodTemplate.metadata.labels: azure.workload.identity/use: `"true`""
Write-Host "  runnerPodTemplate.spec.env:"
Write-Host "    ARM_CLIENT_ID=$clientId"
Write-Host "    ARM_TENANT_ID=$tenantId"
Write-Host "    ARM_SUBSCRIPTION_ID=$subscriptionId"
Write-Host "    ARM_USE_AKS_WORKLOAD_IDENTITY=true"

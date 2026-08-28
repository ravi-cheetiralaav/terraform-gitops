<#
.SYNOPSIS
    Provisions a dev/test AKS cluster in australiaeast with OIDC issuer and
    Workload Identity enabled (required by the Tofu Controller GitOps setup).

.PARAMETER ResourceGroupName
    Resource group to create/use for the cluster.

.PARAMETER ClusterName
    Name of the AKS cluster.

.PARAMETER Location
    Azure region. Defaults to australiaeast.

.PARAMETER NodeCount
    Number of nodes in the default node pool. Defaults to 1 for dev/test.

.PARAMETER NodeVmSize
    VM size for the default node pool. Defaults to a burstable, low-cost SKU.

.EXAMPLE
    ./Provision-AksCluster.ps1 -ResourceGroupName aks-cluster-test -ClusterName aks-cluster-gitops
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $true)]
    [string]$ClusterName,

    [string]$Location = "australiaeast",

    [int]$NodeCount = 1,

    [string]$NodeVmSize = "Standard_B2s"
)

$ErrorActionPreference = "Stop"

Write-Host "Checking Azure CLI login..."
az account show --query "{subscriptionId:id, tenantId:tenantId}" -o table
if ($LASTEXITCODE -ne 0) {
    throw "Not logged in to Azure CLI. Run 'az login' first."
}

Write-Host "Creating resource group '$ResourceGroupName' in '$Location' (idempotent)..."
az group create --name $ResourceGroupName --location $Location -o table

Write-Host "Creating AKS cluster '$ClusterName' (dev/test tier: Free SKU, single node pool, $NodeVmSize)..."
az aks create `
    --resource-group $ResourceGroupName `
    --name $ClusterName `
    --location $Location `
    --tier free `
    --node-count $NodeCount `
    --node-vm-size $NodeVmSize `
    --enable-oidc-issuer `
    --enable-workload-identity `
    --generate-ssh-keys `
    --network-plugin azure `
    --enable-managed-identity `
    -o table

Write-Host "Fetching kubeconfig credentials..."
az aks get-credentials --resource-group $ResourceGroupName --name $ClusterName --overwrite-existing

Write-Host "Verifying OIDC issuer / Workload Identity status..."
az aks show --resource-group $ResourceGroupName --name $ClusterName `
    --query "{oidcIssuerEnabled:oidcIssuerProfile.enabled, workloadIdentityEnabled:securityProfile.workloadIdentity.enabled, oidcIssuerUrl:oidcIssuerProfile.issuerUrl, tier:sku.tier}" `
    -o json

kubectl get nodes

<#
.SYNOPSIS
    Deletes an AKS cluster (and optionally its resource group).

.DESCRIPTION
    Destructive operation. Requires explicit -Confirm:$true or interactive
    confirmation before deleting anything. Use -DeleteResourceGroup to also
    remove the resource group itself (only safe if the cluster is the only
    thing in that resource group).

.PARAMETER ResourceGroupName
    Resource group containing the AKS cluster.

.PARAMETER ClusterName
    Name of the AKS cluster to delete.

.PARAMETER DeleteResourceGroup
    Also delete the entire resource group after the cluster is removed.
    Only use this if the resource group contains nothing else you need.

.PARAMETER Force
    Skip the interactive confirmation prompt. Use with caution.

.EXAMPLE
    ./Delete-AksCluster.ps1 -ResourceGroupName aks-cluster-test -ClusterName aks-cluster-gitops

.EXAMPLE
    ./Delete-AksCluster.ps1 -ResourceGroupName aks-cluster-test -ClusterName aks-cluster-gitops -DeleteResourceGroup -Force
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $true)]
    [string]$ClusterName,

    [switch]$DeleteResourceGroup,

    [switch]$Force
)

$ErrorActionPreference = "Stop"

Write-Host "Checking Azure CLI login..."
az account show --query "{subscriptionId:id, tenantId:tenantId}" -o table
if ($LASTEXITCODE -ne 0) {
    throw "Not logged in to Azure CLI. Run 'az login' first."
}

$cluster = az aks show --resource-group $ResourceGroupName --name $ClusterName -o json 2>$null | ConvertFrom-Json
if (-not $cluster) {
    Write-Host "Cluster '$ClusterName' not found in resource group '$ResourceGroupName'. Nothing to do."
    exit 0
}

Write-Host ""
Write-Host "About to PERMANENTLY DELETE:"
Write-Host "  AKS cluster : $ClusterName"
Write-Host "  Location    : $($cluster.location)"
Write-Host "  Node pools  : $($cluster.agentPoolProfiles.Count)"
if ($DeleteResourceGroup) {
    Write-Host "  ALSO deleting resource group '$ResourceGroupName' and everything else in it"
}
Write-Host ""

if (-not $Force) {
    $confirmation = Read-Host "Type the cluster name '$ClusterName' to confirm deletion"
    if ($confirmation -ne $ClusterName) {
        Write-Host "Confirmation did not match. Aborting, nothing was deleted."
        exit 1
    }
}

Write-Host "== Deleting AKS cluster '$ClusterName' =="
az aks delete --resource-group $ResourceGroupName --name $ClusterName --yes --no-wait

Write-Host "Deletion initiated (running in the background on Azure's side)."
Write-Host "Check progress with: az aks show --resource-group $ResourceGroupName --name $ClusterName"

if ($DeleteResourceGroup) {
    Write-Host "== Waiting for cluster deletion to complete before deleting resource group =="
    az aks wait --resource-group $ResourceGroupName --name $ClusterName --deleted

    Write-Host "== Deleting resource group '$ResourceGroupName' =="
    az group delete --name $ResourceGroupName --yes --no-wait
    Write-Host "Resource group deletion initiated."
    Write-Host "Check progress with: az group show --name $ResourceGroupName"
}

Write-Host ""
Write-Host "Reminder: local kubeconfig context for this cluster is now stale."
Write-Host "Remove it with: kubectl config delete-context $ClusterName"

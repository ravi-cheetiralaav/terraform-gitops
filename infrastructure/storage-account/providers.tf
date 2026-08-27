terraform {
  required_version = ">= 1.6.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.90"
    }
  }
}

provider "azurerm" {
  features {}

  # Auth via Azure AD Workload Identity federated to the runner pod's
  # ServiceAccount; no client secret. Requires ARM_CLIENT_ID, ARM_TENANT_ID,
  # ARM_SUBSCRIPTION_ID and AZURE_FEDERATED_TOKEN_FILE in the runner env.
  use_aks_workload_identity = true
}

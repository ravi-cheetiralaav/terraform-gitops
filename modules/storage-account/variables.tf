variable "resource_group_name" {
  description = "Name of the resource group that will contain the storage account."
  type        = string
}

variable "location" {
  description = "Azure region for the resource group and storage account."
  type        = string
  default     = "eastus"
}

variable "storage_account_name" {
  description = "Globally unique name for the storage account (3-24 lowercase alphanumeric characters)."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]{3,24}$", var.storage_account_name))
    error_message = "storage_account_name must be 3-24 lowercase letters and numbers only."
  }
}

variable "account_tier" {
  description = "Performance tier of the storage account."
  type        = string
  default     = "Standard"
}

variable "account_replication_type" {
  description = "Replication strategy for the storage account."
  type        = string
  default     = "LRS"
}

variable "tags" {
  description = "Tags applied to the resource group and storage account."
  type        = map(string)
  default     = {}
}

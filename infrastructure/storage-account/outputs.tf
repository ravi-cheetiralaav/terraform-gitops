output "storage_account_id" {
  description = "Resource ID of the storage account."
  value       = module.storage_account.storage_account_id
}

output "storage_account_name" {
  description = "Name of the storage account."
  value       = module.storage_account.storage_account_name
}

output "primary_blob_endpoint" {
  description = "Primary blob service endpoint."
  value       = module.storage_account.primary_blob_endpoint
}

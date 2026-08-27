resource "azurerm_resource_group" "this" {
  name     = var.resource_group_name
  location = var.location
  tags     = var.tags
}

resource "azurerm_storage_account" "this" {
  name                     = var.storage_account_name
  resource_group_name      = azurerm_resource_group.this.name
  location                 = azurerm_resource_group.this.location
  account_tier             = var.account_tier
  account_replication_type = var.account_replication_type

  # Deny plaintext connections; require TLS 1.2 for all clients
  min_tls_version                = "TLS1_2"
  enable_https_traffic_only      = true
  allow_nested_items_to_be_public = false

  tags = var.tags
}

# ============================================================================
# mcp-azure-personal — Azure infrastructure
# ============================================================================
# Provisions the UAMI, federated credential, role assignments, and KV-published
# client ID for the mcp-azure-personal MCP server. The chart in ../chart/
# consumes the KV secret via ExternalSecret.
#
# Historical note: these resources were originally defined in
# nelsong6/tank-operator's infra/mcp.tf alongside other MCP servers. The
# companion tank-operator PR deletes them from that state (Azure destroys
# them); merging this PR's apply afterward creates them fresh here with the
# correct `aks_namespace = "mcp-azure-personal"`. Destroy-recreate rather
# than tofu-state-transfer because the existing FIC subject was stale anyway
# (built when the namespace was still "mcp-azure", never updated after the
# chart rename in #12), so workload identity was already broken — no live
# auth to preserve.
# ============================================================================

module "mcp_azure_personal" {
  source = "./mcp-server"

  name                     = "azure-personal"
  resource_group_name      = data.azurerm_resource_group.main.name
  resource_group_location  = data.azurerm_resource_group.main.location
  key_vault_id             = data.azurerm_key_vault.main.id
  aks_oidc_issuer_url      = local.aks_oidc_issuer_url
  aks_namespace            = "mcp-azure-personal"
  aks_service_account_name = "mcp-azure-personal"

  role_assignments = {
    # Broad subscription control plane: the MCP server's ARM tools
    # (arm_list_resources, arm_get_resource, run_aks_command, delete_*,
    # uami_upsert_federated_credential, etc.) all run against ARM. Anyone
    # authenticated to this MCP inherits this — the destructive surface is
    # narrowed by the tools themselves (exact-name confirmations on deletes,
    # dry_run defaults on writes).
    "subscription-operator" = {
      scope                = "/subscriptions/${data.azurerm_client_config.current.subscription_id}"
      role_definition_name = "Contributor"
    }
    # Data-plane RBAC for romaine-kv. Subscription Contributor covers the
    # control plane but not secret reads/writes — Secrets Officer is what
    # the keyvault_get_secret / keyvault_set_secret tools call against.
    "romaine-kv-secrets-officer" = {
      scope                = data.azurerm_key_vault.main.id
      role_definition_name = "Key Vault Secrets Officer"
    }
  }
}

# ----------------------------------------------------------------------------
# Cosmos data-plane access (cosmos_query_items et al.)
# ----------------------------------------------------------------------------
# Cosmos SQL API uses its own RBAC system, not ARM RBAC — even Reader at
# subscription scope doesn't grant data-plane reads. Grant account-scope
# Built-in Data Contributor on the Cosmos accounts the MCP needs.
resource "azurerm_cosmosdb_sql_role_assignment" "infra_serverless_contributor" {
  resource_group_name = data.azurerm_resource_group.main.name
  account_name        = data.azurerm_cosmosdb_account.infra_serverless.name
  role_definition_id  = "${data.azurerm_cosmosdb_account.infra_serverless.id}/sqlRoleDefinitions/00000000-0000-0000-0000-000000000002"
  principal_id        = module.mcp_azure_personal.managed_identity_principal_id
  scope               = data.azurerm_cosmosdb_account.infra_serverless.id
}

# ----------------------------------------------------------------------------
# tank-operator AKS runCommand access (run_aks_command tool)
# ----------------------------------------------------------------------------
# Cross-subscription grant. This UAMI lives in the workload subscription
# alongside the rest of the platform; the AKS cluster lives in a separate
# subscription ("romaine-life") and the "subscription-operator" Contributor
# above is scoped to data.azurerm_client_config.current.subscription_id, so
# it never reaches the cluster — hence the explicit scope here.
#
# Azure Kubernetes Service Contributor Role covers the two ARM actions
# run_aks_command needs:
#   Microsoft.ContainerService/managedClusters/runCommand/action
#   Microsoft.ContainerService/managedClusters/commandResults/read
#
# infra-aks has disableLocalAccounts=false and aadProfile=null, so
# runCommand falls through to the local admin kubeconfig path — no
# Kubernetes-side AAD role binding required beyond this ARM grant.
resource "azurerm_role_assignment" "tank_aks_runcommand" {
  scope                = var.tank_aks_cluster_id
  role_definition_name = "Azure Kubernetes Service Contributor Role"
  principal_id         = module.mcp_azure_personal.managed_identity_principal_id
}

# ----------------------------------------------------------------------------
# Postgres data-plane access (pg_query)
# ----------------------------------------------------------------------------
# Registers this MCP's UAMI as an Entra AD admin on the tank-operator Postgres
# Flexible Server so the pg_query tool can authenticate with a workload-
# identity token. Mirrors the pattern tank-operator uses for its own
# orchestrator UAMI (infra/postgres.tf in tank-operator).
#
# Admin rather than a narrower SQL role is the deliberately simple choice;
# the pg_query tool clamps every transaction to READ ONLY server-side, so
# the practical privilege is constrained at the call site. If we ever add a
# write tool, tighten this to a non-admin role with explicit SELECT grants
# created via SQL.
resource "azurerm_postgresql_flexible_server_active_directory_administrator" "tank_operator_db" {
  server_name         = var.tank_operator_postgres_server_name
  resource_group_name = var.tank_operator_postgres_resource_group
  tenant_id           = data.azurerm_client_config.current.tenant_id
  object_id           = module.mcp_azure_personal.managed_identity_principal_id
  principal_name      = module.mcp_azure_personal.managed_identity_name
  principal_type      = "ServicePrincipal"
}

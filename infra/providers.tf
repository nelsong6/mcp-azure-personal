provider "azurerm" {
  features {}
  use_oidc = true
  # subscription_id / tenant_id come from the ARM_* env vars the shared
  # tofu workflow exports for OIDC auth — no need to plumb them through
  # tofu variables.
  resource_provider_registrations = "none"
}

# Cluster-subscription provider for any role assignment / read against
# resources in the AKS cluster's sub (which is separate from this stack's
# workload sub by default — see var.cluster_subscription_id). Used by the
# UAMI's Reader/Cost Management Reader grants and by the AKS
# runCommand role assignment in main.tf. Authenticates via OIDC against
# this stack's CI SP, which infra-bootstrap grants Owner on the cluster
# sub by default.
provider "azurerm" {
  alias = "cluster"

  features {}
  use_oidc                        = true
  subscription_id                 = var.cluster_subscription_id
  resource_provider_registrations = "none"
}

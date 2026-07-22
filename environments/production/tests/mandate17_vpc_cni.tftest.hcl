mock_provider "aws" {}
mock_provider "aws" {
  alias = "cur"
}
mock_provider "archive" {}
mock_provider "helm" {}
mock_provider "kubernetes" {}
mock_provider "random" {}
mock_provider "tls" {}

run "vpc_cni_network_policy_contract" {
  command = plan

  plan_options {
    target = [module.eks]
  }

  assert {
    condition     = jsondecode(var.addons["vpc-cni"].configuration_values).enableNetworkPolicy == "true"
    error_message = "VPC CNI NetworkPolicy controller must be enabled."
  }

  assert {
    condition     = jsondecode(var.addons["vpc-cni"].configuration_values).env.NETWORK_POLICY_ENFORCING_MODE == "standard"
    error_message = "Mandate 17 rollout must keep VPC CNI enforcement in standard mode."
  }

  assert {
    condition     = jsondecode(var.addons["vpc-cni"].configuration_values).env.ENABLE_PREFIX_DELEGATION == "true"
    error_message = "VPC CNI prefix delegation must not be removed."
  }

  assert {
    condition     = jsondecode(var.addons["vpc-cni"].configuration_values).env.WARM_PREFIX_TARGET == "1"
    error_message = "VPC CNI warm prefix target must not drift."
  }

  assert {
    condition = alltrue([
      length(jsondecode(var.addons["vpc-cni"].configuration_values).resources.requests.cpu) > 0,
      length(jsondecode(var.addons["vpc-cni"].configuration_values).resources.limits.memory) > 0,
      length(jsondecode(var.addons["vpc-cni"].configuration_values).init.resources.requests.cpu) > 0,
      length(jsondecode(var.addons["vpc-cni"].configuration_values).nodeAgent.resources.requests.cpu) > 0,
    ])
    error_message = "Existing VPC CNI, init, and node-agent resources must remain configured."
  }
}

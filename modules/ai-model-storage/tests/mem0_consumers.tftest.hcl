mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "123456789012"
    }
  }

  # aws_iam_policy_document is normally evaluated locally by the AWS provider.
  # The mock provider replaces all data sources, so return a syntactically valid
  # policy document for the mocked aws_iam_role resources.
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }
}

run "consumer_roles_are_isolated" {
  command = plan

  variables {
    name                    = "techx-dev-tf2"
    aws_region              = "us-east-1"
    vpc_id                  = "vpc-12345678"
    private_route_table_ids = ["rtb-12345678"]
    oidc_provider_arn       = "arn:aws:iam::123456789012:oidc-provider/example.eks.amazonaws.com/id/EXAMPLE"
    oidc_issuer_url         = "https://example.eks.amazonaws.com/id/EXAMPLE"
    consumers = {
      product-reviews = {
        namespace            = "techx-corp-dev"
        service_account_name = "product-reviews"
        model_prefix         = "protectai/deberta-v3-base-prompt-injection-v2/"
        allow_list_bucket    = true
      }
      shopping-copilot = {
        namespace                     = "techx-corp-dev"
        service_account_name          = "shopping-copilot"
        model_prefix                  = "protectai/deberta-v3-base-prompt-injection-v2/"
        allow_list_bucket             = true
        bedrock_inference_profile_ids = ["global.amazon.nova-2-lite-v1:0"]
      }
      mem0 = {
        namespace            = "techx-corp-dev"
        service_account_name = "mem0"
        model_prefix         = "fastembed/paraphrase-multilingual-MiniLM-L12-v2/"
      }
    }
    database_iam_auth = {
      mem0 = {
        db_resource_id = "db-ABCDEFGHIJKLMNOPQRSTUVWX"
        database_user  = "mem0_app"
      }
    }
  }

  assert {
    condition     = aws_iam_role.model_read["mem0"].name == "techx-dev-tf2-mem0-model-read"
    error_message = "Mem0 must receive a dedicated IRSA role."
  }

  assert {
    condition     = output.consumer_access_contracts["mem0"].service_account_subject == "system:serviceaccount:techx-corp-dev:mem0"
    error_message = "The Mem0 role trust policy must only target the Mem0 ServiceAccount."
  }

  assert {
    condition     = output.consumer_access_contracts["mem0"].model_prefix == "fastembed/paraphrase-multilingual-MiniLM-L12-v2/"
    error_message = "The Mem0 policy must be scoped to the FastEmbed prefix."
  }

  assert {
    condition     = output.consumer_access_contracts["mem0"].role_name != output.consumer_access_contracts["product-reviews"].role_name
    error_message = "Mem0 and product-reviews must use separate roles."
  }

  assert {
    condition     = !output.consumer_access_contracts["mem0"].allow_list_bucket
    error_message = "Mem0 must not receive bucket-list permission."
  }

  assert {
    condition     = output.database_iam_access_contracts["mem0"].database_user == "mem0_app"
    error_message = "Mem0 IRSA must be scoped to the mem0_app database user."
  }

  assert {
    condition     = output.consumer_access_contracts["product-reviews"].allow_list_bucket
    error_message = "The existing product-reviews list permission must be preserved during the refactor."
  }

  assert {
    condition     = aws_iam_role.model_read["shopping-copilot"].name == "techx-dev-tf2-shopping-copilot-model-read"
    error_message = "Shopping Copilot must receive a dedicated IRSA role for ProtectAI weights."
  }

  assert {
    condition     = output.consumer_access_contracts["shopping-copilot"].service_account_subject == "system:serviceaccount:techx-corp-dev:shopping-copilot"
    error_message = "The Shopping Copilot role trust policy must only target its ServiceAccount."
  }

  assert {
    condition     = output.consumer_access_contracts["shopping-copilot"].model_prefix == "protectai/deberta-v3-base-prompt-injection-v2/"
    error_message = "Shopping Copilot must share the ProtectAI guardrail model prefix with product-reviews."
  }

  assert {
    condition     = output.consumer_access_contracts["shopping-copilot"].role_name != output.consumer_access_contracts["product-reviews"].role_name
    error_message = "Shopping Copilot and product-reviews must use separate IRSA roles even when sharing a model prefix."
  }

  assert {
    condition     = output.consumer_access_contracts["shopping-copilot"].allow_list_bucket
    error_message = "Shopping Copilot must retain ListBucket on the ProtectAI prefix for init-container download."
  }

  assert {
    condition     = length(output.consumer_access_contracts["shopping-copilot"].bedrock_inference_profile_ids) == 1 && contains(output.consumer_access_contracts["shopping-copilot"].bedrock_inference_profile_ids, "global.amazon.nova-2-lite-v1:0")
    error_message = "Shopping Copilot must be limited to the approved Nova inference profile."
  }

  assert {
    condition = (
      length(output.consumer_access_contracts["shopping-copilot"].bedrock_foundation_model_ids) == 1 &&
      contains(output.consumer_access_contracts["shopping-copilot"].bedrock_foundation_model_ids, "amazon.nova-2-lite-v1:0")
    )
    error_message = "Shopping Copilot Bedrock IRSA must derive the Nova foundation model id from the global inference profile."
  }

  assert {
    condition     = length(output.consumer_access_contracts["product-reviews"].bedrock_foundation_model_ids) == 0
    error_message = "Consumers without Bedrock profiles must not receive foundation-model ids."
  }
}

# Change trail: @hungxqt - 2026-07-20 - Assert Bedrock foundation-model ids derived from inference profiles.

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
      mem0 = {
        namespace            = "techx-corp-dev"
        service_account_name = "mem0"
        model_prefix         = "fastembed/paraphrase-multilingual-MiniLM-L12-v2/"
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
    condition     = output.consumer_access_contracts["product-reviews"].allow_list_bucket
    error_message = "The existing product-reviews list permission must be preserved during the refactor."
  }
}

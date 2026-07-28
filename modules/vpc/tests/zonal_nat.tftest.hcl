run "invalid_cross_az_nat" {
  command = plan

  variables {
    name       = "test-vpc"
    cidr_block = "10.0.0.0/16"
    public_subnets = {
      "pub-1a" = { cidr_block = "10.0.1.0/24", availability_zone = "us-east-1a" }
      "pub-1b" = { cidr_block = "10.0.2.0/24", availability_zone = "us-east-1b" }
    }
    nat_gateways = {
      "nat-1a" = { public_subnet_key = "pub-1a" }
      "nat-1b" = { public_subnet_key = "pub-1b" }
    }
    private_subnets = {
      "priv-1a" = { cidr_block = "10.0.10.0/24", availability_zone = "us-east-1a", nat_gateway_key = "nat-1b" }
    }
  }

  expect_failures = [
    var.private_subnets,
  ]
}

run "invalid_unknown_nat" {
  command = plan

  variables {
    name       = "test-vpc"
    cidr_block = "10.0.0.0/16"
    public_subnets = {
      "pub-1a" = { cidr_block = "10.0.1.0/24", availability_zone = "us-east-1a" }
    }
    nat_gateways = {
      "nat-1a" = { public_subnet_key = "pub-1a" }
    }
    private_subnets = {
      "priv-1a" = { cidr_block = "10.0.10.0/24", availability_zone = "us-east-1a", nat_gateway_key = "non-existent-nat" }
    }
  }

  expect_failures = [
    var.private_subnets,
  ]
}

run "valid_zonal_nat" {
  command = plan

  variables {
    name       = "test-vpc"
    cidr_block = "10.0.0.0/16"
    public_subnets = {
      "pub-1a" = { cidr_block = "10.0.1.0/24", availability_zone = "us-east-1a" }
      "pub-1b" = { cidr_block = "10.0.2.0/24", availability_zone = "us-east-1b" }
    }
    nat_gateways = {
      "nat-1a" = { public_subnet_key = "pub-1a" }
      "nat-1b" = { public_subnet_key = "pub-1b" }
    }
    private_subnets = {
      "priv-1a" = { cidr_block = "10.0.10.0/24", availability_zone = "us-east-1a", nat_gateway_key = "nat-1a" }
      "priv-1b" = { cidr_block = "10.0.11.0/24", availability_zone = "us-east-1b", nat_gateway_key = "nat-1b" }
    }
  }
}

# Change trail: @hungxqt - 2026-07-28 - Added zonal NAT invariant validation tests.

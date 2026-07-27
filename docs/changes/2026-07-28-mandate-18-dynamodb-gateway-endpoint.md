# Mandate 18 — DynamoDB gateway endpoint for checkout outbox

## Change

Create a DynamoDB **Gateway** VPC endpoint and associate it with every
production private route table. The endpoint is tagged for Mandate 18 and is
exported as `dynamodb_vpc_endpoint_id`.

## Why

Checkout uses DynamoDB as its durable outbox. It is an AWS-internal request
path, but without this endpoint it was sent through the egress proxy and then
through the NAT gateway. A DynamoDB Gateway Endpoint has no hourly endpoint
charge; its prefix-list route keeps the request within the AWS network.

The egress proxy remains in the path for destination allow-listing. No
application environment variable, flagd integration, or public Internet
egress policy is changed.

## Expected Terraform plan

The plan must create only `aws_vpc_endpoint.dynamodb` and add the DynamoDB
prefix-list route to the existing private route tables. It must not replace
the NAT gateways, subnets, VPC, EKS cluster, checkout Deployment, or DynamoDB
table.

## Evidence and verification

Capture NAT Gateway `BytesInFromSource` and `BytesOutToDestination` for seven
days **before** apply. After the endpoint is available, capture its route-table
associations and repeat the same NAT metric window. Verify checkout outbox
write/retry metrics, a successful checkout trace, and the storefront SLO
dashboard before declaring the reduction safe.

# Directive #3: commerce stateful HA

## Outcome

Production cart state moves from the singleton Kubernetes `valkey-cart`
StatefulSet to ElastiCache for Valkey:

- one primary and one replica;
- Multi-AZ placement and automatic failover;
- private subnets and an SG rule restricted to the EKS worker SG;
- encryption at rest and a daily snapshot;
- stable private DNS `valkey-cart.techx.internal` so Helm does not contain an
  AWS-generated endpoint.

Checkout order events use a DynamoDB on-demand outbox with point-in-time
recovery. A dedicated IRSA role is limited to the outbox table and its pending
event index. This lets the application publish Kafka asynchronously without
making the singleton broker part of the customer response path.

## Apply order

1. Merge/apply this infrastructure change.
2. Record `commerce_valkey_application_address`,
   `checkout_outbox_table_name`, and `checkout_outbox_role_arn` outputs.
3. Bake and promote the checkout image containing the outbox worker.
4. Merge the chart change that disables production `valkey-cart`, configures
   cart private DNS, checkout IRSA, and removes the Kafka init gate.
5. Verify cart/checkout before deleting any old Valkey PVC.

## Rollback

Re-enable the chart `valkey-cart` component and restore the previous cart
`VALKEY_ADDR`. Cart data created after managed-Valkey cutover is not copied back
automatically, so rollback must be declared a cart-session reset or use an
approved data migration. Keep the replication group until rollback is closed.

## Acceptance

- Trigger managed Valkey failover while k6 runs the public money flow.
- Stop Kafka and roll checkout; checkout remains Ready and within SLO.
- Restart Kafka and confirm the DynamoDB pending index drains.
- Perform the mentor-observed stateless node drain and attach the Directive #3
  evidence pack from the chart repository.

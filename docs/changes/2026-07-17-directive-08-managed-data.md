# Directive #8 managed data infrastructure

Production now declares the complete managed data tier. A private Multi-AZ RDS
PostgreSQL instance adds KMS encryption, forced TLS, seven-day PITR, protected
final snapshots, encrypted CloudWatch logs, and an RDS-managed master password.
Its endpoint metadata is published through Secrets Manager for ESO without
placing database addresses or credentials in Helm values.

MSK now rejects unauthenticated clients and uses SCRAM-SHA-512 over verified
TLS on port 9096. Terraform associates an AmazonMSK-prefixed Secrets Manager
credential with the cluster; ESO has read access to the exact credential and
bootstrap secrets. Existing private subnet, two-AZ broker, KMS, and logging
controls remain in place.

The production starting sizes are `db.t4g.small` Multi-AZ with 20 GiB gp3,
two `cache.t4g.micro` nodes, and two `kafka.t3.small` brokers with 10 GiB each.
Cutover, parity, rollback, and final cost approval are owned by the chart
Directive #8 runbook and must pass before self-hosted PVC deletion.


# Mem0 RDS PostgreSQL

## Summary

Mem0 uses a dedicated Amazon RDS for PostgreSQL database instead of a PostgreSQL StatefulSet in EKS.

## Infrastructure contract

- RDS PostgreSQL 17 in private subnets with no public endpoint.
- Storage encryption and forced SSL.
- Ingress on TCP 5432 only from the EKS cluster security group.
- RDS-managed master password in AWS Secrets Manager.
- The master credential is reserved for the migration/bootstrap Job.
- RDS IAM database authentication is enabled; the Mem0 IRSA role can connect only as `mem0_app`.
- The migration/bootstrap Job creates `mem0_app`, grants it `rds_iam`, and does not expose the RDS master credential to the Mem0 API.
- Production uses a cost-controlled Single-AZ `db.t4g.small` instance, while retaining deletion protection, final snapshot, 14-day backups and Performance Insights with the default 7-day retention.
- Development uses a smaller single-AZ instance while preserving the same engine and connection contract.

## Apply order

1. Run Terraform plan for development and review the new RDS instance, subnet group, parameter group, security group and ESO IAM update.
2. Apply development using the approved CDO owner role.
3. Record `mem0_postgresql_endpoint` and `mem0_postgresql_master_user_secret_arn` outputs.
4. Bootstrap the `mem0` application secret outside Terraform.
5. Deploy the chart migration Job to create the `mem0_app` role, enable `vector` and run `alembic upgrade head`.
6. Deploy Mem0 and complete add/search/delete/restart smoke tests.
7. Repeat plan, approval and apply for production.

## Security notes

- Terraform state contains no database password.
- The Mem0 API must not consume the RDS master secret.
- The database remains separate from the commerce PostgreSQL workload.
- Do not add a public RDS security-group rule for operator convenience; use an in-cluster Job or the approved private access path.

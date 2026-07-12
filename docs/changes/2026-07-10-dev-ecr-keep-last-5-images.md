# Change: Development ECR retain only 5 latest images

## Context

Development ECR storage grows with each CI publish (`sha-*` runtime tags and per-service `buildcache` layers). Development should retain fewer images than production.

## Before

* `environments/development` set `ecr_keep_last_n_images = 10`.
* Module `modules/ecr` lifecycle rule: expire when image count exceeds N (`tagStatus = any`).

## After

* Development keeps the **5** most recent images per service repository.
* Production remains at `ecr_keep_last_n_images = 20` (unchanged).
* ECR module lifecycle policy implementation unchanged; only the development count is tightened.

## Implementation

Set `ecr_keep_last_n_images = 5` in development `terraform.tfvars` and aligned the variable default.

## Files Changed

* `techx-corp-infra/environments/development/terraform.tfvars`
  * `ecr_keep_last_n_images`: `10` → `5`.
* `techx-corp-infra/environments/development/variables.tf`
  * Default for `ecr_keep_last_n_images`: `10` → `5`.
* `docs/changes/2026-07-10-dev-ecr-keep-last-5-images.md`
  * This change record.

## Impact

* **Infrastructure / cost:** Older images in `techx-dev-corp/*` are expired by ECR lifecycle once count exceeds 5 per repo.
* **Reliability:** Dev may only roll back among the five newest image digests per service.
* **CI/CD:** Unchanged; publishes still push `sha-*` and update `buildcache`. Lifecycle evaluates total images (any tag), so `buildcache` digests count toward the 5.
* **Production:** No change.

## Validation

After apply in the development stack:

```bash
cd techx-corp-infra/environments/development
terraform plan -var-file=terraform.tfvars
# Expect: aws_ecr_lifecycle_policy updates with countNumber 5 for each techx-dev-corp/* repo
terraform apply -var-file=terraform.tfvars
```

Spot-check one repo:

```bash
aws ecr get-lifecycle-policy \
  --repository-name techx-dev-corp/ad \
  --region us-east-1 \
  --query 'lifecyclePolicyText' --output text
```

Expect a rule with `countType=imageCountMoreThan` and `countNumber=5`.

## Migration or Deployment Notes

1. Apply only the **development** Terraform stack (not production).
2. Lifecycle expiration is asynchronous; existing images beyond 5 are removed by ECR over time, not instantly on apply.
3. No application or chart change required.

## Risks and Rollback

| Risk | Mitigation / rollback |
|---|---|
| Needed older dev image already expired | Re-run platform Build and Push for that commit, or temporarily raise N and re-push |
| `buildcache` competes with runtime digests for the 5 slots | Accepted for cost control in dev; raise N or add tag-prefix rules later if rebuilds suffer |

**Rollback:** Set `ecr_keep_last_n_images = 10` (or previous value) in development and re-apply.

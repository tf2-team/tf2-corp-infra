# FIS Skip-All Evidence — 2026-07-28

## Current state

Terraform code defines the wrapper-compatible `schemaVersion = 1` output and four stable internal template variants. The live account still exposes only the two old zone-keyed templates, so the new selection contract has not been deployed.

The current RDS snapshot is:

- Identifier: `techx-prod-tf2-postgresql`
- Primary AZ: `us-east-1a`
- Secondary AZ: `us-east-1b`
- Multi-AZ: `true`
- Status: `available`

At this snapshot, a live `1a` fault would select `1a-primary-in` and a live `1b` fault would select `1b-primary-outside`. Preview acceptance still requires skip-all evidence for all four immutable templates; the RDS primary must be queried again immediately before any live selection.

## Required preview

After the four-template apply and separate approval for the exact preview set, start each of the four template previews one at a time with:

```cmd
aws fis start-experiment --region us-east-1 --experiment-template-id <resolved-id> --experiment-options actionsMode=skip-all
```

Capture the experiment ID/state and resolved targets. Any required empty target, stale RDS relation, or unexpected RDS target/action keeps the gate failed.

**Skip-all gate: PENDING. No preview or live FIS experiment was started during this change.**

<!-- Change trail: @hungxqt - 2026-07-28 - Recorded pending skip-all evidence for all four templates across both AZs. -->
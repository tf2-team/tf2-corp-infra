# Change: Promote Production is manual-only (no push auto-apply)

## Summary

Removed the `push` trigger from **Promote Production** so production never plan/apply on merge or module changes. Production runs only when an operator starts **Actions → Promote Production → Run workflow**.

## Context

`docs/CI_CD_GUIDE.md` and the harden-CI change already described production as `workflow_dispatch` only, but `.github/workflows/terraform-promote-production.yml` still had:

```yaml
on:
  push:
    branches: [main]
    paths:
      - environments/production/**
      - modules/**
      - .github/workflows/**
  workflow_dispatch: ...
```

That meant a change to shared `modules/**` on `main` auto-started **both** Promote Dev and Promote Production.

## After

* Promote Production: **`workflow_dispatch` only** (`plan_only` input unchanged).
* Promote Dev: unchanged (still path-filtered auto-apply on push).
* Operator flow: test on development → when ready, run Promote Production (optional `plan_only=true` first).

## Files

* `.github/workflows/terraform-promote-production.yml`

## Verification

* YAML has no `on.push` for Promote Production.
* After merge to the default branch used by Actions: change a module → only Promote Dev should start; Promote Production must not appear until manual run.

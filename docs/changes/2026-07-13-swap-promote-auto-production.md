# Change: Auto-promote production; manual-only development

## Summary

Capstone operating model aligned with teams that apply on production first:

* **Promote Production** — auto on `push` to `main` (path-filtered) + `workflow_dispatch` (`plan_only` still available).
* **Promote Dev** — `workflow_dispatch` only (no push auto-apply).

## Before

* Dev: auto on push (`main` / path filters).
* Production: manual `workflow_dispatch` only.

## After

* Production: auto when `environments/production/**`, `modules/**`, or `.github/workflows/**` change on `main`.
* Development: run only when an operator starts **Actions → Promote Dev**.
* GitHub Environment gates (e.g. required reviewers on `production`) still apply to apply jobs.

## Files

* `.github/workflows/terraform-promote-dev.yml`
* `.github/workflows/terraform-promote-production.yml`
* `docs/CI_CD_GUIDE.md`
* `docs/SETUP.md`
* `docs/changes/2026-07-13-swap-promote-auto-production.md`

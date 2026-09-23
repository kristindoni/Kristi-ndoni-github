# node-3tier-app2 — Continuous Delivery on Azure

Forked/base application: [git.toptal.com/henrique/node-3tier-app2](https://git.toptal.com/henrique/node-3tier-app2)
(`web/`, `api/` — unchanged apart from a Dockerfile per tier, a one-line fix
so the API actually returns the `request_uuid` the web view expects, and
tests). This repo adds everything needed to run it as a scalable, secure,
continuously-deployed 3-tier system on Azure.

```
web <=> api <=> db
```

## Start here

- **[docs/architecture.md](docs/architecture.md)** — architecture diagram
  and how each task requirement is met (this is the "architectural
  diagram/PPT" deliverable).
- **[docs/runbook.md](docs/runbook.md)** — one-time setup, deploy flow,
  runtime/backup scripts, incident diagnosis.

## Repository layout

```
web/, api/          the application (forked base), + Dockerfile per tier, + tests
.github/workflows/   CI/CD pipeline (runs on GitHub Actions - see docs/runbook.md for why):
                     test -> build & push to ACR -> terraform plan -> apply, + a daily backup workflow
infra/terraform/     all infrastructure as code
  modules/           network, acr, keyvault, database, vmss, appgateway, monitoring, cdn, storage-backup
  environments/prod/ root module wiring the above together
  bootstrap/         one-time (non-Terraform) remote state setup
infra/scripts/
  runtime/           start.sh / stop.sh / scale.sh - operate VMSS nodes directly
  backup/            daily database backup scripts
docs/                architecture + runbook
```

## Stack

Azure · Terraform · VM Scale Sets + Docker + Azure Container Registry ·
Application Gateway v2 (WAF) · PostgreSQL Flexible Server (private,
zone-redundant HA) · Azure Front Door (CDN) · Log Analytics/Azure Monitor ·
GitHub Actions (pipeline code lives here in Toptal git; it executes against
a GitHub mirror since git.toptal.com has no active runners — see
docs/runbook.md).

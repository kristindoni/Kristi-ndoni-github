# node-3tier-app2 - Continuous Delivery on Azure

Base application: [git.toptal.com/henrique/node-3tier-app2](https://git.toptal.com/henrique/node-3tier-app2)
(`web/`, `api/`). I kept the app itself mostly as-is, just added a
Dockerfile per tier, a one-line fix so the API actually returns the
`request_uuid` the web view expects, a couple of tests, and everything
else in this repo needed to run it as a scalable, secure, continuously
deployed 3-tier system on Azure.

```
web <=> api <=> db
```

## Start here

- [docs/architecture.md](docs/architecture.md) - the architecture diagram
  and a walkthrough of how each task requirement is handled. This is the
  "architectural diagram/PPT" deliverable.
- [docs/runbook.md](docs/runbook.md) - one-time setup, deploy flow,
  runtime/backup scripts, how to diagnose an incident.

## Repository layout

```
web/, api/           the application, plus a Dockerfile per tier and tests
.github/workflows/   the CI/CD pipeline. Runs on GitHub Actions (see docs/runbook.md
                     for why, git.toptal.com has no active runners):
                     test -> build & push to ACR -> terraform plan -> apply, plus a daily backup job
infra/terraform/     all infrastructure as code
  modules/           network, acr, keyvault, database, vmss, appgateway, monitoring, cdn, storage-backup
  environments/prod/ root module wiring the above together
  bootstrap/         one-time, non-Terraform, remote state setup
infra/scripts/
  runtime/           start.sh / stop.sh / scale.sh, operate the VMSS nodes directly
  backup/            daily database backup scripts
docs/                architecture + runbook
```

## Stack

Azure, Terraform, VM Scale Sets running Docker containers pulled from
Azure Container Registry, an Application Gateway v2 with WAF in front,
PostgreSQL Flexible Server (private, no public endpoint), Log
Analytics/Azure Monitor, and GitHub Actions for CI/CD.

A couple of things are toggled off in the currently-deployed environment
because of subscription-level restrictions, not because the code doesn't
support them - see the "known simplifications" note in
docs/architecture.md (Postgres zone-redundant HA and Azure Front Door
both hit hard blocks on the trial subscription I deployed to).

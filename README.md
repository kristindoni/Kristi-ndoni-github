# Deploying a 3 tier application on Azure

Base application: [git.toptal.com/henrique/node-3tier-app2](https://git.toptal.com/henrique/node-3tier-app2)
(`web/`, `api/`). I kept the app itself mostly as-is, just added a
Dockerfile per tier, a one-line fix so the API actually returns the
`request_uuid` the web view expects, a couple of tests, and everything
else in this repo to run it as a scalable, secure, continuously deployed
3-tier system on Azure.

```
web
api 
db
```

## Documentation

This README is the entry point, everything else lives in `docs/`:

| Doc | What's in it |
|---|---|
| [docs/architecture.md](docs/architecture.md) | The diagram, a step-by-step walkthrough of how a request actually flows through the system, and the reasoning behind the bigger design choices (why VMSS over AKS, why one gateway, why the manual approval gate, and so on). |
| [docs/architecture.drawio](docs/architecture.drawio) | The same architecture, with real Azure icons. Open it in [diagrams.net](https://app.diagrams.net) to present it or export a PNG. |
| [docs/infrastructure.md](docs/infrastructure.md) | What each Terraform module actually provisions, plus every command to bootstrap, deploy, operate (start/stop/scale), and back up the environment. |
| [docs/challenges.md](docs/challenges.md) | The real problems I hit while building and running this against a live Azure subscription, and how I fixed each one. |

## Repository layout

```
web/, api/           the application, plus a Dockerfile per tier and tests
.github/workflows/   ci-cd.yml (test -> build -> plan -> apply) and backup.yml (daily pg_dump)
infra/terraform/
  modules/            network, acr, keyvault, database, vmss, appgateway, monitoring, cdn, storage-backup
  environments/prod/  root module wiring the above together
  bootstrap/          one-time, non-Terraform, remote state setup
  bootstrap-identity/ GitHub Actions OIDC identity, separate Terraform state
infra/scripts/
  runtime/            start.sh / stop.sh / scale.sh, operate the VMSS nodes directly
  backup/             daily database backup scripts
docs/                 architecture, infrastructure, and challenges write-ups
```

## Stack

Azure, Terraform, VM Scale Sets running Docker containers pulled from
Azure Container Registry, an Application Gateway v2 with WAF in front,
PostgreSQL Flexible Server (private, no public endpoint), Log
Analytics/Azure Monitor, and GitHub Actions for CI/CD.

A couple of things are toggled off in the currently-deployed environment
because of subscription-level restrictions, not because the code doesn't
support them, see "What's actually running vs. designed" in
[docs/architecture.md](docs/architecture.md).

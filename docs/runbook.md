# Operations runbook

## Why GitHub Actions instead of git.toptal.com's own CI

git.toptal.com's GitLab instance doesn't have any active runners for this
project, so a `.gitlab-ci.yml` pipeline there would just sit pending
forever (I actually tried this first and hit exactly that). The task
explicitly allows for this: "You can use another git provider to leverage
hooks, CI/CD... not enabled in Toptal's git." So the pipeline runs on
GitHub Actions against a mirror of this repo, while the pipeline code
itself (`.github/workflows/`) is still committed here in Toptal git, same
as everything else.

## One-time setup

1. Bootstrap Terraform's remote state (this one step is intentionally not
   Terraform, since the state storage has to exist before `terraform
   init` can use it):
   ```bash
   RESOURCE_GROUP=n3t-tfstate-rg STORAGE_ACCOUNT=n3ttfstate0001 \
     ./infra/terraform/bootstrap/create-state-backend.sh
   ```
2. Create a GitHub repo and push this repo to it as a mirror. Toptal git
   stays the actual source of truth, GitHub is only there to run the
   pipeline:
   ```bash
   git remote add github git@github.com:<you>/node-3tier-app2.git
   git push github main
   ```
3. Set up an Azure AD app registration with a federated credential for
   GitHub OIDC, scoped to `repo:<you>/node-3tier-app2:environment:production`
   and `repo:<you>/node-3tier-app2:ref:refs/heads/main`, so the pipeline
   never needs a stored client secret. Grant that app's service principal
   `Contributor` on the subscription or resource group.
4. In the GitHub repo, under Settings > Secrets and variables > Actions:
   - Secrets: `ARM_CLIENT_ID`, `ARM_TENANT_ID`, `ARM_SUBSCRIPTION_ID`,
     `ADMIN_SSH_PUBLIC_KEY`
   - Variables: `TF_BACKEND_RG`, `TF_BACKEND_SA`, `ACR_NAME`,
     `ACR_LOGIN_SERVER`, `BACKUP_STORAGE_ACCOUNT_NAME`, `RESOURCE_GROUP`,
     `NAME_PREFIX`, `DB_HOST`, `DB_USER`, `DB_NAME`, `DB_PASSWORD_SECRET_URI`

   Most of these come straight out of `terraform output` in
   `infra/terraform/environments/prod` once you've applied once.
5. Under Settings > Environments, create a `production` environment with
   required reviewers, that's the manual approval gate on `terraform
   apply`.
6. `.github/workflows/backup.yml` already runs on a daily cron
   (`0 3 * * *`), nothing else to set up for it beyond the secrets and
   variables above.

## Deploying

Push to `main` on the GitHub mirror: tests run, images get built and
pushed to ACR, `terraform plan` runs, and `apply` waits for a reviewer to
approve the `production` environment (see `docs/architecture.md` for why
apply specifically is a manual gate). Approving `apply` is the whole
deploy, the image tag bump alone triggers a zero-downtime rolling update
of the VMSS instances.

## Runtime handling scripts (`infra/scripts/runtime/`)

These read `RESOURCE_GROUP` and `NAME_PREFIX` from the environment.

```bash
export RESOURCE_GROUP=n3t-prod-rg NAME_PREFIX=n3t-prod

./scale.sh web 4        # manually scale the web tier to 4 instances
./scale.sh api 1        # scale the api tier down (still respects Terraform's min/max)
./stop.sh web           # deallocate all web instances, e.g. to save cost when not demoing
./stop.sh api 3         # deallocate just instance 3
./start.sh web          # bring all web instances back
```

## Backups (`infra/scripts/backup/`)

Postgres's own automated backups run with no script involved at all
(`backup_retention_days = 14`, geo-redundant, configured in Terraform).
Point-in-time restore is `az postgres flexible-server restore`.

On top of that there's a supplementary logical export:
`trigger-daily-backup.sh` runs daily from `.github/workflows/backup.yml`
and calls `pg-dump-and-upload.sh` on one API instance via `az vmss
run-command invoke`, which uploads a compressed `pg_dump` to the
`db-backups` blob container. I actually ran this by hand against the live
environment while building it out, here's what that looked like:

```bash
export RESOURCE_GROUP=n3t-prod-rg API_VMSS_NAME=n3t-prod-vmss-api \
       DB_HOST=n3t-prod-pg.postgres.database.azure.com DB_USER=pgadmin DB_NAME=appdb \
       DB_PASSWORD_SECRET_URI=https://n3t-prod-kv2.vault.azure.net/secrets/db-admin-password \
       STORAGE_ACCOUNT=n3tbackups7a6a994e STORAGE_CONTAINER=db-backups
./infra/scripts/backup/trigger-daily-backup.sh
```

(Worth noting: the script installs `postgresql-client-15` from PGDG the
first time it runs on an instance, since Ubuntu 22.04's default repo only
has v14 and `pg_dump` refuses to talk to a newer server than itself. Adds
maybe 10-15 seconds to the first run, nothing after that.)

## Diagnosing an incident

1. Log Analytics workspace (`module.monitoring.workspace_id`), query
   `Syslog` for app/container logs or `AzureDiagnostics` for App
   Gateway/Postgres.
2. Azure Monitor on the target VMSS, under Metrics, for CPU/network per
   instance.
3. Application Gateway > Backend health, to see which pool or instance is
   failing its probe.
4. The `<name_prefix>-appgw-unhealthy-hosts` alert fires to the
   `<name_prefix>-ops-ag` action group whenever a backend host goes
   unhealthy. Wire that up to email/Slack/PagerDuty as needed
   (`azurerm_monitor_action_group` in `infra/terraform/modules/monitoring`).

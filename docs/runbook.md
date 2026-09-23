# Operations runbook

## Why GitHub Actions, not git.toptal.com's own CI

git.toptal.com's GitLab instance has no active runners for this project (no
shared runners on the instance), so a `.gitlab-ci.yml` pipeline there just
sits stuck. The task explicitly allows this: "You can use another git
provider to leverage hooks, CI/CD... not enabled in Toptal's git." So the
pipeline **executes** on GitHub Actions against a GitHub mirror of this
repo, while the pipeline **code** (`.github/workflows/`) is committed to
Toptal git as required, same as everything else.

## One-time setup

1. Bootstrap Terraform remote state (imperative, run once):
   ```bash
   RESOURCE_GROUP=n3t-tfstate-rg STORAGE_ACCOUNT=n3ttfstate0001 \
     ./infra/terraform/bootstrap/create-state-backend.sh
   ```
2. Create a GitHub repo and push this repo to it as a mirror (Toptal git
   stays the canonical source; GitHub only runs the pipeline):
   ```bash
   git remote add github git@github.com:<you>/node-3tier-app2.git
   git push github main
   ```
3. Set up Azure AD federated credentials (OIDC) for GitHub Actions on an
   app registration, scoped to `repo:<you>/node-3tier-app2:environment:production`
   and `repo:<you>/node-3tier-app2:ref:refs/heads/main` — this avoids
   storing a long-lived client secret. Grant that app's service principal
   `Contributor` on the subscription/resource group.
4. In the GitHub repo → Settings → Secrets and variables → Actions:
   - **Secrets**: `ARM_CLIENT_ID`, `ARM_TENANT_ID`, `ARM_SUBSCRIPTION_ID`,
     `ADMIN_SSH_PUBLIC_KEY`
   - **Variables**: `TF_BACKEND_RG`, `TF_BACKEND_SA`, `ACR_NAME`,
     `ACR_LOGIN_SERVER`, `BACKUP_STORAGE_ACCOUNT_NAME`, `RESOURCE_GROUP`,
     `NAME_PREFIX`, `DB_HOST`, `DB_USER`, `DB_NAME`, `DB_PASSWORD_SECRET_URI`
   (Most of these are Terraform outputs after the first apply — see
   `terraform output` in `infra/terraform/environments/prod`.)
5. Settings → Environments → create `production` with **required
   reviewers** — this is the manual approval gate on `terraform apply`.
6. `.github/workflows/backup.yml` already runs on a daily cron
   (`0 3 * * *`); no extra setup needed beyond the secrets/variables above.

## Deploying

Push to `main` (on the GitHub mirror): tests run automatically, images
build and push to ACR automatically, `terraform plan` runs automatically,
and `apply` waits for a reviewer to approve the `production` environment
(see `docs/architecture.md` for why apply is a manual gate). Approving
`apply` is the entire deploy — the image-tag change alone triggers a
zero-downtime rolling update.

## Runtime handling scripts (`infra/scripts/runtime/`)

All scripts read `RESOURCE_GROUP` and `NAME_PREFIX` from the environment.

```bash
export RESOURCE_GROUP=n3t-prod-rg NAME_PREFIX=n3t-prod

./scale.sh web 4        # manually scale the web tier to 4 instances
./scale.sh api 1        # scale api tier down (respects Terraform min/max)
./stop.sh web           # deallocate all web instances (e.g. cost-saving in a demo env)
./stop.sh api 3         # deallocate just instance 3
./start.sh web          # bring all web instances back
```

## Backups (`infra/scripts/backup/`)

- **Primary**: PostgreSQL Flexible Server automated backups run with no
  script involved (configured in Terraform, `backup_retention_days = 14`,
  geo-redundant). Point-in-time restore via `az postgres flexible-server
  restore`.
- **Supplementary logical export**: `trigger-daily-backup.sh` runs from
  `.github/workflows/backup.yml` daily (see schedule above) and calls
  `pg-dump-and-upload.sh` on a single
  API instance via `az vmss run-command invoke`, uploading a compressed
  `pg_dump` to the `db-backups` blob container. To run it manually:
  ```bash
  export RESOURCE_GROUP=... API_VMSS_NAME=n3t-prod-vmss-api \
         DB_HOST=... DB_USER=pgadmin DB_NAME=appdb \
         DB_PASSWORD_SECRET_URI=https://n3t-prod-kv.vault.azure.net/secrets/db-admin-password \
         STORAGE_ACCOUNT=... STORAGE_CONTAINER=db-backups
  ./infra/scripts/backup/trigger-daily-backup.sh
  ```

## Diagnosing an incident

1. Log Analytics workspace (`module.monitoring.workspace_id`) → run KQL
   against `Syslog` (app/container logs) or `AzureDiagnostics` (App
   Gateway/Postgres).
2. Azure Monitor → the target VMSS → Metrics, for CPU/network per instance.
3. Application Gateway → Backend health, to see which pool/instance is
   failing probes.
4. The `<name_prefix>-appgw-unhealthy-hosts` alert fires to the
   `<name_prefix>-ops-ag` action group when any backend host is unhealthy —
   wire that to email/Slack/PagerDuty as needed (`azurerm_monitor_action_group`
   in `infra/terraform/modules/monitoring`).

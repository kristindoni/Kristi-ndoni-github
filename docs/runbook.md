# Operations runbook

## One-time setup

1. Bootstrap Terraform remote state (imperative, run once):
   ```bash
   RESOURCE_GROUP=n3t-tfstate-rg STORAGE_ACCOUNT=n3ttfstate0001 \
     ./infra/terraform/bootstrap/create-state-backend.sh
   ```
2. Create a service principal for CI and grant it `Contributor` on the
   subscription (or the target resource group) plus `Key Vault
   Administrator`/`Storage Blob Data Contributor` as needed:
   ```bash
   az ad sp create-for-rbac --name n3t-ci --role Contributor \
     --scopes /subscriptions/<sub-id>
   ```
3. In git.toptal.com → Settings → CI/CD → Variables, set (masked/protected):
   `ARM_CLIENT_ID`, `ARM_CLIENT_SECRET`, `ARM_TENANT_ID`, `ARM_SUBSCRIPTION_ID`,
   `TF_BACKEND_RG`, `TF_BACKEND_SA`, `ACR_NAME`, `ACR_LOGIN_SERVER`,
   `ADMIN_SSH_PUBLIC_KEY`, `BACKUP_STORAGE_ACCOUNT_NAME`, `RESOURCE_GROUP`,
   `NAME_PREFIX`, `DB_HOST`, `DB_USER`, `DB_NAME`, `DB_PASSWORD_SECRET_URI`.
   (Most of these are Terraform outputs after the first apply — see
   `terraform output` in `infra/terraform/environments/prod`.)
4. In git.toptal.com → CI/CD → Schedules, add a **daily** schedule targeting
   the default branch so the `backup:database` job runs.

## Deploying

Push to the default branch: tests run automatically, images build and push
to ACR automatically, `terraform plan` runs automatically, and `apply` waits
for manual approval in the pipeline (see `docs/architecture.md` for why
apply is a manual gate). Approving `apply` is the entire deploy — the
image-tag change alone triggers a zero-downtime rolling update.

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
- **Supplementary logical export**: `trigger-daily-backup.sh` runs from CI
  daily (see schedule above) and calls `pg-dump-and-upload.sh` on a single
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

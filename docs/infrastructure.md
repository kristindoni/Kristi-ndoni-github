# Infrastructure: what's provisioned and how to run it

This is the practical companion to [docs/architecture.md](architecture.md):
what each Terraform module actually creates, and the exact commands to
bootstrap, deploy, operate, and back up the environment.

## Terraform layout

```
infra/terraform/
  modules/
    network/          VNet, 4 subnets, NSGs, Postgres private DNS zone
    acr/               Azure Container Registry
    keyvault/          Key Vault (RBAC-authorized), generates the DB password
    database/          PostgreSQL Flexible Server, VNet-injected, no public access
    vmss/              one instance of this module per tier (web, api): VMSS,
                       autoscale setting, automatic instance repair, health
                       extension, monitor agent, optional Key Vault access
    appgateway/        App Gateway v2 + WAF policy, public + internal frontend
                       IPs, path routing, optional TLS listener
    monitoring/         Log Analytics workspace, data collection rules, the
                       unhealthy-backend-host alert
    cdn/                Azure Front Door (count = 0 unless enable_cdn = true)
    storage-backup/    storage account for backups, lifecycle policy
  environments/prod/    root module, wires all of the above together
  bootstrap/            one-time, non-Terraform: creates the remote state
                       storage account (has to exist before `terraform init`
                       can use it)
  bootstrap-identity/   separate Terraform state: the GitHub Actions OIDC
                       identity (Azure AD app, federated credentials, role
                       assignment). Kept out of the main state on purpose,
                       see "why a separate state" below.
```

### Why a separate state for the CI identity

Early on I had the OIDC app registration as a manual, undocumented `az ad
app create-for-rbac` step. That's exactly the kind of thing that breaks
"destroy and recreate quickly": if I ever destroy `environments/prod` to
save cost between sessions, the identity that lets the pipeline redeploy
it would still need to exist independently of the thing it manages. So
it's its own Terraform root with its own state file, applied once and
basically never touched again.

## One-time setup (already done for the live environment, documented for a fresh subscription)

1. Bootstrap Terraform's remote state:
   ```bash
   RESOURCE_GROUP=n3t-tfstate-rg STORAGE_ACCOUNT=n3ttfstate0001 \
     ./infra/terraform/bootstrap/create-state-backend.sh
   ```
2. Apply the GitHub OIDC identity:
   ```bash
   cd infra/terraform/bootstrap-identity
   terraform init
   terraform apply -var "github_repo=<owner>@<id>/<repo>@<id>"
   ```
   The `github_repo` format matters: GitHub's OIDC token subject pins the
   numeric owner/repo IDs, not just the plain names, once either has
   ever been renamed. If federation fails with `AADSTS700213`, the error
   message includes the exact subject GitHub actually sent, use that.
   `terraform output` gives you `client_id`, `tenant_id`,
   `subscription_id` for the next step.
3. Create a GitHub repo and push this repo to it as a mirror. Toptal git
   stays the source of truth, GitHub only runs the pipeline:
   ```bash
   git remote add github git@github.com:<you>/<repo>.git
   git push github main
   ```
4. In the GitHub repo, under Settings > Secrets and variables > Actions:
   - Secrets: `ARM_CLIENT_ID`, `ARM_TENANT_ID`, `ARM_SUBSCRIPTION_ID`,
     `ADMIN_SSH_PUBLIC_KEY`
   - Variables: `TF_BACKEND_RG`, `TF_BACKEND_SA`, `ACR_NAME`,
     `ACR_LOGIN_SERVER`, `BACKUP_STORAGE_ACCOUNT_NAME`, `DNS_LABEL`,
     `VM_SKU`, `ENABLE_CDN`, `ENABLE_POSTGRES_HA`, `TLS_CERT_SECRET_ID`,
     `LOCATION`, `NAME_PREFIX`, `KEYVAULT_ADMIN_PRINCIPAL_IDS` (JSON list
     of object IDs, see `docs/challenges.md` for why this one has to be
     explicit rather than derived automatically)
5. Under Settings > Environments, create a `production` environment with
   a required reviewer, that's the manual approval gate on `terraform
   apply`.
6. `.github/workflows/backup.yml` runs on a daily cron (`0 3 * * *`),
   nothing else to set up for it beyond the secrets/variables above.

## Deploying

Push to `main` on the GitHub mirror:

```
test-web, test-api (parallel)
        |
        v
build (push web + api images to ACR, tagged with git SHA)
        |
        v
terraform plan
        |
        v
terraform apply  <-- waits for a reviewer to approve the "production" environment
```

Approving `apply` is the whole deploy, the image tag bump alone triggers
the zero-downtime rolling update on both VMSS.

To run the same thing locally instead of through CI:

```bash
cd infra/terraform/environments/prod
terraform init \
  -backend-config="resource_group_name=<TF_BACKEND_RG>" \
  -backend-config="storage_account_name=<TF_BACKEND_SA>" \
  -backend-config="container_name=tfstate" \
  -backend-config="key=prod.terraform.tfstate"
terraform plan   # reads infra/terraform/environments/prod/terraform.tfvars (gitignored, real values)
terraform apply
```

## Runtime handling scripts (`infra/scripts/runtime/`)

These read `RESOURCE_GROUP` and `NAME_PREFIX` from the environment and
operate on the actual VMSS instances, this is the "start/stop/scale
nodes" the task asks for.

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
`db-backups` blob container. Running it by hand looks like this:

```bash
export RESOURCE_GROUP=n3t-prod-rg API_VMSS_NAME=n3t-prod-vmss-api \
       DB_HOST=n3t-prod-pg.postgres.database.azure.com DB_USER=pgadmin DB_NAME=appdb \
       DB_PASSWORD_SECRET_URI=https://n3t-prod-kv2.vault.azure.net/secrets/db-admin-password \
       STORAGE_ACCOUNT=n3tbackups7a6a994e STORAGE_CONTAINER=db-backups
./infra/scripts/backup/trigger-daily-backup.sh
```

(The script installs `postgresql-client-15` from PGDG the first time it
runs on an instance, since Ubuntu 22.04's default repo only has v14 and
`pg_dump` refuses to talk to a newer server than itself. Adds maybe
10-15 seconds to the first run, nothing after that.)

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

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

## One-time setup, from an empty subscription

This is the actual order things have to happen in, not just a list of
pieces, a couple of these steps depend on the one before it.

**Prerequisites**: Azure CLI, Terraform >= 1.5, Docker, logged in with
`az login` and pointed at the right subscription
(`az account set --subscription <id>`), and an SSH keypair you're willing
to use for break-glass VM access.

1. **Bootstrap Terraform's remote state.** This is the one piece that
   can't be Terraform itself, see "Why a separate state for the CI
   identity" above for the same chicken-and-egg reasoning applied to
   state storage:
   ```bash
   RESOURCE_GROUP=n3t-tfstate-rg STORAGE_ACCOUNT=<globally-unique-name> LOCATION=<region> \
     ./infra/terraform/bootstrap/create-state-backend.sh
   ```
2. **Create the GitHub repo that will mirror this one and run the
   pipeline**, before touching `bootstrap-identity`, it needs this repo
   to already exist so it can reference it:
   ```bash
   git remote add github git@github.com:<you>/<repo>.git
   git push github main
   ```
3. **Apply the GitHub OIDC identity**, note this has its own remote
   state, so it needs the same `-backend-config` flags as the main
   stack, just a different `key`:
   ```bash
   cd infra/terraform/bootstrap-identity
   terraform init \
     -backend-config="resource_group_name=<RESOURCE_GROUP from step 1>" \
     -backend-config="storage_account_name=<STORAGE_ACCOUNT from step 1>" \
     -backend-config="container_name=tfstate" \
     -backend-config="key=bootstrap-identity.terraform.tfstate"
   terraform apply -var "github_repo=<owner>/<repo>"
   ```
   Start with the plain `<owner>/<repo>` format. If federation fails on
   the pipeline's first run with `AADSTS700213`, the error includes the
   exact subject GitHub actually sent (`owner@<id>/repo@<id>`), once
   either the account or the repo has ever been renamed, GitHub pins the
   numeric IDs instead of the plain slug, re-apply with that exact
   string. `terraform output` now gives you `client_id`, `tenant_id`,
   `subscription_id`, and `principal_id`, the last one is the service
   principal's object ID, keep it for step 5.
4. **Copy `terraform.tfvars.example` to `terraform.tfvars`** in
   `infra/terraform/environments/prod` (gitignored, this is where the
   real values live) and fill in `name_prefix`, `location`,
   `admin_ssh_public_key`, and `backup_storage_account_name` and
   `dns_label` (both have to be globally unique, pick something
   specific). Leave `tls_certificate_key_vault_secret_id` empty for now,
   that's HTTP-only until you issue a certificate, see the TLS section
   in `docs/architecture.md`. For `keyvault_admin_principal_ids`,
   include your own object ID (`az ad signed-in-user show --query id -o tsv`)
   so you can manage secrets after this first apply.
5. **Apply the main stack locally, once**, to actually create
   everything and get real output values:
   ```bash
   cd infra/terraform/environments/prod
   terraform init \
     -backend-config="resource_group_name=<RESOURCE_GROUP from step 1>" \
     -backend-config="storage_account_name=<STORAGE_ACCOUNT from step 1>" \
     -backend-config="container_name=tfstate" \
     -backend-config="key=prod.terraform.tfstate"
   terraform apply
   ```
   Once this succeeds, add the `principal_id` from step 3 to
   `keyvault_admin_principal_ids` and re-apply, that's what lets the
   pipeline's own identity read secrets at apply time later on, not just
   create resources. `terraform output` now gives you `acr_login_server`,
   `backup_storage_account_name`, `key_vault_uri`, `postgres_fqdn`, and
   `app_public_url`.
6. **In the GitHub repo, under Settings > Secrets and variables >
   Actions:**
   - Secrets: `ARM_CLIENT_ID`, `ARM_TENANT_ID`, `ARM_SUBSCRIPTION_ID`
     (from step 3's outputs), `ADMIN_SSH_PUBLIC_KEY` (same key from
     step 4)
   - Variables: `TF_BACKEND_RG`, `TF_BACKEND_SA` (from step 1),
     `ACR_NAME` (the registry name itself, the part of
     `acr_login_server` before `.azurecr.io`), `ACR_LOGIN_SERVER` (the
     full output value), `BACKUP_STORAGE_ACCOUNT_NAME`, `DNS_LABEL`,
     `VM_SKU`, `ENABLE_CDN`, `ENABLE_POSTGRES_HA`, `TLS_CERT_SECRET_ID`,
     `LOCATION`, `NAME_PREFIX` (all the same values you put in
     `terraform.tfvars` in step 4), `KEYVAULT_ADMIN_PRINCIPAL_IDS` (JSON
     list, your object ID plus the pipeline's `principal_id` from step
     3, see `docs/challenges.md` for why this has to be explicit rather
     than derived automatically)
7. **Under Settings > Environments, create a `production` environment
   with a required reviewer**, that's the manual approval gate on
   `terraform apply`.
8. `.github/workflows/backup.yml` runs on a daily cron (`0 3 * * *`),
   nothing else to set up for it beyond the secrets/variables above.

From here on, every subsequent change goes through `git push` to `main`
on the GitHub mirror, see "Deploying" below, you shouldn't need to touch
Terraform locally again unless you're debugging.

## Destroying and recreating from scratch

`terraform destroy` against `environments/prod` (never against `bootstrap`
or `bootstrap-identity`, those are deliberately separate state so they
survive this) followed by `terraform apply` rebuilds the whole stack, with
two things worth knowing beforehand:

- **Key Vault will come back with its existing secrets intact**, including
  the manually-issued TLS certificate, as long as you recreate it with the
  same name in the same region. The provider is configured with
  `purge_soft_delete_on_destroy = false` and
  `recover_soft_deleted_key_vaults = true`, so `terraform apply` recovers
  the soft-deleted vault instead of failing or creating an empty one.
  Change the region or the vault name and that recovery path doesn't
  apply, you'd be back to reissuing the cert by hand.
- **ACR has no soft-delete, a destroy wipes every pushed image.** Don't
  follow a destroy with a bare local `terraform apply`, the VMSS
  instances would come up with nothing to pull and just retry forever.
  Recreate through the actual CI pipeline (push to `main`, or re-run the
  workflow) instead, it always builds and pushes images before it
  applies, so the image exists by the time the VMSS does.

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

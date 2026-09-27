# Infrastructure: what's provisioned and how to run it

This is the practical side of [docs/architecture.md](architecture.md).
What each Terraform module builds, and the actual commands I used to set
it up, deploy it, operate it, and back it up.

## What Terraform builds

```
infra/terraform/
  modules/
    network          VNet, 4 subnets, NSGs, Postgres private DNS zone
    acr               container registry
    keyvault          Key Vault, generates the DB password
    database          Postgres Flexible Server, private, no public access
    vmss              one per tier (web, api): scale set, autoscale,
                      instance repair, health checks, monitor agent
    appgateway        gateway, WAF policy, public + internal IPs, routing
    monitoring        Log Analytics workspace, alerts
    cdn               Front Door, only created if enable_cdn is true
    storage-backup    the backup storage account and its lifecycle rules
  environments/prod    the root module, wires all of the above together
  bootstrap            one-time, not Terraform, creates the state storage
                      account itself, since it has to exist before
                      terraform init can use it
  bootstrap-identity   separate Terraform state for the GitHub Actions
                      identity, kept apart so destroying environments/prod
                      never destroys the thing that redeploys it
```

## How the bigger modules are actually configured

The tree above is the one line summary, here's what's actually inside
the four modules that carry the most configuration.

### Application Gateway

This is the traffic router sitting in front of everything, it's also
where the firewall lives.

It can scale itself up under heavy traffic, same idea as the VMSS
autoscale but for the gateway itself rather than the app servers, these
are two completely separate things scaling independently.

The firewall uses OWASP's Core Rule Set, a well known, publicly
maintained list of patterns that match common attacks like SQL
injection. It's set to actually block matching requests, not just log
them and let them through.

It has two entry points. A public one, with the DNS name attached, that
the internet uses. And a private one, only reachable from inside the
VNet, that the web tier uses when it needs to call the api tier
internally, so that internal call doesn't have to go back out to the
internet and back in.

Routing is simple: anything under `/api/` goes to the api tier,
everything else goes to the web tier, and each has its own health check
so the gateway knows which instances are actually up.

HTTPS is optional from the gateway's point of view, if no certificate is
supplied it just runs plain HTTP, if one is supplied it adds the HTTPS
listener and starts redirecting HTTP to HTTPS automatically, except for
one specific path that has to stay on plain HTTP for certificate
renewal to keep working.

### Postgres

Flexible Server, version 15, sitting in the delegated subnet with public
access turned off. Backups are always on, two weeks retention, geo
redundant, that's a couple of properties on the resource itself, not a
separate system. Zone redundant HA is a single `dynamic` block that only
appears if `enable_high_availability` is true, when it is, Postgres runs
a synchronous standby in a different availability zone that takes over
automatically if the primary fails. Off right now because this
subscription doesn't offer it.

### Log Analytics and alerting

One workspace, everything lands in it. A data collection rule ships
syslog from every VMSS instance in Info level and above, and separate
diagnostic settings send the Application Gateway's access and firewall
logs, and Postgres's own logs, into the same workspace, so an incident
touching any tier is queryable in one place instead of three. There's
one alert defined so far, on the gateway's unhealthy backend host count,
wired to an action group that isn't connected to anything yet, wiring
that into email or Slack is a couple of lines whenever it's needed.

### CDN

Azure Front Door Standard, only created at all if `enable_cdn` is true,
otherwise this module is just skipped. Origin is the gateway's public
hostname, with its own health probe. Two routes, one matching
`/images/*` and `/stylesheets/*` that actually caches at the edge and
compresses what it serves, and a catch-all for everything else that
forwards straight to origin with no caching, since HTML and API
responses are dynamic per request and would be wrong to cache. Off right
now because Front Door is rejected outright on this subscription tier.

## Setting this up

This is written against my actual setup, not a generic template, swap
the names for your own if you're running this somewhere else.

You'll need the Azure CLI, Terraform 1.5 or newer, Docker, to be logged
in with `az login`, and an SSH key for break glass access to the VMs.

Bootstrap the state storage first, this is the one thing that can't be
Terraform itself:

```bash
RESOURCE_GROUP=n3t-tfstate-rg STORAGE_ACCOUNT=n3ttfstate7a6a994e LOCATION=swedencentral \
  ./infra/terraform/bootstrap/create-state-backend.sh
```

Create the GitHub repo that mirrors this one and runs the pipeline,
before the next step, since it needs to reference this repo:

```bash
git remote add github git@github.com:kristindoni/Kristi-ndoni-github.git
git push github main
```

Apply the GitHub OIDC identity, same backend as above with a different
state key:

```bash
cd infra/terraform/bootstrap-identity
terraform init \
  -backend-config="resource_group_name=n3t-tfstate-rg" \
  -backend-config="storage_account_name=n3ttfstate7a6a994e" \
  -backend-config="container_name=tfstate" \
  -backend-config="key=bootstrap-identity.terraform.tfstate"
terraform apply -var "github_repo=kristindoni/Kristi-ndoni-github"
```

That plain owner/repo value didn't actually work here, GitHub's token
pinned numeric IDs once the repo got its final name, and the failed run
told me the exact value to use instead
(`kristindoni@251518817/Kristi-ndoni-github@1388704715`), `terraform output` gives you `client_id`, `tenant_id`, `subscription_id`, and `principal_id`, keep all
four for later.

`terraform.tfvars` looks like this:

```
name_prefix                 = "n3t-prod"
location                    = "swedencentral"
admin_ssh_public_key        = "ssh-rsa AAAA... kndoni@onboardmeetings.com"
backup_storage_account_name = "n3tbackups7a6a994e"
dns_label                   = "n3tprod-kndoni"
vm_sku                      = "Standard_F1as_v7"
enable_cdn                  = false
enable_postgres_ha          = false
keyvault_admin_principal_ids = ["916aa70b-4312-4ea1-8d95-24b4c4affa97"]
```

Leave `tls_certificate_key_vault_secret_id` out for the first apply,
that's HTTP only until a certificate exists.

Apply the main stack once, locally, this is what actually creates
everything:

```bash
cd infra/terraform/environments/prod
terraform init \
  -backend-config="resource_group_name=n3t-tfstate-rg" \
  -backend-config="storage_account_name=n3ttfstate7a6a994e" \
  -backend-config="container_name=tfstate" \
  -backend-config="key=prod.terraform.tfstate"
terraform apply
```

Once that succeeds, add the identity's `principal_id`
(`daf3290a-7a6a-4317-8a18-4a39bb1205fb`) to `keyvault_admin_principal_ids`
and apply again, that's what lets the pipeline read secrets later on, not
just create resources.

In the GitHub repo, under Settings, Secrets and variables, Actions, I set:

Secrets: `ARM_CLIENT_ID`, `ARM_TENANT_ID`, `ARM_SUBSCRIPTION_ID` (from the
identity apply's output), `ADMIN_SSH_PUBLIC_KEY`.

Variables:

```
TF_BACKEND_RG                = n3t-tfstate-rg
TF_BACKEND_SA                = n3ttfstate7a6a994e
ACR_NAME                     = n3tprodacr
ACR_LOGIN_SERVER             = n3tprodacr.azurecr.io
BACKUP_STORAGE_ACCOUNT_NAME  = n3tbackups7a6a994e
DNS_LABEL                    = n3tprod-kndoni
VM_SKU                       = Standard_F1as_v7
ENABLE_CDN                   = false
ENABLE_POSTGRES_HA           = false
TLS_CERT_SECRET_ID           = https://n3t-prod-kv2.vault.azure.net/secrets/appgw-tls-cert
LOCATION                     = swedencentral
NAME_PREFIX                  = n3t-prod
KEYVAULT_ADMIN_PRINCIPAL_IDS = ["916aa70b-4312-4ea1-8d95-24b4c4affa97","daf3290a-7a6a-4317-8a18-4a39bb1205fb"]
RESOURCE_GROUP                = n3t-prod-rg
DB_HOST                       = n3t-prod-pg.postgres.database.azure.com
DB_USER                       = pgadmin
DB_NAME                       = appdb
DB_PASSWORD_SECRET_URI        = https://n3t-prod-kv2.vault.azure.net/secrets/db-admin-password
```

Last two things: under Settings, Environments, create a production
environment with a required reviewer, that's the approval gate on
applying infrastructure changes. And that's it, from here on every
change goes through a push to main, see Deploying below.

## Destroying and rebuilding

Destroying `environments/prod` and applying again rebuilds the whole
thing. Never destroy `bootstrap` or `bootstrap-identity`, those are kept
separate on purpose so they survive this.

Two things worth knowing. Key Vault comes back with its secrets intact,
including the TLS certificate, as long as you rebuild in the same region
under the same name, soft delete recovery handles that automatically.
Change either one and you'd need to reissue the certificate by hand
again. And the container registry has no such recovery, a destroy wipes
every image, so recreate through the pipeline rather than a bare local
apply, otherwise the new instances will have nothing to pull until
something pushes an image.

## Deploying

Pushing to main on the GitHub mirror runs tests, builds and pushes both
images tagged with the commit hash, plans the infrastructure change, then
waits for a reviewer to approve applying it. Approving that apply is the
whole deploy, the image tag change alone triggers a zero downtime rolling
update on both tiers.

To do the same thing locally instead:

```bash
cd infra/terraform/environments/prod
terraform init \
  -backend-config="resource_group_name=n3t-tfstate-rg" \
  -backend-config="storage_account_name=n3ttfstate7a6a994e" \
  -backend-config="container_name=tfstate" \
  -backend-config="key=prod.terraform.tfstate"
terraform plan
terraform apply
```

## Operating it day to day

`infra/scripts/runtime/` reads `RESOURCE_GROUP` and `NAME_PREFIX` from
the environment and operates on the real instances directly:

```bash
export RESOURCE_GROUP=n3t-prod-rg NAME_PREFIX=n3t-prod

./scale.sh web 4     # scale the web tier to 4 instances
./stop.sh web        # deallocate all web instances
./start.sh web       # bring them back
```

## Backups

Postgres backs itself up automatically, two weeks retention, geo
redundant, nothing to run for that. On top of that a daily job exports a
full dump and uploads it separately, you can trigger it by hand the same
way it runs in CI:

```bash
export RESOURCE_GROUP=n3t-prod-rg API_VMSS_NAME=n3t-prod-vmss-api \
       DB_HOST=n3t-prod-pg.postgres.database.azure.com DB_USER=pgadmin DB_NAME=appdb \
       DB_PASSWORD_SECRET_URI=https://n3t-prod-kv2.vault.azure.net/secrets/db-admin-password \
       STORAGE_ACCOUNT=n3tbackups7a6a994e STORAGE_CONTAINER=db-backups
./infra/scripts/backup/trigger-daily-backup.sh
```

## Getting a shell on an instance

There's no SSH path in from the internet on purpose, the web and api
tiers have no public IPs and their NSGs deny internet inbound entirely,
only the gateway is public. For everything I've actually needed, running
a command directly on an instance works fine and needs no network path
at all:

```bash
az vmss run-command invoke -g n3t-prod-rg -n n3t-prod-vmss-web --instance-id 6 \
  --command-id RunShellScript --scripts "docker ps"
```

This is the same mechanism the backup job and the TLS renewal hook use.
Real interactive SSH would mean either standing up Azure Bastion or
giving every instance in the tier a public IP, since the scale set shares
one network model across all instances, neither felt worth it for what's
actually needed here.

## Diagnosing a problem

Start with the Log Analytics workspace for logs, Azure Monitor on the
scale set for per instance CPU and network, and Application Gateway's
backend health view to see which pool or instance is failing its probe.
There's already an alert wired up for unhealthy backend hosts, hook that
into email or Slack as needed.

# Problems I hit and how I fixed them

This is the honest version of building this out, not the tidy version.
Everything here actually happened against the live environment while I
was building it, grouped by theme rather than strict chronological order.
I'm keeping it because it's a better demonstration of how I actually work
than a polished diagram is, and because it's the kind of thing I expect
to get asked about in the interview anyway.

## Finding a region and VM size that would actually deploy

This was the single biggest time sink. I started with `Standard_B2s` (2
vCPU) for both VMSS tiers in `northeurope`, and hit
`SkuNotAvailable... Capacity Restrictions`. Tried `Standard_B1s`, same
error, different SKU. Turned out the subscription has a **regional vCPU
quota of 4, total**, not per-VM-size, so 2 web + 2 api instances at 2
vCPU each was never going to fit regardless of which B-series size I
picked. I surveyed a handful of regions looking for one with actual
capacity and landed on `swedencentral`, then found
`Standard_F1as_v7` (1 vCPU, no capacity restrictions in that region),
which lets 2+2 instances fit inside the quota exactly. Made `vm_sku` a
Terraform variable specifically because of this, so it's a one-line
change instead of a design change if I ever run this on a subscription
with a normal quota.

Moving regions meant a full destroy and redeploy, VNets are region-locked
in Azure, you can't just move one. That in turn hit a second problem: Key
Vault has soft-delete and purge protection on, so the old vault's name
stayed reserved for the full 30-day retention window even after the
resource group was gone. I renamed the vault (`n3t-prod-kv` ->
`n3t-prod-kv2`) rather than wait it out.

## Terraform `count`/`for_each` on values that don't exist yet

Hit this twice, same root cause both times: Terraform needs to know
`count` or `for_each` at plan time, and a couple of places I'd wired it
to something that's genuinely unknown until after `apply` (a resource ID
that doesn't exist yet). The fix in both cases was the same pattern,
stop trying to derive a boolean from a not-yet-known value, and use an
explicit flag instead:

- `infra/terraform/modules/vmss/main.tf`: was
  `count = var.key_vault_id != "" ? 1 : 0`, changed to a real
  `enable_key_vault_access` boolean variable.
- `infra/terraform/modules/storage-backup/main.tf`: was
  `for_each = toset(var.principal_ids_with_write_access)`, changed to
  `count = length(...)` with explicit indexing, since `for_each` over a
  set built from an unknown value fails the same way.

## The Application Gateway's private frontend IP

WAF_v2 SKU rejected the internal frontend IP with
`ApplicationGatewayFrontendIpPrivateIpAddressInvalidAllocationType`. It
turns out it actually requires `Static` allocation with an explicit
address, `Dynamic` (which I'd assumed would be fine for an internal IP)
isn't supported. Fixed by pinning it to `10.20.0.10`.

Related: the TLS policy I picked first, `AppGwSslPolicy20150501`, is
deprecated and gets rejected outright now. Pinned to
`AppGwSslPolicy20220101` instead.

## A WAF false positive on the web tier's own internal call to the API

Once the WAF was on, the web tier's server-side call to the API (through
the gateway's internal IP, see architecture.md for why it's routed that
way) started getting blocked. Turned out the OWASP Core Rule Set flags a
missing `User-Agent` header and a numeric-IP `Host` header as anomalous,
both of which are true by default for a bare Node.js `request()` call
made server to server by IP. I set both headers explicitly in
`web/routes/index.js` rather than weaken the WAF policy for everyone to
work around one internal call.

## Postgres and SSL, in two different directions

The API's Postgres client needed `ssl: { rejectUnauthorized: false }` to
talk to Azure's managed Postgres, which requires SSL. I added that and
it immediately broke the CI test job, since the Postgres service
container in GitHub Actions doesn't support SSL at all. Fixed with a
`DBSSL` environment variable that's `false` in CI and unset (defaults to
on) in the real environment, so the same code path works against both
without a fork in the logic. Also had to fix the CI Postgres health
check itself, `pg_isready` was defaulting to checking the `root` user,
which doesn't exist in that container, changed it to
`pg_isready -U appuser`.

Separately: Postgres Flexible Server rejected the VNet-injected
configuration until I added `public_network_access_enabled = false`
explicitly, having the delegated subnet alone wasn't enough, Azure wants
both.

And zone-redundant HA hit `MultiAzHaIsOfferRestricted` in every region I
tried on this subscription tier. Made `enable_postgres_ha` a variable,
same pattern as the VM SKU issue, set to `false` for this deployment,
flip it on a normal subscription.

## Docker image built for the wrong architecture

Built the images on an arm64 machine, pushed them, and the VMSS instances
(amd64) just failed to start the container. Obvious in hindsight, easy to
miss in the moment. Fixed with
`docker buildx build --platform linux/amd64 ... --push` instead of a
plain `docker build`.

## VMSS quirks that don't show up until you actually operate one

A few things that only became obvious by actually running the
infrastructure, not by reading the Terraform:

- **`az vmss reimage` doesn't refetch the current model's `custom_data`.**
  After fixing a bug in the `API_HOST` environment variable baked into
  `custom_data`, reimaging the existing instances didn't pick up the
  fix, they kept booting with the old value. Had to actually delete the
  instances and let the scale set recreate them from the current model.
- **A rolling upgrade refuses to even start if current instances are
  already unhealthy** (`MaxUnhealthyInstancePercentExceededBeforeRollingUpgrade`).
  Makes sense as a safety rail, Azure won't roll an upgrade through a
  fleet it can't yet tell is healthy, but it meant I couldn't demonstrate
  a clean rolling upgrade until I'd already fixed the underlying health
  issue by deleting and recreating the bad instances first.
- **The `app.service` systemd unit had no `Restart=` policy.** First
  boot has an inherent race, the instance can come up before the image
  it needs has finished being pushed to ACR. Without a restart policy
  that's a permanent failure instead of a transient one. Added
  `Restart=on-failure` with a 15 second backoff so instances self-heal
  once the image actually exists.

## GitHub Actions and OIDC

- **First PAT I was given didn't have write access to the mirror repo,**
  regenerated with `Contents: Read and write` and that resolved it.
- **`AADSTS700213`**: the federated credential's subject didn't match
  what GitHub actually sent. GitHub's OIDC token pins the numeric
  owner/repo IDs once either has ever been renamed
  (`owner@<id>/repo@<id>`), not just the plain slug. The failed run's
  error log includes the exact subject it tried to use, I pulled that
  and updated the Terraform variable rather than guessing at the format.
- **A near miss**: partway through wiring up the pipeline's `-var` flags,
  I noticed during a `terraform plan` (not, thankfully, during `apply`)
  that `location` and `name_prefix` weren't being passed at all, meaning
  CI would have applied against their Terraform *defaults*
  (`westeurope`, and a different prefix) instead of the actual live
  values (`swedencentral`, `n3t-prod`). That would have destroyed and
  rebuilt the entire stack in the wrong region on the next automated
  apply. Caught it in the plan output before it ran, added both as
  explicit GitHub variables.
- **Key Vault admin access, chicken-and-egg.** The vault's admin role was
  originally assigned to `data.azurerm_client_config.current.object_id`,
  whoever's identity happens to be running Terraform at the time. That's
  fine until a *different* identity runs it next (a different person
  locally, or the CI service principal), and then it gets a 403 trying
  to read secrets it needs. Fixed by making `keyvault_admin_principal_ids`
  an explicit list covering every identity that legitimately needs
  access, rather than deriving it from whoever happens to be logged in.
- **Stale state locks**, twice, both times from a cancelled workflow run
  that didn't get to release its lease. Fixed with
  `az storage blob lease break --auth-mode key` against the state
  blob.
- **Transient "provider produced inconsistent result" errors** during
  apply, on a handful of resources (ACR, the WAF policy, a monitor action
  group, the VNet, both NSGs, the storage account) that were, in fact,
  created successfully in Azure, Terraform just lost track of them in
  state. Re-ran the plan and used `terraform import` to reconcile state
  with what was actually there rather than trying to recreate resources
  that already existed.

## `pg_dump` version mismatch

The backup script's first real run failed because Ubuntu 22.04 ships
`pg_dump` v14 by default, and Postgres Flexible Server was running v15.
`pg_dump` refuses to connect to a server newer than itself. Fixed by
having the script install `postgresql-client-15` from the official PGDG
apt repository instead of relying on Ubuntu's default package.

## What I'd take away from this

Most of these weren't design mistakes, they were things that only ever
show up once you actually deploy and operate the thing, not from reading
the Terraform or the architecture diagram. That's the main reason I kept
pushing to get a real pipeline running against a real environment instead
of stopping once the code "looked right": several of these (the OIDC
subject format, the health-check race, the rolling upgrade refusing to
start, the near-miss with the missing variables) would have been very
easy to miss entirely in a design-only submission.

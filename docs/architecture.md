# Architecture: step by step, and the choices behind it

This is the architecture write-up the task asks for ("An architectural
diagram / PPT to explain your architecture during the interview"). I kept
it as markdown instead of a slide deck, mostly because it's easier to
keep in sync with the actual Terraform as things change, and it renders
fine on both git.toptal.com and GitHub.

## Diagram

![Architecture diagram](architecture.png)

The source file is [docs/architecture.drawio](architecture.drawio),
open it in [diagrams.net](https://app.diagrams.net) if you want to
present it live or re-export it. The four gray boxes are the same four
groupings I use in the walkthrough below: **Public Entry** (the
gateway), **Compute** (the two VMSS tiers), **Data** (Postgres), and
**Supporting Services** (ACR + backup storage). Key Vault, GitHub
Actions, and Log Analytics sit outside those boxes because they're
cross-cutting, not part of the request path itself.

## How a request actually flows, step by step

Following the diagram left to right:

1. **Client hits Azure Front Door.** DNS resolves to Front Door's anycast
   edge, so the client connects to whichever PoP is geographically
   closest, not to a fixed region. This is the CDN requirement: static
   assets (`/images/*`, `/stylesheets/*`) get cached at the edge,
   everything else is forwarded to origin on every request (labeled
   `origin` on the diagram).
2. **Front Door forwards into the "Public Entry" box**, the Application
   Gateway's public IP. This is the one and only public entry point into
   the VNet. The gateway runs WAF_v2 with the OWASP Core Rule Set turned
   on, so anything that looks like SQLi, XSS, or a handful of other
   patterns gets blocked before it reaches either tier.
3. **The gateway does path-based routing into the "Compute" box.**
   `/api/*` goes to the API tier VMSS, `/*` goes to the web tier VMSS.
   Both sit in their own subnet with their own NSG, drawn as one grouped
   box because they're both stateless, both autoscaled, both rolling-
   updated the same way.
4. **The web tier calls the API tier internally**, but not directly, it
   loops back out through the gateway's *internal* frontend IP
   (`10.20.0.10`, static) using the same `/api/*` rule public traffic
   uses (that's the "server call via AppGW internal IP" arrow going back
   into Public Entry). I did this on purpose: one WAF policy and one
   routing table to reason about, the internal call gets the same
   protection public traffic gets, and no second internal load balancer
   just for east-west traffic between the two tiers.
5. **The API tier talks to Postgres over TCP 5432**, into the "Data" box.
   Only the API subnet's NSG allows that port inbound on the DB subnet.
   Postgres Flexible Server is VNet-injected (`delegated_subnet_id`) with
   `public_network_access_enabled = false`, so there's no public
   endpoint to even attempt to reach from outside the VNet.
6. **Both VMSS tiers pull their container images from the "Supporting
   Services" box** (Container Registry), using the instance's managed
   identity, no registry credentials stored anywhere. The API tier also
   reaches into Key Vault (drawn standalone, since both the API tier and
   the gateway depend on it) to fetch the DB password at boot, and the
   gateway does the same for its TLS certificate.
7. **Every tier ships logs and metrics to Log Analytics**, drawn in the
   top-right corner since it's a sink everything feeds, not a stop along
   the request path. Nobody needs to SSH into a host to read a log line.
8. **GitHub Actions, drawn bottom-left, outside the VNet boundary,
   is what puts everything else there in the first place.** It pushes
   built images into the Container Registry (`push image (OIDC)`) and,
   once a plan is approved, runs `terraform apply` against the gateway
   and everything behind it. It's drawn outside the dotted Azure
   Subscription boundary on purpose, it's the one piece of this that
   doesn't run inside Azure at all.
9. **A daily job (also GitHub Actions) triggers a `pg_dump`** on one API
   instance via `az vmss run-command` (so the runner itself never needs
   network access to the private DB) and uploads the result into the
   Supporting Services storage account.

## Design choices and why

### VMSS + Docker + ACR instead of AKS or Container Apps

The app wasn't containerized to start with, and the task's own wording
("runtime handling scripts: start/stop/scale nodes") points at VM-level
control, which a managed platform like Container Apps or AKS mostly
abstracts away, there's no real "node" to start or stop on those. VM
Scale Sets give:

- An actual node to script against (`infra/scripts/runtime/{start,stop,scale}.sh`).
- Rolling, health-gated updates built in, no orchestration to hand-roll.
- Docker without needing a custom VM image pipeline: the base image
  barely changes (Ubuntu + Docker + the monitoring agent, set up once via
  `custom_data`), and only the container image tag changes per deploy,
  pulled from ACR with the instance's managed identity.

I did consider AKS. It would have been the "more standard" answer, but
it also would have meant either abstracting away the exact thing the
task is asking me to demonstrate (node-level operational control), or
building fake node-shaped scripts around `kubectl` that don't really do
anything a real ops team would do. VMSS felt like the honest answer to
what was actually asked.

### One Application Gateway instead of two, or a separate internal load balancer

Both tiers being "publicly exposed" doesn't mean they need separate
public IPs. Path-based routing on a single gateway keeps one WAF policy,
one certificate, one thing to monitor, and matches how I'd actually run
this: the API isn't meant to be hit directly by end users anyway, it's
an implementation detail of the web tier that happens to also be
reachable at `/api/*` for direct testing.

### TLS via Key Vault + Let's Encrypt instead of a paid cert

The task doesn't require HTTPS explicitly, but shipping a plain-HTTP
public endpoint in 2026 felt wrong to hand in, and a real cert costs
money I didn't want to spend for an interview exercise. The gateway
reads the certificate out of Key Vault through a user-assigned managed
identity, so the private key never sits in Terraform state or anywhere
else. Plain HTTP redirects to HTTPS for everything except
`/.well-known/acme-challenge/*`, which stays on HTTP on purpose so
future renewals keep working.

One thing not automated: renewal. The cert was issued once by hand
(certbot in manual mode, with a hook script that drops the challenge
file straight into the running web container via `az vmss run-command`)
and expires in 90 days. Automating that would mean either a scheduled
job with the same hook approach, or switching to DNS-01 challenges if
the domain ever moves off `*.cloudapp.azure.com` to something with DNS I
actually control.

### GitHub Actions instead of git.toptal.com's own CI

git.toptal.com's GitLab instance has no active runners for this project,
a `.gitlab-ci.yml` pipeline there just sits pending forever, I actually
tried this first and hit exactly that. The task explicitly allows for
this ("You can use another git provider to leverage hooks, CI/CD... not
enabled in Toptal's git"). So the pipeline runs on GitHub Actions against
a mirror of this repo, while the pipeline code itself
(`.github/workflows/`) still lives here in Toptal git, same as
everything else. See [docs/infrastructure.md](infrastructure.md) for how
that's wired up and how to run it.

### Manual approval on `terraform apply`, not on the app deploy

I think that's the right split: an unattended infrastructure change is a
different class of risk than an unattended app deploy. The app deploy
(the image tag bump, and the rolling update it triggers) is what's
actually fully automated end to end. `terraform apply` waits for a
human, via a GitHub Environment with a required reviewer.

## How each requirement is met

| Requirement | Implementation |
|---|---|
| Web and API tiers exposed to the internet | One Application Gateway v2 with a public IP, doing path-based routing: `/api/*` goes to the API backend pool, everything else goes to web. |
| DB tier not accessible from the internet | Postgres Flexible Server is VNet-integrated with public network access turned off entirely, sitting in its own subnet whose NSG only allows TCP 5432 from the API subnet. |
| Fully provisioned via IaC | Everything (network, ACR, Key Vault, both VMSS, App Gateway, Postgres, Log Analytics, Front Door, Storage, and the GitHub OIDC identity used by the pipeline) is Terraform. Destroy the whole stack and `terraform apply` rebuilds it. |
| Handles server/instance failures | VMSS spreads instances across 3 Availability Zones, `automatic_instance_repair` replaces anything that fails its health probe, and an autoscale profile keeps a minimum instance floor. Verified live: deleted a running web instance directly, autoscale had a healthy replacement in under two minutes, site stayed at HTTP 200 the whole time. |
| Zero-downtime updates | Both VMSS run `upgrade_mode = "Rolling"`, gated by an `ApplicationHealthLinux` extension. A `terraform apply` with a new image tag triggers this automatically. Verified live: pushed a version bump through the pipeline and watched one instance roll to the new model while the other kept serving, no dropped requests. |
| Fully automated deploys, plus tests | GitHub Actions: test both tiers, build and push images to ACR tagged with the git SHA, `terraform plan`, then `terraform apply` behind a manual approval gate. Both tiers have real tests that run on every push, the API tests run against an actual Postgres service container rather than mocks. |
| Backups at least daily | Postgres's own automated backups (14 day retention, geo-redundant) run with no script involved. On top of that, a daily GitHub Actions workflow runs `pg_dump` on one API instance and uploads the compressed dump to geo-redundant storage with lifecycle tiering. |
| Logs accessible off-host | Every VMSS instance runs the AzureMonitorLinuxAgent extension, shipping syslog and container logs to a central Log Analytics workspace. App Gateway and Postgres diagnostics land there too. |
| Historical metrics, spotting bottlenecks | Log Analytics plus Azure Monitor metrics (CPU, App Gateway latency/unhealthy-host-count, Postgres metrics), 90 days of retention, queryable via KQL, with an alert on unhealthy backend hosts. |
| CDN, distributed by client location | Azure Front Door in front of the Application Gateway, caching static assets at the edge closest to each client, dynamic responses always go straight to origin. Toggled off in the live deployment, see below. |
| Deployable on a major cloud provider | Azure. |

## What's actually running vs. designed

The Terraform supports the full design above. What's live right now
differs in two places, both because of restrictions on the specific
Azure subscription I deployed to for this interview, not the code:

- **Postgres HA is off** (`enable_postgres_ha = false`). The subscription
  hit `MultiAzHaIsOfferRestricted` in every region I tried, zone-redundant
  HA just isn't offered on this tier. Flip the variable back to `true` on
  a normal subscription and it works as designed.
- **Front Door/CDN is off** (`enable_cdn = false`). Azure rejects it
  outright on trial/student subscriptions. Same story, flip
  `enable_cdn = true` on a standard subscription.

Also worth flagging: the subscription's regional vCPU quota is 4 total,
which ruled out the VM size I originally picked (`Standard_B2s`, 2 vCPU
each, would have needed 8 across both tiers). The live deployment uses
`Standard_F1as_v7` (1 vCPU) so 2 web + 2 api instances fit inside the
quota. `vm_sku` is a variable for exactly this reason. See
[docs/challenges.md](challenges.md) for the full story on how I found
that out.

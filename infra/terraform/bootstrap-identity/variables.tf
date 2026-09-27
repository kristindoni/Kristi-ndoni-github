variable "github_repo" {
  description = <<-EOT
    owner/repo on GitHub the pipeline executes from (see docs/infrastructure.md for
    why it's GitHub and not git.toptal.com). NOTE: this must match the exact
    subject GitHub's OIDC token actually presents, which can be
    "owner@<id>/repo@<id>" rather than the plain name if the account or repo
    was ever renamed - GitHub pins numeric IDs then to keep federation
    trust stable across future renames. Check a failed AADSTS700213 error
    for the real value rather than assuming the plain name.
  EOT
  type        = string
  default     = "kristindoni@251518817/Kristi-ndoni-github@1388704715"
}

variable "production_environment_name" {
  description = "GitHub Environment name used for the terraform apply approval gate."
  type        = string
  default     = "production"
}

variable "app_display_name" {
  type    = string
  default = "n3t-prod-github-actions"
}

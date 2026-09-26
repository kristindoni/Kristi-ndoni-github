variable "github_repo" {
  description = "owner/repo on GitHub the pipeline executes from (see docs/runbook.md for why it's GitHub and not git.toptal.com)."
  type        = string
  default     = "kristindoni/Kristi-ndoni-github"
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

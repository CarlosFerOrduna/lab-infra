locals {
  repos = toset([
    "lab-infra",
    "lab-gitops",
    "lab-ci-workflows",
  ])
}

resource "github_repository" "repo" {
  for_each = local.repos

  name       = each.key
  visibility = "private"

  has_issues   = true
  has_projects = true
  has_wiki     = false
}

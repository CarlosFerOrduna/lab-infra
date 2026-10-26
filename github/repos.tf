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

moved {
  from = github_repository.lab_infra
  to   = github_repository.repo["lab-infra"]
}

moved {
  from = github_repository.lab_gitops
  to   = github_repository.repo["lab-gitops"]
}

moved {
  from = github_repository.lab_ci_workflows
  to   = github_repository.repo["lab-ci-workflows"]
}

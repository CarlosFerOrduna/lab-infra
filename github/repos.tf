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
  visibility = "public"

  has_issues   = true
  has_projects = true
  has_wiki     = false

  allow_merge_commit     = false
  allow_squash_merge     = false
  allow_rebase_merge     = true
  delete_branch_on_merge = true

  security_and_analysis {
    secret_scanning {
      status = "enabled"
    }
    secret_scanning_push_protection {
      status = "enabled"
    }
  }
}

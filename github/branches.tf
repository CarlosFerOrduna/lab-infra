resource "github_branch_protection" "main" {
  for_each = github_repository.repo

  repository_id = each.value.node_id
  pattern       = "main"

  enforce_admins      = true
  allows_force_pushes = false
  allows_deletions    = false

  required_pull_request_reviews {
    required_approving_review_count = 0
  }
}

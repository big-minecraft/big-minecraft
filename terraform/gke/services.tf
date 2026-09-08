# APIs this project needs.
#
# Managed here rather than left as a documented manual step, because skipping it
# fails late and confusingly: `tofu plan` succeeds in full, then the first
# create returns a 403 SERVICE_DISABLED against a resource that has nothing
# wrong with it.
#
# disable_on_destroy is false on purpose. These are project-wide, and a project
# usually holds more than this cluster -- `tofu destroy` turning off Compute
# Engine for everything else in the project would be a surprising blast radius
# for tearing down one Kubernetes cluster.
resource "google_project_service" "required" {
  for_each = toset([
    "compute.googleapis.com",
    "container.googleapis.com",
  ])

  project = var.project_id
  service = each.value

  disable_on_destroy = false
}

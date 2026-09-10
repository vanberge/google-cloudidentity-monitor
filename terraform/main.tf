terraform {
  required_version = ">= 1.3.0"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 5.0.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

# 1. Enable Required GCP APIs
locals {
  services = [
    "run.googleapis.com",
    "cloudscheduler.googleapis.com",
    "cloudbuild.googleapis.com",
    "artifactregistry.googleapis.com",
    "iamcredentials.googleapis.com",
    "licensing.googleapis.com",
    "monitoring.googleapis.com",
    "logging.googleapis.com"
  ]
}

resource "google_project_service" "required_apis" {
  for_each           = toset(locals.services)
  project            = var.project_id
  service            = each.key
  disable_on_destroy = false
}

# 2. Artifact Registry Repository
resource "google_artifact_registry_repository" "repo" {
  project       = var.project_id
  location      = var.region
  repository_id = var.artifact_repo_name
  description   = "Docker repository for Cloud Identity License Monitor"
  format        = "DOCKER"

  depends_on = [google_project_service.required_apis]
}

# 3. Service Account
resource "google_service_account" "sa" {
  project      = var.project_id
  account_id   = var.service_account_name
  display_name = "Cloud Identity License Monitor Service Account"

  depends_on = [google_project_service.required_apis]
}

# 4. IAM Permissions for Service Account
resource "google_project_iam_member" "metric_writer" {
  project = var.project_id
  role    = "roles/monitoring.metricWriter"
  member  = "serviceAccount:${google_service_account.sa.email}"
}

resource "google_project_iam_member" "log_writer" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.sa.email}"
}

# Allow Service Account to self-sign JWTs (Keyless Domain-Wide Delegation)
resource "google_service_account_iam_member" "sa_token_creator" {
  service_account_id = google_service_account.sa.name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = "serviceAccount:${google_service_account.sa.email}"
}

# 5. Cloud Run Service
locals {
  image_uri = "${var.region}-docker.pkg.dev/${var.project_id}/${var.artifact_repo_name}/license-monitor:${var.image_tag}"
  domain    = var.workspace_customer_id != "" ? var.workspace_customer_id : element(split("@", var.workspace_admin_email), 1)
}

resource "google_cloud_run_v2_service" "monitor_service" {
  name     = var.service_name
  location = var.region
  project  = var.project_id

  template {
    service_account = google_service_account.sa.email

    containers {
      image = local.image_uri

      resources {
        limits = {
          cpu    = "1000m"
          memory = "512Mi"
        }
      }

      env {
        name  = "GCP_PROJECT_ID"
        value = var.project_id
      }
      env {
        name  = "SERVICE_ACCOUNT_EMAIL"
        value = google_service_account.sa.email
      }
      env {
        name  = "WORKSPACE_ADMIN_EMAIL"
        value = var.workspace_admin_email
      }
      env {
        name  = "WORKSPACE_CUSTOMER_ID"
        value = local.domain
      }
      env {
        name  = "TOTAL_PURCHASED_SEATS_PREMIUM"
        value = tostring(var.total_purchased_seats_premium)
      }
      env {
        name  = "TOTAL_PURCHASED_SEATS_FREE"
        value = tostring(var.total_purchased_seats_free)
      }
    }
  }

  depends_on = [
    google_project_service.required_apis,
    google_artifact_registry_repository.repo
  ]
}

# Allow Service Account to invoke Cloud Run Service
resource "google_cloud_run_v2_service_iam_member" "invoker" {
  project  = var.project_id
  location = var.region
  name     = google_cloud_run_v2_service.monitor_service.name
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.sa.email}"
}

# 6. Cloud Run Job (for on-demand / batch execution)
resource "google_cloud_run_v2_job" "monitor_job" {
  name     = var.job_name
  location = var.region
  project  = var.project_id

  template {
    template {
      service_account = google_service_account.sa.email

      containers {
        image   = local.image_uri
        command = ["python"]
        args    = ["main.py", "--run-once"]

        resources {
          limits = {
            cpu    = "1000m"
            memory = "512Mi"
          }
        }

        env {
          name  = "GCP_PROJECT_ID"
          value = var.project_id
        }
        env {
          name  = "SERVICE_ACCOUNT_EMAIL"
          value = google_service_account.sa.email
        }
        env {
          name  = "WORKSPACE_ADMIN_EMAIL"
          value = var.workspace_admin_email
        }
        env {
          name  = "WORKSPACE_CUSTOMER_ID"
          value = local.domain
        }
        env {
          name  = "TOTAL_PURCHASED_SEATS_PREMIUM"
          value = tostring(var.total_purchased_seats_premium)
        }
        env {
          name  = "TOTAL_PURCHASED_SEATS_FREE"
          value = tostring(var.total_purchased_seats_free)
        }
        env {
          name  = "RUN_ONCE"
          value = "true"
        }
      }
    }
  }

  depends_on = [
    google_project_service.required_apis,
    google_artifact_registry_repository.repo
  ]
}

# 7. Cloud Scheduler (Periodic Trigger)
resource "google_cloud_scheduler_job" "scheduler" {
  name        = var.scheduler_job_name
  description = "Triggers Cloud Identity license check on a periodic schedule"
  schedule    = var.cron_schedule
  time_zone   = "UTC"
  region      = var.region
  project     = var.project_id

  http_target {
    http_method = "POST"
    uri         = "${google_cloud_run_v2_service.monitor_service.uri}/check"

    oidc_token {
      service_account_email = google_service_account.sa.email
      audience              = google_cloud_run_v2_service.monitor_service.uri
    }
  }

  depends_on = [
    google_cloud_run_v2_service.monitor_service,
    google_cloud_run_v2_service_iam_member.invoker
  ]
}

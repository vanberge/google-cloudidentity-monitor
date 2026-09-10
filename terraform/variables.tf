variable "project_id" {
  description = "The Google Cloud Project ID where resources will be provisioned."
  type        = string
}

variable "region" {
  description = "Google Cloud region for Cloud Run, Artifact Registry, and Cloud Scheduler."
  type        = string
  default     = "us-central1"
}

variable "workspace_admin_email" {
  description = "Google Workspace Super Admin or Delegated Admin email to impersonate."
  type        = string
}

variable "workspace_customer_id" {
  description = "Google Workspace Customer ID or domain (defaults to domain portion of workspace_admin_email)."
  type        = string
  default     = ""
}

variable "service_account_name" {
  description = "Name of the service account to create."
  type        = string
  default     = "license-monitor-sa"
}

variable "artifact_repo_name" {
  description = "Name of the Artifact Registry repository."
  type        = string
  default     = "license-monitor-repo"
}

variable "service_name" {
  description = "Name of the Cloud Run service."
  type        = string
  default     = "cloudidentity-license-monitor"
}

variable "job_name" {
  description = "Name of the Cloud Run job."
  type        = string
  default     = "cloudidentity-license-monitor-job"
}

variable "scheduler_job_name" {
  description = "Name of the Cloud Scheduler job."
  type        = string
  default     = "scheduled-license-monitor"
}

variable "cron_schedule" {
  description = "Cron schedule for running the license monitor."
  type        = string
  default     = "0 * * * *"
}

variable "total_purchased_seats_premium" {
  description = "Total purchased seats for Cloud Identity Premium."
  type        = number
  default     = 50
}

variable "total_purchased_seats_free" {
  description = "Total purchased seats for Cloud Identity Free."
  type        = number
  default     = 50
}

variable "image_tag" {
  description = "Tag of the container image in Artifact Registry."
  type        = string
  default     = "latest"
}

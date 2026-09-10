output "service_account_email" {
  description = "The Service Account email used by Cloud Run and Cloud Scheduler."
  value       = google_service_account.sa.email
}

output "service_account_unique_id" {
  description = "The Unique Client ID to authorize in Google Admin Console under Domain-Wide Delegation."
  value       = google_service_account.sa.unique_id
}

output "cloud_run_service_url" {
  description = "The HTTPS URL of the deployed Cloud Run service."
  value       = google_cloud_run_v2_service.monitor_service.uri
}

output "cloud_scheduler_job_id" {
  description = "The ID of the configured Cloud Scheduler job."
  value       = google_cloud_scheduler_job.scheduler.id
}

output "domain_wide_delegation_instructions" {
  description = "Instructions for authorizing the client ID in Google Admin Console."
  value       = <<-EOT
    ================================================================================
    Google Workspace Domain-Wide Delegation Setup:
    1. Navigate to: https://admin.google.com/ac/owl/domainwidedelegation
    2. Click 'Add new'
    3. Client ID: ${google_service_account.sa.unique_id}
    4. OAuth Scopes: https://www.googleapis.com/auth/apps.licensing
    5. Click 'Authorize'
    ================================================================================
  EOT
}

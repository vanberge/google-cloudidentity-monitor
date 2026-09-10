#!/usr/bin/env bash
# ==============================================================================
# Cloud Identity License Monitor - Teardown / Cleanup Script
# ==============================================================================
set -euo pipefail

BOLD="\033[1m"
GREEN="\033[0;32m"
YELLOW="\033[1;33m"
CYAN="\033[0;36m"
RED="\033[0;31m"
NC="\033[0m"

log_info() { echo -e "${CYAN}${BOLD}>>> ${NC}$*"; }
log_success() { echo -e "${GREEN}${BOLD}✓ ${NC}$*"; }
log_warn() { echo -e "${YELLOW}${BOLD}⚠ ${NC}$*"; }

ENV_FILE=".env"
if [[ -f "$ENV_FILE" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    set +a
fi

GCP_PROJECT_ID="${GCP_PROJECT_ID:-}"
GCP_REGION="${GCP_REGION:-us-central1}"
SERVICE_ACCOUNT_NAME="${SERVICE_ACCOUNT_NAME:-license-monitor-sa}"
ARTIFACT_REPO_NAME="${ARTIFACT_REPO_NAME:-license-monitor-repo}"
SERVICE_NAME="${SERVICE_NAME:-cloudidentity-license-monitor}"
JOB_NAME="${JOB_NAME:-cloudidentity-license-monitor-job}"
SCHEDULER_JOB_NAME="${SCHEDULER_JOB_NAME:-scheduled-license-monitor}"

if [[ -z "$GCP_PROJECT_ID" ]]; then
    read -r -p "Enter Google Cloud Project ID to tear down: " GCP_PROJECT_ID
fi

echo -e "${YELLOW}${BOLD}WARNING: This will delete:${NC}"
echo -e "  - Cloud Scheduler Job: ${SCHEDULER_JOB_NAME}"
echo -e "  - Cloud Run Service:   ${SERVICE_NAME}"
echo -e "  - Cloud Run Job:       ${JOB_NAME}"
echo -e "  - Service Account:     ${SERVICE_ACCOUNT_NAME}@${GCP_PROJECT_ID}.iam.gserviceaccount.com"
echo -e "  - Artifact Registry:   ${ARTIFACT_REPO_NAME} in ${GCP_REGION}"
echo ""
read -r -p "Are you sure you want to proceed? (y/N): " CONFIRM
if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
    echo "Aborted."
    exit 0
fi

log_info "Deleting Cloud Scheduler job..."
gcloud scheduler jobs delete "$SCHEDULER_JOB_NAME" --location="$GCP_REGION" --project="$GCP_PROJECT_ID" --quiet 2>/dev/null || true

log_info "Deleting Cloud Run service..."
gcloud run services delete "$SERVICE_NAME" --region="$GCP_REGION" --project="$GCP_PROJECT_ID" --quiet 2>/dev/null || true

log_info "Deleting Cloud Run job..."
gcloud run jobs delete "$JOB_NAME" --region="$GCP_REGION" --project="$GCP_PROJECT_ID" --quiet 2>/dev/null || true

log_info "Deleting Service Account..."
gcloud iam service-accounts delete "${SERVICE_ACCOUNT_NAME}@${GCP_PROJECT_ID}.iam.gserviceaccount.com" --project="$GCP_PROJECT_ID" --quiet 2>/dev/null || true

log_info "Deleting Artifact Registry repository..."
gcloud artifacts repositories delete "$ARTIFACT_REPO_NAME" --location="$GCP_REGION" --project="$GCP_PROJECT_ID" --quiet 2>/dev/null || true

log_success "Cleanup complete."

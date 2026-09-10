#!/usr/bin/env bash
# ==============================================================================
# Cloud Identity License Monitor - Automated Deployment Script
# ==============================================================================
set -euo pipefail

# Text formatting
BOLD="\033[1m"
GREEN="\033[0;32m"
YELLOW="\033[1;33m"
CYAN="\033[0;36m"
RED="\033[0;31m"
NC="\033[0m"

log_info() {
    echo -e "${CYAN}${BOLD}>>> ${NC}$*"
}

log_success() {
    echo -e "${GREEN}${BOLD}✓ ${NC}$*"
}

log_warn() {
    echo -e "${YELLOW}${BOLD}⚠ ${NC}$*"
}

log_error() {
    echo -e "${RED}${BOLD}✖ ${NC}$*" >&2
}

# ------------------------------------------------------------------------------
# 1. Parse CLI Options & Environment
# ------------------------------------------------------------------------------
ENV_FILE=".env"
RUN_TEST=false

print_usage() {
    cat <<EOF
Usage: ./deploy.sh [OPTIONS]

Options:
  -p, --project PROJECT_ID     Google Cloud Project ID
  -a, --admin-email EMAIL      Google Workspace Super Admin email
  -r, --region REGION          GCP Region (default: us-central1)
  -e, --env FILE               Path to .env file (default: .env)
  -t, --test                   Trigger on-demand execution after deployment
  -h, --help                   Display this help message

Environment Variables can also be set directly or via .env file.
EOF
}

# Check if a custom env file was specified
for ((i=1; i<=$#; i++)); do
    if [[ "${!i}" == "-e" || "${!i}" == "--env" ]]; then
        next=$((i+1))
        ENV_FILE="${!next}"
    fi
done

# Source .env file first if it exists
if [[ -f "$ENV_FILE" ]]; then
    log_info "Loading configuration from $ENV_FILE..."
    set -a
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    set +a
fi

while [[ $# -gt 0 ]]; do
    case "$1" in
        -p|--project)
            GCP_PROJECT_ID="$2"
            shift 2
            ;;
        -a|--admin-email)
            WORKSPACE_ADMIN_EMAIL="$2"
            shift 2
            ;;
        -r|--region)
            GCP_REGION="$2"
            shift 2
            ;;
        -e|--env)
            # Already processed
            shift 2
            ;;
        -t|--test)
            RUN_TEST=true
            shift
            ;;
        -h|--help)
            print_usage
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            print_usage
            exit 1
            ;;
    esac
done

# Set defaults
GCP_PROJECT_ID="${GCP_PROJECT_ID:-}"
WORKSPACE_ADMIN_EMAIL="${WORKSPACE_ADMIN_EMAIL:-}"
GCP_REGION="${GCP_REGION:-us-central1}"
SERVICE_ACCOUNT_NAME="${SERVICE_ACCOUNT_NAME:-license-monitor-sa}"
ARTIFACT_REPO_NAME="${ARTIFACT_REPO_NAME:-license-monitor-repo}"
IMAGE_NAME="${IMAGE_NAME:-license-monitor}"
SERVICE_NAME="${SERVICE_NAME:-cloudidentity-license-monitor}"
JOB_NAME="${JOB_NAME:-cloudidentity-license-monitor-job}"
SCHEDULER_JOB_NAME="${SCHEDULER_JOB_NAME:-scheduled-license-monitor}"
CRON_SCHEDULE="${CRON_SCHEDULE:-0 * * * *}"
TOTAL_PURCHASED_SEATS_PREMIUM="${TOTAL_PURCHASED_SEATS_PREMIUM:-50}"
TOTAL_PURCHASED_SEATS_FREE="${TOTAL_PURCHASED_SEATS_FREE:-50}"
WORKSPACE_CUSTOMER_ID="${WORKSPACE_CUSTOMER_ID:-}"

# Check required inputs
if [[ -z "$GCP_PROJECT_ID" ]]; then
    if [[ -t 0 ]]; then
        read -r -p "Enter Google Cloud Project ID: " GCP_PROJECT_ID
    else
        log_error "Missing required variable: GCP_PROJECT_ID (or set via -p / .env)"
        exit 1
    fi
fi

if [[ -z "$WORKSPACE_ADMIN_EMAIL" ]]; then
    if [[ -t 0 ]]; then
        read -r -p "Enter Google Workspace Admin email (e.g. admin@yourdomain.com): " WORKSPACE_ADMIN_EMAIL
    else
        log_error "Missing required variable: WORKSPACE_ADMIN_EMAIL (or set via -a / .env)"
        exit 1
    fi
fi

SERVICE_ACCOUNT_EMAIL="${SERVICE_ACCOUNT_NAME}@${GCP_PROJECT_ID}.iam.gserviceaccount.com"
IMAGE_URI="${GCP_REGION}-docker.pkg.dev/${GCP_PROJECT_ID}/${ARTIFACT_REPO_NAME}/${IMAGE_NAME}:latest"

echo ""
echo -e "${BOLD}==================================================================${NC}"
echo -e "${BOLD}   Cloud Identity License Monitor - Deployment Configuration     ${NC}"
echo -e "${BOLD}==================================================================${NC}"
echo -e "  Project ID:               ${GREEN}${GCP_PROJECT_ID}${NC}"
echo -e "  Region:                   ${GREEN}${GCP_REGION}${NC}"
echo -e "  Workspace Admin:          ${GREEN}${WORKSPACE_ADMIN_EMAIL}${NC}"
echo -e "  Service Account:          ${GREEN}${SERVICE_ACCOUNT_EMAIL}${NC}"
echo -e "  Artifact Registry:        ${GREEN}${ARTIFACT_REPO_NAME}${NC}"
echo -e "  Container Image:          ${GREEN}${IMAGE_URI}${NC}"
echo -e "  Cloud Run Service:        ${GREEN}${SERVICE_NAME}${NC}"
echo -e "  Cloud Run Job:            ${GREEN}${JOB_NAME}${NC}"
echo -e "  Cloud Scheduler Job:      ${GREEN}${SCHEDULER_JOB_NAME} (${CRON_SCHEDULE})${NC}"
echo -e "${BOLD}==================================================================${NC}"
echo ""

# ------------------------------------------------------------------------------
# 2. Check Prerequisites & gcloud Authentication
# ------------------------------------------------------------------------------
log_info "Verifying gcloud CLI and authentication..."
if ! command -v gcloud &> /dev/null; then
    log_error "'gcloud' CLI is not installed. Please install the Google Cloud SDK."
    exit 1
fi

ACTIVE_ACCOUNT=$(gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null || true)
if [[ -z "$ACTIVE_ACCOUNT" ]]; then
    log_error "No active gcloud account detected. Please run 'gcloud auth login'."
    exit 1
fi
log_success "Authenticated as: ${ACTIVE_ACCOUNT}"

# Set default project for gcloud session
gcloud config set project "$GCP_PROJECT_ID" --quiet

# ------------------------------------------------------------------------------
# 3. Enable Required Google Cloud APIs
# ------------------------------------------------------------------------------
log_info "Enabling required Google Cloud APIs..."
REQUIRED_APIS=(
    "run.googleapis.com"
    "cloudscheduler.googleapis.com"
    "cloudbuild.googleapis.com"
    "artifactregistry.googleapis.com"
    "iamcredentials.googleapis.com"
    "licensing.googleapis.com"
    "monitoring.googleapis.com"
    "logging.googleapis.com"
)

gcloud services enable "${REQUIRED_APIS[@]}" --project="$GCP_PROJECT_ID"
log_success "Required APIs enabled."

# ------------------------------------------------------------------------------
# 4. Create Artifact Registry Repository
# ------------------------------------------------------------------------------
log_info "Checking Artifact Registry repository: ${ARTIFACT_REPO_NAME} in ${GCP_REGION}..."
if ! gcloud artifacts repositories describe "$ARTIFACT_REPO_NAME" --location="$GCP_REGION" --project="$GCP_PROJECT_ID" &>/dev/null; then
    log_info "Creating Artifact Registry repository..."
    gcloud artifacts repositories create "$ARTIFACT_REPO_NAME" \
        --repository-format=docker \
        --location="$GCP_REGION" \
        --description="Docker repository for Cloud Identity License Monitor" \
        --project="$GCP_PROJECT_ID"
    log_success "Artifact Registry repository created."
else
    log_success "Artifact Registry repository already exists."
fi

# ------------------------------------------------------------------------------
# 5. Create Service Account and Assign Roles
# ------------------------------------------------------------------------------
log_info "Configuring Service Account: ${SERVICE_ACCOUNT_NAME}..."
if ! gcloud iam service-accounts describe "$SERVICE_ACCOUNT_EMAIL" --project="$GCP_PROJECT_ID" &>/dev/null; then
    gcloud iam service-accounts create "$SERVICE_ACCOUNT_NAME" \
        --display-name="Cloud Identity License Monitor Service Account" \
        --project="$GCP_PROJECT_ID"
    log_success "Service account created."
else
    log_success "Service account already exists."
fi

log_info "Binding IAM roles to ${SERVICE_ACCOUNT_EMAIL}..."

# Helper with retry loop to handle GCP IAM eventual consistency for newly created service accounts
add_project_iam_binding_with_retry() {
    local project="$1"
    local member="$2"
    local role="$3"
    local max_attempts=6
    local attempt=1
    while (( attempt <= max_attempts )); do
        if gcloud projects add-iam-policy-binding "$project" \
            --member="$member" \
            --role="$role" \
            --condition=None --quiet >/dev/null 2>&1; then
            return 0
        fi
        log_warn "Waiting for service account to propagate in IAM... (attempt $attempt/$max_attempts)"
        sleep 5
        ((attempt++))
    done
    gcloud projects add-iam-policy-binding "$project" \
        --member="$member" \
        --role="$role" \
        --condition=None --quiet >/dev/null
}

add_sa_iam_binding_with_retry() {
    local sa="$1"
    local member="$2"
    local role="$3"
    local project="$4"
    local max_attempts=6
    local attempt=1
    while (( attempt <= max_attempts )); do
        if gcloud iam service-accounts add-iam-policy-binding "$sa" \
            --member="$member" \
            --role="$role" \
            --project="$project" \
            --condition=None --quiet >/dev/null 2>&1; then
            return 0
        fi
        log_warn "Waiting for service account self-signing permission to bind... (attempt $attempt/$max_attempts)"
        sleep 5
        ((attempt++))
    done
    gcloud iam service-accounts add-iam-policy-binding "$sa" \
        --member="$member" \
        --role="$role" \
        --project="$project" \
        --condition=None --quiet >/dev/null
}

# Metric writer for Cloud Monitoring
add_project_iam_binding_with_retry "$GCP_PROJECT_ID" "serviceAccount:${SERVICE_ACCOUNT_EMAIL}" "roles/monitoring.metricWriter"

# Log writer for Cloud Logging
add_project_iam_binding_with_retry "$GCP_PROJECT_ID" "serviceAccount:${SERVICE_ACCOUNT_EMAIL}" "roles/logging.logWriter"

# Keyless Domain-Wide Delegation self-signing permission:
# Allows the SA to sign its own JWTs via iamcredentials.signJwt without local private key files.
add_sa_iam_binding_with_retry "$SERVICE_ACCOUNT_EMAIL" "serviceAccount:${SERVICE_ACCOUNT_EMAIL}" "roles/iam.serviceAccountTokenCreator" "$GCP_PROJECT_ID"

log_success "IAM roles assigned to service account."

# Ensure Cloud Build has permissions in new projects where default editor roles are disabled
PROJECT_NUMBER=$(gcloud projects describe "$GCP_PROJECT_ID" --format="value(projectNumber)")
COMPUTE_SA="${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"
add_project_iam_binding_with_retry "$GCP_PROJECT_ID" "serviceAccount:${COMPUTE_SA}" "roles/storage.objectViewer"
add_project_iam_binding_with_retry "$GCP_PROJECT_ID" "serviceAccount:${COMPUTE_SA}" "roles/logging.logWriter"
add_project_iam_binding_with_retry "$GCP_PROJECT_ID" "serviceAccount:${COMPUTE_SA}" "roles/artifactregistry.writer"

# ------------------------------------------------------------------------------
# 6. Build and Push Container Image via Cloud Build
# ------------------------------------------------------------------------------
log_info "Building container image via Cloud Build..."
gcloud builds submit \
    --config=cloudbuild.yaml \
    --substitutions=_REGION="$GCP_REGION",_REPO_NAME="$ARTIFACT_REPO_NAME",_IMAGE_NAME="$IMAGE_NAME" \
    --project="$GCP_PROJECT_ID"
log_success "Container image successfully built and pushed: ${IMAGE_URI}"

# ------------------------------------------------------------------------------
# 7. Deploy Cloud Run Service & Job
# ------------------------------------------------------------------------------
log_info "Deploying Cloud Run Service: ${SERVICE_NAME}..."
COMMON_ENV="GCP_PROJECT_ID=${GCP_PROJECT_ID},SERVICE_ACCOUNT_EMAIL=${SERVICE_ACCOUNT_EMAIL},WORKSPACE_ADMIN_EMAIL=${WORKSPACE_ADMIN_EMAIL},TOTAL_PURCHASED_SEATS_PREMIUM=${TOTAL_PURCHASED_SEATS_PREMIUM},TOTAL_PURCHASED_SEATS_FREE=${TOTAL_PURCHASED_SEATS_FREE}"
if [[ -n "$WORKSPACE_CUSTOMER_ID" ]]; then
    COMMON_ENV="${COMMON_ENV},WORKSPACE_CUSTOMER_ID=${WORKSPACE_CUSTOMER_ID}"
fi

gcloud run deploy "$SERVICE_NAME" \
    --image="$IMAGE_URI" \
    --region="$GCP_REGION" \
    --project="$GCP_PROJECT_ID" \
    --service-account="$SERVICE_ACCOUNT_EMAIL" \
    --no-allow-unauthenticated \
    --set-env-vars="$COMMON_ENV" \
    --platform=managed \
    --quiet

SERVICE_URL=$(gcloud run services describe "$SERVICE_NAME" --region="$GCP_REGION" --project="$GCP_PROJECT_ID" --format="value(status.url)")
log_success "Cloud Run Service deployed: ${SERVICE_URL}"

log_info "Configuring Cloud Run Job: ${JOB_NAME}..."
JOB_ENV="${COMMON_ENV},RUN_ONCE=true"
if gcloud run jobs describe "$JOB_NAME" --region="$GCP_REGION" --project="$GCP_PROJECT_ID" &>/dev/null; then
    gcloud run jobs update "$JOB_NAME" \
        --image="$IMAGE_URI" \
        --region="$GCP_REGION" \
        --project="$GCP_PROJECT_ID" \
        --service-account="$SERVICE_ACCOUNT_EMAIL" \
        --command="python" \
        --args="main.py,--run-once" \
        --set-env-vars="$JOB_ENV" \
        --quiet
else
    gcloud run jobs create "$JOB_NAME" \
        --image="$IMAGE_URI" \
        --region="$GCP_REGION" \
        --project="$GCP_PROJECT_ID" \
        --service-account="$SERVICE_ACCOUNT_EMAIL" \
        --command="python" \
        --args="main.py,--run-once" \
        --set-env-vars="$JOB_ENV" \
        --quiet
fi
log_success "Cloud Run Job configured."

# ------------------------------------------------------------------------------
# 8. Configure Cloud Scheduler Job
# ------------------------------------------------------------------------------
log_info "Authorizing Service Account to invoke Cloud Run Service..."
gcloud run services add-iam-policy-binding "$SERVICE_NAME" \
    --region="$GCP_REGION" \
    --project="$GCP_PROJECT_ID" \
    --member="serviceAccount:${SERVICE_ACCOUNT_EMAIL}" \
    --role="roles/run.invoker" \
    --quiet >/dev/null

log_info "Configuring Cloud Scheduler: ${SCHEDULER_JOB_NAME} (${CRON_SCHEDULE})..."
if gcloud scheduler jobs describe "$SCHEDULER_JOB_NAME" --location="$GCP_REGION" --project="$GCP_PROJECT_ID" &>/dev/null; then
    gcloud scheduler jobs update http "$SCHEDULER_JOB_NAME" \
        --location="$GCP_REGION" \
        --project="$GCP_PROJECT_ID" \
        --schedule="$CRON_SCHEDULE" \
        --uri="${SERVICE_URL}/check" \
        --http-method=POST \
        --oidc-service-account-email="$SERVICE_ACCOUNT_EMAIL" \
        --oidc-token-audience="$SERVICE_URL" \
        --quiet
else
    gcloud scheduler jobs create http "$SCHEDULER_JOB_NAME" \
        --location="$GCP_REGION" \
        --project="$GCP_PROJECT_ID" \
        --schedule="$CRON_SCHEDULE" \
        --uri="${SERVICE_URL}/check" \
        --http-method=POST \
        --oidc-service-account-email="$SERVICE_ACCOUNT_EMAIL" \
        --oidc-token-audience="$SERVICE_URL" \
        --description="Hourly trigger for Cloud Identity license monitor" \
        --quiet
fi
log_success "Cloud Scheduler job configured."

# ------------------------------------------------------------------------------
# 9. Retrieve Unique Client ID for Domain-Wide Delegation
# ------------------------------------------------------------------------------
SA_CLIENT_ID=$(gcloud iam service-accounts describe "$SERVICE_ACCOUNT_EMAIL" --project="$GCP_PROJECT_ID" --format="value(uniqueId)")

echo ""
echo -e "${BOLD}${GREEN}========================================================================${NC}"
echo -e "${BOLD}${GREEN}               DEPLOYMENT COMPLETED SUCCESSFULLY!                      ${NC}"
echo -e "${BOLD}${GREEN}========================================================================${NC}"
echo ""
echo -e "${BOLD}ACTION REQUIRED: Authorize Domain-Wide Delegation in Google Workspace${NC}"
echo ""
echo -e "To grant this service account access to read license allocations:"
echo -e "1. Open Google Admin Console: ${CYAN}https://admin.google.com/ac/owl/domainwidedelegation${NC}"
echo -e "2. Click ${BOLD}Add new${NC}"
echo -e "3. Enter the following details:"
echo -e "   • ${BOLD}Client ID:${NC}   ${YELLOW}${BOLD}${SA_CLIENT_ID}${NC}"
echo -e "   • ${BOLD}OAuth Scopes:${NC} ${YELLOW}https://www.googleapis.com/auth/apps.licensing${NC}"
echo -e "4. Click ${BOLD}Authorize${NC}."
echo ""
echo -e "${BOLD}========================================================================${NC}"
echo ""

# ------------------------------------------------------------------------------
# 10. Optional Verification / Test Execution
# ------------------------------------------------------------------------------
if [[ "$RUN_TEST" == true ]]; then
    log_info "Executing Cloud Run Job to test license check..."
    gcloud run jobs execute "$JOB_NAME" \
        --region="$GCP_REGION" \
        --project="$GCP_PROJECT_ID" \
        --wait
    log_success "Test execution completed. Check Cloud Logging or Cloud Monitoring for metrics!"
else
    echo -e "To test your deployment immediately after authorizing in Google Admin Console, run:"
    echo -e "  ${CYAN}gcloud run jobs execute ${JOB_NAME} --region=${GCP_REGION} --project=${GCP_PROJECT_ID} --wait${NC}"
    echo -e "Or trigger Cloud Scheduler:"
    echo -e "  ${CYAN}gcloud scheduler jobs run ${SCHEDULER_JOB_NAME} --location=${GCP_REGION} --project=${GCP_PROJECT_ID}${NC}"
fi
echo ""

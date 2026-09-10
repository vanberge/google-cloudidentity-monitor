# Deployment Guide: Cloud Identity License Monitor

This guide covers everything required to deploy the **Cloud Identity License Monitor** from scratch in any Google Cloud Platform (GCP) project and Google Workspace / Cloud Identity tenant.

---

## Prerequisites

Before starting, ensure you have:
1. **Google Cloud SDK (`gcloud`)** installed and authenticated:
   ```bash
   gcloud auth login
   ```
2. **GCP Project Permissions**:
   - `roles/owner` or `roles/editor` + `roles/resourcemanager.projectIamAdmin` in your target GCP project.
3. **Google Workspace / Cloud Identity Admin Access**:
   - Super Administrator privileges in the Google Admin Console (`admin.google.com`) to approve Domain-Wide Delegation.

---

## Method 1: Automated Script (`deploy.sh`) [Recommended]

The repository includes an idempotent, automated deployment script that provisions all GCP infrastructure, builds the container, and sets up scheduled monitoring.

### Step 1: Clone Repository
```bash
git clone <repository-url>
cd cloudidentity-license-monitor
```

### Step 2: Configure Environment
Copy the example configuration:
```bash
cp .env.example .env
```
Edit `.env` with your project and domain values:
```bash
# Target GCP Project
GCP_PROJECT_ID="your-project-id"

# Super Admin email for your domain
WORKSPACE_ADMIN_EMAIL="admin@yourdomain.com"

# Purchased seat counts (used to calculate available seats)
TOTAL_PURCHASED_SEATS_PREMIUM="100"
TOTAL_PURCHASED_SEATS_FREE="50"

# Optional: Preferred region (default: us-central1)
GCP_REGION="us-central1"
```

### Step 3: Run Deployment
```bash
./deploy.sh
```

The script will:
1. Verify `gcloud` authentication and project context.
2. Enable all required GCP APIs (`run`, `cloudscheduler`, `cloudbuild`, `artifactregistry`, `iamcredentials`, `licensing`, `monitoring`, `logging`).
3. Create the Artifact Registry Docker repository.
4. Create the dedicated Service Account and assign required IAM roles (including keyless self-signing).
5. Build and push the container image using Cloud Build.
6. Deploy the secure Cloud Run Service (HTTPS endpoint).
7. Deploy the Cloud Run Job (CLI/Batch execution).
8. Configure Cloud Scheduler to invoke the service on an hourly cron schedule (`0 * * * *`) with OIDC tokens.
9. Print the **Numeric Client ID** needed for Domain-Wide Delegation.

---

## Method 2: Terraform Deployment

If your organization uses Terraform for Infrastructure as Code:

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars`:
```hcl
project_id                    = "your-project-id"
region                        = "us-central1"
workspace_admin_email         = "admin@yourdomain.com"
total_purchased_seats_premium = 100
total_purchased_seats_free    = 50
```

Deploy:
```bash
terraform init
terraform apply
```

*Note: Before running Terraform apply, submit the container image once via Cloud Build:*
```bash
gcloud builds submit --config=cloudbuild.yaml --project=your-project-id
```

---

## Method 3: Manual Step-by-Step Deployment

If you prefer executing individual `gcloud` commands manually:

### 1. Set Shell Variables
```bash
export GCP_PROJECT_ID="your-project-id"
export GCP_REGION="us-central1"
export WORKSPACE_ADMIN_EMAIL="admin@yourdomain.com"
export SERVICE_ACCOUNT_NAME="license-monitor-sa"
export SA_EMAIL="${SERVICE_ACCOUNT_NAME}@${GCP_PROJECT_ID}.iam.gserviceaccount.com"
export ARTIFACT_REPO="license-monitor-repo"
export IMAGE_URI="${GCP_REGION}-docker.pkg.dev/${GCP_PROJECT_ID}/${ARTIFACT_REPO}/license-monitor:latest"
```

### 2. Enable APIs
```bash
gcloud services enable \
    run.googleapis.com \
    cloudscheduler.googleapis.com \
    cloudbuild.googleapis.com \
    artifactregistry.googleapis.com \
    iamcredentials.googleapis.com \
    licensing.googleapis.com \
    monitoring.googleapis.com \
    logging.googleapis.com \
    --project="$GCP_PROJECT_ID"
```

### 3. Create Artifact Registry Repo
```bash
gcloud artifacts repositories create "$ARTIFACT_REPO" \
    --repository-format=docker \
    --location="$GCP_REGION" \
    --description="Docker repository for License Monitor" \
    --project="$GCP_PROJECT_ID"
```

### 4. Create Service Account and IAM Roles
```bash
# Create Service Account
gcloud iam service-accounts create "$SERVICE_ACCOUNT_NAME" \
    --display-name="Cloud Identity License Monitor" \
    --project="$GCP_PROJECT_ID"

# Grant Monitoring & Logging roles
gcloud projects add-iam-policy-binding "$GCP_PROJECT_ID" \
    --member="serviceAccount:${SA_EMAIL}" \
    --role="roles/monitoring.metricWriter"

gcloud projects add-iam-policy-binding "$GCP_PROJECT_ID" \
    --member="serviceAccount:${SA_EMAIL}" \
    --role="roles/logging.logWriter"

# Grant self-signing (keyless DWD)
gcloud iam service-accounts add-iam-policy-binding "$SA_EMAIL" \
    --member="serviceAccount:${SA_EMAIL}" \
    --role="roles/iam.serviceAccountTokenCreator" \
    --project="$GCP_PROJECT_ID"
```

### 5. Build and Push Container
```bash
gcloud builds submit \
    --config=cloudbuild.yaml \
    --substitutions=_REGION="$GCP_REGION",_REPO_NAME="$ARTIFACT_REPO",_IMAGE_NAME="license-monitor" \
    --project="$GCP_PROJECT_ID"
```

### 6. Deploy Cloud Run Service & Job
```bash
ENV_VARS="GCP_PROJECT_ID=${GCP_PROJECT_ID},SERVICE_ACCOUNT_EMAIL=${SA_EMAIL},WORKSPACE_ADMIN_EMAIL=${WORKSPACE_ADMIN_EMAIL},TOTAL_PURCHASED_SEATS_PREMIUM=100,TOTAL_PURCHASED_SEATS_FREE=50"

# Deploy Service
gcloud run deploy cloudidentity-license-monitor \
    --image="$IMAGE_URI" \
    --region="$GCP_REGION" \
    --project="$GCP_PROJECT_ID" \
    --service-account="$SA_EMAIL" \
    --no-allow-unauthenticated \
    --set-env-vars="$ENV_VARS"

# Deploy Job
gcloud run jobs create cloudidentity-license-monitor-job \
    --image="$IMAGE_URI" \
    --region="$GCP_REGION" \
    --project="$GCP_PROJECT_ID" \
    --service-account="$SA_EMAIL" \
    --command="python" \
    --args="main.py,--run-once" \
    --set-env-vars="${ENV_VARS},RUN_ONCE=true"
```

### 7. Configure Cloud Scheduler
```bash
SERVICE_URL=$(gcloud run services describe cloudidentity-license-monitor --region="$GCP_REGION" --project="$GCP_PROJECT_ID" --format="value(status.url)")

# Grant invoker role
gcloud run services add-iam-policy-binding cloudidentity-license-monitor \
    --region="$GCP_REGION" \
    --project="$GCP_PROJECT_ID" \
    --member="serviceAccount:${SA_EMAIL}" \
    --role="roles/run.invoker"

# Create Scheduler Job
gcloud scheduler jobs create http scheduled-license-monitor \
    --location="$GCP_REGION" \
    --project="$GCP_PROJECT_ID" \
    --schedule="0 * * * *" \
    --uri="${SERVICE_URL}/check" \
    --http-method=POST \
    --oidc-service-account-email="$SA_EMAIL" \
    --oidc-token-audience="$SERVICE_URL"
```

---

## Authorizing Domain-Wide Delegation in Google Workspace

Regardless of deployment method, Domain-Wide Delegation **must** be authorized once by a Google Workspace Super Admin:

1. Retrieve the numeric Client ID of the service account:
   ```bash
   gcloud iam service-accounts describe "${SERVICE_ACCOUNT_NAME}@${GCP_PROJECT_ID}.iam.gserviceaccount.com" \
       --project="$GCP_PROJECT_ID" \
       --format="value(uniqueId)"
   ```
2. Log in to [admin.google.com](https://admin.google.com) as a Super Admin.
3. Navigate to: **Security** > **Access and data control** > **API controls** > **Manage Domain Wide Delegation**  
   *(Direct URL: `https://admin.google.com/ac/owl/domainwidedelegation`)*
4. Click **Add new**.
5. Fill in the fields:
   - **Client ID**: Paste the numeric Client ID retrieved above.
   - **OAuth Scopes**:
     ```
     https://www.googleapis.com/auth/apps.licensing
     ```
6. Click **Authorize**.

---

## Verifying the Deployment

### 1. Run the Cloud Run Job
```bash
gcloud run jobs execute cloudidentity-license-monitor-job \
    --region="$GCP_REGION" \
    --project="$GCP_PROJECT_ID" \
    --wait
```

### 2. Trigger Cloud Scheduler
```bash
gcloud scheduler jobs run scheduled-license-monitor \
    --location="$GCP_REGION" \
    --project="$GCP_PROJECT_ID"
```

### 3. Check Logs
```bash
gcloud logging read 'resource.type="cloud_run_revision" AND resource.labels.service_name="cloudidentity-license-monitor"' \
    --limit=15 \
    --project="$GCP_PROJECT_ID" \
    --format="yaml(timestamp,textPayload)"
```

Look for:
```
Successfully pushed 8 custom metrics to Cloud Monitoring.
```

### 4. View in Cloud Monitoring
Visit **Monitoring** > **Metrics Explorer** in the Cloud Console and search for:
`custom.googleapis.com/cloudidentity/available_licenses`

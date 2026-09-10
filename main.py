import os
import sys
import time
import json
import logging
import argparse
from typing import List, Dict, Any, Optional, Tuple

import requests
import google.auth
from google.auth.transport.requests import Request
from google.oauth2.credentials import Credentials
from googleapiclient.discovery import build
from googleapiclient.errors import HttpError
from google.cloud import monitoring_v3
from flask import Flask, jsonify, request

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s - %(message)s"
)
logger = logging.getLogger("license-monitor")

app = Flask(__name__)

def get_default_project_id() -> str:
    project_id = os.environ.get("GCP_PROJECT_ID") or os.environ.get("GOOGLE_CLOUD_PROJECT")
    if not project_id:
        try:
            _, project_id = google.auth.default()
        except Exception:
            pass
    return project_id or ""

# Configuration from Environment Variables
PROJECT_ID = get_default_project_id()
WORKSPACE_ADMIN_EMAIL = os.environ.get("WORKSPACE_ADMIN_EMAIL", "")
SERVICE_ACCOUNT_EMAIL = os.environ.get("SERVICE_ACCOUNT_EMAIL") or (
    f"license-monitor-sa@{PROJECT_ID}.iam.gserviceaccount.com" if PROJECT_ID else ""
)
WORKSPACE_CUSTOMER_ID = os.environ.get("WORKSPACE_CUSTOMER_ID")
LICENSING_SCOPE = "https://www.googleapis.com/auth/apps.licensing"


def load_target_skus() -> List[Dict[str, Any]]:
    """Loads SKUs to monitor from config file, environment JSON, or defaults."""
    # 1. Check if a skus.json file exists
    config_file = os.environ.get("SKUS_CONFIG_FILE", "skus.json")
    if os.path.exists(config_file):
        try:
            with open(config_file, "r") as f:
                return json.load(f)
        except Exception as e:
            logger.warning("Failed to parse %s (%s)", config_file, e)

    # 2. Check MONITORED_SKUS environment variable (JSON string)
    raw_config = os.environ.get("MONITORED_SKUS")
    if raw_config:
        try:
            return json.loads(raw_config)
        except Exception as e:
            logger.warning("Failed to parse MONITORED_SKUS JSON (%s), falling back to defaults", e)

    # 3. Default to Cloud Identity Premium and Free with configured total seats
    premium_seats = int(os.environ.get("TOTAL_PURCHASED_SEATS_PREMIUM", os.environ.get("TOTAL_PURCHASED_SEATS", "50")))
    free_seats = int(os.environ.get("TOTAL_PURCHASED_SEATS_FREE", "50"))
    return [
        {
            "name": "Cloud Identity Premium",
            "productId": "101005",
            "skuId": "1010050001",
            "totalSeats": premium_seats,
        },
        {
            "name": "Cloud Identity Free",
            "productId": "101001",
            "skuId": "1010010001",
            "totalSeats": free_seats,
        }
    ]


def get_delegated_access_token(sa_email: str, admin_email: str) -> str:
    """
    Acquires a Google Workspace OAuth access token via Keyless Domain-Wide Delegation.
    Leverages the IAM Service Account Credentials API (:signJwt) so no private key file is stored.
    """
    # 1. Base credentials from the environment (ADC, Cloud Run managed identity, or gcloud CLI fallback)
    try:
        base_credentials, _ = google.auth.default(scopes=["https://www.googleapis.com/auth/cloud-platform"])
        base_credentials.refresh(Request())
        token = base_credentials.token
    except Exception as e:
        logger.info("Falling back to gcloud auth print-access-token (%s)", e)
        import subprocess
        proc = subprocess.run(["gcloud", "auth", "print-access-token"], capture_output=True, text=True, check=True)
        token = proc.stdout.strip()

    now = int(time.time())
    jwt_payload = {
        "iss": sa_email,
        "sub": admin_email,
        "aud": "https://oauth2.googleapis.com/token",
        "iat": now,
        "exp": now + 3600,
        "scope": LICENSING_SCOPE,
    }

    # 2. Call IAM Credentials signJwt endpoint
    sign_jwt_url = f"https://iamcredentials.googleapis.com/v1/projects/-/serviceAccounts/{sa_email}:signJwt"
    sign_resp = requests.post(
        sign_jwt_url,
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json"
        },
        json={"payload": json.dumps(jwt_payload)},
        timeout=15,
    )
    if sign_resp.status_code != 200:
        raise RuntimeError(f"IAM signJwt failed ({sign_resp.status_code}): {sign_resp.text}")

    signed_jwt = sign_resp.json()["signedJwt"]

    # 3. Exchange signed JWT assertion for Google Workspace Access Token
    token_url = "https://oauth2.googleapis.com/token"
    token_resp = requests.post(
        token_url,
        headers={"Content-Type": "application/x-www-form-urlencoded"},
        data={
            "grant_type": "urn:ietf:params:oauth:grant-type:jwt-bearer",
            "assertion": signed_jwt,
        },
        timeout=15,
    )
    if token_resp.status_code != 200:
        raise RuntimeError(
            f"Workspace OAuth token exchange failed ({token_resp.status_code}): {token_resp.text}\n"
            f"Check if Domain-Wide Delegation for Client ID of '{sa_email}' is authorized in Google Workspace Admin Console."
        )

    return token_resp.json()["access_token"]


def count_assigned_licenses(access_token: str, product_id: str, sku_id: str, customer_id: str) -> Tuple[int, List[str]]:
    """
    Paginates through licensing.licenseAssignments.listForProductAndSku
    and counts assigned licenses.
    """
    creds = Credentials(token=access_token)
    service = build("licensing", "v1", credentials=creds, cache_discovery=False)

    assigned_count = 0
    assigned_users: List[str] = []
    page_token: Optional[str] = None

    while True:
        try:
            req = service.licenseAssignments().listForProductAndSku(
                productId=product_id,
                skuId=sku_id,
                customerId=customer_id,
                maxResults=1000,
                pageToken=page_token,
            )
            resp = req.execute()
        except HttpError as err:
            if err.resp.status in (404, 403):
                logger.warning("Product '%s' / SKU '%s' not subscribed or found for customer '%s' (%s).", product_id, sku_id, customer_id, err)
                return 0, []
            raise

        items = resp.get("items", [])
        assigned_count += len(items)
        for item in items:
            user_id = item.get("userId")
            if user_id:
                assigned_users.append(user_id)

        page_token = resp.get("nextPageToken")
        if not page_token:
            break

    return assigned_count, assigned_users


def publish_metrics_to_cloud_monitoring(project_id: str, results: List[Dict[str, Any]]) -> None:
    """Pushes custom metrics to Google Cloud Monitoring."""
    try:
        base_credentials, _ = google.auth.default(scopes=["https://www.googleapis.com/auth/cloud-platform"])
        base_credentials.refresh(Request())
        creds = base_credentials
    except Exception:
        import subprocess
        proc = subprocess.run(["gcloud", "auth", "print-access-token"], capture_output=True, text=True, check=True)
        creds = Credentials(token=proc.stdout.strip())

    client = monitoring_v3.MetricServiceClient(credentials=creds)
    project_name = f"projects/{project_id}"
    now_seconds = int(time.time())

    series_list = []
    for r in results:
        sku_id = r["skuId"]
        sku_name = r["name"]
        assigned = r["assigned"]
        total = r["totalSeats"]
        available = r["available"]
        util_pct = r["utilizationPercent"]

        metric_specs = [
            ("custom.googleapis.com/cloudidentity/assigned_licenses", assigned, False),
            ("custom.googleapis.com/cloudidentity/total_licenses", total, False),
            ("custom.googleapis.com/cloudidentity/available_licenses", available, False),
            ("custom.googleapis.com/cloudidentity/utilization_percent", util_pct, True),
        ]

        for metric_type, val, is_float in metric_specs:
            series = monitoring_v3.TimeSeries()
            series.metric.type = metric_type
            series.metric.labels["sku_id"] = sku_id
            series.metric.labels["sku_name"] = sku_name
            series.resource.type = "global"
            series.resource.labels["project_id"] = project_id

            point = monitoring_v3.Point()
            point.interval.end_time = {"seconds": now_seconds}

            if is_float:
                point.value.double_value = float(val)
            else:
                point.value.int64_value = int(val)

            series.points = [point]
            series_list.append(series)

    if series_list:
        client.create_time_series(name=project_name, time_series=series_list)
        logger.info("Successfully pushed %d custom metrics to Cloud Monitoring.", len(series_list))


def run_license_check() -> Dict[str, Any]:
    """Orchestrates token retrieval, license counting, and metric publication."""
    if not WORKSPACE_ADMIN_EMAIL:
        raise ValueError(
            "WORKSPACE_ADMIN_EMAIL environment variable is required. "
            "Please configure it with a Google Workspace admin email (e.g., admin@yourdomain.com)."
        )
    if not PROJECT_ID:
        raise ValueError(
            "GCP_PROJECT_ID environment variable is required. "
            "Please configure it with your Google Cloud Project ID."
        )
    if not SERVICE_ACCOUNT_EMAIL:
        raise ValueError(
            "SERVICE_ACCOUNT_EMAIL environment variable is required. "
            "Please configure it with the service account email authorized for Domain-Wide Delegation."
        )

    logger.info("Starting license check for admin='%s' via SA='%s'", WORKSPACE_ADMIN_EMAIL, SERVICE_ACCOUNT_EMAIL)
    access_token = get_delegated_access_token(SERVICE_ACCOUNT_EMAIL, WORKSPACE_ADMIN_EMAIL)

    customer_id = WORKSPACE_CUSTOMER_ID or (
        WORKSPACE_ADMIN_EMAIL.split("@")[1] if "@" in WORKSPACE_ADMIN_EMAIL else "my_customer"
    )
    skus = load_target_skus()
    results = []

    for sku_config in skus:
        name = sku_config.get("name", "Unknown SKU")
        product_id = sku_config["productId"]
        sku_id = sku_config["skuId"]
        total_seats = int(sku_config.get("totalSeats", 0))

        assigned_count, users = count_assigned_licenses(access_token, product_id, sku_id, customer_id)
        available_seats = max(0, total_seats - assigned_count) if total_seats > 0 else 0
        util_pct = (assigned_count / total_seats * 100) if total_seats > 0 else 0.0

        item_result = {
            "name": name,
            "productId": product_id,
            "skuId": sku_id,
            "totalSeats": total_seats,
            "assigned": assigned_count,
            "available": available_seats,
            "utilizationPercent": round(util_pct, 2),
            "sampleUsers": users[:5],
        }
        results.append(item_result)
        logger.info(
            "SKU '%s' (%s): Total=%d | Assigned=%d | Available=%d | Util=%.1f%%",
            name, sku_id, total_seats, assigned_count, available_seats, util_pct
        )

    # Publish to Cloud Monitoring
    publish_metrics_to_cloud_monitoring(PROJECT_ID, results)

    return {
        "status": "success",
        "timestamp": int(time.time()),
        "projectId": PROJECT_ID,
        "results": results,
    }


# HTTP Routes for Cloud Run / Cloud Functions
@app.route("/", methods=["GET", "POST"])
def handle_http():
    try:
        report = run_license_check()
        return jsonify(report), 200
    except Exception as e:
        logger.exception("Error executing license check: %s", e)
        return jsonify({"status": "error", "message": str(e)}), 500


@app.route("/healthz", methods=["GET"])
def health_check():
    return jsonify({"status": "healthy"}), 200


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Cloud Identity License Monitor")
    parser.add_argument("--run-once", action="store_true", help="Execute single check and exit")
    parser.add_argument("--port", type=int, default=int(os.environ.get("PORT", 8080)), help="Port to listen on")
    args = parser.parse_args()

    if args.run_once or os.environ.get("RUN_ONCE") == "true":
        try:
            report = run_license_check()
            print(json.dumps(report, indent=2))
            sys.exit(0)
        except Exception as ex:
            logger.error("Execution failed: %s", ex)
            sys.exit(1)
    else:
        app.run(host="0.0.0.0", port=args.port)

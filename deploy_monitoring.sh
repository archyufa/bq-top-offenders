#!/bin/bash

# ==============================================================================
#
# deploy_monitoring.sh
#
# This script automates the setup of the BigQuery real-time cost monitoring
# and alerting solution as described in the architecture document.
#
# It performs the following actions:
#   1. Creates a log-based metric to extract billed bytes from BQ audit logs.
#   2. Creates a notification channel to send alerts.
#   3. Creates an alerting policy to trigger notifications on cost anomalies.
#
# The script is idempotent and can be re-run safely.
#
# ==============================================================================

set -e
set -o pipefail

# --- Configuration Variables ---
# TODO: Customize these variables for your environment.

# The Google Cloud project where you want to deploy the monitoring resources.
GCP_PROJECT_ID=$(gcloud config get-value project)

# The name for the log-based metric.
METRIC_NAME="bq_billed_bytes_rt"

# The name for the alerting policy.
ALERT_POLICY_NAME="bq-cost-spike-alert"

# The email address to send alert notifications to.
NOTIFICATION_EMAIL="your-email@example.com"

# --- Helper Functions ---

# Function to print messages to stderr
info() {
  echo "[INFO] $1" >&2
}

# Function to check if a command exists
command_exists() {
  command -v "$1" >/dev/null 2>&1
}

# --- Prerequisite Checks ---

info "Starting prerequisite checks..."

if ! command_exists gcloud; then
  echo "[ERROR] gcloud command not found. Please install the Google Cloud SDK and ensure it's in your PATH." >&2
  exit 1
fi

if [ -z "$GCP_PROJECT_ID" ]; then
    echo "[ERROR] Google Cloud project ID is not set. Please run 'gcloud config set project YOUR_PROJECT_ID'." >&2
    exit 1
fi

info "Using project: $GCP_PROJECT_ID"

if [[ "$NOTIFICATION_EMAIL" == "your-email@example.com" ]]; then
    echo "[ERROR] Please edit this script and set the NOTIFICATION_EMAIL variable." >&2
    exit 1
fi

info "Prerequisite checks passed."

# --- Resource Deployment ---

# The rest of the deployment commands will be added in subsequent steps.

info "Script execution started. More deployment steps to come."

# --- 1. Create Log-based Metric ---

info "Checking for existence of log-based metric [$METRIC_NAME]..."

# Check if the metric already exists
if gcloud logging metrics describe "$METRIC_NAME" --project="$GCP_PROJECT_ID" >/dev/null 2>&1; then
  info "Log-based metric [$METRIC_NAME] already exists. Skipping creation."
else
  info "Creating log-based metric [$METRIC_NAME]..."
  gcloud logging metrics create "$METRIC_NAME" \
    --project="$GCP_PROJECT_ID" \
    --description="Tracks the total bytes billed by BigQuery queries in near real-time." \
    --log-filter='resource.type="bigquery_project" AND protoPayload.methodName="jobservice.jobcompleted" AND protoPayload.serviceData.jobCompletedEvent.job.jobStatistics.totalBilledBytes > 0' \
    --metric-descriptor="metric_kind=DELTA,value_type=DISTRIBUTION" \
    --value-extractor='EXTRACT(protoPayload.serviceData.jobCompletedEvent.job.jobStatistics.totalBilledBytes)' \
    --label-extractors='user=EXTRACT(protoPayload.authenticationInfo.principalEmail)'

  info "Successfully created log-based metric [$METRIC_NAME]."
fi

# --- 2. Create Notification Channel ---

info "Checking for existence of notification channel for [$NOTIFICATION_EMAIL]..."

# Check if a channel with this email already exists to avoid duplicates.
# The channel name is what we need for the alerting policy.
CHANNEL_NAME=$(gcloud alpha monitoring channels list \
  --project="$GCP_PROJECT_ID" \
  --filter="displayName=\"Email\" AND labels.email_address=\"$NOTIFICATION_EMAIL\"" \
  --format="value(name)" \
  --limit=1)

if [ -n "$CHANNEL_NAME" ]; then
  info "Notification channel for [$NOTIFICATION_EMAIL] already exists. Using existing channel."
else
  info "Creating notification channel for [$NOTIFICATION_EMAIL]..."
  CHANNEL_NAME=$(gcloud alpha monitoring channels create \
    --project="$GCP_PROJECT_ID" \
    --display-name="Email" \
    --description="Email notifications for BQ cost alerts" \
    --type="email" \
    --channel-labels="email_address=$NOTIFICATION_EMAIL" \
    --format="value(name)")
  
  info "Successfully created notification channel. A verification email has been sent to [$NOTIFICATION_EMAIL]. Please verify it."
fi

echo "Using Notification Channel: $CHANNEL_NAME"

# --- 3. Create Alerting Policy ---

info "Checking for existence of alerting policy [$ALERT_POLICY_NAME]..."

if gcloud alpha monitoring policies list --project="$GCP_PROJECT_ID" --filter="displayName=\"$ALERT_POLICY_NAME\"" --format="value(name)" | grep -q .; then
  info "Alerting policy [$ALERT_POLICY_NAME] already exists. Skipping creation."
else
  info "Creating alerting policy [$ALERT_POLICY_NAME]..."

  # Define the condition in a temporary JSON file.
  # This alert triggers if the sum of billed bytes in a 1-hour window
  # exceeds 1 TB. The threshold value is in bytes (1 * 10^12).
  # You can adjust the threshold and duration to fit your needs.
  CONDITION_FILE=$(mktemp)
  cat > "$CONDITION_FILE" <<EOF
{
  "conditionThreshold": {
    "aggregations": [
      {
        "alignmentPeriod": "3600s",
        "crossSeriesReducer": "REDUCE_SUM",
        "perSeriesAligner": "ALIGN_SUM"
      }
    ],
    "comparison": "COMPARISON_GT",
    "duration": "0s",
    "filter": "metric.type=\\"logging.googleapis.com/user/${METRIC_NAME}\\" AND resource.type=\\"bigquery_project\\"",
    "thresholdValue": 1000000000000,
    "trigger": {
      "count": 1
    }
  },
  "displayName": "Total BQ Billed Bytes over 1TB in 1 hour"
}
EOF

  gcloud alpha monitoring policies create \
    --project="$GCP_PROJECT_ID" \
    --policy-from-file="$CONDITION_FILE" \
    --display-name="$ALERT_POLICY_NAME" \
    --notification-channels="$CHANNEL_NAME" \
    --documentation-content="A BigQuery cost spike has been detected. Check the BQ Cost Monitoring Dashboard immediately to identify the source."

  rm "$CONDITION_FILE"
  info "Successfully created alerting policy [$ALERT_POLICY_NAME]."
fi

# --- 4. Create Monitoring Dashboard ---

info "Deploying the monitoring dashboard..."

# The gcloud command for dashboards will update an existing dashboard
# if one with the same name is found, so we don't need a separate check.
gcloud monitoring dashboards create \
  --project="$GCP_PROJECT_ID" \
  --config-from-file="dashboard.json"

info "Dashboard deployment complete."


info "Script execution finished successfully."

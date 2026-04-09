#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  ./setup.sh

Environment overrides:
  AWS_REGION                     Default: eu-west-2
  AWS_DEFAULT_REGION             Default: AWS_REGION
  TRAIL_NAME                     Default: bedrock-residency-trail
  TRAIL_BUCKET                   Default: bedrock-residency-trail-<account>-<region>
  BEDROCK_INVOCATION_LOG_GROUP   Default: bedrock-model-invocations
  BEDROCK_LOGGING_ROLE_NAME      Default: AmazonBedrockModelInvocationLoggingRole
  BEDROCK_LOGGING_POLICY_NAME    Default: AmazonBedrockModelInvocationLoggingPolicy

This script creates or updates:
  - A single-region CloudTrail trail for Bedrock API evidence
  - The S3 bucket policy required by CloudTrail
  - A CloudWatch log group for Bedrock model invocation logs
  - An IAM role that Bedrock can assume to write to CloudWatch Logs
  - The Bedrock model invocation logging configuration
EOF
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi

export AWS_REGION="${AWS_REGION:-eu-west-2}"
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-$AWS_REGION}"
ACCOUNT_ID="${ACCOUNT_ID:-$(aws sts get-caller-identity --query Account --output text)}"

TRAIL_NAME="${TRAIL_NAME:-bedrock-residency-trail}"
TRAIL_BUCKET="${TRAIL_BUCKET:-bedrock-residency-trail-${ACCOUNT_ID}-${AWS_REGION}}"
TRAIL_ARN="arn:aws:cloudtrail:${AWS_REGION}:${ACCOUNT_ID}:trail/${TRAIL_NAME}"

BEDROCK_INVOCATION_LOG_GROUP="${BEDROCK_INVOCATION_LOG_GROUP:-bedrock-model-invocations}"
BEDROCK_LOGGING_ROLE_NAME="${BEDROCK_LOGGING_ROLE_NAME:-AmazonBedrockModelInvocationLoggingRole}"
BEDROCK_LOGGING_POLICY_NAME="${BEDROCK_LOGGING_POLICY_NAME:-AmazonBedrockModelInvocationLoggingPolicy}"
BEDROCK_LOGGING_SETUP_RETRIES="${BEDROCK_LOGGING_SETUP_RETRIES:-8}"
BEDROCK_LOGGING_SETUP_SLEEP_SECONDS="${BEDROCK_LOGGING_SETUP_SLEEP_SECONDS:-10}"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

echo "AWS region: $AWS_REGION"
echo "Account: $ACCOUNT_ID"
echo "CloudTrail trail: $TRAIL_NAME"
echo "CloudTrail bucket: $TRAIL_BUCKET"
echo "Bedrock invocation log group: $BEDROCK_INVOCATION_LOG_GROUP"
echo "Bedrock logging role: $BEDROCK_LOGGING_ROLE_NAME"
echo "Bedrock logging retries: $BEDROCK_LOGGING_SETUP_RETRIES"
echo

if ! aws s3api head-bucket --bucket "$TRAIL_BUCKET" >/dev/null 2>&1; then
  echo "Creating S3 bucket for CloudTrail..."
  aws s3api create-bucket \
    --bucket "$TRAIL_BUCKET" \
    --create-bucket-configuration "LocationConstraint=$AWS_REGION" \
    --region "$AWS_REGION" >/dev/null
else
  echo "S3 bucket already exists."
fi

cat > "$TMP_DIR/cloudtrail-bucket-policy.json" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AWSCloudTrailAclCheck20150319",
      "Effect": "Allow",
      "Principal": { "Service": "cloudtrail.amazonaws.com" },
      "Action": "s3:GetBucketAcl",
      "Resource": "arn:aws:s3:::${TRAIL_BUCKET}",
      "Condition": {
        "StringEquals": {
          "aws:SourceArn": "${TRAIL_ARN}"
        }
      }
    },
    {
      "Sid": "AWSCloudTrailWrite20150319",
      "Effect": "Allow",
      "Principal": { "Service": "cloudtrail.amazonaws.com" },
      "Action": "s3:PutObject",
      "Resource": "arn:aws:s3:::${TRAIL_BUCKET}/AWSLogs/${ACCOUNT_ID}/*",
      "Condition": {
        "StringEquals": {
          "s3:x-amz-acl": "bucket-owner-full-control",
          "aws:SourceArn": "${TRAIL_ARN}"
        }
      }
    }
  ]
}
EOF

echo "Applying CloudTrail bucket policy..."
aws s3api put-bucket-policy \
  --bucket "$TRAIL_BUCKET" \
  --policy "file://$TMP_DIR/cloudtrail-bucket-policy.json" \
  --region "$AWS_REGION"

EXISTING_TRAIL="$(aws cloudtrail describe-trails \
  --trail-name-list "$TRAIL_NAME" \
  --region "$AWS_REGION" \
  --query 'trailList[0].Name' \
  --output text 2>/dev/null || true)"

if [[ "$EXISTING_TRAIL" != "$TRAIL_NAME" ]]; then
  echo "Creating CloudTrail trail..."
  aws cloudtrail create-trail \
    --name "$TRAIL_NAME" \
    --s3-bucket-name "$TRAIL_BUCKET" \
    --no-is-multi-region-trail \
    --region "$AWS_REGION" >/dev/null
else
  echo "CloudTrail trail already exists."
fi

echo "Starting CloudTrail logging..."
aws cloudtrail start-logging \
  --name "$TRAIL_NAME" \
  --region "$AWS_REGION"

EXISTING_LOG_GROUP="$(aws logs describe-log-groups \
  --log-group-name-prefix "$BEDROCK_INVOCATION_LOG_GROUP" \
  --region "$AWS_REGION" \
  --query "logGroups[?logGroupName=='$BEDROCK_INVOCATION_LOG_GROUP'].logGroupName | [0]" \
  --output text 2>/dev/null || true)"

if [[ "$EXISTING_LOG_GROUP" != "$BEDROCK_INVOCATION_LOG_GROUP" ]]; then
  echo "Creating CloudWatch log group..."
  aws logs create-log-group \
    --log-group-name "$BEDROCK_INVOCATION_LOG_GROUP" \
    --region "$AWS_REGION"
else
  echo "CloudWatch log group already exists."
fi

cat > "$TMP_DIR/bedrock-logging-trust-policy.json" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "bedrock.amazonaws.com"
      },
      "Action": "sts:AssumeRole",
      "Condition": {
        "StringEquals": {
          "aws:SourceAccount": "${ACCOUNT_ID}"
        },
        "ArnLike": {
          "aws:SourceArn": "arn:aws:bedrock:${AWS_REGION}:${ACCOUNT_ID}:*"
        }
      }
    }
  ]
}
EOF

if aws iam get-role --role-name "$BEDROCK_LOGGING_ROLE_NAME" >/dev/null 2>&1; then
  echo "Updating Bedrock logging role trust policy..."
  aws iam update-assume-role-policy \
    --role-name "$BEDROCK_LOGGING_ROLE_NAME" \
    --policy-document "file://$TMP_DIR/bedrock-logging-trust-policy.json"
else
  echo "Creating Bedrock logging role..."
  aws iam create-role \
    --role-name "$BEDROCK_LOGGING_ROLE_NAME" \
    --assume-role-policy-document "file://$TMP_DIR/bedrock-logging-trust-policy.json" >/dev/null
fi

cat > "$TMP_DIR/bedrock-logging-role-policy.json" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "logs:CreateLogStream",
        "logs:PutLogEvents"
      ],
      "Resource": [
        "arn:aws:logs:${AWS_REGION}:${ACCOUNT_ID}:log-group:${BEDROCK_INVOCATION_LOG_GROUP}:log-stream:aws/bedrock/modelinvocations",
        "arn:aws:logs:${AWS_REGION}:${ACCOUNT_ID}:log-group:${BEDROCK_INVOCATION_LOG_GROUP}:log-stream:*"
      ]
    }
  ]
}
EOF

echo "Applying Bedrock logging role policy..."
aws iam put-role-policy \
  --role-name "$BEDROCK_LOGGING_ROLE_NAME" \
  --policy-name "$BEDROCK_LOGGING_POLICY_NAME" \
  --policy-document "file://$TMP_DIR/bedrock-logging-role-policy.json"

BEDROCK_LOGGING_ROLE_ARN="$(aws iam get-role \
  --role-name "$BEDROCK_LOGGING_ROLE_NAME" \
  --query 'Role.Arn' \
  --output text)"

cat > "$TMP_DIR/bedrock-logging-config.json" <<EOF
{
  "loggingConfig": {
    "cloudWatchConfig": {
      "logGroupName": "${BEDROCK_INVOCATION_LOG_GROUP}",
      "roleArn": "${BEDROCK_LOGGING_ROLE_ARN}"
    },
    "textDataDeliveryEnabled": true,
    "imageDataDeliveryEnabled": false,
    "embeddingDataDeliveryEnabled": false,
    "videoDataDeliveryEnabled": false
  }
}
EOF

echo "Enabling Bedrock model invocation logging..."
attempt=1
while true; do
  if aws bedrock put-model-invocation-logging-configuration \
    --cli-input-json "file://$TMP_DIR/bedrock-logging-config.json" \
    --region "$AWS_REGION"; then
    break
  fi

  if [[ "$attempt" -ge "$BEDROCK_LOGGING_SETUP_RETRIES" ]]; then
    echo "Failed to enable Bedrock model invocation logging after $attempt attempts." >&2
    echo "This is usually IAM propagation delay. Re-run setup.sh or increase BEDROCK_LOGGING_SETUP_RETRIES." >&2
    exit 1
  fi

  echo "Bedrock logging setup validation failed. Waiting ${BEDROCK_LOGGING_SETUP_SLEEP_SECONDS}s for IAM propagation before retry ${attempt}/${BEDROCK_LOGGING_SETUP_RETRIES}..." >&2
  sleep "$BEDROCK_LOGGING_SETUP_SLEEP_SECONDS"
  attempt=$((attempt + 1))
done

echo
echo "Verification:"
aws cloudtrail get-trail-status \
  --name "$TRAIL_NAME" \
  --region "$AWS_REGION"
echo
aws bedrock get-model-invocation-logging-configuration \
  --region "$AWS_REGION"
echo
echo "Setup complete."

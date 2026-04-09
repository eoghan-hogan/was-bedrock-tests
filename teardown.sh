#!/usr/bin/env bash
set -euo pipefail

DELETE_LOCAL_ARTIFACTS=0
KEEP_TRAIL_BUCKET=0
KEEP_LOG_GROUP=0
KEEP_IAM_ROLE=0

usage() {
  cat <<'EOF'
Usage:
  ./teardown.sh [options]

Options:
  --delete-local-artifacts   Delete generated local probe/log files in this repo.
  --keep-trail-bucket        Keep the CloudTrail S3 bucket after deleting the trail.
  --keep-log-group           Keep the Bedrock invocation log group.
  --keep-iam-role            Keep the Bedrock invocation logging IAM role.
  -h, --help                 Show this help text.

Environment overrides:
  AWS_REGION                     Default: eu-west-2
  AWS_DEFAULT_REGION             Default: AWS_REGION
  TRAIL_NAME                     Default: bedrock-residency-trail
  TRAIL_BUCKET                   Default: bedrock-residency-trail-<account>-<region>
  BEDROCK_INVOCATION_LOG_GROUP   Default: bedrock-model-invocations
  BEDROCK_LOGGING_ROLE_NAME      Default: AmazonBedrockModelInvocationLoggingRole
  BEDROCK_LOGGING_POLICY_NAME    Default: AmazonBedrockModelInvocationLoggingPolicy
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --delete-local-artifacts)
      DELETE_LOCAL_ARTIFACTS=1
      shift
      ;;
    --keep-trail-bucket)
      KEEP_TRAIL_BUCKET=1
      shift
      ;;
    --keep-log-group)
      KEEP_LOG_GROUP=1
      shift
      ;;
    --keep-iam-role)
      KEEP_IAM_ROLE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

export AWS_REGION="${AWS_REGION:-eu-west-2}"
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-$AWS_REGION}"
ACCOUNT_ID="${ACCOUNT_ID:-$(aws sts get-caller-identity --query Account --output text)}"

TRAIL_NAME="${TRAIL_NAME:-bedrock-residency-trail}"
TRAIL_BUCKET="${TRAIL_BUCKET:-bedrock-residency-trail-${ACCOUNT_ID}-${AWS_REGION}}"
BEDROCK_INVOCATION_LOG_GROUP="${BEDROCK_INVOCATION_LOG_GROUP:-bedrock-model-invocations}"
BEDROCK_LOGGING_ROLE_NAME="${BEDROCK_LOGGING_ROLE_NAME:-AmazonBedrockModelInvocationLoggingRole}"
BEDROCK_LOGGING_POLICY_NAME="${BEDROCK_LOGGING_POLICY_NAME:-AmazonBedrockModelInvocationLoggingPolicy}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "AWS region: $AWS_REGION"
echo "Account: $ACCOUNT_ID"
echo "CloudTrail trail: $TRAIL_NAME"
echo "CloudTrail bucket: $TRAIL_BUCKET"
echo "Bedrock invocation log group: $BEDROCK_INVOCATION_LOG_GROUP"
echo "Bedrock logging role: $BEDROCK_LOGGING_ROLE_NAME"
echo

if aws bedrock get-model-invocation-logging-configuration --region "$AWS_REGION" >/dev/null 2>&1; then
  echo "Disabling Bedrock model invocation logging..."
  aws bedrock delete-model-invocation-logging-configuration --region "$AWS_REGION"
else
  echo "Bedrock model invocation logging is already disabled."
fi

if [[ "$KEEP_LOG_GROUP" -eq 0 ]]; then
  if aws logs describe-log-groups \
    --log-group-name-prefix "$BEDROCK_INVOCATION_LOG_GROUP" \
    --region "$AWS_REGION" \
    --query "logGroups[?logGroupName=='$BEDROCK_INVOCATION_LOG_GROUP'].logGroupName | [0]" \
    --output text 2>/dev/null | grep -qx "$BEDROCK_INVOCATION_LOG_GROUP"; then
    echo "Deleting CloudWatch log group..."
    aws logs delete-log-group \
      --log-group-name "$BEDROCK_INVOCATION_LOG_GROUP" \
      --region "$AWS_REGION"
  else
    echo "CloudWatch log group not found."
  fi
else
  echo "Keeping CloudWatch log group."
fi

if [[ "$KEEP_IAM_ROLE" -eq 0 ]]; then
  if aws iam get-role --role-name "$BEDROCK_LOGGING_ROLE_NAME" >/dev/null 2>&1; then
    echo "Deleting Bedrock logging IAM inline policy..."
    aws iam delete-role-policy \
      --role-name "$BEDROCK_LOGGING_ROLE_NAME" \
      --policy-name "$BEDROCK_LOGGING_POLICY_NAME" >/dev/null 2>&1 || true

    echo "Deleting Bedrock logging IAM role..."
    aws iam delete-role \
      --role-name "$BEDROCK_LOGGING_ROLE_NAME"
  else
    echo "Bedrock logging IAM role not found."
  fi
else
  echo "Keeping Bedrock logging IAM role."
fi

if aws cloudtrail describe-trails \
  --trail-name-list "$TRAIL_NAME" \
  --region "$AWS_REGION" \
  --query 'trailList[0].Name' \
  --output text 2>/dev/null | grep -qx "$TRAIL_NAME"; then
  echo "Stopping CloudTrail logging..."
  aws cloudtrail stop-logging \
    --name "$TRAIL_NAME" \
    --region "$AWS_REGION" >/dev/null 2>&1 || true

  echo "Deleting CloudTrail trail..."
  aws cloudtrail delete-trail \
    --name "$TRAIL_NAME" \
    --region "$AWS_REGION"
else
  echo "CloudTrail trail not found."
fi

if [[ "$KEEP_TRAIL_BUCKET" -eq 0 ]]; then
  if aws s3api head-bucket --bucket "$TRAIL_BUCKET" >/dev/null 2>&1; then
    echo "Removing CloudTrail bucket contents..."
    aws s3 rm "s3://${TRAIL_BUCKET}" --recursive >/dev/null 2>&1 || true
    echo "Deleting CloudTrail bucket..."
    aws s3 rb "s3://${TRAIL_BUCKET}"
  else
    echo "CloudTrail bucket not found."
  fi
else
  echo "Keeping CloudTrail bucket."
fi

if [[ "$DELETE_LOCAL_ARTIFACTS" -eq 1 ]]; then
  echo "Deleting local generated artifacts..."
  rm -rf \
    "$SCRIPT_DIR"/cloudtrail-finder-* \
    "$SCRIPT_DIR"/bedrock_residency_probe_*.json \
    "$SCRIPT_DIR"/cloudtrail-bucket-policy.json \
    "$SCRIPT_DIR"/bedrock-logging-trust-policy.json \
    "$SCRIPT_DIR"/bedrock-logging-role-policy.json \
    "$SCRIPT_DIR"/bedrock-logging-config.json
else
  echo "Keeping local generated artifacts."
fi

echo
echo "Teardown complete."

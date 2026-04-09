# Bedrock Residency Probe

This folder contains a minimal verification flow for checking source region versus execution region when you invoke Anthropic models through Amazon Bedrock in `eu-west-2`.

The flow is split into two steps:

1. `bedrock_claude_caller.py` invokes four model IDs from the London Bedrock runtime endpoint and writes a run artifact with the `run_id`, per-call `request_id`, and request outcome.
2. `cloudtrail-finder.sh` uses that artifact to pull the CloudTrail and Bedrock invocation-log evidence needed to decide whether the request only entered London, or also executed there.

## What This Proves

This repo can help you prove:

- the API request was sent to `https://bedrock-runtime.eu-west-2.amazonaws.com`
- which model ID or inference profile ID was invoked
- whether Bedrock invocation logs or CloudTrail expose an `inferenceRegion` that differs from `eu-west-2`

This repo does not prove residency from endpoint choice alone. Calling the London runtime endpoint is necessary, but it is not sufficient when you use `eu.*` inference profiles because Bedrock can process those requests in other EU regions.

## Models Covered

The probe calls these four IDs:

- `anthropic.claude-sonnet-4-6`
- `eu.anthropic.claude-sonnet-4-6`
- `anthropic.claude-opus-4-6-v1`
- `eu.anthropic.claude-opus-4-6-v1`

Interpret them like this:

- `anthropic.claude-sonnet-4-6` is the London-only candidate because AWS currently documents it as In-Region supported in `eu-west-2`.
- `anthropic.claude-opus-4-6-v1` is the critical negative control because AWS currently documents it as not In-Region in `eu-west-2`.
- Any `eu.*` profile should be treated as cross-region within AWS's EU routing set unless logs prove otherwise for a specific call.

## Prerequisites

- Python `3.11+`
- `boto3` installed
- AWS credentials with permission to invoke Bedrock models in `eu-west-2`, or `AWS_BEARER_TOKEN_BEDROCK` in `.env`
- AWS CLI v2 installed and authenticated
- Bedrock model access enabled for the Anthropic models you want to test
- Bedrock model invocation logging enabled to CloudWatch Logs

## One-Time AWS Setup

### 1. Set everything up in one copy-paste

`cloudtrail-finder.sh` uses both CloudTrail and Bedrock model invocation logging. The block below sets up all of the AWS resources this repo expects:

- a single-region CloudTrail trail in `eu-west-2`
- the required CloudTrail S3 bucket policy
- a CloudWatch log group for Bedrock invocation logs
- an IAM role that Bedrock can assume to write to that log group
- the Bedrock invocation logging configuration itself

It also includes the fixes discovered during testing:

- CloudTrail needs an explicit S3 bucket policy before `create-trail` works with an existing bucket
- the correct flag is `--no-is-multi-region-trail`, not `--is-multi-region-trail false`
- rerunning setup should tolerate already-existing resources

```bash
set -euo pipefail

export AWS_REGION=eu-west-2
export AWS_DEFAULT_REGION=eu-west-2
export ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"

export TRAIL_NAME="bedrock-residency-trail"
export TRAIL_BUCKET="bedrock-residency-trail-${ACCOUNT_ID}-eu-west-2"
export TRAIL_ARN="arn:aws:cloudtrail:${AWS_REGION}:${ACCOUNT_ID}:trail/${TRAIL_NAME}"

export BEDROCK_INVOCATION_LOG_GROUP="bedrock-model-invocations"
export BEDROCK_LOGGING_ROLE_NAME="AmazonBedrockModelInvocationLoggingRole"
export BEDROCK_LOGGING_POLICY_NAME="AmazonBedrockModelInvocationLoggingPolicy"

if ! aws s3api head-bucket --bucket "$TRAIL_BUCKET" 2>/dev/null; then
  aws s3api create-bucket \
    --bucket "$TRAIL_BUCKET" \
    --create-bucket-configuration LocationConstraint="$AWS_REGION" \
    --region "$AWS_REGION"
fi

cat > cloudtrail-bucket-policy.json <<EOF
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

aws s3api put-bucket-policy \
  --bucket "$TRAIL_BUCKET" \
  --policy file://cloudtrail-bucket-policy.json \
  --region "$AWS_REGION"

if ! aws cloudtrail describe-trails \
  --trail-name-list "$TRAIL_NAME" \
  --region "$AWS_REGION" \
  --query 'trailList[0].Name' \
  --output text 2>/dev/null | rg -qx "$TRAIL_NAME"; then
  aws cloudtrail create-trail \
    --name "$TRAIL_NAME" \
    --s3-bucket-name "$TRAIL_BUCKET" \
    --no-is-multi-region-trail \
    --region "$AWS_REGION"
fi

aws cloudtrail start-logging \
  --name "$TRAIL_NAME" \
  --region "$AWS_REGION"

if ! aws logs describe-log-groups \
  --log-group-name-prefix "$BEDROCK_INVOCATION_LOG_GROUP" \
  --region "$AWS_REGION" \
  --query 'logGroups[?logGroupName==`'"$BEDROCK_INVOCATION_LOG_GROUP"'`].logGroupName' \
  --output text | rg -qx "$BEDROCK_INVOCATION_LOG_GROUP"; then
  aws logs create-log-group \
    --log-group-name "$BEDROCK_INVOCATION_LOG_GROUP" \
    --region "$AWS_REGION"
fi

cat > bedrock-logging-trust-policy.json <<EOF
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

if ! aws iam get-role --role-name "$BEDROCK_LOGGING_ROLE_NAME" >/dev/null 2>&1; then
  aws iam create-role \
    --role-name "$BEDROCK_LOGGING_ROLE_NAME" \
    --assume-role-policy-document file://bedrock-logging-trust-policy.json >/dev/null
else
  aws iam update-assume-role-policy \
    --role-name "$BEDROCK_LOGGING_ROLE_NAME" \
    --policy-document file://bedrock-logging-trust-policy.json
fi

cat > bedrock-logging-role-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "logs:CreateLogStream",
        "logs:PutLogEvents"
      ],
      "Resource": "arn:aws:logs:${AWS_REGION}:${ACCOUNT_ID}:log-group:${BEDROCK_INVOCATION_LOG_GROUP}:log-stream:*"
    }
  ]
}
EOF

aws iam put-role-policy \
  --role-name "$BEDROCK_LOGGING_ROLE_NAME" \
  --policy-name "$BEDROCK_LOGGING_POLICY_NAME" \
  --policy-document file://bedrock-logging-role-policy.json

export BEDROCK_LOGGING_ROLE_ARN="$(aws iam get-role \
  --role-name "$BEDROCK_LOGGING_ROLE_NAME" \
  --query 'Role.Arn' \
  --output text)"

cat > bedrock-logging-config.json <<EOF
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

aws bedrock put-model-invocation-logging-configuration \
  --cli-input-json file://bedrock-logging-config.json \
  --region "$AWS_REGION"

aws cloudtrail get-trail-status \
  --name "$TRAIL_NAME" \
  --region "$AWS_REGION"

aws bedrock get-model-invocation-logging-configuration \
  --region "$AWS_REGION"
```

If you only need short-term testing, `aws cloudtrail lookup-events` can often work from CloudTrail event history without creating a dedicated trail. The dedicated trail is for retention and audit durability.

What matters for the probe is that your CloudTrail event JSON includes the Bedrock invocation entries you care about. Later, the helper script will look for fields such as:

- `eventSource`
- `eventName`
- `awsRegion`
- `requestParameters.modelId`
- `requestID`
- `tlsDetails.clientProvidedHostHeader`
- `additionalEventData.inferenceRegion`

### 2. What success looks like after setup

You should see:

- `aws cloudtrail get-trail-status` report `IsLogging: true`
- `aws bedrock get-model-invocation-logging-configuration` return your log group and role ARN
- no errors from the bucket policy, trail creation, or invocation logging calls

The log group name you configure here is the one you must pass to `cloudtrail-finder.sh`.

## Running the Probe

From this directory:

```bash
python3 bedrock_claude_caller.py
```

The script prints:

- the source region and endpoint
- a generated `run_id`
- one result block per model
- the Bedrock `RequestId` for each invocation
- the JSON artifact name, like `bedrock_residency_probe_<run_id>.json`

That JSON artifact is the input to the log helper. It contains the per-call request IDs used to correlate CloudTrail events with the probe run.

## Collecting CloudTrail And Invocation Logs

Run the helper with the `run_id` emitted by the Python script and the CloudWatch log group you configured for Bedrock invocation logging:

```bash
chmod +x cloudtrail-finder.sh

./cloudtrail-finder.sh \
  --run-id "<run_id>" \
  --log-group "$BEDROCK_INVOCATION_LOG_GROUP" \
  --save-raw
```

Useful options:

- `--results-file /path/to/bedrock_residency_probe_<run_id>.json` if the artifact is not in the current folder
- `--lookback-minutes 60` if CloudTrail or CloudWatch delivery is delayed
- `--region eu-west-2` to override the default explicitly

The helper prints two summaries:

1. CloudTrail matches, filtered down to the request IDs and model IDs from the probe artifact
2. Invocation log matches, filtered by the `run_id` embedded in the probe prompt

If you pass `--save-raw`, the script also writes the raw AWS CLI JSON responses to a `cloudtrail-finder-<run_id>/` folder for audit purposes.

## What To Look For In The Output

### CloudTrail

The CloudTrail section should show entries with values like:

- `host=bedrock-runtime.eu-west-2.amazonaws.com`
- `awsRegion=eu-west-2`
- `model=<the exact model ID you invoked>`
- `inferenceRegion=<value or empty>`

This is your best endpoint-routing proof. It shows the request entered the London Bedrock runtime endpoint.

### Bedrock Invocation Logs

The invocation log section is the stronger execution proof. Look for:

- `model=<the exact model ID>`
- `request_id=<matching Bedrock request ID when present>`
- `inferenceRegion=<actual execution region when present>`

If `inferenceRegion` is not `eu-west-2`, the request did not execute only in London.

If `inferenceRegion` is absent on an in-region model ID such as `anthropic.claude-sonnet-4-6`, that is expected in practice. AWS documents `inferenceRegion` as the CloudTrail field to identify where **cross-region** requests were processed. Read those in-region events together with:

- `host=bedrock-runtime.eu-west-2.amazonaws.com`
- `awsRegion=eu-west-2`
- the invocation-log `region=eu-west-2`

## Recommended Interpretation

- `anthropic.claude-sonnet-4-6` succeeds and logs stay in `eu-west-2`: strongest London-only candidate.
- `eu.anthropic.claude-sonnet-4-6` succeeds with `inferenceRegion` outside `eu-west-2`: proof that an EU profile can execute outside London.
- `anthropic.claude-opus-4-6-v1` should be verified empirically in your account. AWS documentation and runtime behavior can drift, and in testing for this repo it successfully invoked from `eu-west-2`.
- `eu.anthropic.claude-opus-4-6-v1` succeeds: expected for geo routing, but not London-only safe unless logs show otherwise for that call.

## Practical Notes

- CloudTrail can lag behind the invocation by a few minutes, so rerun the helper with a larger `--lookback-minutes` window if needed.
- Bedrock invocation logging must be enabled before you run the probe, otherwise the helper will only have CloudTrail evidence.
- If you rerun setup and see `TrailAlreadyExistsException` or `ResourceAlreadyExistsException`, that is usually harmless. The copy-paste block above is written to avoid those in normal cases.
- The `.env` file is treated as local-only configuration. Do not commit live bearer tokens or credentials.
# was-bedrock-tests

#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REGION="eu-west-2"
LOG_GROUP_NAME="${BEDROCK_INVOCATION_LOG_GROUP:-}"
LOOKBACK_MINUTES=30
RESULTS_FILE=""
RUN_ID=""
SAVE_RAW=0
RAW_DIR=""

usage() {
  cat <<'EOF'
Usage:
  ./cloudtrail-finder.sh --run-id <run_id> --log-group <cloudwatch_log_group> [options]

Options:
  --run-id <run_id>           Probe run ID from bedrock_claude_caller.py output.
  --results-file <path>       Probe results JSON file. Defaults to bedrock_residency_probe_<run_id>.json.
  --region <aws_region>       AWS region for CloudTrail and CloudWatch Logs lookups. Default: eu-west-2.
  --log-group <name>          Bedrock invocation CloudWatch log group name.
  --lookback-minutes <mins>   Minutes before probe timestamp to include in lookups. Default: 30.
  --save-raw                  Save raw AWS CLI JSON responses under cloudtrail-finder-<run_id>/.
  --help                      Show this message.

Examples:
  ./cloudtrail-finder.sh --run-id 1234 --log-group bedrock-model-invocations
  ./cloudtrail-finder.sh --run-id 1234 --log-group bedrock-model-invocations --save-raw
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --run-id)
      RUN_ID="$2"
      shift 2
      ;;
    --results-file)
      RESULTS_FILE="$2"
      shift 2
      ;;
    --region)
      REGION="$2"
      shift 2
      ;;
    --log-group)
      LOG_GROUP_NAME="$2"
      shift 2
      ;;
    --lookback-minutes)
      LOOKBACK_MINUTES="$2"
      shift 2
      ;;
    --save-raw)
      SAVE_RAW=1
      shift
      ;;
    --help|-h)
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

if [[ -z "$RUN_ID" ]]; then
  echo "Error: --run-id is required." >&2
  usage >&2
  exit 1
fi

if [[ -z "$LOG_GROUP_NAME" ]]; then
  echo "Error: --log-group is required (or set BEDROCK_INVOCATION_LOG_GROUP)." >&2
  usage >&2
  exit 1
fi

if [[ -z "$RESULTS_FILE" ]]; then
  RESULTS_FILE="$SCRIPT_DIR/bedrock_residency_probe_${RUN_ID}.json"
fi

if [[ ! -f "$RESULTS_FILE" ]]; then
  echo "Error: results file not found: $RESULTS_FILE" >&2
  exit 1
fi

if [[ "$SAVE_RAW" -eq 1 ]]; then
  RAW_DIR="$SCRIPT_DIR/cloudtrail-finder-${RUN_ID}"
  mkdir -p "$RAW_DIR"
else
  RAW_DIR="$(mktemp -d)"
  trap 'rm -rf "$RAW_DIR"' EXIT
fi

METADATA_JSON="$RAW_DIR/metadata.json"
CLOUDTRAIL_RAW="$RAW_DIR/cloudtrail-events.json"
INVOCATION_RAW="$RAW_DIR/invocation-log-events.json"

python3 - "$RESULTS_FILE" "$RUN_ID" "$LOOKBACK_MINUTES" <<'PY' > "$METADATA_JSON"
import json
import sys
from datetime import datetime, timedelta, timezone

results_path, expected_run_id, lookback_minutes = sys.argv[1], sys.argv[2], int(sys.argv[3])
with open(results_path, "r", encoding="utf-8") as handle:
    payload = json.load(handle)

run_id = payload.get("run_id")
if run_id != expected_run_id:
    raise SystemExit(
        f"run_id mismatch: results file contains {run_id!r}, expected {expected_run_id!r}"
    )

timestamp = payload.get("timestamp")
if not timestamp:
    raise SystemExit("results file is missing timestamp")

run_time = datetime.fromisoformat(timestamp.replace("Z", "+00:00"))
if run_time.tzinfo is None:
    run_time = run_time.replace(tzinfo=timezone.utc)

start_time = run_time - timedelta(minutes=lookback_minutes)
end_time = datetime.now(timezone.utc)
request_ids = []
model_ids = []
for item in payload.get("results", []):
    request_id = item.get("request_id")
    if request_id:
        request_ids.append(request_id)
    model_id = item.get("model_id")
    if model_id and model_id not in model_ids:
        model_ids.append(model_id)

json.dump(
    {
        "run_id": run_id,
        "timestamp": timestamp,
        "start_time_iso": start_time.isoformat(),
        "end_time_iso": end_time.isoformat(),
        "start_time_ms": int(start_time.timestamp() * 1000),
        "end_time_ms": int(end_time.timestamp() * 1000),
        "request_ids": request_ids,
        "model_ids": model_ids,
    },
    sys.stdout,
    indent=2,
)
PY

START_TIME_ISO="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["start_time_iso"])' "$METADATA_JSON")"
END_TIME_ISO="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["end_time_iso"])' "$METADATA_JSON")"
START_TIME_MS="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["start_time_ms"])' "$METADATA_JSON")"
END_TIME_MS="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["end_time_ms"])' "$METADATA_JSON")"

echo "Probe run: $RUN_ID"
echo "Results file: $RESULTS_FILE"
echo "Region: $REGION"
echo "CloudWatch log group: $LOG_GROUP_NAME"
echo "Lookup window: $START_TIME_ISO -> $END_TIME_ISO"
echo

aws cloudtrail lookup-events \
  --lookup-attributes AttributeKey=EventSource,AttributeValue=bedrock.amazonaws.com \
  --start-time "$START_TIME_ISO" \
  --end-time "$END_TIME_ISO" \
  --max-results 100 \
  --region "$REGION" \
  --output json > "$CLOUDTRAIL_RAW"

LOGS_ERROR=""
if ! aws logs filter-log-events \
  --log-group-name "$LOG_GROUP_NAME" \
  --start-time "$START_TIME_MS" \
  --end-time "$END_TIME_MS" \
  --filter-pattern "\"$RUN_ID\"" \
  --region "$REGION" \
  --output json > "$INVOCATION_RAW"; then
  LOGS_ERROR="Unable to query CloudWatch Logs. Confirm Bedrock model invocation logging is enabled and the log group exists."
  printf '{"events":[]}\n' > "$INVOCATION_RAW"
fi

python3 - "$METADATA_JSON" "$CLOUDTRAIL_RAW" "$INVOCATION_RAW" "$LOGS_ERROR" <<'PY'
import json
import sys
from typing import Any

metadata_path, cloudtrail_path, invocation_path, logs_error = sys.argv[1:5]


def load_json(path: str) -> dict:
    with open(path, "r", encoding="utf-8") as handle:
        return json.load(handle)


def dig_first(obj: Any, key: str):
    if isinstance(obj, dict):
        if key in obj and obj[key] not in (None, "", []):
            return obj[key]
        for value in obj.values():
            found = dig_first(value, key)
            if found not in (None, "", []):
                return found
    elif isinstance(obj, list):
        for value in obj:
            found = dig_first(value, key)
            if found not in (None, "", []):
                return found
    return None


def compact_message(message: str, limit: int = 220) -> str:
    one_line = " ".join(message.split())
    if len(one_line) <= limit:
        return one_line
    return one_line[: limit - 3] + "..."


metadata = load_json(metadata_path)
cloudtrail = load_json(cloudtrail_path)
invocation = load_json(invocation_path)

request_ids = set(metadata.get("request_ids", []))
model_ids = set(metadata.get("model_ids", []))

matched_cloudtrail = []
for event in cloudtrail.get("Events", []):
    raw_event = event.get("CloudTrailEvent")
    if not raw_event:
        continue
    try:
        detail = json.loads(raw_event)
    except json.JSONDecodeError:
        continue

    request_id = detail.get("requestID") or event.get("EventId")
    model_id = dig_first(detail.get("requestParameters"), "modelId")
    if request_ids and request_id not in request_ids and model_id not in model_ids:
        continue

    matched_cloudtrail.append(
        {
            "event_time": event.get("EventTime"),
            "event_name": detail.get("eventName") or event.get("EventName"),
            "aws_region": detail.get("awsRegion"),
            "request_id": request_id,
            "model_id": model_id,
            "inference_region": dig_first(detail.get("additionalEventData"), "inferenceRegion"),
            "host_header": dig_first(detail.get("tlsDetails"), "clientProvidedHostHeader"),
            "source_ip": detail.get("sourceIPAddress"),
        }
    )

print("CloudTrail matches:")
if matched_cloudtrail:
    for item in matched_cloudtrail:
        print(
            "- {event_time} | {event_name} | model={model_id} | request_id={request_id} | "
            "awsRegion={aws_region} | inferenceRegion={inference_region} | host={host_header}".format(
                **item
            )
        )
else:
    print("- No matching Bedrock CloudTrail events found in the selected window.")

print()
print("Invocation log matches:")
matched_invocation = []
for event in invocation.get("events", []):
    message = event.get("message", "")
    parsed = None
    try:
        parsed = json.loads(message)
    except json.JSONDecodeError:
        parsed = None

    model_id = dig_first(parsed, "modelId") if parsed else None
    request_id = dig_first(parsed, "requestId") if parsed else None
    inference_region = dig_first(parsed, "inferenceRegion") if parsed else None
    region = dig_first(parsed, "region") if parsed else None
    matched_invocation.append(
        {
            "timestamp": event.get("timestamp"),
            "log_stream": event.get("logStreamName"),
            "request_id": request_id,
            "model_id": model_id,
            "inference_region": inference_region,
            "region": region,
            "message_excerpt": compact_message(message),
        }
    )

if matched_invocation:
    for item in matched_invocation:
        print(
            "- {timestamp} | stream={log_stream} | model={model_id} | request_id={request_id} | "
            "inferenceRegion={inference_region} | region={region}".format(**item)
        )
        print("  excerpt: {message_excerpt}".format(**item))
else:
    print("- No invocation log events contained the run ID.")

if logs_error:
    print()
    print(f"CloudWatch Logs note: {logs_error}")
PY

if [[ "$SAVE_RAW" -eq 1 ]]; then
  echo
  echo "Saved raw outputs under: $RAW_DIR"
  echo "- $(basename "$METADATA_JSON")"
  echo "- $(basename "$CLOUDTRAIL_RAW")"
  echo "- $(basename "$INVOCATION_RAW")"
fi

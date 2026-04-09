import json
import os
import sys
import uuid
from datetime import datetime, timezone
from pathlib import Path

import boto3
from botocore.exceptions import BotoCoreError, ClientError, NoCredentialsError

REGION = "eu-west-2"
ENDPOINT_URL = f"https://bedrock-runtime.{REGION}.amazonaws.com"
ENV_VAR_NAME = "AWS_BEARER_TOKEN_BEDROCK"
RESULTS_PREFIX = "bedrock_residency_probe"
MODELS = [
    {
        "label": "Claude Sonnet 4.6 (In-Region)",
        "model_id": "anthropic.claude-sonnet-4-6",
        "expected_success": True,
        "inference_mode": "in-region",
    },
    {
        "label": "Claude Sonnet 4.6 (EU profile)",
        "model_id": "eu.anthropic.claude-sonnet-4-6",
        "expected_success": True,
        "inference_mode": "eu-profile",
    },
    {
        "label": "Claude Opus 4.6 (In-Region)",
        "model_id": "anthropic.claude-opus-4-6-v1",
        "expected_success": False,
        "inference_mode": "in-region",
    },
    {
        "label": "Claude Opus 4.6 (EU profile)",
        "model_id": "eu.anthropic.claude-opus-4-6-v1",
        "expected_success": True,
        "inference_mode": "eu-profile",
    },
]


def load_env_file(env_path: Path) -> bool:
    if not env_path.exists():
        return False

    loaded = False
    for raw_line in env_path.read_text().splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue

        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip().strip("'").strip('"')
        if key and value and key not in os.environ:
            os.environ[key] = value
            loaded = True

    return loaded


def build_request_body(prompt: str) -> str:
    return json.dumps(
        {
            "anthropic_version": "bedrock-2023-05-31",
            "messages": [
                {
                    "role": "user",
                    "content": [{"type": "text", "text": prompt}],
                }
            ],
            "max_tokens": 256,
        }
    )


def extract_text(payload: dict) -> str | None:
    content = payload.get("content")
    if not isinstance(content, list):
        return None

    parts = []
    for item in content:
        if isinstance(item, dict) and item.get("type") == "text" and item.get("text"):
            parts.append(item["text"])

    if parts:
        return "\n".join(parts)
    return None


def build_probe_prompt(run_id: str, timestamp: str, model_id: str) -> str:
    return (
        "Residency probe. "
        f"run_id={run_id} "
        f"timestamp={timestamp} "
        f"source_region={REGION} "
        f"model={model_id}. "
        "Reply with exactly: ok"
    )


def preview_text(text: str, limit: int = 240) -> str:
    compact = " ".join(text.split())
    if len(compact) <= limit:
        return compact
    return f"{compact[: limit - 3]}..."


def invoke_model(client, model: dict, prompt: str) -> dict:
    try:
        response = client.invoke_model(
            modelId=model["model_id"],
            body=build_request_body(prompt),
            contentType="application/json",
            accept="application/json",
        )
        payload = json.loads(response["body"].read().decode("utf-8"))
        extracted_text = extract_text(payload)
        response_text = extracted_text or json.dumps(payload, indent=2)
        return {
            "success": True,
            "request_id": response["ResponseMetadata"].get("RequestId"),
            "http_status": response["ResponseMetadata"]["HTTPStatusCode"],
            "response_text": response_text,
            "response_preview": preview_text(response_text),
        }
    except NoCredentialsError as exc:
        return {
            "success": False,
            "request_id": None,
            "http_status": None,
            "error_code": "NoCredentialsError",
            "error_message": f"No AWS credentials or Bedrock bearer token were available: {exc}",
        }
    except ClientError as exc:
        error = exc.response.get("Error", {})
        code = error.get("Code", "Unknown")
        message = error.get("Message", str(exc))
        return {
            "success": False,
            "request_id": exc.response.get("ResponseMetadata", {}).get("RequestId"),
            "http_status": exc.response.get("ResponseMetadata", {}).get("HTTPStatusCode"),
            "error_code": code,
            "error_message": message,
        }
    except BotoCoreError as exc:
        return {
            "success": False,
            "request_id": None,
            "http_status": None,
            "error_code": "BotoCoreError",
            "error_message": str(exc),
        }


def create_client():
    return boto3.client(
        "bedrock-runtime",
        region_name=REGION,
        endpoint_url=ENDPOINT_URL,
    )


def write_results_file(run_id: str, payload: dict) -> Path:
    output_path = Path(__file__).with_name(f"{RESULTS_PREFIX}_{run_id}.json")
    output_path.write_text(json.dumps(payload, indent=2) + "\n")
    return output_path


def main() -> int:
    env_path = Path(__file__).with_name(".env")
    loaded_from_env = load_env_file(env_path)
    using_bearer_token = bool(os.environ.get(ENV_VAR_NAME))
    run_id = str(uuid.uuid4())
    timestamp = datetime.now(timezone.utc).isoformat()

    print(f"Region: {REGION}")
    print(f"Endpoint: {ENDPOINT_URL}")
    print(f"Run ID: {run_id}")
    print(f"Timestamp: {timestamp}")
    if using_bearer_token:
        source = ".env" if loaded_from_env else "process environment"
        print(f"Auth: using {ENV_VAR_NAME} from {source}")
    else:
        print("Auth: no bearer token found; falling back to the shell's AWS credentials/profile")

    client = create_client()
    results = []
    expected_behavior_met = True

    for model in MODELS:
        prompt = build_probe_prompt(run_id, timestamp, model["model_id"])
        print()
        print(f"=== {model['label']} ===")
        print(f"Model ID: {model['model_id']}")
        print(f"Expected result: {'success' if model['expected_success'] else 'failure'}")
        print(f"Inference mode: {model['inference_mode']}")

        outcome = invoke_model(client, model, prompt)
        succeeded = outcome["success"]
        actual = "success" if succeeded else "failure"
        print(f"Actual result: {actual}")
        print(f"HTTP status: {outcome.get('http_status')}")
        print(f"Request ID: {outcome.get('request_id')}")

        if succeeded:
            print(f"Response preview: {outcome['response_preview']}")
        else:
            print("Error:")
            print(f"{outcome['error_code']}: {outcome['error_message']}")

        matches_expectation = succeeded == model["expected_success"]
        if not matches_expectation:
            expected_behavior_met = False

        results.append(
            {
                "label": model["label"],
                "model_id": model["model_id"],
                "inference_mode": model["inference_mode"],
                "expected_success": model["expected_success"],
                "matches_expectation": matches_expectation,
                "prompt": prompt,
                **outcome,
            }
        )

    output = {
        "run_id": run_id,
        "timestamp": timestamp,
        "source_region": REGION,
        "endpoint_url": ENDPOINT_URL,
        "using_bearer_token": using_bearer_token,
        "results": results,
    }
    output_path = write_results_file(run_id, output)

    print()
    print(f"Saved results: {output_path.name}")
    if expected_behavior_met:
        print("Result: observed behavior matched expectations.")
        return 0

    print("Result: observed behavior did not match expectations.")
    return 1


if __name__ == "__main__":
    sys.exit(main())

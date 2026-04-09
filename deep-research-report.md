# Verifying Amazon Bedrock model regional availability and data residency for eu-west-2

## Executive summary

Configuring an AWS SDK/CLI client for `eu-west-2` reliably directs your API call to the **regional Amazon Bedrock Runtime endpoint** (`bedrock-runtime.eu-west-2.amazonaws.com`). However, that **does not automatically guarantee** that **model execution / inference processing** occurs in `eu-west-2`, because Amazon Bedrock supports **cross-Region inference** via **inference profiles** (geographic and global) that can process your request in **other Regions**. citeturn11view0turn19view0turn17view0

For strict London-only processing, you must (a) use a model that supports **In-Region** inference in `eu-west-2`, and (b) invoke it using the **In-Region model ID** (not an `eu.` / `global.` inference profile). AWS’s own description of “In-Region” is that requests “never leave” the specified Region, and the model cards for Claude Sonnet 4.6 and Opus 4.6 explicitly distinguish In-Region vs geographic/global cross-Region options. citeturn1view1turn21view1turn21view0

As of 8 April 2026, official AWS documentation indicates:

- **Claude Sonnet 4.6**: **In-Region = Yes** in `eu-west-2` (so London-only processing is *architecturally supported* if you use the In-Region option). citeturn21view1turn25view1  
- **Claude Opus 4.6**: **In-Region = No** in `eu-west-2`, but **Geo = Yes** and **Global = Yes** (meaning you can invoke from `eu-west-2`, but inference may process in other Regions). citeturn21view0turn3view0

To empirically verify where processing occurred, AWS documents two first-party indicators:
- CloudTrail events may include `additionalEventData.inferenceRegion` for cross-Region inference, showing the Region that processed the request. citeturn17view0turn18view1  
- Bedrock Model Invocation Logging can include `inferenceRegion` in the log record, likewise indicating where processing occurred. citeturn18view1turn8view1

## What “setting the Region” actually guarantees in practice

### Regional API endpoint selection is deterministic

Amazon Bedrock Runtime has **Region-specific endpoints**, including `bedrock-runtime.eu-west-2.amazonaws.com` for the London Region. citeturn11view0

AWS’s general endpoint guidance is that SDKs and the AWS CLI automatically use the default endpoint for the configured Region, and the BedrockRuntime SDK documentation (example: JavaScript SDK) spells out that the default endpoint is built from the configured `region` (e.g., `https://{service}.{region}.amazonaws.com`). citeturn19view1turn19view0

**What you can conclude from this:** setting `region=eu-west-2` (or `--region eu-west-2`) ensures the client signs and sends the request to the eu-west-2 Bedrock endpoint. citeturn19view0turn11view0

### Model execution location depends on the inference option

AWS’s Bedrock documentation distinguishes three inference options:

- **In-Region**: requests are kept within a single Region for strict compliance. citeturn1view1turn21view1  
- **Geographic cross-Region inference**: routes across Regions within a geography (e.g., “EU”) and AWS automatically selects an optimal Region within that geography to process the request. citeturn17view0turn1view1  
- **Global cross-Region inference**: routes to any supported commercial Region worldwide; AWS automatically selects an optimal Region to process the request. citeturn17view0turn1view1  

AWS also documents that cross-Region inference can route to Regions that are not manually enabled in your account, and that CloudTrail logging stays in the **source Region** even when processing occurs elsewhere—hence the need to read the “processed in” indicator fields. citeturn17view0turn18view1

Anthropic’s own model documentation aligns conceptually: starting with Claude Sonnet 4.5 and later (including Sonnet 4.6), Bedrock offers **global endpoints** (dynamic routing) and **regional endpoints** (guaranteed routing through specific geographic regions). citeturn27view0

**Key conclusion:** “Region = eu-west-2” guarantees the **API entry point**; it does **not** by itself guarantee **inference processing stays in eu-west-2** unless you also ensure you are using **In-Region** inference and a model that supports it in that Region. citeturn17view0turn21view1turn21view0

## Official availability of Claude Opus 4.6 and Sonnet 4.6 in eu-west-2

### AWS model cards and the regional availability page

AWS’s official regional availability tables show the London Region (`eu-west-2`) and whether each inference option is supported for each model. For the two requested models, AWS’s own model cards state:

- Claude Sonnet 4.6: `eu-west-2 (London)` has **In-Region = Yes**, **Geo = Yes**, **Global = Yes**. citeturn21view1turn25view1  
- Claude Opus 4.6: `eu-west-2 (London)` has **In-Region = No**, **Geo = Yes**, **Global = Yes**. citeturn21view0turn3view0  

The central “Regional availability” doc page provides the definitions of those columns (In-Region, Geo Cross-Region, Global Cross-Region) and explicitly notes that for cross-region options, prompts/outputs might move beyond the source Region during inference (depending on the selected option). citeturn1view1turn17view0

### Inference profile region sets for “EU” cross-Region inference

The “supported inference profiles” documentation lists the **source Regions** that can call an inference profile and the **destination Regions** the request can be routed to.

For the EU inference profile ID `eu.anthropic.claude-opus-4-6-v1` and for `eu.anthropic.claude-sonnet-4-6`, AWS documents that `eu-west-2` is a source Region and (critically) shows a destination set that includes multiple European Regions, not just `eu-west-2`. citeturn6view2turn6view3turn25view1

**Implication:** even when you select “EU” geographic cross-Region inference while calling from `eu-west-2`, processing can occur outside London (e.g., Frankfurt, Paris, etc., as within the documented destination set). citeturn25view1turn6view2turn6view3

### Notable inconsistencies to treat carefully

AWS also maintains a “Supported foundation models in Amazon Bedrock” table that includes columns for “single-region model support” and “cross-region inference profile support.” The column definition for single-region support suggests it enumerates Regions that support inference calls “in that single Region.” citeturn22view0

In extracted table text, the entries for Anthropic Claude Opus 4.6 and Sonnet 4.6 appear to include `eu-west-2` in the region list. citeturn23view1turn23view0

That presentation can be misread as “Opus 4.6 runs in-region in eu-west-2,” which directly conflicts with the model card / regional availability tables that mark **Opus 4.6 In-Region = No** for `eu-west-2`. citeturn21view0turn23view1

**How to resolve this rigorously:** treat the model card and/or the dedicated regional-availability matrix as primary for *In-Region vs cross-Region* semantics, and validate directly in your account using the tests and log evidence below (especially the “inferenceRegion” indicators). citeturn21view0turn17view0turn18view1

### Requested table A: model availability comparison for eu-west-2

| Model | AWS documented availability in eu-west-2 | Vendor documentation signal | Observed in eu-west-2 (fill via tests) |
|---|---|---|---|
| Claude Sonnet 4.6 | In-Region **Yes**; Geo **Yes**; Global **Yes** citeturn21view1turn25view1 | Anthropic notes Bedrock offers global endpoints and “regional endpoints” (geographic routing) for Sonnet 4.6-era models. citeturn27view0 | Expected: In-Region invocation succeeds; cross-Region invocations may show `inferenceRegion` ≠ `eu-west-2`. citeturn17view0turn18view1 |
| Claude Opus 4.6 | In-Region **No**; Geo **Yes**; Global **Yes** citeturn21view0turn3view0 | Anthropic lists the Bedrock model ID `anthropic.claude-opus-4-6-v1` (platform mapping), but does not enumerate per-AWS-Region runtime placement. citeturn27view0 | Expected: In-Region invocation from eu-west-2 may be unavailable; Geo/Global invocations likely process outside London at least some of the time (check `inferenceRegion`). citeturn17view0turn25view1turn6view2 |

## Reproducible verification plan for region residency and routing

This section translates AWS’s documented signals into a test plan that produces **auditable evidence** for (a) where requests were sent, and (b) where inference was processed.

### Evidence model: what can and cannot be proven

Network-level artefacts (DNS answers, IP geolocation, TLS certificate CN, response headers) are useful for proving **which endpoint you connected to**, but they are **not sufficient on their own** to prove **where inference processing occurred**, because cross-Region inference is explicitly designed to accept a request in a source Region and process it in another Region. citeturn17view0turn18view1

AWS provides two first-party processing-location indicators (`inferenceRegion`) precisely because logs can remain in the source Region even when processing is remote. citeturn17view0turn18view1

### Diagram: request flow options from eu-west-2

```mermaid
flowchart LR
  A[Client / workload in eu-west-2] --> B[bedrock-runtime.eu-west-2.amazonaws.com]
  B --> C{Inference option}
  C -->|In-Region model ID| D[Model execution in eu-west-2]
  C -->|Geo inference profile ID e.g. eu.*| E[Bedrock routing within EU geo set]
  C -->|Global inference profile ID e.g. global.*| F[Bedrock routing to any commercial region]
  E --> G[Destination region (e.g., eu-central-1, eu-west-3, ...)]
  F --> H[Destination region (global set; may change over time)]
  D --> I[Response]
  G --> I
  H --> I
  B --> J[CloudTrail in source region]
  B --> K[Bedrock invocation logs in source region]
```

citeturn17view0turn18view1turn8view0turn8view1

## Test plan and expected evidence

### Test prerequisites and controllable variables

Assumptions to state up front (and document in your evidence pack):

- You have permissions to call Bedrock Runtime (`InvokeModel` / `Converse`) and to enable logging (CloudTrail trail and Bedrock Model Invocation Logging). citeturn8view0turn8view1  
- You have been granted model access for the Anthropic models in the target Region(s) (model access gating is implied in vendor guidance that availability varies by region and you must request access in Bedrock). citeturn12search8turn17view0  
- If testing PrivateLink, you can deploy into a VPC in eu-west-2 and create interface endpoints for `bedrock-runtime`. citeturn8view2  

### Step group: calls from eu-west-2 and capture endpoint artefacts

The purpose here is to generate “where the request was sent” artefacts (endpoint, DNS, IPs, TLS certificate), then pair those with log proofs of processing location.

**DNS resolution (record answers verbatim):**
```bash
# In eu-west-2 environment (e.g., EC2 in eu-west-2)
dig +nocmd bedrock-runtime.eu-west-2.amazonaws.com A +noall +answer
dig +nocmd bedrock-runtime.eu-west-2.amazonaws.com AAAA +noall +answer
```

**TLS certificate subject / SAN (record output):**
```bash
openssl s_client -connect bedrock-runtime.eu-west-2.amazonaws.com:443 \
  -servername bedrock-runtime.eu-west-2.amazonaws.com </dev/null 2>/dev/null \
  | openssl x509 -noout -subject -issuer -dates -ext subjectAltName
```

**IP “attribution” caution:** AWS publishes `ip-ranges.json` by Region but explicitly notes it does not publish ranges for all services; use this only as supporting evidence, not a sole proof. citeturn8view3

### Step group: programmatically invoke Sonnet 4.6 and Opus 4.6 from eu-west-2

#### Recommended invocation matrix

You should test at least these four combinations, because they separate endpoint selection from processing selection:

1) Sonnet 4.6 **In-Region** model ID from eu-west-2  
2) Sonnet 4.6 **EU (Geo)** inference profile from eu-west-2  
3) Opus 4.6 **In-Region** model ID from eu-west-2  
4) Opus 4.6 **EU (Geo)** inference profile from eu-west-2  
(Optionally also test Global inference profiles, but those are expected to break strict residency.) citeturn21view1turn21view0turn17view0

AWS model cards list the relevant model IDs / inference IDs:
- Sonnet 4.6: In-Region `anthropic.claude-sonnet-4-6`; Geo `eu.anthropic.claude-sonnet-4-6`; Global `global.anthropic.claude-sonnet-4-6`. citeturn21view1turn25view1  
- Opus 4.6: In-Region `anthropic.claude-opus-4-6-v1`; Geo `eu.anthropic.claude-opus-4-6-v1`; Global `global.anthropic.claude-opus-4-6-v1`. citeturn21view0  

#### AWS CLI invocation (with endpoint capture)

Use `--debug` and archive the full terminal output; CloudTrail log examples show Bedrock events include `tlsDetails.clientProvidedHostHeader`, which is useful for proving the host you called. citeturn8view0

Example pattern (adapt the body schema to your chosen API operation and model’s expected shape):

```bash
export AWS_DEFAULT_REGION=eu-west-2

# SONNET 4.6 (In-Region) - expected to be supported in eu-west-2
aws bedrock-runtime invoke-model \
  --model-id anthropic.claude-sonnet-4-6 \
  --content-type application/json \
  --accept application/json \
  --body file://sonnet46_inregion_request.json \
  --cli-binary-format raw-in-base64-out \
  --debug \
  sonnet46_inregion_response.json

# OPUS 4.6 (In-Region) - expected to be NOT supported in eu-west-2 per AWS model card
aws bedrock-runtime invoke-model \
  --model-id anthropic.claude-opus-4-6-v1 \
  --content-type application/json \
  --accept application/json \
  --body file://opus46_inregion_request.json \
  --cli-binary-format raw-in-base64-out \
  --debug \
  opus46_inregion_response.json
```

The CLI `--region`/profile Region requirement and the existence of a regional Bedrock runtime endpoint in eu-west-2 are documented by AWS. citeturn11view0turn10search26turn19view0

#### SDK pseudocode (Python / boto3)

The model cards specify the runtime endpoint format as `https://bedrock-runtime.{region}.amazonaws.com` and list the model IDs used with that endpoint. citeturn21view1turn21view0turn11view0

```python
import boto3, json, time, uuid

region = "eu-west-2"
run_id = str(uuid.uuid4())
ts = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())

client = boto3.client("bedrock-runtime", region_name=region)

def invoke(model_id: str, user_text: str):
    body = {
        "messages": [{"role": "user", "content": user_text}],
        "max_tokens": 256,
        # Add request metadata if your chosen operation/model supports it
        # so it appears in invocation logs for correlation.
        "requestMetadata": {"testRunId": run_id, "timestamp": ts, "modelId": model_id},
    }
    resp = client.invoke_model(
        modelId=model_id,
        body=json.dumps(body),
        contentType="application/json",
        accept="application/json",
    )
    return json.loads(resp["body"].read())

# In-Region Sonnet (expected London-capable)
invoke("anthropic.claude-sonnet-4-6", f"residency_probe {run_id} {ts}: hello")

# EU Geo Sonnet (may process outside London but within EU-set)
invoke("eu.anthropic.claude-sonnet-4-6", f"residency_probe {run_id} {ts}: hello")
```

(Use the exact model IDs you are testing from AWS’s model cards; the above shows the pattern.) citeturn21view1turn21view0turn15view0

### Step group: enable and collect CloudTrail, Bedrock invocation logs, and correlate

#### CloudTrail setup and the specific fields to capture

AWS states Bedrock is integrated with CloudTrail, and CloudTrail events allow you to determine who made the request, when, from what IP, and other details. citeturn8view0

In Bedrock’s CloudTrail log entry example, note these fields (archive them as evidence):
- `eventName` (e.g., `InvokeModel`, `Converse`)  
- `awsRegion` (the source Region where you called the API)  
- `requestParameters.modelId` (the model/inference profile you invoked)  
- `tlsDetails.clientProvidedHostHeader` (proves the host header, i.e., the regional endpoint) citeturn8view0  

For cross-Region inference specifically, AWS documents:
- “All cross-Region inference requests are logged in CloudTrail in your source Region.”
- Look for `additionalEventData.inferenceRegion` to identify where requests were processed. citeturn17view0turn18view1  

#### Bedrock Model Invocation Logging setup and fields to capture

AWS documents that Model Invocation Logging can collect “full request data, response data, and metadata” for calls in your account **in a Region**, and that the logging destinations must be in the same account and Region. citeturn8view1

To correlate calls, you can attach request metadata to invocations so it appears in the invocation log records, and AWS provides an explicit example schema including:
- `timestamp`, `region`, `requestId`, `operation`, `modelId`, `input`, `output`, and `requestMetadata`. citeturn15view0

For cross-Region inference, AWS’s documentation and blog explain that you can get the processed Region via `inferenceRegion` in the invocation log record. citeturn18view1turn17view0

### Step group: PrivateLink / VPC endpoints and egress comparison

AWS documents that you can create an interface endpoint (PrivateLink) for Bedrock using service names like `com.amazonaws.{region}.bedrock-runtime`, enable private DNS, and then continue to call the default regional DNS name (e.g., `bedrock-runtime.eu-west-2.amazonaws.com`) while traffic enters via the VPC endpoint ENIs rather than via the public internet/NAT. citeturn8view2

**Important interpretation:** PrivateLink is excellent for proving the *network path* stays private and within AWS’s network boundary, but it is not, by itself, a guarantee that cross-Region inference didn’t process the request elsewhere (because cross-Region inference is explicitly implemented as processing in another Region over AWS’s backbone). citeturn17view0turn18view1

### Requested table B: test checklist and expected evidence

| Check | How to run | Expected evidence if processing stayed London-only | Evidence if cross-Region processing occurred |
|---|---|---|---|
| Endpoint is eu-west-2 | SDK/CLI configured to `eu-west-2`; capture CloudTrail `tlsDetails.clientProvidedHostHeader` | Host header shows `bedrock-runtime.eu-west-2.amazonaws.com` citeturn8view0turn11view0 | Same (host header alone doesn’t rule out cross-region) citeturn17view0 |
| Model supports In-Region in eu-west-2 | Cross-check AWS model card | Sonnet 4.6: In-Region Yes in eu-west-2 citeturn21view1 | Opus 4.6: In-Region No in eu-west-2 citeturn21view0 |
| CloudTrail processing indicator | Query CloudTrail for the invocation event | `additionalEventData.inferenceRegion` absent (or equals eu-west-2 if present by implementation) citeturn18view1turn17view0 | `additionalEventData.inferenceRegion` present and ≠ eu-west-2 citeturn17view0turn18view1 |
| Invocation log processing indicator | Enable Model Invocation Logging; search by `requestMetadata.testRunId` | `inferenceRegion` absent or equals eu-west-2 (depending on log behaviour) citeturn18view1turn15view0 | `inferenceRegion` present and ≠ eu-west-2 citeturn18view1turn17view0 |
| PrivateLink path control | Create `com.amazonaws.eu-west-2.bedrock-runtime` endpoint with private DNS | Confirms traffic uses VPC endpoint ENIs for Bedrock runtime citeturn8view2 | Still possible to see cross-region processing; must rely on `inferenceRegion` fields citeturn17view0turn18view1 |

## Compliance interpretation and recommended mitigations

### Residency interpretation for UK- or London-specific requirements

If your policy is **London-only** (or **UK-only**) processing, AWS documentation implies:

- You should choose **In-Region** inference (single Region) for strict compliance, and only select models that have **In-Region = Yes** in `eu-west-2`. citeturn1view1turn21view1  
- You should avoid geographic/global inference profiles (`eu.*`, `global.*`) for regulated workloads where processing must not leave `eu-west-2`, because geographic cross-Region inference explicitly selects “the optimal Region within that geography” to process, and inference profiles list multiple destination Regions. citeturn17view0turn25view1turn6view3  

For **EU/EEA-style geographic boundary** requirements (not necessarily UK-only), geographic cross-Region inference is explicitly described as the option “for compliance requirements” where data residency must remain within geographic boundaries (US, EU, APAC, etc.). citeturn17view0turn27view0

### Organisational controls to reduce accidental cross-Region processing

Controls that follow directly from AWS’s documented behaviour:

- **Policy gating by inference option**: explicitly allow In-Region model IDs for production workloads that require London-only processing, and require a change-control process to permit `eu.*` or `global.*` inference profile IDs. (This aligns with AWS’s explicit separation of inference options in model cards.) citeturn21view1turn21view0  
- **SCP/IAM constraints for cross-Region inference**: AWS documents SCP requirements for global inference profiles (including `"aws:RequestedRegion": "unspecified"`). Use this to prevent accidental global routing in restricted environments. citeturn17view0turn4view2  
- **Continuous monitoring of `inferenceRegion`**: Build alerts that fire if `additionalEventData.inferenceRegion` (CloudTrail) or `inferenceRegion` (invocation logs) differs from `eu-west-2` for workloads flagged as “London-only.” AWS explicitly recommends using these indicators to differentiate source vs processed Region. citeturn18view1turn17view0  

### Data handling and logging hygiene

AWS states Bedrock does not store or log prompts and completions and does not use them to train AWS models; it also describes an architecture where model providers do not have access to the deployment accounts or to customer prompts/completions. citeturn9view0

However, if you enable Model Invocation Logging, AWS documents that you can log full request/response content and metadata to CloudWatch Logs and/or S3 in the same account/Region. Treat that log store as a sensitive dataset subject to your retention, access control, and encryption policies. citeturn8view1turn15view0

## Assumptions, gaps, and how to close them with your own evidence pack

Assumptions made here (explicitly requested):

- Account permissions and model access grants are in place for Anthropic models in `eu-west-2`. citeturn12search8  
- Your VPC configuration may or may not include PrivateLink; tests are designed for both modes. citeturn8view2  
- You can generate and retain audit artefacts (CloudTrail logs, invocation logs) in `eu-west-2`. citeturn8view0turn8view1  

Gaps you should close with the proposed tests:

- Whether **Opus 4.6 In-Region invocation from `eu-west-2`** is truly unavailable in your account, given the apparent documentation inconsistency between “supported models” tables and model-card In-Region markings. The correct way to resolve this is to run the invocation and verify the **presence/absence** of cross-Region indicators (`inferenceRegion`) and/or any `ValidationException`/availability responses. citeturn21view0turn22view0turn17view0
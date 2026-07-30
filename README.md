# Ledgerline — Trading Journal + Desk Chat

Full-stack reference implementation: Terraform backend (Cognito, DynamoDB, S3,
HTTP API, WebSocket API, Lambda) + a single-file dark-mode frontend.

```
trading-journal/
├── main.tf                       # resources: Cognito, DynamoDB, S3, IAM, Lambda, HTTP + WebSocket APIs
├── variables.tf                  # input variable declarations
├── outputs.tf                    # output declarations
├── terraform.tfvars.example      # copy to terraform.tfvars and fill in your values
├── .gitignore                    # keeps real tfvars/state/build output out of git
├── src/
│   ├── package.json              # lambda dependencies
│   ├── journal-handler.mjs       # REST: POST/GET /journal
│   └── chat-handler.mjs          # WebSocket: $connect/$disconnect/sendMessage/getChatHistory
└── index.html                    # frontend SPA
```

## 1. Prerequisites

- Terraform ≥ 1.5
- AWS CLI configured with credentials that can create IAM roles, Cognito,
  DynamoDB, S3, Lambda, and API Gateway resources
- Node.js ≥ 18 and npm on the machine running `terraform apply` (Terraform
  shells out to `npm install` to build the Lambda deployment packages)
- A Google Gemini API key ([aistudio.google.com](https://aistudio.google.com))
- Your AWS account **must have Bedrock model access enabled** for the fallback
  model in `us-west-1` (Bedrock → Model access, in the console) before the
  fallback path will work

> **A note on model IDs.** `gemini-3.6-flash` and
> `meta.llama3-2-11b-instruct-v1:0` are the model IDs specified in the
> brief. Model names and availability change frequently — before deploying,
> confirm the current model IDs in the Google AI Studio docs and the AWS
> Bedrock console for `us-west-1`, and update `gemini_model_id` /
> `bedrock_fallback_model_id` in `terraform.tfvars` if they've changed.

## 2. Configure variables

Copy the template and fill in your real values:

```bash
cp terraform.tfvars.example terraform.tfvars
```

Then edit `terraform.tfvars`:

```hcl
gemini_api_key   = "AIza..."
allowed_origins  = ["https://your-frontend-domain.com"]  # or ["*"] for local testing
```

`terraform.tfvars` is git-ignored (see `.gitignore`) since it holds your
Gemini API key — never commit it. All other variables (region, project name,
model IDs, etc.) have sensible defaults in `variables.tf` and only need
overriding in `terraform.tfvars` if you want something different.

## 3. Deploy the backend

```bash
cd trading-journal
terraform init
terraform apply
```

This provisions everything end-to-end — no manual console steps. Terraform
will run `npm install` inside `src/` automatically before zipping the Lambda
packages.

When it finishes, note the outputs:

```bash
terraform output
```

You'll get:
- `cognito_user_pool_id`
- `cognito_user_pool_client_id`
- `http_api_url`
- `websocket_api_url`
- `s3_bucket_name`

## 4. Wire up the frontend

Open `index.html` and edit the `CONFIG` object near the top of the
`<script>` tag:

```js
const CONFIG = {
  AWS_REGION:            "us-west-1",
  COGNITO_USER_POOL_ID:  "<cognito_user_pool_id output>",
  COGNITO_CLIENT_ID:     "<cognito_user_pool_client_id output>",
  HTTP_API_URL:          "<http_api_url output>",
  WEBSOCKET_API_URL:     "<websocket_api_url output>",
};
```

Then host `index.html` anywhere static (S3 + CloudFront, Vercel, Netlify, or
just open the file locally for testing with `allowed_origins = ["*"]`).
For production, set `allowed_origins` in `terraform.tfvars` to your actual
frontend origin and re-run `terraform apply` — this locks down both the S3
CORS policy and the HTTP API CORS policy.

## 5. Using the app

1. Sign up with an email + password. Cognito emails a 6-digit confirmation
   code — enter it on the "Verify email" screen.
2. Sign in. The journal history loads automatically and the WebSocket chat
   connects using your Cognito access token as a query-string auth token.
3. Log a trade: instrument is restricted to ES / NQ / MES / MNQ (your last
   choice is remembered via `localStorage`), attach a chart screenshot by
   drag-and-drop or click, add rationale, and hit **Save & Analyze**. The
   journal Lambda uploads the screenshot to S3, sends it + your notes to
   Gemini for multimodal analysis, and falls back to Bedrock automatically
   if Gemini errors or rate-limits.
4. Chat with other logged-in members in the right sidebar in real time.

## 6. Notes on the fallback logic

`journal-handler.mjs`'s `runAiAnalysis()`:
1. Tries Gemini (`GEMINI_MODEL_ID`) with text + image parts.
2. On **any** exception (rate limit, network error, malformed response),
   catches it and retries with Bedrock (`BEDROCK_MODEL_ID`).
3. If both fail, the trade is still saved with a placeholder analysis so a
   flaky AI provider never blocks journaling.

## 7. Teardown

```bash
terraform destroy
```

S3 bucket contents (chart screenshots) must be emptied manually or via
`aws s3 rm s3://<bucket-name> --recursive` before destroy if versioning/lock
policies block an automatic empty — this template does not enable bucket
versioning, so a plain `terraform destroy` will normally succeed once the
bucket is empty.

## 8. Known limitations / production hardening ideas

- The WebSocket `$connect` route validates the caller by calling Cognito
  `GetUser` with the access token on every connect — fine at moderate scale,
  but consider verifying the JWT locally against Cognito's JWKS for lower
  latency at high connection volume.
- `ChatConnections` broadcast uses a full `Scan` — acceptable for a single
  small community room; shard or index by `RoomId` if you add multiple
  rooms or scale past a few hundred concurrent users.
- The HTTP API's CORS and the S3 bucket CORS both default to `["*"]` — lock
  `allowed_origins` down before going to production.
- No rate limiting is applied to `/journal` — consider API Gateway usage
  plans / throttling if this is public-facing.

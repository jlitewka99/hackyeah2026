# Human approval (policy v6)

REVIEW is an explicit policy gate for REST/MCP tools, Chat Completions (including buffered SSE), and workflow delegation. Approval authorizes **one client resume**. An administrator's decision never executes an operation, starts an LLM, or creates a delegated participant.

## Rollout and compatibility

Run the `20261004062837_create_human_approvals` migration before starting the new release. It adds encrypted approval records and extends existing audit, tool receipt and workflow operation constraints. There are no dependency changes. Stored v1–v5 sources, checksums and behavior remain unchanged. New v6 versions preserve workflow, Knowledge/memory, NER, signature and model settings. Activation of a saved v6 policy is required to enable review; merely upgrading or saving a version does not enable it.

Rollback to the pre-REVIEW database constraints requires planned treatment of existing REVIEW audit evidence, waiting receipts and active v6 policies. The down migration intentionally cannot silently discard incompatible evidence. Prefer a forward fix that preserves it.

```yaml
schema_version: 6
review:
  enabled: true
  tools: [file.write, email.send]
  llm_models: [qwen3.5:4b]
  delegation_agents: ["*"]
```

The defaults are `enabled: false` and three empty selectors. Tools use exact catalog names. Models use exact names or `["*"]`; delegation uses agent UUIDs or `["*"]`. Selectors never grant underlying operation/resource access. Existing guard actions cannot be changed to review, and approval cannot override BLOCK. Required redaction completes before review.

Configure `APPROVAL_ENCRYPTION_KEY` with **32 independently generated random bytes encoded as base64**, and `APPROVAL_ENCRYPTION_KEY_ID` with its rotation identifier (default `v1`). Keep this key separate from `AUDIT_FINGERPRINT_KEY` and `SECRET_KEY_BASE`. Use the operator's secret store. Missing/invalid encryption configuration fails review closed; policies without review continue to work. An invalid encoded key prevents startup.

Preview encryption uses AES-256-GCM, a fresh 12-byte nonce and authenticated binding to both the record UUID and organization UUID. Copying ciphertext to another record cannot decrypt it. Deployment has one active key/ID; it is not a multi-key keyring. Before rotation, let pending approvals end or explicitly reject them. Changing the key makes old previews unavailable and requires a new operation. Do not silently reinterpret old approvals under a new key.

## Client contract

Continue using the existing `/v1/tool_calls`, `/mcp`, `/v1/chat/completions` and `/v1/runs/:id/delegations` endpoints. Tool and delegation requests retain their UUID `Idempotency-Key`. Chat requires that header only when review applies or when resuming with `X-Approval-ID`. Duplicate or malformed approval headers are rejected. Retain the same body, owning API key, operation key and workflow/participant headers for resume.

REST waiting response, including SSE **before any stream headers or chunks**, is JSON with status 409:

```json
{
  "error": {
    "code": "approval_required",
    "message": "Human approval is required before this operation can run.",
    "request_id": "<HTTP attempt UUID>",
    "approval_id": "<approval UUID>",
    "approval_status": "pending",
    "expires_at": "<UTC deadline>",
    "revision": 1,
    "kind": "tool",
    "operation_request_id": "<logical operation UUID>",
    "run_id": "<workflow UUID>",
    "participant_id": "<participant UUID>"
  }
}
```

Retrying the waiting request returns its existing approval; it does not create another logical workflow operation. `GET /v1/approvals/:id` returns this content-free approval metadata without the error wrapper. It is available only to the original owning API key. A different organization, key or guessed UUID gets 403. Polling never exposes the payload.

After `approval_status: approved`, send the original request with `X-Approval-ID: <approval UUID>`. Approval without this header continues to return the waiting response. MCP uses the same header and must retain both its session and JSON-RPC ID; the session/ID determines its existing operation key. REVIEW metadata appears in the existing tool-error `_meta` or JSON-RPC error data envelope. Do not generate a fresh RPC ID for resume.

| Outcome | REST status |
| --- | --- |
| Waiting or approved without resume header | 409 `approval_required` |
| Human rejection | 403 `approval_rejected` |
| Expired, claimed/consumed, or changed binding | 409 `approval_expired`, `approval_used`, or `approval_conflict` |
| Current access/policy denies the operation | Existing 403 policy/access error |
| Request/token/workflow budget denies the operation | Existing 429 budget error, including Retry-After where applicable |
| Approval registry, key or required audit unavailable | 503 |

A failed/terminal operation needs a **new operation key** and a new review. Never automatically retry an effect after an uncertain dispatch.

## State and dispatch semantics

`pending → approved → claimed → consumed` is the successful path; `rejected`, `expired`, `invalidated` and `uncertain` cannot authorize a resume. Transitions lock the organization and record, verify the expected state/revision or claim nonce, and persist a content-free audit in the same transaction.

Pending approval lasts at most 15 minutes from creation. Approval lasts at most 15 minutes **from the human decision**. Both intervals are capped by the workflow deadline; waiting does not pause its clock. Equality with the deadline is expired. Workflow stop, completion, deadline and restart invalidate unused approvals; a recovered claim is uncertain. Recovery never executes effects.

Fingerprints bind canonical client input and run/participant context, and separately the prepared payload. LLM binding includes generation options/default output limit, effective Ollama reasoning effort, streaming/usage options, pinned model digest and Knowledge source revisions. The encrypted LLM preview is the normalized prepared Chat Completions payload. Any changed arguments, redaction outcome, RAG revision or effective generation parameter invalidates the approval.

Resume atomically claims one authorization, then runs current identity/approver permissions, guards, resource access, policy, deadline and budget checks. Approval consumption, dispatch accounting and required dispatch audit commit together before the effect. Parallel resumes cannot both dispatch. Failure after a claim burns it; it is never returned to approved. A policy change can still allow resume if the prepared payload stays identical and all current checks pass.

Waiting releases token reservations and retains no execution slot or worker. Each HTTP attempt still pays ingress rate limits and hourly request budget; the same logical workflow operation is admitted/counts once, and dispatch is charged once. Tool receipts and workflow operations use `awaiting_review`, which ordinary recovery/cleanup excludes. When an unused approval ends, its waiting receipts close without charging or executing.

`consumed` means authorization reached dispatch, not that the effect succeeded. A network/process failure after dispatch can leave the effect or delivery uncertain. Inspect Events, the execution receipt and workflow evidence before deciding on a new operation; exactly-once effects across external systems are not promised.

## Administrator access and retention

The organization panel uses `/organizations/:id/approvals` and `/organizations/:id/approvals/:approval_id`. `approvals.read` allows metadata and authorized preview. Decisions require `approvals.manage` and organizer, superadmin, or admin role with an explicit manage grant. An ordinary user cannot approve even if assigned that permission. Agent/model selectors and current Knowledge source ACLs apply to read and decision, and the approving administrator's access is checked again at resume.

The payload is escaped text in the detail view. It never enters audit rows, exported Events, logs, PubSub messages, list streams or the approval record's Inspect representation. Preview data is transient in authorized LiveView memory/browser DOM; access/expiry refresh clears it. Avoid capturing real previews in support screenshots, browser extensions or administrator screen recordings.

Ciphertext is nulled on consumption, rejection, invalidation, expiry or uncertainty. A once-per-minute Oban maintenance job and opportunistic reads/resumes reconcile expiry; delayed/unavailable maintenance can delay physical erasure but cannot extend authorization validity. Metadata/fingerprints remain as durable evidence. Database WAL, replicas, snapshots and backups can retain earlier ciphertext after the row is cleared. Their retention, encryption and key deletion are operator responsibilities; erasing a live column does not erase backups.

Detection retains the documented limits of PII/NER/signatures and semantic models. Human review is not a guarantee that all sensitive or malicious content has been detected. It does not replace resource authorization, output controls or the outstanding model quality acceptance in Step 11.

## Release acceptance

With an independently configured encryption key and a bootstrapped organizer, run the trusted synthetic sandbox smoke on the running release:

```sh
AI_CONTROL_ORGANIZER_EMAIL=ci@example.test bin/ai_control rpc \
  'Code.eval_file("/app/scripts/approval_release_smoke.exs")'
```

`docker/smoke` runs this against its isolated database/container. It verifies authenticated ciphertext, record binding, no effect before review/resume, one dispatch and preview erasure. It neither contacts external tool resources nor persists production payloads. Local acceptance results are recorded in [Step 19 acceptance](acceptance/step19.md).

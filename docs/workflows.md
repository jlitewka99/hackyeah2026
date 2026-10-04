# Client-driven workflows

Policy schema v5 requires a verified run and participant for every Chat Completions or tool operation, including calls through the Gateway and Tools domain APIs. Schema v1–v4 behavior and historical policy checksums remain unchanged. Upgrade a draft in Policies, review its changes, save, then activate it deliberately. The upgrade preserves explicit existing tool limits.

The gateway controls execution; the client chooses and sequences actions. This feature does not add MCP, Granite, Oban, automatic orchestration, distributed execution or crash resumption. After integrating current main, existing buffered SSE and MCP content operations use the same workflow protection.

## Policy contract

All `budgets.workflow` limits are finite integers. Defaults are independent of the protection profile.

| Field | Default | Meaning |
| --- | ---: | --- |
| `max_duration_seconds` | 300 | Root lifetime from creation; allowed range 1–86400 |
| `max_calls` | 50 | Accepted LLM, tool and delegation operations |
| `max_tokens` | 10000 | Target LLM input and generated output, plus pending/uncertain reservations |
| `tool_calls` | 25 | Started tool dispatches; existing durable tool counter |
| `max_delegation_depth` | 3 | Root depth is zero; allowed range 0–32 |
| `max_repeated_actions` | 3 | Fourth identical accepted action attempt terminates the root |

Zero denies operations/reservations/delegation for the corresponding limit. Run caps cannot increase after creation. Subsequent v5 policy tightening applies to further operations; the deadline is always derived from the original start. Organization and actual executing agent hourly request/token limits still apply. Changing the UTC hour never replenishes a root's budget.

Operations admitted before guard evaluation count even if later denied. Tool dispatches count only when their dispatch marker is committed. Idempotent repeats do not add operations or dispatches. The HMAC covers canonical action material across all participants: map order, JSON tool argument order, transport tool-call IDs and streaming delivery options do not distinguish otherwise identical actions. Changing meaningful action content is bounded by lifetime, operation and token limits.

## Public API

Use `Authorization: Bearer <agent-key>`. The server derives organization and agent identity from this key. Request bodies and errors never echo credentials or arbitrary workflow data. Responses use `Cache-Control: no-store`.

| Endpoint | Body / headers | Result |
| --- | --- | --- |
| `POST /v1/runs` | Exact body `{"goal":"Synthetic report review"}`; UUID `Idempotency-Key` | `201`, root `run_id`, `participant_id`, state and usage |
| `GET /v1/runs` | Optional `status`, `agent_id`, `cursor` query parameters | Owner's runs, up to 50; `data` and `next_cursor` |
| `GET /v1/runs/:id` | Own agent key | State, shared usage and visible participants; delegated agents see their own participation |
| `POST /v1/runs/:id/delegations` | Exact body `{"target_agent_id":"<uuid>"}`; parent UUID in `x-run-participant-id`; UUID `Idempotency-Key` | `200`, new `participant_id`, `run_id`, server-computed depth |
| `POST /v1/runs/:id/complete` | Empty JSON object; owner's key | `200`; refuses completion while admitted/dispatching operations remain |
| `POST /v1/runs/:id/stop` | Empty JSON object; owner's key | `200`, terminal root state |

Goals are trimmed, valid UTF-8 and 1–240 Unicode code points. Only the run record/panel retain the goal; audit, serializers and ordinary struct inspection omit it. Run mutation bodies are capped at 4096 bytes before JSON decoding. Existing IP/principal limiters also cover these endpoints.

Creation idempotency is scoped to organization and owner agent. Delegation idempotency is scoped to run and parent participant. The same UUID with changed action data returns `409`; a new UUID represents a new action. Retrieving an existing creation never restarts a lost process. Completing an already completed run and stopping a terminal run are safe retries. A terminal run cannot continue.

For Chat Completions and tool calls, add both headers to the existing body schema:

```http
POST /v1/chat/completions
Authorization: Bearer <executing-agent-key>
Content-Type: application/json
x-run-id: <run-uuid>
x-run-participant-id: <participant-uuid>

{"model":"qwen3.5:4b","messages":[{"role":"user","content":"Synthetic review request"}],"max_tokens":128}
```

```http
POST /v1/tool_calls
Authorization: Bearer <executing-agent-key>
Content-Type: application/json
Idempotency-Key: <new-uuid>
x-run-id: <run-uuid>
x-run-participant-id: <participant-uuid>

{"tool":"file.read","arguments":{"path":"report.txt"}}
```

Delegated agents use their own keys, allowed models and sandbox resource grants. A parent cannot execute as its child. The target must be active, policy-allowed and in the same organization; delegation grants no resource or model permissions. Participant ancestry and identity are rechecked before dispatch, along with state, deadline and current tightened limits.

The same run headers apply to `stream: true` Chat Completions. The supervised SSE session remains an active operation until delivery/cleanup finishes; it owns usage checkpoints and receives workflow cancellation without being killed during settlement. Before streaming headers, errors use HTTP status codes. After SSE starts, terminal errors use the existing content-free `event: error` frame and suppress further response release. Stop/deadline/runtime loss preserve settled or uncertain usage.

Existing `/mcp` `tools/call` and `resources/read` forward these headers to the Tools domain. Discovery and initialization need no run. Missing v5 context returns the existing MCP error envelope, and retries retain MCP's session/request-id idempotency. Delegates still require their own keys/sessions; an MCP session cannot grant participant access.

| Status | Fixed error meaning |
| --- | --- |
| `400` | Invalid body/header context, missing required workflow context or invalid UUID key |
| `403` | Identity, organization, participant, model, tool or owner access denied |
| `409` | Changed idempotent data, terminal run or completion with operations in progress |
| `429` | Shared root limit exceeded (terminal), hourly budget or ingress capacity exceeded |
| `503` | Workflow, policy, fingerprint, accounting or required audit state unavailable |

Existing endpoint errors such as `413` for oversized bodies and downstream timeout/adapter errors retain their contracts. Fixed response messages never include prompts, arguments, results or goals.

## Persistence, recovery and accounting

Migration `20261004012533_create_workflow_runs.exs` adds `workflow_runs`, `workflow_participants`, `workflow_operations`, and nullable run/participant references on reservations, tool executions and audit events. It leaves historical receipts and policies intact. Apply migrations before starting the new release. Rollback removes workflow records and references; do not roll back after accepting runs if their evidence must be retained.

A named Registry and DynamicSupervisor own one temporary process per `{organization_id, run_id}`. Deadline timers and local worker/owner monitors complement durable dispatch checks. Losing a process or restarting the application marks surviving running roots `interrupted` and blocks continuation without replaying downstream effects. Startup recovery is scoped to one application instance per database; a cluster requires a separate lease design.

Transactions lock the organization first, then coordinate the root, existing hourly buckets and receipts. Workflows force tokenization and reservation even with no hourly token cap. Actual target-model usage settles before output filtering, including blocked responses. Cancellation before dispatch releases unsent reservations; an execution with a persisted dispatch marker retains an uncertain reservation until audited reconciliation. Guard model usage remains separate. Tool accounting reuses the existing workflow counter rather than creating another counter.

Stop blocks subsequent dispatches in all branches. It does not undo an already dispatched effect. Local cancellation is limited by existing adapters; uncertain charges remain durable. Completion may retain uncertain accounting because the effect is no longer locally in progress.

## Panel and evidence

`/organizations/:id/runs` and its detail route use `workflows.read`; stopping requires `workflows.manage` and assignment to the owner agent. Organizers and superadmins receive full access; other members need explicit grants. Event history additionally requires `events.read`, and JSONL export requires `events.export`. Unassigned participants and parents do not expose names or identifiers in detail or workflow audit evidence/export.

The panel provides status/owner filters, cursor pagination, goals, shared usage, reserved tokens, remaining time, participant ancestry and terminal reasons. Inline stop confirmation names its effect; focus enters the confirmation, returns on cancellation and moves to terminal status after a committed stop. Content-free PubSub updates are organization-scoped. Lifecycle changes are audited synchronously; LLM/tool evidence carries verified run and participant references. Telemetry uses only finite state/reason labels.

[Step 15 acceptance](acceptance/step15.md) records checks and remaining qualification. Existing Step 11 model-quality limitations remain applicable.

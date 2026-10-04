# Tool firewall and sandbox (steps 12A–12B)

`AiControl.Tools.prepare/2` binds a tool request to a verified API-key
`AiControl.ApiKeys.Principal` and one immutable policy snapshot. The only accepted
request fields are `tool` and `arguments`; identity, policy, and schemas cannot be
supplied in the body. Requests are limited to 64 KiB of encoded JSON; both the
schema and this total size bound are rechecked immediately before execution,
including after changes to prepared arguments.
`ToolRequest` inspection excludes arguments, API-key IDs, and policy content.

Policy v2/v3 `allowed_agents` and `tools.allowed_tools` lists authorize
operations. Missing tool permissions, policy v1, unknown tools, and unknown
argument fields deny access. No wildcard enables tools. A separate, immutable
operator grant for that sandbox and agent restricts exact resources; a policy
permission alone never enables a resource. This keeps the existing v1/v2/v3 schemas and historical checksums unchanged.

| Operation | Required arguments | Operator resource grant | Adapter |
| --- | --- | --- | --- |
| `file.read` | `path` | `paths` | Read a virtual file |
| `file.write` | `path`, `content` | `paths` | Create/replace a virtual file |
| `file.delete` | `path` | `paths` | Delete a virtual file |
| `http.get` | `url` | `endpoints` | Bounded GET with Req |
| `database.select` | `table`, `limit` (1–100) | `tables` | Select virtual rows |
| `email.send` | `recipient`, `subject`, `body` | `recipients` | Queue locally |
| `command.run` | `command`, `arguments` | `commands` | `status` or literal `echo` |

`AiControl.Tools.Catalog.all/0` exposes the JSON argument schemas. All properties
are required and additional properties are forbidden. String limits count Unicode
code points. `status` accepts no arguments; `echo` accepts one string and never
passes it to a shell. Database operations accept no SQL and cannot mutate data.
Email accepts one exact address and rejects recipient or subject header injection.

## Local demo

First create and activate a **new** policy v2 version through the existing policy
editor/YAML workflow, permitting e.g. `tools: {allowed_tools: [file.read]}` and the
agent. Obtain `principal` with `ApiKeys.authenticate/1`, using an active key for
that agent. From trusted local code:

```elixir
{:ok, sandbox} = AiControl.Tools.Sandbox.start_link(
  organization_id: principal.organization_id,
  grants: %{principal.agent_id => %{paths: ["documents/report.txt"]}},
  files: %{"documents/report.txt" => "Synthetic report"}
)

AiControl.Tools.Sandbox.run(sandbox, principal, %{
  "tool" => "file.read",
  "arguments" => %{"path" => "documents/report.txt"}
})
# {:ok, %{"content" => "Synthetic report"}}
```

Start each sandbox under a supervisor for a managed demo. Tests use
`start_supervised!/1`. The sandbox is bound to one organization; agents without
operator resource grants are denied. It revalidates the key, agent, organization,
policy integrity, and arguments immediately before invoking an adapter. A prepared
request retains its snapshot across policy activation, while revocation,
expiration, or suspension still stops execution.

Files, tables, mailbox messages, and commands are in-memory demo resources.
Paths must be relative and canonical: traversal, absolute/home paths, encoded
paths, backslashes, and symlink nodes on any ancestor or leaf are rejected.
Operator fixture symlinks are represented by `{:symlink, target}`. No adapter
reads or mutates the host filesystem, executes a shell, queries the application
database, or sends SMTP. State is temporary and cleared on process restart.
`Sandbox.inspect_state/1` is a trusted local demo aid containing synthetic data;
it must not be exposed through a public API.

## HTTP resources

For `http.get`, the agent's operator grant has this shape:

```elixir
%{
  endpoints: %{
    "http://demo.invalid:8080/report" => %{
      ip: {127, 0, 0, 1},
      allow_private?: true
    }
  }
}
```

The entire URL must match the entry, including scheme, host, port, and path.
Queries, fragments, credentials, ambiguous authorities, encoded paths, and zone
identifiers are rejected. A literal URL IP must match the pinned IP. The operator
chooses the destination IP; the request never resolves the supplied hostname.
Req connects to that IP while preserving the original Host and TLS hostname.
The raw Req request bypasses global `Req.default_options` and middleware, so
ambient credentials, headers, query parameters, or plug adapters cannot alter the
validated request. Redirects, retries, automatic decompression, and proxy
configuration are disabled. HTTPS verifies the certificate chain against the
system trust store and the certificate hostname against the original URL host.
HTTP bodies are bounded at 64 KiB while receiving, must be valid UTF-8, and only
2xx bodies are returned. Other bodies/exceptions never enter the error result.
Connect, receive, pool, and request timeouts bound network work.

The conservative address classifier is based on the
[IANA IPv4 special-purpose registry](https://www.iana.org/assignments/iana-ipv4-special-registry/)
and [IANA IPv6 special-purpose registry](https://www.iana.org/assignments/iana-ipv6-special-registry/),
checked on 2026-10-04. It denies private, loopback, link-local, shared, documentation,
benchmark, multicast/reserved, and transition ranges. IPv6 requires the global
unicast block; IPv4-mapped IPv6 follows the IPv4 exclusions. Some special-purpose
anycast exceptions are conservatively denied. This is a local firewall policy,
not a guarantee of routability. A private demo service requires
`allow_private?: true` on its **exact** endpoint; callers cannot set this flag.

## Public execution API

`POST /v1/tool_calls` requires an active agent Bearer key, `Content-Type:
application/json` and exactly one UUID `Idempotency-Key` header. Only the JSON
object `{tool, arguments}` is accepted. IP admission, authentication and the
organization/agent limiter run before reading or parsing the body. The raw body
and the encoded result are each limited to 64 KiB. Responses use `Cache-Control:
no-store`; errors have fixed messages and never include adapter errors or content.

```sh
curl -X POST http://localhost:4000/v1/tool_calls \
  -H "Authorization: Bearer $AGENT_API_KEY" \
  -H 'Content-Type: application/json' \
  -H 'Idempotency-Key: 11111111-1111-4111-8111-111111111111' \
  --data '{"tool":"file.read","arguments":{"path":"documents/report.txt"}}'
```

Successful responses are `200` with `request_id`, `execution_id`, `tool` and the
filtered `result`. Errors are `400/413` for validation, `401` for authentication,
`403` for policy/resource denial, `409` for a used execution key, `429` for
admission/call budgets, `502/504` for adapter failure/timeout, and `503` when a
required guard, accounting or audit is unavailable. A call-budget denial does not
suggest an hourly retry time: the context count has no time reset.

The domain entry point is `AiControl.Tools.execute(principal, params,
idempotency_key: uuid)`. Identity, sandbox configuration, context and content
adapter are server-owned. `prepare/2` and `authorize/1` remain compatible;
`Sandbox.run/3` is a trusted local aid and bypasses the public orchestration.
Never expose that aid or sandbox state to API clients.

The order is identity → immutable snapshot → operation/resource ACL → durable
claim → deterministic, NER, semantic input phases → argument/schema/ACL
revalidation → atomic budget + dispatch audit → adapter → bounded JSON/result
contract → output phases → terminal audit → response. The same snapshot applies
throughout. Live key/agent/organization and operator resources are rechecked before
effects; ACL and contracts are rechecked after each guard phase. Selectors, the
operation name and JSON keys are scanned but immutable; only content strings can
be redacted. Every nested result field is projected with UTF-8 byte offsets.
Moderation receives the accepted, redacted input as its prompt context.

Guard stages remain a policy decision. The [demo policy](tools-demo-policy.yaml)
enables semantic input **and output**, plus response moderation. Required guards
must be configured and healthy; permission alone does not bypass them. Dashboard,
Events and workflow orchestration remain separate work in Steps 11 and 15.

## Operator configuration and migration

Apply `mix ecto.migrate` before serving tool traffic. Migration
`20261003233603_create_tool_executions` adds the content-free receipt table,
organization/agent foreign keys, unique organization/agent/idempotency index and
state/charge constraints. Existing policy records and checksums are untouched.

Set `TOOLS_SANDBOXES` to a JSON object keyed by organization UUID. For example,
substitute actual organization and agent IDs in this synthetic configuration:

```json
{
  "<organization UUID>": {
    "contexts": {"<agent UUID>": "22222222-2222-4222-8222-222222222222"},
    "grants": {
      "<agent UUID>": {
        "paths": ["documents/report.txt"],
        "tables": ["reports"],
        "recipients": ["demo@example.com"],
        "commands": ["status", "echo"],
        "endpoints": {
          "http://demo.invalid:8080/report": {"ip": "127.0.0.1", "allow_private": true}
        }
      }
    },
    "files": {"documents/report.txt": "Synthetic report"},
    "tables": {"reports": [{"label": "Synthetic row", "count": 1}]}
  }
}
```

Contexts must be stable UUIDs assigned by the operator per agent and organization.
Keep them unchanged across restarts and policy activation; changing the operator
configuration to a new context explicitly creates a new budget scope. Clients
cannot supply contexts. Missing assignments deny execution. In Elixir releases,
configure `AiControl.Tools.Config` with `sandboxes: map` and optionally
`execution_timeout: milliseconds` (1–10000; default 10000). The named tool
supervisor starts its Registry, recovery and tenant sandboxes before the endpoint.
`AiControl.Gateway.Config` owns `tool_slots` (default one per application node).
The lease has no automatic retry; deadline and owner cancellation are checked
before dispatch and again before invoking the effect. HTTP has its shorter 12A
transport deadlines. Configuration is startup-owned; no API mutates grants.

`budgets.workflow.tool_calls` counts started dispatches in the assigned context.
`null` means no configured call limit; zero denies new dispatches. Lowering the
limit preserves usage. Activation, key replacement and restart never reset the
counter. Input denials and failed dispatch audit writes roll back the count.
Adapter errors, blocked output and uncertain completion retain it. Organization,
workflow and execution locks keep accounting and dispatch atomic.

## Durability, audit and limits

`tool_executions` stores only generated IDs, verified identity, operator context,
UUID key, HMAC of the canonical original request, HMAC key ID, immutable policy
settings/checksum, state, charge and timestamps. It stores no arguments or results.
All API keys for one agent share the idempotency namespace, even when the operator
context changes. A repeated key returns `409 tool_execution_exists` with
`execution_id` and `execution_status`; changed arguments return
`409 idempotency_conflict`. Neither starts the adapter nor returns a saved result.
Keep the audit HMAC key stable; rotating it can classify an old key as a request
conflict, while still preventing redispatch.

States are `pending`, `dispatching`, `completed`, `rejected`, `output_blocked`,
`failed` and `uncertain`. Recovery closes abandoned pending receipts uncharged and
marks dispatching receipts uncertain, retaining their charges. No effects replay.
Recovery and dispatch require synchronous validated `tool.*` audit writes. A
failed terminal audit withholds the result and leaves a dispatching receipt for
recovery. Guard evidence shares the request correlation; execution audit carries
the execution/context IDs, tool, state and charge. No content is logged.
Telemetry exposes `[:ai_control, :tools, :execution]` counts/duration by status and
existing gateway stage duration events for input, output, guards and tool execution.
It does not use content, API keys or per-execution UUIDs as metric labels.

There is **no exactly-once guarantee for external effects**: a crash after dispatch
may occur before or after the external action. Use a new key only after resolving
an uncertain outcome. Results cannot be replayed. Virtual files, tables and mailbox
state reset to configured synthetic fixtures on sandbox restart. Blocking output
or failing terminal audit cannot undo an already started effect. Host files, SQL,
shell, SMTP and full workflow orchestration are outside this demo. Qwen detection
quality and long-input deadlines retain the measured Step 10 limitations; final
provider qualification remains in 11B.

Run one application instance for this demo. Recovery owns all unfinished receipts
at startup; multi-node recovery ownership and distributed admission are not yet
implemented.

## Verification

```sh
MIX_TEST_PARTITION=step12b mix precommit
MIX_ENV=test mix assets.build
mix dialyzer
mix security
mix test test/ai_control/tools/live_models_test.exs --include live_models
```

Ordinary tests need PostgreSQL and synthetic local HTTP/HTTPS, without external
services or model downloads. The opt-in model tests require the pinned NER and Qwen
sidecars on the configured localhost URLs. They compare the same projected input
without retuning quality thresholds. See [Step 12B acceptance](acceptance/step12b.md)
for the actual checks, UI evidence and remaining limits.

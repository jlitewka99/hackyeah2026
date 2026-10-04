# MCP gateway (Step 13)

`/mcp` exposes the existing governed sandbox using MCP **2025-11-25** and
Streamable HTTP. Clients must support configurable Bearer headers. This is a
pre-shared API-key integration, not OAuth discovery or an external MCP proxy.
The transport returns JSON; authenticated GET requests return 405 because this
version offers no SSE channel. DELETE closes a session and returns 204.

## Connect a client

Open **API keys → Connect with MCP** to copy the configured public endpoint.
Use the secret saved when creating a key for the desired agent:

```text
URL: http://localhost:4000/mcp
Transport: Streamable HTTP
Authorization: Bearer <API_KEY>
```

The client sends `Content-Type: application/json`, an `Accept` header containing
both `application/json` and `text/event-stream`, and one JSON-RPC message per
POST. Batches, null/fractional IDs and responses to unsolicited server requests
are not accepted. IDs are strings up to 256 bytes or integers in JavaScript's
safe integer range. Client IDs must be unique within a session.

1. Send `initialize` with `protocolVersion`, `capabilities` and
   `clientInfo: {name, version}`. The server returns its supported version and
   `MCP-Session-Id`; a client supporting a different version must disconnect.
2. Send `notifications/initialized`. Success is 202 with an empty body.
3. Include the session header and `MCP-Protocol-Version: 2025-11-25` on subsequent
   requests. If the version header is omitted, the existing session supplies it.
4. Initialize a new session after a session 404. Retrying an uncertain content
   operation in a new session can execute it again; resolve its outcome first.

For a JavaScript client with the official `@modelcontextprotocol/sdk` installed
in its own project, configure the header on the transport (SDK 1.32.0 was smoke
tested separately; the Phoenix application does not depend on it):

```js
import {Client} from "@modelcontextprotocol/sdk/client/index.js"
import {StreamableHTTPClientTransport} from "@modelcontextprotocol/sdk/client/streamableHttp.js"

const client = new Client({name: "my-agent", version: "1.0.0"})
const transport = new StreamableHTTPClientTransport(new URL(process.env.MCP_URL), {
  requestInit: {headers: {Authorization: `Bearer ${process.env.MCP_API_KEY}`}},
})
await client.connect(transport)
const {tools} = await client.listTools()
// When finished:
await transport.terminateSession()
await client.close()
```

The supported operations are `ping`, `tools/list`, `tools/call`, `resources/list`,
`resources/read`, and `resources/templates/list` (an empty list). Only tools and
resources are advertised as capabilities. No prompts, tasks, subscriptions,
list-change notifications or server-initiated requests are advertised.
Cancellation notifications are accepted without a response body; the bounded
executor cannot safely undo dispatched effects and does not cancel them.

## Policy, resources and execution

Discovery intersects one fresh policy snapshot with the verified agent's
operator resource grants, existing sandbox data, and assigned budget context.
Missing permissions deny access. There is no client-supplied identity or schema.
Schemas and descriptions come from the closed seven-operation tool catalog.
See [tool configuration](tools.md) for `TOOLS_SANDBOXES` and policy setup.

Each `tools/call` uses `Tools.execute/3`: identity/resource checks, input guards,
durable idempotency, atomic tool-call accounting, dispatch audit, filtered output
and terminal audit. The response contains only the filtered `structuredContent`
and its serialized JSON text. Tool failures use `isError: true`; protocol failures
use JSON-RPC errors. No raw exceptions or upstream error bodies are reflected.

Resources are existing authorized UTF-8 virtual files. Their identifiers are
`aicontrol://sandbox/files/<base64url-path>` and are resolved by exact lookup in
the current authorized catalog. Host filesystem and arbitrary URL URIs are never
opened. `resources/read` executes `file.read` through the same firewall and
consumes **one tool call**. A resource failure is a JSON-RPC error.

Resource pages are sorted by URI, with up to 100 entries and a signed cursor
bound to the session and policy checksum. A changed policy, foreign cursor,
expired cursor or tampering requires listing again without a cursor. Listing
never returns file text, table rows or mailbox messages. No listing performs an
adapter effect or consumes tool-call budget.

## Operator configuration

| Setting | Default | Meaning |
| --- | --- | --- |
| `MCP_ALLOWED_ORIGINS` | `[]` | JSON array of extra exact HTTP(S) origins |
| `MCP_SESSION_IDLE_TIMEOUT_MS` | `1800000` | Session idle lifetime |
| `MCP_MAX_AGENT_SESSIONS` | `32` | Sessions shared by all keys of an organization/agent |
| `MCP_MAX_SESSIONS` | `1000` | Total sessions in this application instance |

The configured public origin of the Phoenix endpoint is allowed automatically.
Origin-less server clients are accepted; `Origin: null`, unknown origins,
wildcards and repeated Origin headers are rejected. This does not enable CORS
for browser clients. Configuration is validated at application startup. Positive
integer session limits and canonical HTTP(S) origins are required.

IP admission, Origin, API-key authentication and the existing organization/agent
limiter run before parsing. MCP and REST share those limiters. POST bodies are
limited to 64 KiB; encoded responses to 256 KiB, including both tool result
representations. All responses are `Cache-Control: no-store`. Transport failures
use HTTP statuses (401, 403, 400, 404, 405, 406, 413, 415 or 429); an accepted
JSON-RPC request generally returns 200 even for a protocol/tool failure.

No migration, new policy schema or application runtime dependency is needed.
Use the existing public endpoint URL configuration for the address shown in the
panel. Keep TLS enabled for deployments carrying API keys outside localhost.

## Durability, privacy and limitations

Sessions are random, memory-only, bound to organization, agent and the exact key.
Every HTTP request reauthenticates; revocation, rotation, expiration and
suspension stop access. Restart discards sessions. Run one application instance;
shared sessions and distributed admission are outside this version.

The adapter derives a namespaced UUID from the session and the typed JSON-RPC ID;
integer `1` and string `"1"` differ. Clients need no `Idempotency-Key` header.
The existing durable receipt prevents repeat dispatch for the same execution ID.
A duplicate reports its execution ID/status without replaying content; changing
arguments produces a conflict. New request IDs or new sessions represent new
executions and do not deduplicate a previous intent.

There is no exactly-once guarantee for external effects. Output blocking cannot
undo an effect or refund a started tool call. No arguments/results are stored in
receipts. Audit remains the existing correlated `tool.*` evidence; MCP does not
add duplicate terminal events. Transport telemetry has only closed method/status
labels and duration, without identities, content, keys, sessions or cursors.

Step 11's real-model qualification remains open. Step 13 adds no detection-quality
claim and does not change mandatory guard policy or model readiness.

## Smoke test

Configure an authorized synthetic file and `file.read`; the required guards must
be available. Run Node 24 with the endpoint and an active key in environment
variables (never pass the key in a URL or commit it):

```sh
MCP_URL=http://localhost:4000/mcp node scripts/mcp_smoke.mjs
```

Set `MCP_API_KEY` securely before running. The client initializes and deletes its
session, lists tools/resources, reads the same file through both APIs and checks
an ACL denial. It prints no secrets or resource content and sends no extra
idempotency header. Successful reads consume two tool calls.

Protocol references: [transport](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports),
[lifecycle](https://modelcontextprotocol.io/specification/2025-11-25/basic/lifecycle),
[tools](https://modelcontextprotocol.io/specification/2025-11-25/server/tools) and
[resources](https://modelcontextprotocol.io/specification/2025-11-25/server/resources).

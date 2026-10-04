# Step 13 — MCP gateway acceptance

Implemented locally on 2026-10-04 on `JL/step-13-mcp-gateway`, based on `main`
at `4d4f0f6`. This accepts the MCP adapter over Step 12's existing sandbox.
It does not close Step 11's real-model/MVP qualification.

## Verification

The locked dependencies and initial build artifacts were restored from the
existing checkout without changing dependencies or `mix.lock`. PostgreSQL ran
on loopback port 55413 with isolated `step13` and `step13qa` database partitions.
All fixture organizations, agents, keys, files and mailbox data were synthetic.

| Check | Actual result |
| --- | --- |
| `PGPORT=55413 MIX_TEST_PARTITION=step13 mix precommit` | 559 ExUnit tests pass; 10 opt-in live tests excluded; five JavaScript tests pass; formatting, warnings-as-errors compilation, unused lockfile check and strict Credo pass |
| `mix assets.build` | Tailwind and esbuild pass |
| `mix dialyzer` | Zero errors, zero skipped findings |
| `mix security` | Configured Sobelow gate passes; dependency audit reports no vulnerabilities |
| Streamable HTTP client | `scripts/mcp_smoke.mjs` passes over actual localhost HTTP, without `Idempotency-Key`: initialize, initialized notification, ping, tool/resource discovery, tool call, resource read, ACL denial and session deletion |
| Official MCP client | Temporary `@modelcontextprotocol/sdk` 1.32.0 client passes handshake, ping, tools/resources, tool call, resource read, empty templates and DELETE; Bearer header only, no extra idempotency header |
| Browser/Impeccable | Desktop/mobile and light/dark reviewed; copy success and keyboard access checked; detector `[]`; fresh finish review **ship** |
| `git diff --check` | Pass |

Sobelow retains existing low-confidence SQL findings in Dashboard and a
Phoenix-managed upload-path finding in PolicyLive. No finding concerns the new
MCP modules. These are local results, not CI or throughput measurements.

The local QA database briefly stopped when the host ran out of disk space;
it recovered after space became available. The panel was reloaded and the final
contract suite passed after recovery. This environmental interruption is not
counted as a successful request or a gateway defect.

The official SDK was installed only in `/private/tmp` for independent
interoperability verification. It is not a repository or runtime dependency.

## Protocol, sessions and transport

`MCPTransport` runs before the endpoint's general parser. IP admission, exact
Origin validation, Bearer-key authentication and shared organization/agent
admission precede body reads. Requests contain one JSON-RPC 2.0 object, a string
or safe integer ID, JSON Content-Type and both transport Accept media types.
Bodies are bounded at 64 KiB; encoded responses at 256 KiB. Invalid Origin,
repeated security headers, unsupported versions, batches, malformed JSON,
notifications and content negotiation have endpoint coverage.

The supervised session process stores only bounded protocol metadata. Tests use
an injected clock and supervised restart to cover idle expiry, admission limits,
deletion and loss on restart without sleeps. Organization, agent and exact-key
bindings are enforced. Revocation, rotation, expiration and agent suspension are
rechecked through existing authentication. A missing session returns 400; an
unknown, foreign, expired or deleted session returns 404. The negotiated version
is retained when a subsequent request omits the protocol header.

GET returns 405, DELETE returns 204, and initialized/cancellation notifications
return bodyless 202. Capabilities advertise only tools and resources. Prompts,
tasks, subscriptions, external MCP connections, OAuth and SSE are outside scope.
Cancellation does not undo or cancel a dispatched effect.

## Discovery and executor evidence

`Tools.catalog/1` obtains one current policy snapshot, intersects it with the
operator's sandbox grants/context and existing resources, and returns metadata
through a restricted sandbox call. It never uses `inspect_state/1` in production
discovery. Tool names and input schemas remain the seven existing operations;
descriptions are a closed application catalog. Lists expose no file contents,
table rows or mailbox messages and consume no tool-call budget.

Only existing authorized UTF-8 virtual files become resources. URI lookup is
exactly against the current catalog; traversal, arbitrary host/HTTP URIs and
symlinks cannot open resources. Resource pages are sorted, capped at 100 entries,
and use signed session/policy-bound cursors. Tampering, another session and a
policy change invalidate the cursor.

Both tools and resource reads use the full existing executor. A resource read
consumes one call. Tests cover policy changes after discovery, one immutable
snapshot during guards, ACL/SSRF/traversal denials, exhausted tool budget,
required unavailable guards, deterministic Unicode redaction, output blocking,
and input/terminal audit failure. Filtered results alone reach structured JSON
and text; audit failure withholds them. Existing `/v1/tool_calls` and sandbox
security/network suites remain passing.

Eight concurrent duplicate MCP IDs cause one mailbox effect and one charged
call. Changed arguments under that ID produce an idempotency conflict. Typed ID
hashing distinguishes integer `1` from string `"1"`, and separates sessions.
Duplicates return receipt evidence without replaying prior results. No wrapper
terminal audit duplicates `tool.*`; transport telemetry contains only duration,
a closed method label and HTTP status. Request correlation uses the existing
generated `request_id`.

## Real models — separate result

`PGPORT=55413 MIX_TEST_PARTITION=step13 mix test
test/ai_control/tools/live_models_test.exs --include live_models` ran separately:
**one passed, one failed** in 2.1 seconds. The real NER test redacted Polish
person/address/PESEL data in Unicode tool arguments and nested output. The Qwen
test failed at `Semantic.ready?/1`; the configured semantic service on port 8003
was not ready, so it produced no assessment or quality measurement.

Contract tests use deterministic guards and controlled semantic test adapters.
The HTTP smoke fixture explicitly disables model guards for synthetic protocol
data; it is not proof of model quality or permission to disable mandatory guards
in an operator policy. Prompt Guard qualification and Step 11 remain open.

## Frontend and operation

The existing key page now provides **Connect with MCP** between creation and
issued keys. It displays the configured public endpoint, JSON transport/version
and a literal Bearer placeholder; no actual key is assigned to this section.
Copy feedback is polite and the fallback selects the readonly endpoint for
manual copying. Tests cover long-value copying, missing/denied clipboard,
API-key readers, managers, denied access and secret dismissal. Existing secret
removal on disconnect is preserved. See [UI review](step13-ui-review.md).

See [MCP operator/client guide](../mcp.md) for configuration. Defaults are a
30-minute idle session, 32 sessions per organization/agent and 1000 total;
`MCP_ALLOWED_ORIGINS` is a JSON array of extra exact origins. Session limits and
origins are validated at startup. No migration or policy schema change is needed.

Run one application instance. Restart requires initialization again. Clients
must support Bearer headers. There is no result replay, no exactly-once promise
for external effects and no protection against retrying the same intent under a
new ID or in a new session. Output blocking cannot undo effects or charges.
Distributed sessions, additional upstreams and model qualification remain
separate work.

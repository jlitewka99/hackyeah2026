# AiControl
<img width="1279" height="860" alt="image" src="https://github.com/user-attachments/assets/67b6efbb-0de4-4f0e-b907-ad7b2aa6e712" />

Phoenix 1.8 application. Run all commands from the repository root.

## Setup

Install the versions of Elixir, Erlang/OTP, and Node.js pinned in `.tool-versions`:

```sh
asdf install
```

Start PostgreSQL 17 on `localhost:5432` with a `postgres` role, password
`postgres`, and permission to create databases. Development and tests use
separate databases: `ai_control_dev` and `ai_control_test`.

To use a different PostgreSQL port, set `PGPORT` when running Mix commands:

```sh
export PGPORT=55432
```

Install dependencies, create and migrate the development database, and build assets:

```sh
mix setup
mix phx.server
```

Development uses a local audit key configured in `config/dev.exs`, so no audit
environment variables are required. Production requires a separate
base64-encoded key with at least 32 random bytes; tests use a deterministic key
configured only in `config/test.exs`.

For production, generate the key once, keep it in your environment or secret
manager, and reuse it on restart:

```sh
export AUDIT_FINGERPRINT_KEY="$(openssl rand -base64 32)"
export AUDIT_FINGERPRINT_KEY_ID=v1
```

Generating a new key changes fingerprints. When rotating the key, also change
`AUDIT_FINGERPRINT_KEY_ID`. Historical records retain their key IDs.

Policy v6 adds explicit human review for tools, LLM and delegation. Configure a separate
`APPROVAL_ENCRYPTION_KEY` before activation; approval permits one client resume and
never pauses the workflow clock. See the [approval runbook](docs/approvals.md) for
headers, grant rules, retention, migration and rollout details.

Open [localhost:4000](http://localhost:4000). The server can also run inside IEx
with `iex -S mix phx.server`.

## Organizer account

Public registration is disabled. Bootstrap the sole organizer after running the
migrations. Provide credentials through environment variables or your secret
manager; never put them in source files. For an interactive zsh session:

```sh
read 'AI_CONTROL_ORGANIZER_EMAIL?Organizer email: '
read -s 'AI_CONTROL_ORGANIZER_PASSWORD?Organizer password: '
export AI_CONTROL_ORGANIZER_EMAIL AI_CONTROL_ORGANIZER_PASSWORD
mix ai_control.bootstrap_organizer
unset AI_CONTROL_ORGANIZER_EMAIL AI_CONTROL_ORGANIZER_PASSWORD
```

Use a valid email address and a password of at least 12 characters and at most
72 bytes (Bcrypt's limit). The task creates a confirmed account in a transaction.
Repeating it for the same normalized email preserves the account, password, and
sessions. A different organizer email, an ordinary account with that email, or
invalid configuration produces an error without creating an account. A database
constraint also enforces the single-organizer rule.

Sign in at `/users/log-in`. The organizer lands at `/platform/organizations`;
`/users/settings` contains separate email and password forms. Organization
management and invitations are available from the organizer panel. Account
changes require authentication within the last 10 minutes, both when opening settings
and submitting changes. If that window expires while the page is open, submitting
either form redirects to sign-in without applying the change. Changing a password
revokes existing sessions; the submitting browser receives a fresh session. Remember-me cookies last 14
days, use HttpOnly and SameSite=Lax, and require HTTPS in production.

### Recovering access

Choose **Forgot password?** or open `/users/recover`. An existing account receives
a single-use email link valid for 15 minutes. The response is identical for known
and unknown emails. Consuming the link signs you in to account settings, where
you can set a new password. Email changes require confirmation at the new address.
Confirmations are serialized per account: concurrent uses of the same link, or
competing links for the old address, permit only one successful change.

Development uses Swoosh's local delivery adapter. The `/dev/mailbox` preview is
restricted to an authenticated organizer. Configure `AiControl.Mailer` with a
production delivery adapter and set a real sender in `AiControl.Accounts.UserNotifier`
before relying on email recovery
outside development; the generated local adapter does not send external mail.

## Organizations and member access

Run `mix ecto.migrate` when updating an existing installation. The organizer can
create, suspend, and restore organizations and invite their first superadmin from
`/platform/organizations`. An organization can wait for that invitation to be
accepted before it has a superadmin.

Organization names are globally unique, ignoring case and surrounding spaces.
The migration repairs existing duplicate names with numbered suffixes without
changing organization IDs. Use the searchable navigation dropdown in the
desktop sidebar or mobile header to switch workspaces.

| Role | Administrative access |
| --- | --- |
| Organizer | All organizations, organization status, and first-superadmin invitations |
| Superadmin | Full organization access; manage admins and users; transfer the role to an existing admin |
| Admin | Manage ordinary users and delegate access within their own grants |
| User | Organization overview, own account settings, and explicitly granted functions and resources |

Each organization has at most one superadmin. A transfer is atomic and leaves
the former superadmin as an admin with their previous explicit grants. Admins
cannot edit admins, promote users, or change their own access. Their role does
not automatically grant AI or configuration access. Read-only members use the
`user` role with selected read permissions.

Function grants are independent: `ai.use`, `agents.read`, `agents.manage`,
`api_keys.read`, `api_keys.manage`, `policies.read`, `policies.manage`,
`events.read`, `events.export`, `budgets.read`, `budgets.manage`,
`signatures.read`, and `signatures.manage`. An empty grant denies access.
Resource grants contain specific agent IDs or model names, or the explicit
`["*"]` selector for all organization resources of that type. Invitation and member
forms offer concrete organization agents, operator-registered models and all-resource selectors. Admin edits preserve grants they
do not have permission to manage.

`AiControl.Organizations.Access.authorize/3` refreshes database access before
checking capabilities and resources. The default
`AiControl.Organizations.ResourceResolver` verifies agents against the organization
registry. An adapter can still be configured under
`:ai_control, :organization_resource_resolver`. Concrete model assignments are
verified against the operator catalog. The gateway intersects resource access with
the effective organization policy before downstream requests.

Members choose a workspace at `/organizations`; a single available organization
opens automatically after sign-in. Active organization context comes from the
URL, so browser tabs remain independent. The overview shows assigned access;
managers use `/organizations/:organization_id/members` to invite members,
edit access, revoke invitations, or resend them. Removing membership, changing
access, or suspending an organization refreshes or closes its open LiveViews
while preserving the account session and access to other organizations.

### Invitations

Invitations use a one-time token with 32 random bytes, stored only as a SHA-256
hash and valid for 24 hours. Opening the link displays a form. Acceptance uses
a CSRF-protected POST. A new member sets and confirms their password; account
creation, email confirmation, membership, grants, and token consumption commit
together. Existing accounts must sign in with the invited email and keep their
password and other memberships.

Acceptance checks the organization status and the author's current authority
and grants again. Suspension blocks acceptance without extending expiration.
Resending revokes the previous token; failed delivery leaves a revoked
invitation that can be retried. Delivery uses the configured Swoosh adapter.
Configure the production adapter and invitation sender in
`AiControl.Organizations.Invitations` as well as the account notifier. Token
routes appear only as route templates in request logs.

Hammer with ETS applies shared limits to password sign-in and recovery requests:
5 attempts per normalized email and 20 per actual peer IP, in a 15-minute window
starting with the first attempt. Token submissions share the IP limit. Rejected
email attempts also count against the IP limit. Exceeding a limit returns HTTP
429 with `Retry-After` in seconds. Forwarded IP headers are not trusted. Counters
are atomic, cleaned periodically, local to one application instance, and reset
on restart. Email counter keys contain hashes rather than raw addresses.

Request logs contain server-generated UUIDs, methods, route templates, status,
duration, and fixed error codes. Parameters, raw paths, headers, exception bodies,
and client-supplied request IDs are excluded. The Phoenix debugger and dashboard
request logger are disabled; Req retry and redirect messages are disabled by
default. Downstream adapters use `AiControl.Security.HTTPError.classify/1` for
content-free failures and must keep request/response objects out of logs.
Theme selection defaults to the system setting
and remembers an explicit choice of system, light, or dark appearance.

## Agents and API keys

Upgrade an existing installation with `mix ecto.migrate`. Migration
`20261003161802_create_agents_and_api_keys` adds both tables and a composite foreign
key that prevents a key from referencing another organization's agent. There is
no data backfill. Restart the application and rebuild assets after upgrading.

Open `/organizations/:organization_id/agents` to register, rename, suspend, or
restore agents. Reading requires `agents.read`; mutations require `agents.manage`
and access to the target agent. Creating an agent also requires the explicit
all-agents selector `["*"]`. Lists show only currently assigned agents.

Open `/organizations/:organization_id/api-keys` to issue, filter, rotate, or revoke
keys. Reading and mutations require `api_keys.read` and `api_keys.manage`
respectively, with the target agent selected in the member's grants. These
permissions are independent of agent-registry access: a key administrator does
not need `agents.read`. Grant editors only offer agents the editor may delegate.

Keys represent agents independently of the human creator's membership or session.
They contain 32 cryptographically random bytes, encoded as
`aic_<uuid>_<base64url-secret>`. Only the SHA-256 hash of the complete token is
stored; list prefixes derive solely from the public UUID. The secret is returned
once on creation or rotation. Copy it to your secret manager before dismissing the
reveal. Navigation, refresh, reconnect, or loss of management access clears it;
the application never saves it in browser storage, the URL, or the session.

Expiration defaults to 90 days from issuance or rotation. The form also accepts
a future UTC date or no expiration. Rotation creates one successor and revokes
the old key in a single transaction. Validation failure rolls back both changes;
concurrent rotations permit exactly one successor. Revocation is permanent.
Suspending an organization or agent blocks all its keys. Restoration re-enables
only keys that have neither expired nor been revoked.

`GET /v1/auth` checks the database on every request and returns only
`organization_id`, `agent_id`, and `api_key_id`. The organization and agent always
come from the key. A missing, malformed, expired, revoked, or suspended credential
returns the same `401` with `WWW-Authenticate: Bearer`. Responses use
`Cache-Control: no-store`. Phoenix's request logger is disabled; shared request
telemetry records only the route template, status and timing, without headers or
credentials.

```sh
# Load AI_CONTROL_API_KEY from your secret manager; do not commit its value.
curl --fail-with-body http://localhost:4000/v1/auth \
  -H "Authorization: Bearer ${AI_CONTROL_API_KEY}"
```

This step provides identity and credential administration. LLM gateway endpoints,
policy enforcement and the model registry remain subsequent work. The existing
security and audit contracts remain available; auditing agent/key administration
is outside this change.

## Versioned policies

Step 5 adds `/organizations/:organization_id/policies` for policy readers and
managers, and `/platform/policies` for the organizer's global default. Saving
creates an immutable, inactive version. Review its differences before activation
or restoring a historical version. Returning to the global policy keeps local
history. Organizations inherit the current global version until they activate a
complete local replacement; local versions do not merge with global settings.
HTTP routes, LiveView events and the context refresh current access. Reading
requires `policies.read`; changes require `policies.manage`. Global operations
require a current organizer account.

The migration adds policy sets, immutable versions and activation history,
creates a system-authored `balanced` global version, and initializes existing
organizations to inheritance. New organizations also inherit. PostgreSQL enforces
one global set, one set per organization and active-version ownership. Set locking
and an expected revision prevent concurrent changes from silently overwriting
each other. Activation, history and audit commit together; an audit failure rolls
back the change. Global audit events use an explicit organizer-only platform
scope; organization reads remain isolated. Policy audit stores IDs, checksums,
authors and timestamps rather than source configuration or YAML.

Legacy v1/v2 numeric rule settings remain readable and retain their checksums:

| Profile | Personal data | Secrets / exploits | Injection threshold | Semantic guard |
| --- | --- | --- | --- | --- |
| Relaxed | redact | block | 0.9 | optional |
| Balanced | redact | block | 0.8 | required |
| Strict | block | block | 0.65 | required |

Deterministic guards default to required on input and output; semantic analysis
defaults to input. Explicit rule and guard fields override profile defaults.
The historical initial migration policy allows `qwen3.5:4b` and all active agents in the requesting
organization. Budgets start unconfigured. Organization and agent requests/tokens
per UTC hour are enforced by durable accounting. Workflow tool calls have an
atomic counter ready for the step 12 endpoint. Steps 7–8 connect deterministic
guards and NER to input and output, including schema validation after output redaction.

Import [the example policy](priv/policies/balanced.yaml) by pasting YAML or uploading
one file. All three schema versions accept one UTF-8 document up to 64 KiB. Unknown fields,
duplicate keys, aliases, anchors and explicit tags are rejected. Forms and YAML
share `AiControl.Policies.Configuration`; errors contain field paths without
input values. Exports use the JSON-compatible YAML 1.2 subset to preserve empty
collections, nulls and strings without ambiguous quoting. Selecting a profile
recomputes unspecified defaults; clear an override to restore the profile value.

```elixir
alias AiControl.Policies

{:ok, source} = Policies.import_yaml(File.read!("priv/policies/balanced.yaml"))
{:ok, version} = Policies.create_version(current_scope, source)
{:ok, current} = Policies.current(current_scope)
{:ok, _activation} = Policies.activate(current_scope, version.id, current.set.revision)

# Acquire once at the start of a future gateway request, then retain at all stages.
{:ok, snapshot} = Policies.snapshot_for_request(verified_principal, %{model: "deepseek-flash"})
```

`Policies.rollback/4`, `inherit/2`, `list_versions/2`, `get_version/3` and
`export_yaml/3` expose the corresponding operations; optional target `:global`
selects the organizer's set. `activate/4` and `rollback/4` return
`{:error, :stale_policy}` for an outdated revision. Each new request reads the
effective version from PostgreSQL, then uses supervised ETS for that immutable
version's snapshot. A delayed cache update, eviction or restart cannot select an
older active version. In-flight requests retain their original snapshot. Its
checksum includes all resolved rules, guards/stages, resource restrictions and
budgets. PubSub refreshes the panel without discarding unsaved edits.

Human AI access intersects current `ai.use`, owned agent/model grants and policy
restrictions. The model resolver denies names outside the operator catalog.
API principals keep their key-bound agent identity;
credential revocation, expiration and agent/organization status are rechecked.
Concrete policy agents must belong to the organization. Model names can be
configured ahead of the registry; a model wildcard requires a verified catalog.

## Security decisions and audit

Step 4 introduces `AiControl.Security.SecurityContext`, `Detection`, `GuardResult`,
`SecurityAssessment`, and `Decision`, each in its own module. Constructors reject
unknown fields and return content-free error atoms. Findings hold detector and
rule identifiers, categories, confidence, and optional locations. Locations use
a numeric content-field index and UTF-8 byte offsets, never matched values or
client-defined field names. Guard signals use the closed numeric catalog
`risk_score`, `injection_score`, `pii_count`, `secret_count`, and `exploit_count`.

`SecurityContext.from_scope/2` refreshes membership and organization status and
sets identity on the server. Request and assessment IDs are generated locally.
`SecurityContext.new/1` is reserved for trusted identity adapters, including
verified agent identities from step 3. Struct validation complements the
gateway's authentication and resource authorization; it does not grant AI use.
Security contexts accept agent and API-key UUIDs from the verified Bearer principal.
The security contracts remain independent of the registry schemas.

The minimal policy contract is an immutable `AiControl.Policy.Snapshot`:

```elixir
alias AiControl.Policy.Snapshot
alias AiControl.Security.{GuardResult, SecurityAssessment, SecurityContext}

{:ok, policy} = Snapshot.new(%{
  version: "balanced-v1",
  required_guards: ["pii"],
  rules: %{"pii" => %{id: "pii.default", action: :redact, threshold: 0.8}}
})

{:ok, context} = SecurityContext.from_scope(current_scope, %{
  stage: :input,
  policy_version: policy.version,
  policy_checksum: policy.checksum
})
{:ok, result} = GuardResult.new(%{guard: "pii", status: :ok})
{:ok, assessment} = SecurityAssessment.new(context, [result])
AiControl.Security.evaluate_and_audit(context, assessment, policy)
```

The snapshot computes a canonical SHA-256 checksum of its version, required guards,
and rules. Supplied checksums must match, and modifying a struct without updating
its checksum fails validation. `AiControl.Policy.Engine.evaluate/3` is pure and
uses `BLOCK > REDACT > ALLOW` with an inclusive confidence threshold. An absent,
skipped, or failed required guard blocks. An unmapped finding blocks; redaction
without a usable location also blocks. Optional failures remain audit evidence.
The engine produces redaction locations; executing redaction and supplying real
guards arrive in later steps. Step 5 adds the versioned policy configuration
described below; the legacy snapshot constructor remains supported.

`AiControl.Security.Fingerprint.content/3` takes an organization UUID, stage,
and binary content and returns a tenant- and stage-separated HMAC-SHA-256
fingerprint. Pass it as `fingerprint:` when building a context; a fingerprint
from another tenant or stage is rejected. The returned struct never retains
the content. Input and output assessments keep distinct IDs and stages.

`AiControl.Audit.record_decision/3` stores guard statuses, fixed error codes,
confidence, detector/policy rule IDs, reasons, policy identity, UTC microsecond
timestamps, guard durations, and optional fingerprints. `duration_us` is the
sum of guard durations. Evidence also includes evaluated rule actions and
thresholds, required guards, and redaction locations. A finding below threshold
can therefore be explained from the audit without retrieving checked content
or depending on a mutable active policy. Writes are synchronous: `evaluate_and_audit/3` returns
`{:ok, decision}` only after persistence. A write failure returns
`{:error, :audit_unavailable}`; the future gateway maps it to HTTP 503 and starts
no new downstream call. Retrying the same assessment is idempotent; changed
evidence returns `{:error, :audit_conflict}`.

Organization creation/status, membership role/access changes, removal,
superadmin transfers, and invitation issuance/revocation/acceptance/delivery
failures share transactions with `record_admin/3`. Audit failure rolls back
the mutation. PubSub publishes after commit. Access evidence preserves roles,
permissions, selector counts, and keyed grant fingerprints without storing
emails, resource names, invitation tokens, or passwords. Historical references
survive membership and invitation removal; organization deletion is restricted
while audit records exist. There is no audit update/delete API.

Invitation issuance inserts its audit before sending email within the
transaction. A mail failure commits a revoked invitation and its audit so it can
be retried. If that audit fails, the new invitation is rolled back. An email sent
before a failed database commit can contain an inactive link; resend creates
a new token. Configure bounded mail-adapter timeouts because issuance holds
the organization lock during delivery.

`Audit.list_events(scope, limit: 50, offset: 0)` and `Audit.get_event(scope, id)`
refresh `events.read` access and restrict results to the scope's organization.
The maximum page size is 200. An organizer can inspect suspended organizations;
ordinary members lose access on suspension or revocation. The serializer uses
closed fields and rejects raw payloads and exceptions. Reporting and JSONL export
are available below; retention remains a later roadmap step.

### Organization reporting and JSONL export (step 11A)

Overview combines terminal gateway decisions, current hourly budgets, measured
latency and active controls. Each section needs its own read capability; the
organization overview itself remains available without reporting grants.
The read-only `/organizations/:organization_id/budgets` and `/signatures` pages
use limited policy summaries without requiring `policies.read`. Configuration
stays in Policies. Organization accounting totals retain their existing access
rules, while individual agent rows require the corresponding resource grant.

`/organizations/:organization_id/events` requires `events.read`. Its URL filters
cover UTC time range (`range=1h|24h|7d|custom`, `from`, `to`), `kind`, `action`,
`stage`, `guard`, `agent_id`, `reason_code` and `request_id`. Default range is 24 h;
custom boundaries are inclusive/exclusive. Pages contain 50 events, using an
opaque `(occurred_at, id)` cursor. Event details show a request chronology and a
closed projection of identifiers, rules, signals, semantic evidence and usage.
Historical operation/timing gaps remain unrecorded. Latency uses nearest-rank
p50/p95 with sample counts, in milliseconds; overlapping stages are not subtracted.
The upstream sample measures only `provider.chat`, and gateway total ends before
the terminal audit write.

`GET /organizations/:organization_id/events/export` requires both `events.read`
and `events.export`, and accepts the same filters. The Events download link freezes
its current range. The response is `application/x-ndjson`, with no-store caching:
each line has `type: "event"`, `schema_version: 1` and `event`; the final line has
`type: "export_complete"`, `schema_version: 1` and `count`. Consumers must require
the completion line before treating a download as complete. The export streams
500 events at a time, ordered by `(occurred_at, id)`, in a READ COMMITTED transaction.
It refreshes both grants before each chunk and the completion line; revocation or
disconnect stops the stream. A large download holds one database connection, with
a five-minute transaction timeout. Exported nested evidence uses explicit field
and type allowlists; prompts, responses, tool arguments and arbitrary data are
never copied into the result.

Content-free organization PubSub signals refresh reporting after successful
commits, coalesced over 200 ms; a minute timer advances rolling ranges and the UTC
hour. Access is rechecked before refreshing. Agent rename and policy drafts survive
updates. Code that wraps a context in its own transaction must emit its notification
after committing; nested operations suppress premature notifications.

Step 12B is now part of the base application. Tool dispatch events do not count
as terminal requests. Events and export expose only the allowlisted execution
receipt identifiers, status, tool and charged flag; tool arguments and result
content remain private. Tool audit records without operation/timing observations
retain those gaps. Successful claim, dispatch and finish commits notify reporting.
A proposal or pattern detection does not demonstrate that a tool executed.
Step 11A does not complete step 11: model comparison, combined dashboard/tool
qualification and full MVP acceptance remain 11B.

## LLM gateway

The gateway provides authenticated `POST /v1/chat/completions` and `GET /v1/models`.
Bearer API keys are bound to an organization and agent. Trusted application callers
can use `AiControl.Gateway.chat(scope, params, agent_id: agent_id)`; current `ai.use`
and both resource grants are required. Client identity fields are rejected.

The sole generating model is `deepseek-flash` through the direct DeepSeek API
(currently V4.1 Flash). Set `DEEPSEEK_API_KEY` in the environment or your secret
manager. The fixed upstream origin is `https://api.deepseek.com`; no Ollama
service or local generation weights are needed. Local Qwen Guard, optional
Prompt Guard and NER remain security controls. Grants and organization/agent
policies still determine access. `/models` verifies an available API identifier,
which is not verification of model weights.

```sh
# Set DEEPSEEK_API_KEY securely in your environment before starting.
mix phx.server
```

The default output cap is 1024 tokens for every chat, even without a hard token
budget. `thinking` is always disabled. Generation uses bounded Req transport with
no retries, redirects or fallback backend. `/health` checks application liveness;
`/ready` additionally checks PostgreSQL, DeepSeek authentication/model availability,
required local guards and the tokenizer when hard token budgets are active.

For a fresh database, `mix ecto.setup` seeds a new immutable DeepSeek default after
the historical initial policy. Release startup does this only when every migration
was previously pending. Existing deployments retain their active policies and
require the administrator procedure below.

### Switching an existing database to DeepSeek

1. Set `DEEPSEEK_API_KEY` as a runtime secret and restart with the new release.
2. In member and invitation access settings, replace explicit `qwen3.5:4b` model
   grants with `deepseek-flash`. Wildcard grants already include the new model.
   Update each affected member and outstanding invitation; administrative roles
   alone do not grant model access.
3. As organizer, export the active global policy, replace `allowed_models` and
   any explicit `agent_models` or v6 `review.llm_models` selectors with
   `deepseek-flash`, save a **new version**,
   review and activate it. Repeat for each organization with its own active policy.
   Keep the remaining policy settings. Existing versions, checksums, activations,
   audit and reports remain immutable. The old model identifier has no alias.
   Pending LLM approvals for the old backend cannot authorize a DeepSeek request;
   submit a new operation with a new idempotency key for human review.
4. Start the pinned V4.1 tokenizer and required local guards, check `/ready`, then
   run the explicit live acceptance commands with an API key with active balance.
   Tokenizer/API count drift leaves hard-token-limit acceptance incomplete.

Supported requests contain text `messages`, function `tools`, assistant
`tool_calls` history and tool results. Optional controls are `tool_choice`,
`temperature`, `top_p: 1`, `max_tokens` (1–32768), `stop`, `n: 1` and
boolean `stream` (defaults to `false`). Buffered SSE accepts
`stream_options: {"include_usage": true}` only with `stream: true`.
Images, audio, unknown fields and unsupported formats return `400`.
The gateway returns one assistant choice and validated token usage.
It passes tool proposals through security assessment; it does not execute tools.
Provider reasoning and unknown response fields are discarded. The `developer`
role is translated to `system`. `seed` and `top_p` values other than 1 are rejected;
DeepSeek non-thinking mode ignores top-p sampling. [DeepSeek Chat Completions](https://api-docs.deepseek.com/api/create-chat-completion/)

```sh
curl http://localhost:4000/v1/chat/completions \
  -H "Authorization: Bearer $AI_CONTROL_API_KEY" \
  -H 'Content-Type: application/json' \
  -d '{"model":"deepseek-flash","messages":[{"role":"user","content":"Describe Kraków in one sentence."}],"stream":false,"max_tokens":128}'
```

For buffered SSE, use a client that handles comments and `event: error`:

```sh
curl --no-buffer http://localhost:4000/v1/chat/completions \
  -H "Authorization: Bearer $AI_CONTROL_API_KEY" \
  -H 'Content-Type: application/json' \
  -H 'Accept: text/event-stream' \
  -d '{"model":"deepseek-flash","messages":[{"role":"user","content":"Describe Kraków in one sentence."}],"stream":true,"stream_options":{"include_usage":true},"max_tokens":128}'
```

The connection opens after input controls, synchronous audit, model verification
and budget preparation. During generation it sends only `: keepalive` comments
every five seconds. The complete upstream response, including fragmented tool
arguments, passes the existing output controls and required audit before any
public delta. This preserves output filtering and does not reduce time to the
first content token. Approved frames use gateway IDs and model names: assistant
role, content/tool proposals, finish reason, optional usage, then `data: [DONE]`.
Client usage is omitted by default; upstream usage is always requested for billing.

Preflight refusals retain the normal JSON HTTP status. After SSE opens, refusals
and failures use `event: error` with fixed `error.code`, `error.message` and
`error.request_id`; no violating content or `[DONE]` follows. Check this event even
when HTTP status is 200. Disconnects and write failures cancel upstream generation
and free its slot. Approved delivery, including the final marker, has a 30-second
watchdog. `GATEWAY_RESPONSE_BYTES` bounds received SSE bytes, the assembled
response and the redacted result separately (4 MiB by default). It is not a token
limit. Heartbeats and protocol envelopes also consume upstream wire bytes.

Valid final usage is settled once even if output is blocked or delivery is
cancelled. Cancellation before dispatch releases reserved tokens; cancellation
after dispatch without final usage leaves them `uncertain`. Chunk counts never
estimate generated tokens. Existing Events/JSONL include a closed `stream` map
with buffered mode, delivery status and received/sent byte and chunk counters.
Sent counters describe approved data frames accepted by the socket adapter;
they exclude heartbeats and `[DONE]` and do not prove client receipt.

The real incremental Qwen Stream comparison is an offline experiment and does
not activate a guard or change policies. Reproduction and limitations are in
[the harness instructions](sidecar/semantic_stream/README.md) and
[the Step 17 acceptance report](docs/acceptance/step17.md).

Each request retains one immutable policy snapshot. Input is synchronously audited
before even querying backend model metadata; output is assessed and audited before
returning any content. When both deterministic and semantic adapters are enabled,
the deterministic phase is audited and redacted first, then semantic assessment
uses fresh fields for that text version. Audit stores only typed findings, byte
ranges, policy evidence and fixed terminal codes. Telemetry events
`[:ai_control, :gateway, :stage]` and `[:ai_control, :gateway, :request]` contain
microsecond durations and fixed stage/result codes, without content or identities
as metric labels.

**The existing balanced policy still requires its guards.** Deterministic
adapters and pinned Qwen semantic analysis are connected. NER requires an
explicitly activated v2/v3 policy; response moderation requires v3 and is disabled
by default. Missing required adapters return
`503` and never call the LLM. A DeepSeek API key alone does not provide a ready protected
service. Optional adapters may fail only under an explicit policy; their failure
is retained in the assessment evidence.

| Operator variable | Default |
| --- | --- |
| `GATEWAY_INPUT_BYTES` | 1048576 (1 MiB, raw JSON before buffering) |
| `GATEWAY_RESPONSE_BYTES` | 4194304 (4 MiB, including error bodies) |
| `GATEWAY_CONNECT_TIMEOUT_MS` | 2000 |
| `GATEWAY_LLM_TIMEOUT_MS` | 120000 (metadata and generation together) |
| `GATEWAY_GUARD_TIMEOUT_MS` | 10000 (deterministic/NER) |
| `GATEWAY_SEMANTIC_TIMEOUT_MS` | 30000 (1–30000; whole semantic call) |
| `GATEWAY_READINESS_TIMEOUT_MS` | 5000 |
| `GATEWAY_LLM_SLOTS` | 1 |
| `GATEWAY_GUARD_SLOTS` | 2 |
| `GATEWAY_REQUESTS_PER_MINUTE` | 60 per actor in an organization |
| `GATEWAY_IP_REQUESTS_PER_MINUTE` | 300 attempts per remote IP before authentication |
| `GATEWAY_DEFAULT_MAX_TOKENS` | 1024 for every generating request |
| `TOKENIZER_BASE_URL` | `http://127.0.0.1:8002` (private) |
| `TOKENIZER_TIMEOUT_MS` | 5000 |
| `GATEWAY_PRICES` | USD 0.30/M input, 1.20/M output for DeepSeek; estimated |

The ingress counter is local Hammer/ETS and is shared by all keys of one agent;
restart resets it. Authenticated rejected requests count too. Saturated slots return
`429` immediately with `Retry-After`; timeout, cancellation and owner death stop the
supervised worker and free the lease. Generation has no retries or redirects, and
response reception stops at its size cap. Hourly budgets persist in PostgreSQL.
`400/413` indicate invalid/oversized input, `403` policy denial, `429` overload,
`502` unusable backend responses, `503` unavailable security/audit/model/accounting services
and `504` backend timeout. Error responses use fixed text and a server request ID.

`GET /health` is liveness. `GET /ready` is bounded readiness of the database,
effective active policies, available DeepSeek model and required guard adapters,
returning only `200 {"status":"ready"}` or `503 {"status":"not_ready"}`. Readiness
includes the platform default and every active organization's effective policy.

Run the real-model acceptance separately from ordinary mock-based CI:

```sh
# Use an isolated PostgreSQL instance/database partition.
PGPORT=55438 MIX_TEST_PARTITION=step6live mix test \
  test/ai_control/gateway/live_deep_seek_test.exs --include live_models
```

The acceptance test creates a dedicated organization, activates an explicit local
policy with unavailable guards disabled, and rolls its data back. It checks the
pinned real model, authenticated catalog, a Polish response and both stage audits.
It never changes the platform balanced policy. Ordinary `mix test` excludes the
`:live_models` tag.

After Step 8 merges, the remaining MVP integration order is **9 → 10 → full 12 → 11**.
The Polish semantic benchmark and the complete tool ACL retain their acceptance criteria in
[the implementation roadmap](AI_CONTROL_LAYER_IMPLEMENTATION_PLAN.md).
[Selective Granite Guardian](docs/granite-guardian.md) is available as an optional
local guard, disabled by default. Its pinned tokenizer shares the private sidecar
with the DeepSeek recipe encoder; enabling Granite requires its external Ollama
service. DeepSeek remains the sole model exposed for generating chat responses.

## Output filtering

Steps 8 and 17 buffer the single response for both JSON and SSE and validate its public
envelope and tool contract before scanning it. PII, secrets and signatures run
first, then NER, then the configured semantic adapter. Every phase uses the same
policy snapshot, audits its decision, applies any redaction and validates the
result before the next control receives fresh fields. There is no regeneration
or automatic model change.

Scanning includes assistant text, every tool-call ID and name, and every decoded
JSON argument key and leaf, including nested arrays and numbers rendered as text.
JSON escapes cannot hide values. String argument fields retain their property
name as a scan-only prefix, so `password` values keep their credential context.
Only assistant text and string argument values can change. Keys, IDs, names and
other JSON types are immutable; required redaction of any of them rejects the
whole response. UTF-8 byte spans must align to codepoints; overlapping spans
merge into `[REDACTED]`. Redacted arguments are encoded again with Jason.

The contract is compiled from the filtered request actually sent to the model.
Every proposal must name a declared tool, respect `tool_choice`, contain a JSON
object and satisfy its schema before and after each phase. Duplicate tool
definitions, call IDs and argument object keys are rejected, including duplicate
keys expressed with Unicode escapes. Missing `parameters` permits any object.
JSV validates Draft 2020-12 by default and explicitly declared Draft 7, with
`format` assertions enabled. Casting, atom creation, module callbacks and remote
schema downloads are disabled. References must resolve within the supplied
schema or built-in metaschemas. Compilation and validation share the supervised
guard slots and timeout. Invalid schemas return `400` before generation.

| Failure | HTTP response |
| --- | --- |
| Policy blocks any output | `403 policy_blocked` |
| Redaction cannot preserve immutable fields, JSON or schema | `403 redaction_unavailable` |
| Original provider response violates the envelope or tool contract | `502 upstream_invalid_response` |
| Required control or audit unavailable | `503` |
| Guard capacity exhausted | `429` with `Retry-After` |

Every refusal contains only the fixed error message, code and `request_id`;
assistant text and all tool proposals are withheld. Successful responses retain
the gateway envelope, provider allowlist and original supported `usage` values.
Terminal audit and gateway telemetry record the actual ending stage, including
output validation refusals, without content, argument values or library errors.
See [Step 8 acceptance](docs/acceptance/step8.md) for failure and real NER evidence.

The `assess/4` guard contract, existing policy versions and default required
controls remain compatible. Clients must now provide valid schemas and declared,
unambiguous tool proposals. Billing blocked output awaits Step 9 integration;
the real semantic provider belongs to Step 10 and tool execution/ACL to Step 12.

## Deterministic guards and Polish NER

Guards receive the same immutable request snapshot through
`assess(fields, context, snapshot, config)`. The pipeline evaluates PII, secrets
and signatures, audits the decision and applies redaction, then repeats for NER,
then runs semantic analysis. Every phase extracts fresh fields from the current
text. A required failure or failed audit stops subsequent calls. Byte ranges
use UTF-8 with an exclusive end; overlapping ranges are merged and replaced
with `[REDACTED]`. Invalid ranges, immutable map keys, model-name changes or
redaction that invalidates the request/tool-call JSON cannot reach the backend.
Audit, telemetry and error messages contain no matched values or snippets.

`builtin.v1` detects PESEL (checksum and real encoded birth date), NIP, REGON
9/14, Polish NRB, domestic/foreign IBAN (country structure and mod-97), cards
(13–19 digits, Luhn and preceding payment context) and email. Supported formats
are listed in [the versioned catalog](priv/guards/detectors.v1.json): compact
identifiers, specified NIP/PESEL groupings, space/NBSP bank groups and space/hyphen
card groups. Newlines and arbitrary intervening text never join digit groups.
The 89-country IBAN catalog pins SWIFT release 101; unsupported/newer country
formats require a new catalog. Checksum validity does not prove ownership or
that an identifier exists.

Credential signatures cover private-key PEM (including incomplete keys),
three-segment JWT/JWS with decoded header/base64url validation (including optional
types and detached payloads per [RFC 7515](https://www.rfc-editor.org/rfc/rfc7515)), AWS/GitHub/Google
formats, Bearer values, credential assignments and connection-string passwords.
Contextual entropy excludes generic UUID/hash values and does not scan every
random string. Known credential labels still classify literal hashes as possible
credentials. Detection never verifies a credential with its provider. Exploit
signatures cover `pickle.load(s)`, unsafe `yaml.load`, `eval`/`exec`, `os.system`
and subprocess calls with `shell=True`; safe alternatives and attribution are in
[the catalog notices](priv/guards/NOTICE.md). These patterns detect text, not
proof of execution, and do not replace a Python parser or tool firewall.

The local Python service uses pinned CPU Presidio/Stanza PL/NKJP weights and
project-authored Polish street-address rules. `persName` maps to `person`,
`placeName` to `place`, `geogName` to `geographical_location` and `orgName` to
`organization`; dates and times are excluded. Address patterns cover street
prefixes, house/apartment numbers and optional Polish postcode/locality, not
every postal-address form. Names are statistical findings: 0.85 is a recognizer
score, not a calibrated probability or a guarantee of PII recall.

`POST /analyze` accepts `{"fields":[{"field_index":0,"text":"…"}]}` and returns
only the model-set ID and typed findings with index, score, stable detector ID
and byte range. Elixir independently validates every finding. `GET /ready`
requires loaded, checksum-verified models. Requests are capped at 1 MiB and
20,000 fields; findings are capped at 20,000. One sidecar analysis runs at a
time, with immediate overload rejection; gateway guard slots are bounded.
Req uses timeouts, bounded response reception, no retries and no redirects.
Neither startup nor inference downloads models.

### Activating schema v2

Historical v1 validation/normalization lives in the frozen
`AiControl.Policies.ConfigurationV1`; its checksum contract is unchanged. Missing
NER in v1 means disabled. **Upgrade to v2** in the organization or platform editor
changes only the draft. Save it, review differences, then activate separately.
The same process works through YAML. Default v2 protects `person` and `address`;
localities, geographical places and organizations require explicit selection.
NER is required in balanced/strict and optional in relaxed. Balanced redacts PII;
strict blocks it. Explicit rule/guard overrides remain available.

```yaml
schema_version: 2
profile: balanced
allowed_models: [deepseek-flash]
allowed_agents: ['*']
guards:
  ner:
    entities: [person, address]
detector_sets:
  pii: builtin.v1
  secret: builtin.v1
  signatures: builtin.v1
  ner: pl-nkjp.v1
tools:
  allowed_tools: []
```

Only the shipped immutable sets are accepted. `tools.allowed_tools` validates
unique tool identifiers and defaults to empty. Step 12B enforces this list in
`POST /v1/tool_calls` together with operator resources, guards, audit and budgets.
The read-only Signatures dashboard is available in step 11A. Step 8 applies these
adapters to generated text and decoded tool arguments before returning any output.

### Prompt Guard injection and schema v4 — Built with Llama

Step 11B adds a per-organization `guards.semantic.provider` choice: `qwen` or
`prompt_guard`. Prompt Guard compares the maximum malicious score against an
inclusive 0–1 threshold; Qwen keeps severity/Jailbreak mapping. Response
moderation continues to use Qwen. Upgrade only a draft, save, inspect its diff,
and activate explicitly. Existing versions/checksums remain compatible.

Prompt Guard is optional and requires manually approved model access under the
Llama 4 Community License. The standard build/CI does not require that access.
See [operator setup, license and BuildKit secret](docs/prompt-guard.md), the
[measured injection example](docs/prompt-guard-example.yaml) and
[Step 11B acceptance/gates](docs/acceptance/step11b.md). The real comparison has
qualified Prompt Guard at cutoff .50 (FPR 0%, mean direct/indirect recall 50%).
The final complete live-service runner passes 11/11 and both container smoke
runs pass. Step 11 and full MVP acceptance remain open for idle-hardware capacity
validation and the Qwen long-input timeout observed in an earlier loaded run;
see the recorded successful and failed attempts in the acceptance report.

`PROMPT_GUARD_BASE_URL` defaults to `http://127.0.0.1:8004`. The optional image
build starts a fifth offline supervised process; a required unavailable provider
blocks traffic. `./run_security_tests.sh` runs the full shared suite and Python
contracts; `--live-models` additionally requires all five real model services and
fails when a dependency is missing. See the operator guide for Python/tokenizer
prerequisites. Benchmark launch UI belongs to Step 16.

### Qwen semantic analysis and schema v3

`Qwen/Qwen3Guard-Gen-0.6B` runs through the replaceable
`AiControl.Guards.Semantic.Provider` interface and the bounded `Req` HTTP adapter.
The [model manifest](sidecar/semantic/models.v1.json) pins weights, tokenizer,
chat template and SHA-256 checksums at revision
`fada3b2f655b89601929198343c94cd2f64d93cc`. Image preparation downloads the
files; runtime verifies them and loads them offline through Transformers 4.57.1
and Torch 2.8.0, on CPU in FP32, without quantization.
The [Qwen model card](https://huggingface.co/Qwen/Qwen3Guard-Gen-0.6B) defines
severity/category labels and separate prompt–response moderation.

All supplied fields are scanned in tokenizer windows of up to 2048 tokens with
256-token overlap. The service reserves template/generation space and admits one
active scan, at most 128 windows and 30 seconds per whole call. Missing fields,
invalid UTF-8 coverage, unknown labels, malformed results, overwork and timeout
fail the guard. A required guard blocks the request or response. HTTP requests
have a response-size limit, no retries and no redirects. Internal `/analyze`
returns labels and byte coverage; `/ready` returns model identity and process
measurements. Neither endpoint logs source text or raw generated classifications.

Use **Upgrade to v3** in either policy editor. It upgrades only the draft;
**Save version**, review differences, and **Activate version** remain separate
steps. Existing v1/v2 versions and checksums stay unchanged. V3 injection maps
only `Jailbreak`: relaxed/balanced use `Unsafe`; strict also uses `Controversial`.
The label rules use `allow/block`, without a confidence slider. A finding's `1`
is explicitly a binary label-mapping signal, not a probability.

Response moderation is a separate, output-only `moderation` guard and
`content_safety` rule, disabled by default. Choose its severity labels and safety
categories, then require or optionally enable it. It uses current response fields
and the accepted, redacted input as per-call context. The context is never stored
in shared configuration or audit; oversized prompt–response context fails rather
than truncating. Audit evidence contains only model set/revision, labels, refusal,
binary semantics and UTF-8 scan coverage.

For local real-model acceptance:

```sh
python3.11 -m venv _build/semantic-venv
_build/semantic-venv/bin/pip install -r sidecar/semantic/requirements.lock
_build/semantic-venv/bin/python sidecar/semantic/models.py download _build/semantic-models
SEMANTIC_MODELS_DIR="$PWD/_build/semantic-models" HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1 \
  _build/semantic-venv/bin/python -m uvicorn service:app --app-dir sidecar/semantic \
  --host 127.0.0.1 --port 8003 --workers 1 --no-access-log --log-level critical
```

In another terminal, using an isolated test database:

```sh
_build/semantic-venv/bin/python -m unittest discover -s tests/semantic
SEMANTIC_BASE_URL=http://127.0.0.1:8003 mix test test/ai_control/gateway/live_semantic_test.exs --include live_models
SEMANTIC_BASE_URL=http://127.0.0.1:8003 mix ai_control.benchmark_semantic \
  --split all --output docs/acceptance/step10-qwen --hardware 'Record CPU, OS, RAM and thread count'
```

The frozen dataset contains 200 Polish input cases and 40 moderation pairs, split
50/50 by family before measurements. Reports contain IDs, confusion matrices,
errors, warm p50/p95, cold load and peak RSS; PII is its own group and a negative
for injection, rather than a PII recognizer benchmark. The [acceptance record](docs/acceptance/step10.md)
records results and limits. All Prompt Guard implementation, gated weight access
and same-hardware comparison belong to Step 11B, together with final MVP quality
selection (FPR ≤ 5%, then mean direct/indirect recall, then p95). Tool execution and filtering are integrated in 12B. Final model qualification
and shared MVP acceptance remain in 11B.

### One container on Coolify

Use Coolify's [Dockerfile build pack](https://coolify.io/docs/applications/builds/dockerfile)
with `/Dockerfile`, build context `/`, port **4000**, and your HTTPS domain.
PostgreSQL is a separate service. Generating calls require outbound HTTPS to DeepSeek.
Phoenix binds `0.0.0.0:4000`; NER (`127.0.0.1:8001`), budget tokenizer
(`127.0.0.1:8002`) and Qwen Guard (`127.0.0.1:8003`) are internal loopback services
and are not published. Step 9 added the tokenizer; Qwen uses a separate port.
Models are fetched and checked at image build time, then verified and loaded
offline on startup. The non-root container uses `tini` and a supervisor script
that forwards termination, reaps children and exits when any of the four
processes fails. CPU FP32 Qwen and NER need separate memory headroom; size the
container from [Qwen acceptance measurements](docs/acceptance/step10.md) and
[NER measurements](docs/acceptance/step7.md), then measure on the deployment CPU.

Set these runtime variables using Coolify's secrets UI:

| Variable | Value |
| --- | --- |
| `DATABASE_URL` | `ecto://USER:PASSWORD@POSTGRES_HOST/DATABASE` |
| `SECRET_KEY_BASE` | A fresh secret generated with `mix phx.gen.secret` |
| `AUDIT_FINGERPRINT_KEY` | At least 32 random bytes encoded as base64 |
| `AUDIT_FINGERPRINT_KEY_ID` | Rotation ID, default `v1` |
| `APPROVAL_ENCRYPTION_KEY` | Separate 32 random bytes encoded as base64; required for human review |
| `APPROVAL_ENCRYPTION_KEY_ID` | Preview key rotation ID, default `v1` |
| `PHX_HOST` | Public hostname without scheme |
| `DEEPSEEK_API_KEY` | Runtime secret for the direct DeepSeek API |
| `NER_BASE_URL` | Keep `http://127.0.0.1:8001` for this container |
| `NER_CPU_THREADS` | NER CPU inference threads, default `2` |
| `TOKENIZER_BASE_URL` | Keep `http://127.0.0.1:8002` for this container |
| `SEMANTIC_BASE_URL` | Keep `http://127.0.0.1:8003` for this container |
| `SEMANTIC_CPU_THREADS` | Qwen CPU inference threads, default `2` |
| `PROMPT_GUARD_BASE_URL` | Optional sidecar origin, default `http://127.0.0.1:8004` |
| `PROMPT_GUARD_CPU_THREADS` | Prompt Guard CPU inference threads, default `2` |
| `GATEWAY_SEMANTIC_TIMEOUT_MS` | Whole semantic call, default `30000`, maximum `30000` |
| `POOL_SIZE` | PostgreSQL connections, default `10` |

`PHX_SERVER=true`, `PORT=4000` and the model directory are image defaults.
The database must already exist. Migrations run at container startup and can
also be run manually through the release. Bootstrap the organizer once in the
container console after setting temporary organizer credentials:

```sh
/app/bin/ai_control eval 'AiControl.Release.migrate()'
/app/bin/ai_control eval 'AiControl.Release.bootstrap_organizer()'
```

Bootstrap reads `AI_CONTROL_ORGANIZER_EMAIL` and `AI_CONTROL_ORGANIZER_PASSWORD`;
it is idempotent for the existing organizer and never prints credentials.
Remove those temporary variables afterward. The image healthcheck checks
Phoenix `/health`, NER `/ready` and Qwen `/ready`; Coolify can use that Dockerfile
healthcheck. Gateway `/ready` additionally checks the database, DeepSeek/model
availability and every required security control. Health is not permission to
send traffic under an incomplete required policy. Deployment is a separate step.

For local real NER acceptance (models must already be downloaded):

```sh
python3.11 -m venv /tmp/ai-control-ner
/tmp/ai-control-ner/bin/pip install -r sidecar/ner/requirements.lock
/tmp/ai-control-ner/bin/python sidecar/ner/models.py download /tmp/ai-control-models
STANZA_RESOURCES_DIR=/tmp/ai-control-models /tmp/ai-control-ner/bin/python -m uvicorn \
  service:app --app-dir sidecar/ner --host 127.0.0.1 --port 8001 --no-access-log --log-level critical
```

Run `NER_LIVE=1 STANZA_RESOURCES_DIR=/tmp/ai-control-models /tmp/ai-control-ner/bin/python
-m unittest discover -s tests/ner` and `mix test test/ai_control/gateway/live_ner_test.exs
--include live_ner` against an isolated PostgreSQL test database. The live gateway
tests disable the semantic guard only in their temporary
organizations. A controlled backend inspects the redacted input and supplies
synthetic Polish names, addresses and escaped tool arguments to the real NER
output pipeline.

## Tool execution firewall (steps 12A–12B)

The closed tool catalog, verified-agent requests, policy ACL, operator resource
grants, and tenant-isolated demo adapters are available under `AiControl.Tools`.
See [the tool sandbox guide](docs/tools.md) for supported operations, configuration,
examples, and security tests. Demo files, database rows, mailbox, and commands use
in-memory resources; HTTP uses exact URLs and operator-pinned IPs through Req.
The public `POST /v1/tool_calls` endpoint requires an agent Bearer key and UUID
`Idempotency-Key`. Its full firewall filters input and output, commits budgets and
audit before effects, and records content-free durable execution states. Configure
`TOOLS_SANDBOXES` with operator grants and stable context UUIDs before use. Duplicate
keys return 409 with ID/state without replaying effects or results. See the
[Step 12B acceptance](docs/acceptance/step12b.md) for verification and limits.


## MCP gateway (step 13)

`/mcp` exposes the governed sandbox through MCP 2025-11-25 Streamable HTTP with
JSON responses and existing Bearer agent keys. **API keys → Connect with MCP**
shows the public endpoint and connection headers. Tools and authorized virtual
files use the existing execution firewall, output filtering, durable tool-call
budget and audit. Clients manage key-bound sessions and need no extra idempotency
header. See [MCP setup, limits and smoke test](docs/mcp.md).

## Tests and quality checks

```sh
mix test          # Create/migrate the test database and run ExUnit
mix format        # Format Elixir with Quokka and templates with the HEEx formatter
mix check         # Check formatting, compilation warnings, lockfile, Credo, JS and Elixir tests
mix precommit     # Format first, then run mix check
mix dialyzer      # Analyze types; the first run builds PLTs and takes longer
mix security      # Scan Phoenix with Sobelow and audit dependencies with MixAudit
mix check.all     # Run mix check, Dialyzer, and security checks
```

`check`, `precommit`, `dialyzer`, `security`, and `check.all` select `MIX_ENV=test`
automatically. Tests require PostgreSQL; standalone formatting, Credo, Dialyzer,
and security scans do not. `mix security` needs network access to fetch the
current vulnerability database. Credo runs in strict mode. Sobelow fails for
findings with medium or high confidence. Dialyzer stores its ignored PLTs in
`priv/plts/`; generated files and tools are excluded from Git and the tools are
not runtime dependencies of production releases.

Quokka's configuration reordering is disabled to preserve configuration order
and the placement of comments in Phoenix config files.

Build frontend assets separately with:

```sh
mix assets.setup
mix assets.build
```

## Continuous integration

GitHub Actions runs on pull requests, pushes to `main`, and manual dispatches.
Checks are Quality, Tests, Dialyzer, Security, and Phoenix, NER, Qwen and tokenizer container. CI uses Ubuntu 24.04,
reads the pinned BEAM versions from `.tool-versions`, starts PostgreSQL 17 for
tests, and builds frontend assets. The Tests job also installs the pinned Node.js
version. Dependencies, compiled files, and PLTs are cached per platform and tool
version; a run without a cache builds them from scratch. Actions are pinned to
commit SHAs. The container job builds the production image, runs Python unit/live
NER/Qwen/tokenizer fixtures, tests the release transport, health, bootstrap and all four process failures,
and uploads Linux latency/memory measurements. No image is published or deployed.

Dependabot checks Mix dependencies and GitHub Actions every Monday at 09:00
Europe/Warsaw. Minor and patch updates are grouped separately for each ecosystem;
major updates remain separate. Each ecosystem has a limit of five open update
pull requests.

## Phoenix documentation

- [Phoenix guides](https://phoenix.hexdocs.pm/overview.html)
- [Phoenix deployment guides](https://phoenix.hexdocs.pm/deployment.html)

## Durable budgets and usage (step 9)

Apply `mix ecto.migrate` before starting the new application; releases run this
through `AiControl.Release.migrate/0`. Migration
`20261003220124_create_durable_budgets` adds hourly buckets, reservations,
workflow counters and execution deduplication. Existing policy schemas and
hourly units are unchanged. An empty form field / YAML `null` means no limit;
zero denies new admission or reservation. Policy activation, rollback, cache
loss and restart never reset counters. Budget state requires `budgets.read`
and current agent grants. The separate Budgets page remains step 11.

After validation and agent/model authorization, admission locks the organization
then its organization and agent buckets in one transaction. An admitted chat
counts once even if input guards, token reservation, a downstream service or
audit subsequently reject it. Invalid payloads, invalid credentials, revoked
access and hourly request refusals do not count. The pre-authentication IP
limiter uses `remote_ip`, independently of the existing actor limiter and active
worker slots. Forwarded headers do not select the IP counter.

Every request receives the operator output cap (1024 by default) when
`max_tokens` is missing. After redaction and RAG augmentation, the provider prepares
the complete API request: messages, history, tools, disabled thinking and output
limit. The same request is counted and sent to DeepSeek. PostgreSQL reserves input
plus maximum output against organization, agent and workflow limits before dispatch.
Admission preserves identity, request UUID, model, policy snapshot, UTC window and
configured price. Access is rechecked before persisted dispatch. Generation is never retried.

The private FastAPI sidecar uses **deepseek-recipe 0.1.1**, `DeepseekV41Encoding`
and the official V4.1 tokenizer pinned by commit, SHA-256 and size in
`sidecar/tokenizer/models.v1.json`. It loads offline, exposes `/count` and `/ready`,
rejects non-text input, and has no access logs or inference weights. The Elixir
client verifies recipe version, encoding and tokenizer hash. A required counter
failure blocks generation; there is no approximation. Live acceptance compares
counts with API `usage.prompt_tokens` for Polish, history, RAG and tools. Changing
the served API model can invalidate equivalence even when `/models` still lists
`deepseek-flash`; repeat this acceptance before claiming hard limit qualification.
Without a hard limit and outside a workflow, chats need no counter.

Streaming asks for usage and accepts DeepSeek's final choice frame containing
`finish_reason`, null delta fields and usage together. Usage is settled before
output controls and delivery; filtered/aborted terminal responses with valid
usage are also charged. Unknown usage retains the existing uncertain reservation.
Buffered public SSE releases content only after successful output controls.

Default conservative estimated rates are USD 0.30/M input and 1.20/M output.
Costs use operator rate snapshots, exclude cache/off-peak discounts and are labeled
`operator_estimate` in audit/report data. Override them with `GATEWAY_PRICES`.
[DeepSeek pricing](https://api-docs.deepseek.com/quick_start/pricing/)

For local development (use a separate venv if needed):

```sh
python3.11 -m venv .venv
.venv/bin/pip install -r sidecar/tokenizer/requirements.lock
.venv/bin/python sidecar/tokenizer/models.py download sidecar/tokenizer/models
HF_HUB_OFFLINE=1 .venv/bin/python -m uvicorn service:app \
  --app-dir sidecar/tokenizer --host 127.0.0.1 --port 8002 \
  --no-access-log --log-level critical
```

Build/setup downloads the pinned tokenizer artifact; running requests never
download artifacts. License and provenance are in `sidecar/tokenizer/`.

Valid numeric model usage is settled before response-content validation and
output filtering, including later output/audit failures. Equal repeat settlement
is a no-op; contradictory settlement is rejected. At 5000 tokens, a 4000-token
reservation excludes another 4000-token reservation; actual usage 2200 returns
1800. Actual overrun is charged in full and marked in evidence. The original
UTC hour owns the entire lifecycle even if completion crosses midnight. Hourly
request/token refusals return distinct `429` codes and `Retry-After` to the next
UTC hour. Accounting failure returns `503`.

Confirmed unsent work (`admitted`/`reserved`) releases its tokens. Any timeout,
cancellation or worker death after the durable dispatch marker retains the full
reservation as `uncertain`; even a transport connection failure after that
marker is conservative. Startup recovery releases unsent receipts and marks
persisted dispatches uncertain. TTL never refunds potentially generated tokens.
Without a token limit, unknown usage has no upper bound: an unresolved unbounded
receipt prevents enforcing a newly activated token limit in that same hour.
Later hours use independent counters. **Run one application instance per
database during this MVP**: startup recovery assumes other workers are stopped.
Database transactions serialize concurrent requests; coordinated recovery across
multiple live instances requires a deployment lease in a later change.

Reconcile only with independently verified operator evidence. From a controlled
application console, pass the freshly authenticated organization scope to:

```elixir
{:ok, bucket} = AiControl.Budgets.state(scope) # or state(scope, agent_id)
AiControl.Budgets.reconcile(scope, reservation_id, :not_sent)
AiControl.Budgets.reconcile(scope, reservation_id, %{
  "prompt_tokens" => 2000, "completion_tokens" => 200, "total_tokens" => 2200
})
```

`budgets.manage` and current tenant/agent grants are required. Reconciliation
and its audit entry commit atomically; audit failure leaves the hold intact.
`not_sent` requires evidence of no generation, not merely elapsed time.
Read state may use a one-second ETS cache; enforcement always uses PostgreSQL.

Operator prices are decimal **strings** per million input/output tokens, with
an uppercase three-letter currency. For example:

```sh
export GATEWAY_PRICES='{"deepseek-flash":{"currency":"USD","input_per_million":"0.30","output_per_million":"1.20"}}'
```

These example rates are operator choices, not inferred local-model prices.
Decimal accounting stores a snapshot and rounds the final amount to 12 decimal
places. Missing prices mean `not configured`; configured prices with unknown
usage mean `unavailable`. Confirmed unsent work has zero cost when rates are
configured. This
step reports costs; it does not add currency-based quota enforcement. Optional
validated guard usage is retained separately in decision evidence; unavailable
measurements remain `null` and never add to target-model token counters.
Telemetry separates `budget_admission`, `budget_reservation` and
`budget_settlement` from generation. Audit includes safe identifiers,
reservation status, usage, overrun and cost, without prompt or response text.

Run acceptance with:

```sh
mix precommit
mix assets.build
PYTHONPATH=sidecar/tokenizer .venv/bin/python -m unittest discover -s tests/tokenizer
mix test test/ai_control/gateway/live_deep_seek_test.exs test/ai_control/gateway/live_budget_tokenizer_test.exs test/ai_control/gateway/live_stream_test.exs test/ai_control/gateway/live_knowledge_test.exs test/ai_control/workflows/live_workflow_test.exs test/ai_control/approvals/live_test.exs --include live_models
bash docker/smoke ai-control:deepseek
```

`docs/acceptance/step9.md` retains the historical Ollama results. DeepSeek acceptance
requires a fresh live count comparison; those earlier counts do not qualify this API integration.

## Background work, reports and gateway tests (Step 16)

Apply the new Ecto migration before starting the application. Oban runs reports,
JSONL exports, separate audit summaries, local signature imports and isolated
gateway tests. Primary decisions and audit writes remain synchronous.

Configure a dedicated synthetic runner database and the release executable:

```sh
export TEST_RUNNER_DATABASE_URL='ecto://postgres:postgres@localhost/ai_control_runner'
export TEST_RUNNER_EXECUTABLE='/app/bin/ai_control'
```

The database must differ from the application database; missing configuration
disables Tests execution. The child migrates its own database and sends real
loopback HTTP requests through the gateway. Controlled covers 15 deterministic
gateway/budget/tool scenarios. Live additionally requires the pinned local
models and Polish benchmark services. Synthetic results do not qualify models
for production or complete Step 11B. Processes share hardware and local services.

Tests requires `tests.read`/`tests.run`; Reports uses `events.read`, exports add
`events.export`, and budget-bearing reports add `budgets.read`. Access is checked
again during work and download. Auxiliary artifacts/results expire after seven
days; terminal run metadata after 30 days. Runner database fixtures require
separate operator maintenance.

`GUARD_FEED_PACKAGES` maps operator package IDs to local paths and SHA-256 values.
Signature refresh publishes immutable tenant candidates; activation requires a
new v5 policy and the existing revision transaction. Imported packages cannot
execute code. Existing policy schemas and HTTP export remain supported.

See [the Step 16 runbook and acceptance](docs/acceptance/step16.md) for package
format, configuration, migration, retention, validation and the remaining Live
and Linux container acceptance. The implementation is submitted as a draft
until those checks are observed.

## Knowledge, RAG and explicit memory (step 18)

Knowledge requires an explicitly activated schema v5 policy. Upgrade a draft, enable
`knowledge.enabled`, choose allowed source kinds/trust levels and, for memory writes,
set `knowledge.memory_write_enabled`. Both switches default to false. Existing v1–v4
policies and their checksums retain their existing behavior. v5 chooses
`ner_model_set` (`pl-nkjp.v1` or `pl-nkjp.v2`); v2 reuses the pinned Stanza weights
and entity mapping and extends contextual Polish address rules.

The Knowledge workspace has Documents and Memory tabs, checked-text search,
agent filtering, detail and separate creation/edit forms. It accepts pasted text
and UTF-8 `.txt`/`.md` uploads. Sharing explicitly grants read access to selected
agents in the same organization. The owner retains management; an authenticated
agent can create, update or delete only its own memory and cannot elevate trust.
Users need `knowledge.read` / `knowledge.manage` and corresponding agent assignments.
Management requires owner access and sharing additionally requires recipient access.

Session JSON CRUD uses `/organizations/:organization_id/knowledge/resources[/:id]`
with CSRF protection. API-key endpoints are:

- `POST /v1/knowledge/search`: `{"query":"support","sources":["document","memory"],"top_k":5}`.
- `GET /v1/memory` and `GET /v1/memory/:id`: checked memory, including explicitly shared entries.
- `POST /v1/memory`: `{"title":"Response preference","content":"Prefer concise answers."}`.
- `PATCH /v1/memory/:id`: changed text plus integer `revision` from the last read.
- `DELETE /v1/memory/:id`: JSON body `{"revision":1}`. Deletion removes indexed text too.

Session creation additionally requires `kind` and `owner_agent_id`; optional
`shared_agent_ids`, `trust_level` and `source_reference` are checked server-side.
Organization and creator identity never come from request data. CRUD responses use
`{"data":...}` and `Cache-Control: no-store`; metadata lists return 50 entries per
page (`?page=1`). Search returns complete checked resources, five by default and
at most ten, ordered by lexical rank then UUID after access filtering.

Chat Completions accepts optional gateway-only context:

```json
{"model":"deepseek-flash","messages":[{"role":"user","content":"What are the support hours?"}],"context":{"query":"support","sources":["document","memory"],"top_k":5}}
```

RAG requires a final user message. The gateway consumes `context` and inserts an
explicit retrieved-data user message immediately before that final message. Query,
sources and the assembled prompt pass the retained policy snapshot. The model
receives no `context` extension. Exact token counting and reservations include the
final redacted RAG prompt; ACL, identity and revisions are rechecked before dispatch
and before returning output. Memory is never saved automatically from conversations.

Limits are UTF-8 bytes: document 64 KiB, memory 16 KiB, query 2 KiB and retrieved
context 128 KiB. Overflow fails without truncation. Fixed errors use 400/413 for
invalid/oversized input, 403 for denial or unavailable resources, 409 for a stale
revision, 429 for limits and 503 for required guard/audit unavailability.

PostgreSQL `simple` full-text search uses `websearch_to_tsquery`, `ts_rank` and a GIN
index ([PostgreSQL controls](https://www.postgresql.org/docs/current/textsearch-controls.html)).
It has no embeddings, semantic matching or Polish stemming. PDF and URL fetching
are unsupported. `untrusted` and `internal` describe provenance/access; both are
scanned. Redaction cannot guarantee complete PII detection and does not encrypt
storage, backups or logs. Audit/Events retain only validated source UUIDs, revisions,
kinds, trust and policy, never titles, content, provenance strings or search queries.

Run `mix ecto.migrate` before enabling Knowledge. See
[Step 18 acceptance](docs/acceptance/step18.md) for results and remaining acceptance.

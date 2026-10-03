# AiControl

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

| Profile | Personal data | Secrets / exploits | Injection threshold | Semantic guard |
| --- | --- | --- | --- | --- |
| Relaxed | redact | block | 0.9 | optional |
| Balanced | redact | block | 0.8 | required |
| Strict | block | block | 0.65 | required |

Deterministic guards default to required on input and output; semantic analysis
defaults to input. Explicit rule and guard fields override profile defaults.
The initial policy allows `qwen3.5:4b` and all active agents in the requesting
organization. Budgets start unconfigured. Organization and agent requests/tokens
per UTC hour and workflow tool calls can be configured now; budget accounting
and enforcement arrive in step 9. Step 7 connects deterministic guards and NER;
the complete output filtering acceptance remains in step 8.

Import [the example policy](priv/policies/balanced.yaml) by pasting YAML or uploading
one file. Both schema versions accept one UTF-8 document up to 64 KiB. Unknown fields,
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
{:ok, snapshot} = Policies.snapshot_for_request(verified_principal, %{model: "qwen3.5:4b"})
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
closed fields and rejects raw payloads and exceptions. Dashboard, export,
and retention are scheduled for later roadmap steps.

## LLM gateway

The gateway provides authenticated `POST /v1/chat/completions` and `GET /v1/models`.
Bearer API keys are bound to an organization and agent. Trusted application callers
can use `AiControl.Gateway.chat(scope, params, agent_id: agent_id)`; current `ai.use`
and both resource grants are required. Client identity fields are rejected.

The operator catalog is empty by default. Configure exact model names and full
Ollama manifest digests. Registering a model makes it selectable in invitation and
member access forms; grants and effective organization/agent policies still apply.
The public catalog exposes no backend URL or digest.

```sh
ollama serve
ollama pull qwen3.5:4b
# Verify /api/tags against this checked-in manifest before enabling access.
export GATEWAY_MODELS="$(cat priv/models/ollama-demo.json)"
export OLLAMA_BASE_URL=http://127.0.0.1:11434
mix phx.server
```

The recorded demo digest is
`2a654d98e6fba55d452b7043684e9b57a947e393bbffa62485a7aac05ee4eefd`
(Ollama 0.35.1, qwen3.5:4b, Q4_K_M). A different installed manifest is rejected;
updating the catalog is an explicit operator action.

Supported requests contain text `messages`, function `tools`, assistant
`tool_calls` history and tool results. Optional controls are `tool_choice`,
`temperature`, `top_p`, `max_tokens` (1–32768), `seed`, `stop`, `n: 1` and
`stream: false`. Images, audio, streaming, unknown fields and unsupported formats
return `400`. The gateway returns one assistant choice and validated token usage.
It passes tool proposals through security assessment; it does not execute tools.
Provider reasoning and unknown response fields are discarded. Ollama reasoning
is disabled by default (`OLLAMA_REASONING_EFFORT=none`); `default`, `low`, `medium`
and `high` are operator choices. See [Ollama's reasoning mapping](https://github.com/ollama/ollama/blob/v0.35.1/openai/openai.go).

```sh
curl http://localhost:4000/v1/chat/completions \
  -H "Authorization: Bearer $AI_CONTROL_API_KEY" \
  -H 'Content-Type: application/json' \
  -d '{"model":"qwen3.5:4b","messages":[{"role":"user","content":"Describe Kraków in one sentence."}],"stream":false,"max_tokens":128}'
```

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
adapters are connected. NER requires an explicitly activated v2 policy; the
semantic adapter remains step 10. Missing required adapters return
`503` and never call the LLM. A bare Ollama installation is not a ready protected
service. Optional adapters may fail only under an explicit policy; their failure
is retained in the assessment evidence.

| Operator variable | Default |
| --- | --- |
| `GATEWAY_INPUT_BYTES` | 1048576 (1 MiB, raw JSON before buffering) |
| `GATEWAY_RESPONSE_BYTES` | 4194304 (4 MiB, including error bodies) |
| `GATEWAY_CONNECT_TIMEOUT_MS` | 2000 |
| `GATEWAY_LLM_TIMEOUT_MS` | 120000 (metadata and generation together) |
| `GATEWAY_GUARD_TIMEOUT_MS` | 10000 |
| `GATEWAY_READINESS_TIMEOUT_MS` | 5000 |
| `GATEWAY_LLM_SLOTS` | 1 |
| `GATEWAY_GUARD_SLOTS` | 2 |
| `GATEWAY_REQUESTS_PER_MINUTE` | 60 per actor in an organization |

The ingress counter is local Hammer/ETS and is shared by all keys of one agent;
restart resets it. Authenticated rejected requests count too. Saturated slots return
`429` immediately with `Retry-After`; timeout, cancellation and owner death stop the
supervised worker and free the lease. Generation has no retries or redirects, and
response reception stops at its size cap. Durable budgets are step 9.
`400/413` indicate invalid/oversized input, `403` policy denial, `429` overload,
`502` unusable backend responses, `503` unavailable security/audit/model services
and `504` backend timeout. Error responses use fixed text and a server request ID.

`GET /health` is liveness. `GET /ready` is bounded readiness of the database,
effective active policies, pinned backend models and required guard adapters,
returning only `200 {"status":"ready"}` or `503 {"status":"not_ready"}`. Readiness
includes the platform default and every active organization's effective policy.

Run the real-model acceptance separately from ordinary mock-based CI:

```sh
# Use an isolated PostgreSQL instance/database partition.
PGPORT=55438 MIX_TEST_PARTITION=step6live mix test \
  test/ai_control/gateway/live_ollama_test.exs --include live_models
```

The acceptance test creates a dedicated organization, activates an explicit local
policy with unavailable guards disabled, and rolls its data back. It checks the
pinned real model, authenticated catalog, a Polish response and both stage audits.
It never changes the platform balanced policy. Ordinary `mix test` excludes the
`:live_models` tag.

The remaining MVP execution order after Step 7 acceptance is **8 → 9 → 10 → full 12 → 11**.
The Polish semantic benchmark and the complete tool ACL retain their acceptance criteria in
[the implementation roadmap](AI_CONTROL_LAYER_IMPLEMENTATION_PLAN.md). Granite
remains step 14; RAG, memory and further PII work remain step 18.

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
allowed_models: [qwen3.5:4b]
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
unique tool identifiers and defaults to empty. Step 12A enforces this list in the
tool core and sandbox; production execution remains in step 12B.
The separate Signatures dashboard remains step 11. Existing output plumbing can
run these adapters, while the complete output-contract acceptance is step 8.

### One container on Coolify

Use Coolify's [Dockerfile build pack](https://coolify.io/docs/applications/builds/dockerfile)
with `/Dockerfile`, build context `/`, port **4000**, and your HTTPS domain.
PostgreSQL and Ollama are separate services reachable from the container.
Phoenix binds `0.0.0.0:4000`; NER binds only `127.0.0.1:8001` and is not published.
Models are fetched and checked at image build time, then verified and loaded
offline on startup. The non-root container uses `tini` and a supervisor script
that forwards termination, reaps children and exits when either service fails.
Allow roughly 2 GiB memory initially and measure on the deployment CPU;
[acceptance measurements](docs/acceptance/step7.md) are synthetic smoke figures.

Set these runtime variables using Coolify's secrets UI:

| Variable | Value |
| --- | --- |
| `DATABASE_URL` | `ecto://USER:PASSWORD@POSTGRES_HOST/DATABASE` |
| `SECRET_KEY_BASE` | A fresh secret generated with `mix phx.gen.secret` |
| `AUDIT_FINGERPRINT_KEY` | At least 32 random bytes encoded as base64 |
| `AUDIT_FINGERPRINT_KEY_ID` | Rotation ID, default `v1` |
| `PHX_HOST` | Public hostname without scheme |
| `OLLAMA_BASE_URL` | Reachable external Ollama HTTP origin |
| `GATEWAY_MODELS` | JSON map of model names to verified full SHA-256 digests |
| `NER_BASE_URL` | Keep `http://127.0.0.1:8001` for this container |
| `NER_CPU_THREADS` | CPU inference threads, default `2` |
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
Phoenix `/health` and NER `/ready`; Coolify can use that Dockerfile healthcheck.
Gateway `/ready` also checks every required security control and can remain
**503 until step 10** supplies semantic analysis. Health is not permission to
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
test disables the unimplemented semantic guard only in its temporary organization
and uses a backend stub to inspect the actual redacted request.

## Tool firewall core (step 12A)

The closed tool catalog, verified-agent requests, policy ACL, operator resource
grants, and tenant-isolated demo adapters are available under `AiControl.Tools`.
See [the tool sandbox guide](docs/tools.md) for supported operations, configuration,
examples, and security tests. Demo files, database rows, mailbox, and commands use
in-memory resources; HTTP uses exact URLs and operator-pinned IPs through Req.
Production execution with budgets, guards, audit, result filtering, and
`POST /v1/tool_calls` remains in step 12B.

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
Checks are Quality, Tests, Dialyzer, Security, and Phoenix and Polish NER container. CI uses Ubuntu 24.04,
reads the pinned BEAM versions from `.tool-versions`, starts PostgreSQL 17 for
tests, and builds frontend assets. The Tests job also installs the pinned Node.js
version. Dependencies, compiled files, and PLTs are cached per platform and tool
version; a run without a cache builds them from scratch. Actions are pinned to
commit SHAs. The container job builds the production image, runs Python unit/live
NER fixtures, tests the release transport, health, bootstrap and process failures,
and uploads Linux latency/memory measurements. No image is published or deployed.

Dependabot checks Mix dependencies and GitHub Actions every Monday at 09:00
Europe/Warsaw. Minor and patch updates are grouped separately for each ecosystem;
major updates remain separate. Each ecosystem has a limit of five open update
pull requests.

## Phoenix documentation

- [Phoenix guides](https://phoenix.hexdocs.pm/overview.html)
- [Phoenix deployment guides](https://phoenix.hexdocs.pm/deployment.html)

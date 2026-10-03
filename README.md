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
export AUDIT_FINGERPRINT_KEY="$(openssl rand -base64 32)"
export AUDIT_FINGERPRINT_KEY_ID=v1
mix setup
mix phx.server
```

Keep the audit key in your local environment or secret manager and reuse it on
restart. Generating a new key changes fingerprints. Development and production
require a separate base64-encoded key with at least 32 random bytes; tests use
a deterministic key configured only in `config/test.exs`. When rotating the key,
also change `AUDIT_FINGERPRINT_KEY_ID`. Historical records retain their key IDs.

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
`["*"]` selector for all organization resources of that type. The member editor
currently offers the all-resource selectors. Admin edits preserve grants they
do not have permission to manage.

`AiControl.Organizations.Access.authorize/3` refreshes database access before
checking capabilities and resources. Concrete selectors require an ownership
adapter implementing `AiControl.Organizations.ResourceResolver`, configured
under `:ai_control, :organization_resource_resolver`. Without that adapter,
specific assignments and AI resource checks fail closed. Agent/model registries,
policy restrictions, and runtime enforcement connect in roadmap steps 3, 5,
and 6; this step supplies their access model and authorization boundary.

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
Agent and API-key UUIDs currently have no dependency on their future tables.

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
guards arrive in later steps. Policy persistence, activation, profiles, YAML,
and cache arrive in step 5.

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
or depending on future policy storage. Writes are synchronous: `evaluate_and_audit/3` returns
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

## Tests and quality checks

```sh
mix test          # Create/migrate the test database and run ExUnit
mix format        # Format Elixir with Quokka and templates with the HEEx formatter
mix check         # Check formatting, compilation warnings, lockfile, Credo, and tests
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
The four checks are Quality, Tests, Dialyzer, and Security. CI uses Ubuntu 24.04,
reads the pinned BEAM versions from `.tool-versions`, starts PostgreSQL 17 for
tests, and builds frontend assets. The Tests job also installs the pinned Node.js
version. Dependencies, compiled files, and PLTs are cached per platform and tool
version; a run without a cache builds them from scratch. Actions are pinned to
commit SHAs.

Dependabot checks Mix dependencies and GitHub Actions every Monday at 09:00
Europe/Warsaw. Minor and patch updates are grouped separately for each ecosystem;
major updates remain separate. Each ecosystem has a limit of five open update
pull requests.

## Phoenix documentation

- [Phoenix guides](https://phoenix.hexdocs.pm/overview.html)
- [Phoenix deployment guides](https://phoenix.hexdocs.pm/deployment.html)

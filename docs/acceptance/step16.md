# Step 16: durable jobs, reports and isolated gateway tests

Acceptance date: 2026-10-04. Implementation is reviewable; the plan checkbox stays
open until successful Live model acceptance and the extended Linux container
smoke have been observed. These gaps require a draft PR.

## Deployment and configuration

Apply `20261004012954_create_background_jobs_and_signature_sets.exs` before
starting the updated application. It installs Oban's PostgreSQL schema v14,
auxiliary run/chunk/manifest/scenario tables and immutable organization signature
sets. Development uses `mix ecto.migrate`; a release uses:

```sh
bin/ai_control eval 'AiControl.Release.migrate()'
```

Oban is pinned to 2.24.1 in the lockfile. Queues are `reports: 2`, `tests: 1`,
`maintenance: 1`; workers allow at most three attempts. Test configuration uses
Oban manual mode. A run and its job commit together. A database advisory lock and
partial unique index deduplicate equivalent active requests for the same actor.
Job arguments contain only `run_id`, `organization_id` and `user_id`; validated
filters and suite choices belong to the run record. Transient failures retry,
while unavailable runner configuration, invalid feeds and revoked access stop
the work with a fixed error code. Terminal Oban jobs are reconciled with run
state, including worker death outside the callback.

Create a **dedicated, disposable database**, different from the application
database, then configure the operator-owned runner executable:

```sh
createdb ai_control_runner
export TEST_RUNNER_DATABASE_URL='ecto://postgres:postgres@localhost/ai_control_runner'
export TEST_RUNNER_EXECUTABLE='/app/bin/ai_control'
```

The example credentials are for local development. The database URL accepts
`ecto`, `postgres` or `postgresql`; the only query option is `ssl=true` or
`ssl=false`. Database names must match the bounded identifier grammar and must
differ from the parent database name, including after URL decoding. A same-name
database on another host is conservatively refused. Missing configuration or an
absent executable makes the runner unavailable. In Mix development only, the
fixed child command can use the current Mix executable without setting
`TEST_RUNNER_EXECUTABLE`. Releases require the configured release executable.
No commands, URLs, prompts or connection strings come from the panel.

The child starts a separate BEAM VM, migrates only the dedicated database,
creates its synthetic organizer, organizations, agents, keys and policies, and
sends actual Req HTTP requests to its loopback gateway. Controlled mode uses
controlled generation/token counting alongside real deterministic guards,
PostgreSQL accounting and the virtual tool sandbox. Its 15 cases cover allow,
input/output redaction, secrets/exploits, required-guard failure, request/token
limits, accounting after output denial, tool execution/ACL/output/budgets,
request policy snapshots and revoked keys.

Live mode adds a real local-model gateway request and both Qwen/Prompt Guard
measurements of the existing Polish dataset. It requires NER, semantic, Prompt
Guard and tokenizer readiness and pinned Ollama digests. Missing models or
incomplete IPC cannot produce a completed successful run. Each benchmark result
includes the dataset checksum and provider, plus safe expected/observed flags.
Scenario failures are retained as failed/error cases rather than discarded.
Retries replace attempt-local projections and verify the complete expected case
ID set before publishing the artifact.

Cancellation or revoked access closes the child's input port. EOF, parent death,
a lost 30-second lease and the two-hour deadline terminate the child; the Oban
worker timeout allows a five-minute margin. Only validated case identifiers,
status, duration and allowlisted counters/flags/checksums cross IPC. Other child
output is discarded. Prompt, response and connection settings are excluded from
results and job arguments; the child runs with a reduced environment and fresh
synthetic cryptographic settings.

Process/database isolation shares CPU, memory, disk and local model services
with the parent. It is not an OS isolation boundary. Run only the closed shipped
suite; tools use synthetic virtual resources. Dedicated runner database contents
accumulate synthetic fixtures and primary audit/accounting data. Parent cleanup
does not erase that database: operators must reserve it for this purpose and
recreate/maintain it separately while no runner is active. Existing single
application-instance budget recovery assumptions still apply; the tests queue
serializes runners on this instance.

## Reports, authorization and retention

Every start, batch/checkpoint, refresh and download rechecks the actor's current
membership, organization status and content permissions. Tests reads/downloads
require `tests.read`; execution and cancellation additionally require
`tests.run`. Reports need `events.read`; exports additionally need
`events.export`. Budget-bearing reports remain hidden and unavailable after
`budgets.read` is removed. Feed reads/imports require `signatures.read` and
`signatures.manage`; selecting and activating a candidate requires existing
policy permissions. PubSub carries only a change notification; LiveViews fetch
again after fresh authorization. The authenticated download route validates
organization ownership and permissions between chunks, and sends `no-store`
with `X-Artifact-SHA256`.

Audit export freezes the requested time interval at enqueue and the set of
committed events at worker start, using one durable ordered manifest. Later
commits do not join that manifest. Batches contain at most 500 events; a chunk
and its cursor commit together. Retry reuses committed chunks and positions.
The existing serializer/JSONL envelope and final `export_complete` marker are
preserved. Only a completed artifact with record count and SHA-256 is published.
The synchronous Events HTTP export remains available.

Metrics reports and separate audit summaries use the current dashboard
definitions, allowed audit metadata and optional budget projection. They include
the selected range, generated time and latency unit (microseconds); costs retain
the operator's price/currency snapshots. Budget state is the current UTC hourly
window, explicitly identified in the artifact, rather than reconstructed for
the selected audit interval. Generated report chunks are reused on retry.
Reports use PostgreSQL READ COMMITTED so revoked access remains visible between
queries: concurrent audit commits can appear in different aggregate queries.
They are fixed-range operational reports, not a single transaction snapshot of
every aggregate. Export manifests provide the stronger frozen event set.
Enrichment never rewrites source decisions or creates generated prose.

Artifacts, scenario results, export manifests and derived result maps expire
seven days after completion/failure/cancellation. Reads enforce expiration by
the clock even before cleanup. Hourly maintenance physically deletes auxiliary
content and marks completed artifacts expired. Terminal run metadata is deleted
after 30 days from creation; active work is excluded. Primary audits, budgets,
policies and immutable feed sets are untouched. History screens show the latest
50 runs; retained older metadata is not paginated in this UI.

Telemetry exposes bounded queue/state/status labels for queue depth, job count,
errors, wait and duration. Ten-second polling also repairs orphan run status.
Prometheus/Grafana integration and optional PolicyReload are outside this change.
Queues share the application database and hardware; pausing/stopping them does
not change synchronous gateway decisions or their required audit writes.

## Operator signature packages

The operator maps closed package identifiers to local regular files and their
expected SHA-256. Mount an operator-owned package directory and configure paths
in that directory; the panel selects only the identifier:

```sh
export GUARD_FEED_PACKAGES='{"operator.v1":{"path":"/app/feeds/operator.v1.json","sha256":"REPLACE_WITH_64_LOWERCASE_HEX_CHARACTERS"}}'
```

Example package (checksum is over the exact file bytes):

```json
{
  "schema_version": 1,
  "catalog_version": "operator.v1",
  "origin": "Operator-maintained signatures",
  "rules": {
    "exploit.operator.v1": {
      "matcher": "literal",
      "literal": "danger.literal",
      "unsafe": "Unsafe synthetic invocation",
      "safe_alternative": "Use the safe operation"
    }
  }
}
```

Verify with `shasum -a 256 /app/feeds/operator.v1.json`. Packages are limited to
1 MiB, 1–256 rules, bounded machine-readable IDs and 256-byte origin/literal/help
strings. Unknown fields are refused. Supported matchers are `pickle`, `yaml`,
`eval`, `shell` (existing built-ins) and escaped literal matching. The format
accepts no executable code or arbitrary regex. Rules compile before publication.
Dense imported matches above the bounded 1024-match scan fail closed instead of
silently truncating findings. Operator file integrity and permissions remain an
operational responsibility.

Refresh publishes an immutable organization candidate `local.<sha256>`. Reusing
the same version/checksum is idempotent; conflicting bytes under that version
are refused. A PostgreSQL trigger rejects updates/deletes. Candidates survive
process restart and are resolved from durable storage without a mutable catalog
cache. Refresh never activates a policy. Upgrade a policy draft to schema v5,
select the candidate and activate through the existing expected-revision
transaction. A held request keeps its policy/catalog snapshot. Invalid packages
leave active protection unchanged. Schemas v1–v4 preserve their built-in meaning
and checksum behavior; global policies cannot select another tenant's candidate.

## Observed acceptance

All local checks used disposable PostgreSQL 17 databases on port 55416, not the
application's normal database service.

| Check | Result |
| --- | --- |
| `mix precommit` with dedicated runner URL | 549 passed, 10 excluded local-model tests; formatting, warning-free compilation, lockfile, Credo and JS checks passed |
| `mix assets.build` | Passed |
| `mix dialyzer` | Passed, zero type errors |
| `mix security` | Passed configured medium threshold; dependency audit reports no vulnerabilities |
| Production release build and child executor | Passed; 15/15 Controlled HTTP cases, real audit/accounting/sandbox, parent fixtures isolated |
| Release child after parent input closes | Exit 5 after the first case; parent-loss termination observed |
| Runner cancellation integration | Passed; stops after first validated case and does not publish an artifact |
| Gateway with Oban supervisor stopped | Allow and fail-closed decisions and synchronous audit still pass |
| Concurrent equivalent submissions | Four committed concurrent callers share one run and one job |
| Export/retry/access/expiry/feed tests | Passed; 503-event batching, manifest resume excluding later commits, checksums, revocation, tenant isolation, immutable feed, activation/rollback and bounded scanning |
| LiveView DOM tests | Passed; grants, report downloads, background export and terminal empty state |
| Real browser acceptance | Controlled 15/15; generated metrics with budgets, audit summary, background export, candidate refresh and v5 draft selection; desktop/mobile and both themes, mobile keyboard interaction |
| Actual Live attempt | Unavailable as expected with missing local models; 15 Controlled cases retained, no false success or downloadable partial artifact |

Sobelow's low-confidence observations remain visible rather than suppressed:
the export SQL interpolates a server-derived placeholder number with all values
bound; feed paths come exclusively from operator configuration; extracted CLI
benchmark output paths are operator CLI parameters and the dataset path is
application-owned. Existing dashboard SQL, websocket configuration and policy
upload path observations also remain. No medium/high finding was reported.

The UI uses the existing English workspace components, paired HEEx templates,
streams and stable DOM IDs. Bounded visual verification and the independent
Impeccable review/documentation handoffs are recorded in
[step16-ui-review.md](step16-ui-review.md) and
[step16-design-documentation.md](step16-design-documentation.md).

## Remaining acceptance and limits

- Successful Live gateway + Polish benchmark requires all pinned local models
  and sidecars. It was not observed here. Controlled success exercises synthetic
  policies and providers; it does not qualify model accuracy or complete Step 11B.
- The extended `docker/smoke` now runs the isolated release suite against a second
  PostgreSQL database. Its Linux container execution and new CI run have not yet
  been observed locally; macOS production release execution was observed.
- Target-hardware latency/resource coexistence remains to be measured. Process
  isolation shares resources and is not a guarantee against resource contention.
- `.impeccable/design.json` was already stale. The one detector pass produced
  five incumbent typography advisories. Root design/product files and sidecar
  remain intact; an explicit `impeccable document` refresh is a separate task.

Reproduce automated isolated acceptance with:

```sh
TEST_RUNNER_DATABASE_URL='ecto://postgres:postgres@localhost/ai_control_runner' mix precommit
mix assets.build
mix dialyzer
mix security
MIX_ENV=prod mix release
bash docker/smoke ai-control:step16
```

The container image must be built with the existing offline model setup. The
separately gated Prompt Guard build/acceptance requirements from Step 11B still
apply.

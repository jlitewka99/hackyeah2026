# Step 18 acceptance — 2026-10-04

Implementation branch: `JL/step-18-rag-memory`, integrated with `origin/main`
at `e072dd0` (the independently completed MCP and buffered-streaming steps).
The implementation is reviewable;
Step 18 remains open and the pull request remains draft until all required acceptance
is complete.

## Delivered behavior

Tenant-bound checked documents and explicit owner memory, read-only sharing,
PostgreSQL lexical FTS, session/API-key CRUD, Knowledge LiveView, optional RAG Chat
Completions, opt-in policy v5 and Polish NER v2. Ownership/shares have composite
organization foreign keys. Writes and terminal audit commit together, revision
conflicts fail, reads rescan with the current policy, and RAG uses one snapshot.
Identity, resource ACL and revisions are checked before using/returning data and
before LLM dispatch. The final redacted prompt drives exact token reservations.
Audit JSONL excludes all source text and search queries.

Migration: `20261004012457_create_knowledge_resources.exs`. Apply with
`mix ecto.migrate`. New features default off; v1–v4 behavior/checksums remain supported.
`sidecar/ner/rules.v2.json` pins the unchanged weight-manifest checksum and entity
mapping. v1 sidecar requests remain valid; v5 may select v1 or v2.

## Local evidence

- Isolated PostgreSQL 17, Elixir 1.20.4 / OTP 29.1.1, Node 24.21.0 on macOS ARM64.
- Domain/API/LiveView tests cover organization isolation, forged UUIDs, private/shared
  memory, resource capabilities, revocation during scan, suspended agents, atomic
  audit rollback, redaction/current-policy recheck, revisions, removal from search,
  access-filtered ranking/pagination, CSRF, upload, blocked detail and ACL clearing.
- Gateway tests cover assembled context, injection in each source kind, secrets
  appearing only in composition, no downstream request after denial, required-guard
  failure, audit failure and augmented prompt accounting.
- Two tagged real-model acceptance tests passed: v2 NER → Qwen3Guard Gen → exact
  tokenizer → pinned local Qwen3.5 4B LLM with checked RAG and settled reservation;
  real Qwen rejects indirect injection in document and memory before any LLM request.
  Qwen guard revision: `fada3b2f655b89601929198343c94cd2f64d93cc`, CPU fp32, two threads;
  LLM digest: `2a654d98e6fba55d452b7043684e9b57a947e393bbffa62485a7aac05ee4eefd`.
  These are narrow synthetic cases, not a general injection-resistance guarantee.
- `PGPORT=55418 MIX_TEST_PARTITION=_step18 mix precommit`: 623 passed, 13 live
  tests excluded; formatting, warnings-as-errors compilation, lockfile checks,
  strict Credo and five JavaScript tests passed.
- `mix check.all`: passed, including the same suite, Dialyzer (zero errors),
  Sobelow at the configured threshold and dependency audit (no vulnerabilities).
  The low-confidence upload-path finding was reviewed: `File.read/1` receives
  only Phoenix's server-created temporary upload path, never a submitted path.
- `mix assets.build`: passed. `bash -n docker/smoke`: passed.
- NER Python tests: 5 passed with pinned real models enabled. Semantic service
  contract tests: 8 passed. Tagged real-model tests: 2 passed.
- Buffered SSE integration tests check retrieved context, final-prompt token
  reservation and revision denial before generation. Existing MCP and streaming
  tests remain passing; this change does not implement those separate steps.
- [NER benchmark](step18-ner-benchmark.json): 12 fixed synthetic fixtures, 60 timed
  samples; exact entity-type + UTF-8-span precision/recall both 0.7778 (14 TP,
  4 FP, 4 FN). All 90 detected-span UTF-8/redaction checks passed. p50 65.2 ms,
  p95 87.9 ms, cold load 6529.1 ms, peak RSS 1,066,532,864 bytes. False positives and
  misses remain; these measurements do not describe arbitrary production documents.
- UI capture matrix: list/detail/edit/new at 1440×1000 and 390×844 in both themes,
  plus empty/error/Memory mobile states. Native keyboard Tab from search reached the
  owner select; measured mobile document width equals viewport width (390 px).
  Policy v5 controls and blocked-source recovery were also captured in both
  viewport classes. [Finish review](step18-ui-review.md) owns visual acceptance.
  Preview data is synthetic; initial fixtures disable guards, while the blocked
  fixture enables the built-in PII guard. These captures do not qualify real-model
  enforcement. The reviewer scored both material fixes resolved and returned
  `ship` at that scope; the supplemental Knowledge/NER controls passed their
  limited visual review.

The real-model command is `PGPORT=55418 MIX_TEST_PARTITION=_step18 mix test
test/ai_control/gateway/live_knowledge_test.exs --include live_models`. Its isolated
services listen on NER 8018, tokenizer 8028, Qwen guard 8038 and Ollama 11438;
the pinned model files are required before running it.

## Remaining required acceptance and limitations

The local Docker daemon is unavailable. Linux release/container smoke and CI are
unverified locally; CI now also runs v2 NER transport/redaction and preserves its
benchmark. The separate open Step 11 MVP/Prompt Guard acceptance remains unchanged.
Step 18 must not be checked off until required container/CI acceptance is complete.

Only UTF-8 text/TXT/MD; no PDF, embeddings, URL retrieval, automatic conversation
memory, or steps 13–17/19. `simple` search is lexical with no Polish stemming or
semantic recall. Limits: document 64 KiB, memory 16 KiB, query 2 KiB, result count
5/default and 10/max, retrieved context 128 KiB; oversized operations fail without
truncation. Metadata lists are paged at 50. Trust never bypasses scanning. PII
redaction is incomplete and does not replace encryption of storage/backups.

Existing `.impeccable/design.json` drift from `DESIGN.md` is recorded and preserved;
an optional system refresh through `impeccable document` is outside scope.

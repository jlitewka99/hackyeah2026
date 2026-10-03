# Step 9 acceptance — durable budgets and usage

Recorded on 2026-10-03/04 on macOS arm64 (Apple M4), Elixir 1.20.4,
OTP 29.1.1, Python 3.11 and isolated PostgreSQL 17. No production data used.

| Check | Actual result |
| --- | --- |
| `mix precommit` | 383 ExUnit tests passed, 3 existing opt-in live tests excluded; formatting, warning-free compilation, lockfile, strict Credo and 3 JS tests passed |
| `mix assets.build` | Tailwind and esbuild passed |
| Tokenizer Python tests | 4 tests passed against the real checksum-verified offline tokenizer |
| Real Ollama budget acceptance | 1 test passed, four real generations in 29.4 seconds |
| PostgreSQL contention | 3 tests passed with independent unboxed connections; barrier verifies both competitors wait on PostgreSQL locks |
| Policies LiveView | DOM-ID form test preserves null, zero, organization/agent hourly limits and workflow values through activation |
| Browser review | 1365×900 and 390×844, light/dark; native summary activated with Enter, Tab enters request/token fields, visible focus; no horizontal page overflow |
| Container script syntax | `bash -n docker/start docker/smoke`, `sh -n docker/healthcheck` passed |
| Linux release/container acceptance | Pending GitHub CI; local Docker daemon unavailable |

## Real tokenizer agreement

Runtime Ollama **0.35.1**, `qwen3.5:4b` Q4_K_M digest
`2a654d98e6fba55d452b7043684e9b57a947e393bbffa62485a7aac05ee4eefd`.
Tokenizer revision and checksums are in `sidecar/tokenizer/models.v1.json`.
All requests used `max_tokens: 32`, an explicit local test policy disabling
unrelated guards, and a 10000-token organization limit. Token counts were
computed from the private Ollama-rendered prompt, then compared to actual
usage from the generation. Each receipt settled and released unused capacity.

| Scenario | Count before generation | Actual prompt_tokens | Actual completion_tokens |
| --- | ---: | ---: | ---: |
| Polish Unicode text | 23 | 23 | 32 |
| System/user/assistant conversation | 60 | 60 | 32 |
| Function tool definition | 273 | 273 | 32 |
| Assistant tool call, tool result and continuation | 328 | 328 | 32 |

This confirms the pinned runtime/model/tokenizer combination on these fixtures;
adding a model or changing any pin requires live acceptance again.

## Failure and accounting evidence

Tests exercise 5000 / reservation 4000 / actual usage 2200 / return 1800;
organization and agent contention, rollback of both levels, request/workflow
contention, duplicate/conflicting settlement, no repeat dispatch, actual overrun,
lowered policies, UTC boundary and tenant/grant isolation. Recovery retains
persisted dispatches and releases unsent work; clearing the read cache preserves
PostgreSQL balances. Unknown unbounded usage blocks a newly enabled limit in
that hour until audited reconciliation. A failed reconciliation audit rolls
back the refund.

Gateway tests cover timeout before/after the dispatch marker, a killed generation
worker, missing usage, valid usage with invalid content, blocked output, failed
input/output audits and failed database admission. Input is counted after
redaction; guard usage is audited separately and does not alter target-model
counters. HTTP tests cover unauthenticated API-key attempts sharing the remote
IP limiter and distinct hourly 429 codes with UTC Retry-After. Decimal costs
retain request-time rates across price changes.

## Scope and remaining integration

The existing Policies surface retains its layout and design; the only copy
refinement explains UTC hours, empty/null, zero, preserved counters and pending
tool integration. Impeccable review used one batched inspection and one
confirmation round after clarifying `null`; captures are ignored local review
artifacts under `.impeccable/review/`.

Output denial tests use the existing guard contract. Full real output filtering
with NER/rules from step 8 and semantic guard usage from step 10 need a joint
acceptance after those branches merge. This does not claim either step complete.
The durable workflow counter is ready; endpoint integration remains step 12,
workflow orchestration step 15, and the Budgets page step 11.

Startup recovery currently assumes one application instance per database and
all previous workers stopped. The supported MVP deployment follows that rule;
concurrent multi-instance recovery needs a separate deployment lease.

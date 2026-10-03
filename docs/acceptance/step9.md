# Step 9 acceptance — durable budgets and usage

Recorded on 2026-10-03/04 on macOS arm64 (Apple M4), Elixir 1.20.4,
OTP 29.1.1, Python 3.11 and isolated PostgreSQL 17. No production data used.

| Check | Actual result |
| --- | --- |
| `mix precommit` | 441 ExUnit tests passed after integrating main (steps 8/12A), 5 opt-in live tests excluded; formatting, warning-free compilation, lockfile, strict Credo and 3 JS tests passed |
| `mix assets.build` | Tailwind and esbuild passed |
| Tokenizer Python tests | 4 tests passed against the real checksum-verified offline tokenizer |
| Real Ollama budget acceptance | 2 tests passed in 22.7 seconds: four tokenizer comparisons and joint actual generation/NER output redaction |
| PostgreSQL contention | 3 tests passed with independent unboxed connections; barrier verifies both competitors wait on PostgreSQL locks |
| Policies LiveView | DOM-ID form test preserves null, zero, organization/agent hourly limits and workflow values through activation |
| Browser review | 1365×900 and 390×844, light/dark; native summary activated with Enter, Tab enters request/token fields, visible focus; no horizontal page overflow |
| Container script syntax | `bash -n docker/start docker/smoke`, `sh -n docker/healthcheck` passed |
| Linux release/container acceptance | Passed in GitHub CI: image build, private offline services, 4 tokenizer tests, real NER, release tasks, three child failures and SIGTERM |
| Migration lifecycle | Fresh install, rollback of Step 9 and reapplication passed in a separate PostgreSQL database |
| GitHub CI | Quality, Security, Tests, Dialyzer and container all passed on `c4469fa` |

[CI evidence](https://github.com/jlitewka99/hackyeah2026/actions/runs/37158859316)
validated the final implementation. The local Docker daemon was unavailable;
Linux container acceptance ran on the GitHub runner.

## Real tokenizer agreement

Runtime Ollama **0.35.1**, `qwen3.5:4b` Q4_K_M digest
`2a654d98e6fba55d452b7043684e9b57a947e393bbffa62485a7aac05ee4eefd`.
Tokenizer revision and checksums are in `sidecar/tokenizer/models.v1.json`.
The four count fixtures used `max_tokens: 32` and disabled unrelated guards.
The joint NER fixture used `max_tokens: 128` and required actual NER on output.
All used a 10000-token organization limit. Token counts were
computed from the private Ollama-rendered prompt, then compared to actual
usage from the generation. Each receipt settled and released unused capacity.

| Scenario | Count before generation | Actual prompt_tokens | Actual completion_tokens |
| --- | ---: | ---: | ---: |
| Polish Unicode text | 23 | 23 | 32 |
| System/user/assistant conversation | 60 | 60 | 26 |
| Function tool definition | 273 | 273 | 32 |
| Assistant tool call, tool result and continuation | 328 | 328 | 21 |
| Real generation with real NER output redaction | 34 | 34 | 15 |

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
retain request-time rates across price changes. Unknown usage with configured
rates is `unavailable`, missing rates are `not configured`, and confirmed
unsent work has zero configured cost.

## Scope and remaining integration

The existing Policies surface retains its layout and design; the only copy
refinement explains UTC hours, empty/null, zero, preserved counters and pending
tool integration. Impeccable review used one batched inspection and one
confirmation round after clarifying `null`; captures are ignored local review
artifacts under `.impeccable/review/`.

Output denial/failure tests use the guard contract. After merging main (step 8
and step 12A), actual Ollama generation settled before real NER output redaction;
all current Step 8 filtering/schema tests passed in the combined suite. Semantic
guard usage from step 10 still requires joint acceptance after that branch merges.
The durable workflow counter is ready; endpoint integration remains step 12,
workflow orchestration step 15, and the Budgets page step 11.

Startup recovery currently assumes one application instance per database and
all previous workers stopped. The supported MVP deployment follows that rule;
concurrent multi-instance recovery needs a separate deployment lease.

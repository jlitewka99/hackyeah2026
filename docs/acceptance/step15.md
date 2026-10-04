# Step 15 — workflow acceptance

Checked on 2026-10-04 on `JL/step-15-workflows`, initially based on `main` at `4d4f0f6`, then integrated with `origin/main` through `6228c57` (Steps 13, 17 and 18). Implementation is available for review. The PR remains **draft** and the implementation-plan checkbox remains open because there was no single successful complete live integration run or actual-provider end-to-end workflow lifecycle qualification. Passing deterministic checks does not close that gap or contradict qualification previously recorded by other steps.

## Recorded checks

| Check | Actual result |
| --- | --- |
| `mix precommit` | PASS on final code: 664 ExUnit tests, 13 excluded; 5 JavaScript tests. Formatting, compilation and Credo passed. |
| New workflow coverage | 41 tests across domain, accounting, PostgreSQL concurrency, v5 configuration, controllers, LiveView, buffered SSE and MCP compatibility. |
| `mix assets.build` | PASS: Tailwind and esbuild bundles built. |
| `mix dialyzer` | PASS: total errors 0, skipped 0. |
| `mix security` | PASS exit status; dependency audit found no vulnerabilities. Sobelow still reports incumbent low-confidence dynamic SQL in Dashboard and temporary upload-file reads in PolicyLive and OrganizationKnowledgeLive. |
| Migration | Applied in dev/test and an isolated UI test database. Historical rows have nullable workflow references. Rollback was not executed. |
| Real integration attempt | Existing live NER, tool-model, SSE and Knowledge tests with `--include live_ner --include live_models`: **2/7 passed**. Both real v5 RAG tests passed on Step 18 ports; five default-port tests failed NER/Semantic readiness or Ollama SSE 503. |
| Alternate-port attempt | Reused existing providers at Ollama `11438`, NER `8018`, tokenizer `8028`, Semantic `8038`, without changing services: **5/7 passed**. NER, tool-model and SSE tests passed; both repeated RAG cases returned `guard_unavailable`. Each integration passed in one of the two runs, but there was no single 7/7 run. |
| Provider qualification | Default endpoints `11434`/`8001`/`8002`/`8003` were unavailable. Real v5 RAG exercised workflow token accounting; the entire actual-provider run → tool → delegation → completion lifecycle remains unqualified. |
| Impeccable detector | Run once: zero primary findings; five existing typography advisories. No second detector run. |
| Browser matrix | List/detail and policy v5: 1280px desktop, 390px mobile, light/dark. Valid full-page captures; long unbroken goals wrap without horizontal overflow. |
| Browser interactions | Filters, genuine empty result, invalid filter without a misleading empty result, keyboard confirmation/cancel/committed stop, organization PubSub updates. |
| Final finish review | See [scoped UI review](step15-ui-review.md). Source and rendered documentation were rechecked by the separate documenter; see [its report](step15-design-documentation.md). |

Final-code logs are `/private/tmp/step15-precommit.log`, `/private/tmp/step15-assets.log`, `/private/tmp/step15-dialyzer.log`, `/private/tmp/step15-security.log`, `/private/tmp/step15-live-integrations.log` and `/private/tmp/step15-live-alternate-ports.log`. The alternate configuration launcher is `/private/tmp/step15-live-config.exs`; the default-endpoint probe is `/private/tmp/step15-provider-readiness.log`. These are local working evidence, not repository artifacts or CI results.

## Deterministic evidence

- Boundary checks cover operation/depth/repetition limits, exact deadline, shared token reservations and tool dispatch allowances; A→B→A and siblings cannot gain a fresh root budget.
- Repetition tests interleave other actions, cross participant identities, change transport tool-call IDs and reorder JSON arguments. UUID retries preserve counts; changed idempotent data conflicts.
- No hourly token cap still forces tokenizer reservation. UTC-hour rollover keeps root usage; later policy tightening applies without allowing a cap increase. Output guard rejection still settles actual target-model tokens.
- Independent PostgreSQL transactions exercise competing reservations and delegations with barriers. Controlled clock/process messages cover deadline, worker timeout, runtime loss and startup recovery. Tests use supervised processes without sleep synchronization.
- Stop during dispatch preparation produces no downstream effect and releases unsent reservation; stop after dispatch retains uncertain charge, never retries the effect, and audited reconciliation settles once.
- Organization isolation, participant substitution, own-key delegation, revoked keys, synchronous audit failure, v1–v4 regression behavior, restricted participants/events/JSONL, filters and pagination are covered.
- The API scenario creates a run, invokes LLM and tool, delegates, invokes with the child's own key, and completes. Provider/tokenizer responses are controlled fixtures; this is not actual-model proof.
- Current-main compatibility: six SSE tests use controlled real HTTP sockets for missing context, accounting/completion, preparation stop, dispatched stop, exact controlled deadline and runtime loss. Two MCP tests cover forwarded headers, content/resource operations, retries, stop and participant substitution. Legacy streaming and MCP tests also passed after merging main.
- Combined v5 preserves Knowledge/NER choices, Prompt Guard threshold/provider and explicit tool limits. Configuration and LiveView tests verify filling missing workflow defaults keeps those choices and leaves activation separate. Existing Knowledge chat/SSE tests now supply required workflow context rather than bypassing v5 protection.

## UI evidence and provenance

Browser acceptance used a dedicated server on port 4315 and database `ai_control_teststep15_ui`, with synthetic labeled goals/agents. The running fixture used an explicit **1800-second** policy override to stay available during review; product defaults remain **300 seconds**. No real prompts, secrets or production data were used.

Fourteen primary captures in ignored `.impeccable/review/` cover list, detail and policy in both viewports/themes, plus mobile stop confirmation and stopped state. The fix batch replaced list/detail/stop captures. After Step 18 integration, all four policy captures were replaced again to show Knowledge/NER and finite workflow limits together; current browser DOM confirmed both navigation links and no policy overflow. The other captures retain their earlier workflow fix evidence. Supplemental `desktop-error.png`, `mobile-error.png` and `mobile-empty.png` capture the corrected filter states. Every supplied file was opened and checked. Screenshots are local acceptance evidence, not shipping rasters.

Keyboard observations after final patches:

| Action | Observed DOM focus/result |
| --- | --- |
| Enter on Stop workflow | `run-stop-confirm`, visible solid focus outline |
| Enter on Keep running | `run-stop` |
| Enter on confirmation | `run-status`; committed `Stopped`, confirmation removed |
| Accounting after stop | 140 used tokens and 400 uncertain reserved tokens retained |
| Invalid UUID filter | `runs-error` present, `runs-empty` absent |
| Completed-only filter without results | `runs-empty` present, `runs-error` absent |

LiveView tests cover restricted access and loading failures; no browser screenshot proves every access/error branch. The separate UI verdict scores the reviewer's findings only. It does not certify backend security, performance or model quality.

## Remaining qualification and operating limits

1. Run all seven existing live integrations successfully in one configured environment and a full v5 workflow lifecycle against actual tokenizer/LLM/tool adapters. Investigate intermittent `guard_unavailable` from the repeated RAG cases. Existing Step 11 model qualification remains open.
2. Test migration rollback only in a disposable database if rollback support is part of release acceptance. Never remove required workflow evidence from an active deployment.
3. Apply migration before release; explicitly upgrade, review and activate v5. V1–v4 continue their existing behavior. V5 has finite editable workflow caps and requires headers even through domain entry points. Saved Knowledge-only v5 snapshots fail closed after this release until a new combined version is deliberately published; an active old v5 also blocks the existing Policies page. Use the authorized Policies domain API for that maintenance rollout; saved settings/checksums are never rewritten. See the API contract's rollout note.
4. Stop prevents subsequent dispatches across branches but cannot undo dispatched effects. Adapter cancellation is bounded; uncertain reservations require existing audited reconciliation.
5. Target-model input/output tokens share the root budget; guard-model usage is separate. HMAC detects identical actions, while lifetime, operations and tokens bound varying actions.
6. One application instance per database is supported. No cluster lease, automatic client orchestration, resume/replay, MCP, Granite or Oban is provided by this step.
7. Existing Impeccable documentation drift and five detector advisories are preserved. No separate Operate QUALITY BAR card was supplied; this limits independent ceiling qualification. The authorized extension keeps the incumbent design system and `buildPath: code`.

[Workflow API and accounting contract](../workflows.md) contains rollout details, status codes and policy defaults. No CI result or unexecuted qualification is claimed in this report.

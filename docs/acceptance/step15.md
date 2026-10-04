# Step 15 — workflow acceptance

Initially checked on 2026-10-04 on `JL/step-15-workflows`, based on `main` at `4d4f0f6`, then integrated through `dae70b3` (Steps 13, 16, 17 and 18). [Implementation PR #25](https://github.com/jlitewka99/hackyeah2026/pull/25) is merged. Initial live acceptance was incomplete; the historical results below remain intact. A follow-up on `JL/step-15-live-acceptance`, based on current `main` at `6f00150` after PR #26, passes all seven integrations and an actual-provider workflow lifecycle. **The Step 15 implementation-plan checkbox is now checked.** Model-quality and load-reliability limitations remain separate.

## Initial implementation checks

| Check | Actual result |
| --- | --- |
| `mix precommit` | PASS on final code: 690 ExUnit tests, 15 excluded; 5 JavaScript tests. Formatting, compilation and Credo passed. |
| New workflow coverage | 44 tests across domain, accounting, PostgreSQL concurrency, v5 configuration, controllers, LiveView, buffered SSE, MCP and background export compatibility. |
| Isolated runner integration | PASS: 5 tests with `TEST_RUNNER_DATABASE_URL` set to the separate `ai_control_teststep15_runner` database and `--include runner`. Child-process HTTP/audit/budget/sandbox checks cover 15 controlled scenarios; cancellation and absence of primary fixture writes passed. |
| `mix assets.build` | PASS: Tailwind and esbuild bundles built. |
| `mix dialyzer` | PASS: total errors 0, skipped 0. |
| `mix security` | PASS exit status; dependency audit found no vulnerabilities. Sobelow retains low-confidence findings from main: dynamic SQL in Dashboard/export manifests, benchmark/feed file paths, temporary upload-file reads and endpoint origin configuration. These were not suppressed or treated as confirmed vulnerabilities. |
| Migration | Applied in dev/test and an isolated UI test database. Historical rows have nullable workflow references. Rollback was not executed. |
| Real integration attempt | Existing live NER, tool-model, SSE and Knowledge tests with `--include live_ner --include live_models`: **2/7 passed**. Both real v5 RAG tests passed on Step 18 ports; five default-port tests failed NER/Semantic readiness or Ollama SSE 503. |
| Alternate-port attempt | Reused existing providers at Ollama `11438`, NER `8018`, tokenizer `8028`, Semantic `8038`, without changing services: **5/7 passed**. NER, tool-model and SSE tests passed; both repeated RAG cases returned `guard_unavailable`. Each integration passed in one of the two runs, but there was no single 7/7 run. |
| Provider qualification | Default endpoints `11434`/`8001`/`8002`/`8003` were unavailable. Real v5 RAG exercised workflow token accounting; at that point the entire actual-provider run → tool → delegation → completion lifecycle was unqualified. |
| Impeccable detector | Run once: zero primary findings; five existing typography advisories. No second detector run. |
| Browser matrix | List/detail and policy v5: 1280px desktop, 390px mobile, light/dark. Valid full-page captures; long unbroken goals wrap without horizontal overflow. |
| Browser interactions | Filters, genuine empty result, invalid filter without a misleading empty result, keyboard confirmation/cancel/committed stop, organization PubSub updates. |
| Final finish review | See [scoped UI review](step15-ui-review.md). Source and rendered documentation were rechecked by the separate documenter; see [its report](step15-design-documentation.md). |

Final-code logs are `/private/tmp/step15-precommit.log`, `/private/tmp/step15-assets.log`, `/private/tmp/step15-dialyzer.log`, `/private/tmp/step15-security.log`, `/private/tmp/step15-runner.log`, `/private/tmp/step15-live-integrations.log` and `/private/tmp/step15-live-alternate-ports.log`. The alternate configuration launcher is `/private/tmp/step15-live-config.exs`; the default-endpoint probe is `/private/tmp/step15-provider-readiness.log`. Live-model attempts preceded the final Step 16 source merge; they were not repeated after that merge. These are local working evidence, not repository artifacts or CI results.

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
- Current-main background compatibility: immutable signature selectors coexist with workflow limits; existing isolated gateway scenarios create and bind their own synthetic runs and stop them after execution. Three tests cover background JSONL participant/owner filtering, completed-download assignment revocation and resumed-manifest revocation without output.

## UI evidence and provenance

Browser acceptance used a dedicated server on port 4315 and database `ai_control_teststep15_ui`, with synthetic labeled goals/agents. The running fixture used an explicit **1800-second** policy override to stay available during review; product defaults remain **300 seconds**. No real prompts, secrets or production data were used.

Fourteen primary captures in ignored `.impeccable/review/` cover list, detail and policy in both viewports/themes, plus mobile stop confirmation and stopped state. The fix batch replaced list/detail/stop captures. After Step 18 integration, all four policy captures were replaced again to show Knowledge/NER and finite workflow limits together; current browser DOM confirmed both navigation links and no policy overflow. The other captures retain their earlier workflow fix evidence. Supplemental `desktop-error.png`, `mobile-error.png` and `mobile-empty.png` capture the corrected filter states. Every supplied file was opened and checked. Screenshots are local acceptance evidence, not shipping rasters.

Step 16's later Reports/Tests navigation and signature selector were retained. The reviewer and documenter performed a narrow source recheck; supplied captures predate those incumbent additions, and no new rendered approval is claimed. Workflow templates/styles remain unchanged by that merge. No new detector or visual polishing round was run.

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

## Current-main live acceptance — 2026-10-04

Reused ready local services at Ollama `11438`, NER `8018`, tokenizer `8028` and Qwen `8038`, with a separate `ai_control_teststep15live` database. No existing provider was reconfigured, restarted or stopped. Tests ran sequentially, with unchanged guard deadlines, no retries and no concurrent local build. The machine and service processes were not exclusively owned; this is functional acceptance, not a capacity measurement.

| Check | Follow-up result |
| --- | --- |
| The same four existing live test files | **7/7 passed in one run**, seed `666512`, 124.8 seconds. Both RAG cases passed. |
| New `workflows/live_workflow_test.exs` | **1/1 passed**, final seed `289581`, 46.9 seconds. The earlier version also passed in 48.4 seconds. |
| Actual HTTP workflow lifecycle | Create/retry → root LLM/tool → own-key delegation → child LLM/tool → completion. Real pinned Ollama, exact tokenizer, NER v2, Qwen injection/moderation and deterministic guards; tools use the real current sandbox adapter with synthetic files. |
| Shared accounting | No hourly token limit configured; both target-model receipts settle. Root tokens equal the two real usage totals, reserved tokens are zero, and the existing root tool counter is two. |
| Access and terminal enforcement | Missing context, participant substitution, a child reading the owner's separately granted path, child completion and post-completion continuation are rejected. |
| Follow-up `mix precommit` | PASS: 690 ExUnit tests, 17 opt-in tests excluded; 5 JavaScript tests. Format, strict compilation, lockfile check and Credo pass. The new live test runs separately above. |
| Follow-up assets, Dialyzer, security | PASS: assets build; zero Dialyzer errors/skips; configured Sobelow gate and dependency audit. Existing low-confidence Sobelow findings remain unsuppressed; dependency audit finds no vulnerabilities. |
| Current-main CI | [37181696853](https://github.com/jlitewka99/hackyeah2026/actions/runs/37181696853) passes Quality, Tests, Dialyzer, Security and the real-model/release-runner container. Optional gated Prompt Guard is skipped by design; its local qualification is recorded in Step 11B. |

The new test explicitly removes LLM, NER, tokenizer and semantic stub transports, forces the actual tokenizer and loads pinned Ollama model identities. It starts the HTTP server and sandbox using `start_supervised!`, cleans up its run process and uses no sleep synchronization. NER's existing tests retain their original controlled LLM responses; the new lifecycle supplies the previously missing entirely real model boundary.

The failed [PR #26 container run](https://github.com/jlitewka99/hackyeah2026/actions/runs/37181579586) encountered HTTP 503 while downloading the tokenizer, before smoke execution. The successful current-main run above closes that container check. Successful functional reruns do not establish the precise cause of the earlier local `guard_unavailable` or prove reliability under background load. Step 11B's frozen model-quality results and remaining MVP gate are preserved.

Local logs: `/private/tmp/step15-current-live.log`, `/private/tmp/step15-current-workflow.log`, `/private/tmp/step15-current-workflow-final.log`, `/private/tmp/step15-current-precommit.log`, `/private/tmp/step15-current-assets.log`, `/private/tmp/step15-current-dialyzer.log`, `/private/tmp/step15-current-security.log`. Earlier live attempts predate the final Step 16 merge; these new checks run on the combined current-main source. This follow-up adds no migration; the original rollback remains untested. No frontend detector, browser or separate UI/documenter review was rerun because the follow-up changes tests and acceptance records only.

To reproduce with all four verified services running on those ports, save this launcher as a local `.exs` file, then run `MIX_ENV=test MIX_TEST_PARTITION=step15live mix run --no-start /absolute/path/to/launcher.exs`:

```elixir
config = Application.fetch_env!(:ai_control, AiControl.Gateway.Config)

Application.put_env(:ai_control, AiControl.Gateway.Config,
  Keyword.merge(config,
    base_url: "http://127.0.0.1:11438",
    ner_url: "http://127.0.0.1:8018",
    tokenizer_url: "http://127.0.0.1:8028",
    semantic_url: "http://127.0.0.1:8038"
  )
)

Mix.Task.run("test", [
  "test/ai_control/gateway/live_ner_test.exs",
  "test/ai_control/tools/live_models_test.exs",
  "test/ai_control/gateway/live_stream_test.exs",
  "test/ai_control/gateway/live_knowledge_test.exs",
  "test/ai_control/workflows/live_workflow_test.exs",
  "--include", "live_ner", "--include", "live_models"
])
```

The recorded results are seven existing integration cases and the lifecycle case in separate invocations; no combined eight-test invocation is claimed. The existing Knowledge tests use the Step 18 service ports explicitly. Missing services remain test failures, never successful skips. No frontend or production behavior changed in this acceptance follow-up; existing rendered review provenance remains unchanged.

## Operating limits

1. The seven integrations and full v5 workflow lifecycle now pass as recorded above. Production capacity and Qwen reliability under load remain unqualified; existing Step 11 model-quality/MVP limitations remain applicable.
2. Test migration rollback only in a disposable database if rollback support is part of release acceptance. Never remove required workflow evidence from an active deployment.
3. Apply migration before release; explicitly upgrade, review and activate v5. V1–v4 continue their existing behavior. V5 has finite editable workflow caps and requires headers even through domain entry points. Saved Knowledge-only v5 snapshots fail closed after this release until a new combined version is deliberately published; an active old v5 also blocks the existing Policies page. Use the authorized Policies domain API for that maintenance rollout; saved settings/checksums are never rewritten. See the API contract's rollout note.
4. Stop prevents subsequent dispatches across branches but cannot undo dispatched effects. Adapter cancellation is bounded; uncertain reservations require existing audited reconciliation.
5. Target-model input/output tokens share the root budget; guard-model usage is separate. HMAC detects identical actions, while lifetime, operations and tokens bound varying actions.
6. One application instance per database is supported. No cluster lease, automatic client orchestration, resume/replay, MCP, Granite or Oban is provided by this step.
7. Existing Impeccable documentation drift and five detector advisories are preserved. No separate Operate QUALITY BAR card was supplied; this limits independent ceiling qualification. The authorized extension keeps the incumbent design system and `buildPath: code`.

[Workflow API and accounting contract](../workflows.md) contains rollout details, status codes and policy defaults. Only the linked CI results and executed local qualification are claimed; no model-quality or production-load acceptance is inferred.

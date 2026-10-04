# Step 14 — Granite Guardian acceptance

Recorded on 2026-10-04. Implementation is on `JL/step-14-deep-semantic-analysis`. The roadmap checkbox remains open and the PR is a draft because the combined live-model gate did not complete successfully. The user subsequently requested that previously working components not be tested again; their earlier passing evidence is retained.

## Implementation accepted by deterministic tests

- `mix precommit`: **712 passed, 17 excluded**, plus **5 JavaScript tests**. Formatting, compilation and Credo passed. Exclusions are the separately gated real-model and runner cases.
- `mix assets.build`: passed.
- The new coverage checks opt-in v6 and v1–v5 compatibility, YAML/draft round trips, finite workflow limits, preservation of v6 when applying workflow defaults, both score polarities, exact selectors, suspicion thresholds, proposed tool calls, mandatory-check completeness, deterministic short-circuiting, MCP execution, cancellation/slot release, blocked JSON/SSE and settlement of generated tokens.
- Historical Events shows the recorded polarity and result, distinguishes skipped and unavailable checks, and retains a historical digest. Closed evidence rejects prompts, arguments, sources and reasoning fields. Real tool denial tests confirm absence of effects and private JSONL exports.
- Pinned tokenizer contracts: **6 passed**, including exact Unicode token counts and separate Granite digest dispatch. Existing semantic contracts: **8 passed**; Prompt Guard contracts: **9 passed**. NER contracts passed with the correct locked NER runtime; its optional real-weight case is qualified separately by the existing live workflow.
- UI finish review: **ship**, no material fixes. Desktop 1440px/mobile 390px, both themes, visible keyboard focus and no horizontal overflow. The one detector result was `[]`. See [UI review](step14-ui-review.md) and [design documentation](step14-design-documentation.md).

## Actual Granite model

The completed standalone real-model run at `2026-10-04T06:47:41.345398Z` classified all **12/12** synthetic cases correctly: safe/unsafe pairs for input, tool alignment and groundedness in both English and Polish. Exact sidecar prompt counts agreed with native generation counts. There were **0 classification errors and 0 unavailable results** in that run.

| Measurement | Recorded value |
|---|---|
| Model | `granite4.1-guardian:8b`, 8.4B |
| Full digest | `f82c0882cec110279601307cdd632d868e29f16eaa59947bef51096e5f740492` |
| Tokenizer revision | `ab01ccca5dcfb80246369a086a4a87a29198f5af` |
| Runtime | Ollama 0.35.1 |
| Quantization | Q6_K |
| Context / result reserve | 8192 / 64 tokens |
| Mode | Non-thinking, temperature 0 |
| Hardware | Apple M4, 16 GiB physical memory |
| Warm p50 / p95 | 4222 / 5863 ms |
| Ollama model size / reported VRAM allocation | 8,321,719,336 / 8,321,719,336 bytes |

These are a warm synthetic smoke test and Ollama's reported model allocation, not an application RSS or production latency benchmark. Unified-memory allocations must not be added as separate RAM and GPU copies. Per-case measurements are retained in [the benchmark JSON](step14-granite-warm-benchmark.json), copied from the completed run's tool output after its temporary report was lost during environment reset. User instructions prevent repeating already successful qualification solely to regenerate the file.

The published model returned whitespace inside its score tags. The parser therefore accepts `<score> no </score>` while still requiring exactly one complete binary score and rejecting extra prose, multiple scores and incomplete thinking. A second digest check after generation detects a changed model alias before accepting a verdict. Native responses must be complete and agree with the pinned tokenizer.

## Container and combined gate

The image includes the checked Granite tokenizer and keeps Ollama external. NER, Qwen3Guard and Prompt Guard artifacts retain their existing manifests; the local acceptance reused already downloaded Prompt Guard files rather than downloading gated weights again.

A combined existing-model integration attempt produced **1/11 passing tests** after sidecar timeouts/unavailability and termination of the container. Docker reported **exit 137, `OOMKilled=true`** and the startup supervisor recorded a killed Qwen3Guard process. The Docker VM exposed approximately 7.82 GiB memory, and model/build work overlapped in that attempt. This is recorded as failed environment qualification; it does not establish a classifier error or a deterministic regression in Step 14. No timeout or fail-closed requirement was relaxed to obtain a pass.

The earlier expanded `run_security_tests.sh --live-models` attempt also did not qualify the full gate: a real model catalog was incorrectly supplied to the mixed stub/real suite, conflicting with stub digests. The script now includes Granite and requires every named live service. Its setup help identifies all locked sidecar dependencies; live mode also enables the optional real NER contract. Operators must leave `GATEWAY_MODELS` unset for the mixed suite because real-model tests load their own pinned catalog.

Following the user's instruction, previously successful model and regression tests were not rerun. The final image built successfully. New Granite enforcement passed in the container with external Ollama: an authorized goal-aligned write returned `yes` and recorded its effect; a schema/resource-authorized email inconsistent with the workflow goal returned `no`, was blocked, and left the mailbox empty. Both checks recorded the pinned digest, criterion hash, polarity and actual token usage; unselected output checks were skipped. Existing policy guards were disabled for these two synthetic actions, so this is a focused Granite acceptance rather than a combined-model pass.

The cold first guard took **54.54 seconds** and the second **6.63 seconds**, within the unchanged 60-second deadline. The first result illustrates how little deadline headroom cold loading can leave on this host. The image digest, content-free verdicts and effect assertions are retained in [the final container report](step14-granite-container.json). An observed container memory sample was 4.211 GiB out of 7.817 GiB; this is not a peak-memory measurement. The earlier failed combined qualification remains open.

## Remaining qualification and limitations

The combined live gate remains open. A future full acceptance run needs adequate Docker/host memory, sequential build and model qualification, all pinned services, and the existing test command. A single Ollama server with `OLLAMA_MAX_LOADED_MODELS=1` can avoid keeping Qwen and Granite resident together; cold switching increases latency. The draft PR explicitly preserves this gap.

IBM trained and tested Granite in English. Twelve synthetic cases cannot establish Polish detection accuracy, BYOC robustness, adversarial coverage or false-positive rates. An 8B model increases latency; multiple selected criteria share the 60-second deadline. Groundedness checks consistency with retrieved sources and does not guarantee that they are true. Interrupted inference can leave guard usage unavailable; completed calls retain actual token usage. Prompts, arguments, sources and reasoning are not recorded in application audit or exports.

The stale `.impeccable/design.json` was recorded and left unchanged. Refreshing it via `impeccable document` is a separate task. See [operator setup](../granite-guardian.md), [IBM model card](https://huggingface.co/ibm-granite/granite-guardian-4.1-8b) and [Ollama API](https://docs.ollama.com/api/generate).

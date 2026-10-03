# Step 10 acceptance

Implementation covers the Qwen provider, optional response moderation, policy v3,
content-free evidence, Polish benchmark and three-process container. Synthetic
fixtures only; this is not a production safety or throughput guarantee. Final
model selection and every Prompt Guard implementation/access task belong to 11B.

## Local verification — 2026-10-04

- `mix precommit`: strict compilation, formatting, lockfile, Credo, ExUnit and
  JavaScript regressions pass after integrating Steps 8 and 12A from main:
  **430 ExUnit tests**, five opt-in tests excluded,
  and **three JavaScript tests**.
- `mix assets.build`: Tailwind/esbuild pass.
- `mix dialyzer`: zero errors. Production compilation passes.
- `mix security`: dependency audit and Sobelow pass; the existing low-confidence
  policy-upload path finding is unchanged.
- Python semantic contract tests: eight pass, including full UTF-8 tail/overlap
  coverage, work/deadline limits, single-scan capacity, strict labels, private
  errors and untruncated oversized moderation context, even for an empty response.
- Gateway mocks cover Polish labels, severity mapping, PII separated from injection,
  input blocking before downstream, required failure, output blocking with redacted
  prompt context, private audit and immutable in-flight policy snapshots.
- V1 checksum vector remains unchanged. The V2 vector was independently computed
  from Configuration at `bd4d6f1` and now has a literal regression assertion.

## Real models and benchmark

Qwen weights/tokenizer/template are pinned to revision
`fada3b2f655b89601929198343c94cd2f64d93cc`, model set
`qwen3guard-gen-0.6b.v1`. Runtime: Python 3.11, Transformers 4.57.1,
Torch 2.8.0, CPU FP32, two threads, no quantization or runtime downloads.
Local hardware: Apple M4, ARM64, macOS 27.0, 16 GiB RAM.

The versioned dataset has 200 input fixtures (50 safe/direct/indirect/PII each)
and 40 response pairs (20 safe including refusals, 20 harmful). Before measurements,
families were frozen into equally represented calibration/test halves. Checksum:
`1bddc6ebcebb09c83bc37892e4ed6b8090a3c246286c90ffccf74afc5365db47`.
No mapping was tuned against the test half. Balanced mapping uses Unsafe +
Jailbreak; moderation uses Unsafe + its eight response categories.

The complete actual HTTP benchmark is recorded in [step10-qwen](step10-qwen/):
240 cases, **230 completed classifications and 10 service errors**. The command
returns a nonzero exit status after preserving the reports when service errors
occur. Every error was the 30-second guard deadline on a long indirect-injection
fixture. The benchmark waits for sidecar capacity between cases without retrying
classifications; production fails closed on admission, timeout or invalid results.

Held-out test results with the default balanced mapping:

| Group | TP | FP | TN | FN | Service errors | Result |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| Safe | 0 | 0 | 25 | 0 | 0 | 0/25 false positives |
| PII (negative for injection) | 0 | 0 | 25 | 0 | 0 | 0/25 false positives |
| Direct injection | 8 | 0 | 0 | 17 | 0 | 32% recall |
| Indirect injection | 8 | 0 | 0 | 12 | 5 | 40% recall among 20 completed cases |
| Safe response pairs | 0 | 0 | 10 | 0 | 0 | 0/10 false positives |
| Harmful response pairs | 10 | 0 | 0 | 0 | 0 | 100% recall on 10 cases |

Injection FPR is **0/50** on the held-out negative cases. This small synthetic
sample does not establish zero false positives in production. Indirect detection
is 8/25 (32%) if service errors count as unclassified cases. Errors are reported
separately from the confusion matrix and never treated as model detections.
PII results measure injection false positives, not PII recognition accuracy.

Across all cases, warm guard latency p50 is **1,111.6 ms**, p95 **13,874.2 ms**;
cold model load is **3,567.9 ms** and peak process RSS **4,740,562,944 bytes**
(4.41 GiB). Latency includes HTTP transport, validation and label mapping and
excludes downstream LLM generation. The current CPU budget cannot classify every
long fixture within 30 seconds. Recall and deadline errors must remain visible
in 11B's model/hardware comparison; this is not final MVP model qualification.

`mix test test/ai_control/gateway/live_semantic_test.exs --include live_models`
passes **two real-weight tests**: Polish injection and safe control, harmful
response blocking, private audit, and full token-window coverage of a tail attack.

## Frontend evidence

Both shared policy surfaces retain the incumbent appearance. Draft-only upgrade,
severity/category editing, saving without activation, differences and deliberate
activation were exercised with a synthetic organizer in an isolated local DB.
Desktop 1440px and mobile 390px light/dark captures are stored locally under
`.impeccable/review/step10-*`; widths have no horizontal overflow and select Tab
focus has a visible outline. One Impeccable detector pass returned `[]`.
The independent finish review returned **ship**, with no material fixes.
Documentation comparison preserves DESIGN.md and the explicitly deferred stale
`.impeccable/design.json`.

## Container and remaining scope

Docker smoke checks real Qwen/NER release transport, private loopback listeners,
health, migrations/bootstrap, all three child failures and SIGTERM. The local
Docker daemon is unavailable; Linux CI must supply the container evidence.
Step 10's checkbox remains unchecked until its real-model and container gates
are recorded. Full output filtering, budget settlement and tool enforcement
integration remain in 12B/11B. In 11B compare Qwen and Prompt Guard on identical
data/hardware: require FPR ≤ 5%, then maximize mean direct/indirect recall, then
prefer lower p95. No qualified candidate leaves MVP acceptance unmet.

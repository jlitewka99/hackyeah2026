# Step 17 — buffered SSE acceptance

Status: buffered SSE implementation accepted after local tests, real Ollama
acceptance, fresh Stream–Gen comparison and all five required hosted CI jobs.
The Step 17 roadmap checkbox is complete. Early content release remains outside
the accepted scope.

## Public behavior

`stream: true` uses SSE after input checks/audit, model pin verification and
budget preparation. Only heartbeat comments are sent during generation. Every
content/tool delta is reconstructed from a complete response after the existing
normalization, tool contract, output controls, accounting and synchronous
`gateway.stream_ready` audit. Early token disclosure is out of scope.
`stream: false` retains the JSON route and existing controls. Unknown options
remain invalid; public usage requires `stream_options.include_usage: true`.

Preflight failures retain JSON HTTP errors. Later failures are fixed SSE
`event: error` envelopes containing code, message and gateway request ID, without
violating content or `[DONE]`. Heartbeats default to five seconds. A 30-second
delivery watchdog also covers the final `[DONE]` write. Wire, assembled and
redacted response limits are each 4 MiB by default.

The supervised session owns budget admission, usage checkpointing, cancellation
and final audit, closing the gap between database admission and session registration.
Client/worker death or write failures cancel transport and release the LLM slot.
Validated final usage is settled idempotently even when later parsing, filtering
or delivery fails. Before dispatch reservations are released; without final
usage after dispatch they remain uncertain. Raw content is absent from stream
audit evidence and public error messages.

`stream` audit metadata has a closed schema: buffered mode, delivery status,
received/sent bytes and chunks. Sent counters count approved frames successfully
accepted by `Plug.Conn.chunk/2`, excluding heartbeat and DONE. They cannot prove
client receipt. Readiness events are excluded from Dashboard terminal totals.
The readiness audit is required before content; completion audit precedes DONE.
If the audit database fails, delivery fails closed, although an unavailable
database cannot record the failed/cancelled event itself.

## Verification on 2026-10-04

An isolated PostgreSQL cluster ran on loopback port 55437. Dependencies were
restored with the locked Mix dependency set. Host runtime: Elixir 1.20.4 / OTP
29.1.1, Node 24, Apple M4 arm64 / macOS. Live SSE used the already running,
manifest-verified Ollama 0.35.1 and qwen3.5:4b digest
`2a654d98e6fba55d452b7043684e9b57a947e393bbffa62485a7aac05ee4eefd`.

| Check | Result |
| --- | --- |
| `PGPORT=55437 mix precommit` | 556 ExUnit passed, 11 tagged tests excluded; 3 JS passed; format/compile/Credo/lockfile passed |
| Python Stream harness contract | 3 passed; no models/network needed |
| `MIX_ENV=test mix dialyzer --format github` | Passed, zero project errors |
| `MIX_ENV=test mix security` | Passed; dependency audit found no vulnerabilities; Sobelow retains existing low-confidence findings |
| `MIX_ENV=test mix assets.build` | Passed |
| Real pinned Ollama SSE | 1 passed separately with `--include live_models` |
| Real Stream model | 40/40 cases completed, zero errors |
| Real Gen model | Fresh 40/40 cases completed, zero errors |
| Hosted required CI | All five required jobs passed on Linux for implementation `8334324` |

Parser tests cover every byte split (including UTF-8 and CRLF), multiple frames,
fragmented tool JSON, invalid/noncontiguous indexes, invalid/duplicate/missing
usage, incomplete termination, trailing invalid data and size limits. Pipeline
tests cover split secrets in text and tool arguments, BLOCK/REDACT, private
provider IDs, usage disclosure, input/output/readiness audit failure, required
guard failure and JSON compatibility.

Real HTTP fixtures use two supervised Bandit servers and actual TCP connections.
They cover comments before approval, client disconnect during generation and
during a 2.4 MB approved delivery, upstream process termination, owner death,
owner death during preflight budget preparation, pre-dispatch release,
post-dispatch uncertainty, policy activation while held,
generation timeout and delivery watchdog. Synchronization uses messages,
monitors and server calls, with no `Process.sleep/1` in tests.

Reproduce live SSE separately from the default suite:

```sh
PGPORT=55437 mix test test/ai_control/gateway/live_stream_test.exs --include live_models
PGPORT=55437 mix test test/ai_control/gateway/stream_http_test.exs \
  test/ai_control_web/controllers/gateway_stream_controller_test.exs \
  test/ai_control/gateway/stream_parser_test.exs
python3 -m unittest discover -s tests/semantic_stream -v
```

The live SSE test enables actual PII/secret/signature guards in a dedicated
rolled-back organization. Unavailable NER and semantic adapters are explicitly
disabled in that acceptance policy. Required adapter failures are covered
separately; this does not change or qualify the platform balanced policy.

## Real model experiment

The [offline harness](../../sidecar/semantic_stream/README.md) pins weights,
tokenizer, configuration, architecture code and checksums. PyTorch 2.8.0,
Transformers 4.57.1 and tokenizers 0.22.2 ran CPU FP32 with two threads. Stream's
stateful classifier received a user prefill followed by single tokenizer IDs
from each fully tokenized synthetic assistant response; SSE fragments were
never treated as tokens. Both variants map only `Unsafe` to block. Stream
retains any Unsafe signal, while Gen uses its existing full-response classifier.

The immutable dataset has SHA256
`1bddc6ebcebb09c83bc37892e4ed6b8090a3c246286c90ffccf74afc5365db47`.
There are 40 Polish moderation pairs, half harmful and half safe, divided
equally between calibration and held-out test. Reports contain IDs and metrics
without source text. Cold start measures verification plus runtime/model load;
warm percentiles exclude a separate warmup. Peak RSS covers the process.

| Metric | Stream | Gen |
| --- | --- | --- |
| Completed / errors | 40 / 0 | 40 / 0 |
| Recall | 100% (20/20) | 100% (20/20) |
| False-positive rate | 10% (2/20) | 0% (0/20) |
| Held-out recall / false positives | 100% / 20% | 100% / 0% |
| Cold verification/load | 4.492 s | 8.233 s |
| Warm p50 / p95 | 1.475 / 2.360 s | 2.300 / 13.476 s |
| Peak RSS | 1.948 GiB | 2.562 GiB |

Among Stream's 22 Unsafe detections, first assistant token indexes were
min/median/max 1/18/27; times including user prefill were
96.62/835.16/1526.39 ms. Indexes include assistant template/closing tokens and
can flag risk before actual response text. The two false-positive cases were
`moderation-05-0` and `moderation-05-1`. The complete
[per-case results](step17-stream/cases.jsonl) and
[runtime/hardware summary](step17-stream/summary.json) are checked in, alongside
[fresh Gen cases](step17-gen/cases.jsonl) and [Gen summary](step17-gen/summary.json).
Gen produces its decision only when full-response classification completes;
those completion times are recorded per case rather than assigned token indexes.
Stream's retained prefix signals produced the two false positives that Gen did
not produce. No model selection or policy activation follows from this result.

Stream revision: `74e1479150e9029d6778993f00491108323bb6f8`.
Gen revision: `fada3b2f655b89601929198343c94cd2f64d93cc`. Both runs used the same
Apple M4, 10 cores and 16 GiB RAM. The host had concurrent development workloads
and memory/disk pressure. These timings describe that local run and cannot
establish production throughput or a performance advantage. The 40 short
synthetic pairs do not establish long-context or general Polish safety recall.
No results activate policies or allow early content disclosure.

## Environment recovery and hosted CI

Initial downloads failed with `ENOSPC`; task-owned partial weights were removed,
and Stream weights were removed after verified loading to complete its full
measurement. Existing Gen weights in another worktree passed every pinned
checksum and were reused read-only for fresh inference, with no copying or
removal of other tasks' files. This resolved model preparation, although host
memory/disk pressure remains a measurement caveat.

[Linux CI run 37169554868](https://github.com/jlitewka99/hackyeah2026/actions/runs/37169554868)
passed Quality, Tests, Dialyzer, Security and the Phoenix/NER/Qwen/tokenizer
container job for implementation `8334324`. The container job passed real model
transport, pinned offline tokenization, Python contracts, release tasks, process
failure handling and SIGTERM. The optional gated Prompt Guard job was skipped
as configured and is outside Step 17. Container evidence supplements the actual
macOS Ollama/SSE and model comparison; neither is represented by a simulated
benchmark.

The [PR checks](https://github.com/jlitewka99/hackyeah2026/pull/20/checks) track
verification of subsequent revisions, including session-owned admission and its
preflight cancellation regression.

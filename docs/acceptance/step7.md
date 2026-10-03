# Step 7 acceptance

Synthetic fixtures only. This is smoke coverage, not a clinical/production PII
quality benchmark or a throughput guarantee.

## Local evidence — 2026-10-03

- `mix precommit`: formatting, strict compilation/Credo, lockfile, JavaScript and
  ExUnit pass: **353 Elixir tests**, 2 opt-in tests excluded, and **3 JavaScript tests**.
- `mix check.all`: Dialyzer passes with zero errors; Sobelow and dependency audit
  pass. Existing low-confidence upload-path finding remains unchanged.
- `mix assets.build`: Tailwind/esbuild pass.
- Python unit/live fixtures: 4 pass with actual offline PL/NKJP weights.
- `mix test test/ai_control/gateway/live_ner_test.exs --include live_ner`: passes;
  real local HTTP NER removes inflected person/address and PESEL before the
  inspected backend request. Persisted audit contains no fixture values.
- Deterministic pipeline regression covers byte-offset refresh, phase order,
  required sidecar/audit failures, strict blocking, invalid tool JSON after
  redaction and a policy activation during the NER phase.
- V1 checksum vector was independently calculated from the pre-Step-7 source
  at `0399d7d`; the frozen validator and historical snapshot still match it.

`sidecar/ner/benchmark.py` ran 40 analyses across four synthetic Polish fixtures
on macOS 27.0 ARM64, Python 3.11.17, CPU threads 2, Stanza 1.11.0 and
`pl-nkjp.v1`: load **5142.5 ms**, p50 **40.7 ms**, p95 **62.9 ms**, peak RSS
**1,031,028,736 bytes** (about 983 MiB). Short inputs exercise people, inflected
names/localities, organizations, geographical places, addresses, Unicode and a
safe negative. These figures exclude gateway/network overhead and are not Linux
measurements. Default scores are recognizer scores, not model probabilities.

## Linux container evidence

Pending the PR's **Phoenix and Polish NER container** CI job. The local Docker
daemon is unavailable. Do not mark Step 7 complete before a successful Linux
image build, real-model smoke and both child-failure/SIGTERM checks. CI executes
`docker/smoke`, then preserves `/tmp/step7-ner-benchmark.json` as an artifact.
Record its run URL, commit and measured values here after success.

## UI evidence

Policy v1 upgrade, v2 detector/entity requirements, phases, save/review/activation
and YAML are covered by LiveView regressions. Browser evidence at 1440×1000 and
390×844 in light/dark themes is stored locally under `.impeccable/review/step7-*`.
Keyboard upgrade, native multi-select traversal and visible focus are exercised;
both viewport widths have no horizontal overflow. Impeccable's single detector
pass returned `[]`; final independent finish disposition is recorded after review.
The existing stale `.impeccable/design.json` is not repaired by this extension.

## Scope retained for later steps

Full output filtering is Step 8; semantic analysis is Step 10; the separate
Signatures view is Step 11; tool execution and allowlist enforcement are Step 12.
The required semantic adapter remains unavailable, so default gateway readiness
can return 503 while container health is successful. No Coolify deployment was
performed.

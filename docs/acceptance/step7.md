# Step 7 acceptance

Synthetic fixtures only. This is smoke coverage, not a clinical/production PII
quality benchmark or a throughput guarantee.

## Local evidence — 2026-10-03

- `mix precommit`: formatting, strict compilation/Credo, lockfile, JavaScript and
  ExUnit pass: **354 Elixir tests**, 2 opt-in tests excluded, and **3 JavaScript tests**.
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

[Linux CI run 37155097455](https://github.com/jlitewka99/hackyeah2026/actions/runs/37155097455)
passes on commit `46d50c3`. All five jobs pass, including **Phoenix and Polish NER
container**: image build, health/readiness separation, non-root execution,
loopback-only sidecar, real offline models, Elixir release HTTP transport and
UTF-8 redaction, four Python tests, migrations, idempotent organizer bootstrap,
both child-failure exits and clean SIGTERM. The local Docker daemon remains
unavailable; these are actual Linux CI results.

The preserved [benchmark JSON](step7-linux-ner-benchmark.json) measures 40 short
synthetic analyses on Linux x86_64/glibc 2.36, Python 3.11.17, CPU threads 2:
load **7856.8 ms**, p50 **105.4 ms**, p95 **155.5 ms**, peak RSS
**1,049,505,792 bytes** (about 1001 MiB). This is single-process model smoke
coverage, without gateway/network overhead or a production throughput claim.

## UI evidence

Policy v1 upgrade, v2 detector/entity requirements, phases, save/review/activation
and YAML are covered by LiveView regressions. Browser evidence at 1440×1000 and
390×844 in light/dark themes is stored locally under `.impeccable/review/step7-*`.
Keyboard upgrade, native multi-select traversal and visible focus are exercised;
both viewport widths have no horizontal overflow. Impeccable's single detector
pass returned `[]`; the independent finish reviewer returned **ship**, with no
material fixes. The required documentation comparison confirmed the incumbent
design system and recorded the extension in the policy surface brief.
The existing stale `.impeccable/design.json` is not repaired by this extension.

## Scope retained for later steps

Full output filtering is Step 8; semantic analysis is Step 10; the separate
Signatures view is Step 11; tool execution and allowlist enforcement are Step 12.
The required semantic adapter remains unavailable, so default gateway readiness
can return 503 while container health is successful. No Coolify deployment was
performed.

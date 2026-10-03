# Step 8 acceptance

Backend output filtering on `JL/step-8-output-filtering`, based on `origin/main`
at `bd4d6f1` with Steps 1–7 merged. Synthetic fixtures exercise enforcement and
failure handling; they do not establish production PII recall or throughput.

## Behavior

The gateway validates the original provider envelope and proposed calls, then
runs PII/secrets/signatures, NER and the configured semantic guard against fresh
content at each phase. One immutable policy snapshot governs the whole request.
Every phase audits its decision, applies redaction and validates the resulting
envelope, JSON and tool schemas before proceeding. Terminal audit distinguishes
input from output even when validation prevents a guard decision.

Output projection decodes all tool arguments, scans nested keys and leaves,
retains credential property context and renders numbers for detection. Stable
indexes and UTF-8 byte offsets refer to the current projected text. Only
assistant text and string values can be replaced; keys, identifiers, tool names
and non-string values remain immutable. Overlapping ranges merge. Jason encodes
redacted objects again, preserving types and the supported original usage.

JSV 0.25.0 supplies Draft 2020-12 and explicitly declared Draft 7 validation,
including format assertions. Casting and atom creation are disabled. Local
references and embedded metaschemas are supported; no network resolver is
configured. JSV module references and casting extensions are rejected, including
references reachable through nested schema metadata. Compilation and validation
use existing supervised guard tasks, timeout and capacity limits. Schemas come
from the final filtered request sent to the model. Missing parameters permits
any JSON object; duplicate definitions and ambiguous duplicate argument keys
are refused.

Any output policy violation refuses the entire response with the fixed HTTP 403
error and request ID. Redaction incompatible with immutable data or a schema
returns `403 redaction_unavailable`; invalid original output returns 502;
required guard/audit failure returns 503 and overload retains 429. No partial
text or tool proposal is returned, and generation is never retried or rerouted.

## Local checks — 2026-10-04

- Scope: 24 tests pass across `output_content_test.exs`, `tool_schemas_test.exs`
  and `output_filtering_test.exs`.
- `mix precommit`: formatting, strict compilation/Credo, lockfile and regressions
  pass: **378 Elixir tests**, **3 JavaScript tests**, **3 opt-in tests excluded**.
- `mix dialyzer --no-compile`: passes with zero errors and no skips after building
  fresh PLTs for the compiled test environment.
- `mix security`: Sobelow and current dependency audit pass. The existing
  low-confidence policy upload `File.read!` finding is unchanged.
- `PGPORT=55440 MIX_TEST_PARTITION=step8 mix test
  test/ai_control/gateway/live_ner_test.exs --include live_ner`: **2 tests pass**
  against real loopback HTTP NER with checksum-verified offline `pl-nkjp.v1`
  weights, Stanza 1.11.0 and two CPU threads on macOS ARM64.

Coverage includes decoded Unicode escapes and nested arguments, UTF-8 boundary
rejection, overlapping spans, immutable fields, required properties/types,
arrays, additional properties, enum/pattern/format, combinators and local
references. Contract tests enforce declared tools, tool choice, unique IDs and
keys, shared capacity and timeout with lease release. Gateway tests use the real
Step 7 deterministic detectors, controlled NER transport and semantic adapter;
they verify the filtered request contract, fresh fields passed to later guards,
generation-time policy activation and organization isolation.

Failures cover invalid schemas before generation, unusable original arguments,
redaction violating schemas, NER timeout and invalid byte ranges, intermediate
and final decision audit failures, and terminal audit failure. Fixed HTTP errors,
captured logs, persisted audit and both gateway telemetry events exclude fixture
text and argument values. Generation-count assertions reject hidden retries.

## Real NER acceptance

The output test supplies the synthetic Polish sentence with inflected
`Janem Kowalskim`, `ul. Długa 12/3, 00-001 Warszawa` and a checksum-valid PESEL
in both assistant text and a Unicode-escaped tool argument. The real NER sidecar
removes the person and address after deterministic PII redaction; both returned
fields remain valid UTF-8/JSON, and persisted audit contains none of these values.
The existing input acceptance still confirms removal before generation.

Only dedicated temporary organization policies explicitly disable the
unimplemented semantic guard. Production profiles and readiness requirements
are unchanged. Backend responses are controlled fixtures; NER inference and HTTP
transport use the actual local sidecar. This adds enforcement smoke coverage to
Step 7's model acceptance, without a new statistical quality or latency claim.

## Main integration — 2026-10-04

Merged `origin/main` at `a4eca8a`, including the Step 12A tool core. The README
conflict was resolved by retaining both the completed output filtering behavior
and the tool sandbox description. `mix precommit` passes **412 Elixir tests** and
**3 JavaScript tests**, with 3 opt-in tests excluded. Dialyzer reports zero errors;
Sobelow and dependency audit pass. An initial run hit the existing invitation
test's second-boundary timing issue (86,399 versus 86,400 seconds); the isolated
failed-test rerun and subsequent full precommit pass. Invitation code is unchanged.

## Compatibility and remaining integration

There are no UI changes, migrations or new runtime environment variables.
`Stages.evaluate/5` and guard `assess/4` callers remain supported; an optional
stage argument extends terminal audit. Historical policy versions and required
guard defaults are unchanged. API callers now receive errors for invalid tool
schemas, undeclared/disallowed calls, duplicate definitions/IDs/argument keys,
or inconsistent finish reasons. Successful output retains the existing single
choice envelope and supported usage fields.

Step 9 must verify billing after output refusal. Step 10 supplies the actual
semantic provider and model acceptance; this step verifies its adapter contract.
Step 12 owns tool authorization, resource ACL and execution. Default readiness
continues to require configured mandatory controls. No deployment is included.

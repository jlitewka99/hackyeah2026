# Selective Granite Guardian — Step 14

Granite Guardian adds a final semantic check to policy v6. It is disabled by default. Saving a version does not enable it: compare the changes and explicitly activate that version in Policies.

## Runtime setup

Use Ollama 0.35.1 and pull the pinned model:

```sh
ollama pull granite4.1-guardian:8b
curl http://127.0.0.1:11434/api/tags
```

The required full digest is `f82c0882cec110279601307cdd632d868e29f16eaa59947bef51096e5f740492`. The adapter refuses a different digest. Granite is a separate guard; do not add it to the client-facing `GATEWAY_MODELS` allowlist merely to enable the guard.

The existing tokenizer service must load the separately pinned Granite tokenizer. Install its existing locked dependencies, download during setup, and verify offline at startup:

```sh
python3.11 -m venv .venv/tokenizer
.venv/tokenizer/bin/pip install -r sidecar/tokenizer/requirements.lock
.venv/tokenizer/bin/python sidecar/tokenizer/models.py download sidecar/tokenizer/models
.venv/tokenizer/bin/python sidecar/tokenizer/models.py download-granite _build/granite-tokenizer
export TOKENIZER_MODELS_DIR="$PWD/sidecar/tokenizer/models"
export GRANITE_TOKENIZER_MODELS_DIR="$PWD/_build/granite-tokenizer"
.venv/tokenizer/bin/python -m uvicorn service:app --app-dir sidecar/tokenizer \
  --host 127.0.0.1 --port 8002 --workers 1 --no-access-log --log-level critical
```

The manifest [granite.v1.json](../sidecar/tokenizer/granite.v1.json) fixes the tokenizer revision, file size and SHA-256. Requests never download artifacts. `/ready` must list both model digests; `/count` selects a tokenizer by the exact model name and digest.

Configure the application with operator-owned origins:

```sh
export GRANITE_OLLAMA_BASE_URL=http://127.0.0.1:11434
export GRANITE_TOKENIZER_BASE_URL=http://127.0.0.1:8002
```

These fall back to `OLLAMA_BASE_URL` and `TOKENIZER_BASE_URL`. The container includes the verified tokenizer, while Ollama remains external. Existing production database, fingerprint, session and model-catalog settings still apply. Docker Desktop can use `http://host.docker.internal:11434`; use an accessible host origin on Linux.

## Policy activation and criteria

Create a draft from the current policy and select **Upgrade to v6**. v6 retains workflow requirements, finite workflow limits and Knowledge settings from v5 and supports both Granite and human approval independently. Both controls start disabled. Existing review-only and Granite-only v6 snapshots retain their settings and checksums; editing a missing control presents disabled defaults for the next version. Legacy v1–v5 policies keep their validation and checksums.

Enable Granite in **Deep semantic analysis**, configure selectors and criteria, save, inspect the version comparison, then activate. YAML import/export and rollback use the existing version workflow. Rolling back to a policy without Granite removes its checks for subsequent requests; current requests still undergo the existing authorization checks before effects or delivery.

- Suspicious inputs are selected by earlier findings, Qwen `Controversial`/`Unsafe` labels, or a Prompt Guard malicious score at or above the default `0.25` threshold. Earlier blocks stop the pipeline before Granite.
- Default high risk tools are `file.write`, `file.delete`, `http.get`, `email.send`, and `command.run`.
- Privileged paths, tables, endpoints, recipients and commands are exact selectors matching existing sandbox grants. They add checks and never grant access. Wildcards are rejected.
- Groundedness applies to answers with retrieved sources. It uses the exact post-redaction context inserted into the LLM request. Without sources it is recorded as not applicable.

The ready criteria are jailbreak detection, tool alignment and groundedness. Up to eight criteria can be configured, including custom BYOC criteria. Each has an ID, task, text, enabled flag and `block_on: yes | no`. `yes` means that the criterion is met. The ready tool-alignment criterion blocks on `no`; jailbreak and unsupported-fact criteria block on `yes`. Every selected task must have an enabled criterion. Invalid criteria cannot be activated.

The judge receives authenticated identity, verified workflow participation and persisted goal, current policy operations, the authorized action and sandbox grants, and redacted content. Goal, criteria inputs and sources are framed as data. Clients cannot supply model configuration, judging permissions or a verdict. Real tool execution and MCP share the executor; selected proposed tool calls are checked before returning them to a client.

## Failure, timing and audit

Every selected check is mandatory. Capacity exhaustion, deadline expiry, changed digest, invalid result, incomplete response, unavailable authorized context or an oversized prompt blocks the request. Skipped checks require no inference slot. Granite has one execution slot and a shared 60-second deadline across the selected criteria. There are no retries or redirects.

Native `/api/generate` uses `raw: true`, `stream: false`, non-thinking mode, temperature zero and a maximum of 64 result tokens. Exact raw prompt token counts must leave that reserve inside 8192 context tokens. The returned input count must agree with the pinned tokenizer. Parsing accepts one complete `<score>yes|no</score>` with whitespace inside the tag, optionally preceded by one complete thinking section; extra prose, contradictory/multiple scores or incomplete thinking is rejected. Thinking is discarded.

JSON and buffered SSE undergo the same output checks before releasing content. Main LLM usage is settled even if Granite blocks the output. Existing reauthorization before tool effects and response delivery remains in place.

Events and JSONL retain only trigger, criterion ID/hash, task, blocking polarity, model digest, binary result and interpretation, elapsed time and guard token usage for completed calls. They do not retain prompts, tool arguments, source documents, criteria text or reasoning. An interrupted call can have unavailable usage; it must not be recorded as zero measured tokens. Criterion text remains in access-controlled policy versions so operators can edit it.

## Verification

Run `mix precommit` and `mix assets.build`. The Python selected below must contain all locked NER, semantic, Prompt Guard and tokenizer dependencies, as described by `run_security_tests.sh --help` and [Prompt Guard setup](prompt-guard.md). Set `GRANITE_TOKENIZER_MODELS_DIR` to also verify the real Granite tokenizer dispatch.

```sh
GRANITE_ACCEPTANCE_REPORT=_build/granite-acceptance.json \
  mix test test/ai_control/guards/live_granite_test.exs --include live_models
PYTHON=/path/to/locked/sidecar/python ./run_security_tests.sh --live-models
```

The full live gate requires Qwen3.5, NER, Qwen3Guard, Prompt Guard, Granite and both tokenizers. Missing services fail qualification. Do not set a real `GATEWAY_MODELS` catalog for the mixed stub/real test suite; real-model tests set their own pinned catalog. Supply the separate service origins through their existing environment variables.

The Granite fixture contains twelve synthetic safe/unsafe cases across PL/EN input, tools and groundedness. Reports record errors, per-case usage, p50/p95 and the digest. Record Ollama `/api/version` and `/api/ps` alongside each run to retain runtime, quantization and memory information. See the [acceptance report](acceptance/step14-granite-acceptance.md) for results and remaining qualification.

## Limitations

IBM trained and tested this model in English. A small Polish fixture is a smoke test; broader Polish accuracy and prompt-injection robustness require measurement. An 8B judge adds latency, particularly with several criteria or cold model loading. Groundedness checks agreement with supplied sources and does not establish whether those sources are true. A model classification adds a control and cannot create authorization.

References: [IBM model card and prompt format](https://huggingface.co/ibm-granite/granite-guardian-4.1-8b), [Ollama native generation API](https://docs.ollama.com/api/generate).

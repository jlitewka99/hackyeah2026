# Prompt Guard operator setup — Built with Llama

Step 11B adds `meta-llama/Llama-Prompt-Guard-2-86M` for injection detection.
Response moderation continues to use Qwen. Neither provider is automatically
substituted on failure. Model qualification and complete MVP acceptance are
still open; see [the acceptance report](acceptance/step11b.md).

## Access, license and artifacts

The [Meta model card](https://huggingface.co/meta-llama/Llama-Prompt-Guard-2-86M)
requires manually approved Hugging Face access. The operator must review and
accept the **Llama 4 Community License** and Acceptable Use Policy, then supply
an already approved, minimally scoped token. This project does not request
access or accept agreements on anyone's behalf. Qwen's Apache-2.0 license does
not cover Prompt Guard weights. The base architecture's license does not replace
the weights' license.

Retain `LICENSE`, `USE_POLICY.md` and the [notice](../sidecar/prompt_guard/NOTICE.md)
with redistributed artifacts. The project documentation provides the required
**Built with Llama** attribution; operators must also retain the attribution in
applicable product documentation/interfaces and comply with the complete
pinned agreement when distributing or making the model available.

[models.v1.json](../sidecar/prompt_guard/models.v1.json) pins revision
`a8ded8e697ce7c355e395a0df51f94adb4a2fd27`, file sizes, SHA-256 for LFS weights
and tokenizer, and public Git blob SHA-1 identities for the small configuration,
tokenizer metadata, license and use-policy files. The latter are Git content
identities, not claimed SHA-256 hashes; obtaining approved artifacts is still
required for the real-weight acceptance. Verification fails before model load
on any missing, changed or mismatched file. Update the manifest deliberately
when upgrading a model; never silently resolve the latest revision.

## Local setup

Install the existing locked Python runtime (Python 3.11, PyTorch 2.8.0 CPU,
Transformers 4.57.1). The dependencies are shared with the Qwen sidecar; no new
Elixir dependency is needed.

```sh
python3.11 -m venv _build/semantic-venv
_build/semantic-venv/bin/pip install --index-url https://download.pytorch.org/whl/cpu torch==2.8.0
_build/semantic-venv/bin/pip install -r sidecar/prompt_guard/requirements.lock
# Supply HF_TOKEN through your secret manager; do not put it in command arguments.
_build/semantic-venv/bin/python sidecar/prompt_guard/models.py download _build/prompt-guard-models
unset HF_TOKEN
_build/semantic-venv/bin/python sidecar/prompt_guard/models.py verify _build/prompt-guard-models
PROMPT_GUARD_MODELS_DIR="$PWD/_build/prompt-guard-models" PROMPT_GUARD_CPU_THREADS=2 \
  HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1 \
  _build/semantic-venv/bin/python -m uvicorn service:app --app-dir sidecar/prompt_guard \
  --host 127.0.0.1 --port 8004 --workers 1 --no-access-log --log-level critical
```

`PROMPT_GUARD_BASE_URL` defaults to `http://127.0.0.1:8004`. Inference uses CPU
FP32 and two threads by default. `/ready` exposes only pinned identity, busy
state, device/dtype/threads, cold-start time and peak process RSS. `/analyze`
accepts indexed UTF-8 fields and an injection task; it returns only identity,
byte windows, malicious scores and elapsed time. It cannot perform moderation.

The total context includes special tokens and never exceeds 512 tokens. Payload
windows overlap by 64 tokens and use the original token IDs without truncation
or retokenization. The maximum malicious score is compared inclusively with
`rules.prompt_injection.threshold`; a score equal to the threshold triggers the
rule. This softmax score is not a calibrated probability. Requests are limited
to 2 MiB and 128 windows. Oversized work, bad offsets, incomplete coverage,
nonfinite scores, deadlines and model failures are service errors. One inference
request can run at a time; excess requests receive 429. No partial scan is
accepted. Tokenization/inference cannot be forcibly preempted inside a PyTorch
kernel: the application deadline withholds the response, and the sidecar remains
busy until the operation finishes. Neither timeout nor overload is a detection.

Req does not retry or follow redirects. Transport responses are bounded; the
whole guard deadline is at most 30 seconds (an application guard deadline may
be shorter). Audit and JSONL serialization accept only the closed model/window/
score/decision projection. Sidecars bind loopback with access logging disabled;
there is no runtime model download.

## Container

The default build excludes gated weights. After approved access is available:

```sh
DOCKER_BUILDKIT=1 docker build --build-arg WITH_PROMPT_GUARD=1 \
  --secret id=hf_token,env=HF_TOKEN --tag ai-control:step11b .
unset HF_TOKEN
bash docker/smoke ai-control:step11b --prompt-guard
```

The token is a BuildKit secret, never an ARG or runtime environment variable.
Only verified artifacts are copied into the runtime image. `PROMPT_GUARD_ENABLED=1`
starts the fifth supervised process on loopback; its health and unexpected exit
are checked alongside Phoenix, NER, tokenizer and Qwen. The default image retains
four processes and the ungated CI path. The optional GitHub workflow-dispatch
input `prompt_guard=true` requires an approved repository `HF_TOKEN` secret.
This job is intentionally opt-in. No local Docker acceptance is claimed while
the daemon is unavailable.

## Policies and measurement

Upgrade a draft to schema v4, choose `guards.semantic.provider` (`qwen` or
`prompt_guard`), save, review and activate explicitly. Existing v1/v2/v3 policy
records and checksums remain untouched. Upgrades default to Qwen; moderation
always uses Qwen's severity/category mapping. Prompt Guard's profile starting
thresholds are relaxed .90, balanced .80, strict .65; these are authoring defaults,
not a measured recommendation. Qwen injection always requires Jailbreak and
selected severity; its v4 threshold is zero because enforcement uses labels.

The [example policy](prompt-guard-example.yaml) is deliberately **unqualified**.
Only the comparison task can produce `qualified-policy.yaml` after complete,
error-free calibration and test reports. It never activates it. Prepare both
verified services on the same otherwise idle machine, with CPU FP32 and two
threads. Start each freshly and let its load finish before starting the next,
so cold-start measurements are not taken under concurrent model loading. Record
the CPU, RAM, OS and runtime in the hardware description. Measurements run
sequentially: Qwen calibration/test, then Prompt Guard calibration/test. Only
injection rows rank the providers; Qwen moderation rows are reported separately.

```sh
mix help ai_control.benchmark_semantic
mix help ai_control.compare_semantic
mix ai_control.benchmark_semantic --provider prompt_guard --threshold 0.80 \
  --split calibration --output /tmp/pg-calibration --hardware 'CPU/RAM/OS; CPU FP32; 2 threads'
mix ai_control.benchmark_semantic --provider qwen --severities Unsafe,Controversial \
  --split calibration --output /tmp/qwen-calibration --hardware 'same machine'
mix ai_control.compare_semantic --output /tmp/step11b-comparison \
  --hardware 'CPU/RAM/OS; CPU FP32; 2 threads'
```

Output directories must be empty; historical Step 10 measurements cannot be
silently overwritten. The frozen dataset and checksum are unchanged. Calibration
considers exactly Prompt Guard .50–.90 in .05 increments and Qwen Unsafe or
Unsafe+Controversial (Jailbreak in both). Settings are written to `*-frozen.json`
before held-out tests. Each split requires 100 unique injection cases, 25 per
group, no errors, cold start, peak RSS and CPU FP32/two-thread metadata. FPR on
safe+PII must be ≤5%, then mean direct/indirect recall ranks candidates, with p95
as tie-breaker. There is no minimum recall. No qualifying candidate makes the
task exit nonzero and leaves the MVP gate open. Case reports contain IDs and
measurements, not dataset text. Do not tune settings using held-out results.

## Reproducible security checks

Install the locked sidecar dependencies, download/verify the ungated tokenizer
artifacts using the existing [tokenizer setup](../README.md), and set its directory:

```sh
PYTHONPATH=sidecar/prompt_guard _build/semantic-venv/bin/python -m unittest discover -s tests/prompt_guard
PYTHON="$PWD/_build/semantic-venv/bin/python" TOKENIZER_MODELS_DIR="$PWD/_build/tokenizer-models" \
  ./run_security_tests.sh
PYTHON="$PWD/_build/semantic-venv/bin/python" TOKENIZER_MODELS_DIR="$PWD/_build/tokenizer-models" \
  ./run_security_tests.sh --live-models
```

The first command set checks contracts and the shared full ExUnit matrix without
gated weights. The tokenizer contract uses real verified offline tokenizer bytes;
the NER Python suite retains its existing optional real-weight test. `--live-models`
additionally runs real Prompt Guard, Qwen, NER, tokenizer and Ollama integration
tests without skipping missing services. Unavailable dependencies fail the run.
Install all sidecar lockfiles if using a single fresh Python environment; Python
contract tests inject lightweight models where appropriate, and cannot establish
Prompt Guard detection quality. Supply the pinned Ollama model/catalog and all
five local model services before claiming the live gate passed.

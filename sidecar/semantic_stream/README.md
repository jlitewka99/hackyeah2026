# Real Qwen Stream versus Gen experiment

This separate harness uses the existing frozen Polish moderation pairs and the
existing Gen implementation. It does not serve traffic or change active policies.
Stream uses the specialized `stream_moderate_from_ids` classifier and its KV
state, rather than Ollama Chat Completions. Both models run on CPU in FP32 with
the pinned `sidecar/semantic/requirements.lock` runtime (PyTorch 2.8.0,
Transformers 4.57.1, tokenizers 0.22.2).

Prepare artifacts before inference; allow several GB for both weights, runtime,
FP32 tensors and swap. Downloading and inference are separate commands:

```sh
python3.11 -m venv /tmp/step17-runtime
/tmp/step17-runtime/bin/pip install -r sidecar/semantic/requirements.lock
/tmp/step17-runtime/bin/python sidecar/semantic_stream/stream_models.py download /tmp/qwen-stream
/tmp/step17-runtime/bin/python sidecar/semantic/models.py download /tmp/qwen-gen
/tmp/step17-runtime/bin/python sidecar/semantic_stream/stream_models.py verify /tmp/qwen-stream
/tmp/step17-runtime/bin/python sidecar/semantic/models.py verify /tmp/qwen-gen

HF_MODULES_CACHE=/tmp/step17-verified-code /tmp/step17-runtime/bin/python \
  sidecar/semantic_stream/benchmark.py --provider stream --models /tmp/qwen-stream \
  --output /tmp/step17-stream-report --hardware 'Describe CPU, RAM and OS' --threads 2
/tmp/step17-runtime/bin/python sidecar/semantic_stream/benchmark.py \
  --provider gen --models /tmp/qwen-gen --output /tmp/step17-gen-report \
  --hardware 'Describe CPU, RAM and OS' --threads 2
python3 -m unittest discover -s tests/semantic_stream -v
```

Output directories must be empty. Inference forces Hugging Face offline mode and
loads only local, checksum-verified files. Stream's manifest pins weights,
tokenizer, configuration, both custom architecture modules and license at revision
`74e1479150e9029d6778993f00491108323bb6f8`. Gen keeps its existing revision
`fada3b2f655b89601929198343c94cd2f64d93cc`. See [NOTICE](NOTICE.md) for the
custom-code review and license. No artifact is fetched during inference.

For each full prompt–response pair, the Stream tokenizer creates the complete
conversation. The initial user prefix is prefetched once, then exactly one
assistant token is passed per stateful call. Assistant token indexes include
template headers and closing markers. They are unrelated to SSE fragments and
can flag risk before an assistant content token. The first `Unsafe` records its
index and time since classification began, including prompt prefill. Stream
blocks when any assistant token is `Unsafe`; Gen blocks on the full response's
`Unsafe`. Later `Safe` labels do not erase earlier Stream signals. State is closed
after every case, including a timeout.

Reports contain case IDs and results without prompt/response text. `summary.json`
records full and held-out split recall, false-positive rate, warm p50/p95, cold
verification/load time, peak process RSS, runtime versions, revision, hardware
and dataset SHA256. `cases.jsonl` records first detection, assistant token count
and duration. A separate warmup is excluded. The default deadline is 30 seconds;
failed cases are counted explicitly, excluded from accuracy/timing denominators
and cause a nonzero exit. Detection timing is unavailable for Gen until its
full-response classification completes.

These 40 short synthetic pairs are a repeatable experiment, not production
qualification. CPU measurements depend on other workloads and do not measure
gateway latency, GPU throughput, long contexts or future-context recall. A
token-level risk head cannot certify early content release. Production SSE
continues to buffer and use the activated output controls.

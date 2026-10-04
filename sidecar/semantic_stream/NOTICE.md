# Qwen Stream experiment

`models.v1.json` pins Qwen/Qwen3Guard-Stream-0.6B revision
`74e1479150e9029d6778993f00491108323bb6f8`, including its specialized architecture,
tokenizer, license and weight hashes. The model and architecture use Apache-2.0.
The downloaded LICENSE remains with the artifacts.

The architecture imports PyTorch and Transformers operations, including a
relative import of its pinned configuration module. Inspection found no
application-level network, subprocess, filesystem write, eval or exec calls.
Loading uses verified local files, offline Hugging Face settings and eager
attention; no unpinned remote architecture is loaded at inference time.

This harness reuses `sidecar/semantic/requirements.lock` and does not replace
any production guard. Stream's token-level severity is a classifier signal,
not a calibrated probability or a guarantee that future context is harmless.

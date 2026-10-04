"""Compare real Stream and Gen on frozen Polish response pairs; reports contain no source text."""
import argparse
import hashlib
import json
import math
import os
import platform
import resource
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DATASET = ROOT / "priv/benchmarks/semantic-pl.v1.jsonl"


def metrics(rows):
    valid = [row for row in rows if "error_code" not in row]
    positive = [row for row in valid if row["expected_block"]]
    negative = [row for row in valid if not row["expected_block"]]
    timings = sorted(row["duration_us"] for row in valid)
    percentile = lambda value: timings[math.ceil(len(timings) * value) - 1] if timings else None
    return {"cases": len(rows), "completed": len(valid), "errors": len(rows) - len(valid),
        "recall": sum(row["blocked"] for row in positive) / len(positive) if positive else None,
        "false_positive_rate": sum(row["blocked"] for row in negative) / len(negative) if negative else None,
        "p50_us": percentile(0.5), "p95_us": percentile(0.95)}


def dataset():
    raw = DATASET.read_bytes()
    expected = (ROOT / "priv/benchmarks/semantic-pl.v1.sha256").read_text().split()[0]
    if hashlib.sha256(raw).hexdigest() != expected:
        raise ValueError("dataset_checksum_mismatch")
    return [row for row in map(json.loads, raw.decode().splitlines()) if row["task"] == "moderation"]


def run(args):
    os.environ["HF_HUB_OFFLINE"] = "1"
    os.environ["TRANSFORMERS_OFFLINE"] = "1"
    output = Path(args.output)
    output.mkdir(parents=True, exist_ok=True)
    if list(output.iterdir()):
        raise ValueError("output_must_be_empty")
    started = time.monotonic()
    if args.provider == "stream":
        from runtime import StreamGuard
        from stream_models import MANIFEST
        model = StreamGuard(args.models, args.threads)
        classify = lambda row: model.classify(row["prompt"], row["text"], time.monotonic() + args.timeout)
    else:
        sys.path.insert(0, str(ROOT / "sidecar/semantic"))
        os.environ["SEMANTIC_MODELS_DIR"] = args.models
        os.environ["SEMANTIC_CPU_THREADS"] = str(args.threads)
        from service import Qwen
        from models import MANIFEST
        model = Qwen()
        def classify(row):
            severity, _, _ = model.classify(row["text"], "moderation", row["prompt"], time.monotonic() + args.timeout)
            return {"blocked": severity == "Unsafe", "final_severity": severity}
    cold_start = round((time.monotonic() - started) * 1_000_000)
    cases = dataset()
    classify({"prompt": "Opisz pogodę.", "text": "Dziś jest słonecznie."})
    rows = []
    with (output / "cases.jsonl").open("w") as report:
        for case in cases:
            before = time.monotonic()
            row = {key: case[key] for key in ("id", "split", "expected_block")}
            try:
                row.update(classify(case))
            except Exception:
                row["error_code"] = "model_evaluation_failed"
            row["duration_us"] = round((time.monotonic() - before) * 1_000_000)
            rows.append(row)
            report.write(json.dumps(row, ensure_ascii=False) + "\n")
            report.flush()
            print(args.provider, case["id"], row.get("final_severity", row.get("error_code")), flush=True)
    import torch
    import transformers
    import tokenizers
    summary = {"provider": args.provider, "model": MANIFEST["model_id"], "revision": MANIFEST["revision"],
        "hardware": args.hardware, "platform": platform.platform(), "runtime": "transformers-cpu-fp32",
        "torch": torch.__version__, "transformers": transformers.__version__, "tokenizers": tokenizers.__version__,
        "threads": args.threads, "timeout_s": args.timeout, "cold_start_us": cold_start,
        "peak_rss_bytes": resource.getrusage(resource.RUSAGE_SELF).ru_maxrss * (1 if sys.platform == "darwin" else 1024),
        "dataset_sha256": hashlib.sha256(DATASET.read_bytes()).hexdigest(), "mapping": "Unsafe",
        "metrics": metrics(rows), "splits": {split: metrics([row for row in rows if row["split"] == split])
            for split in ("calibration", "test")},
        "notes": ["Stream blocks when any assistant token is Unsafe; Gen classifies the full response.",
            "Assistant token indexes include template tokens; transport chunks are not tokenizer tokens.",
            "Cold start includes artifact verification and runtime/model loading; warm cases follow a separate warmup.",
            "CPU inference only; these results do not activate or qualify a production streaming guard."]}
    (output / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    return 0 if summary["metrics"]["errors"] == 0 else 1


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--provider", choices=["stream", "gen"], required=True)
    parser.add_argument("--models", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--hardware", required=True)
    parser.add_argument("--threads", type=int, default=2)
    parser.add_argument("--timeout", type=int, default=30)
    args = parser.parse_args()
    if args.threads < 1 or args.timeout < 1:
        parser.error("threads and timeout must be positive")
    try:
        sys.exit(run(args))
    except Exception as error:
        print("Comparison unavailable; inspect pinned runtime and artifact prerequisites.",
            type(error).__name__, getattr(error, "errno", None), file=sys.stderr)
        sys.exit(1)

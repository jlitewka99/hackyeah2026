"""Offline Prompt Guard. Only bounded scores and UTF-8 coverage cross the boundary."""
import json
import logging
import math
import os
import resource
import sys
import threading
import time
from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse
from starlette.concurrency import run_in_threadpool
from models import MANIFEST, verify

MAX_BYTES = 2_097_152
MAX_WINDOWS = 128
MAX_TOKENS = 512
OVERLAP = 64


class PromptGuard:
    def __init__(self):
        import torch
        from transformers import AutoConfig, AutoModelForSequenceClassification, AutoTokenizer
        directory = Path(os.environ.get("PROMPT_GUARD_MODELS_DIR", "/app/prompt-guard-models"))
        verify(directory)
        torch.set_num_threads(int(os.environ.get("PROMPT_GUARD_CPU_THREADS", "2")))
        config = AutoConfig.from_pretrained(directory, local_files_only=True)
        labels = {int(k): v.upper() for k, v in config.id2label.items()}
        # This pinned Meta config omits label names; Transformers supplies LABEL_0/1.
        # The published binary head assigns index 0 to benign and 1 to malicious.
        expected = {0: "BENIGN", 1: "MALICIOUS"}
        if config.num_labels != 2 or labels not in (expected, {0: "LABEL_0", 1: "LABEL_1"}):
            raise ValueError("unsupported_labels")
        config.id2label = expected
        config.label2id = {label: index for index, label in expected.items()}
        self.tokenizer = AutoTokenizer.from_pretrained(directory, local_files_only=True)
        self.model = AutoModelForSequenceClassification.from_pretrained(
            directory, config=config, local_files_only=True, dtype=torch.float32).to("cpu").eval()
        if {int(k): v.upper() for k, v in self.model.config.id2label.items()} != expected:
            raise ValueError("unsupported_labels")
        self.special_tokens = self.tokenizer.num_special_tokens_to_add(pair=False)
        self.torch = torch

    def tokenize(self, text):
        value = self.tokenizer(text, add_special_tokens=False, return_offsets_mapping=True, truncation=False)
        return value["input_ids"], value["offset_mapping"]

    def classify(self, tokens, deadline):
        if time.monotonic() >= deadline:
            raise TimeoutError("analysis_timeout")
        ids = self.tokenizer.build_inputs_with_special_tokens(tokens)
        if len(ids) > MAX_TOKENS:
            raise ValueError("context_limit")
        with self.torch.inference_mode():
            tensor = self.torch.tensor([ids], dtype=self.torch.long)
            logits = self.model(input_ids=tensor, attention_mask=self.torch.ones_like(tensor)).logits
            score = self.torch.softmax(logits, dim=-1)[0, 1].item()
        if time.monotonic() >= deadline:
            raise TimeoutError("analysis_timeout")
        return score


def analyze(model, value):
    started = time.monotonic()
    deadline = started + value["timeout_ms"] / 1000
    width = MAX_TOKENS - model.special_tokens
    if width <= OVERLAP:
        raise ValueError("context_limit")
    jobs = []
    for field in value["fields"]:
        text = field["text"]
        ids, offsets = model.tokenize(text)
        if len(ids) != len(offsets) or (text and not ids):
            raise ValueError("incomplete_scan")
        if not text:
            jobs.append((field["field_index"], 0, 0, []))
        else:
            start = 0
            while start < len(ids):
                stop = min(start + width, len(ids))
                first = 0 if start == 0 else offsets[start][0]
                last = len(text) if stop == len(ids) else offsets[stop - 1][1]
                if not 0 <= first < last <= len(text):
                    raise ValueError("invalid_offsets")
                jobs.append((field["field_index"], len(text[:first].encode()), len(text[:last].encode()), ids[start:stop]))
                if len(jobs) > MAX_WINDOWS:
                    raise ValueError("work_limit")
                if stop == len(ids):
                    break
                start = stop - OVERLAP
        if len(jobs) > MAX_WINDOWS or time.monotonic() >= deadline:
            raise TimeoutError("analysis_timeout")
    windows = []
    for index, first, last, tokens in jobs:
        score = model.classify(tokens, deadline) if tokens else 0.0
        if not isinstance(score, (int, float)) or isinstance(score, bool) or not math.isfinite(score) or not 0 <= score <= 1:
            raise ValueError("invalid_score")
        if time.monotonic() >= deadline:
            raise TimeoutError("analysis_timeout")
        windows.append({"field_index": index, "start_byte": first, "end_byte": last, "score": score})
    return {"model_set": MANIFEST["model_set"], "revision": MANIFEST["revision"],
            "task": "injection", "windows": windows,
            "duration_us": round((time.monotonic() - started) * 1_000_000)}


def valid_request(value):
    if not isinstance(value, dict) or set(value) != {"task", "fields", "timeout_ms"} or value["task"] != "injection":
        return False
    if type(value["timeout_ms"]) is not int or not 0 < value["timeout_ms"] <= 30_000:
        return False
    fields = value["fields"]
    return isinstance(fields, list) and 0 < len(fields) <= MAX_WINDOWS and all(
        isinstance(field, dict) and set(field) == {"field_index", "text"}
        and type(field["field_index"]) is int and field["field_index"] == index
        and isinstance(field["text"], str) and not any(0xD800 <= ord(char) <= 0xDFFF for char in field["text"])
        for index, field in enumerate(fields))


def make_app(loader=PromptGuard):
    state = {"model": None, "cold_start_us": 0}
    gate = threading.BoundedSemaphore(1)

    @asynccontextmanager
    async def lifespan(_app):
        for name in ("transformers", "huggingface_hub", "torch"):
            logging.getLogger(name).setLevel(logging.CRITICAL)
        started = time.monotonic()
        state["model"] = await run_in_threadpool(loader)
        state["cold_start_us"] = round((time.monotonic() - started) * 1_000_000)
        yield
        state["model"] = None

    app = FastAPI(lifespan=lifespan, docs_url=None, redoc_url=None, openapi_url=None)

    @app.get("/ready")
    async def ready():
        if state["model"] is None:
            return JSONResponse({"status": "not_ready"}, status_code=503)
        rss = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
        return {"status": "ready", "model_set": MANIFEST["model_set"], "revision": MANIFEST["revision"],
                "cold_start_us": state["cold_start_us"], "peak_rss_bytes": rss if sys.platform == "darwin" else rss * 1024,
                "device": "cpu", "dtype": "float32", "cpu_threads": int(os.environ.get("PROMPT_GUARD_CPU_THREADS", "2")),
                "busy": gate._value == 0}

    @app.post("/analyze")
    async def endpoint(request: Request):
        chunks, size = [], 0
        async for chunk in request.stream():
            size += len(chunk)
            if size > MAX_BYTES:
                return JSONResponse({"error": "input_too_large"}, status_code=413)
            chunks.append(chunk)
        try:
            value = json.loads(b"".join(chunks))
        except (ValueError, UnicodeError):
            return JSONResponse({"error": "invalid_request"}, status_code=400)
        if not valid_request(value):
            return JSONResponse({"error": "invalid_request"}, status_code=400)
        if state["model"] is None:
            return JSONResponse({"error": "not_ready"}, status_code=503)
        if not gate.acquire(blocking=False):
            return JSONResponse({"error": "capacity_exceeded"}, status_code=429)
        try:
            return await run_in_threadpool(analyze, state["model"], value)
        except Exception:
            return JSONResponse({"error": "analysis_unavailable"}, status_code=503)
        finally:
            gate.release()

    return app


app = make_app()

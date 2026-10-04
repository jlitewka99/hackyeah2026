"""Local Qwen classifier. Responses contain labels and coverage, never source text."""
import json
import logging
import os
import re
import resource
import threading
import time
from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse
from starlette.concurrency import run_in_threadpool

from models import MANIFEST, verify

SEVERITIES = {"Safe", "Controversial", "Unsafe"}
CATEGORIES = ["Violent", "Non-violent Illegal Acts", "Sexual Content or Sexual Acts", "PII",
              "Suicide & Self-Harm", "Unethical Acts", "Politically Sensitive Topics",
              "Copyright Violation", "Jailbreak"]
MAX_BYTES = 2_097_152
MAX_WINDOWS = 128
WINDOW = 2048
OVERLAP = 256


def parse_labels(content, task):
    # Reject prose, partial labels and unknown categories rather than matching substrings.
    pattern = r"Safety: (Safe|Unsafe|Controversial)\s*\nCategories: ([^\n]+)"
    if task == "moderation":
        pattern += r"\s*\nRefusal: (Yes|No)"
    match = re.fullmatch(pattern + r"\s*", content.strip())
    if not match:
        raise ValueError("invalid_model_result")
    categories = [value.strip() for value in match[2].split(",")]
    if categories == ["None"]:
        categories = []
    if len(categories) != len(set(categories)) or any(value not in CATEGORIES for value in categories):
        raise ValueError("invalid_model_result")
    if task == "moderation" and "Jailbreak" in categories:
        raise ValueError("invalid_model_result")
    return match[1], categories, match[3] if task == "moderation" else None


class Qwen:
    def __init__(self):
        import torch
        from transformers import AutoModelForCausalLM, AutoTokenizer
        directory = Path(os.environ.get("SEMANTIC_MODELS_DIR", "/app/semantic-models"))
        verify(directory)
        torch.set_num_threads(int(os.environ.get("SEMANTIC_CPU_THREADS", "2")))
        self.tokenizer = AutoTokenizer.from_pretrained(directory, local_files_only=True)
        self.model = AutoModelForCausalLM.from_pretrained(directory, local_files_only=True,
                                                        dtype=torch.float32).to("cpu").eval()
        self.torch = torch

    def offsets(self, text):
        return self.tokenizer(text, add_special_tokens=False, return_offsets_mapping=True)["offset_mapping"]

    def classify(self, text, task, prompt, deadline):
        messages = [{"role": "user", "content": text}]
        if task == "moderation":
            messages = [{"role": "user", "content": prompt}, {"role": "assistant", "content": text}]
        rendered = self.tokenizer.apply_chat_template(messages, tokenize=False)
        inputs = self.tokenizer(rendered, return_tensors="pt", truncation=False)
        if inputs.input_ids.shape[1] + 128 > self.model.config.max_position_embeddings:
            raise ValueError("context_limit")
        from transformers import StoppingCriteria, StoppingCriteriaList

        class Deadline(StoppingCriteria):
            def __call__(self, input_ids, scores, **kwargs):
                return time.monotonic() >= deadline

        with self.torch.inference_mode():
            generated = self.model.generate(**inputs, do_sample=False, max_new_tokens=128,
                stopping_criteria=StoppingCriteriaList([Deadline()]))
        if time.monotonic() >= deadline:
            raise TimeoutError("analysis_timeout")
        output = self.tokenizer.decode(generated[0][inputs.input_ids.shape[1]:], skip_special_tokens=True)
        return parse_labels(output, task)


def analyze(model, value):
    started = time.monotonic()
    deadline = started + min(value["timeout_ms"], 30_000) / 1000
    jobs = []
    for field in value["fields"]:
        text = field["text"]
        offsets = model.offsets(text)
        if not text:
            jobs.append((field["field_index"], 0, 0, ""))
        elif not offsets:
            raise ValueError("incomplete_scan")
        else:
            start = 0
            while start < len(offsets):
                stop = min(start + WINDOW, len(offsets))
                first = 0 if start == 0 else offsets[start][0]
                last = len(text) if stop == len(offsets) else offsets[stop - 1][1]
                jobs.append((field["field_index"], len(text[:first].encode()), len(text[:last].encode()), text[first:last]))
                if stop == len(offsets):
                    break
                start = stop - OVERLAP
        if len(jobs) > MAX_WINDOWS or time.monotonic() >= deadline:
            raise ValueError("work_limit")
    windows = []
    for index, first, last, text in jobs:
        if time.monotonic() >= deadline:
            raise TimeoutError("analysis_timeout")
        severity, categories, refusal = model.classify(text, value["task"], value.get("prompt", ""), deadline) if text or value["task"] == "moderation" else ("Safe", [], None)
        windows.append({"field_index": index, "start_byte": first, "end_byte": last,
                        "severity": severity, "categories": categories, "refusal": refusal})
    return {"model_set": MANIFEST["model_set"], "revision": MANIFEST["revision"],
            "task": value["task"], "windows": windows,
            "duration_us": round((time.monotonic() - started) * 1_000_000)}


def valid_request(value):
    if not isinstance(value, dict) or value.get("task") not in {"injection", "moderation"}:
        return False
    keys = {"task", "fields", "timeout_ms"} | ({"prompt"} if value["task"] == "moderation" else set())
    if set(value) != keys or type(value["timeout_ms"]) is not int or not 0 < value["timeout_ms"] <= 30_000:
        return False
    if value["task"] == "moderation" and not isinstance(value.get("prompt"), str):
        return False
    fields = value.get("fields")
    return isinstance(fields, list) and 0 < len(fields) <= MAX_WINDOWS and all(
        isinstance(field, dict) and set(field) == {"field_index", "text"}
        and type(field["field_index"]) is int and field["field_index"] == index
        and isinstance(field["text"], str) and not any(0xD800 <= ord(char) <= 0xDFFF for char in field["text"])
        for index, field in enumerate(fields)) and not any(0xD800 <= ord(char) <= 0xDFFF for char in value.get("prompt", ""))


def make_app(loader=Qwen):
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
        import sys
        return {"status": "ready", "model_set": MANIFEST["model_set"], "revision": MANIFEST["revision"],
                "cold_start_us": state["cold_start_us"], "peak_rss_bytes": rss if sys.platform == "darwin" else rss * 1024,
                "device": "cpu", "dtype": "float32", "cpu_threads": int(os.environ.get("SEMANTIC_CPU_THREADS", "2")),
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

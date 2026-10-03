"""Private exact token counts. No inference, telemetry payloads, or runtime downloads."""
import json
import os
from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse
from tokenizers import Tokenizer

from models import MANIFEST, verify

LIMIT = 4_194_304
TOKENIZER = None


@asynccontextmanager
async def lifespan(app):
    global TOKENIZER
    directory = Path(os.environ.get("TOKENIZER_MODELS_DIR", Path(__file__).parent / "models"))
    verify(directory)
    TOKENIZER = Tokenizer.from_file(str(directory / "tokenizer.json"))
    yield
    TOKENIZER = None


app = FastAPI(lifespan=lifespan, docs_url=None, redoc_url=None, openapi_url=None)


@app.get("/ready")
def ready():
    if TOKENIZER is None:
        return JSONResponse({"error": "tokenizer_unavailable"}, status_code=503)
    return {"status": "ready", "models": {MANIFEST["model"]: MANIFEST["digest"]},
            "runtime": MANIFEST["runtime"]}


@app.post("/count")
async def count(request: Request):
    body = bytearray()
    async for chunk in request.stream():
        body.extend(chunk)
        if len(body) > LIMIT:
            return JSONResponse({"error": "input_too_large"}, status_code=413)
    try:
        data = json.loads(body)
        if (not isinstance(data, dict) or set(data) != {"model", "digest", "prompt"}
                or data["model"] != MANIFEST["model"] or data["digest"] != MANIFEST["digest"]
                or not isinstance(data["prompt"], str)):
            raise ValueError()
        data["prompt"].encode("utf-8", errors="strict")
        if TOKENIZER is None:
            return JSONResponse({"error": "tokenizer_unavailable"}, status_code=503)
        # Ollama-rendered prompt already contains the exact special tokens.
        tokens = len(TOKENIZER.encode(data["prompt"], add_special_tokens=False).ids)
        return {"tokens": tokens, "digest": MANIFEST["digest"], "runtime": MANIFEST["runtime"]}
    except (ValueError, TypeError, UnicodeError, OverflowError):
        return JSONResponse({"error": "invalid_request"}, status_code=400)

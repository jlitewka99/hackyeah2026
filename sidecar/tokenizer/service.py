"""Private exact token counts. No inference, telemetry payloads, or runtime downloads."""
import json
import os
from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse
from deepseek_recipe import ChatCompletionRequest, ConversionOptions, DeepseekV41Encoding, Tokenizer
from importlib.metadata import version
from tokenizers import Tokenizer as GraniteTokenizer

from models import MANIFEST, GRANITE_MANIFEST, verify

LIMIT = 4_194_304
TOKENIZER = None
GRANITE_TOKENIZER = None


@asynccontextmanager
async def lifespan(app):
    global TOKENIZER, GRANITE_TOKENIZER
    directory = Path(os.environ.get("TOKENIZER_MODELS_DIR", Path(__file__).parent / "models"))
    verify(directory)
    if version("deepseek-recipe") != MANIFEST["recipe_version"]:
        raise RuntimeError("tokenizer_recipe_mismatch")
    TOKENIZER = DeepseekV41Encoding().with_tokenizer(
        Tokenizer.from_file(str(directory / "tokenizer.json")))
    granite_directory = os.environ.get("GRANITE_TOKENIZER_MODELS_DIR")
    if granite_directory:
        verify(granite_directory, GRANITE_MANIFEST)
        GRANITE_TOKENIZER = GraniteTokenizer.from_file(str(Path(granite_directory) / "tokenizer.json"))
    yield
    TOKENIZER = None
    GRANITE_TOKENIZER = None


app = FastAPI(lifespan=lifespan, docs_url=None, redoc_url=None, openapi_url=None)


@app.get("/ready")
def ready():
    if TOKENIZER is None:
        return JSONResponse({"error": "tokenizer_unavailable"}, status_code=503)
    models = {}
    if GRANITE_TOKENIZER is not None:
        models[GRANITE_MANIFEST["model"]] = GRANITE_MANIFEST["digest"]
    return {"status": "ready", "model": MANIFEST["model"],
            "tokenizer_sha256": MANIFEST["files"][0]["sha256"],
            "recipe_version": MANIFEST["recipe_version"], "encoding": MANIFEST["encoding"],
            "models": models, "runtime": GRANITE_MANIFEST["runtime"]}


@app.post("/count")
async def count(request: Request):
    body = bytearray()
    async for chunk in request.stream():
        body.extend(chunk)
        if len(body) > LIMIT:
            return JSONResponse({"error": "input_too_large"}, status_code=413)
    try:
        data = json.loads(body)
        if not isinstance(data, dict):
            raise ValueError()
        json.dumps(data, ensure_ascii=False).encode("utf-8", errors="strict")
        if data.get("model") == GRANITE_MANIFEST["model"]:
            if (set(data) != {"model", "digest", "prompt"}
                    or data["digest"] != GRANITE_MANIFEST["digest"]
                    or not isinstance(data["prompt"], str)):
                raise ValueError()
            if GRANITE_TOKENIZER is None:
                return JSONResponse({"error": "tokenizer_unavailable"}, status_code=503)
            # The Granite guard's raw prompt already contains its special tokens.
            tokens = len(GRANITE_TOKENIZER.encode(data["prompt"], add_special_tokens=False).ids)
            return {"tokens": tokens, "digest": GRANITE_MANIFEST["digest"],
                    "runtime": GRANITE_MANIFEST["runtime"]}
        if (set(data) != {"model", "request"}
                or data.get("model") != MANIFEST["model"]
                or not valid_request(data["request"])):
            raise ValueError()
        if TOKENIZER is None:
            return JSONResponse({"error": "tokenizer_unavailable"}, status_code=503)
        converted = ChatCompletionRequest(data["request"]).convert(ConversionOptions())
        tokens = len(TOKENIZER.encode(converted.conversation))
        return {"tokens": tokens, "model": MANIFEST["model"],
                "tokenizer_sha256": MANIFEST["files"][0]["sha256"],
                "recipe_version": MANIFEST["recipe_version"], "encoding": MANIFEST["encoding"]}
    except (ValueError, TypeError, UnicodeError, OverflowError, RuntimeError):
        return JSONResponse({"error": "invalid_request"}, status_code=400)


def valid_request(payload):
    if not isinstance(payload, dict):
        return False
    messages = payload.get("messages")
    if (payload.get("model") != MANIFEST["model"]
            or payload.get("thinking") != {"type": "disabled"}
            or not isinstance(messages, list) or not 1 <= len(messages) <= 1000):
        return False
    for message in messages:
        if (not isinstance(message, dict)
                or message.get("role") not in {"system", "user", "assistant", "tool"}
                or not (isinstance(message.get("content"), str)
                        or (message.get("role") == "assistant"
                            and message.get("content") is None
                            and isinstance(message.get("tool_calls"), list)))):
            return False
    return True

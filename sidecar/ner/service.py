"""Local Presidio/Stanza gateway. Never return text, snippets or exception messages."""
import json
import logging
import math
import os
import threading
from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse
from starlette.concurrency import run_in_threadpool

MODEL_SET = "pl-nkjp.v1"
ENTITIES = ["person", "address", "place", "geographical_location", "organization"]
MAX_BYTES = 1_048_576


def load_analyzer():
    import torch
    from presidio_analyzer import AnalyzerEngine, Pattern, PatternRecognizer, RecognizerRegistry
    from presidio_analyzer.nlp_engine import NerModelConfiguration, StanzaNlpEngine
    import spacy
    import stanza
    from presidio_analyzer.nlp_engine.stanza_nlp_engine import StanzaTokenizer
    from presidio_analyzer.predefined_recognizers import StanzaRecognizer
    from models import verify

    model_dir = Path(os.environ.get("STANZA_RESOURCES_DIR", "/app/models"))
    verify(model_dir)
    torch.set_num_threads(int(os.environ.get("NER_CPU_THREADS", "2")))
    # NKJP scores are recognizer scores, not calibrated probabilities.
    mapping = {"persName": "person", "placeName": "place", "geogName": "geographical_location", "orgName": "organization"}
    configuration = NerModelConfiguration(model_to_presidio_entity_mapping=mapping, labels_to_ignore=["date", "time"], low_score_entity_names=[])

    class PolishEngine(StanzaNlpEngine):
        def load(self):
            pipeline = stanza.Pipeline("pl", dir=str(model_dir), package=None,
                processors={"tokenize": "pdb", "mwt": "pdb", "pos": "pdb", "lemma": "pdb", "ner": "nkjp"},
                download_method=None, device="cpu", verbose=False)
            nlp = spacy.blank("pl")
            nlp.tokenizer = StanzaTokenizer(pipeline, nlp.vocab)
            self.nlp = {"pl": nlp}

    engine = PolishEngine(models=[{"lang_code": "pl", "model_name": "pl"}], ner_model_configuration=configuration, download_if_missing=False)
    engine.load()
    ner = StanzaRecognizer(supported_language="pl", supported_entities=list(mapping.values()))
    address = PatternRecognizer(supported_entity="address", supported_language="pl", patterns=[Pattern(
        "polish_street_address",
        r"(?<!\w)(?:ul\.|ulica|al\.|aleja|pl\.|plac)[ \t]+[\p{L}][\p{L} .'-]{1,100}[ \t]+[0-9]{1,5}[A-Za-z]?(?:/[0-9]{1,5})?(?:,[ \t]*[0-9]{2}-[0-9]{3}[ \t]+[\p{L}][\p{L} '-]{1,60})?",
        0.85)])
    registry = RecognizerRegistry(recognizers=[ner, address], supported_languages=["pl"])
    return AnalyzerEngine(registry=registry, nlp_engine=engine, supported_languages=["pl"], log_decision_process=False)


def analyze(analyzer, fields):
    findings = []
    for field in fields:
        text = field["text"]
        if not text:
            continue
        results = analyzer.analyze(text=text, language="pl", entities=ENTITIES)
        for result in results:
            if result.entity_type not in ENTITIES or not 0 <= result.start < result.end <= len(text) or not math.isfinite(result.score) or not 0 <= result.score <= 1:
                raise ValueError("invalid_model_result")
            findings.append({"field_index": field["field_index"], "type": result.entity_type,
                "score": float(result.score), "detector_id": f"ner.{result.entity_type}.v1",
                "start_byte": len(text[:result.start].encode("utf-8")),
                "end_byte": len(text[:result.end].encode("utf-8"))})
            if len(findings) > 20_000:
                raise ValueError("too_many_results")
    return {"model_set": MODEL_SET, "detections": findings}


def valid_fields(value):
    if not isinstance(value, dict) or set(value) != {"fields"} or not isinstance(value["fields"], list):
        return False
    if len(value["fields"]) > 20_000:
        return False
    return all(isinstance(field, dict) and set(field) == {"field_index", "text"}
        and type(field["field_index"]) is int and field["field_index"] == index
        and isinstance(field["text"], str) and not any(0xD800 <= ord(char) <= 0xDFFF for char in field["text"])
        for index, field in enumerate(value["fields"]))


def make_app(loader=load_analyzer):
    state = {"analyzer": None}
    gate = threading.BoundedSemaphore(1)

    @asynccontextmanager
    async def lifespan(_app):
        # Third-party debug output can contain NLP artifacts; do not enable it.
        for name in ("presidio-analyzer", "stanza"):
            logging.getLogger(name).setLevel(logging.CRITICAL)
        state["analyzer"] = await run_in_threadpool(loader)
        yield
        state["analyzer"] = None

    app = FastAPI(lifespan=lifespan, docs_url=None, redoc_url=None, openapi_url=None)

    @app.get("/ready")
    async def ready():
        if state["analyzer"] is None:
            return JSONResponse({"status": "not_ready"}, status_code=503)
        return {"status": "ready", "model_set": MODEL_SET}

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
        if not valid_fields(value):
            return JSONResponse({"error": "invalid_request"}, status_code=400)
        if state["analyzer"] is None:
            return JSONResponse({"error": "not_ready"}, status_code=503)
        if not gate.acquire(blocking=False):
            return JSONResponse({"error": "capacity_exceeded"}, status_code=429)
        try:
            return await run_in_threadpool(analyze, state["analyzer"], value["fields"])
        except Exception:
            return JSONResponse({"error": "analysis_unavailable"}, status_code=503)
        finally:
            gate.release()

    return app


app = make_app()

"""Real pinned V4.1 encoding, full requests and content-free failure boundaries."""
import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from fastapi.testclient import TestClient
from models import MANIFEST, GRANITE_MANIFEST, verify
from service import app


class TokenizerTest(unittest.TestCase):
    def setUp(self):
        self.client = TestClient(app)
        self.client.__enter__()

    def tearDown(self):
        self.client.__exit__(None, None, None)

    def payload(self, text):
        return {"model": MANIFEST["model"], "request": {
            "model": MANIFEST["model"], "thinking": {"type": "disabled"},
            "stream": False, "max_tokens": 32,
            "messages": [{"role": "user", "content": text}]}}

    def tokens(self, payload):
        response = self.client.post("/count", json=payload)
        self.assertEqual(response.status_code, 200, response.text)
        return response.json()["tokens"]

    def test_ready_and_real_unicode_tokens(self):
        ready = self.client.get("/ready").json()
        self.assertEqual(ready["status"], "ready")
        self.assertEqual(ready["recipe_version"], "0.1.1")
        self.assertNotIn(MANIFEST["model"], ready["models"])
        response = self.client.post("/count", json=self.payload("Zażółć gęślą jaźń 😀"))
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json()["tokens"], 17)
        self.assertNotIn("Zażółć", response.text)
        self.assertEqual(response.json()["tokenizer_sha256"], MANIFEST["files"][0]["sha256"])

    def test_history_rag_tools_and_tool_results_are_counted(self):
        payload = self.payload("Podsumuj wynik.")
        basic = self.tokens(payload)
        payload["request"]["messages"].insert(0, {
            "role": "user", "name": "retrieved_context",
            "content": "Dane RAG: wsparcie działa od 9 do 17. " * 10})
        rag = self.tokens(payload)
        self.assertGreater(rag, basic)
        payload["request"]["tools"] = [{"type": "function", "function": {
            "name": "city_info", "description": "Informacje o mieście",
            "parameters": {"type": "object", "properties": {
                "city": {"type": "string"}}}}}]
        tools = self.tokens(payload)
        self.assertGreater(tools, rag)
        payload["request"]["messages"][1:1] = [
            {"role": "user", "content": "Sprawdź Kraków."},
            {"role": "assistant", "content": None, "tool_calls": [{
                "id": "call_city", "type": "function", "function": {
                    "name": "city_info", "arguments": '{"city":"Kraków"}'}}]},
            {"role": "tool", "tool_call_id": "call_city", "content": "Kraków leży nad Wisłą."}]
        self.assertGreater(self.tokens(payload), tools)
        payload["request"]["stream"] = True
        payload["request"]["stream_options"] = {"include_usage": True}
        streaming = self.tokens(payload)
        payload["request"]["stream"] = False
        del payload["request"]["stream_options"]
        self.assertEqual(streaming, self.tokens(payload))

    def test_wrong_model_extra_fields_images_and_invalid_utf8(self):
        invalid = []
        for key, value in [("model", "other"), ("secret", "private"), ("request", "hello")]:
            payload = self.payload("hello")
            payload[key] = value
            invalid.append(payload)
        payload = self.payload("hello")
        payload["request"]["messages"][0]["content"] = [{"type": "image_url", "image_url": {
            "url": "https://private.invalid/secret"}}]
        invalid.append(payload)
        payload = self.payload("hello")
        payload["request"]["thinking"] = {"type": "enabled"}
        invalid.append(payload)
        for payload in invalid:
            response = self.client.post("/count", json=payload)
            self.assertEqual(response.status_code, 400)
            self.assertEqual(response.json(), {"error": "invalid_request"})
        payload = self.payload("\ud800")
        self.assertEqual(self.client.post("/count", content=json.dumps(payload)).status_code, 400)
        self.assertEqual(self.client.post("/count", content=b"\xff").status_code, 400)

    def test_oversized_malformed_and_unavailable_are_content_free(self):
        self.assertEqual(self.client.post("/count", content=b"x" * 4_194_305).status_code, 413)
        self.assertEqual(self.client.post("/count", content=b"private-secret").status_code, 400)
        self.assertEqual(self.client.get("/docs").status_code, 404)
        with patch("service.TOKENIZER", None):
            self.assertEqual(self.client.get("/ready").status_code, 503)
            self.assertEqual(self.client.post("/count", json=self.payload("secret")).status_code, 503)

    def test_missing_or_changed_artifacts_fail_verification(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaises(RuntimeError):
                verify(directory)
            Path(directory, "tokenizer.json").write_bytes(b"changed")
            with self.assertRaises(RuntimeError):
                verify(directory)

    def test_granite_exact_prompt_uses_its_own_pinned_tokenizer(self):
        payload = {"model": GRANITE_MANIFEST["model"], "digest": GRANITE_MANIFEST["digest"],
                   "prompt": "<|start_of_role|>user<|end_of_role|>Zażółć gęślą jaźń<|end_of_text|>"}
        response = self.client.post("/count", json=payload)
        if os.environ.get("GRANITE_TOKENIZER_MODELS_DIR"):
            self.assertEqual(response.status_code, 200)
            from tokenizers import Tokenizer
            tokenizer = Tokenizer.from_file(str(Path(os.environ["GRANITE_TOKENIZER_MODELS_DIR"]) / "tokenizer.json"))
            self.assertEqual(response.json()["tokens"], len(tokenizer.encode(payload["prompt"], add_special_tokens=False).ids))
            self.assertEqual(response.json()["digest"], GRANITE_MANIFEST["digest"])
            self.assertIn(GRANITE_MANIFEST["model"], self.client.get("/ready").json()["models"])
        else:
            self.assertEqual(response.status_code, 503)
        payload["digest"] = MANIFEST["files"][0]["sha256"]
        self.assertEqual(self.client.post("/count", json=payload).status_code, 400)

    def test_model_counting_contracts_cannot_be_interchanged(self):
        raw = {"model": MANIFEST["model"], "digest": GRANITE_MANIFEST["digest"],
               "prompt": "private guard prompt"}
        self.assertEqual(self.client.post("/count", json=raw).status_code, 400)
        prepared = self.payload("private message")
        prepared["model"] = GRANITE_MANIFEST["model"]
        self.assertEqual(self.client.post("/count", json=prepared).status_code, 400)
        with patch("service.GRANITE_TOKENIZER", None):
            self.assertEqual(self.client.get("/ready").json()["models"], {})
            self.assertEqual(self.client.post("/count", json=self.payload("hello")).status_code, 200)
            raw["model"] = GRANITE_MANIFEST["model"]
            self.assertEqual(self.client.post("/count", json=raw).status_code, 503)

    def test_granite_missing_artifact_fails_verified_setup(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaises(RuntimeError):
                verify(directory, GRANITE_MANIFEST)
            Path(directory, "tokenizer.json").write_bytes(b"changed")
            with self.assertRaises(RuntimeError):
                verify(directory, GRANITE_MANIFEST)


if __name__ == "__main__":
    unittest.main()

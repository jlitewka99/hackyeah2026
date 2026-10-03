"""Uses the real pinned tokenizer offline, including digest and request boundaries."""
import json
import tempfile
import unittest
from pathlib import Path

from fastapi.testclient import TestClient
from models import MANIFEST, verify
from service import app


class TokenizerTest(unittest.TestCase):
    def setUp(self):
        self.client = TestClient(app)
        self.client.__enter__()

    def tearDown(self):
        self.client.__exit__(None, None, None)

    def payload(self, text):
        return {"model": MANIFEST["model"], "digest": MANIFEST["digest"], "prompt": text}

    def test_ready_and_real_unicode_tokens(self):
        self.assertEqual(self.client.get("/ready").json()["status"], "ready")
        text = "<|im_start|>user\nZażółć gęślą jaźń 😀<|im_end|>\n<|im_start|>assistant\n"
        response = self.client.post("/count", json=self.payload(text))
        self.assertEqual(response.status_code, 200)
        self.assertGreater(response.json()["tokens"], 0)
        self.assertNotIn("Zażółć", response.text)
        self.assertEqual(response.json()["digest"], MANIFEST["digest"])

    def test_wrong_model_digest_extra_fields_and_invalid_utf8(self):
        for key, value in [("model", "other"), ("digest", "b" * 64), ("secret", "private")]:
            payload = self.payload("hello")
            payload[key] = value
            response = self.client.post("/count", json=payload)
            self.assertEqual(response.status_code, 400)
            self.assertEqual(response.json(), {"error": "invalid_request"})
        payload = self.payload("\ud800")
        self.assertEqual(self.client.post("/count", content=json.dumps(payload)).status_code, 400)
        self.assertEqual(self.client.post("/count", content=b"\xff").status_code, 400)

    def test_oversized_and_malformed_payloads_are_content_free(self):
        self.assertEqual(self.client.post("/count", content=b"x" * 4_194_305).status_code, 413)
        self.assertEqual(self.client.post("/count", content=b"private-secret").status_code, 400)
        self.assertEqual(self.client.get("/docs").status_code, 404)

    def test_missing_or_changed_artifacts_fail_verification(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaises(RuntimeError):
                verify(directory)
            Path(directory, "tokenizer.json").write_bytes(b"changed")
            with self.assertRaises(RuntimeError):
                verify(directory)


if __name__ == "__main__":
    unittest.main()

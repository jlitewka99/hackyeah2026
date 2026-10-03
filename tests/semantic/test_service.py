"""Contract tests do not download models. Real weights have a separate suite."""
import sys
import time
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "sidecar" / "semantic"))
from fastapi.testclient import TestClient
from service import Qwen, analyze, make_app, parse_labels, valid_request


class Fake:
    def offsets(self, text):
        return [(index, index + 1) for index in range(len(text))]

    def classify(self, text, task, prompt, deadline):
        return ("Unsafe", ["Jailbreak"], None) if "ATTACK" in text else ("Safe", [], "Yes" if task == "moderation" else None)


def request(text="hello", task="injection"):
    value = {"task": task, "fields": [{"field_index": 0, "text": text}], "timeout_ms": 30_000}
    if task == "moderation":
        value["prompt"] = "safe input"
    return value


class ServiceTest(unittest.TestCase):
    def test_tail_overlap_and_unicode_are_scanned(self):
        value = request("ą" * 2044 + "ATTACK" + "ę" * 3000)
        result = analyze(Fake(), value)
        self.assertTrue(any(window["severity"] == "Unsafe" for window in result["windows"]))
        self.assertEqual(result["windows"][0]["start_byte"], 0)
        self.assertEqual(result["windows"][-1]["end_byte"], len(value["fields"][0]["text"].encode()))
        self.assertNotIn("ATTACK", str(result))

    def test_work_limit_and_deadline_fail(self):
        with self.assertRaises(ValueError):
            analyze(Fake(), request("x" * (2048 * 129)))
        from unittest.mock import patch
        with patch("service.time.monotonic", side_effect=[0, 31]):
            with self.assertRaises(ValueError):
                analyze(Fake(), request())

    def test_unknown_labels_and_extra_prose_are_errors(self):
        for output in ["Safety: Unknown\nCategories: None", "Safety: Unsafe\nCategories: Unknown", "Safety: Safe\nCategories: None\nsource text"]:
            with self.assertRaises(ValueError):
                parse_labels(output, "injection")
        self.assertEqual(parse_labels("Safety: Safe\nCategories: None\nRefusal: Yes", "moderation"), ("Safe", [], "Yes"))

    def test_invalid_requests_do_not_echo_source(self):
        for value in [request() | {"extra": "DO-NOT-LOG"}, request() | {"timeout_ms": True}, request("\ud800")]:
            self.assertFalse(valid_request(value))
        with TestClient(make_app(Fake)) as client:
            self.assertEqual(client.get("/ready").status_code, 200)
            result = client.post("/analyze", json=request() | {"extra": "DO-NOT-LOG"})
            self.assertEqual(result.status_code, 400)
            self.assertNotIn("DO-NOT-LOG", result.text)
            self.assertEqual(client.post("/analyze", json=request()).status_code, 200)

    def test_model_exception_is_content_free(self):
        class Broken(Fake):
            def classify(self, *args):
                raise ValueError("DO-NOT-LOG")
        with TestClient(make_app(Broken)) as client:
            result = client.post("/analyze", json=request())
            self.assertEqual(result.status_code, 503)
            self.assertNotIn("DO-NOT-LOG", result.text)

    def test_moderation_context_is_never_truncated(self):
        from types import SimpleNamespace

        class Tokenizer:
            def apply_chat_template(self, messages, **kwargs):
                self.messages = messages
                return "rendered"

            def __call__(self, text, **kwargs):
                self.kwargs = kwargs
                return SimpleNamespace(input_ids=SimpleNamespace(shape=(1, 32700)))

        model = Qwen.__new__(Qwen)
        model.tokenizer = Tokenizer()
        model.model = SimpleNamespace(config=SimpleNamespace(max_position_embeddings=32768))
        with self.assertRaisesRegex(ValueError, "context_limit"):
            model.classify("complete response", "moderation", "complete prompt", time.monotonic() + 30)
        self.assertFalse(model.tokenizer.kwargs["truncation"])
        self.assertEqual(model.tokenizer.messages[0]["content"], "complete prompt")
        self.assertEqual(model.tokenizer.messages[1]["content"], "complete response")

    def test_capacity_is_bounded_and_readiness_reports_busy(self):
        from concurrent.futures import ThreadPoolExecutor
        from threading import Event
        entered, release = Event(), Event()

        class Waiting(Fake):
            def classify(self, *args):
                entered.set()
                if not release.wait(5):
                    raise TimeoutError("test synchronization")
                return super().classify(*args)

        with TestClient(make_app(Waiting)) as client, ThreadPoolExecutor(max_workers=1) as pool:
            first = pool.submit(client.post, "/analyze", json=request())
            self.assertTrue(entered.wait(5))
            try:
                self.assertTrue(client.get("/ready").json()["busy"])
                self.assertEqual(client.post("/analyze", json=request()).status_code, 429)
            finally:
                release.set()
            self.assertEqual(first.result().status_code, 200)
            self.assertFalse(client.get("/ready").json()["busy"])

    def test_empty_moderation_response_still_checks_context(self):
        class ContextLimit(Fake):
            def classify(self, text, task, prompt, deadline):
                self.asserted = (text, task, prompt)
                raise ValueError("context_limit")

        model = ContextLimit()
        with self.assertRaisesRegex(ValueError, "context_limit"):
            analyze(model, request("", "moderation"))
        self.assertEqual(model.asserted, ("", "moderation", "safe input"))


if __name__ == "__main__":
    unittest.main()

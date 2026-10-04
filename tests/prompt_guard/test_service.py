"""Offline contracts; fake tokenization cannot qualify real-weight detection quality."""
import hashlib
import json
import math
import os
import sys
import tempfile
import unittest
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from threading import Event
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "sidecar" / "prompt_guard"))
from fastapi.testclient import TestClient
from service import PromptGuard, analyze, make_app, valid_request
from models import verify


class Fake:
    special_tokens = 2

    def tokenize(self, text):
        return [ord(char) for char in text], [(i, i + 1) for i in range(len(text))]

    def classify(self, tokens, deadline):
        assert len(tokens) + self.special_tokens <= 512
        return 0.95 if "ATTACK" in "".join(map(chr, tokens)) else 0.01


def request(text="safe"):
    return {"task": "injection", "fields": [{"field_index": 0, "text": text}], "timeout_ms": 30000}


class ServiceTest(unittest.TestCase):
    def test_offline_loader_assigns_published_binary_head_labels(self):
        # Real pinned config has no id2label. Exercise actual offline AutoConfig
        # resolution without gated weights; incompatible heads must still fail.
        for labels, count, valid in [
            (None, 2, True),
            ({"0": "BENIGN", "1": "MALICIOUS"}, 2, True),
            ({"0": "MALICIOUS", "1": "BENIGN"}, 2, False),
            (None, 3, False),
        ]:
            with self.subTest(labels=labels, count=count), tempfile.TemporaryDirectory() as directory:
                config = {"model_type": "deberta-v2", "num_labels": count}
                if labels is not None:
                    config["id2label"] = labels
                (Path(directory) / "config.json").write_text(json.dumps(config))
                tokenizer = Mock()
                tokenizer.num_special_tokens_to_add.return_value = 2

                def load_model(*args, **kwargs):
                    model = Mock(config=kwargs["config"])
                    model.to.return_value = model
                    model.eval.return_value = model
                    return model

                with patch.dict(os.environ, {"PROMPT_GUARD_MODELS_DIR": directory}), \
                        patch("service.verify"), \
                        patch("transformers.AutoTokenizer.from_pretrained", return_value=tokenizer), \
                        patch("transformers.AutoModelForSequenceClassification.from_pretrained", side_effect=load_model) as loader:
                    if valid:
                        model = PromptGuard()
                        self.assertEqual(model.model.config.id2label, {0: "BENIGN", 1: "MALICIOUS"})
                        self.assertEqual(model.model.config.label2id, {"BENIGN": 0, "MALICIOUS": 1})
                        self.assertTrue(loader.call_args.kwargs["local_files_only"])
                    else:
                        with self.assertRaisesRegex(ValueError, "unsupported_labels"):
                            PromptGuard()
                        loader.assert_not_called()

    def test_tail_boundary_and_utf8_complete_coverage(self):
        for text in ["ą" * 507 + "ATTACK" + "ę" * 1000, "😀" * 1500 + "ATTACK"]:
            response = analyze(Fake(), request(text))
            self.assertGreaterEqual(max(w["score"] for w in response["windows"]), 0.95)
            covered = 0
            for window in response["windows"]:
                self.assertLessEqual(window["start_byte"], covered)
                text.encode()[:window["start_byte"]].decode()
                text.encode()[:window["end_byte"]].decode()
                covered = max(covered, window["end_byte"])
            self.assertEqual(covered, len(text.encode()))
            self.assertNotIn("ATTACK", str(response))

    def test_empty_and_multiple_fields(self):
        value = request("")
        value["fields"].append({"field_index": 1, "text": "ATTACK"})
        response = analyze(Fake(), value)
        self.assertEqual(response["windows"][0], {"field_index": 0, "start_byte": 0, "end_byte": 0, "score": 0.0})
        self.assertGreaterEqual(response["windows"][1]["score"], 0.95)

    def test_invalid_scores_fail_closed(self):
        class Invalid(Fake):
            def classify(self, *args):
                return score
        for score in [math.nan, math.inf, -0.1, 1.1, True]:
            with self.assertRaises(ValueError):
                analyze(Invalid(), request())

    def test_work_and_deadline_bounds(self):
        with self.assertRaises(ValueError):
            analyze(Fake(), request("x" * 70000))
        with patch("service.time.monotonic", side_effect=[0, 31]):
            with self.assertRaises(TimeoutError):
                analyze(Fake(), request())

    def test_strict_private_protocol(self):
        for value in [request() | {"extra": "PRIVATE"}, request() | {"timeout_ms": True}, request() | {"task": "moderation"}, request("\ud800")]:
            self.assertFalse(valid_request(value))
        with TestClient(make_app(Fake)) as client:
            self.assertEqual(client.get("/ready").status_code, 200)
            self.assertEqual(client.post("/analyze", json=request()).status_code, 200)
            response = client.post("/analyze", json=request() | {"extra": "PRIVATE"})
            self.assertEqual(response.status_code, 400)
            self.assertNotIn("PRIVATE", response.text)
            self.assertEqual(client.post("/analyze", content=b"x" * 2097153).status_code, 413)

    def test_exceptions_do_not_echo_content(self):
        class Broken(Fake):
            def classify(self, *args):
                raise ValueError("PRIVATE")
        with TestClient(make_app(Broken)) as client:
            response = client.post("/analyze", json=request())
            self.assertEqual(response.status_code, 503)
            self.assertNotIn("PRIVATE", response.text)

    def test_capacity_and_busy_readiness(self):
        entered, release = Event(), Event()
        class Waiting(Fake):
            def classify(self, *args):
                entered.set()
                if not release.wait(5):
                    raise TimeoutError("synchronization")
                return super().classify(*args)
        with TestClient(make_app(Waiting)) as client, ThreadPoolExecutor(max_workers=1) as pool:
            first = pool.submit(client.post, "/analyze", json=request())
            self.assertTrue(entered.wait(5))
            try:
                self.assertTrue(client.get("/ready").json()["busy"])
                self.assertEqual(client.post("/analyze", json=request()).status_code, 429)
            finally:
                release.set()
            self.assertEqual(first.result(timeout=5).status_code, 200)

    def test_pinned_git_blob_and_lfs_integrity(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "artifact"
            path.write_bytes(b"verified")
            sha = hashlib.sha256(b"verified").hexdigest()
            blob = hashlib.sha1(b"blob 8\0verified").hexdigest()
            for kind, digest in [("sha256", sha), ("git_blob_sha1", blob)]:
                with patch("models.MANIFEST", {"files": [{"path": "artifact", "bytes": 8, kind: digest}]}):
                    verify(directory)
                    path.write_bytes(b"tampered")
                    with self.assertRaises(RuntimeError):
                        verify(directory)
                    path.write_bytes(b"verified")

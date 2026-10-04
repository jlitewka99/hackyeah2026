"""No model downloads: report contracts, frozen dataset, incremental state and cleanup."""
from contextlib import nullcontext
from types import SimpleNamespace
import sys
import unittest
from pathlib import Path

DIRECTORY = Path(__file__).resolve().parents[2] / "sidecar/semantic_stream"
sys.path.insert(0, str(DIRECTORY))
from benchmark import dataset, metrics
from runtime import StreamGuard


class BenchmarkTest(unittest.TestCase):
    def test_dataset_contains_frozen_safe_and_unsafe_response_pairs(self):
        rows = dataset()
        self.assertEqual(len(rows), 40)
        self.assertEqual(sum(row["expected_block"] for row in rows), 20)
        self.assertTrue(all("prompt" in row for row in rows))

    def test_failed_rows_are_reported_without_invented_percentiles_or_accuracy(self):
        self.assertEqual(metrics([])["p95_us"], None)
        rows = [{"expected_block": True, "blocked": True, "duration_us": 10},
                {"expected_block": False, "blocked": True, "duration_us": 20},
                {"expected_block": True, "error_code": "model_evaluation_failed"}]
        result = metrics(rows)
        self.assertEqual(result["errors"], 1)
        self.assertEqual(result["recall"], 1)
        self.assertEqual(result["false_positive_rate"], 1)
        self.assertEqual(result["p95_us"], 20)

    def test_incremental_unsafe_signal_is_retained_and_state_is_closed(self):
        class IDs(list):
            @property
            def shape(self):
                return (len(self),)
            def __getitem__(self, key):
                value = super().__getitem__(key)
                return IDs(value) if isinstance(key, slice) else value
            def tolist(self):
                return list(self)
        class Tokenizer:
            def apply_chat_template(self, messages, tokenize, **kwargs):
                return [1, 2] if tokenize else "rendered"
            def __call__(self, text, **kwargs):
                return {"input_ids": [IDs([1, 2, 3, 4])]}
        class Model:
            config = SimpleNamespace(max_position_embeddings=100)
            def __init__(self):
                self.closed, self.calls = [], []
            def stream_moderate_from_ids(self, ids, role, stream_state=None):
                self.calls.append((ids, role, stream_state))
                return {"risk_level": ["Unsafe" if ids == 3 else "Safe"]}, "state"
            def close_stream(self, state):
                self.closed.append(state)
        guard = StreamGuard.__new__(StreamGuard)
        guard.tokenizer, guard.model = Tokenizer(), Model()
        guard.torch = SimpleNamespace(inference_mode=nullcontext)
        result = guard.classify("prompt", "response", float("inf"))
        self.assertTrue(result["blocked"])
        self.assertEqual(result["final_severity"], "Safe")
        self.assertEqual(result["first_unsafe"]["assistant_token_index"], 1)
        self.assertEqual(guard.model.closed, ["state"])
        self.assertEqual([call[1] for call in guard.model.calls], ["user", "assistant", "assistant"])
        guard.model.closed = []
        with self.assertRaisesRegex(ValueError, "deadline"):
            guard.classify("prompt", "response", 0)
        self.assertEqual(guard.model.closed, ["state"])


if __name__ == "__main__":
    unittest.main()

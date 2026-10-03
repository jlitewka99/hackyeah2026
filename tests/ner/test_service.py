import os
import sys
import unittest
from pathlib import Path
from types import SimpleNamespace

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "sidecar/ner"))
from fastapi.testclient import TestClient
from service import analyze, load_analyzer, make_app


class SyntheticAnalyzer:
    def analyze(self, **kwargs):
        if kwargs["text"] == "raise":
            raise RuntimeError("DO-NOT-LOG-SECRET")
        return [SimpleNamespace(entity_type="person", start=2, end=5, score=0.85)]


class ServiceTests(unittest.TestCase):
    def test_byte_offsets_and_no_text_in_result(self):
        result = analyze(SyntheticAnalyzer(), [{"field_index": 0, "text": "😀 Jan"}])
        finding = result["detections"][0]
        self.assertEqual((finding["start_byte"], finding["end_byte"]), (5, 8))
        self.assertNotIn("Jan", str(result))
        self.assertEqual(set(finding), {"field_index", "type", "score", "detector_id", "start_byte", "end_byte"})

    def test_endpoint_validation_limits_and_sanitized_errors(self):
        with TestClient(make_app(lambda: SyntheticAnalyzer())) as client:
            self.assertEqual(client.get("/ready").status_code, 200)
            for body in [{"fields": [{"field_index": 1, "text": "secret"}]}, {"fields": "secret"}, {"fields": [], "extra": "secret"}]:
                response = client.post("/analyze", json=body)
                self.assertEqual(response.status_code, 400)
                self.assertNotIn("secret", response.text)
            self.assertEqual(client.post("/analyze", content=b"x" * 1_048_577).status_code, 413)
            response = client.post("/analyze", json={"fields": [{"field_index": 0, "text": "raise"}]})
            self.assertEqual(response.status_code, 503)
            self.assertNotIn("DO-NOT-LOG", response.text)

    def test_no_model_is_not_ready(self):
        client = TestClient(make_app(lambda: SyntheticAnalyzer()))
        self.assertEqual(client.get("/ready").status_code, 503)

    @unittest.skipUnless(os.environ.get("NER_LIVE") == "1", "real pinned models required")
    def test_real_polish_entities_inflections_addresses_and_unicode(self):
        analyzer = load_analyzer()
        fixtures = [
            ("Rozmawiałem z Janem Kowalskim w Warszawie.", {"person", "place"}),
            ("Microsoft ma siedzibę w Polsce.", {"organization", "place"}),
            ("😀 Adres Jana Kowalskiego: ul. Długa 12/3, 00-001 Warszawa.", {"person", "address", "place", "geographical_location"}),
        ]
        for text, expected in fixtures:
            result = analyze(analyzer, [{"field_index": 0, "text": text}])
            self.assertTrue(expected.issubset({finding["type"] for finding in result["detections"]}))
            raw = text.encode()
            for finding in result["detections"]:
                self.assertTrue(raw[finding["start_byte"]:finding["end_byte"]].decode())
        result = analyze(analyzer, [{"field_index": 0, "text": "Oblicz wynik: dwa plus dwa."}])
        self.assertEqual(result["detections"], [])


if __name__ == "__main__":
    unittest.main()

"""Reproducible synthetic acceptance benchmark; reports measurements without text."""
import json
import platform
import resource
import statistics
import time
from service import analyze, load_analyzer

fixtures = [
    ("Rozmawiałem z Janem Kowalskim w Warszawie.", {"person", "place"}),
    ("Microsoft ma siedzibę w Polsce.", {"organization", "place"}),
    ("😀 Adres Jana Kowalskiego: ul. Długa 12/3, 00-001 Warszawa.", {"person", "address", "place", "geographical_location"}),
    ("Oblicz wynik: dwa plus dwa.", set()),
]
started = time.perf_counter()
analyzer = load_analyzer()
load_ms = (time.perf_counter() - started) * 1000
latencies = []
for _ in range(10):
    for text, expected in fixtures:
        started = time.perf_counter()
        result = analyze(analyzer, [{"field_index": 0, "text": text}])
        latencies.append((time.perf_counter() - started) * 1000)
        actual = {item["type"] for item in result["detections"]}
        assert expected.issubset(actual) if expected else not actual
        for item in result["detections"]:
            text.encode()[item["start_byte"]:item["end_byte"]].decode()
rss = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
print(json.dumps({"model_set": "pl-nkjp.v1", "platform": platform.platform(),
    "python": platform.python_version(), "cpu_threads": 2, "samples": len(latencies),
    "load_ms": round(load_ms, 1), "p50_ms": round(statistics.median(latencies), 1),
    "p95_ms": round(sorted(latencies)[int(len(latencies) * 0.95) - 1], 1),
    "peak_rss_bytes": rss if platform.system() == "Darwin" else rss * 1024}))

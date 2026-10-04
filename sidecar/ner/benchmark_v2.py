"""Synthetic, exact-span benchmark. Only measurements are emitted, never source text."""
import json
import platform
import resource
import statistics
import time
from service import analyze, load_analyzers

# All examples and identities are synthetic. Labels are fixed independently of predictions.
FIXTURES = [
    ("Rozmawiałem z Janem Kowalskim w Warszawie.", [("person", "Janem Kowalskim"), ("place", "Warszawie")]),
    ("Spotkałem Annę Wiśniewską w Łodzi.", [("person", "Annę Wiśniewską"), ("place", "Łodzi")]),
    ("Microsoft ma siedzibę w Polsce.", [("organization", "Microsoft"), ("place", "Polsce")]),
    ("😀 Adres: ul. Długa 12/3\n00-001 Warszawa", [("address", "ul. Długa 12/3\n00-001 Warszawa"), ("geographical_location", "Długa"), ("place", "Warszawa")]),
    ("Adres: ulica Żółta 7 m. 4, 01-234 Łódź", [("address", "ulica Żółta 7 m. 4, 01-234 Łódź"), ("geographical_location", "Żółta"), ("place", "Łódź")]),
    ("Adres: aleja Jana Pawła 9 lok. 2", [("address", "aleja Jana Pawła 9 lok. 2"), ("geographical_location", "Jana Pawła")]),
    ("Adres: osiedle Zielone 15A", [("address", "osiedle Zielone 15A"), ("geographical_location", "Zielone")]),
    ("Oblicz wynik: dwa plus dwa.", []),
    ("Maj to miesiąc, a róża to kwiat.", []),
    ("Marek to nazwa jednostki w przykładzie ekonomicznym.", []),
    ("Długa historia nie jest adresem.", []),
    ("Firma Allegro działa w Warszawie.", [("organization", "Allegro"), ("place", "Warszawie")]),
]

started = time.perf_counter()
analyzer = load_analyzers()["pl-nkjp.v2"]
load_ms = (time.perf_counter() - started) * 1000
latencies, tp, fp, fn, offset_checks, redaction_checks = [], 0, 0, 0, 0, 0
for iteration in range(5):
    for text, labels in FIXTURES:
        raw = text.encode()
        gold = set()
        for kind, span in labels:
            first = text.index(span)
            gold.add((kind, len(text[:first].encode()), len(text[:first + len(span)].encode())))
        started = time.perf_counter()
        result = analyze(analyzer, [{"field_index": 0, "text": text}], "pl-nkjp.v2")
        latencies.append((time.perf_counter() - started) * 1000)
        actual = {(r["type"], r["start_byte"], r["end_byte"]) for r in result["detections"]}
        if iteration == 0:
            tp += len(gold & actual)
            fp += len(actual - gold)
            fn += len(gold - actual)
        intervals = sorted({(a, b) for _, a, b in actual})
        merged = []
        for first, last in intervals:
            raw[first:last].decode("utf-8")
            offset_checks += 1
            if merged and first <= merged[-1][1]:
                merged[-1] = (merged[-1][0], max(last, merged[-1][1]))
            else:
                merged.append((first, last))
        checked = raw
        for first, last in reversed(merged):
            checked = checked[:first] + b"[REDACTED]" + checked[last:]
        checked.decode("utf-8")
        for _, first, last in actual:
            assert raw[first:last] not in checked
            redaction_checks += 1
rss = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
print(json.dumps({"model_set": "pl-nkjp.v2", "platform": platform.platform(), "python": platform.python_version(),
    "cpu_threads": 2, "fixtures": len(FIXTURES), "samples": len(latencies), "metric": "micro exact entity type and UTF-8 span; first iteration",
    "true_positive": tp, "false_positive": fp, "false_negative": fn,
    "precision": round(tp / (tp + fp), 4) if tp + fp else 1,
    "recall": round(tp / (tp + fn), 4) if tp + fn else 1,
    "utf8_offset_checks": offset_checks, "detected_span_redaction_checks": redaction_checks,
    "load_ms": round(load_ms, 1), "p50_ms": round(statistics.median(latencies), 1),
    "p95_ms": round(sorted(latencies)[int(len(latencies) * .95) - 1], 1),
    "peak_rss_bytes": rss if platform.system() == "Darwin" else rss * 1024}))

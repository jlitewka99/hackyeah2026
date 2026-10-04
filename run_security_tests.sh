#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")"
live=0
case "${1:-}" in
  '') ;;
  --live-models) live=1 ;;
  --help) printf 'Usage: ./run_security_tests.sh [--live-models]\nPYTHON must provide the locked NER, tokenizer, semantic and Prompt Guard dependencies. Live mode requires all model services plus pinned Granite and its tokenizer.\n'; exit 0 ;;
  *) printf 'Unknown argument\n' >&2; exit 2 ;;
esac
if (($# > 1)); then printf 'Unexpected arguments\n' >&2; exit 2; fi
if ((live)); then export NER_LIVE=1; fi
python_runtime="${PYTHON:-python3.11}"
failures=0
run_check() {
  printf '\nRunning %s\n' "$1"
  local label="$1"
  shift
  if "$@"; then printf 'PASS: %s\n' "$label"; else printf 'FAIL: %s\n' "$label" >&2; failures=$((failures + 1)); fi
}
run_check 'ExUnit security and integration suite' mix test --warnings-as-errors
for service in ner tokenizer semantic prompt_guard; do
  run_check "$service contract" env PYTHONPATH="sidecar/$service" "$python_runtime" -m unittest discover -s "tests/$service"
done
if ((live)); then
  run_check 'All real-model integration tests (no missing-service skips)' mix test test/ai_control/gateway/live_ollama_test.exs test/ai_control/gateway/live_ner_test.exs test/ai_control/gateway/live_budget_tokenizer_test.exs test/ai_control/gateway/live_semantic_test.exs test/ai_control/gateway/live_prompt_guard_test.exs test/ai_control/tools/live_models_test.exs test/ai_control/guards/live_granite_test.exs test/ai_control/approvals/live_test.exs --include live_models --include live_ner
fi
printf '\nSecurity checks complete: %s failed group(s).\n' "$failures"
((failures == 0))

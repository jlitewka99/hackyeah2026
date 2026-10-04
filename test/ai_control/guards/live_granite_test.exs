defmodule AiControl.Guards.LiveGraniteTest do
  use ExUnit.Case, async: false

  alias AiControl.Gateway.Config
  alias AiControl.Guards.Granite.{Criteria, Model, Ollama, Prompt}

  @moduletag :live_models
  @moduletag timeout: 900_000
  test "pinned real model qualifies PL/EN input, tool alignment and groundedness pairs" do
    config = Config.get()

    assert Ollama.ready?(config),
           "Granite and its pinned tokenizer must both be ready; missing services never skip live qualification"

    cases = File.read!("test/support/fixtures/granite_cases.json") |> Jason.decode!()
    criteria = Map.new(Criteria.defaults(), fn {_, value} -> {value["task"], value} end)

    results =
      Enum.map(cases, fn item ->
        prompt =
          Prompt.render(criteria[item["task"]], item["data"], item["target"], item["documents"])

        start = System.monotonic_time(:millisecond)
        result = Ollama.analyze(prompt, config, start + 60_000)

        {actual, usage} =
          case result do
            {:ok, score, usage} -> {score, usage}
            _ -> {"unavailable", nil}
          end

        Map.take(item, ~w(id task language expected))
        |> Map.merge(%{
          "actual" => actual,
          "duration_ms" => System.monotonic_time(:millisecond) - start,
          "usage" => usage
        })
      end)

    durations = results |> Enum.map(& &1["duration_ms"]) |> Enum.sort()
    errors = Enum.count(results, &(&1["actual"] != &1["expected"]))

    report = %{
      "recorded_at" => DateTime.to_iso8601(DateTime.utc_now()),
      "model" => Model.name(),
      "digest" => Model.digest(),
      "tokenizer_revision" => Model.revision(),
      "context_tokens" => 8192,
      "non_thinking" => true,
      "temperature" => 0,
      "errors" => errors,
      "p50_ms" => percentile(durations, 0.5),
      "p95_ms" => percentile(durations, 0.95),
      "cases" => results
    }

    if path = System.get_env("GRANITE_ACCEPTANCE_REPORT"),
      do: File.write!(path, Jason.encode!(report, pretty: true) <> "\n")

    IO.puts(
      "Granite qualification: #{errors}/#{length(results)} errors; p50=#{report["p50_ms"]}ms p95=#{report["p95_ms"]}ms digest=#{Model.digest()}"
    )

    assert errors == 0, "See the acceptance report for failed or unavailable synthetic cases"
  end

  defp percentile(values, rank), do: Enum.at(values, max(0, ceil(length(values) * rank) - 1))
end

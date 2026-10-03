defmodule Mix.Tasks.AiControl.BenchmarkSemantic do
  @shortdoc "Benchmark Polish semantic fixtures against the local Qwen sidecar"
  @moduledoc "Benchmark pinned Qwen via Req; reports contain IDs and measurements, never text."
  use Mix.Task

  alias AiControl.Gateway.Config
  alias AiControl.Guards.{Moderation, Semantic}
  alias AiControl.Guards.Semantic.Local
  alias AiControl.Policies.Configuration
  alias AiControl.Policy.Snapshot

  @impl true
  def run(args) do
    {opts, _, invalid} =
      OptionParser.parse(args,
        strict: [output: :string, url: :string, split: :string, hardware: :string]
      )

    if invalid != [],
      do:
        Mix.raise(
          "Use --output DIRECTORY --url ORIGIN --split calibration|test|all --hardware DESCRIPTION"
        )

    Mix.Task.run("app.start")
    config = Config.get() |> Keyword.put(:semantic_url, opts[:url] || Config.get(:semantic_url))
    if !Local.ready?(config), do: Mix.raise("Pinned semantic service is not ready")
    raw = File.read!("priv/benchmarks/semantic-pl.v1.jsonl")
    checksum = Base.encode16(:crypto.hash(:sha256, raw), case: :lower)

    if checksum != String.trim(File.read!("priv/benchmarks/semantic-pl.v1.sha256")),
      do: Mix.raise("Dataset checksum mismatch")

    cases = raw |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
    split = opts[:split] || "all"
    if split not in ~w(all calibration test), do: Mix.raise("Unsupported split")
    {:ok, %{settings: settings}} = Configuration.validate(Configuration.default(3))

    rules =
      Map.new(settings["rules"], fn {name, rule} ->
        {name,
         %{
           id: rule["id"],
           action: if(rule["action"] == "block", do: :block, else: :redact),
           threshold: rule["threshold"]
         }}
      end)

    {:ok, snapshot} =
      Snapshot.new(%{version: "semantic-benchmark-v1", settings: settings, rules: rules})

    rows =
      cases
      |> Enum.filter(&(split == "all" || &1["split"] == split))
      |> Enum.map(&assess_case(&1, snapshot, config))

    write_report(rows, checksum, split, config, opts)
  end

  defp assess_case(item, snapshot, config) do
    # A timed-out HTTP caller can leave a CPU prefill finishing in the sidecar.
    # Wait between benchmark cases; never retry a classification or count 429s as negatives.
    wait_for_idle(config, System.monotonic_time(:millisecond) + 60_000)
    guard = if item["task"] == "injection", do: Semantic, else: Moderation
    started = System.monotonic_time()

    result =
      guard.assess(
        [item["text"]],
        nil,
        snapshot,
        Keyword.put(config, :semantic_prompt, item["prompt"])
      )

    elapsed = System.convert_time_unit(System.monotonic_time() - started, :native, :microsecond)

    row =
      Map.take(item, ~w(id family split group task expected_block))
      |> Map.put("duration_us", elapsed)

    case result do
      {:ok, result} ->
        Map.merge(row, %{
          "blocked" => result.detections != [],
          "error" => nil,
          "evidence" => result.evidence
        })

      {:error, _} ->
        Map.merge(row, %{"blocked" => nil, "error" => "guard_unavailable"})
    end
  end

  defp write_report(rows, checksum, split, config, opts) do
    health = Req.get!(config[:semantic_url] <> "/ready", retry: false, redirect: false).body

    summary = %{
      dataset_checksum: checksum,
      model_set: Local.model_set(),
      revision: Local.revision(),
      runtime: "transformers-4.57.1-torch-2.8.0-cpu-fp32",
      hardware: opts[:hardware] || "unspecified",
      cold_start_us: health["cold_start_us"],
      peak_rss_bytes: health["peak_rss_bytes"],
      split: split,
      mapping: %{severities: ["Unsafe"], injection_categories: ["Jailbreak"]},
      latency_scope:
        "full guard transport, validation and policy label mapping; excludes LLM generation",
      p50_us: percentile(rows, 0.5),
      p95_us: percentile(rows, 0.95),
      groups:
        rows
        |> Enum.group_by(& &1["group"])
        |> Map.new(fn {group, rows} -> {group, metrics(rows)} end),
      splits:
        rows
        |> Enum.group_by(& &1["split"])
        |> Map.new(fn {name, items} -> {name, split_metrics(items)} end)
    }

    output = opts[:output] || "docs/acceptance/step10-qwen"
    File.mkdir_p!(output)

    File.write!(
      Path.join(output, "cases.jsonl"),
      Enum.map_join(rows, "", &(Jason.encode!(&1) <> "\n"))
    )

    File.write!(Path.join(output, "summary.json"), Jason.encode!(summary, pretty: true) <> "\n")

    csv =
      "id,split,group,expected_block,blocked,error,duration_us\n" <>
        Enum.map_join(rows, "", fn row ->
          Enum.map_join(
            ~w(id split group expected_block blocked error duration_us),
            ",",
            &to_string(row[&1])
          ) <> "\n"
        end)

    File.write!(Path.join(output, "cases.csv"), csv)

    Mix.shell().info(
      "Recorded #{length(rows)} cases; #{Enum.count(rows, & &1["error"])} service errors. Report: #{output}"
    )

    if Enum.any?(rows, & &1["error"]), do: Mix.raise("Benchmark has service errors; see report")
  end

  defp wait_for_idle(config, deadline) do
    health =
      Req.get!(config[:semantic_url] <> "/ready",
        retry: false,
        redirect: false,
        receive_timeout: 5_000,
        request_timeout: 5_000
      ).body

    if health["busy"] do
      if System.monotonic_time(:millisecond) >= deadline,
        do: Mix.raise("Sidecar did not become idle after a benchmark case")

      Process.sleep(200)
      wait_for_idle(config, deadline)
    end
  end

  defp metrics(rows) do
    valid = Enum.reject(rows, & &1["error"])
    tp = Enum.count(valid, &(&1["expected_block"] && &1["blocked"]))
    fn_count = Enum.count(valid, &(&1["expected_block"] && !&1["blocked"]))
    fp = Enum.count(valid, &(!&1["expected_block"] && &1["blocked"]))
    tn = Enum.count(valid, &(!&1["expected_block"] && !&1["blocked"]))

    %{
      count: length(rows),
      errors: length(rows) - length(valid),
      tp: tp,
      fp: fp,
      tn: tn,
      fn: fn_count,
      precision: ratio(tp, tp + fp),
      recall: ratio(tp, tp + fn_count),
      fpr: ratio(fp, fp + tn)
    }
  end

  defp split_metrics(rows) do
    injection = Enum.filter(rows, &(&1["task"] == "injection"))

    %{
      injection: metrics(injection),
      moderation: metrics(Enum.filter(rows, &(&1["task"] == "moderation"))),
      groups:
        Map.new(Enum.group_by(rows, & &1["group"]), fn {group, items} ->
          {group, metrics(items)}
        end)
    }
  end

  defp ratio(_, 0), do: nil
  defp ratio(a, b), do: a / b

  defp percentile(rows, fraction) do
    rows
    |> Enum.map(& &1["duration_us"])
    |> Enum.sort()
    |> Enum.at(max(ceil(length(rows) * fraction) - 1, 0))
  end
end

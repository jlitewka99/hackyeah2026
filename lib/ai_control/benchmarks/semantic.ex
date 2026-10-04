defmodule AiControl.Benchmarks.Semantic do
  @moduledoc "Benchmark providers via Req; reports contain IDs and measurements, never text."

  alias AiControl.Gateway.Config
  alias AiControl.Guards.{Moderation, Semantic}
  alias AiControl.Guards.Semantic.{Local, PromptGuard}
  alias AiControl.Policies.Configuration
  alias AiControl.Policy.Snapshot

  def run(args) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          output: :string,
          url: :string,
          split: :string,
          hardware: :string,
          provider: :string,
          threshold: :float,
          severities: :string
        ]
      )

    if invalid != [] || rest != [],
      do:
        fail!(
          "Use --output DIRECTORY --url ORIGIN --split calibration|test|all --hardware DESCRIPTION"
        )

    {:ok, _} = Application.ensure_all_started(:ai_control)
    config = benchmark_config(opts)
    {cases, checksum} = dataset()
    split = benchmark_split(opts)
    opts = prepare_output(opts, config[:benchmark_provider], split)
    {snapshot, settings} = benchmark_snapshot(opts, config[:benchmark_provider])

    rows =
      cases
      |> Enum.filter(fn item ->
        (split == "all" || item["split"] == split) &&
          (config[:benchmark_provider] == "qwen" || item["task"] == "injection")
      end)
      |> Enum.map(&assess_case(&1, snapshot, config))

    write_report(rows, checksum, split, config, Keyword.put(opts, :settings, settings))
  end

  defp benchmark_config(opts) do
    provider = opts[:provider] || "qwen"
    if provider not in ~w(qwen prompt_guard), do: fail!("Unsupported provider")

    config =
      Config.get()
      |> Keyword.put(:semantic_url, opts[:url] || Config.get(:semantic_url))
      |> Keyword.put(:benchmark_provider, provider)
      |> Keyword.put(:injection_provider, provider)

    config =
      if provider == "prompt_guard" && opts[:url],
        do: Keyword.put(config, :prompt_guard_url, opts[:url]),
        else: config

    if !Semantic.ready?(config), do: fail!("Pinned semantic service is not ready")
    config
  end

  defp dataset do
    raw = File.read!(Application.app_dir(:ai_control, "priv/benchmarks/semantic-pl.v1.jsonl"))
    checksum = Base.encode16(:crypto.hash(:sha256, raw), case: :lower)

    if checksum !=
         String.trim(
           File.read!(Application.app_dir(:ai_control, "priv/benchmarks/semantic-pl.v1.sha256"))
         ),
       do: fail!("Dataset checksum mismatch")

    cases = raw |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
    {cases, checksum}
  end

  defp benchmark_split(opts) do
    split = opts[:split] || "all"
    if split not in ~w(all calibration test), do: fail!("Unsupported split")
    split
  end

  defp prepare_output(opts, provider, split) do
    output = opts[:output] || "docs/acceptance/step11b-models/#{provider}-#{split}"

    if File.dir?(output) && File.ls!(output) != [],
      do: fail!("Benchmark output must be empty to preserve historical measurements")

    Keyword.put(opts, :output, output)
  end

  defp benchmark_snapshot(opts, provider) do
    severities = String.split(opts[:severities] || "Unsafe", ",")

    source =
      Configuration.default(4)
      |> Map.put("guards", %{"semantic" => %{"provider" => provider, "severities" => severities}})
      |> Map.put("rules", %{
        "prompt_injection" => %{
          "threshold" => if(provider == "qwen", do: 0, else: opts[:threshold] || 0.8)
        }
      })

    {:ok, %{settings: settings}} = Configuration.validate(source)

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

    {snapshot, settings}
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
          "blocked" =>
            result.detections != [] &&
              snapshot.rules[
                if(item["task"] == "injection", do: "prompt_injection", else: "content_safety")
              ].action == :block,
          "error" => nil,
          "evidence" => result.evidence
        })

      {:error, _} ->
        Map.merge(row, %{"blocked" => nil, "error" => "guard_unavailable"})
    end
  end

  defp write_report(rows, checksum, split, config, opts) do
    module = if config[:benchmark_provider] == "prompt_guard", do: PromptGuard, else: Local

    url =
      if config[:benchmark_provider] == "prompt_guard",
        do: config[:prompt_guard_url],
        else: config[:semantic_url]

    health =
      Req.get!(url <> "/ready",
        retry: false,
        redirect: false,
        receive_timeout: 5_000,
        request_timeout: 5_000
      ).body

    summary = %{
      dataset_checksum: checksum,
      provider: config[:benchmark_provider],
      model_set: module.model_set(),
      revision: module.revision(),
      runtime: "transformers-4.57.1-torch-2.8.0-cpu-fp32",
      device: health["device"],
      dtype: health["dtype"],
      cpu_threads: health["cpu_threads"],
      hardware: opts[:hardware] || "unspecified",
      cold_start_us: health["cold_start_us"],
      peak_rss_bytes: health["peak_rss_bytes"],
      split: split,
      mapping: %{
        severities: opts[:settings]["guards"]["semantic"]["severities"],
        threshold: opts[:settings]["rules"]["prompt_injection"]["threshold"],
        injection_categories: ["Jailbreak"]
      },
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

    output = opts[:output]
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

    IO.puts(
      "Recorded #{length(rows)} cases; #{Enum.count(rows, & &1["error"])} service errors. Report: #{output}"
    )

    if Enum.any?(rows, & &1["error"]), do: fail!("Benchmark has service errors; see report")

    validate_measurements!(health)
  end

  defp validate_measurements!(health) do
    if !is_integer(health["cold_start_us"]) || health["cold_start_us"] < 0 ||
         !is_integer(health["peak_rss_bytes"]) || health["peak_rss_bytes"] <= 0,
       do: fail!("Benchmark lacks cold start or peak RSS measurements; see report")

    if health["device"] != "cpu" || health["dtype"] != "float32" || health["cpu_threads"] != 2,
      do: fail!("Benchmark requires CPU FP32 with exactly two threads; see report")
  end

  defp wait_for_idle(config, deadline) do
    health =
      Req.get!(
        if(config[:benchmark_provider] == "prompt_guard",
          do: config[:prompt_guard_url],
          else: config[:semantic_url]
        ) <> "/ready",
        retry: false,
        redirect: false,
        receive_timeout: 5_000,
        request_timeout: 5_000
      ).body

    if health["busy"] do
      if System.monotonic_time(:millisecond) >= deadline,
        do: fail!("Sidecar did not become idle after a benchmark case")

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

  def measure(provider, on_case) when provider in ~w(qwen prompt_guard) do
    config = benchmark_config(provider: provider)
    {cases, checksum} = dataset()
    {snapshot, _} = benchmark_snapshot([], provider)

    rows =
      cases
      |> Enum.filter(&(provider == "qwen" || &1["task"] == "injection"))
      |> Enum.map(fn item ->
        row = assess_case(item, snapshot, config)
        row = Map.put(row, "dataset_checksum", checksum)
        on_case.(row)
        row
      end)

    %{
      dataset_checksum: checksum,
      provider: provider,
      cases: length(rows),
      errors: Enum.count(rows, & &1["error"]),
      p50_us: percentile(rows, 0.5),
      p95_us: percentile(rows, 0.95)
    }
  end

  def case_ids do
    {cases, _} = dataset()

    for provider <- ~w(qwen prompt_guard),
        item <- cases,
        provider == "qwen" || item["task"] == "injection",
        do: provider <> "." <> String.downcase(item["id"])
  end

  defp fail!(message), do: raise(ArgumentError, message)
end

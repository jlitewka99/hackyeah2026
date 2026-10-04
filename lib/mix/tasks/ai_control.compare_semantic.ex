defmodule Mix.Tasks.AiControl.CompareSemantic do
  @shortdoc "Calibrate then qualify Qwen and Prompt Guard on the frozen Polish dataset"
  @moduledoc "Runs pinned providers sequentially; freezes mappings before held-out measurements."
  use Mix.Task

  alias AiControl.Guards.Semantic.Qualification
  alias AiControl.Policies.{Configuration, YAML}

  @impl true
  def run(args) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: [output: :string, hardware: :string])

    if invalid != [] || rest != [] || !opts[:hardware],
      do: Mix.raise("Use --output DIRECTORY --hardware DESCRIPTION")

    root = opts[:output] || "docs/acceptance/step11b-models"

    if File.dir?(root) && File.ls!(root) != [],
      do: Mix.raise("Comparison output must be empty to prevent stale evidence")

    File.mkdir_p!(root)
    candidates = Enum.map(~w(qwen prompt_guard), &candidate(&1, root, opts[:hardware]))

    winner =
      candidates
      |> Enum.filter(& &1.qualified)
      |> Enum.sort_by(&{-&1.metrics.mean_recall, &1.metrics.p95_us})
      |> List.first()

    File.write!(
      Path.join(root, "comparison.json"),
      Jason.encode!(%{hardware: opts[:hardware], candidates: candidates, winner: winner},
        pretty: true
      ) <> "\n"
    )

    if winner do
      source =
        Configuration.default(4)
        |> Map.put("guards", %{
          "semantic" =>
            Map.get(winner.variant, :severities, [])
            |> severity_config()
            |> Map.put("provider", winner.provider)
        })

      source =
        if winner.provider == "prompt_guard",
          do:
            Map.put(source, "rules", %{
              "prompt_injection" => %{"threshold" => winner.variant.threshold}
            }),
          else: source

      File.write!(Path.join(root, "qualified-policy.yaml"), YAML.encode(source))

      Mix.shell().info(
        "Qualified injection provider: #{winner.provider}; policy saved without activation"
      )
    else
      Mix.raise("No complete qualifying model; reports preserved and MVP acceptance remains open")
    end
  end

  defp severity_config([]), do: %{}
  defp severity_config(values), do: %{"severities" => values}

  defp candidate(provider, root, hardware) do
    calibration = Path.join(root, provider <> "-calibration")
    calibration_complete? = run_benchmark(provider, "calibration", calibration, hardware, %{})
    selected = Qualification.select(read_rows(calibration), Qualification.variants(provider))
    variant = if selected, do: selected.variant, else: hd(Qualification.variants(provider))
    frozen = %{provider: provider, variant: variant}

    File.write!(
      Path.join(root, provider <> "-frozen.json"),
      Jason.encode!(frozen, pretty: true) <> "\n"
    )

    test = Path.join(root, provider <> "-test")
    test_complete? = run_benchmark(provider, "test", test, hardware, variant)
    metrics = Qualification.metrics(read_rows(test), variant)

    %{
      provider: provider,
      variant: variant,
      metrics: metrics,
      qualified:
        calibration_complete? && test_complete? && !is_nil(selected) &&
          Qualification.qualified?(metrics)
    }
  end

  defp run_benchmark(provider, split, output, hardware, variant) do
    Mix.Task.reenable("ai_control.benchmark_semantic")

    options = [
      "--provider",
      provider,
      "--split",
      split,
      "--output",
      output,
      "--hardware",
      hardware
    ]

    options =
      if variant[:threshold],
        do: options ++ ["--threshold", to_string(variant.threshold)],
        else: options

    options =
      if variant[:severities],
        do: options ++ ["--severities", Enum.join(variant.severities, ",")],
        else: options

    try do
      Mix.Task.run("ai_control.benchmark_semantic", options)
      true
    rescue
      Mix.Error ->
        Mix.shell().error("#{provider} #{split} incomplete; inspect preserved report")
        false
    end
  end

  defp read_rows(directory) do
    case File.read(Path.join(directory, "cases.jsonl")) do
      {:ok, raw} -> raw |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
      _ -> []
    end
  end
end

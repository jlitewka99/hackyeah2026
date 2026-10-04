defmodule AiControl.Guards.Semantic do
  @moduledoc "Snapshot-owned injection provider; model signals are not calibrated probabilities."
  @behaviour AiControl.Gateway.Guard

  alias AiControl.Guards.Semantic.{Local, PromptGuard}
  alias AiControl.Security.{Detection, GuardResult}

  @impl true
  def assess(fields, context, snapshot, config) do
    if selected_provider(snapshot) == "prompt_guard",
      do: PromptGuard.assess(fields, context, snapshot, config),
      else: assess_as("semantic", "injection", fields, context, snapshot, config)
  end

  def selected_provider(snapshot),
    do: get_in(snapshot.settings, ["guards", "semantic", "provider"]) || "qwen"

  @impl true
  def ready?(config) do
    if config[:injection_provider] == "prompt_guard",
      do: PromptGuard.ready?(config),
      else: provider(config).ready?(config)
  end

  def assess_as(guard, task, fields, _context, snapshot, config) do
    started = System.monotonic_time()

    with {:ok, response} <- provider(config).analyze(fields, task, config),
         true <- Local.valid_response?(response, fields, task) do
      settings = snapshot.settings["guards"][guard]

      severities =
        Map.get(
          settings,
          "severities",
          if(snapshot.settings["profile"] == "strict",
            do: ~w(Unsafe Controversial),
            else: ["Unsafe"]
          )
        )

      categories = if task == "injection", do: ["Jailbreak"], else: settings["categories"]
      category = if task == "injection", do: "prompt_injection", else: "content_safety"

      detected? =
        Enum.any?(response["windows"], fn window ->
          window["severity"] in severities && Enum.any?(window["categories"], &(&1 in categories))
        end)

      detections =
        if detected? do
          {:ok, detection} =
            Detection.new(%{
              guard: guard,
              category: category,
              rule_id: "#{guard}.qwen_labels.v1",
              confidence: 1
            })

          [detection]
        else
          []
        end

      evidence =
        response
        |> Map.take(~w(model_set revision task windows))
        |> Map.put("signal_kind", "label_mapping_binary")

      GuardResult.new(%{
        guard: guard,
        status: :ok,
        detections: detections,
        evidence: evidence,
        signals:
          if(task == "injection",
            do: %{"injection_score" => if(detected?, do: 1, else: 0)},
            else: %{}
          ),
        duration_us:
          System.convert_time_unit(System.monotonic_time() - started, :native, :microsecond)
      })
    else
      _ -> {:error, :guard_unavailable}
    end
  end

  defp provider(config), do: Keyword.get(config, :semantic_provider, Local)
end

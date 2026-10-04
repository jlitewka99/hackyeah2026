defmodule AiControl.Guards.Granite do
  @moduledoc "Selected criteria are mandatory and can only tighten the earlier decision."
  @behaviour AiControl.Gateway.Guard

  alias AiControl.Guards.Granite.{Ollama, Plan, Prompt}
  alias AiControl.Security.{Detection, GuardResult}

  @impl true
  def ready?(config), do: Ollama.ready?(config)

  @impl true
  def assess(fields, context, policy, config) do
    started = System.monotonic_time(:microsecond)

    deadline =
      config[:granite_deadline] || System.monotonic_time(:millisecond) + config[:granite_timeout]

    checks =
      (config[:granite_plan] || Plan.build(fields, context, policy, config))
      |> Plan.authorize(policy, config)

    evidence = Enum.map(checks, &evaluate(&1, config, deadline))
    failed = Enum.any?(evidence, &(&1["status"] == "error"))
    selected = Enum.any?(checks, &Plan.selected?/1)
    blocked = Enum.any?(evidence, &(&1["interpretation"] == "block"))

    detections =
      if blocked do
        {:ok, detection} =
          Detection.new(%{
            guard: "granite",
            category: "granite_violation",
            rule_id: "granite.violation.v1",
            confidence: 1
          })

        [detection]
      else
        []
      end

    GuardResult.new(%{
      guard: "granite",
      status:
        cond do
          failed -> :error
          selected -> :ok
          true -> :skipped
        end,
      detections: if(failed, do: [], else: detections),
      evidence: Plan.evidence(evidence),
      error_code: if(failed, do: "provider_invalid_response"),
      duration_us: System.monotonic_time(:microsecond) - started
    })
  end

  def unavailable(plan, duration_us \\ 0) do
    evidence =
      Enum.map(plan, fn check ->
        if Plan.selected?(check),
          do:
            Map.merge(check.evidence, %{"status" => "error", "interpretation" => "unavailable"}),
          else: check.evidence
      end)

    {:ok, result} =
      GuardResult.new(%{
        guard: "granite",
        status: :error,
        error_code: "guard_unavailable",
        duration_us: duration_us,
        evidence: Plan.evidence(evidence)
      })

    result
  end

  def skipped(plan) do
    {:ok, result} =
      GuardResult.new(%{
        guard: "granite",
        status: :skipped,
        evidence: Plan.evidence(Enum.map(plan, & &1.evidence))
      })

    result
  end

  defp evaluate(check, config, deadline) do
    if Plan.selected?(check) do
      started = System.monotonic_time(:microsecond)

      result =
        with true <- check.data != :unavailable and check.documents != :unavailable,
             prompt = Prompt.render(check.criterion, check.data, check.target, check.documents),
             {:ok, score, usage} <- provider(config).analyze(prompt, config, deadline) do
          Map.merge(check.evidence, %{
            "status" => "ok",
            "score" => score,
            "usage" => usage,
            "interpretation" =>
              if(score == check.evidence["block_on"], do: "block", else: "allow")
          })
        else
          _ ->
            Map.merge(check.evidence, %{"status" => "error", "interpretation" => "unavailable"})
        end

      Map.put(result, "duration_us", System.monotonic_time(:microsecond) - started)
    else
      check.evidence
    end
  end

  defp provider(config), do: Keyword.get(config, :granite_provider, Ollama)
end

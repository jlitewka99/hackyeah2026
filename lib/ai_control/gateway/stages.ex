defmodule AiControl.Gateway.Stages do
  @moduledoc "Assess and audit each current text version before using it at the next stage."
  alias AiControl.{Gateway, Security}
  alias AiControl.Gateway.{Config, Content, Request, Response, Slots}
  alias AiControl.Guards.Granite
  alias AiControl.Policy.Engine
  alias AiControl.Policy.Snapshot
  alias AiControl.Security.GraniteEvidence
  alias AiControl.Security.{GuardResult, SecurityAssessment}
  alias Granite.Plan

  @phases [~w(pii secret signatures), ["ner"], ["semantic", "moderation"], ["granite"]]

  def evaluate(value, identity, policy, request_id, stage, opts \\ []) do
    Gateway.measure(
      stage,
      fn ->
        phases =
          Enum.filter(@phases, fn guards ->
            Enum.any?(guards, &Snapshot.enabled?(policy, &1, stage))
          end)

        opts = Keyword.put(opts, :granite_identity, identity)

        if length(phases) < 2 and not Snapshot.enabled?(policy, "granite", stage) do
          complete(value, identity, policy, request_id, stage, opts)
        else
          layered(value, identity, policy, request_id, stage, phases, opts)
        end
      end,
      opts
    )
  end

  defp layered(value, identity, policy, request_id, stage, phases, opts) do
    phases
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, value, [], false}, fn {guards, index},
                                                     {:ok, current, previous, findings} ->
      opts = Keyword.merge(opts, granite_previous: previous, granite_findings: findings)

      with {:ok, context} <- Gateway.context(identity, policy, request_id, stage),
           {:ok, results} <- results(current, context, policy, guards, opts),
           {:ok, assessment} <- SecurityAssessment.new(context, previous ++ results),
           {:ok, decision} <-
             phase_decision(context, assessment, policy, guards, index == length(phases) - 1),
           {:ok, safe} <- enforce(current, decision, stage, opts),
           :ok <- safe_contract(current, safe, stage, opts) do
        evidence = Enum.map(previous ++ results, &%{&1 | detections: []})
        {:cont, {:ok, safe, evidence, findings or Enum.any?(results, &(&1.detections != []))}}
      else
        error -> {:halt, classify_error(error)}
      end
    end)
    |> case do
      {:ok, safe, _, _} -> {:ok, safe}
      error -> error
    end
  end

  defp phase_decision(context, assessment, policy, _guards, true),
    do: Security.evaluate_and_audit(context, assessment, policy)

  defp phase_decision(context, assessment, policy, guards, false) do
    current = Enum.filter(assessment.results, &(&1.guard in guards))

    with {:ok, phase} <- SecurityAssessment.new(context, current),
         {:ok, decision} <- Engine.evaluate_phase(context, phase, policy, guards),
         {:ok, _} <- AiControl.Audit.record_phase_decision(context, phase, decision, guards) do
      {:ok, decision}
    end
  end

  defp complete(value, identity, policy, request_id, stage, opts) do
    guards =
      List.flatten(@phases)
      |> Enum.reject(&(&1 in ~w(ner moderation granite) && !Snapshot.enabled?(policy, &1, stage)))

    with {:ok, context} <- Gateway.context(identity, policy, request_id, stage),
         {:ok, results} <- results(value, context, policy, guards, opts),
         {:ok, assessment} <- SecurityAssessment.new(context, results),
         {:ok, decision} <- Security.evaluate_and_audit(context, assessment, policy) do
      with {:ok, safe} <- enforce(value, decision, stage, opts),
           :ok <- safe_contract(value, safe, stage, opts),
           do: {:ok, safe}
    else
      error -> classify_error(error)
    end
  end

  defp classify_error({:error, {:capacity_exceeded, _}} = error), do: error

  defp classify_error({:error, reason} = error)
       when reason in [
              :audit_unavailable,
              :guard_unavailable,
              :policy_blocked,
              :redaction_unavailable
            ], do: error

  defp classify_error(_), do: {:error, :guard_unavailable}

  defp results(value, context, policy, guards, opts) do
    fields = adapter(opts).fields(value, context.stage) |> Enum.map(& &1.text)

    Enum.reduce_while(guards, {:ok, []}, fn guard, {:ok, results} ->
      case assess(guard, fields, value, context, policy, opts) do
        {:error, {:capacity_exceeded, _}} = error ->
          {:halt, error}

        result ->
          collect_result(result, results, Snapshot.required_guards(policy, context.stage))
      end
    end)
  end

  defp collect_result(result, results, required) do
    collected = {:ok, results ++ [result]}

    if result.status != :ok && result.guard in required,
      do: {:halt, collected},
      else: {:cont, collected}
  end

  defp safe_contract(original, safe, stage, opts) do
    case Keyword.get(opts, :content_adapter) do
      nil -> default_contract(original, safe, stage, opts)
      module -> module.validate(original, safe, stage, opts)
    end
  end

  defp adapter(opts), do: Keyword.get(opts, :content_adapter, Content)

  defp default_contract(original, safe, :input, _opts) do
    case Request.validate(safe) do
      {:ok, _} ->
        if original["model"] == safe["model"], do: :ok, else: {:error, :redaction_unavailable}

      _ ->
        {:error, :redaction_unavailable}
    end
  end

  defp default_contract(_, safe, :output, opts) do
    contract = Keyword.get(opts, :tool_contract, %{schemas: %{}, choice: "auto"})

    case Response.validate(safe, contract) do
      {:error, :upstream_invalid_response} -> {:error, :redaction_unavailable}
      result -> result
    end
  end

  defp assess("granite", fields, value, context, policy, opts) do
    deadline = System.monotonic_time(:millisecond) + Config.get(:granite_timeout)
    config = Keyword.merge(Config.get(), opts) |> Keyword.put(:granite_value, value)
    plan = Plan.build(fields, context, policy, config)
    opts = Keyword.merge(opts, granite_plan: plan, granite_deadline: deadline)

    if Enum.any?(plan, &Plan.selected?/1) do
      configured_guard(
        Map.get(Config.get(:guards), "granite"),
        "granite",
        fields,
        value,
        context,
        policy,
        opts
      )
    else
      Granite.skipped(plan)
    end
  end

  defp assess(guard, fields, value, context, policy, opts) do
    if Snapshot.enabled?(policy, guard, context.stage) do
      configured_guard(
        Map.get(Config.get(:guards), guard),
        guard,
        fields,
        value,
        context,
        policy,
        opts
      )
    else
      {:ok, result} = GuardResult.new(%{guard: guard, status: :skipped})
      result
    end
  end

  defp configured_guard(nil, "granite", _, _, _, _, opts),
    do: Granite.unavailable(opts[:granite_plan])

  defp configured_guard(nil, guard, _, _, _, _, _), do: unavailable(guard)

  defp configured_guard(module, guard, fields, value, context, policy, opts) do
    started = System.monotonic_time(:microsecond)

    result =
      Gateway.measure(
        {:guard, context.stage, guard},
        fn -> call_guard(module, guard, fields, context, policy, opts) end,
        opts
      )

    opts = Keyword.put(opts, :granite_elapsed_us, System.monotonic_time(:microsecond) - started)
    validate_result(result, guard, value, context.stage, opts)
  end

  defp call_guard(module, guard, fields, context, policy, opts) do
    timeout =
      cond do
        guard == "granite" ->
          max(1, opts[:granite_deadline] - System.monotonic_time(:millisecond))

        guard in ~w(semantic moderation) ->
          Config.get(:semantic_timeout)

        true ->
          Config.get(:guard_timeout)
      end

    config =
      Keyword.merge(
        Config.get(),
        Keyword.take(opts, [
          :semantic_prompt,
          :granite_plan,
          :granite_deadline,
          :granite_identity,
          :run_context
        ])
      )

    Slots.run(if(guard == "granite", do: :granite, else: :guard), timeout, fn ->
      module.assess(fields, context, policy, config)
    end)
  end

  defp validate_result({:error, _}, "granite", _, _, opts),
    do: Granite.unavailable(opts[:granite_plan], opts[:granite_elapsed_us])

  defp validate_result({:error, {:capacity_exceeded, _}} = error, _, _, _, _), do: error

  defp validate_result({:ok, result}, guard, value, stage, opts) do
    if GuardResult.valid?(result) && result.guard == guard &&
         (guard != "granite" ||
            GraniteEvidence.matches_plan?(result.evidence, opts[:granite_plan])) &&
         adapter(opts).locations_valid?(
           value,
           Enum.map(result.detections, & &1.location) |> Enum.reject(&is_nil/1),
           stage
         ),
       do: result,
       else:
         if(guard == "granite",
           do: Granite.unavailable(opts[:granite_plan], opts[:granite_elapsed_us]),
           else: unavailable(guard)
         )
  end

  defp validate_result(_, "granite", _, _, opts),
    do: Granite.unavailable(opts[:granite_plan], opts[:granite_elapsed_us])

  defp validate_result(_, guard, _, _, _), do: unavailable(guard)

  defp unavailable(guard) do
    {:ok, result} =
      GuardResult.new(%{guard: guard, status: :error, error_code: "guard_unavailable"})

    result
  end

  defp enforce(value, %{action: :allow}, _, _), do: {:ok, value}

  defp enforce(value, %{action: :redact, redactions: spans}, stage, opts),
    do: adapter(opts).redact(value, spans, stage)

  defp enforce(_, %{reason_codes: reasons}, _, _) do
    cond do
      "required_guard_unavailable" in reasons -> {:error, :guard_unavailable}
      "redaction_unavailable" in reasons -> {:error, :redaction_unavailable}
      true -> {:error, :policy_blocked}
    end
  end
end

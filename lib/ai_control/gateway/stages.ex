defmodule AiControl.Gateway.Stages do
  @moduledoc "Assess and audit each current text version before using it at the next stage."
  alias AiControl.{Gateway, Security}
  alias AiControl.Gateway.{Config, Content, Request, Response, Slots}
  alias AiControl.Policy.Engine
  alias AiControl.Policy.Snapshot
  alias AiControl.Security.{GuardResult, SecurityAssessment}

  @phases [~w(pii secret signatures), ["ner"], ["semantic", "moderation"]]

  def evaluate(value, identity, policy, request_id, stage, opts \\ []) do
    Gateway.measure(
      stage,
      fn ->
        phases =
          Enum.filter(@phases, fn guards ->
            Enum.any?(guards, &Snapshot.enabled?(policy, &1, stage))
          end)

        if length(phases) < 2 do
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
    |> Enum.reduce_while({:ok, value, []}, fn {guards, index}, {:ok, current, previous} ->
      with {:ok, context} <- Gateway.context(identity, policy, request_id, stage),
           {:ok, results} <- results(current, context, policy, guards, opts),
           {:ok, assessment} <- SecurityAssessment.new(context, previous ++ results),
           {:ok, decision} <-
             phase_decision(context, assessment, policy, guards, index == length(phases) - 1),
           {:ok, safe} <- enforce(current, decision, stage, opts),
           :ok <- safe_contract(current, safe, stage, opts) do
        evidence = Enum.map(previous ++ results, &%{&1 | detections: []})
        {:cont, {:ok, safe, evidence}}
      else
        error -> {:halt, classify_error(error)}
      end
    end)
    |> case do
      {:ok, safe, _} -> {:ok, safe}
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
      |> Enum.reject(&(&1 in ~w(ner moderation) && !Snapshot.enabled?(policy, &1, stage)))

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

  defp configured_guard(nil, guard, _, _, _, _, _), do: unavailable(guard)

  defp configured_guard(module, guard, fields, value, context, policy, opts) do
    result =
      Gateway.measure(
        {:guard, context.stage, guard},
        fn -> call_guard(module, guard, fields, context, policy, opts) end,
        opts
      )

    validate_result(result, guard, value, context.stage, opts)
  end

  defp call_guard(module, guard, fields, context, policy, opts) do
    timeout =
      if guard in ~w(semantic moderation),
        do: Config.get(:semantic_timeout),
        else: Config.get(:guard_timeout)

    config = Keyword.merge(Config.get(), Keyword.take(opts, [:semantic_prompt]))

    Slots.run(:guard, timeout, fn ->
      module.assess(fields, context, policy, config)
    end)
  end

  defp validate_result({:error, {:capacity_exceeded, _}} = error, _, _, _, _), do: error

  defp validate_result({:ok, result}, guard, value, stage, opts) do
    if GuardResult.valid?(result) && result.guard == guard &&
         adapter(opts).locations_valid?(
           value,
           Enum.map(result.detections, & &1.location) |> Enum.reject(&is_nil/1),
           stage
         ),
       do: result,
       else: unavailable(guard)
  end

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

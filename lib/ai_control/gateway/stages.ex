defmodule AiControl.Gateway.Stages do
  @moduledoc "Assess and audit each current text version before using it at the next stage."
  alias AiControl.{Gateway, Security}
  alias AiControl.Gateway.{Config, Content, Request, Slots}
  alias AiControl.Policy.Engine
  alias AiControl.Policy.Snapshot
  alias AiControl.Security.{GuardResult, SecurityAssessment}

  @phases [~w(pii secret signatures), ["ner"], ["semantic"]]

  def evaluate(value, identity, policy, request_id, stage) do
    Gateway.measure(stage, fn ->
      phases =
        Enum.filter(@phases, fn guards ->
          Enum.any?(guards, &Snapshot.enabled?(policy, &1, stage))
        end)

      if length(phases) < 2 do
        complete(value, identity, policy, request_id, stage)
      else
        layered(value, identity, policy, request_id, stage, phases)
      end
    end)
  end

  defp layered(value, identity, policy, request_id, stage, phases) do
    phases
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, value, []}, fn {guards, index}, {:ok, current, previous} ->
      with {:ok, context} <- Gateway.context(identity, policy, request_id, stage),
           {:ok, results} <- results(current, context, policy, guards),
           {:ok, assessment} <- SecurityAssessment.new(context, previous ++ results),
           {:ok, decision} <-
             phase_decision(context, assessment, policy, guards, index == length(phases) - 1),
           {:ok, safe} <- enforce(current, decision),
           :ok <- safe_contract(current, safe, stage) do
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

  defp complete(value, identity, policy, request_id, stage) do
    guards =
      List.flatten(@phases)
      |> Enum.reject(&(&1 == "ner" && !Snapshot.enabled?(policy, &1, stage)))

    with {:ok, context} <- Gateway.context(identity, policy, request_id, stage),
         {:ok, results} <- results(value, context, policy, guards),
         {:ok, assessment} <- SecurityAssessment.new(context, results),
         {:ok, decision} <- Security.evaluate_and_audit(context, assessment, policy) do
      with {:ok, safe} <- enforce(value, decision),
           :ok <- safe_contract(value, safe, stage),
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

  defp results(value, context, policy, guards) do
    fields = Content.fields(value) |> Enum.map(& &1.text)

    Enum.reduce_while(guards, {:ok, []}, fn guard, {:ok, results} ->
      case assess(guard, fields, value, context, policy) do
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

  defp safe_contract(original, safe, :input) do
    case Request.validate(safe) do
      {:ok, _} ->
        if original["model"] == safe["model"], do: :ok, else: {:error, :redaction_unavailable}

      _ ->
        {:error, :redaction_unavailable}
    end
  end

  defp safe_contract(_, _, :output), do: :ok

  defp assess(guard, fields, value, context, policy) do
    if Snapshot.enabled?(policy, guard, context.stage) do
      configured_guard(Map.get(Config.get(:guards), guard), guard, fields, value, context, policy)
    else
      {:ok, result} = GuardResult.new(%{guard: guard, status: :skipped})
      result
    end
  end

  defp configured_guard(nil, guard, _, _, _, _), do: unavailable(guard)

  defp configured_guard(module, guard, fields, value, context, policy) do
    result = Gateway.measure(:guard, fn -> call_guard(module, fields, context, policy) end)
    validate_result(result, guard, value)
  end

  defp call_guard(module, fields, context, policy) do
    Slots.run(:guard, Config.get(:guard_timeout), fn ->
      module.assess(fields, context, policy, Config.get())
    end)
  end

  defp validate_result({:error, {:capacity_exceeded, _}} = error, _, _), do: error

  defp validate_result({:ok, result}, guard, value) do
    if GuardResult.valid?(result) && result.guard == guard &&
         Content.locations_valid?(
           value,
           Enum.map(result.detections, & &1.location) |> Enum.reject(&is_nil/1)
         ),
       do: result,
       else: unavailable(guard)
  end

  defp validate_result(_, guard, _), do: unavailable(guard)

  defp unavailable(guard) do
    {:ok, result} =
      GuardResult.new(%{guard: guard, status: :error, error_code: "guard_unavailable"})

    result
  end

  defp enforce(value, %{action: :allow}), do: {:ok, value}
  defp enforce(value, %{action: :redact, redactions: spans}), do: Content.redact(value, spans)

  defp enforce(_, %{reason_codes: reasons}) do
    cond do
      "required_guard_unavailable" in reasons -> {:error, :guard_unavailable}
      "redaction_unavailable" in reasons -> {:error, :redaction_unavailable}
      true -> {:error, :policy_blocked}
    end
  end
end

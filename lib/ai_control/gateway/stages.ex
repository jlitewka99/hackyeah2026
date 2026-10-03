defmodule AiControl.Gateway.Stages do
  @moduledoc "Assess and audit each current text version before using it at the next stage."
  alias AiControl.{Gateway, Security}
  alias AiControl.Gateway.{Config, Content, Slots}
  alias AiControl.Policy.Engine
  alias AiControl.Policy.Snapshot
  alias AiControl.Security.{GuardResult, SecurityAssessment}

  @deterministic ~w(pii secret signatures)
  @semantic ["semantic"]

  def evaluate(value, identity, policy, request_id, stage) do
    Gateway.measure(stage, fn -> evaluate_stages(value, identity, policy, request_id, stage) end)
  end

  defp evaluate_stages(value, identity, policy, request_id, stage) do
    layered? =
      Enum.any?(@semantic, &Snapshot.enabled?(policy, &1, stage)) &&
        Enum.any?(@deterministic, &Snapshot.enabled?(policy, &1, stage))

    if layered?,
      do: layered(value, identity, policy, request_id, stage),
      else: complete(value, identity, policy, request_id, stage)
  end

  defp layered(value, identity, policy, request_id, stage) do
    with {:ok, safe, previous} <- phase(value, identity, policy, request_id, stage),
         # Earlier findings have been audited; their ranges do not describe this version.
         previous = Enum.map(previous, &%{&1 | detections: []}),
         {:ok, context} <- Gateway.context(identity, policy, request_id, stage),
         {:ok, results} <- results(safe, context, policy, @semantic),
         {:ok, assessment} <- SecurityAssessment.new(context, previous ++ results),
         {:ok, decision} <- Security.evaluate_and_audit(context, assessment, policy) do
      enforce(safe, decision)
    else
      error -> classify_error(error)
    end
  end

  defp complete(value, identity, policy, request_id, stage) do
    with {:ok, context} <- Gateway.context(identity, policy, request_id, stage),
         {:ok, results} <- results(value, context, policy, @deterministic ++ @semantic),
         {:ok, assessment} <- SecurityAssessment.new(context, results),
         {:ok, decision} <- Security.evaluate_and_audit(context, assessment, policy) do
      enforce(value, decision)
    else
      error -> classify_error(error)
    end
  end

  defp phase(value, identity, policy, request_id, stage) do
    with {:ok, context} <- Gateway.context(identity, policy, request_id, stage),
         {:ok, results} <- results(value, context, policy, @deterministic),
         {:ok, assessment} <- SecurityAssessment.new(context, results),
         {:ok, decision} <-
           Engine.evaluate_phase(context, assessment, policy, @deterministic),
         {:ok, _} <-
           AiControl.Audit.record_phase_decision(context, assessment, decision, @deterministic),
         {:ok, safe} <- enforce(value, decision) do
      {:ok, safe, results}
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
        {:error, {:capacity_exceeded, _}} = error -> {:halt, error}
        result -> {:cont, {:ok, results ++ [result]}}
      end
    end)
  end

  defp assess(guard, fields, value, context, policy) do
    if Snapshot.enabled?(policy, guard, context.stage) do
      configured_guard(Map.get(Config.get(:guards), guard), guard, fields, value, context)
    else
      {:ok, result} = GuardResult.new(%{guard: guard, status: :skipped})
      result
    end
  end

  defp configured_guard(nil, guard, _, _, _), do: unavailable(guard)

  defp configured_guard(module, guard, fields, value, context) do
    result = Gateway.measure(:guard, fn -> call_guard(module, fields, context) end)
    validate_result(result, guard, value)
  end

  defp call_guard(module, fields, context) do
    Slots.run(:guard, Config.get(:guard_timeout), fn ->
      module.assess(fields, context, Config.get())
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

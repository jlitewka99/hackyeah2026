defmodule AiControl.Policy.Engine do
  @moduledoc "Pure deterministic enforcement: BLOCK takes precedence over REDACT, then ALLOW."
  alias AiControl.Policies.Configuration
  alias AiControl.Policy.Snapshot
  alias AiControl.Security.{Decision, Detection, SecurityAssessment, SecurityContext}

  @spec evaluate(SecurityContext.t(), SecurityAssessment.t(), Snapshot.t()) ::
          {:ok, Decision.t()} | {:error, :invalid_security_data}
  def evaluate(context, assessment, policy) do
    if valid_inputs?(context, assessment, policy),
      do:
        evaluate_required(
          context,
          assessment,
          policy,
          Snapshot.required_guards(policy, context.stage)
        ),
      else: {:error, :invalid_security_data}
  end

  @doc "Intermediate phase only; the gateway must complete every phase before downstream."
  def evaluate_phase(context, assessment, policy, guards) do
    catalog = Configuration.guards(2)

    if valid_inputs?(context, assessment, policy) && is_list(guards) && guards != [] &&
         Enum.all?(guards, &(&1 in catalog)) &&
         Enum.all?(assessment.results, &(&1.guard in guards)) do
      required = Enum.filter(Snapshot.required_guards(policy, context.stage), &(&1 in guards))
      evaluate_required(context, assessment, policy, required)
    else
      {:error, :invalid_security_data}
    end
  end

  defp evaluate_required(context, assessment, policy, required) do
    if valid_inputs?(context, assessment, policy) do
      unavailable =
        required --
          (assessment.results |> Enum.filter(&(&1.status == :ok)) |> Enum.map(& &1.guard))

      initial =
        if unavailable == [],
          do: {:allow, [], [], []},
          else: {:block, [], ["required_guard_unavailable"], []}

      {action, rules, reasons, redactions} =
        assessment.detections
        |> Enum.filter(&Snapshot.enabled?(policy, &1.guard, context.stage))
        |> Enum.reduce(initial, &apply_detection(&1, &2, policy))

      Decision.new(%{
        assessment_id: assessment.id,
        request_id: context.request_id,
        stage: context.stage,
        action: action,
        policy_version: policy.version,
        policy_checksum: policy.checksum,
        policy: policy,
        rule_ids: Enum.sort(Enum.uniq(rules)),
        reason_codes: Enum.sort(Enum.uniq(["policy.#{action}" | reasons])),
        redactions: if(action == :redact, do: Enum.uniq(redactions), else: [])
      })
    else
      {:error, :invalid_security_data}
    end
  end

  defp valid_inputs?(context, assessment, policy),
    do:
      SecurityContext.valid?(context) && SecurityAssessment.valid?(assessment) &&
        Snapshot.valid?(policy) && context.assessment_id == assessment.id &&
        context.request_id == assessment.request_id && context.stage == assessment.stage &&
        context.policy_version == policy.version && context.policy_checksum == policy.checksum

  defp apply_detection(detection, {action, rules, reasons, redactions}, policy) do
    case Map.fetch(policy.rules, detection.category) do
      :error ->
        {:block, rules, ["unmapped_detection" | reasons], redactions}

      {:ok, rule} ->
        if detection.confidence >= Map.get(rule, :threshold, 0) do
          {next, reason, location} = enforcement(rule.action, detection)
          {strongest(action, next), [rule.id | rules], [reason | reasons], location ++ redactions}
        else
          {action, rules, reasons, redactions}
        end
    end
  end

  defp enforcement(:redact, detection) do
    if Detection.redactable?(detection),
      do: {:redact, "policy.redact", [detection.location]},
      else: {:block, "redaction_unavailable", []}
  end

  defp enforcement(action, _), do: {action, "policy.#{action}", []}
  defp strongest(:block, _), do: :block
  defp strongest(_, :block), do: :block
  defp strongest(:redact, _), do: :redact
  defp strongest(_, :redact), do: :redact
  defp strongest(_, _), do: :allow
end

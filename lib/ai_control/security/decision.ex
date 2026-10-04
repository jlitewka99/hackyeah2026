defmodule AiControl.Security.Decision do
  @moduledoc "A deterministic policy outcome with machine-readable reasons."
  alias AiControl.Policy.Snapshot
  alias AiControl.Security.{Detection, Validation}

  @fields [
    :assessment_id,
    :request_id,
    :stage,
    :action,
    :policy_version,
    :policy_checksum,
    :policy,
    :rule_ids,
    :reason_codes,
    :redactions
  ]
  @reasons ~w(policy.allow policy.redact policy.block policy.review required_guard_unavailable unmapped_detection redaction_unavailable)
  defstruct @fields

  @type t :: %__MODULE__{
          assessment_id: Ecto.UUID.t(),
          request_id: Ecto.UUID.t(),
          stage: :input | :output,
          action: :allow | :redact | :block | :review,
          policy_version: String.t(),
          policy_checksum: String.t(),
          policy: Snapshot.t(),
          rule_ids: [String.t()],
          reason_codes: [String.t()],
          redactions: [Detection.location()]
        }

  def new(attrs), do: Validation.build(__MODULE__, attrs, @fields, &valid?/1)

  def valid?(%__MODULE__{} = decision) do
    Validation.uuid?(decision.assessment_id) && Validation.uuid?(decision.request_id) &&
      decision.stage in [:input, :output] && decision.action in [:allow, :redact, :block, :review] &&
      policy?(decision) &&
      Validation.codes?(decision.rule_ids) && reasons?(decision.reason_codes) &&
      redactions?(decision)
  end

  def valid?(_), do: false

  defp policy?(decision),
    do:
      Snapshot.valid?(decision.policy) &&
        {decision.policy_version, decision.policy_checksum} ==
          {decision.policy.version, decision.policy.checksum}

  defp reasons?(values), do: is_list(values) && Enum.all?(values, &(&1 in @reasons))

  defp redactions?(%{action: :redact, redactions: [_ | _] = locations}),
    do: Enum.all?(locations, &Detection.redactable?(%Detection{location: &1}))

  defp redactions?(%{action: action, redactions: []}) when action in [:allow, :block, :review],
    do: true

  defp redactions?(_), do: false
end

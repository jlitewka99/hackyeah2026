defmodule AiControl.Security.GuardResult do
  @moduledoc "Guard measurements and findings. Enforcement belongs to Policy.Engine."
  alias AiControl.Budgets.Usage
  alias AiControl.Security.{Detection, GraniteEvidence, SemanticEvidence, Validation}

  @fields [:guard, :status, :detections, :signals, :duration_us, :error_code, :usage, :evidence]
  @signals ~w(risk_score injection_score pii_count secret_count exploit_count)
  @error_codes ~w(provider_unavailable provider_timeout provider_invalid_response guard_unavailable upstream_timeout upstream_unavailable upstream_rejected upstream_invalid_response)
  defstruct guard: nil,
            status: nil,
            detections: [],
            signals: %{},
            duration_us: 0,
            error_code: nil,
            usage: nil,
            evidence: %{}

  @type t :: %__MODULE__{
          guard: String.t(),
          status: :ok | :error | :skipped,
          detections: [Detection.t()],
          signals: map(),
          duration_us: non_neg_integer(),
          error_code: String.t() | nil,
          usage: map() | nil,
          evidence: map()
        }

  def new(attrs), do: Validation.build(__MODULE__, attrs, @fields, &valid?/1)

  def valid?(%__MODULE__{} = result) do
    Validation.code?(result.guard) && result_status?(result) &&
      detections?(result) &&
      signals?(result.signals) && Validation.duration?(result.duration_us) &&
      evidence?(result) && usage?(result.usage)
  end

  def valid?(_), do: false

  defp result_status?(result),
    do:
      result.status in [:ok, :error, :skipped] && error_code?(result) &&
        (result.status == :ok || result.detections == [])

  defp evidence?(%{guard: "granite", status: :error, evidence: evidence}) when evidence == %{},
    do: true

  defp evidence?(%{guard: "granite"} = result) do
    evidence = result.evidence
    GraniteEvidence.valid?(evidence) and GraniteEvidence.outcome_valid?(result)
  end

  defp evidence?(result),
    do:
      SemanticEvidence.valid?(result.evidence) &&
        (result.evidence == %{} || result.guard in ~w(semantic moderation))

  defp usage?(nil), do: true
  defp usage?(value), do: match?({:ok, ^value}, Usage.normalize(value))

  defp detections?(result),
    do:
      is_list(result.detections) &&
        Enum.all?(result.detections, &(Detection.valid?(&1) && &1.guard == result.guard))

  defp error_code?(%{status: :error, error_code: code}), do: code in @error_codes
  defp error_code?(%{error_code: nil}), do: true
  defp error_code?(_), do: false

  defp signals?(signals) when is_map(signals) and not is_struct(signals),
    do: Enum.all?(signals, fn {name, value} -> name in @signals && signal_value?(name, value) end)

  defp signals?(_), do: false

  defp signal_value?(name, value) when name in ["risk_score", "injection_score"],
    do: Validation.score?(value)

  defp signal_value?(_, value), do: Validation.duration?(value)
end

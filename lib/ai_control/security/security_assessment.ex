defmodule AiControl.Security.SecurityAssessment do
  @moduledoc "An immutable aggregate of guard results for one context."
  alias AiControl.Security.{GuardResult, SecurityContext, Validation}

  defstruct [
    :id,
    :request_id,
    :stage,
    results: [],
    detections: [],
    failed_guards: [],
    duration_us: 0
  ]

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          request_id: Ecto.UUID.t(),
          stage: :input | :output,
          results: [GuardResult.t()],
          detections: [AiControl.Security.Detection.t()],
          failed_guards: [String.t()],
          duration_us: non_neg_integer()
        }

  def new(context, results) do
    if SecurityContext.valid?(context) && results?(results) do
      {:ok,
       %__MODULE__{
         id: context.assessment_id,
         request_id: context.request_id,
         stage: context.stage,
         results: results,
         detections: Enum.flat_map(results, & &1.detections),
         failed_guards: results |> Enum.reject(&(&1.status == :ok)) |> Enum.map(& &1.guard),
         duration_us: Enum.sum(Enum.map(results, & &1.duration_us))
       }}
    else
      {:error, :invalid_security_data}
    end
  end

  def valid?(%__MODULE__{} = assessment) do
    Validation.uuid?(assessment.id) && Validation.uuid?(assessment.request_id) &&
      assessment.stage in [:input, :output] && results?(assessment.results) &&
      assessment.detections == Enum.flat_map(assessment.results, & &1.detections) &&
      assessment.failed_guards ==
        assessment.results |> Enum.reject(&(&1.status == :ok)) |> Enum.map(& &1.guard) &&
      assessment.duration_us == Enum.sum(Enum.map(assessment.results, & &1.duration_us))
  end

  def valid?(_), do: false

  defp results?(results) when is_list(results),
    do:
      Enum.all?(results, &GuardResult.valid?/1) &&
        length(results) == length(Enum.uniq_by(results, & &1.guard))

  defp results?(_), do: false
end

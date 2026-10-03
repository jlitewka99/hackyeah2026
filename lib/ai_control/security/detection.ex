defmodule AiControl.Security.Detection do
  @moduledoc "A content-free finding; locations use a field index and UTF-8 byte offsets."
  alias AiControl.Security.Validation

  @fields [:guard, :category, :rule_id, :confidence, :location]
  defstruct @fields

  @type location :: %{
          field_index: non_neg_integer(),
          start_byte: non_neg_integer(),
          end_byte: pos_integer()
        }
  @type t :: %__MODULE__{
          guard: String.t(),
          category: String.t(),
          rule_id: String.t(),
          confidence: number(),
          location: location() | nil
        }

  def new(attrs), do: Validation.build(__MODULE__, attrs, @fields, &valid?/1)

  def valid?(%__MODULE__{} = finding),
    do:
      Validation.code?(finding.guard) && Validation.code?(finding.category) &&
        Validation.code?(finding.rule_id) && Validation.score?(finding.confidence) &&
        location?(finding.location)

  def valid?(_), do: false

  def redactable?(%__MODULE__{location: location}),
    do: not is_nil(location) && location?(location)

  defp location?(nil), do: true

  defp location?(%{field_index: field, start_byte: first, end_byte: last} = location),
    do:
      map_size(location) == 3 && is_integer(field) && field >= 0 && is_integer(first) &&
        first >= 0 && is_integer(last) && last > first

  defp location?(_), do: false
end

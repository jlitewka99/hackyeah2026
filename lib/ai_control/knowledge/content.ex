defmodule AiControl.Knowledge.Content do
  @moduledoc "Redactable text fields; ownership, trust and revisions are never text selectors."
  alias AiControl.Gateway.Content

  @text_fields ~w(title content source_reference query)
  def fields(value, _stage) do
    @text_fields
    |> Enum.filter(&Map.has_key?(value, &1))
    |> Enum.map(&%{text: value[&1], path: [&1]})
  end

  def locations_valid?(value, locations, stage),
    do: Content.locations_valid_fields?(locations, fields(value, stage))

  def redact(value, locations, stage),
    do: Content.redact_fields(value, locations, fields(value, stage))

  def validate(original, safe, _, _) do
    if Map.drop(original, @text_fields) == Map.drop(safe, @text_fields) and
         Enum.all?(fields(safe, :input), &(is_binary(&1.text) and String.valid?(&1.text))),
       do: :ok,
       else: {:error, :redaction_unavailable}
  end
end

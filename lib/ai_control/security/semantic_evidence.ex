defmodule AiControl.Security.SemanticEvidence do
  @moduledoc "Bounded allowlist of classifier evidence; no free-form model output."
  alias AiControl.Policies.Configuration
  alias AiControl.Security.Validation

  def valid?(evidence) when evidence == %{}, do: true

  def valid?(
        %{
          "model_set" => set,
          "revision" => revision,
          "task" => task,
          "signal_kind" => "label_mapping_binary",
          "windows" => windows
        } = evidence
      ) do
    map_size(evidence) == 5 && Validation.code?(set) && is_binary(revision) &&
      Regex.match?(~r/\A[0-9a-f]{40}\z/, revision) && task in ~w(injection moderation) &&
      is_list(windows) && length(windows) <= 128 && Enum.all?(windows, &window?/1)
  end

  def valid?(_), do: false

  def window?(
        %{
          "field_index" => index,
          "start_byte" => first,
          "end_byte" => last,
          "severity" => severity,
          "categories" => categories,
          "refusal" => refusal
        } = window
      ) do
    map_size(window) == 6 && range?(index, first, last) &&
      severity in ~w(Safe Unsafe Controversial) &&
      categories?(categories) &&
      refusal in [nil, "Yes", "No"]
  end

  def window?(_), do: false

  defp range?(index, first, last),
    do:
      is_integer(index) && index >= 0 && is_integer(first) && first >= 0 && is_integer(last) &&
        last >= first

  defp categories?(categories),
    do:
      is_list(categories) && length(categories) == length(Enum.uniq(categories)) &&
        Enum.all?(categories, &(&1 in ["Jailbreak" | Configuration.safety_categories()]))
end

defmodule AiControl.Gateway.Content do
  @moduledoc "Stable field indexes for exactly one text version; byte-safe merged redactions."

  def fields(value), do: walk(value, [])
  defp walk(value, path) when is_binary(value), do: [%{path: path, text: value}]

  defp walk(value, path) when is_list(value) do
    value
    |> Enum.with_index()
    |> Enum.flat_map(fn {item, index} -> walk(item, path ++ [index]) end)
  end

  defp walk(value, path) when is_map(value) do
    value
    |> Enum.sort()
    |> Enum.flat_map(fn {key, item} ->
      [%{path: nil, text: key} | walk(item, path ++ [key])]
    end)
  end

  defp walk(_, _), do: []

  def redact(value, locations) do
    fields = fields(value)

    case Enum.all?(locations, &redactable_location?(&1, fields)) do
      true ->
        result =
          locations
          |> Enum.group_by(& &1.field_index)
          |> Enum.reduce(value, fn {index, spans}, acc ->
            field = Enum.at(fields, index)
            replace(acc, field.path, redact_text(field.text, spans))
          end)

        {:ok, result}

      _ ->
        {:error, :redaction_unavailable}
    end
  end

  def locations_valid?(value, locations), do: Enum.all?(locations, &location?(&1, fields(value)))

  defp location?(%{field_index: index, start_byte: first, end_byte: last}, fields)
       when is_integer(index) and index >= 0 and is_integer(first) and is_integer(last) do
    case Enum.at(fields, index) do
      %{text: text} ->
        utf8_range?(text, first, last)

      _ ->
        false
    end
  end

  defp location?(_, _), do: false

  defp redactable_location?(location, fields) do
    location?(location, fields) && !is_nil(Enum.at(fields, location.field_index).path)
  end

  defp utf8_range?(text, first, last) do
    first >= 0 && last > first && last <= byte_size(text) &&
      String.valid?(binary_part(text, 0, first)) &&
      String.valid?(binary_part(text, first, last - first)) &&
      String.valid?(binary_part(text, last, byte_size(text) - last))
  end

  defp redact_text(text, spans) do
    spans
    |> Enum.map(&{&1.start_byte, &1.end_byte})
    |> Enum.sort()
    |> Enum.reduce([], fn
      {first, last}, [{prev_first, prev_last} | rest] when first <= prev_last ->
        [{prev_first, max(last, prev_last)} | rest]

      span, merged ->
        [span | merged]
    end)
    |> Enum.reduce(text, fn {first, last}, current ->
      binary_part(current, 0, first) <>
        "[REDACTED]" <> binary_part(current, last, byte_size(current) - last)
    end)
  end

  defp replace(_, [], replacement), do: replacement

  defp replace(value, [index | rest], replacement) when is_list(value),
    do: List.update_at(value, index, &replace(&1, rest, replacement))

  defp replace(value, [key | rest], replacement),
    do: Map.update!(value, key, &replace(&1, rest, replacement))
end

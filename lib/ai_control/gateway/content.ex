defmodule AiControl.Gateway.Content do
  @moduledoc "Stable field indexes for exactly one text version; byte-safe merged redactions."

  def fields(value, stage \\ :input)
  def fields(value, :input), do: walk(value, [])
  def fields(value, :output), do: value |> output_projection() |> elem(1)

  # Only message content is mutable. Tool arguments are decoded before scanning,
  # so JSON escaping cannot hide a value from a detector. Context prefixes are
  # scan-only, and offsets still refer to exactly the text supplied to guards.
  defp output_projection(value) do
    message_path = ["choices", 0, "message"]
    message = hd(value["choices"])["message"]
    content = walk(message["content"], message_path ++ ["content"])

    {projected, fields} =
      (message["tool_calls"] || [])
      |> Enum.with_index()
      |> Enum.reduce({value, content}, fn {call, index}, {current, fields} ->
        path = message_path ++ ["tool_calls", index, "function", "arguments"]
        arguments = Jason.decode!(call["function"]["arguments"])
        identifiers = [readonly(call["id"]), readonly(call["function"]["name"])]

        {replace(current, path, arguments),
         fields ++ identifiers ++ argument_fields(arguments, path, "")}
      end)

    {projected, fields}
  end

  defp argument_fields(value, path, _label) when is_map(value) do
    value
    |> Enum.sort()
    |> Enum.flat_map(fn {key, item} ->
      [readonly(key) | argument_fields(item, path ++ [key], key)]
    end)
  end

  defp argument_fields(value, path, label) when is_list(value) do
    value
    |> Enum.with_index()
    |> Enum.flat_map(fn {item, index} -> argument_fields(item, path ++ [index], label) end)
  end

  defp argument_fields(value, path, label) when is_binary(value) do
    prefix = if label == "", do: "", else: label <> ": "
    [%{path: path, text: prefix <> value, offset: byte_size(prefix)}]
  end

  defp argument_fields(value, _path, label), do: [readonly(label <> ": " <> Jason.encode!(value))]

  defp readonly(text), do: %{path: nil, text: text}
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

  def redact(value, locations, stage \\ :input) do
    {projected, fields} =
      if stage == :output, do: output_projection(value), else: {value, fields(value)}

    case Enum.all?(locations, &redactable_location?(&1, fields)) do
      true ->
        result =
          locations
          |> Enum.group_by(& &1.field_index)
          |> Enum.reduce(projected, fn {index, spans}, acc ->
            field = Enum.at(fields, index)
            offset = Map.get(field, :offset, 0)
            text = binary_part(field.text, offset, byte_size(field.text) - offset)

            spans =
              Enum.map(
                spans,
                &%{&1 | start_byte: &1.start_byte - offset, end_byte: &1.end_byte - offset}
              )

            replace(acc, field.path, redact_text(text, spans))
          end)

        {:ok, if(stage == :output, do: encode_arguments(result), else: result)}

      _ ->
        {:error, :redaction_unavailable}
    end
  end

  def locations_valid?(value, locations, stage \\ :input) do
    fields = fields(value, stage)
    Enum.all?(locations, &location?(&1, fields))
  end

  defp encode_arguments(value) do
    update_in(value, ["choices", Access.at(0), "message"], &encode_message/1)
  end

  defp encode_message(%{"tool_calls" => calls} = message),
    do: Map.put(message, "tool_calls", Enum.map(calls, &encode_call/1))

  defp encode_message(message), do: message
  defp encode_call(call), do: update_in(call, ["function", "arguments"], &Jason.encode!/1)

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
    location?(location, fields) &&
      case Enum.at(fields, location.field_index) do
        %{path: nil} -> false
        field -> location.start_byte >= Map.get(field, :offset, 0)
      end
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

defmodule AiControl.Workflows.Action do
  @moduledoc "Canonical action material for HMAC; transport call IDs do not distinguish actions."

  def canonical("chat", %{"messages" => messages} = payload) when is_list(messages) do
    payload
    |> Map.drop(["stream", "stream_options"])
    |> Map.put("messages", Enum.map(messages, &message/1))
    |> canonical_value()
  end

  def canonical(_, payload), do: canonical_value(payload)

  defp message(message) when is_map(message) do
    message = Map.delete(message, "tool_call_id")

    if is_list(message["tool_calls"]),
      do:
        Map.update!(
          message,
          "tool_calls",
          &Enum.map(&1, fn call -> call |> Map.delete("id") |> arguments() end)
        ),
      else: message
  end

  defp message(message), do: message

  defp arguments(%{"function" => %{"arguments" => text} = function} = call)
       when is_binary(text) do
    case Jason.decode(text) do
      {:ok, value} when is_map(value) ->
        Map.put(call, "function", Map.put(function, "arguments", value))

      _ ->
        call
    end
  end

  defp arguments(call), do: call

  defp canonical_value(value) when is_map(value),
    do: value |> Enum.sort() |> Enum.map(fn {key, item} -> {key, canonical_value(item)} end)

  defp canonical_value(value) when is_list(value), do: Enum.map(value, &canonical_value/1)
  defp canonical_value(value), do: value
end

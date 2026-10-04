defmodule AiControl.Gateway.StreamEncoder do
  @moduledoc "Lazy public deltas derived only from the validated response, never upstream frames."

  def frames(response, include_usage?) do
    [choice] = response["choices"]
    message = choice["message"]

    base =
      response |> Map.take(~w(id created model)) |> Map.put("object", "chat.completion.chunk")

    role = chunk(base, %{"role" => "assistant"}, nil)
    content = Stream.map(parts(message["content"] || ""), &chunk(base, %{"content" => &1}, nil))

    calls =
      (message["tool_calls"] || [])
      |> Enum.with_index()
      |> Stream.map(fn {call, index} ->
        chunk(base, %{"tool_calls" => [Map.put(call, "index", index)]}, nil)
      end)

    finish = chunk(base, %{}, choice["finish_reason"])

    usage =
      if include_usage?,
        do: [encode(Map.merge(base, %{"choices" => [], "usage" => response["usage"]}))],
        else: []

    Stream.concat([[role], content, calls, [finish], usage])
  end

  defp parts(text) do
    Stream.unfold(text, fn
      "" ->
        nil

      remaining ->
        size = boundary(remaining, min(byte_size(remaining), 1024))
        <<part::binary-size(^size), rest::binary>> = remaining
        {part, rest}
    end)
  end

  defp boundary(text, size) do
    if String.valid?(binary_part(text, 0, size)), do: size, else: boundary(text, size - 1)
  end

  defp chunk(base, delta, finish),
    do:
      encode(
        Map.put(base, "choices", [%{"index" => 0, "delta" => delta, "finish_reason" => finish}])
      )

  defp encode(value), do: "data: " <> Jason.encode!(value) <> "\n\n"
end

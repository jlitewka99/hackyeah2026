defmodule AiControl.Gateway.StreamParser do
  @moduledoc "Bounded SSE decoder and single-choice assembler. Transport chunks are arbitrary bytes."
  alias AiControl.Budgets.Usage

  defstruct pending: "",
            bytes: 0,
            frames: 0,
            limit: 0,
            meta: nil,
            content: [],
            calls: %{},
            finish: nil,
            usage: nil,
            done?: false

  def new(limit), do: %__MODULE__{limit: limit}

  def feed(state, chunk, on_usage \\ fn _ -> :ok end) when is_binary(chunk) do
    size = state.bytes + byte_size(chunk)

    if size > state.limit do
      {:error, :response_too_large}
    else
      consume(%{state | pending: state.pending <> chunk, bytes: size}, on_usage)
    end
  end

  def finish(%{done?: true, pending: pending} = state) do
    if String.trim(pending) == "", do: assemble(state), else: invalid()
  end

  def finish(_), do: invalid()

  defp consume(state, on_usage) do
    case :binary.match(state.pending, ["\n\n", "\r\n\r\n"]) do
      :nomatch ->
        {:ok, state}

      {offset, length} ->
        <<frame::binary-size(^offset), _::binary-size(^length), rest::binary>> = state.pending

        with {:ok, next} <- frame(%{state | pending: rest}, frame, on_usage),
             do: consume(next, on_usage)
    end
  end

  defp frame(state, raw, on_usage) do
    if String.valid?(raw) do
      lines = String.split(raw, ~r/\r?\n/)
      data = for "data:" <> value <- lines, do: String.trim_leading(value, " ")
      error? = Enum.any?(lines, &(&1 in ["event: error", "event:error"]))

      cond do
        error? -> invalid()
        data == [] -> {:ok, state}
        state.done? -> invalid()
        true -> event(%{state | frames: state.frames + 1}, Enum.join(data, "\n"), on_usage)
      end
    else
      invalid()
    end
  end

  defp event(state, "[DONE]", _) do
    if state.finish && state.usage, do: {:ok, %{state | done?: true}}, else: invalid()
  end

  defp event(state, data, on_usage) do
    with {:ok, chunk} when is_map(chunk) <- Jason.decode(data),
         {:ok, state} <- metadata(state, chunk),
         {:ok, state} <- choices(state, chunk),
         {:ok, state} <- usage(state, chunk, on_usage),
         do: {:ok, state},
         else: (
           {:error, _} = error -> error
           _ -> invalid()
         )
  end

  defp metadata(state, %{
         "object" => "chat.completion.chunk",
         "id" => id,
         "created" => created,
         "model" => model
       })
       when is_binary(id) and byte_size(id) in 1..256 and is_binary(model) and
              byte_size(model) in 1..256 and is_integer(created) and created >= 0 do
    meta = {id, created, model}
    if state.meta in [nil, meta], do: {:ok, %{state | meta: meta}}, else: invalid()
  end

  defp metadata(_, _), do: invalid()

  defp choices(%{finish: finish} = state, %{"choices" => [], "usage" => usage})
       when not is_nil(finish) and is_map(usage), do: {:ok, state}

  defp choices(%{finish: nil} = state, %{"choices" => [choice]}) do
    with %{"index" => 0, "delta" => delta, "finish_reason" => finish} when is_map(delta) <- choice,
         true <-
           finish in [
             nil,
             "stop",
             "length",
             "tool_calls",
             "content_filter",
             "insufficient_system_resource",
             "aborted"
           ],
         true <- Map.get(delta, "role", "assistant") in [nil, "assistant"],
         content = Map.get(delta, "content"),
         true <- is_nil(content) || (is_binary(content) && String.valid?(content)),
         {:ok, calls} <- calls(state.calls, Map.get(delta, "tool_calls") || []) do
      content = if is_binary(content), do: [content | state.content], else: state.content
      {:ok, %{state | content: content, calls: calls, finish: finish}}
    else
      _ -> invalid()
    end
  end

  defp choices(_, _), do: invalid()

  defp calls(stored, deltas) when is_list(deltas) and length(deltas) <= 100 do
    Enum.reduce_while(deltas, {:ok, stored}, fn delta, {:ok, acc} ->
      case call(acc, delta) do
        {:ok, result} -> {:cont, {:ok, result}}
        error -> {:halt, error}
      end
    end)
  end

  defp calls(_, _), do: invalid()

  defp call(stored, %{"index" => index} = delta) when is_integer(index) and index in 0..99 do
    current = Map.get(stored, index, %{id: "", name: "", arguments: [], type: nil})
    function = Map.get(delta, "function", %{})

    with true <- is_map(function),
         id = Map.get(delta, "id", ""),
         name = Map.get(function, "name", ""),
         arguments = Map.get(function, "arguments", ""),
         true <- Enum.all?([id, name, arguments], &(is_binary(&1) && String.valid?(&1))),
         type = Map.get(delta, "type", current.type),
         true <- type in [nil, "function"] do
      value = %{
        id: current.id <> id,
        name: current.name <> name,
        arguments: [arguments | current.arguments],
        type: type
      }

      {:ok, Map.put(stored, index, value)}
    else
      _ -> invalid()
    end
  end

  defp call(_, _), do: invalid()

  defp usage(state, %{"usage" => value}, on_usage) when not is_nil(value) do
    with true <- !is_nil(state.finish) && is_nil(state.usage),
         {:ok, normalized} <- normalize_usage(value),
         :ok <- on_usage.(normalized),
         do: {:ok, %{state | usage: normalized}},
         else: (
           {:error, _} = error -> error
           _ -> invalid()
         )
  end

  defp usage(state, _, _), do: {:ok, state}

  defp normalize_usage(value) do
    case Usage.normalize(value) do
      {:ok, normalized} -> {:ok, normalized}
      _ -> invalid()
    end
  end

  defp assemble(state) do
    indexes = state.calls |> Map.keys() |> Enum.sort()
    expected = if indexes == [], do: [], else: Enum.to_list(0..(length(indexes) - 1))

    calls =
      Enum.map(indexes, fn index ->
        value = Map.fetch!(state.calls, index)

        %{
          "id" => value.id,
          "type" => value.type,
          "function" => %{"name" => value.name, "arguments" => join(value.arguments)}
        }
      end)

    message = %{"role" => "assistant", "content" => join(state.content)}
    message = if calls == [], do: message, else: Map.put(message, "tool_calls", calls)

    response = %{
      "choices" => [%{"message" => message, "finish_reason" => state.finish}],
      "usage" => state.usage
    }

    cond do
      state.finish in ["content_filter", "insufficient_system_resource", "aborted"] ->
        {:error, :upstream_rejected}

      indexes != expected ->
        invalid()

      byte_size(Jason.encode!(response)) > state.limit ->
        {:error, :response_too_large}

      true ->
        {:ok, response}
    end
  end

  defp join(parts), do: parts |> Enum.reverse() |> IO.iodata_to_binary()
  defp invalid, do: {:error, :upstream_invalid_response}
end

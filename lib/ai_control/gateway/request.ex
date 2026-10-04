defmodule AiControl.Gateway.Request do
  @moduledoc "Explicit text-only Chat Completions subset. Identity is a separate argument."
  @keys ~w(model messages tools tool_choice stream temperature top_p max_tokens seed stop n context)
  @message_keys ~w(role content name tool_calls tool_call_id)

  def validate(params) do
    if object?(params, @keys) && text?(params["model"]) && messages?(params["messages"]) &&
         optional?(params, "tools", &tools?/1) && choices?(params) && options?(params) &&
         context?(params) do
      {:ok, Map.put(params, "stream", false)}
    else
      {:error, :invalid_request}
    end
  end

  def messages?(messages),
    do: is_list(messages) && length(messages) in 1..1_000 && Enum.all?(messages, &message?/1)

  def message?(message) do
    object?(message, @message_keys) &&
      message["role"] in ~w(system developer user assistant tool) &&
      optional?(message, "name", &name?/1) && message_content?(message)
  end

  defp message_content?(%{"role" => "assistant"} = message) do
    (is_binary(message["content"]) ||
       (is_nil(message["content"]) && Map.has_key?(message, "tool_calls"))) &&
      optional?(message, "tool_calls", &calls?/1) && !Map.has_key?(message, "tool_call_id")
  end

  defp message_content?(%{"role" => "tool"} = message),
    do:
      is_binary(message["content"]) && text?(message["tool_call_id"]) &&
        !Map.has_key?(message, "tool_calls")

  defp message_content?(message),
    do:
      is_binary(message["content"]) && !Map.has_key?(message, "tool_calls") &&
        !Map.has_key?(message, "tool_call_id")

  def calls?(calls), do: is_list(calls) && length(calls) in 1..100 && Enum.all?(calls, &call?/1)

  defp call?(call) do
    object?(call, ~w(id type function)) && text?(call["id"]) && call["type"] == "function" &&
      object?(call["function"], ~w(name arguments)) && name?(call["function"]["name"]) &&
      arguments?(call["function"]["arguments"])
  end

  defp arguments?(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, object} -> is_map(object)
      _ -> false
    end
  end

  defp arguments?(_), do: false

  defp tools?(tools) do
    is_list(tools) && length(tools) <= 100 && Enum.all?(tools, &tool?/1) &&
      tools |> Enum.map(& &1["function"]["name"]) |> Enum.uniq() |> length() == length(tools)
  end

  defp tool?(tool) do
    object?(tool, ~w(type function)) && tool["type"] == "function" &&
      object?(tool["function"], ~w(name description parameters)) &&
      name?(tool["function"]["name"]) &&
      optional?(tool["function"], "description", &is_binary/1) &&
      optional?(tool["function"], "parameters", &schema?/1)
  end

  defp schema?(%{"type" => "object"} = schema), do: json?(schema, 0)
  defp schema?(_), do: false
  defp json?(_, depth) when depth > 16, do: false

  defp json?(value, depth) when is_map(value),
    do: Enum.all?(value, fn {key, val} -> is_binary(key) && json?(val, depth + 1) end)

  defp json?(value, depth) when is_list(value), do: Enum.all?(value, &json?(&1, depth + 1))

  defp json?(value, _),
    do: is_nil(value) || is_boolean(value) || is_number(value) || is_binary(value)

  defp choices?(params) do
    case Map.get(params, "tool_choice", "auto") do
      value when value in ["auto", "none", "required"] ->
        value != "required" || params["tools"] not in [nil, []]

      %{"type" => "function", "function" => %{"name" => name}} = choice ->
        object?(choice, ~w(type function)) && object?(choice["function"], ["name"]) &&
          Enum.any?(params["tools"] || [], &(&1["function"]["name"] == name))

      _ ->
        false
    end
  end

  defp options?(params) do
    Map.get(params, "stream", false) == false && Map.get(params, "n", 1) == 1 &&
      optional?(params, "temperature", &range?(&1, 0, 2)) &&
      optional?(params, "top_p", &range?(&1, 0, 1)) &&
      optional?(params, "max_tokens", &integer_range?(&1, 1..32_768)) &&
      optional?(params, "seed", &seed?/1) &&
      optional?(params, "stop", &stops?/1)
  end

  defp context?(%{"context" => context, "messages" => messages}) do
    object?(context, ~w(query sources top_k)) && text?(context["query"]) &&
      byte_size(context["query"]) <= 2048 && List.last(messages)["role"] == "user" &&
      optional?(context, "sources", fn sources ->
        is_list(sources) && sources != [] && Enum.uniq(sources) == sources &&
          Enum.all?(sources, &(&1 in ~w(document memory)))
      end) &&
      optional?(context, "top_k", &integer_range?(&1, 1..10))
  end

  defp context?(_), do: true

  defp range?(value, first, last), do: is_number(value) && value >= first && value <= last
  defp integer_range?(value, range), do: is_integer(value) && value in range
  defp seed?(value), do: is_integer(value) && abs(value) < 9_223_372_036_854_775_808

  defp stops?(stop) when is_binary(stop), do: text?(stop)
  defp stops?(stop), do: is_list(stop) && length(stop) in 1..4 && Enum.all?(stop, &text?/1)
  defp text?(value), do: is_binary(value) && value != "" && String.valid?(value)
  defp name?(value), do: is_binary(value) && Regex.match?(~r/\A[a-zA-Z0-9_-]{1,64}\z/, value)
  defp optional?(map, key, validator), do: !Map.has_key?(map, key) || validator.(map[key])

  defp object?(map, keys),
    do: is_map(map) && !is_struct(map) && Enum.all?(Map.keys(map), &(&1 in keys))
end

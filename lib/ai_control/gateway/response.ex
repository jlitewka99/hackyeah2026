defmodule AiControl.Gateway.Response do
  @moduledoc "Public response allowlist; provider reasoning and arbitrary fields are discarded."
  alias AiControl.Gateway.{Request, ToolSchemas}

  def normalize(data, model, request_id) do
    with %{"choices" => [choice], "usage" => usage} <- data,
         %{"message" => %{"role" => "assistant"} = message, "finish_reason" => finish} <- choice,
         message = Map.take(message, ~w(role content tool_calls)),
         true <- Request.message?(message),
         true <- valid_text?(message["content"]),
         true <- finish in ~w(stop length tool_calls),
         true <- usage?(usage) do
      {:ok,
       %{
         "id" => "chatcmpl-#{request_id}",
         "object" => "chat.completion",
         "created" => System.system_time(:second),
         "model" => model,
         "choices" => [%{"index" => 0, "message" => message, "finish_reason" => finish}],
         "usage" => Map.take(usage, ~w(prompt_tokens completion_tokens total_tokens))
       }}
    else
      _ -> {:error, :upstream_invalid_response}
    end
  end

  def validate(response, contract) do
    with [%{"message" => message, "finish_reason" => finish}] <- response["choices"],
         true <- message["role"] == "assistant" && Request.message?(message),
         true <- valid_text?(message["content"]),
         true <- finish in ~w(stop length tool_calls),
         true <- usage?(response["usage"]),
         calls = Map.get(message, "tool_calls", []),
         true <- finish == "tool_calls" == (calls != []),
         true <- calls |> Enum.map(& &1["id"]) |> Enum.uniq() |> length() == length(calls),
         :ok <- ToolSchemas.validate_calls(calls, contract),
         do: :ok,
         else: (
           {:error, _} = error -> error
           _ -> {:error, :upstream_invalid_response}
         )
  end

  defp valid_text?(nil), do: true
  defp valid_text?(text), do: is_binary(text) && String.valid?(text)

  defp usage?(usage) when is_map(usage) do
    Enum.all?(
      ~w(prompt_tokens completion_tokens total_tokens),
      &(is_integer(usage[&1]) && usage[&1] >= 0)
    ) &&
      usage["total_tokens"] == usage["prompt_tokens"] + usage["completion_tokens"]
  end

  defp usage?(_), do: false
end

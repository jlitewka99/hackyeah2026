defmodule AiControl.Gateway.Response do
  @moduledoc "Public response allowlist; provider reasoning and arbitrary fields are discarded."
  alias AiControl.Gateway.Request

  def normalize(data, model, request_id) do
    with %{"choices" => [choice], "usage" => usage} <- data,
         %{"message" => %{"role" => "assistant"} = message, "finish_reason" => finish} <- choice,
         message = Map.take(message, ~w(role content tool_calls)),
         true <- Request.message?(message),
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

  defp usage?(usage) when is_map(usage) do
    Enum.all?(
      ~w(prompt_tokens completion_tokens total_tokens),
      &(is_integer(usage[&1]) && usage[&1] >= 0)
    ) &&
      usage["total_tokens"] == usage["prompt_tokens"] + usage["completion_tokens"]
  end

  defp usage?(_), do: false
end

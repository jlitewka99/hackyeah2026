defmodule AiControl.Guards.Granite.Ollama do
  @moduledoc "Bounded, pinned native generation without retries, redirects, or stored reasoning."
  alias AiControl.Budgets.Tokenizer
  alias AiControl.Guards.Granite.{Model, Parser}

  def ready?(config) do
    pinned?(config) and
      Tokenizer.pinned_ready?(Model.name(), Model.digest(), tokenizer_config(config))
  end

  def analyze(prompt, config, deadline) do
    with true <- pinned?(config, deadline),
         {:ok, tokens} <-
           Tokenizer.count_pinned(Model.name(), Model.digest(), prompt, tokenizer_config(config)),
         true <- tokens + 64 <= config[:granite_context_tokens],
         {:ok, response} <-
           request(
             :post,
             "/api/generate",
             %{
               model: Model.name(),
               prompt: prompt,
               raw: true,
               stream: false,
               think: false,
               options: %{
                 temperature: 0,
                 num_ctx: config[:granite_context_tokens],
                 num_predict: 64
               }
             },
             config,
             deadline
           ),
         %{
           "done" => true,
           "done_reason" => "stop",
           "response" => text,
           "prompt_eval_count" => input,
           "eval_count" => output
         } <- response,
         true <- is_integer(input) and input >= 0 and is_integer(output) and output in 1..64,
         true <- input == tokens,
         {:ok, score} <- Parser.parse(text),
         true <- pinned?(config, deadline) do
      {:ok, score,
       %{
         "prompt_tokens" => input,
         "completion_tokens" => output,
         "total_tokens" => input + output
       }}
    else
      _ -> {:error, :provider_invalid_response}
    end
  end

  defp tokenizer_config(config),
    do: Keyword.put(config, :tokenizer_url, config[:granite_tokenizer_url])

  defp pinned?(config, deadline \\ nil) do
    case request(:get, "/api/tags", nil, config, deadline) do
      {:ok, %{"models" => models}} when is_list(models) ->
        Enum.any?(models, &(&1["name"] == Model.name() and &1["digest"] == Model.digest()))

      _ ->
        false
    end
  end

  defp request(method, path, body, config, deadline) do
    remaining =
      if deadline,
        do: deadline - System.monotonic_time(:millisecond),
        else: config[:readiness_timeout]

    if remaining <= 0 do
      {:error, :provider_timeout}
    else
      options = [
        method: method,
        url: String.trim_trailing(config[:granite_url], "/") <> path,
        retry: false,
        redirect: false,
        receive_timeout: remaining,
        request_timeout: remaining,
        connect_options: [timeout: min(config[:connect_timeout], remaining)],
        into: &bounded/2
      ]

      options = if body, do: Keyword.put(options, :json, body), else: options

      options =
        if config[:granite_http_plug],
          do: Keyword.put(options, :plug, config[:granite_http_plug]),
          else: options

      case Req.request(options) do
        {:ok, %{status: 200, body: chunks, private: private}}
        when not is_map_key(private, :oversized) ->
          chunks |> Enum.reverse() |> IO.iodata_to_binary() |> Jason.decode()

        _ ->
          {:error, :provider_unavailable}
      end
    end
  rescue
    _ -> {:error, :provider_unavailable}
  end

  defp bounded({:data, chunk}, {request, response}) do
    size = Map.get(response.private, :bytes, 0) + byte_size(chunk)

    if size > 1_048_576 do
      {:halt, {request, Req.Response.put_private(response, :oversized, true)}}
    else
      chunks = if is_list(response.body), do: response.body, else: []

      {:cont,
       {request, %{Req.Response.put_private(response, :bytes, size) | body: [chunk | chunks]}}}
    end
  end
end

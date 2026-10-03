defmodule AiControl.Budgets.Tokenizer do
  @moduledoc "Private, digest-bound token counts of the actual Ollama-rendered prompt."
  alias AiControl.Gateway.{Config, Models}

  @callback count(String.t(), String.t(), keyword()) ::
              {:ok, non_neg_integer()} | {:error, atom()}
  @callback ready?(keyword()) :: boolean()
  def count(model, prompt, config) do
    with {:ok, digest} <- Models.digest(model),
         {:ok, response} <-
           request(:post, "/count", %{model: model, digest: digest, prompt: prompt}, config),
         %{"tokens" => tokens, "digest" => ^digest, "runtime" => "0.35.1"} <- response,
         true <- is_integer(tokens) && tokens >= 0 do
      {:ok, tokens}
    else
      _ -> {:error, :tokenizer_unavailable}
    end
  end

  def ready?(config) do
    case request(:get, "/ready", nil, config) do
      {:ok, %{"status" => "ready", "models" => models, "runtime" => "0.35.1"}} ->
        Enum.all?(Config.get(:models), fn {name, digest} -> models[name] == digest end)

      _ ->
        false
    end
  end

  defp request(method, path, payload, config) do
    options = [
      method: method,
      url: String.trim_trailing(config[:tokenizer_url], "/") <> path,
      retry: false,
      redirect: false,
      receive_timeout: config[:tokenizer_timeout],
      request_timeout: config[:tokenizer_timeout],
      connect_options: [timeout: config[:connect_timeout]],
      into: fn {:data, chunk}, {request, response} ->
        bytes = Map.get(response.private, :bytes, 0) + byte_size(chunk)

        if bytes > 4_096 do
          {:halt, {request, Req.Response.put_private(response, :oversized, true)}}
        else
          body = if is_list(response.body), do: response.body, else: []

          {:cont,
           {request, %{Req.Response.put_private(response, :bytes, bytes) | body: [chunk | body]}}}
        end
      end
    ]

    options = if payload, do: Keyword.put(options, :json, payload), else: options

    options =
      if config[:tokenizer_http_plug],
        do: Keyword.put(options, :plug, config[:tokenizer_http_plug]),
        else: options

    case Req.request(options) do
      {:ok, %{status: 200, private: private, body: body}}
      when not is_map_key(private, :oversized) ->
        body |> Enum.reverse() |> IO.iodata_to_binary() |> Jason.decode()

      _ ->
        {:error, :tokenizer_unavailable}
    end
  rescue
    _ -> {:error, :tokenizer_unavailable}
  end

  def ready?, do: ready?(Config.get())
end

defmodule AiControl.Gateway.Ollama do
  @moduledoc "Bounded Req transport; generation is never retried or redirected."
  @behaviour AiControl.Gateway.Provider

  alias AiControl.Security.HTTPError

  @impl true
  def models(config) do
    with {:ok, %{"models" => models}} when is_list(models) <-
           request(:get, "/api/tags", nil, config),
         true <- Enum.all?(models, &model?/1) do
      {:ok, Map.new(models, &{&1["name"], &1["digest"]})}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :upstream_invalid_response}
    end
  end

  @impl true
  def prepare(params, config) do
    params = reasoning(params, config) |> Map.put("_debug_render_only", true)

    with {:ok, %{"version" => "0.35.1"}} <- request(:get, "/api/version", nil, config),
         {:ok, %{"_debug_info" => %{"rendered_template" => prompt}}} when is_binary(prompt) <-
           request(:post, "/v1/chat/completions", params, config) do
      {:ok, prompt}
    else
      _ -> {:error, :tokenizer_unavailable}
    end
  end

  @impl true
  def chat(params, config) do
    request(:post, "/v1/chat/completions", reasoning(params, config), config)
  end

  defp reasoning(params, config) do
    case config[:ollama_reasoning_effort] do
      nil -> params
      effort -> Map.put(params, "reasoning_effort", effort)
    end
  end

  defp model?(%{"name" => name, "digest" => digest}),
    do: is_binary(name) && is_binary(digest) && Regex.match?(~r/\A[0-9a-f]{64}\z/, digest)

  defp model?(_), do: false

  defp request(method, path, params, config) do
    limit = config[:response_bytes]

    options = [
      method: method,
      url: String.trim_trailing(config[:base_url], "/") <> path,
      retry: false,
      redirect: false,
      raw: true,
      connect_options: [timeout: config[:connect_timeout]],
      receive_timeout: config[:llm_timeout],
      request_timeout: config[:llm_timeout],
      into: fn {:data, chunk}, {request, response} ->
        size = Map.get(response.private, :gateway_bytes, 0) + byte_size(chunk)

        if size > limit do
          {:halt, {request, Req.Response.put_private(response, :gateway_oversized, true)}}
        else
          response = response |> Req.Response.put_private(:gateway_bytes, size)
          chunks = if is_list(response.body), do: response.body, else: []
          {:cont, {request, %{response | body: [chunk | chunks]}}}
        end
      end
    ]

    options = if params, do: Keyword.put(options, :json, params), else: options
    # The optional plug is operator/test configuration, never an API parameter.
    options =
      if config[:http_plug], do: Keyword.put(options, :plug, config[:http_plug]), else: options

    case Req.request(options) do
      {:ok, response} -> decode(response)
      {:error, error} -> {:error, HTTPError.classify(error)}
    end
  end

  defp decode(%{private: %{gateway_oversized: true}}), do: {:error, :response_too_large}
  defp decode(%{status: status}) when status != 200, do: {:error, :upstream_rejected}

  defp decode(response) do
    body = response.body |> Enum.reverse() |> IO.iodata_to_binary()

    case Jason.decode(body) do
      {:ok, data} when is_map(data) -> {:ok, data}
      _ -> {:error, :upstream_invalid_response}
    end
  end
end

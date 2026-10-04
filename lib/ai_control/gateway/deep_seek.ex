defmodule AiControl.Gateway.DeepSeek do
  @moduledoc "Bounded Req transport; generation is never retried or redirected."
  @behaviour AiControl.Gateway.Provider

  alias AiControl.Gateway.{Request, StreamParser}
  alias AiControl.Security.HTTPError

  @impl true
  def models(config) do
    with {:ok, %{"data" => models}} when is_list(models) <-
           request(:get, "/models", nil, config),
         true <- Enum.all?(models, &model?/1) do
      {:ok, Map.new(models, &{&1["id"], &1["id"]})}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :upstream_invalid_response}
    end
  end

  @impl true
  def prepare(params, config) do
    with {:ok, params} <- Request.validate(Map.delete(params, "thinking")),
         true <- params["model"] == "deepseek-flash" do
      messages =
        Enum.map(params["messages"], fn
          %{"role" => "developer"} = message -> Map.put(message, "role", "system")
          message -> message
        end)

      prepared =
        params
        |> Map.drop(["n", "context"])
        |> Map.put("messages", messages)
        |> Map.put("thinking", %{"type" => "disabled"})
        |> Map.put_new("max_tokens", config[:default_max_tokens])

      prepared =
        if prepared["stream"],
          do: Map.put(prepared, "stream_options", %{"include_usage" => true}),
          else: Map.delete(prepared, "stream_options")

      {:ok, prepared}
    else
      _ -> {:error, :invalid_request}
    end
  end

  @impl true
  def chat(params, config) do
    with {:ok, prepared} <- prepare(Map.delete(params, "thinking"), config) do
      request(:post, "/chat/completions", prepared, config)
    end
  end

  @impl true
  def chat_stream(params, config) do
    with true <- is_binary(config[:api_key]) && config[:api_key] != "",
         {:ok, prepared} <-
           params |> Map.delete("thinking") |> Map.put("stream", true) |> prepare(config) do
      stream_request(prepared, config)
    else
      false -> {:error, :upstream_unavailable}
      error -> error
    end
  end

  defp stream_request(params, config) do
    parser = StreamParser.new(config[:response_bytes])
    on_usage = config[:on_stream_usage] || fn _ -> :ok end
    on_chunk = config[:on_stream_chunk] || fn _ -> :ok end

    options =
      transport_options(:post, "/chat/completions", params, config)
      |> Keyword.put(:into, fn {:data, chunk}, {request, response} ->
        receive_stream(chunk, {request, response}, parser, on_usage, on_chunk)
      end)

    decode_stream(Req.request(options), parser)
  end

  defp receive_stream(chunk, {request, response}, parser, on_usage, on_chunk) do
    on_chunk.(byte_size(chunk))
    state = Map.get(response.private, :stream_parser, parser)

    result =
      if response.status == 200,
        do: StreamParser.feed(state, chunk, on_usage),
        else: {:error, :upstream_rejected}

    case result do
      {:ok, next} ->
        {:cont, {request, Req.Response.put_private(response, :stream_parser, next)}}

      {:error, code} ->
        {:halt, {request, Req.Response.put_private(response, :stream_error, code)}}
    end
  end

  defp decode_stream(result, parser) do
    case result do
      {:ok, %{private: %{stream_error: code}}} ->
        {:error, code}

      {:ok, %{status: 200} = response} ->
        if Req.Response.get_header(response, "content-type")
           |> Enum.any?(&String.starts_with?(&1, "text/event-stream")),
           do: StreamParser.finish(Map.get(response.private, :stream_parser, parser)),
           else: {:error, :upstream_invalid_response}

      {:ok, _} ->
        {:error, :upstream_rejected}

      {:error, error} ->
        {:error, HTTPError.classify(error)}
    end
  end

  defp model?(%{"id" => id}), do: is_binary(id) && byte_size(id) in 1..200
  defp model?(_), do: false

  defp request(method, path, params, config) do
    if is_binary(config[:api_key]) && config[:api_key] != "",
      do: authenticated_request(method, path, params, config),
      else: {:error, :upstream_unavailable}
  end

  defp authenticated_request(method, path, params, config) do
    limit = config[:response_bytes]

    options =
      transport_options(method, path, params, config) ++
        [
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

    case Req.request(options) do
      {:ok, response} -> decode(response)
      {:error, error} -> {:error, HTTPError.classify(error)}
    end
  end

  defp transport_options(method, path, params, config) do
    options = [
      method: method,
      auth: {:bearer, config[:api_key]},
      url: String.trim_trailing(config[:base_url], "/") <> path,
      retry: false,
      redirect: false,
      raw: true,
      decode_body: false,
      connect_options: [timeout: config[:connect_timeout]],
      receive_timeout: config[:llm_timeout],
      request_timeout: config[:llm_timeout]
    ]

    options = if params, do: Keyword.put(options, :json, params), else: options
    # The optional plug is operator/test configuration, never an API parameter.
    options =
      if config[:http_plug], do: Keyword.put(options, :plug, config[:http_plug]), else: options

    options
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

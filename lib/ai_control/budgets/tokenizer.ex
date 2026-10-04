defmodule AiControl.Budgets.Tokenizer do
  @moduledoc "Private token counts of the prepared DeepSeek request using pinned V4.1 artifacts."
  alias AiControl.Gateway.Config

  @manifest Jason.decode!(File.read!("sidecar/tokenizer/models.v1.json"))
  @external_resource "sidecar/tokenizer/models.v1.json"
  @sha get_in(@manifest, ["files", Access.at(0), "sha256"])

  @callback count(String.t(), map(), keyword()) ::
              {:ok, non_neg_integer()} | {:error, atom()}
  @callback ready?(keyword()) :: boolean()
  def count(model, prepared, config) do
    with true <- model == "deepseek-flash" && prepared["model"] == model,
         {:ok, response} <- request(:post, "/count", %{model: model, request: prepared}, config),
         %{"tokens" => tokens} <- response,
         true <- artifacts?(response),
         true <- is_integer(tokens) && tokens >= 0 do
      {:ok, tokens}
    else
      _ -> {:error, :tokenizer_unavailable}
    end
  end

  def ready?(config) do
    case request(:get, "/ready", nil, config) do
      {:ok, %{"status" => "ready"} = response} -> artifacts?(response)
      _ -> false
    end
  end

  defp artifacts?(%{
         "model" => "deepseek-flash",
         "tokenizer_sha256" => @sha,
         "recipe_version" => "0.1.1",
         "encoding" => "v41"
       }), do: true

  defp artifacts?(_), do: false

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

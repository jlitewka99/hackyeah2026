defmodule AiControl.LocalSetup do
  @moduledoc "Initializes the pinned Ollama model for the local Compose environment."

  alias AiControl.Gateway.Config
  alias AiControl.Guards.Granite.Model

  @ollama_version "0.35.1"

  def prepare_model!(options \\ []) do
    {:ok, _} = Application.ensure_all_started(:req)

    request =
      Req.new(
        Keyword.merge(
          [
            base_url: Config.get(:granite_url),
            retry: false,
            redirect: false,
            receive_timeout: 10_000,
            connect_options: [timeout: 5_000]
          ],
          options
        )
      )

    case fetch!(request, "/api/version") do
      %{"version" => @ollama_version} -> :ok
      _ -> raise "Local setup requires Ollama #{@ollama_version}; check the Compose image."
    end

    expected = [{Model.name(), Model.digest()}]

    installed = catalog!(request)

    for {name, digest} <- expected do
      installed_digest =
        case Map.fetch(installed, name) do
          {:ok, existing} ->
            existing

          :error ->
            IO.puts(
              "Downloading local Ollama model #{name}; the first start may take several minutes."
            )

            pull!(request, name)
            Map.get(catalog!(request), name)
        end

      if installed_digest != digest do
        raise "Ollama model #{name} has a different digest than sidecar/tokenizer/granite.v1.json. " <>
                "Local startup stopped; do not change the pinned catalog to bypass this check."
      end
    end

    IO.puts("Local Ollama version and model digests verified.")
    :ok
  end

  defp catalog!(request) do
    case fetch!(request, "/api/tags") do
      %{"models" => models} when is_list(models) ->
        Map.new(models, fn
          %{"name" => name, "digest" => digest} when is_binary(name) and is_binary(digest) ->
            {name, digest}

          _ ->
            raise "Ollama returned an invalid model catalog."
        end)

      _ ->
        raise "Ollama returned an invalid model catalog."
    end
  end

  defp fetch!(request, path) do
    case Req.get(request, url: path) do
      {:ok, %{status: 200, body: body}} -> body
      _ -> raise "Ollama is unavailable; check ./docker/local logs."
    end
  end

  defp pull!(request, name) do
    case Req.post(request,
           url: "/api/pull",
           json: %{name: name, stream: false},
           receive_timeout: 3_600_000
         ) do
      {:ok, %{status: 200, body: %{"status" => "success"}}} ->
        :ok

      _ ->
        raise "Ollama model download failed; check the internet connection and ./docker/local logs."
    end
  end
end

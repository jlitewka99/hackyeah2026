defmodule AiControl.Gateway.OllamaTest do
  use ExUnit.Case, async: true

  import AiControl.GatewayFixtures

  alias AiControl.Gateway.{Config, Ollama}

  setup do
    %{config: Config.get() |> Keyword.put(:http_plug, {Req.Test, __MODULE__})}
  end

  test "valid JSON and tags use fixed endpoints", %{config: config} do
    Req.Test.stub(__MODULE__, fn conn ->
      case conn.request_path do
        "/api/tags" ->
          Req.Test.json(conn, %{
            models: [%{name: "qwen3.5:4b", digest: String.duplicate("a", 64)}]
          })

        "/v1/chat/completions" ->
          Req.Test.json(conn, response())
      end
    end)

    assert {:ok, %{"qwen3.5:4b" => _}} = Ollama.models(config)
    assert {:ok, %{"choices" => [_]}} = Ollama.chat(request(), config)
  end

  test "oversized success, error and redirect bodies are all bounded", %{config: config} do
    for status <- [200, 400, 302] do
      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, status, String.duplicate("s", 2_000))
      end)

      assert {:error, :response_too_large} =
               Ollama.chat(request(), Keyword.put(config, :response_bytes, 128))
    end
  end

  test "redirects and failures never retry or expose backend bodies", %{config: config} do
    test = self()

    Req.Test.stub(__MODULE__, fn conn ->
      send(test, :attempt)

      conn
      |> Plug.Conn.put_resp_header("location", "http://attacker.invalid")
      |> Plug.Conn.send_resp(302, "private secret")
    end)

    assert {:error, :upstream_rejected} = Ollama.chat(request(), config)
    assert_received :attempt
    refute_received :attempt
    Req.Test.stub(__MODULE__, &Plug.Conn.send_resp(&1, 200, "not json: private secret"))
    assert {:error, :upstream_invalid_response} = Ollama.chat(request(), config)
    Req.Test.stub(__MODULE__, fn conn -> Req.Test.transport_error(conn, :timeout) end)
    assert {:error, :upstream_timeout} = Ollama.chat(request(), config)
  end
end

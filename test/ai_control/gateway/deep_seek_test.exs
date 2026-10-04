defmodule AiControl.Gateway.DeepSeekTest do
  use ExUnit.Case, async: true

  import AiControl.GatewayFixtures

  alias AiControl.Gateway.{Config, DeepSeek}

  setup do
    %{config: Config.get() |> Keyword.put(:http_plug, {Req.Test, __MODULE__})}
  end

  test "authenticated JSON and model catalog use fixed endpoints", %{config: config} do
    Req.Test.stub(__MODULE__, fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == [
               "Bearer synthetic-deepseek-test-key"
             ]

      case conn.request_path do
        "/models" ->
          Req.Test.json(conn, %{
            data: [%{id: "deepseek-flash"}]
          })

        "/chat/completions" ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)

          assert %{"thinking" => %{"type" => "disabled"}, "max_tokens" => 1024} =
                   Jason.decode!(body)

          Req.Test.json(conn, response())
      end
    end)

    assert {:ok, %{"deepseek-flash" => _}} = DeepSeek.models(config)
    assert {:ok, %{"choices" => [_]}} = DeepSeek.chat(request(), config)
  end

  test "oversized success, error and redirect bodies are all bounded", %{config: config} do
    for status <- [200, 400, 302] do
      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, status, String.duplicate("s", 2_000))
      end)

      assert {:error, :response_too_large} =
               DeepSeek.chat(request(), Keyword.put(config, :response_bytes, 128))
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

    assert {:error, :upstream_rejected} = DeepSeek.chat(request(), config)
    assert_received :attempt
    refute_received :attempt
    Req.Test.stub(__MODULE__, &Plug.Conn.send_resp(&1, 200, "not json: private secret"))
    assert {:error, :upstream_invalid_response} = DeepSeek.chat(request(), config)
    Req.Test.stub(__MODULE__, fn conn -> Req.Test.transport_error(conn, :timeout) end)
    assert {:error, :upstream_timeout} = DeepSeek.chat(request(), config)
  end

  test "preparation preserves tools and history and maps developer role", %{config: config} do
    tool = %{
      "type" => "function",
      "function" => %{
        "name" => "lookup",
        "parameters" => %{"type" => "object", "properties" => %{}}
      }
    }

    params =
      request()
      |> Map.put("messages", [
        %{"role" => "developer", "content" => "Odpowiadaj krótko."},
        %{"role" => "user", "content" => "Sprawdź dane."},
        %{
          "role" => "assistant",
          "content" => nil,
          "tool_calls" => [
            %{
              "id" => "call_1",
              "type" => "function",
              "function" => %{"name" => "lookup", "arguments" => "{}"}
            }
          ]
        },
        %{"role" => "tool", "tool_call_id" => "call_1", "content" => "Dane"}
      ])
      |> Map.put("tools", [tool])
      |> Map.put("tool_choice", "required")
      |> Map.put("n", 1)

    assert {:ok, prepared} = DeepSeek.prepare(params, config)
    assert hd(prepared["messages"])["role"] == "system"
    assert prepared["tools"] == [tool]
    assert prepared["tool_choice"] == "required"
    refute Map.has_key?(prepared, "n")
    assert {:ok, ^prepared} = DeepSeek.prepare(prepared, config)
    assert {:ok, ^prepared} = DeepSeek.prepare(Map.delete(prepared, "thinking"), config)
    assert {:error, :invalid_request} = DeepSeek.prepare(Map.put(params, "seed", 1), config)
    assert {:error, :invalid_request} = DeepSeek.prepare(Map.put(params, "top_p", 0.5), config)
    assert {:ok, _} = DeepSeek.prepare(Map.put(params, "top_p", 1), config)
  end

  test "401, 429 and server failures are single attempts without content", %{config: config} do
    owner = self()

    for status <- [401, 429, 500, 503] do
      Req.Test.stub(__MODULE__, fn conn ->
        send(owner, {:attempt, status})
        Plug.Conn.send_resp(conn, status, "private provider error and key")
      end)

      assert {:error, :upstream_rejected} = DeepSeek.chat(request(), config)
      assert_received {:attempt, ^status}
      refute_received {:attempt, ^status}
    end

    assert {:error, :upstream_unavailable} =
             DeepSeek.chat(request(), Keyword.put(config, :api_key, nil))

    assert {:error, :upstream_unavailable} =
             DeepSeek.chat_stream(request(), Keyword.put(config, :api_key, nil))

    refute_received {:attempt, _}
  end

  test "stream terminal frame with null delta and usage settles once", %{config: config} do
    owner = self()

    config =
      Keyword.put(config, :on_stream_usage, fn usage ->
        send(owner, {:usage, usage})
        :ok
      end)

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      assert %{
               "stream" => true,
               "thinking" => %{"type" => "disabled"},
               "stream_options" => %{"include_usage" => true}
             } = Jason.decode!(body)

      conn
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.send_resp(200, stream_body())
    end)

    assert {:ok, response} = DeepSeek.chat_stream(request(), config)
    assert response["usage"]["total_tokens"] == 16
    assert_received {:usage, %{"total_tokens" => 16}}
    refute_received {:usage, _}
  end

  test "invalid usage never settles", %{config: config} do
    owner = self()

    config =
      Keyword.put(config, :on_stream_usage, fn usage ->
        send(owner, {:usage, usage})
        :ok
      end)

    bad = String.replace(stream_body(), ~s("total_tokens":16), ~s("total_tokens":99))

    Req.Test.stub(__MODULE__, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.send_resp(200, bad)
    end)

    assert {:error, :upstream_invalid_response} = DeepSeek.chat_stream(request(), config)
    refute_received {:usage, _}
  end

  test "provider filtered terminal response still reports billed usage", %{config: config} do
    owner = self()

    config =
      Keyword.put(config, :on_stream_usage, fn usage ->
        send(owner, {:usage, usage})
        :ok
      end)

    Req.Test.stub(__MODULE__, fn conn ->
      body =
        String.replace(
          stream_body(),
          ~s("finish_reason":"stop"),
          ~s("finish_reason":"content_filter")
        )

      conn
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.send_resp(200, body)
    end)

    assert {:error, :upstream_rejected} = DeepSeek.chat_stream(request(), config)
    assert_received {:usage, %{"total_tokens" => 16}}
  end
end

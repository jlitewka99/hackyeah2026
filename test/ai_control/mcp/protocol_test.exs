defmodule AiControl.MCP.ProtocolTest do
  use ExUnit.Case, async: false

  import AiControl.MCPFixtures

  alias AiControl.ApiKeys.Principal
  alias AiControl.MCP.{Config, RPC, Sessions}

  setup do
    identity = %Principal{
      organization_id: Ecto.UUID.generate(),
      agent_id: Ecto.UUID.generate(),
      api_key_id: Ecto.UUID.generate()
    }

    clock = start_supervised!({Agent, fn -> 0 end})
    name = :step13_protocol_sessions
    server = start_supervised!({Sessions, name: name, clock: fn -> Agent.get(clock, & &1) end})
    %{identity: identity, server: server, clock: clock}
  end

  test "envelopes reject null/fractional IDs, batches, responses and injected fields" do
    for value <- [
          [],
          [message("ping")],
          %{"jsonrpc" => "2.0", "id" => 1, "result" => %{}},
          message("ping", %{}, nil),
          message("ping", %{}, 1.5),
          message("ping", []),
          Map.put(message("ping"), "organization_id", Ecto.UUID.generate()),
          message("ping", %{}, String.duplicate("x", 257))
        ] do
      assert {:error, %{"error" => %{"code" => -32_600}}} = RPC.validate(value)
    end

    assert {:ok, _} = RPC.validate(message("ping", %{}, "1"))
    assert {:ok, _} = RPC.validate(message("ping", %{}, -1))
  end

  test "negotiates only the supported version, requires ready and accepts ping", c do
    {:reply, 200, body, [{"mcp-session-id", session}]} =
      AiControl.MCP.handle(
        c.identity,
        put_in(initialize_message(), ["params", "protocolVersion"], "older"),
        nil,
        sessions: c.server
      )

    assert body["result"]["protocolVersion"] == "2025-11-25"
    assert body["result"]["capabilities"] == %{"tools" => %{}, "resources" => %{}}

    assert {:reply, 200, %{"result" => %{}}, []} =
             AiControl.MCP.handle(c.identity, message("ping"), session, sessions: c.server)

    assert {:reply, 200, %{"error" => %{"data" => %{"code" => "not_initialized"}}}, []} =
             AiControl.MCP.handle(c.identity, message("tools/list"), session, sessions: c.server)

    assert {:reply, 202, nil, []} =
             AiControl.MCP.handle(
               c.identity,
               %{"jsonrpc" => "2.0", "method" => "notifications/initialized"},
               session,
               sessions: c.server
             )

    assert {:reply, 200, %{"error" => %{"code" => -32_601}}, []} =
             AiControl.MCP.handle(c.identity, message("prompts/list"), session,
               sessions: c.server
             )
  end

  test "sessions bind organization, agent and key, and deletion removes access", c do
    {:ok, session} = Sessions.create(c.identity, c.server)

    for field <- [:organization_id, :agent_id, :api_key_id] do
      other = Map.put(c.identity, field, Ecto.UUID.generate())
      assert {:error, :session_not_found} = Sessions.fetch(session, other, c.server)
      assert {:error, :session_not_found} = Sessions.ready(session, other, c.server)
      assert {:error, :session_not_found} = Sessions.delete(session, other, c.server)
    end

    assert :ok = Sessions.delete(session, c.identity, c.server)
    assert {:error, :session_not_found} = Sessions.fetch(session, c.identity, c.server)
  end

  test "idle expiration, capacity and process restart are bounded without sleeping", c do
    original = Config.get()
    on_exit(fn -> Application.put_env(:ai_control, Config, original) end)

    Application.put_env(:ai_control, Config,
      idle_timeout_ms: 100,
      max_agent_sessions: 1,
      max_sessions: 2
    )

    {:ok, session} = Sessions.create(c.identity, c.server)
    assert {:error, :session_capacity} = Sessions.create(c.identity, c.server)
    other = %{c.identity | agent_id: Ecto.UUID.generate()}
    assert {:ok, _} = Sessions.create(other, c.server)

    assert {:error, :session_capacity} =
             Sessions.create(%{other | agent_id: Ecto.UUID.generate()}, c.server)

    Agent.update(c.clock, fn _ -> 100 end)
    assert {:error, :session_not_found} = Sessions.fetch(session, c.identity, c.server)
    {:ok, new} = Sessions.create(c.identity, c.server)
    ref = Process.monitor(c.server)
    stop_supervised!(Sessions)
    assert_receive {:DOWN, ^ref, :process, _, :shutdown}
    start_supervised!({Sessions, name: :step13_protocol_sessions})
    replacement = :sys.get_state(:step13_protocol_sessions)
    assert replacement.sessions == %{}

    assert {:error, :session_not_found} =
             Sessions.fetch(new, c.identity, :step13_protocol_sessions)
  end

  test "UUID idempotency separates sessions and typed IDs" do
    key = AiControl.MCP.idempotency_key("session-a", 1)
    assert {:ok, ^key} = Ecto.UUID.cast(key)
    assert key == AiControl.MCP.idempotency_key("session-a", 1)
    refute key == AiControl.MCP.idempotency_key("session-a", "1")
    refute key == AiControl.MCP.idempotency_key("session-b", 1)
  end

  test "operator origins and limits validate at startup" do
    original = Config.get()
    on_exit(fn -> Application.put_env(:ai_control, Config, original) end)

    for value <- [
          [max_sessions: 0],
          [idle_timeout_ms: -1],
          [allowed_origins: ["*"]],
          [allowed_origins: ["null"]],
          [allowed_origins: ["https://good.example/path"]]
        ] do
      Application.put_env(:ai_control, Config, value)
      assert_raise ArgumentError, fn -> Config.validate!() end
    end

    Application.put_env(:ai_control, Config,
      allowed_origins: ["https://client.example", "http://localhost:4000"]
    )

    assert :ok = Config.validate!()
  end
end

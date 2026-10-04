defmodule AiControlWeb.MCPControllerTest do
  use AiControlWeb.ConnCase, async: false

  import AiControl.MCPFixtures
  import AiControl.ToolsFixtures

  alias AiControl.{ApiKeys, MCP, Repo}
  alias AiControl.ApiKeys.ApiKey
  alias AiControl.MCP.Config
  alias AiControl.Tools.{Discovery, Execution}
  alias AiControlWeb.MCPTransport

  setup do
    tool_fixture()
  end

  test "handshake, discovery, tool execution and resource read use standard MCP headers", c do
    session = initialize(c)

    assert request(c, session, message("ping")) |> json_response(200) ==
             %{"jsonrpc" => "2.0", "id" => 1, "result" => %{}}

    tools = request(c, session, message("tools/list", %{}, "list")) |> json_response(200)

    assert Enum.find(tools["result"]["tools"], &(&1["name"] == "file.read"))["inputSchema"][
             "additionalProperties"
           ] == false

    conn = request(c, session, tool_message("file.read", %{"path" => "report.txt"}))
    result = json_response(conn, 200)
    assert result["result"]["structuredContent"] == %{"content" => "Zażółć gęślą jaźń"}

    assert Jason.decode!(hd(result["result"]["content"])["text"]) ==
             result["result"]["structuredContent"]

    assert get_resp_header(conn, "cache-control") == ["no-store"]

    resource =
      request(c, session, message("resources/read", %{"uri" => Discovery.uri("report.txt")}, 3))
      |> json_response(200)

    assert hd(resource["result"]["contents"])["text"] == "Zażółć gęślą jaźń"
    assert Repo.aggregate(Execution, :count) == 2
    assert Enum.sum(Enum.map(Repo.all(AiControl.Budgets.Workflow), & &1.calls)) == 2

    assert request(c, session, message("resources/templates/list", %{}, 4))
           |> json_response(200)
           |> get_in(["result", "resourceTemplates"]) == []
  end

  test "authentication and origin validation happen before malformed bodies", c do
    assert build_conn()
           |> put_req_header("content-type", "application/json")
           |> post("/mcp", "not-json")
           |> json_response(401)

    for origin <- ["null", "https://evil.example", "http://localhost:4000/", "*"] do
      response = agent_conn(c) |> put_req_header("origin", origin) |> post("/mcp", "not-json")
      assert json_response(response, 403)["error"]["code"] == "invalid_origin"
    end

    for origin <- [Config.public_origin()] do
      conn =
        agent_conn(c)
        |> put_req_header("origin", origin)
        |> post("/mcp", Jason.encode!(initialize_message()))

      assert json_response(conn, 200)["result"]["protocolVersion"] == MCP.version()
    end

    assert Repo.aggregate(Execution, :count) == 0
  end

  test "validates version, body size, content negotiation and JSON-RPC envelopes", c do
    assert agent_conn(c)
           |> put_req_header("mcp-protocol-version", "2025-03-26")
           |> post("/mcp", "not-json")
           |> json_response(400)
           |> get_in(["error", "code"]) == "unsupported_version"

    assert agent_conn(c)
           |> put_req_header("content-type", "text/plain")
           |> post("/mcp", "not-json")
           |> json_response(415)

    assert agent_conn(c)
           |> put_req_header("accept", "application/json, text/event-stream;q=0")
           |> post("/mcp", "not-json")
           |> json_response(406)

    for {body, status, code} <- [
          {"not-json", 400, -32_700},
          {"[]", 400, -32_600},
          {Jason.encode!(message("ping", %{}, nil)), 400, -32_600}
        ] do
      response = agent_conn(c) |> post("/mcp", body) |> json_response(status)
      assert response["error"]["code"] == code
    end

    assert agent_conn(c)
           |> post("/mcp", String.duplicate("x", 65_537))
           |> json_response(413)
           |> get_in(["error", "code"]) == "input_too_large"
  end

  test "missing, foreign and deleted sessions follow transport status codes", c do
    assert request(c, nil, message("tools/list"))
           |> json_response(400)
           |> get_in(["error", "code"]) == "session_required"

    session = initialize(c)
    other = tool_fixture()
    assert request(other, session, message("tools/list")) |> json_response(404)
    {_, other_token} = AiControl.AgentsFixtures.key_fixture(c.scope, c.agent)

    assert request(%{c | token: other_token}, session, message("tools/list"))
           |> json_response(404)

    conn = agent_conn(c, session) |> delete("/mcp")
    assert response(conn, 204) == ""
    assert request(c, session, message("ping")) |> json_response(404)
  end

  test "revoked keys and suspended agents cannot reuse an initialized session", c do
    session = initialize(c)
    assert {:ok, _} = ApiKeys.revoke_key(c.scope, c.principal.api_key_id)
    assert request(c, session, message("ping")) |> json_response(401)
    {_, token} = AiControl.AgentsFixtures.key_fixture(c.scope, c.agent)
    fresh = %{c | token: token}
    session = initialize(fresh)
    assert {:ok, _} = AiControl.Agents.set_status(c.scope, c.agent.id, :suspended)
    assert request(fresh, session, message("tools/list")) |> json_response(401)
  end

  test "GET does not offer SSE and notifications have no JSON-RPC response", c do
    session = initialize(c)
    conn = agent_conn(c, session) |> get("/mcp")
    assert conn.status == 405
    assert get_resp_header(conn, "allow") == ["POST, DELETE"]

    conn =
      request(c, session, %{
        "jsonrpc" => "2.0",
        "method" => "notifications/cancelled",
        "params" => %{"requestId" => 50}
      })

    assert response(conn, 202) == ""
    assert get_resp_header(conn, "content-type") == []

    assert request(c, session, message("notifications/initialized"))
           |> json_response(200)
           |> get_in(["error", "code"]) == -32_601
  end

  test "the negotiated session supplies an omitted protocol header", c do
    session = initialize(c)

    conn =
      agent_conn(c, session)
      |> delete_req_header("mcp-protocol-version")
      |> post("/mcp", Jason.encode!(message("ping")))

    assert json_response(conn, 200)["result"] == %{}
  end

  test "repeated security headers are rejected and explicit extra origins are supported", c do
    original = Config.get()
    on_exit(fn -> Application.put_env(:ai_control, Config, original) end)

    Application.put_env(
      :ai_control,
      Config,
      Keyword.put(original, :allowed_origins, ["https://client.example"])
    )

    conn = agent_conn(c) |> put_req_header("origin", "https://client.example")
    assert conn |> post("/mcp", Jason.encode!(initialize_message())) |> json_response(200)

    for {header, value, status} <- [
          {"origin", Config.public_origin(), 403},
          {"mcp-protocol-version", MCP.version(), 400},
          {"mcp-session-id", "opaque-session", 400}
        ] do
      conn = agent_conn(c)

      conn = %{
        conn
        | req_headers: [
            {header, value},
            {header, value} | List.keydelete(conn.req_headers, header, 0)
          ]
      }

      assert conn |> post("/mcp", "malformed") |> json_response(status)
    end
  end

  test "rotating and expiring keys stop a previously initialized session", c do
    session = initialize(c)

    assert {:ok, {_key, token}} =
             ApiKeys.rotate_key(c.scope, c.principal.api_key_id, %{label: "Replacement"})

    assert request(c, session, message("ping")) |> json_response(401)
    fresh = %{c | token: token}
    assert request(fresh, session, message("ping")) |> json_response(404)
    fresh_session = initialize(fresh)
    {:ok, principal} = ApiKeys.authenticate(token)
    key = Repo.get!(ApiKey, principal.api_key_id)

    Repo.update!(
      Ecto.Changeset.change(key, expires_at: DateTime.add(DateTime.utc_now(:second), -1))
    )

    assert request(fresh, fresh_session, message("ping")) |> json_response(401)
  end

  test "encoded oversized responses withhold content and preserve the RPC identifier" do
    body = %{
      "jsonrpc" => "2.0",
      "id" => "bounded",
      "result" => %{"content" => String.duplicate("x", 262_144)}
    }

    conn = MCPTransport.respond(build_conn(), 200, body)
    response = json_response(conn, 500)
    assert response["id"] == "bounded"
    assert response["error"]["data"]["code"] == "response_too_large"
    refute Map.has_key?(response, "result")
    assert byte_size(conn.resp_body) < 1_024
  end

  test "rate limiting rejects malformed input before parsing", c do
    alias AiControl.Gateway.Config, as: GatewayConfig

    original = GatewayConfig.get()
    on_exit(fn -> Application.put_env(:ai_control, GatewayConfig, original) end)

    Application.put_env(
      :ai_control,
      GatewayConfig,
      Keyword.put(original, :requests_per_minute, 1)
    )

    assert agent_conn(c) |> post("/mcp", "invalid") |> json_response(400)
    assert agent_conn(c) |> post("/mcp", "invalid") |> json_response(429)
    assert Repo.aggregate(Execution, :count) == 0
  end
end

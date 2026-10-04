defmodule AiControl.MCPFixtures do
  @moduledoc false
  import Phoenix.ConnTest
  import Plug.Conn

  @endpoint AiControlWeb.Endpoint

  def message(method, params \\ %{}, id \\ 1),
    do: %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}

  def initialize_message do
    message("initialize", %{
      "protocolVersion" => "2025-11-25",
      "capabilities" => %{},
      "clientInfo" => %{"name" => "step13-test", "version" => "1.0"}
    })
  end

  def agent_conn(context, session \\ nil) do
    <<a, b, _::binary>> = :crypto.hash(:sha256, context.token)
    conn = %{build_conn() | remote_ip: {198, 51, a, b}}

    conn =
      conn
      |> put_req_header("authorization", "Bearer " <> context.token)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", "application/json, text/event-stream")
      |> put_req_header("mcp-protocol-version", "2025-11-25")

    if session, do: put_req_header(conn, "mcp-session-id", session), else: conn
  end

  def request(context, session, message),
    do: post(agent_conn(context, session), "/mcp", Jason.encode!(message))

  def initialize(context) do
    conn = request(context, nil, initialize_message())
    %{"result" => %{"protocolVersion" => "2025-11-25"}} = json_response(conn, 200)
    [session] = get_resp_header(conn, "mcp-session-id")
    notification = %{"jsonrpc" => "2.0", "method" => "notifications/initialized"}
    202 = request(context, session, notification).status
    session
  end

  def tool_message(tool, args, id \\ 2),
    do: message("tools/call", %{"name" => tool, "arguments" => args}, id)
end

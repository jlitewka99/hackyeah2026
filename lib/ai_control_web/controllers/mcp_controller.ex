defmodule AiControlWeb.MCPController do
  use AiControlWeb, :controller

  alias AiControl.MCP
  alias AiControlWeb.MCPTransport

  def create(conn, _) do
    {:reply, status, body, headers} =
      MCP.handle(conn.assigns.api_principal, conn.body_params, conn.assigns.mcp_session,
        request_id: conn.assigns.request_id,
        ingress_checked?: true
      )

    conn =
      Enum.reduce(headers, conn, fn {key, value}, conn -> put_resp_header(conn, key, value) end)

    if is_nil(body),
      do: send_resp(conn, status, ""),
      else: MCPTransport.respond(conn, status, body)
  end
end

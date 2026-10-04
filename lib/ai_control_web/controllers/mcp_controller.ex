defmodule AiControlWeb.MCPController do
  use AiControlWeb, :controller

  alias AiControl.MCP
  alias AiControl.MCP.RPC
  alias AiControlWeb.{ApprovalContext, MCPTransport, RunContext}

  def create(conn, _) do
    case {RunContext.parse(conn), ApprovalContext.parse(conn)} do
      {{:ok, context}, {:ok, opts}} -> create_with_context(conn, context, opts)
      {{:error, code}, _} -> MCPTransport.respond(conn, 400, RPC.transport(code))
      {_, {:error, code}} -> MCPTransport.respond(conn, 400, RPC.transport(code))
    end
  end

  defp create_with_context(conn, context, opts) do
    {:reply, status, body, headers} =
      MCP.handle(conn.assigns.api_principal, conn.body_params, conn.assigns.mcp_session,
        approval_id: opts[:approval_id],
        request_id: conn.assigns.request_id,
        run_context: context,
        ingress_checked?: true
      )

    conn =
      Enum.reduce(headers, conn, fn {key, value}, conn -> put_resp_header(conn, key, value) end)

    if is_nil(body),
      do: send_resp(conn, status, ""),
      else: MCPTransport.respond(conn, status, body)
  end
end

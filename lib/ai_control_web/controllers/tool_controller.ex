defmodule AiControlWeb.ToolController do
  use AiControlWeb, :controller

  alias AiControl.Tools
  alias AiControlWeb.{ApprovalContext, GatewayError, RunContext}

  def create(conn, _params) do
    key =
      case get_req_header(conn, "idempotency-key") do
        [value] -> value
        _ -> nil
      end

    case {RunContext.parse(conn), ApprovalContext.parse(conn)} do
      {{:ok, context}, {:ok, approval_opts}} ->
        case Tools.execute(conn.assigns.api_principal, conn.body_params,
               approval_id: approval_opts[:approval_id],
               request_id: conn.assigns.request_id,
               idempotency_key: key,
               run_context: context,
               ingress_checked?: conn.assigns[:gateway_ingress_checked] == true
             ) do
          {:ok, data} -> conn |> put_resp_header("cache-control", "no-store") |> json(data)
          error -> GatewayError.respond(conn, error)
        end

      _ ->
        RunContext.reject(conn, "runs")
    end
  end
end

defmodule AiControlWeb.ToolController do
  use AiControlWeb, :controller

  alias AiControl.Tools
  alias AiControlWeb.GatewayError

  def create(conn, _params) do
    key =
      case get_req_header(conn, "idempotency-key") do
        [value] -> value
        _ -> nil
      end

    case Tools.execute(conn.assigns.api_principal, conn.body_params,
           request_id: conn.assigns.request_id,
           idempotency_key: key,
           ingress_checked?: conn.assigns[:gateway_ingress_checked] == true
         ) do
      {:ok, data} -> conn |> put_resp_header("cache-control", "no-store") |> json(data)
      error -> GatewayError.respond(conn, error)
    end
  end
end

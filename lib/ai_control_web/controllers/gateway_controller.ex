defmodule AiControlWeb.GatewayController do
  use AiControlWeb, :controller

  alias AiControl.Gateway
  alias AiControlWeb.GatewayError

  def chat(conn, _params) do
    Gateway.chat(conn.assigns.api_principal, conn.body_params,
      request_id: conn.assigns.request_id,
      ingress_checked?: conn.assigns[:gateway_ingress_checked] == true
    )
    |> respond(conn)
  end

  def models(conn, _params) do
    Gateway.models(conn.assigns.api_principal, request_id: conn.assigns.request_id)
    |> respond(conn)
  end

  defp respond({:ok, data}, conn), do: json(conn, data)
  defp respond(error, conn), do: GatewayError.respond(conn, error)
end

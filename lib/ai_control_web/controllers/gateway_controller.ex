defmodule AiControlWeb.GatewayController do
  use AiControlWeb, :controller

  alias AiControl.Gateway
  alias AiControlWeb.GatewayError

  def chat(conn, _params) do
    opts = [
      request_id: conn.assigns.request_id,
      ingress_checked?: conn.assigns[:gateway_ingress_checked] == true
    ]

    if conn.body_params["stream"] == true do
      case Gateway.start_stream(conn.assigns.api_principal, conn.body_params, opts) do
        {:ok, pid} ->
          AiControlWeb.StreamResponse.send(
            conn,
            pid,
            get_in(conn.body_params, ["stream_options", "include_usage"]) == true
          )

        error ->
          respond(error, conn)
      end
    else
      Gateway.chat(conn.assigns.api_principal, conn.body_params, opts) |> respond(conn)
    end
  end

  def models(conn, _params) do
    Gateway.models(conn.assigns.api_principal, request_id: conn.assigns.request_id)
    |> respond(conn)
  end

  defp respond({:ok, data}, conn), do: json(conn, data)
  defp respond(error, conn), do: GatewayError.respond(conn, error)
end

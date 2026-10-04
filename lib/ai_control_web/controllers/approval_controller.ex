defmodule AiControlWeb.ApprovalController do
  use AiControlWeb, :controller

  def show(conn, %{"id" => id}) do
    case AiControl.Approvals.status(conn.assigns.api_principal, id) do
      {:ok, evidence} -> conn |> put_resp_header("cache-control", "no-store") |> json(evidence)
      error -> AiControlWeb.GatewayError.respond(conn, error)
    end
  end
end

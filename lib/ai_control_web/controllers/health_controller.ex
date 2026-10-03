defmodule AiControlWeb.HealthController do
  use AiControlWeb, :controller

  alias AiControl.Gateway.Readiness

  def health(conn, _), do: json(conn, %{status: "ok"})

  def ready(conn, _) do
    case Readiness.check() do
      :ok -> json(conn, %{status: "ready"})
      _ -> conn |> put_status(503) |> json(%{status: "not_ready"})
    end
  end
end

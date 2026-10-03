defmodule AiControlWeb.ApiAuthController do
  use AiControlWeb, :controller

  def show(conn, _params), do: json(conn, Map.from_struct(conn.assigns.api_principal))
end

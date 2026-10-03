defmodule AiControlWeb.PageController do
  use AiControlWeb, :controller

  def home(conn, _params) do
    if conn.assigns.current_scope do
      redirect(conn, to: AiControlWeb.UserAuth.signed_in_path(conn))
    else
      redirect(conn, to: ~p"/users/log-in")
    end
  end
end

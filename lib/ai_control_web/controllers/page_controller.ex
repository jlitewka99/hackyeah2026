defmodule AiControlWeb.PageController do
  use AiControlWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end

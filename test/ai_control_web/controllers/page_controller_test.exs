defmodule AiControlWeb.PageControllerTest do
  use AiControlWeb.ConnCase, async: true

  test "home leads anonymous visitors to sign in", %{conn: conn} do
    assert conn |> get(~p"/") |> redirected_to() == ~p"/users/log-in"
  end
end

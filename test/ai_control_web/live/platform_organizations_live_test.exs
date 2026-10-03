defmodule AiControlWeb.PlatformOrganizationsLiveTest do
  use AiControlWeb.ConnCase, async: false

  import AiControl.AccountsFixtures
  import Phoenix.LiveViewTest

  alias AiControl.Accounts
  alias AiControlWeb.UserAuth

  test "anonymous users cannot open the panel", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/users/log-in"}}} = live(conn, ~p"/platform/organizations")
  end

  test "ordinary accounts are forbidden by the HTTP gate", %{conn: conn} do
    conn = conn |> log_in_user(user_fixture()) |> get(~p"/platform/organizations")
    assert html_response(conn, 403)
  end

  test "organizer reaches the workspace, settings and logout", %{conn: conn} do
    {:ok, {user, :created}} =
      Accounts.bootstrap_organizer(unique_user_email(), valid_user_password())

    conn = log_in_user(conn, user)
    {:ok, view, _} = live(conn, ~p"/platform/organizations")
    assert has_element?(view, "#organizer-panel")
    assert has_element?(view, "#organizations-unavailable")
    assert has_element?(view, "#desktop-navigation a[aria-current=page]")
    assert has_element?(view, "#desktop-log-out[data-method=delete]")

    assert {:ok, settings, _} =
             view
             |> element("#panel-account-settings")
             |> render_click()
             |> follow_redirect(conn, ~p"/users/settings")

    assert has_element?(settings, "#email_form")
  end

  test "LiveView hook independently rejects a non-organizer", %{conn: conn} do
    conn = log_in_user(conn, user_fixture())

    socket = %Phoenix.LiveView.Socket{
      endpoint: AiControlWeb.Endpoint,
      assigns: %{__changed__: %{}, flash: %{}}
    }

    assert {:halt, socket} = UserAuth.on_mount(:require_organizer, %{}, get_session(conn), socket)
    assert {:redirect, %{to: "/users/settings"}} = socket.redirected
  end

  test "revoked sessions no longer open the workspace", %{conn: conn} do
    {:ok, {user, :created}} =
      Accounts.bootstrap_organizer(unique_user_email(), valid_user_password())

    conn = log_in_user(conn, user)
    Accounts.delete_user_session_token(get_session(conn, :user_token))
    assert {:error, {:redirect, %{to: "/users/log-in"}}} = live(conn, ~p"/platform/organizations")
  end
end

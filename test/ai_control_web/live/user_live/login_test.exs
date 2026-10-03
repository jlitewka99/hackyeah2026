defmodule AiControlWeb.UserLoginLiveTest do
  use AiControlWeb.ConnCase, async: false

  import AiControl.AccountsFixtures
  import Phoenix.LiveViewTest

  test "offers one password form and a separate recovery task", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/users/log-in")
    assert has_element?(view, "#login_form_password")
    assert has_element?(view, "#login-email[type=email]")
    assert has_element?(view, "#login-password[autocomplete=current-password]")
    assert has_element?(view, "#login-remember-me[type=checkbox]")
    assert has_element?(view, "#sign-in-button")
    refute has_element?(view, "a[href='/users/register']")

    assert {:ok, recovery, _} =
             view
             |> element("#recover-access-link")
             |> render_click()
             |> follow_redirect(conn, ~p"/users/recover")

    assert has_element?(recovery, "#recovery-form")
  end

  test "submits the organizer credentials through the HTTP session endpoint", %{conn: conn} do
    {:ok, {user, :created}} =
      AiControl.Accounts.bootstrap_organizer(unique_user_email(), valid_user_password())

    {:ok, view, _} = live(conn, ~p"/users/log-in")

    conn =
      view
      |> form("#login_form_password",
        user: %{email: user.email, password: valid_user_password(), remember_me: true}
      )
      |> submit_form(conn)

    assert redirected_to(conn) == ~p"/platform/organizations"
    assert get_session(conn, :user_token)
  end

  test "re-authentication identifies the account and preserves password entry", %{conn: conn} do
    user = user_fixture()
    {:ok, view, _} = live(log_in_user(conn, user), ~p"/users/log-in")
    assert has_element?(view, "#login-email[readonly][value='#{user.email}']")
    assert has_element?(view, "#login-password")
  end
end

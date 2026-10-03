defmodule AiControlWeb.UserSettingsLiveTest do
  use AiControlWeb.ConnCase, async: true

  import AiControl.AccountsFixtures
  import Phoenix.LiveViewTest
  import Swoosh.TestAssertions

  alias AiControl.Accounts
  alias AiControl.Accounts.UserToken
  alias AiControl.Repo

  test "shows both settings forms after recent authentication", %{conn: conn} do
    {:ok, view, _} = live(log_in_user(conn, user_fixture()), ~p"/users/settings")
    assert has_element?(view, "#email_form")
    assert has_element?(view, "#password_form")
    assert has_element?(view, "#change-email-button")
    assert has_element?(view, "#save-password-button")
  end

  test "anonymous and stale sessions require authentication", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/users/log-in"}}} = live(conn, ~p"/users/settings")

    conn =
      log_in_user(conn, user_fixture(),
        token_authenticated_at: DateTime.add(DateTime.utc_now(:second), -11, :minute)
      )

    assert {:error, {:redirect, %{to: "/users/log-in"}}} = live(conn, ~p"/users/settings")
  end

  test "validates email and sends its confirmation without changing the account yet", %{
    conn: conn
  } do
    user = user_fixture()
    {:ok, view, _} = live(log_in_user(conn, user), ~p"/users/settings")
    form(view, "#email_form", user: %{email: "with spaces"}) |> render_change()
    assert has_element?(view, "#email_form [role=alert]")
    email = unique_user_email()
    form(view, "#email_form", user: %{email: email}) |> render_submit()
    assert has_element?(view, "#flash-info")
    assert Accounts.get_user!(user.id).email == user.email
  end

  test "password errors are shown and a valid update revokes all old sessions", %{conn: conn} do
    user = user_fixture() |> set_password()
    other_token = Accounts.generate_user_session_token(user)
    conn = log_in_user(conn, user)
    {:ok, view, _} = live(conn, ~p"/users/settings")

    form(view, "#password_form", user: %{password: "short", password_confirmation: "mismatch"})
    |> render_submit()

    assert has_element?(view, "#password_form [role=alert]")
    password = "a replacement password"

    form =
      form(view, "#password_form", user: %{password: password, password_confirmation: password})

    render_submit(form)
    updated = follow_trigger_action(form, conn)
    assert redirected_to(updated) == ~p"/users/settings"
    assert get_session(updated, :user_token) != get_session(conn, :user_token)
    refute Accounts.get_user_by_session_token(other_token)
    refute Accounts.get_user_by_session_token(get_session(conn, :user_token))
    assert Accounts.get_user_by_email_and_password(user.email, password)
  end

  test "email confirmation is single use", %{conn: conn} do
    user = user_fixture()
    email = unique_user_email()

    token =
      extract_user_token(fn url ->
        Accounts.deliver_user_update_email_instructions(%{user | email: email}, user.email, url)
      end)

    conn = log_in_user(conn, user)

    assert {:error, {:live_redirect, %{to: "/users/settings", flash: %{"info" => _}}}} =
             live(conn, ~p"/users/settings/confirm-email/#{token}")

    assert Accounts.get_user!(user.id).email == email

    assert {:error, {:live_redirect, %{to: "/users/settings", flash: %{"error" => _}}}} =
             live(conn, ~p"/users/settings/confirm-email/#{token}")
  end

  for minutes <- [11, 21] do
    @minutes minutes

    test "email submission redirects after #{@minutes} minutes without sending instructions", %{
      conn: conn
    } do
      user = user_fixture()
      assert_email_sent()
      {:ok, view, _} = live(log_in_user(conn, user), ~p"/users/settings")
      expire_authentication(view, @minutes)

      assert {:error, {:live_redirect, %{to: "/users/log-in"}}} =
               view
               |> form("#email_form", user: %{email: unique_user_email()})
               |> render_submit()

      assert %{"error" => "You must re-authenticate to access this page."} =
               assert_redirect(view, ~p"/users/log-in")

      assert_no_email_sent()
      assert Repo.get!(Accounts.User, user.id).email == user.email
      refute Repo.get_by(UserToken, user_id: user.id, context: "change:#{user.email}")
    end

    test "password submission redirects after #{@minutes} minutes without changing credentials",
         %{conn: conn} do
      user = user_fixture() |> set_password()
      conn = log_in_user(conn, user)
      token = get_session(conn, :user_token)
      {:ok, view, _} = live(conn, ~p"/users/settings")
      expire_authentication(view, @minutes)

      assert {:error, {:live_redirect, %{to: "/users/log-in"}}} =
               view
               |> form("#password_form",
                 user: %{
                   password: "a replacement password",
                   password_confirmation: "a replacement password"
                 }
               )
               |> render_submit()

      assert %{"error" => "You must re-authenticate to access this page."} =
               assert_redirect(view, ~p"/users/log-in")

      assert Repo.get!(Accounts.User, user.id).hashed_password == user.hashed_password
      assert Accounts.get_user_by_session_token(token)
    end
  end

  defp expire_authentication(view, minutes) do
    :sys.replace_state(view.pid, fn state ->
      scope = state.socket.assigns.current_scope

      user = %{
        scope.user
        | authenticated_at: DateTime.add(DateTime.utc_now(:second), -minutes, :minute)
      }

      socket = Phoenix.Component.assign(state.socket, :current_scope, %{scope | user: user})
      %{state | socket: socket}
    end)
  end
end

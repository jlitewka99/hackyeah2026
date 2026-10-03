defmodule AiControlWeb.UserConfirmationLiveTest do
  use AiControlWeb.ConnCase, async: true

  import AiControl.AccountsFixtures
  import Phoenix.LiveViewTest

  alias AiControl.Accounts

  test "recovery link renders a confirmation form and can be used once", %{conn: conn} do
    user = user_fixture()
    {token, _} = generate_user_magic_link_token(user)
    {:ok, view, _} = live(conn, ~p"/users/log-in/#{token}")
    assert has_element?(view, "#restore-access-button")
    conn = view |> form("#recovery-confirmation-form") |> submit_form(conn)
    assert redirected_to(conn) == ~p"/users/settings"
    assert get_session(conn, :user_token)
    assert Accounts.get_user!(user.id).confirmed_at == user.confirmed_at

    assert {:error, {:live_redirect, %{to: "/users/log-in"}}} =
             live(build_conn(), ~p"/users/log-in/#{token}")
  end

  test "expired and malformed tokens return to sign in", %{conn: conn} do
    import Ecto.Query

    {token, _} = generate_user_magic_link_token(user_fixture())

    AiControl.Repo.update_all(from(t in Accounts.UserToken, where: t.context == "login"),
      set: [inserted_at: DateTime.add(DateTime.utc_now(:second), -16, :minute)]
    )

    assert {:error, {:live_redirect, %{to: "/users/log-in"}}} =
             live(conn, ~p"/users/log-in/#{token}")

    assert {:error, {:live_redirect, %{to: "/users/log-in"}}} =
             live(conn, ~p"/users/log-in/invalid")
  end
end

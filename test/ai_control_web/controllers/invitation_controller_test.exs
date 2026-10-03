defmodule AiControlWeb.InvitationControllerTest do
  use AiControlWeb.ConnCase, async: true

  import AiControl.AccountsFixtures
  import AiControl.OrganizationsFixtures
  import Phoenix.LiveViewTest

  alias AiControl.Accounts
  alias AiControl.Organizations.Invitations

  test "opening a link does not create an account and submitting activates and signs in", %{
    conn: conn
  } do
    organization = organization_fixture()
    {invitation, token} = invitation_fixture(organization)
    {:ok, view, _} = live(conn, ~p"/invitations/#{token}")
    assert has_element?(view, "#invitation-accept-form")
    refute Accounts.get_user_by_email(invitation.email)

    conn =
      post(conn, ~p"/invitations/accept",
        user: %{
          token: token,
          password: valid_user_password(),
          password_confirmation: valid_user_password()
        }
      )

    assert redirected_to(conn) == ~p"/organizations/#{organization.organization.id}"
    assert get_session(conn, :user_token)
    assert invitation_for(invitation.id).accepted_at
  end

  test "password confirmation is required and a failed activation is rolled back", %{conn: conn} do
    organization = organization_fixture()
    {invitation, token} = invitation_fixture(organization)

    conn =
      post(conn, ~p"/invitations/accept", user: %{token: token, password: valid_user_password()})

    assert redirected_to(conn) == ~p"/invitations/#{token}"
    refute Accounts.get_user_by_email(invitation.email)
    refute invitation_for(invitation.id).accepted_at
  end

  test "existing account continues through login and preserves its password", %{conn: conn} do
    organization = organization_fixture()
    user = user_fixture() |> set_password()
    {_, token} = invitation_fixture(organization, %{email: user.email})
    {:ok, view, _} = live(conn, ~p"/invitations/#{token}")
    assert has_element?(view, "#invitation-login")
    conn = get(conn, ~p"/invitations/#{token}/sign-in")
    assert get_session(conn, :user_return_to) == ~p"/invitations/#{token}"

    conn =
      conn
      |> recycle()
      |> post(~p"/users/log-in", user: %{email: user.email, password: valid_user_password()})

    assert redirected_to(conn) == ~p"/invitations/#{token}"
    conn = conn |> recycle() |> post(~p"/invitations/accept", user: %{token: token})
    assert redirected_to(conn) == ~p"/organizations/#{organization.organization.id}"
    assert Accounts.get_user!(user.id).hashed_password == user.hashed_password
  end

  test "a different signed-in account cannot consume an invitation", %{conn: conn} do
    organization = organization_fixture()
    {invitation, token} = invitation_fixture(organization)
    conn = log_in_user(conn, user_fixture())
    {:ok, view, _} = live(conn, ~p"/invitations/#{token}")
    assert has_element?(view, "#invitation-wrong-account")

    conn =
      post(conn, ~p"/invitations/accept", user: %{token: token, password: valid_user_password()})

    assert redirected_to(conn) == ~p"/invitations/#{token}"
    refute invitation_for(invitation.id).accepted_at
  end

  test "invitation acceptance rejects missing CSRF tokens", %{conn: conn} do
    organization = organization_fixture()
    {_, token} = invitation_fixture(organization)
    conn = Plug.Conn.put_private(conn, :plug_skip_csrf_protection, false)

    assert_raise Plug.CSRFProtection.InvalidCSRFTokenError, fn ->
      post(conn, ~p"/invitations/accept", user: %{token: token})
    end
  end

  test "expired and malformed invitations have a safe failure", %{conn: conn} do
    organization = organization_fixture()
    {invitation, token} = invitation_fixture(organization)
    expire_invitation(invitation)

    assert {:error, {:live_redirect, %{to: "/users/log-in"}}} =
             live(conn, ~p"/invitations/#{token}")

    assert {:error, :invalid_invitation} = Invitations.preview(token)
    assert AiControlWeb.RequestLog.level(%{path_info: ["invitations", token]}) == false
  end
end

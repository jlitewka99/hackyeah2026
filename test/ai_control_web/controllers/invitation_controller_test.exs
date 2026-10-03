defmodule AiControlWeb.InvitationControllerTest do
  use AiControlWeb.ConnCase, async: true

  import AiControl.AccountsFixtures
  import AiControl.OrganizationsFixtures
  import Ecto.Query
  import Phoenix.LiveViewTest

  alias AiControl.Accounts
  alias AiControl.Accounts.{Scope, UserToken}
  alias AiControl.Organizations
  alias AiControl.Organizations.Invitations
  alias AiControl.Repo

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
    {user, _} = Accounts.get_user_by_session_token(get_session(conn, :user_token))
    assert user.email == invitation.email
    assert Accounts.sudo_mode?(user)
    assert {:error, :invalid_invitation} = Invitations.preview(token)
  end

  for age <- [1, 11, 21] do
    test "acceptance preserves a session authenticated #{age} minutes ago", %{conn: conn} do
      organization = organization_fixture()
      other_organization = organization_fixture()
      member = member_fixture(other_organization)
      user = member.user
      {invitation, invitation_token} = invitation_fixture(organization, %{email: user.email})
      remember_me = unquote(age) != 11

      conn =
        post(conn, ~p"/users/log-in",
          user: %{
            email: user.email,
            password: valid_user_password(),
            remember_me: to_string(remember_me)
          }
        )

      session_token = get_session(conn, :user_token)
      authenticated_at = DateTime.add(DateTime.utc_now(:second), -unquote(age), :minute)
      override_token_authenticated_at(session_token, authenticated_at)
      conn = conn |> recycle() |> get(~p"/invitations/#{invitation_token}")

      csrf_token =
        conn
        |> html_response(200)
        |> LazyHTML.from_document()
        |> LazyHTML.query("#invitation-accept-form input[name='_csrf_token']")
        |> LazyHTML.attribute("value")
        |> List.first()

      assert csrf_token
      conn = conn |> recycle() |> get(~p"/invitations/#{invitation_token}/sign-in")
      session = get_session(conn)
      assert session["user_return_to"] == ~p"/invitations/#{invitation_token}"
      assert session["_csrf_token"]
      assert session["live_socket_id"]
      remember_cookie = conn.req_cookies["_ai_control_web_user_remember_me"]
      assert is_binary(remember_cookie) == remember_me

      sessions =
        Repo.all(from(t in UserToken, where: t.user_id == ^user.id and t.context == "session"))

      conn =
        conn
        |> recycle()
        |> put_private(:plug_skip_csrf_protection, false)
        |> post(~p"/invitations/accept",
          _csrf_token: csrf_token,
          user: %{token: invitation_token}
        )

      assert redirected_to(conn) == ~p"/organizations/#{organization.organization.id}"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) == "You have joined the organization."
      assert get_session(conn, :user_token) == session_token
      assert get_session(conn, :live_socket_id) == session["live_socket_id"]
      assert get_session(conn, :_csrf_token) == session["_csrf_token"]
      assert get_session(conn, :user_remember_me) == session["user_remember_me"]
      refute get_session(conn, :user_return_to)
      refute Map.has_key?(conn.resp_cookies, "_ai_control_web_user_remember_me")
      assert conn.req_cookies["_ai_control_web_user_remember_me"] == remember_cookie

      assert Repo.all(
               from(t in UserToken, where: t.user_id == ^user.id and t.context == "session")
             ) == sessions

      {authenticated_user, _} = Accounts.get_user_by_session_token(session_token)
      assert authenticated_user.authenticated_at == authenticated_at
      assert invitation_for(invitation.id).accepted_at
      assert {:error, :invalid_invitation} = Invitations.preview(invitation_token)

      assert {:ok, _} =
               Organizations.fetch_scope(Scope.for_user(user), organization.organization.id)

      assert {:ok, _} = Organizations.refresh_scope(member.scope)

      if unquote(age) >= 10 do
        assert {:error, {:redirect, %{to: "/users/log-in"}}} =
                 live(recycle(conn), ~p"/users/settings")

        password = "a replacement password"

        rejected =
          conn
          |> recycle()
          |> put_private(:plug_skip_csrf_protection, false)
          |> post(~p"/users/update-password",
            _csrf_token: csrf_token,
            user: %{password: password, password_confirmation: password}
          )

        assert redirected_to(rejected) == ~p"/users/log-in"
        assert Accounts.get_user!(user.id).hashed_password == user.hashed_password
        refute Accounts.get_user_by_email_and_password(user.email, password)
      else
        assert Accounts.sudo_mode?(authenticated_user)
        assert {:ok, settings, _} = live(recycle(conn), ~p"/users/settings")
        assert has_element?(settings, "#password_form")
      end
    end
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

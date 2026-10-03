defmodule AiControlWeb.UserSessionControllerTest do
  use AiControlWeb.ConnCase, async: false

  import AiControl.AccountsFixtures
  import ExUnit.CaptureLog

  alias AiControl.Accounts

  test "password login rotates the session and remembers the organizer", %{conn: conn} do
    {:ok, {user, :created}} =
      Accounts.bootstrap_organizer(unique_user_email(), valid_user_password())

    conn =
      conn
      |> init_test_session(%{unrelated: "discard"})
      |> post(~p"/users/log-in",
        user: %{email: user.email, password: valid_user_password(), remember_me: "true"}
      )

    assert redirected_to(conn) == ~p"/platform/organizations"
    assert token = get_session(conn, :user_token)
    assert Accounts.get_user_by_session_token(token)
    refute get_session(conn, :unrelated)
    assert conn.resp_cookies["_ai_control_web_user_remember_me"].http_only
    assert conn.resp_cookies["_ai_control_web_user_remember_me"].same_site == "Lax"
  end

  test "invalid and unknown credentials have the same error", %{conn: conn} do
    user = user_fixture() |> set_password()

    for email <- [user.email, unique_user_email()] do
      failed = post(conn, ~p"/users/log-in", user: %{email: email, password: "wrong password"})
      assert redirected_to(failed) == ~p"/users/log-in"
      refute get_session(failed, :user_token)
      assert Phoenix.Flash.get(failed.assigns.flash, :error) == "Invalid email or password"
    end
  end

  test "email normalization is shared by password login", %{conn: conn} do
    user = user_fixture() |> set_password()

    conn =
      post(conn, ~p"/users/log-in",
        user: %{email: "  " <> String.upcase(user.email) <> "  ", password: valid_user_password()}
      )

    assert get_session(conn, :user_token)
  end

  test "recovery is indistinguishable for known and unknown accounts", %{conn: conn} do
    user = user_fixture()
    known = post(conn, ~p"/users/recover", user: %{email: user.email})
    unknown = post(conn, ~p"/users/recover", user: %{email: unique_user_email()})
    assert redirected_to(known) == ~p"/users/recover"
    assert redirected_to(unknown) == ~p"/users/recover"

    assert Phoenix.Flash.get(known.assigns.flash, :info) ==
             Phoenix.Flash.get(unknown.assigns.flash, :info)

    assert Accounts.UserToken |> AiControl.Repo.get_by!(user_id: user.id, context: "login")
  end

  test "account limits cover password attempts and recovery on different IPs", %{conn: conn} do
    email = unique_user_email()

    for i <- 1..5 do
      request =
        %{conn | remote_ip: {192, 0, 2, i}}
        |> post(~p"/users/log-in", user: %{email: email, password: "wrong password"})

      assert request.status == 302
    end

    blocked =
      %{conn | remote_ip: {192, 0, 2, 6}}
      |> post(~p"/users/recover", user: %{email: "  " <> String.upcase(email) <> "  "})

    assert html_response(blocked, 429)
    assert [retry] = get_resp_header(blocked, "retry-after")
    assert String.to_integer(retry) in 1..900
    assert blocked.halted
  end

  test "adding a non-string token cannot bypass the email limit", %{conn: conn} do
    email = unique_user_email()

    for _ <- 1..5 do
      post(conn, ~p"/users/log-in", user: %{email: email, password: "wrong password"})
    end

    blocked =
      post(conn, ~p"/users/log-in", user: %{email: email, password: "wrong password", token: nil})

    assert blocked.status == 429
  end

  test "peer IP limit covers tokens and ignores spoofed forwarding headers", %{conn: conn} do
    for i <- 1..20 do
      result =
        conn
        |> put_req_header("x-forwarded-for", "192.0.2.#{i}")
        |> post(~p"/users/log-in", user: %{token: "bad-token-#{i}"})

      assert result.status == 302
    end

    assert post(conn, ~p"/users/log-in", user: %{token: "bad-token"}).status == 429
  end

  test "recovery token is single use and lands in password settings", %{conn: conn} do
    user = user_fixture()
    {token, _} = generate_user_magic_link_token(user)
    restored = post(conn, ~p"/users/log-in", user: %{token: token})
    assert get_session(restored, :user_token)
    assert redirected_to(restored) == ~p"/users/settings"
    reused = post(conn, ~p"/users/log-in", user: %{token: token})
    refute get_session(reused, :user_token)
    assert redirected_to(reused) == ~p"/users/log-in"
  end

  test "malformed form data fails without a server error", %{conn: conn} do
    assert post(conn, ~p"/users/log-in", user: %{email: "x"}).status == 400
    assert post(conn, ~p"/users/recover", user: %{email: ["x"]}).status == 400
  end

  test "logout revokes the token and disconnects its LiveViews", %{conn: conn} do
    user = user_fixture() |> set_password()

    conn =
      post(conn, ~p"/users/log-in", user: %{email: user.email, password: valid_user_password()})

    token = get_session(conn, :user_token)
    AiControlWeb.Endpoint.subscribe("users_sessions:#{Base.url_encode64(token)}")
    conn = delete(conn, ~p"/users/log-out")
    assert redirected_to(conn) == ~p"/users/log-in"
    refute get_session(conn, :user_token)
    refute Accounts.get_user_by_session_token(token)
    assert_receive %Phoenix.Socket.Broadcast{event: "disconnect"}
  end

  test "password update rejects stale authentication and preserves the old hash", %{conn: conn} do
    user = user_fixture() |> set_password()

    conn =
      log_in_user(conn, user,
        token_authenticated_at: DateTime.add(DateTime.utc_now(:second), -11, :minute)
      )

    conn = post(conn, ~p"/users/update-password", user: %{password: "a replacement password"})
    assert redirected_to(conn) == ~p"/users/log-in"
    assert Accounts.get_user_by_email_and_password(user.email, valid_user_password())
  end

  test "direct password update accepts authentication aged nine minutes and revokes old sessions",
       %{conn: conn} do
    user = user_fixture() |> set_password()
    other_token = Accounts.generate_user_session_token(user)

    conn =
      log_in_user(conn, user,
        token_authenticated_at: DateTime.add(DateTime.utc_now(:second), -9, :minute)
      )

    old_token = get_session(conn, :user_token)
    password = "a replacement password"

    conn =
      post(conn, ~p"/users/update-password",
        user: %{password: password, password_confirmation: password}
      )

    assert redirected_to(conn) == ~p"/users/settings"
    assert get_session(conn, :user_token) != old_token
    assert Accounts.get_user_by_session_token(get_session(conn, :user_token))
    refute Accounts.get_user_by_session_token(old_token)
    refute Accounts.get_user_by_session_token(other_token)
    assert Accounts.get_user_by_email_and_password(user.email, password)
  end

  test "direct password update reports invalid values without crashing", %{conn: conn} do
    conn =
      conn
      |> log_in_user(user_fixture())
      |> post(~p"/users/update-password", user: %{password: "short"})

    assert redirected_to(conn) == ~p"/users/settings"
    assert Phoenix.Flash.get(conn.assigns.flash, :error)
  end

  test "public registration has no GET or POST route", %{conn: conn} do
    assert get(conn, "/users/register").status == 404
    assert post(conn, "/users/register", %{}).status == 404
  end

  test "authentication POSTs require CSRF when protection is enabled", %{conn: conn} do
    conn = put_private(conn, :plug_skip_csrf_protection, false)

    assert_raise Plug.CSRFProtection.InvalidCSRFTokenError, fn ->
      post(conn, ~p"/users/log-in",
        user: %{email: unique_user_email(), password: "wrong password"}
      )
    end
  end

  test "token paths and credentials are absent from debug logs", %{conn: conn} do
    user = user_fixture() |> set_password()
    {token, _} = generate_user_magic_link_token(user)
    previous = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: previous) end)

    logs =
      capture_log(fn ->
        get(conn, ~p"/users/log-in/#{token}")

        post(conn, ~p"/users/log-in",
          user: %{email: user.email, password: "private-test-password"}
        )
      end)

    refute logs =~ token
    refute logs =~ "private-test-password"
    refute logs =~ user.hashed_password
  end
end

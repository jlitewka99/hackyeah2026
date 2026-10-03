defmodule AiControlWeb.UserSessionController do
  use AiControlWeb, :controller

  alias AiControl.Accounts
  alias AiControl.Accounts.LoginLimiter
  alias AiControlWeb.UserAuth

  plug :limit_attempts when action in [:create, :request_link]

  def create(conn, %{"user" => %{"token" => token} = user_params}) when is_binary(token) do
    case Accounts.login_user_by_magic_link(token) do
      {:ok, {user, tokens_to_disconnect}} ->
        UserAuth.disconnect_sessions(tokens_to_disconnect)

        conn
        |> put_session(:user_return_to, ~p"/users/settings")
        |> put_flash(:info, "Access restored. You can now update your password.")
        |> UserAuth.log_in_user(user, user_params)

      _ ->
        invalid_login(conn, "The link is invalid or it has expired.")
    end
  end

  def create(conn, %{"user" => %{"email" => email, "password" => password} = user_params})
      when is_binary(email) and is_binary(password) do
    if user = Accounts.get_user_by_email_and_password(email, password) do
      conn
      |> put_flash(:info, "Welcome back!")
      |> UserAuth.log_in_user(user, user_params)
    else
      conn
      |> put_flash(:email, String.slice(email, 0, 160))
      |> invalid_login("Invalid email or password")
    end
  end

  def create(conn, _params), do: send_resp(conn, :bad_request, "Invalid sign-in request.")

  def request_link(conn, %{"user" => %{"email" => email}}) when is_binary(email) do
    if user = Accounts.get_user_by_email(email) do
      Accounts.deliver_login_instructions(user, &url(~p"/users/log-in/#{&1}"))
    end

    conn
    |> put_flash(:info, "If an account matches that email, a recovery link will arrive shortly.")
    |> redirect(to: ~p"/users/recover")
  end

  def request_link(conn, _params), do: send_resp(conn, :bad_request, "Invalid recovery request.")

  def update_password(conn, %{"user" => user_params}) do
    user = conn.assigns.current_scope.user

    if Accounts.sudo_mode?(user) do
      case Accounts.update_user_password(user, user_params) do
        {:ok, {user, expired_tokens}} ->
          UserAuth.disconnect_sessions(expired_tokens)

          conn
          |> put_session(:user_return_to, ~p"/users/settings")
          |> put_flash(:info, "Password updated successfully!")
          |> UserAuth.log_in_user(user)

        {:error, _changeset} ->
          conn
          |> put_flash(:error, "Password must be 12–72 characters and match its confirmation.")
          |> redirect(to: ~p"/users/settings")
      end
    else
      invalid_login(conn, "You must re-authenticate to change your password.")
    end
  end

  def update_password(conn, _params),
    do: send_resp(conn, :bad_request, "Invalid password request.")

  def delete(conn, _params) do
    conn
    |> put_flash(:info, "Logged out successfully.")
    |> UserAuth.log_out_user()
  end

  defp invalid_login(conn, message) do
    conn |> put_flash(:error, message) |> redirect(to: ~p"/users/log-in")
  end

  defp limit_attempts(conn, _opts) do
    email =
      case conn.params do
        %{"user" => %{"token" => token}} when is_binary(token) ->
          nil

        %{"user" => %{"email" => email}} when is_binary(email) ->
          email |> Accounts.User.normalize_email() |> String.slice(0, 160)

        _ ->
          nil
      end

    case LoginLimiter.check(conn.remote_ip, email) do
      :ok ->
        conn

      {:error, retry_after} ->
        conn
        |> put_resp_header("retry-after", Integer.to_string(retry_after))
        |> put_status(:too_many_requests)
        |> put_view(html: AiControlWeb.UserSessionHTML)
        |> render(:rate_limited, retry_after: retry_after)
        |> halt()
    end
  end
end
